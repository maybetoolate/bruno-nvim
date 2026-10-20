--- Normalize Bruno/OpenCollection request files into one internal model.
local M = {}

local function as_list(value, key_name)
  if value == nil then
    return {}
  end
  if type(value) == "table" and vim.islist(value) then
    return value
  end
  if type(value) == "table" then
    local out = {}
    for key, val in pairs(value) do
      out[#out + 1] = { name = key_name == "value" and nil or key, value = val }
    end
    table.sort(out, function(a, b)
      return (a.name or "") < (b.name or "")
    end)
    return out
  end
  return {}
end

local function normalize_headers(headers)
  local out = {}
  for _, header in ipairs(as_list(headers)) do
    if type(header) == "table" and header.name then
      out[#out + 1] = {
        name = tostring(header.name),
        value = header.value ~= nil and tostring(header.value) or "",
        disabled = header.disabled or nil,
        description = header.description,
      }
    end
  end
  return out
end

local function normalize_params(params)
  local out = {}
  for _, param in ipairs(as_list(params)) do
    if type(param) == "table" and param.name then
      out[#out + 1] = {
        name = tostring(param.name),
        value = param.value ~= nil and tostring(param.value) or "",
        type = param.type or "query",
        disabled = param.disabled or nil,
      }
    end
  end
  return out
end

local function normalize_variables(vars)
  local out = {}
  if type(vars) ~= "table" then
    return out
  end
  if not vim.islist(vars) then
    for name, value in pairs(vars) do
      out[#out + 1] = { name = name, value = value }
    end
  else
    for _, var in ipairs(vars) do
      if type(var) == "table" and var.name then
        out[#out + 1] = {
          name = tostring(var.name),
          value = var.value,
          disabled = var.disabled,
          description = var.description,
        }
      end
    end
  end
  return out
end

local function normalize_scripts(runtime, scripts)
  local source = scripts or (runtime and runtime.scripts) or {}
  local out = {}
  for _, script in ipairs(source) do
    if type(script) == "table" and script.code then
      local kind = script.type or "after-response"
      if kind == "pre-request" then
        kind = "before-request"
      end
      out[#out + 1] = { type = kind, code = script.code }
    end
  end
  return out
end

local function normalize_settings(settings)
  if type(settings) ~= "table" then
    return {}
  end
  -- Some collections nest HTTP settings under `settings.http`.
  if settings.http then
    return vim.tbl_deep_extend("force", settings, settings.http)
  end
  return settings
end

local function pick_body(body, info_type)
  if body == nil then
    return nil
  end

  if vim.islist(body) then
    local chosen
    for _, variant in ipairs(body) do
      if type(variant) == "table" and variant.selected then
        chosen = variant
        break
      end
    end
    chosen = chosen or body[1]
    body = chosen and (chosen.body or chosen) or nil
  end

  if type(body) ~= "table" then
    return { type = "text", data = tostring(body) }
  end

  if body.type then
    return body
  end
  if body.query then
    return { type = "graphql", query = body.query, variables = body.variables }
  end
  if body.data ~= nil then
    return { type = info_type == "graphql" and "graphql" or "text", data = body.data }
  end
  return body
end

--- @param defaults table|nil
--- @return table
function M.normalize_defaults(defaults)
  defaults = defaults or {}
  local out = {
    headers = normalize_headers(defaults.headers),
    variables = normalize_variables(defaults.variables),
    scripts = normalize_scripts(nil, defaults.scripts),
    auth = defaults.auth,
    settings = normalize_settings(defaults.settings),
  }
  return out
end

--- Merge two header lists; the later list wins for duplicate names.
--- @param base table[]
--- @param override table[]
--- @return table[]
function M.merge_headers(base, override)
  local out = vim.deepcopy(base or {})
  local index = {}
  for i, header in ipairs(out) do
    index[(header.name or ""):lower()] = i
  end
  for _, header in ipairs(override or {}) do
    local key = (header.name or ""):lower()
    if index[key] then
      out[index[key]] = vim.deepcopy(header)
    else
      out[#out + 1] = vim.deepcopy(header)
      index[key] = #out
    end
  end
  return out
end

--- Normalize a parsed request file.
--- @param raw table parsed YAML or .bru model
--- @param node table|nil collection node (provides defaults/path)
--- @return table request
function M.normalize(raw, node)
  local info = raw.info or {}
  local http = raw.http or raw.graphql or {}
  local defaults = (node and node.defaults) or {}
  local type_ = info.type or "http"
  local method = http.method or (type_ == "graphql" and "POST") or "GET"

  local body = pick_body(http.body, type_)

  if type_ == "graphql" and not body then
    local gql = raw.graphql or {}
    body = { type = "graphql", query = gql.query, variables = gql.variables }
  end

  local req = {
    name = info.name or (node and vim.fs.basename(node.path)) or "request",
    type = type_,
    seq = info.seq,
    method = tostring(method):upper(),
    url = http.url or "",
    headers = M.merge_headers(defaults.headers, normalize_headers(http.headers)),
    params = normalize_params(http.params),
    body = body,
    auth = http.auth ~= nil and http.auth or defaults.auth,
    scripts = vim.list_extend(vim.deepcopy(defaults.scripts or {}), normalize_scripts(raw.runtime, raw.scripts)),
    settings = vim.tbl_deep_extend("force", defaults.settings or {}, normalize_settings(raw.settings)),
    variables = normalize_variables(raw.variables),
    docs = raw.docs,
    path = node and node.path,
    root = node and node.collection and node.collection.root,
    node = node,
    raw = raw,
  }

  return req
end

--- Build the GraphQL JSON payload for a normalized request body.
--- @param body table
--- @return string|nil
function M.graphql_payload(body)
  if not body or not body.query then
    return nil
  end
  local variables = body.variables
  if type(variables) == "string" then
    if variables ~= "" then
      local ok, decoded = pcall(vim.json.decode, variables)
      variables = ok and decoded or variables
    else
      variables = nil
    end
  end
  local payload = { query = body.query }
  if variables ~= nil then
    payload.variables = variables
  end
  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok then
    return nil
  end
  return encoded
end

return M
