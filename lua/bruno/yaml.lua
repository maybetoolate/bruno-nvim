--- Minimal, dependency-free YAML 1.2 reader for Bruno collection files.
---
--- Supports the subset used by Bruno / OpenCollection: block mappings and
--- sequences, quoted and plain scalars, literal/folded block scalars, comments,
--- flow sequences/mappings and document markers. Anchors, aliases, tags and
--- multi-document streams are not supported.
local M = {}

local NULL = vim.NIL

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Strip a trailing `# comment` from a plain scalar. `#` only starts a comment
--- when preceded by whitespace, so URLs and `#fragment` survive.
local function strip_comment(s)
  local i, quote = 1, nil
  while i <= #s do
    local c = s:sub(i, i)
    if quote then
      if c == "\\" and quote == '"' then
        i = i + 1
      elseif c == quote then
        if quote == "'" and s:sub(i + 1, i + 1) == "'" then
          i = i + 1
        else
          quote = nil
        end
      end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == "#" and (i == 1 or s:sub(i - 1, i - 1):match("%s")) then
      return s:sub(1, i - 1)
    end
    i = i + 1
  end
  return s
end

local function scalar(raw)
  local s = trim(raw)
  if s == "" then
    return nil
  end
  local low = s:lower()
  if low == "null" or low == "~" then
    return NULL
  end
  if low == "true" then
    return true
  end
  if low == "false" then
    return false
  end
  if low == "yes" then
    return true
  end
  if low == "no" then
    return false
  end
  if s:match("^[-+]?%d+$") then
    -- Keep zero-padded strings (e.g. 007) as strings.
    if #s > 1 and s:sub(1, 1) == "0" then
      return s
    end
    return tonumber(s)
  end
  if s:match("^[-+]?%d*%.%d+$") or s:match("^[-+]?%d+%.%d*[eE][-+]?%d+$") or s:match("^[-+]?%d+[eE][-+]?%d+$") then
    return tonumber(s)
  end
  return s
end

