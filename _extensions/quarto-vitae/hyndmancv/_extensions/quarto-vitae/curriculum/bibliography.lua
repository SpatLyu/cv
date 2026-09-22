--- Bibliography carriers: CSL items as entry data, rendered by citeproc.
---
--- The filter parses no citation data itself. Inline payloads normalise
--- through `pandoc.read`, and a `file=` is handed to a scoped citeproc run as
--- `bibliography:` metadata, so every format citeproc accepts works by
--- construction, with parsing and diagnostics all pandoc's. Shares nothing
--- with the table path except the template layer.

local M = {}

--- Guess a payload's format from its first non-whitespace byte.
---
--- Reliable rather than heuristic: the three grammars are disjoint there.
--- `@` opens a bibtex entry, `[`/`{` open CSL-JSON, and CSL-YAML can start
--- with neither.
--- @param text string
--- @return string format
function M.sniff(text)
  local first = text:match("^%s*(%S)")
  if first == "@" then return "bibtex" end
  if first == "[" or first == "{" then return "csljson" end
  return "cslyaml"
end

--- Aliases accepted by the `format:` override, normalised to the three
--- internal names. Fence classes are normalised in options.lua instead.
local FORMAT_ALIASES = {
  bibtex = "bibtex", biblatex = "bibtex",
  csljson = "csljson", json = "csljson",
  cslyaml = "cslyaml", yaml = "cslyaml",
}

--- Normalise a declared format name, warning about an unknown one.
--- @param name any
--- @return string|nil format
function M.normalise_format(name)
  if name == nil then return nil end
  local format = FORMAT_ALIASES[tostring(name):lower()]
  if not format then
    quarto.log.warning(
      "vitae: unknown bibliography format '" .. tostring(name) ..
      "'; supported: bibtex, csljson, cslyaml. Sniffing instead")
  end
  return format
end

--- Read one payload into CSL items.
---
--- CSL-YAML has no pandoc reader of its own, so it is wrapped as a metadata
--- block and read as markdown; the payload is a top-level YAML list, which
--- sits legally at the same indentation as the `references:` key.
--- @param text string
--- @param format string one of bibtex | csljson | cslyaml
--- @return boolean ok, pandoc.Pandoc|string result document or error
local function read_payload(text, format)
  if format == "bibtex" then
    return pcall(pandoc.read, text, "bibtex")
  elseif format == "csljson" then
    return pcall(pandoc.read, text, "csljson")
  end
  return pcall(pandoc.read, "---\nreferences:\n" .. text .. "\n---\n", "markdown")
end

--- Convert payload text into a list of CSL items (pandoc references).
---
--- Never falls through silently: a payload that does not parse warns and
--- yields nil. With a declared format the message is pandoc's own error; with
--- a sniffed one it names the guess, since the guess itself may be the
--- problem.
--- @param text string
--- @param format string|nil declared format; nil sniffs
--- @return pandoc.List|nil references
function M.to_references(text, format)
  local declared = format ~= nil
  format = format or M.sniff(text)

  local ok, result = read_payload(text, format)
  if ok and result.meta.references and #result.meta.references > 0 then
    return result.meta.references
  end

  local problem = ok and "no references found in the payload"
    or "pandoc reports: " .. tostring(result):gsub("%s+$", "")
  if declared then
    quarto.log.warning(
      "vitae: could not read bibliography payload as " .. format .. "; " .. problem)
  else
    quarto.log.warning(
      "vitae: bibliography payload looks like " .. format .. ", but " .. problem ..
      ". Set `format:` if the guess is wrong")
  end
  return nil
end

--- Resolve a bibliography `file=` relative to the document being rendered.
---
--- The one documented place this rule lives: records `file=` (§3c) must match
--- it when implemented.
--- @param path string
--- @return string absolute path
function M.resolve_file(path)
  if pandoc.path.is_absolute(path) then return path end
  return pandoc.path.join({ pandoc.path.directory(quarto.doc.input_file), path })
end

--- Document metadata copied into each scoped run, so a carrier renders under
--- the same citeproc configuration as the document itself.
local CITEPROC_META = {
  "csl", "lang", "link-citations", "link-bibliography",
  "citation-abbreviations", "notes-after-punctuation",
}

--- `nocite: '@*'`, selecting every item the run's source provides.
local function nocite_all()
  return pandoc.MetaInlines({ pandoc.Cite(
    { pandoc.Str("@*") },
    { pandoc.Citation("*", "NormalCitation") }) })
end

--- Run citeproc over one carrier's citation data — the multibib pattern.
---
--- Builds a mini-document holding only metadata: the citeproc-relevant fields
--- of the real document, the carrier's source, and a wildcard nocite. Each
--- carrier is its own run, so a key may recur across sections and a numbered
--- style restarts per section.
---
--- No `csl` is forced here: with none set, citeproc falls back to its own
--- default style, which sorts alphabetically by author-date. A CV author who
--- wants data order preserved (or sorted by time, etc.) supplies their own
--- `csl:` — see the README for pointers to styles that do this.
--- @param source table { bibliography = path } or { references = items }
--- @param doc_meta pandoc.Meta
--- @return pandoc.Blocks|nil entries the refs div content
--- @return pandoc.Div|nil refs_div citeproc's whole refs div
--- @return table refs recovered CSL items, for id/type roles
function M.scoped_citeproc(source, doc_meta)
  local meta = pandoc.Meta({})
  for _, key in ipairs(CITEPROC_META) do
    if doc_meta[key] ~= nil then meta[key] = doc_meta[key] end
  end
  if source.bibliography then
    meta.bibliography = pandoc.MetaString(source.bibliography)
  else
    meta.references = source.references
  end
  meta.nocite = nocite_all()

  local mini = pandoc.Pandoc({}, meta)
  local ok, processed = pcall(pandoc.utils.citeproc, mini)
  if not ok then
    quarto.log.warning("vitae: citeproc failed: " .. tostring(processed))
    return nil, nil, {}
  end

  local refs_div = nil
  for _, block in ipairs(processed.blocks) do
    if block.t == "Div" and block.identifier == "refs" then refs_div = block end
  end
  if not refs_div then
    quarto.log.warning("vitae: citeproc produced no bibliography")
    return nil, nil, {}
  end

  -- Recover the items for the `id`/`type` roles. Only *cited* items are
  -- returned, which the wildcard nocite makes all of them.
  local ok_refs, refs = pcall(pandoc.utils.references, mini)
  return refs_div.content, refs_div, ok_refs and refs or {}
end

return M
