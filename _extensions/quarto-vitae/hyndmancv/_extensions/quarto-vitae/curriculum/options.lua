--- Reading vitae configuration from Quarto cell and div attributes.
---
--- Quarto's engines do not agree on how a structured cell option reaches the
--- AST, so this module normalises the differences and is the only place that
--- inspects raw attributes:
---
---   value shape | knitr                  | jupyter
---   ------------|------------------------|-----------------------------------
---   scalar      | ("vitae", "detailed")  | same
---   list        | ("vitae-tags", "[…]")  | same (JSON array)
---   map         | ("vitae", "{…}")       | ("quarto-private-N",
---               |                        |  '{"key":"vitae","value":{…}}')
---
--- Only maps diverge, and only under jupyter, where the option is wrapped in a
--- `quarto-private-N` envelope. N restarts at 1 in each cell, so the envelope is
--- found by pattern rather than by a fixed key.

local M = {}

--- Config keys accepted as bare attributes on an `.entries` div. An allowlist,
--- so that a typo warns instead of being stored under the wrong name.
---
--- Only keys something reads belong here, so that accepting one promises it does
--- something. `file` qualifies: it is read to report that it is not implemented.
local BARE_KEYS = {
  style = true, fields = true, as = true, file = true,
  collapse = true, input = true, format = true,
}

local function is_json_object(str)
  return type(str) == "string" and str:match("^%s*[{%[]")
end

--- Decode an attribute value: JSON when it looks like JSON, else the raw string.
local function decode_value(str)
  if not is_json_object(str) then return str end
  local ok, decoded = pcall(quarto.json.decode, str)
  if ok then return decoded end
  quarto.log.warning("vitae: could not decode attribute value: " .. tostring(str))
  return str
end

--- Strip leading and trailing whitespace.
function M.trim(str)
  return (str:gsub("^%s+", ""):gsub("%s+$", ""))
end
local trim = M.trim

--- Strip one layer of matching quotes.
local function unquote(str)
  str = trim(str)
  local q = str:sub(1, 1)
  if #str >= 2 and (q == '"' or q == "'") and str:sub(-1) == q then
    return str:sub(2, -2)
  end
  return str
end