local function unescape_double(s)
  local out, i = {}, 1
  while i <= #s do
    local c = s:sub(i, i)
    if c ~= "\\" then
      out[#out + 1] = c
      i = i + 1
    else
      local n = s:sub(i + 1, i + 1)
      local map =
        { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", ["0"] = "\0" }
      if n == "u" then
        local hex = s:sub(i + 2, i + 5)
        local code = tonumber(hex, 16)
        out[#out + 1] = code and vim.fn.nr2char(code) or ""
        i = i + 6
      elseif n == "x" then
        local hex = s:sub(i + 2, i + 3)
        local code = tonumber(hex, 16)
        out[#out + 1] = code and string.char(code) or ""
        i = i + 4
      else
        out[#out + 1] = map[n] or n
        i = i + 2
      end
    end
  end
  return table.concat(out)
end

--- Read a quoted scalar starting at `i`. Returns value, next index.
local function read_quoted(s, i)
  local quote = s:sub(i, i)
  i = i + 1
  local out = {}
  while i <= #s do
    local c = s:sub(i, i)
    if quote == "'" then
      if c == "'" then
        if s:sub(i + 1, i + 1) == "'" then
          out[#out + 1] = "'"
          i = i + 2
        else
          return table.concat(out), i + 1
        end
      else
        out[#out + 1] = c
        i = i + 1
      end
    else
      if c == '"' then
        return unescape_double(table.concat(out)), i + 1
      end
      if c == "\\" then
        local start = i
        i = i + 1
        local n = s:sub(i, i)
        if n == "u" then
          i = i + 4
        elseif n == "x" then
          i = i + 2
        end
        out[#out + 1] = s:sub(start, i)
        i = i + 1
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
  end
  return table.concat(out), i
end

--- Parse a flow value (`[...]`, `{...}`) or scalar starting at `i`.
local function parse_flow(s, i)
  local function skip_ws()
    while i <= #s and s:sub(i, i):match("%s") do
      i = i + 1
    end
  end

  local parse_value

  local function parse_key()
    skip_ws()
    local c = s:sub(i, i)
    if c == '"' or c == "'" then
      return read_quoted(s, i)
    end
    local start = i
    while i <= #s and not s:sub(i, i):match("[:},%s]") do
      i = i + 1
    end
    return s:sub(start, i - 1), i
  end

  parse_value = function()
    skip_ws()
    local c = s:sub(i, i)
    if c == "[" then
      i = i + 1
      local arr = {}
      while true do
        skip_ws()
        if s:sub(i, i) == "]" then
          i = i + 1
          break
        end
        if i > #s then
          break
        end
        arr[#arr + 1] = parse_value()
        skip_ws()
        if s:sub(i, i) == "," then
          i = i + 1
        end
      end
      return arr
    elseif c == "{" then
      i = i + 1
      local map = {}
      while true do
        skip_ws()
        if s:sub(i, i) == "}" then
          i = i + 1
          break
        end
        if i > #s then
          break
        end
        local key, next_i = parse_key()
        i = next_i
        skip_ws()
        if s:sub(i, i) == ":" then
          i = i + 1
        end
        map[key] = parse_value()
        skip_ws()
        if s:sub(i, i) == "," then
          i = i + 1
        end
      end
      return map
    elseif c == '"' or c == "'" then
      local value, next_i = read_quoted(s, i)
      i = next_i
      return value
    else
      local start = i
      while i <= #s and not s:sub(i, i):match("[,%]}]") do
        i = i + 1
      end
      return scalar(s:sub(start, i - 1))
    end
  end

  return parse_value(), i
end

local function parse_quoted_value(value)
  local v, _ = read_quoted(value, 1)
  return v
end

local function looks_like_flow(s)
  local c = s:sub(1, 1)
  return c == "[" or c == "{"
end

local function split_key(content)
  local i, quote = 1, nil
  while i <= #content do
    local c = content:sub(i, i)
    if quote then
      if c == "\\" and quote == '"' then
        i = i + 1
      elseif c == quote then
        if quote == "'" and content:sub(i + 1, i + 1) == "'" then
          i = i + 1
        else
          quote = nil
        end
      end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == ":" and (i == #content or content:sub(i + 1, i + 1):match("%s")) then
      local key = trim(content:sub(1, i - 1))
      if key:sub(1, 1) == '"' or key:sub(1, 1) == "'" then
        key = parse_quoted_value(key)
      end
      return key, trim(content:sub(i + 1))
    end
    i = i + 1
  end
  return nil, nil
end

local function tokenize(text)
  local lines = {}
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  if text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  local n = 0
  for raw in text:gmatch("(.-)\n") do
    n = n + 1
    local content = raw:gsub("^%s*", "")
    local indent = #raw - #content
    local blank = content == "" or content:sub(1, 1) == "#"
    lines[n] = { raw = raw, content = content, indent = indent, blank = blank }
  end
  return lines
end

local function decode_impl(text)
  local lines = tokenize(text)
  local pos = 1
  local total = #lines

  local parse_block

  local function next_content()
    while pos <= total and lines[pos].blank do
      pos = pos + 1
    end
    return lines[pos]
  end

  local function read_block_scalar(parent_indent, header)
    local collected = {}
    local base
    while pos <= total do
      local line = lines[pos]
      if line.content == "" then
        collected[#collected + 1] = ""
        pos = pos + 1
      elseif line.indent > parent_indent then
        if not base then
          base = line.indent
        end
        collected[#collected + 1] = line.raw:sub(base + 1)
        pos = pos + 1
      else
        break
      end
    end

    while #collected > 0 and collected[#collected] == "" do
      table.remove(collected)
    end

    local folded = header:sub(1, 1) == ">"
    local chomp = header:match("[+-]") or ""
    local body = {}

    if folded then
      local prev_blank = false
      for _, line in ipairs(collected) do
        if line == "" then
          body[#body + 1] = "\n"
          prev_blank = true
        else
          if #body > 0 and not prev_blank then
            body[#body + 1] = " "
          end
          body[#body + 1] = line
          prev_blank = false
        end
      end
    else
      body = collected
    end

    local out = table.concat(body, folded and "" or "\n")
    if chomp == "-" then
      return out
    end
    return out .. "\n"
  end

  local function parse_value(value, indent)
    value = trim(value)

    if value:match("^[|>][+-]?%d?$") then
      return read_block_scalar(indent, value)
    end

    while value:sub(1, 1) == "#" do
      value = ""
    end
    if value == "" then
      return nil
    end

    local first = value:sub(1, 1)
    if first == '"' or first == "'" then
      return parse_quoted_value(value)
    end
    if looks_like_flow(value) then
      return (parse_flow(value, 1))
    end
    return scalar(strip_comment(value))
  end

  local function parse_mapping(first_content, indent)
    local map = {}

    local function parse_pair(content, at_indent)
      local key, rest = split_key(content)
      if not key then
        error(("invalid mapping entry at line %d: %q"):format(pos, content), 0)
      end
      if rest == "" or rest:sub(1, 1) == "#" then
        local nxt = next_content()
        if nxt and nxt.indent > at_indent then
          map[key] = parse_block(nxt.indent)
        elseif nxt and nxt.indent == at_indent and (nxt.content == "-" or nxt.content:sub(1, 2) == "- ") then
          -- A sequence may be indented at the same level as its key.
          map[key] = parse_block(at_indent)
        else
          map[key] = nil
        end
      else
        map[key] = parse_value(rest, at_indent)
      end
    end

    if first_content then
      parse_pair(first_content, indent)
    end

    while true do
      local line = next_content()
      if not line or line.indent < indent then
        break
      end
      if line.indent > indent then
        error(("unexpected indentation at line %d: %q"):format(pos, line.content), 0)
      end
      if line.content == "-" or line.content:sub(1, 2) == "- " then
        break
      end
      pos = pos + 1
      parse_pair(line.content, indent)
    end

    return map
  end

  local function parse_sequence(indent)
    local arr = {}
    while true do
      local line = next_content()
      if not line or line.indent < indent then
        break
      end
      if line.indent > indent then
        error(("unexpected indentation at line %d: %q"):format(pos, line.content), 0)
      end
      if not (line.content == "-" or line.content:sub(1, 2) == "- ") then
        break
      end
      pos = pos + 1
      local after = line.content:sub(2)
      local spaces = #(after:match("^%s*") or "")
      local rest = after:sub(spaces + 1)
      local item_indent = indent + 1 + spaces

      if rest == "" or rest:sub(1, 1) == "#" then
        local nxt = next_content()
        if nxt and nxt.indent > indent then
          arr[#arr + 1] = parse_block(nxt.indent)
        else
          arr[#arr + 1] = nil
        end
      elseif split_key(rest) then
        arr[#arr + 1] = parse_mapping(rest, item_indent)
      else
        arr[#arr + 1] = parse_value(rest, item_indent)
      end
    end
    return arr
  end

  parse_block = function(indent)
    local line = next_content()
    if not line then
      return nil
    end
    if line.indent < indent then
      return nil
    end
    indent = line.indent
    if line.content == "-" or line.content:sub(1, 2) == "- " then
      return parse_sequence(indent)
    end
    return parse_mapping(nil, indent)
  end

  -- Skip leading document start markers.
  while pos <= total and (lines[pos].content == "---" or lines[pos].content == "...") do
    pos = pos + 1
  end

  local first = next_content()
  if not first then
    return {}
  end

  local result = parse_block(first.indent)

  -- Ignore a trailing document end marker.
  while pos <= total and lines[pos].blank do
    pos = pos + 1
  end
  if pos <= total and lines[pos].content ~= "..." and lines[pos].content ~= "---" then
    error(("unexpected content at line %d: %q"):format(pos, lines[pos].content), 0)
  end

  return result
end

--- Decode a YAML string into a Lua table.
--- @param text string
--- @return table|nil result
--- @return string|nil error
function M.decode(text)
  if type(text) ~= "string" then
    return nil, "expected a string"
  end
  local ok, result = pcall(decode_impl, text)
  if not ok then
    return nil, tostring(result)
  end
  return result
end

--- Decode a YAML file.
--- @param path string
--- @return table|nil result
--- @return string|nil error
function M.decode_file(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil, "cannot open " .. path
  end
  local text = fd:read("*a")
  fd:close()
  return M.decode(text)
end

M.null = NULL

return M
