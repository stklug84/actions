#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	java (JRE 11+, on PATH — installed by action.yml)
#	robot.jar (ontodev/robot — downloaded by action.yml)
# @description:
#	Check OWL ontologies for logical consistency and coherence with
#	`robot reason` for the rdf/reason-owl composite action. Driven by
#	environment variables: FILES (space-separated ontology files,
#	each reasoned independently), REASONER (hermit | elk | whelk |
#	jfact | structural), and ROBOT_JAR (path to the robot.jar).
#	`robot reason` exits nonzero on logical inconsistency and on
#	unsatisfiable classes, so a passing file is both consistent and
#	coherent. The reasoned output is written to a throwaway temp
#	.owl file and discarded — only the exit status matters (ROBOT
#	infers the output format from the file extension, so
#	--output /dev/null would fail with INVALID FORMAT ERROR).
#	Prints `OK <file>` / `FAIL <file>` (plus ROBOT's diagnostics on
#	failure) and exits nonzero when any file fails or is missing.
# @arguments:
#	none (configured via environment variables, see @description)
## Usage: FILES="<file> [<file> ...]" [REASONER=hermit] ROBOT_JAR=<path> scripts/reason.sh
### Example: FILES="ontology/core.owl" REASONER=elk ROBOT_JAR=/tmp/robot.jar scripts/reason.sh

set -euo pipefail

FILES="${FILES:?FILES is required (space-separated ontology files)}"
REASONER="${REASONER:-hermit}"
ROBOT_JAR="${ROBOT_JAR:?ROBOT_JAR is required (path to robot.jar)}"

err() { echo "::error::$*" >&2; }

command -v java >/dev/null 2>&1 || {
	err "java not found on PATH"
	exit 1
}
if [ ! -f "$ROBOT_JAR" ]; then
	err "robot.jar not found at $ROBOT_JAR."
	exit 1
fi

case "$REASONER" in
hermit | elk | whelk | jfact | structural) ;;
*)
	err "Unknown reasoner '$REASONER' (expected hermit, elk, whelk, jfact, or structural)."
	exit 1
	;;
esac

read -ra FILE_LIST <<<"$FILES"
if [ "${#FILE_LIST[@]}" -eq 0 ]; then
	err "FILES contains no files."
	exit 1
fi

# Throwaway output target: ROBOT infers the output format from the file
# extension, so the discarded result needs a real .owl path (a bare
# /dev/null fails with INVALID FORMAT ERROR).
TMPDIR_REASON="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_REASON"' EXIT
TMP_OUT="$TMPDIR_REASON/reasoned.owl"

FAILURES=0
for file in "${FILE_LIST[@]}"; do
	if [ ! -f "$file" ]; then
		echo "FAIL $file"
		err "$file not found."
		FAILURES=$((FAILURES + 1))
		continue
	fi
	if OUTPUT="$(java -jar "$ROBOT_JAR" reason \
		--reasoner "$REASONER" --input "$file" --output "$TMP_OUT" 2>&1)"; then
		echo "OK   $file"
	else
		echo "FAIL $file"
		if [ -n "$OUTPUT" ]; then
			echo "$OUTPUT"
		fi
		FAILURES=$((FAILURES + 1))
	fi
done

echo
echo "Reasoned over ${#FILE_LIST[@]} file(s), $FAILURES failure(s)."
[ "$FAILURES" -eq 0 ]
