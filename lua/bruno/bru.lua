--- Reader for Bruno's original `.bru` text format.
---
--- The format is a sequence of named blocks:
---
--- ```bru
--- meta { name: Get user  type: http  seq: 1 }
--- get { url: https://example.com/users/:id  body: none  auth: inherit }
--- headers { content-type: application/json }
--- body:json { {"id": 1} }
--- script:post-response { bru.setVar("id", res.body.id); }
--- ```
---
--- This module normalizes the result into the same shape produced by the
--- OpenCollection YAML reader so the rest of the plugin only deals with one model.
local M = {}

local OPEN_RE = "^([%w_%-%:%.]+)%s*{%s*$"
local CLOSE_RE = "^}%s*$"

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_lines(text)
  local lines = {}
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

--- Split `key: value` at the first colon. Values may contain colons.
local function split_pair(line)
  local key, value = line:match("^%s*([^:]+):%s*(.*)$")
  if not key then
    return nil, nil
  end
  return trim(key), trim(value)
end

--- Parse the simple `key: value` bodies of meta/headers/params/auth blocks.
local function parse_pairs(body, opts)
  opts = opts or {}
  local out = {}
  for _, line in ipairs(split_lines(body)) do
    local t = trim(line)
    if t ~= "" and t:sub(1, 1) ~= "#" then
      local key, value = split_pair(t)
      if key then
        if opts.lower then
          key = key:lower()
        end
        out[key] = value
      end
    end
  end
  return out
end

