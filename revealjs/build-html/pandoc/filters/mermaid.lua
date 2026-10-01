-- mermaid.lua: swap ```mermaid code blocks for image references and dump
-- the diagram source to <mermaid-dir>/<sha1>.mmd for build-time rendering.
-- Metadata (supplied via --metadata-file):
--   mermaid-dir   directory the .mmd files are written into (must exist)
--   mermaid-salt  string mixed into the hash (config/font/renderer identity)
local function stringify(v)
  return v and pandoc.utils.stringify(v) or nil
end

function Pandoc(doc)
  local dir = stringify(doc.meta['mermaid-dir'])
  if not dir then
    return nil
  end
  local salt = stringify(doc.meta['mermaid-salt']) or ''
  local count = 0
  local blocks = doc.blocks:walk({
    CodeBlock = function(cb)
      if not cb.classes:includes('mermaid') then
        return nil
      end
      local hash = pandoc.utils.sha1(salt .. '\n' .. cb.text)
      local path = dir .. '/' .. hash
      local fh = assert(io.open(path .. '.mmd', 'w'))
      fh:write(cb.text)
      if not cb.text:match('\n$') then
        fh:write('\n')
      end
      fh:close()
      count = count + 1
      -- Keep the block's own attributes (e.g. width=70%) on the image and
      -- tag it so the theme can size diagrams (img.mermaid).
      local attr = pandoc.Attr(cb.identifier, {'mermaid'}, cb.attributes)
      local img = pandoc.Image({}, path .. '.svg', '', attr)
      return pandoc.Para({img})
    end,
  })
  io.stderr:write(string.format('mermaid.lua: extracted %d diagram(s) to %s\n', count, dir))
  doc.blocks = blocks
  return doc
end
