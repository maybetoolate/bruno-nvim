--- URL building: path parameters, query parameters and percent-encoding.
local M = {}

local env = require("bruno.env")

local function encode(value, enabled)
  if enabled == false then
    return value
  end
  -- encodeURIComponent-style escaping: characters such as `,` and `/` are
  -- encoded even though RFC 3986 permits them inside a query string.
  return (tostring(value):gsub("([^%w%-%._~])", function(char)
    return ("%%%02X"):format(string.byte(char))
  end))
end

local function escape_pattern(text)
  return (text:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

--- Replace `:name` and `{name}` path parameters.
local function apply_path_params(url, params, ctx, encode_enabled)
  for _, param in ipairs(params or {}) do
    if param.type == "path" and not param.disabled and param.name ~= "" then
      local value = encode(env.interpolate(param.value or "", ctx), encode_enabled)
      local name = escape_pattern(param.name)
      url = url:gsub(":" .. name .. "%f[%W]", value)
      url = url:gsub("{" .. name .. "}", value)
    end
  end
  return url
end

--- Build the final request URL.
--- @param req table normalized request
--- @param ctx table interpolation context
--- @param opts table|nil { include_disabled = boolean }
--- @return string url
--- @return table warnings
function M.build(req, ctx, opts)
  opts = opts or {}
  local settings = req.settings or {}
  local encode_enabled = settings.encodeUrl ~= false

  local url = env.interpolate(req.url or "", ctx)
  if url == "" then
    return url, ctx.warnings
  end

  local params = req.params or {}
  url = apply_path_params(url, params, ctx, encode_enabled)

  local query = {}
  for _, param in ipairs(params) do
    if param.type ~= "path" and param.name ~= "" and (not param.disabled or opts.include_disabled) then
      local name = encode(env.interpolate(param.name, ctx), encode_enabled)
      local value = encode(env.interpolate(param.value or "", ctx), encode_enabled)
      query[#query + 1] = name .. "=" .. value
    end
  end

  if #query > 0 then
    local separator = "?"
    if url:find("?", 1, true) then
      separator = "&"
    end
    if url:sub(-1) == "?" or url:sub(-1) == "&" then
      separator = ""
    end
    url = url .. separator .. table.concat(query, "&")
  end

  return url, ctx.warnings
end

--- Append a query parameter to a URL (used by API-key auth).
--- @param url string
--- @param name string
--- @param value string
--- @param encode_enabled boolean|nil
--- @return string
function M.with_query_param(url, name, value, encode_enabled)
  local separator = url:find("?", 1, true) and "&" or "?"
  if url:sub(-1) == "?" or url:sub(-1) == "&" then
    separator = ""
  end
  return url .. separator .. encode(name, encode_enabled) .. "=" .. encode(value, encode_enabled)
end

return M
