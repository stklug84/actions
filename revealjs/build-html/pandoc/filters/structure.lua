-- structure.lua: opinionated slide-structure rules on top of pandoc's own
-- heading -> slide mapping, plus a structure summary for the build wrapper.
--
--   * slide level: front-matter `slide-level` if present, else 2 when the
--     deck has any level-2 heading, else 1 (never pandoc's auto-detection,
--     which silently merges every ## when a # is followed by text).
--   * with slide level 2, every level-1 heading is a section divider: it
--     gets the `divider` class and the theme's `divider-background` colour
--     unless the heading already carries a background attribute.
--   * GitHub-style alerts (> [!NOTE] ...) become `callout callout-<kind>`
--     divs, so a deck previews on GitHub and renders as a themed callout.
--   * deck-only front-matter keys (theme, size, math, ...) are removed from
--     the metadata: pass 2 must never see them, because pandoc's HTML writer
--     defines template variables of the same name (e.g. `math`, `css`) and a
--     leftover metadata value would shadow them.
--   * writes <structure-file> as JSON:
--       {"slide_level":N,"headings":{"1":a,"2":b,...}}
--
-- Metadata consumed (supplied by prepare.py via --metadata-file):
--   structure-file, divider-background, slide-level (front matter)
local function stringify(v)
  return v and pandoc.utils.stringify(v) or nil
end

-- Front-matter keys owned by prepare.py; everything pandoc itself needs
-- (title, subtitle, author, date, institute, lang, keywords) stays.
local DECK_ONLY_KEYS = {
  'theme', 'css', 'size', 'slide-level', 'slide-number', 'transition',
  'navigation', 'center', 'logo', 'footer', 'math', 'highlight', 'mermaid',
  'pdf', 'reveal', 'title-slide',
}

local ALERTS = {
  ['[!NOTE]'] = 'note',
  ['[!TIP]'] = 'tip',
  ['[!IMPORTANT]'] = 'important',
  ['[!WARNING]'] = 'warning',
  ['[!CAUTION]'] = 'caution',
}

local function alert_to_callout(bq)
  local first = bq.content[1]
  if not first or first.t ~= 'Para' or #first.content == 0 then
    return nil
  end
  local marker = first.content[1]
  if marker.t ~= 'Str' or not ALERTS[marker.text] then
    return nil
  end
  local kind = ALERTS[marker.text]
  local rest = pandoc.List(first.content)
  rest:remove(1)
  while rest[1] and (rest[1].t == 'SoftBreak' or rest[1].t == 'Space' or rest[1].t == 'LineBreak') do
    rest:remove(1)
  end
  local blocks = pandoc.List(bq.content)
  if #rest == 0 then
    blocks:remove(1)
  else
    blocks[1] = pandoc.Para(rest)
  end
  return pandoc.Div(blocks, pandoc.Attr('', { 'callout', 'callout-' .. kind }))
end

local function has_background(attributes)
  for key, _ in pairs(attributes) do
    if key:match('^background') or key:match('^data%-background') then
      return true
    end
  end
  return false
end

function Pandoc(doc)
  local counts = {}
  doc.blocks:walk({
    Header = function(h)
      counts[h.level] = (counts[h.level] or 0) + 1
    end,
  })
  local level = tonumber(stringify(doc.meta['slide-level']))
  if not level then
    level = (counts[2] or 0) > 0 and 2 or 1
  end
  local divider_bg = stringify(doc.meta['divider-background'])

  doc.blocks = doc.blocks:walk({
    Header = function(h)
      if level == 2 and h.level == 1 then
        if not h.classes:includes('divider') then
          h.classes:insert('divider')
        end
        if divider_bg and not has_background(h.attributes) then
          h.attributes['background-color'] = divider_bg
        end
        return h
      end
      return nil
    end,
    BlockQuote = alert_to_callout,
  })

  for _, key in ipairs(DECK_ONLY_KEYS) do
    doc.meta[key] = nil
  end

  local file = stringify(doc.meta['structure-file'])
  if file then
    local headings = {}
    for lvl, n in pairs(counts) do
      headings[tostring(lvl)] = n
    end
    local fh = assert(io.open(file, 'w'))
    fh:write(pandoc.json.encode({ slide_level = level, headings = headings }))
    fh:write('\n')
    fh:close()
  end
  io.stderr:write(string.format('structure.lua: slide level %d\n', level))
  return doc
end
