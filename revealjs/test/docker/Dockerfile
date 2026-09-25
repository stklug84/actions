# Pin-only, multi-stage Dockerfile for the revealjs/* integration test in
# this repository (.github/workflows/lint.yml, job revealjs-render). It is
# never built: revealjs/resolve-images extracts each stage's FROM
# reference and the test runs the three tools via `docker run`. Pinning by
# digest makes the test reproducible; Dependabot's docker ecosystem keeps
# the digests current. Consumers keep their own copy of this file (see the
# README of revealjs/resolve-images).

# DL3007 (avoid :latest) does not apply: every reference carries an
# explicit version tag AND a digest.
FROM pandoc/core:3.11.0.0-alpine@sha256:62518bfb6833705dc90a1634d8d879299bd820b3f74ad3b32fba8b618452553a AS pandoc
FROM minlag/mermaid-cli:11.17.0@sha256:a6fb0574dded4086888b5e38476899c9aff8963196f689f11a0f8fceee588ce1 AS mermaid
FROM ghcr.io/astefanutti/decktape:3.16.1@sha256:66f5eff34a444628f5ab524da5390a454412fa879f3d15df96daf4c5c8da6b33 AS decktape
