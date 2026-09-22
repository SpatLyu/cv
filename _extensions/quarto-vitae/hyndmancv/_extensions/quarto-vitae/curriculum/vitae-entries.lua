--- vitae-entries: render tabular CV data through template-specific listings.
---
--- Finds tables carried by an attribute carrier (a `.entries` fenced div, or a
--- code cell with `vitae` options), renames their columns, and renders them
--- with a pandoc template supplied by the active CV format extension.
---
--- This filter knows no role vocabulary. Every column reaches the template under
--- its own name, or the name `fields` gives it, and nothing else is added or
--- assumed. `what`/`when`/`with`/`where`/`why` are a convention among template
--- authors, not names implemented here.

local options = require("options")
local bibliography = require("bibliography")

--- The pandoc format, and template extension, to render entries into.
---
--- Cached: the target cannot change mid-render, and this is asked for once per
--- carrier. Resolved lazily rather than at load time, so `quarto.doc` is ready.
local target_format_cache = nil
local function target_format()
  if not target_format_cache then
    if quarto.doc.is_format("latex") then
      target_format_cache = { "latex", "tex" }
    elseif quarto.doc.is_format("typst") then
      target_format_cache = { "typst", "typ" }
    elseif quarto.doc.is_format("html") then
      target_format_cache = { "html", "html" }
    else
      target_format_cache = { "markdown", "md" }
    end
  end
  return target_format_cache[1], target_format_cache[2]
end

--- Render inline content into the target format.
---
--- Pandoc does the writing, so special characters are escaped exactly once and
--- markdown in a cell survives. Handlers receive ready-to-emit markup and must
--- not escape it again.
local function render_inlines(inlines, format)
  if not inlines or #inlines == 0 then return "" end
  local text = pandoc.write(pandoc.Pandoc({ pandoc.Plain(inlines) }), format)
  return options.trim(text)
end