--- Parse `name: value` rows, where a `~` prefix disables the row.
local function parse_key_value_list(body)
  local out = {}
  for _, line in ipairs(split_lines(body)) do
    local t = trim(line)
    if t ~= "" and t:sub(1, 1) ~= "#" and not t:match("^@") then
      local disabled = false
      if t:sub(1, 1) == "~" then
        disabled = true
        t = trim(t:sub(2))
      end
      local key, value = split_pair(t)
      if key then
        out[#out + 1] = { name = key, value = value, disabled = disabled or nil }
      end
    end
  end
  return out
end

--- Parse an environment file (`vars { ... }`).
--- @param text string
--- @return table|nil
function M.parse_environment(text)
  local vars = {}
  local body = text:match("vars%s*{%s*\n(.-)\n}") or text:match("vars%s*{(.-)}")
  if not body and text:match("^%s*vars%s*{") then
    body = ""
  end
  if not body then
    return { variables = vars }
  end
  local pending_description
  for _, line in ipairs(split_lines(body)) do
    local t = trim(line)
    if t:match("^@description") then
      pending_description = t:match("^@description%s*%(%s*'(.*)'%s*%)")
        or t:match('^@description%s*%(%s*"(.*)"%s*%)')
        or t:match("^@description%s*%(%s*%[%[(.*)%]%]%s*%)")
    elseif t ~= "" and t:sub(1, 1) ~= "#" then
      local key, value = split_pair(t)
      if key then
        vars[#vars + 1] = {
          name = key,
          value = value,
          enabled = true,
          description = pending_description,
        }
        pending_description = nil
      end
    end
  end
  return { variables = vars }
end

--- Parse a `.bru` request file.
--- @param text string
--- @return table raw Normalized request model (info/http/runtime/settings/docs)
function M.parse(text)
  local lines = split_lines(text)
  local blocks = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match(OPEN_RE)
    if name then
      local start = i + 1
      local j = start
      local body = {}
      while j <= #lines and not lines[j]:match(CLOSE_RE) do
        body[#body + 1] = lines[j]
        j = j + 1
      end
      blocks[#blocks + 1] = { name = name, body = table.concat(body, "\n") }
      i = j + 1
    else
      i = i + 1
    end
  end

  local raw = {
    info = { type = "http" },
    http = { headers = {}, params = {}, auth = "inherit" },
    runtime = { scripts = {} },
    settings = {},
  }

  local body_type = "none"
  local vars = {}

  for _, block in ipairs(blocks) do
    local name = block.name
    local body = block.body

    if name == "meta" then
      local meta = parse_pairs(body)
      raw.info.name = meta.name
      raw.info.type = meta.type or "http"
      raw.info.seq = tonumber(meta.seq) or meta.seq
    elseif name == "docs" then
      raw.docs = body:gsub("^%s+", ""):gsub("%s+$", "")
    elseif name == "headers" then
      raw.http.headers = parse_key_value_list(body)
    elseif name == "params:query" or name == "params:path" then
      local kind = name:match(":(%w+)")
      for _, item in ipairs(parse_key_value_list(body)) do
        item.type = kind
        raw.http.params[#raw.http.params + 1] = item
      end
    elseif name == "vars:pre-request" then
      for _, item in ipairs(parse_key_value_list(body)) do
        vars[#vars + 1] = { name = item.name, value = item.value, disabled = item.disabled }
      end
    elseif name:match("^body:") then
      local subtype = name:match("^body:(.+)$")
      if subtype == "graphql" then
        body_type = "graphql"
        raw.http.body = { type = "graphql", query = body }
      elseif subtype == "graphql:vars" then
        raw.http.body = raw.http.body or { type = "graphql" }
        raw.http.body.variables = body
      elseif subtype == "form-urlencoded" or subtype == "multipart-form" then
        body_type = subtype
        local data = {}
        for _, item in ipairs(parse_key_value_list(body)) do
          data[#data + 1] = { name = item.name, value = item.value, type = "text", disabled = item.disabled }
        end
        raw.http.body = { type = subtype, data = data }
      else
        body_type = subtype
        raw.http.body = { type = subtype, data = body }
      end
    elseif name:match("^auth:") then
      local auth_type = name:match("^auth:(.+)$")
      local p = parse_pairs(body)
      if auth_type == "bearer" then
        raw.http.auth = { type = "bearer", token = p.token }
      elseif auth_type == "basic" then
        raw.http.auth = { type = "basic", username = p.username, password = p.password }
      elseif auth_type == "apikey" then
        raw.http.auth = { type = "apikey", key = p.key, value = p.value, placement = p.placement or "header" }
      elseif auth_type == "digest" then
        raw.http.auth = { type = "digest", username = p.username, password = p.password }
      elseif auth_type == "ntlm" then
        raw.http.auth = { type = "ntlm", username = p.username, password = p.password }
      elseif auth_type == "oauth2" then
        raw.http.auth = { type = "oauth2", raw = p }
      else
        raw.http.auth = { type = auth_type }
      end
    elseif name:match("^script:") then
      local phase = name:match("^script:(.+)$")
      phase = phase == "pre-request" and "before-request" or phase
      raw.runtime.scripts[#raw.runtime.scripts + 1] = { type = phase, code = body:gsub("^\n", "") }
    elseif name == "tests" then
      raw.runtime.scripts[#raw.runtime.scripts + 1] = { type = "tests", code = body:gsub("^\n", "") }
    elseif name == "settings" then
      for key, value in pairs(parse_pairs(body)) do
        if value == "true" then
          raw.settings[key] = true
        elseif value == "false" then
          raw.settings[key] = false
        elseif tonumber(value) then
          raw.settings[key] = tonumber(value)
        else
          raw.settings[key] = value
        end
      end
    elseif
      name:match("^get$")
      or name:match("^post$")
      or name:match("^put$")
      or name:match("^delete$")
      or name:match("^patch$")
      or name:match("^head$")
      or name:match("^options$")
    then
      local p = parse_pairs(body)
      raw.http.method = name:upper()
      raw.http.url = p.url
      if p.body and p.body ~= "none" then
        body_type = p.body
      end
      if p.auth and p.auth ~= "inherit" then
        raw.http.auth = { type = p.auth }
      end
    end
  end

  if not raw.http.method then
    -- Derive the method from the block name, defaulting to GET.
    raw.http.method = "GET"
  end
  if body_type == "none" then
    raw.http.body = nil
  elseif body_type == "json" and raw.http.body then
    raw.http.body.type = "json"
  elseif body_type == "text" and raw.http.body then
    raw.http.body.type = "text"
  elseif body_type == "xml" and raw.http.body then
    raw.http.body.type = "xml"
  end

  if #vars > 0 then
    raw.variables = vars
  end

  return raw
end

--- Parse a `.bru` file from disk.
--- @param path string
--- @return table|nil
function M.parse_file(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil, "cannot open " .. path
  end
  local text = fd:read("*a")
  fd:close()
  return M.parse(text)
end

return M