--- Split on `sep`, ignoring separators nested in brackets or quotes.
---
--- This is what lets a column name contain a comma or a colon, as in
--- `{what: 'Prize, Medal'}` and `{when: "Year: awarded"}`.
local function split_top(str, sep)
  local parts, buf, depth, quote = {}, {}, 0, nil
  for i = 1, #str do
    local c = str:sub(i, i)
    if quote then
      if c == quote then quote = nil end
      buf[#buf + 1] = c
    elseif c == '"' or c == "'" then
      quote = c
      buf[#buf + 1] = c
    elseif c == "[" or c == "{" then
      depth = depth + 1
      buf[#buf + 1] = c
    elseif c == "]" or c == "}" then
      depth = depth - 1
      buf[#buf + 1] = c
    elseif c == sep and depth == 0 then
      parts[#parts + 1] = table.concat(buf)
      buf = {}
    else
      buf[#buf + 1] = c
    end
  end
  parts[#parts + 1] = table.concat(buf)
  return parts
end

--- Parse a flow scalar or flow sequence: `Degree` or `[achievements, notes]`.
local function parse_value(str)
  str = trim(str)
  local inner = str:match("^%[(.*)%]$")
  if not inner then return unquote(str) end

  local list = {}
  for _, item in ipairs(split_top(inner, ",")) do
    if trim(item) ~= "" then list[#list + 1] = unquote(item) end
  end
  return list
end

--- Parse a YAML flow mapping: `{what: Degree, why: [achievements, notes]}`.
---
--- Written new: old, per dplyr::rename(): the key is the name the template sees,
--- the value the table's own column. A list maps several columns onto one name.
---
--- A div attribute is a string while a cell option arrives already decoded, so
--- both are accepted and the carriers take the same value shape. The syntax is
--- YAML's own, so a div spells in flow style what a cell option spells as a
--- nested block. JSON parses too, being flow YAML.
local function parse_mapping(str)
  if type(str) ~= "string" then return str end

  local body = trim(str):match("^{(.*)}$")
  if not body then
    quarto.log.warning(
      "vitae: could not parse fields '" .. str ..
      "'; expected a mapping such as {what: degree, with: institution}" ..
      (str:find("=") and " (pairs are written `new: old`, not `new=old`)" or ""))
    return nil
  end

  local mapping = {}
  for _, item in ipairs(split_top(body, ",")) do
    if trim(item) ~= "" then
      local parts = split_top(item, ":")
      local new = trim(parts[1])
      table.remove(parts, 1)
      local old = table.concat(parts, ":")
      if new ~= "" and trim(old) ~= "" then
        mapping[unquote(new)] = parse_value(old)
      else
        quarto.log.warning(
          "vitae: could not parse field mapping '" .. trim(item) ..
          "'; expected new: old")
      end
    end
  end
  return mapping
end

--- Collect `quarto-private-N` envelopes from an Attr into {key = value}.
--- Jupyter uses these for map-valued cell options.
local function unwrap_private(attr)
  local found = {}
  for key, value in pairs(attr.attributes) do
    if key:match("^quarto%-private%-%d+$") then
      local ok, envelope = pcall(quarto.json.decode, value)
      if ok and type(envelope) == "table" and envelope.key then
        found[envelope.key] = envelope.value
      end
    end
  end
  return found
end

--- Read the vitae configuration carried by an element's Attr.
---
--- Recognises, in increasing precedence:
---   * the `entries` class (bare selection, no configuration)
---   * flat `vitae-<field>` attributes
---   * a structured `vitae` attribute (knitr) or private envelope (jupyter)
---
--- Returns nil when the element carries no vitae configuration at all, so
--- callers can cheaply skip unrelated divs.
--- @param attr pandoc.Attr
--- @return table|nil config
function M.read(attr)
  local private = unwrap_private(attr)
  local config = {}
  local found = false

  -- On an `.entries` div, configuration is written as bare attributes
  -- (`::: {.entries style="brief"}`), since fenced divs cannot nest YAML.
  local is_entries_div = attr.classes:includes("entries")
  if is_entries_div then
    found = true
    for key, value in pairs(attr.attributes) do
      if BARE_KEYS[key] then
        config[key] = value
      elseif not key:match("^vitae") and not key:match("^quarto%-private%-%d+$") then
        quarto.log.warning(
          "vitae: ignoring unknown attribute '" .. key .. "' on .entries div")
      end
    end
  end

  -- Structured `vitae:` option, from either engine.
  local structured = private["vitae"] or attr.attributes["vitae"]
  if structured ~= nil then
    found = true
    structured = decode_value(structured)
    if type(structured) == "table" then
      for k, v in pairs(structured) do config[k] = v end
    else
      -- `#| vitae: detailed` is shorthand for the style.
      config.style = structured
    end
  end

  -- Flat `vitae-<field>` attributes take precedence over the structured block,
  -- being the more specific spelling.
  for key, value in pairs(attr.attributes) do
    local field = key:match("^vitae%-(.+)$")
    if field then
      found = true
      config[field] = decode_value(value)
    end
  end
  for key, value in pairs(private) do
    local field = key:match("^vitae%-(.+)$")
    if field then
      found = true
      config[field] = value
    end
  end

  if not found then return nil end
  config.fields = parse_mapping(config.fields)
  return config
end

--- Find the tables carried by a container, at any depth.
---
--- Depth varies by engine and output mode: `.cell-output-display` for knitr's
--- `kable()`, a direct child under jupyter's `output: asis`,
--- `.cell-output-markdown` for a jupyter display object. Searching all
--- descendants covers them without special-casing any.
--- @param blocks pandoc.Blocks
--- @return table tables
function M.find_tables(blocks)
  local tables = {}
  pandoc.walk_block(pandoc.Div(blocks), {
    Table = function(tbl) tables[#tables + 1] = tbl end
  })
  return tables
end

--- Fence classes that declare a payload format, normalised to the names
--- `bibliography.lua` understands. Chosen to be what an author writes for
--- syntax highlighting anyway.
local PAYLOAD_FORMATS = {
  bibtex = "bibtex", biblatex = "bibtex",
  json = "csljson", yaml = "cslyaml",
}

--- Find the payloads carried by a container, at any depth: fenced blocks in a
--- div body, or printed cell output.
---
--- The engines label printed output differently: knitr tags stdout
--- `.cell-output-stdout`, while a jupyter result is an unclassed CodeBlock. So
--- anything that is not the echoed *source* counts as a payload.
---
--- A fence class naming a known format declares it; `format` is nil otherwise,
--- and the caller sniffs.
--- @param blocks pandoc.Blocks
--- @return table payloads list of { text, format }
function M.find_payloads(blocks)
  local payloads = {}
  pandoc.walk_block(pandoc.Div(blocks), {
    CodeBlock = function(cb)
      if not cb.classes:includes("cell-code") then
        local format = nil
        for _, class in ipairs(cb.classes) do
          if PAYLOAD_FORMATS[class] then
            format = PAYLOAD_FORMATS[class]
            break
          end
        end
        payloads[#payloads + 1] = { text = cb.text, format = format }
      end
    end
  })
  return payloads
end

--- Find the text of a container's printed output, at any depth. Used by the
--- `input:` path, which brings its own reader and so ignores fence classes.
--- @param blocks pandoc.Blocks
--- @return table texts
function M.find_outputs(blocks)
  local texts = {}
  for _, payload in ipairs(M.find_payloads(blocks)) do
    texts[#texts + 1] = payload.text
  end
  return texts
end

return M