--- Read a table cell as either a scalar value or a list of values.
---
--- A cell holding a bullet list, which only grid tables allow, yields one value
--- per item; anything else is a single value. A property of the cell, not of
--- which column it is in.
local function read_cell(cell, format)
  local blocks = cell.contents
  if #blocks == 1 and blocks[1].t == "BulletList" then
    local items = {}
    for _, item in ipairs(blocks[1].content) do
      items[#items + 1] = render_inlines(pandoc.utils.blocks_to_inlines(item), format)
    end
    return items
  end
  return render_inlines(pandoc.utils.blocks_to_inlines(blocks), format)
end

--- Build a column index -> template variable name mapping for a table.
---
--- The default is the identity, so `fields` is only a set of overrides. It is
--- written new: old per dplyr::rename() and inverted here, to be looked up by
--- the table's own column name. Nothing is dropped, and no name is special.
---
--- A name may claim several columns (`{why: [achievements, notes]}`); their
--- values combine into one list.
local function column_names(head_row, config)
  local renamed = {}
  if type(config.fields) == "table" then
    for new, old in pairs(config.fields) do
      if type(old) == "string" then
        renamed[old:lower()] = new
      elseif type(old) == "table" then
        for _, column in ipairs(old) do
          if type(column) == "string" then renamed[column:lower()] = new end
        end
      end
    end
  end

  local names = {}
  for i, cell in ipairs(head_row.cells) do
    local header = options.trim(pandoc.utils.stringify(cell.contents)):lower()
    names[i] = renamed[header] or header
  end
  return names
end

--- Do two entries agree on every field except `column`?
local function same_but(a, b, column)
  for field, value in pairs(a) do
    if field ~= column and b[field] ~= value then return false end
  end
  for field, value in pairs(b) do
    if field ~= column and a[field] ~= value then return false end
  end
  return true
end

--- Append a value, flattening nested lists and dropping empty cells.
local function push(out, value)
  if type(value) == "table" then
    for _, item in ipairs(value) do push(out, item) end
  elseif value ~= nil and value ~= "" then
    out[#out + 1] = value
  end
end

--- Combine two field values into one list, dropping empty cells.
local function merge_values(head, tail)
  local out = {}
  push(out, head)
  push(out, tail)
  return out
end

--- Convert a pandoc Table into a list of entries keyed by column name.
local function table_to_entries(tbl, config, format)
  local head_rows = tbl.head.rows
  if #head_rows == 0 then
    quarto.log.warning("vitae: table has no header row, cannot name its columns")
    return {}
  end
  local names = column_names(head_rows[1], config)

  -- Opt-in, and names its column: collapsing on a guessed one would silently
  -- merge rows that genuinely differ.
  local collapse = config.collapse

  local entries = {}
  for _, body in ipairs(tbl.bodies) do
    for _, row in ipairs(body.body) do
      local entry = {}
      for i, cell in ipairs(row.cells) do
        local name = names[i]
        if name then
          local value = read_cell(cell, format)
          -- Columns sharing a name combine, in table column order.
          if entry[name] == nil then
            entry[name] = value
          else
            entry[name] = merge_values(entry[name], value)
          end
        end
      end

      -- How a pipe table builds a multi-item field, its cells being unable to
      -- hold a bullet list: consecutive rows differing only there accumulate.
      local previous = entries[#entries]
      if collapse and previous and entry[collapse] ~= nil
        and same_but(previous, entry, collapse) then
        previous[collapse] = merge_values(previous[collapse], entry[collapse])
      else
        entries[#entries + 1] = entry
      end
    end
  end

  return entries
end

local function is_directory(path)
  return pcall(pandoc.system.list_directory, path)
end

--- Every `_extensions/**/entries` directory in the project.
---
--- Extensions install either directly (`_extensions/yourcv`) or under an
--- organisation (`_extensions/quarto-vitae/yourcv`), so both depths are
--- searched. Cached, so this runs once per render.
local entries_dirs_cache = nil
local function extension_entries_dirs()
  if entries_dirs_cache then return entries_dirs_cache end
  entries_dirs_cache = {}

  local ok, top = pcall(pandoc.system.list_directory, "_extensions")
  if not ok then return entries_dirs_cache end

  for _, name in ipairs(top) do
    local dir = pandoc.path.join({ "_extensions", name })
    if is_directory(dir) then
      local direct = pandoc.path.join({ dir, "entries" })
      if is_directory(direct) then
        entries_dirs_cache[#entries_dirs_cache + 1] = direct
      end
      local ok_sub, subs = pcall(pandoc.system.list_directory, dir)
      if ok_sub then
        for _, sub in ipairs(subs) do
          local nested = pandoc.path.join({ dir, sub, "entries" })
          if is_directory(nested) then
            entries_dirs_cache[#entries_dirs_cache + 1] = nested
          end
        end
      end
    end
  end
  return entries_dirs_cache
end

local function read_file(path)
  local handle = io.open(path, "r")
  if not handle then return nil end
  local content = handle:read("*a")
  handle:close()
  return content
end

--- Locate the template for a style, in the documented resolution order.
---
--- Step 3 reads extension sources directly. `format-resources` is copied only
--- after pandoc runs, so a template resolved that way works on every render
--- except the first: silently correct locally, silently broken in CI.
---
--- `no_generic` opts out of step 4, for styles with a better fallback than the
--- generic layout — bibliographies fall back to citeproc's own output.
---
--- @return string|nil source, string|nil path, boolean generic
local function find_template(style, ext, meta, no_generic)
  local filename = style .. "." .. ext

  -- 1. Document metadata override.
  local override = meta.vitae and meta.vitae.templates and meta.vitae.templates[style]
  if override then
    local path = pandoc.utils.stringify(override)
    local source = read_file(path)
    if source then return source, path, false end
    quarto.log.warning("vitae: template override not found: " .. path)
  end

  -- 2. An `entries/` directory beside the document. Also where
  --    `format-resources` lands, so this keeps working for anyone relying on it.
  local local_path = pandoc.path.join({ "entries", filename })
  local source = read_file(local_path)
  if source then return source, local_path, false end

  -- 3. Any installed extension providing this style.
  local found, sources = {}, {}
  for _, dir in ipairs(extension_entries_dirs()) do
    local path = pandoc.path.join({ dir, filename })
    local content = read_file(path)
    if content then
      found[#found + 1] = path
      sources[#sources + 1] = content
    end
  end
  if #found > 1 then
    quarto.log.warning(
      "vitae: several extensions provide a '" .. style .. "' template (" ..
      table.concat(found, ", ") .. "); using the first")
  end
  if found[1] then return sources[1], found[1], false end

  if no_generic then return nil, nil, false end

  -- 4. This extension's generic fallback for the target format.
  local generic = quarto.utils.resolve_path("entries/generic." .. ext)
  source = read_file(generic)
  if source then return source, generic, true end

  return nil, nil, false
end

--- Warn that the generic layout is standing in for a style's own template.
---
--- The fallback is legitimate for a format with no CV templates, but hides a
--- packaging bug when the extension claims the style. The format's `styles:`
--- declaration tells the two apart; without one, there is nothing to report.
local function warn_generic_fallback(style, ext, meta)
  local declared = meta.vitae and meta.vitae.styles
  if not declared then return end

  local names, claims_style = {}, false
  for _, item in ipairs(declared) do
    local name = pandoc.utils.stringify(item)
    names[#names + 1] = name
    if name == style then claims_style = true end
  end

  if claims_style then
    quarto.log.warning(
      "vitae: this format declares style '" .. style ..
      "' but no " .. style .. "." .. ext ..
      " template was found; using the generic layout")
  else
    quarto.log.warning(
      "vitae: unknown style '" .. style .. "'; this format provides " ..
      table.concat(names, ", ") .. ". Using the generic layout")
  end
end

local function render_entries(entries, config, meta)
  local format, ext = target_format()
  local style = config.style or "detailed"

  local source, path, generic = find_template(style, ext, meta)
  if not source then
    quarto.log.warning(
      "vitae: no entries template found for style '" .. style ..
      "' and format '" .. format .. "'")
    return nil
  end

  if generic then warn_generic_fallback(style, ext, meta) end

  local template = pandoc.template.compile(source, pandoc.path.directory(path))
  local rendered = pandoc.layout.render(
    pandoc.template.apply(template, { entries = entries, style = style }))

  if config.as == "markdown" then
    return pandoc.read(rendered, "markdown").blocks
  end
  return pandoc.Blocks({ pandoc.RawBlock(format, rendered) })
end

--- Serialisations accepted by `input:`, mapped to their pandoc reader.
---
--- Opt-in, for when auto-printing does not work: the carrier prints text, which
--- every engine can do, instead of depending on how one renders a given type.
local INPUT_READERS = { csv = "csv" }

--- Read printed output as tables, for a carrier using `input:`.
---
--- Returns nil once it has reported a problem, so the caller does not warn again
--- about the same carrier.
local function read_input(el, config)
  local reader = INPUT_READERS[config.input]
  if not reader then
    quarto.log.warning(
      "vitae: unknown input '" .. tostring(config.input) ..
      "'; supported: csv")
    return nil
  end

  local tables = {}
  for _, text in ipairs(options.find_outputs(el.content)) do
    -- pandoc's own reader: quoting follows RFC 4180, and the result is an
    -- ordinary Table, so everything downstream is unaware of the difference.
    local ok, doc = pcall(pandoc.read, text, reader)
    if ok then
      for _, tbl in ipairs(options.find_tables(doc.blocks)) do
        tables[#tables + 1] = tbl
      end
    else
      quarto.log.warning(
        "vitae: could not read cell output as " .. config.input .. ": " ..
        tostring(doc))
    end
  end
  return tables
end

--- Warn about a carrier that asked for entries but supplied no table.
---
--- Worth warning about because it removes a whole section from the CV. The usual
--- cause is a code cell whose engine printed the object verbatim rather than as
--- a table, which depends on both the engine and the object's type.
local function warn_no_table(el, config)
  local where = config.style and ("style '" .. config.style .. "'") or "no style"
  if el.attr.identifier ~= "" then
    where = where .. ", #" .. el.attr.identifier
  end

  if config.file then
    quarto.log.warning(
      "vitae: `file` (" .. tostring(config.file) .. ") is not implemented yet " ..
      "(" .. where .. "); supply a table in the carrier instead")
  elseif config.input then
    quarto.log.warning(
      "vitae: carrier (" .. where .. ") set `input: " .. tostring(config.input) ..
      "` but printed nothing to read; the cell must print its data, e.g. " ..
      "write.csv(x, stdout(), row.names = FALSE)")
  elseif el.attr.classes:includes("cell") then
    quarto.log.warning(
      "vitae: code cell (" .. where .. ") produced no table, so no entries " ..
      "were rendered. The engine likely printed the value verbatim: knitr " ..
      "needs `df-print: kable` set by the format, and Jupyter only renders " ..
      "objects with an HTML table repr. See https://quarto-vitae.github.io/")
  else
    quarto.log.warning(
      "vitae: .entries div (" .. where .. ") contains no table, so no entries " ..
      "were rendered")
  end
end

--- Decide where a bibliography carrier's citation data comes from.
---
--- `file=` wins, and the filter never opens it: the path goes to the scoped
--- citeproc run as `bibliography:` metadata, so every format citeproc accepts
--- works by construction. Otherwise payloads (fenced blocks or printed
--- output) are read into CSL items, an explicit `format:` overriding the
--- fence class, which overrides sniffing.
---
--- Returns nil once it has warned, so the caller does not warn again.
--- @return table|nil source { bibliography = path } or { references = items }
local function bibliography_source(el, config)
  local payloads = options.find_payloads(el.content)

  if config.file then
    if #payloads > 0 then
      quarto.log.warning(
        "vitae: bibliography carrier has both `file` and an inline payload; " ..
        "using `file` (" .. tostring(config.file) .. ")")
    end
    local path = bibliography.resolve_file(tostring(config.file))
    local handle = io.open(path, "r")
    if not handle then
      quarto.log.warning(
        "vitae: bibliography file not found: " .. tostring(config.file) ..
        " (resolved to " .. path .. "; paths are relative to the document)")
      return nil
    end
    handle:close()
    return { bibliography = path }
  end

  if #payloads == 0 then
    local where = el.attr.identifier ~= "" and ("#" .. el.attr.identifier)
      or (el.attr.classes:includes("cell") and "code cell" or ".entries div")
    quarto.log.warning(
      "vitae: bibliography carrier (" .. where .. ") has neither `file` nor " ..
      "a payload, so no entries were rendered. Supply file=, a fenced " ..
      "bibtex/yaml/json block, or print citation data from the cell")
    return nil
  end

  local override = bibliography.normalise_format(config.format)
  local references = pandoc.List({})
  for _, payload in ipairs(payloads) do
    local items = bibliography.to_references(payload.text, override or payload.format)
    if items then references:extend(items) end
  end
  if #references == 0 then return nil end
  return { references = references }
end

--- Turn citeproc's refs div content into ordinary entries.
---
--- Each `.csl-entry` becomes one entry with a small role set: `entry` (the
--- rendered reference, written to the target format so escaping matches
--- `read_cell`), `id` (citation key, citeproc's `ref-` prefix stripped) and
--- `type` (CSL type, recovered via pandoc.utils.references). No CSL knowledge
--- reaches the template.
local function bibliography_entries(ref_blocks, items, format)
  local types = {}
  for _, item in ipairs(items) do
    types[tostring(item.id)] = item.type and tostring(item.type) or nil
  end

  local entries = {}
  for _, block in ipairs(ref_blocks) do
    if block.t == "Div" and block.classes:includes("csl-entry") then
      local id = block.identifier:gsub("^ref%-", "")
      -- Citeproc wraps each entry in a single Para; unwrapping it keeps the
      -- rendered value inline (no <p> in HTML), as read_cell does for cells.
      local content = block.content
      if #content == 1 and content[1].t == "Para" then
        content = pandoc.Blocks({ pandoc.Plain(content[1].content) })
      end
      entries[#entries + 1] = {
        entry = options.trim(pandoc.write(pandoc.Pandoc(content), format)),
        id = id,
        type = types[id],
      }
    end
  end
  return entries
end

--- Warn when the format declares the bibliography style but ships no template.
---
--- The passthrough is legitimate for a format with no opinion about
--- publication markup, but hides a packaging bug when the extension claims the
--- style. Mirrors warn_generic_fallback, with the passthrough as the fallback.
local function warn_bibliography_fallback(ext, meta)
  local declared = meta.vitae and meta.vitae.styles
  if not declared then return end
  for _, item in ipairs(declared) do
    if pandoc.utils.stringify(item) == "bibliography" then
      quarto.log.warning(
        "vitae: this format declares style 'bibliography' but no bibliography." ..
        ext .. " template was found; passing citeproc's output through")
      return
    end
  end
end

--- Process a bibliography carrier: scoped citeproc run, then the template
--- layer, with citeproc's own output as the fallback rather than the generic
--- template — the five-slot generic must never render citations.
local function process_bibliography(el, config, meta)
  local source = bibliography_source(el, config)
  if not source then return nil end

  local ref_blocks, refs_div, items = bibliography.scoped_citeproc(source, meta)
  if not ref_blocks then return nil end

  local format, ext = target_format()
  local template_source, path = find_template("bibliography", ext, meta, true)
  if not template_source then
    warn_bibliography_fallback(ext, meta)
    -- Passthrough of citeproc's own output. Its fixed `refs` id would recur
    -- across carriers and collide with a document-level bibliography, so the
    -- carrier's own identifier replaces it.
    refs_div.attr.identifier = el.attr.identifier
    return pandoc.Blocks({ refs_div })
  end

  local entries = bibliography_entries(ref_blocks, items, format)
  local template = pandoc.template.compile(template_source, pandoc.path.directory(path))
  local rendered = pandoc.layout.render(
    pandoc.template.apply(template, { entries = entries, style = "bibliography" }))

  if config.as == "markdown" then
    return pandoc.read(rendered, "markdown").blocks
  end
  return pandoc.Blocks({ pandoc.RawBlock(format, rendered) })
end

--- Process any attribute carrier: a `.entries` div, or a code cell whose
--- options carry vitae configuration.
local function process_div(el, meta)
  local config = options.read(el.attr)
  if not config then return nil end

  -- The one special case in the style system: the carrier's data is citation
  -- data, not records. The style decides the interpretation, never the file
  -- extension. The table path below is untouched.
  if config.style == "bibliography" then
    return process_bibliography(el, config, meta)
  end

  local format = target_format()

  -- `input:` reads printed text; otherwise take whatever table the engine
  -- rendered.
  local tables
  if config.input then
    tables = read_input(el, config)
    if not tables then return nil end
  else
    tables = options.find_tables(el.content)
  end

  if #tables == 0 then
    warn_no_table(el, config)
    return nil
  end

  local out = pandoc.Blocks({})
  for _, tbl in ipairs(tables) do
    local entries = table_to_entries(tbl, config, format)
    local blocks = render_entries(entries, config, meta)
    if blocks then out:extend(blocks) end
  end
  if #out == 0 then return nil end

  -- Replace the whole carrier, so .cell / .cell-output-* wrappers do not leak
  -- into the LaTeX or Typst output.
  return out
end

--- Only `Pandoc` is exported, and the walk is explicit.
---
--- A top-level `Div` function would run in pandoc's default traversal, which
--- happens *before* `Pandoc`, leaving document metadata unavailable and silently
--- disabling both the `vitae.templates` override and the `vitae.styles` warning.
--- Walking from here keeps metadata in scope.
function Pandoc(doc)
  return doc:walk({
    Div = function(el) return process_div(el, doc.meta) end
  })
end
