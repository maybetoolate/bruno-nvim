--- Authentication resolution and application.
local M = {}

local env = require("bruno.env")
local url = require("bruno.url")
local config = require("bruno.config")

local oauth_cache = {}

local function header_index(headers, name)
  for i, header in ipairs(headers or {}) do
    if (header.name or ""):lower() == name:lower() then
      return i
    end
  end
end

local function set_header(spec, name, value)
  if header_index(spec.headers, name) then
    return false
  end
  spec.headers[#spec.headers + 1] = { name = name, value = value }
  return true
end

--- Resolve the effective auth for a request, walking the folder chain.
--- @param req table
--- @return table|string|nil
function M.resolve(req)
  local auth = req.auth
  if auth == nil or auth == "inherit" then
    auth = req.node and req.node.defaults and req.node.defaults.auth or nil
  end
  if auth == "inherit" then
    auth = nil
  end
  return auth
end

local function form_encode(value)
  return vim.uri_encode(value or "", "rfc3986")
end

local function fetch_oauth2(auth, ctx, dry_run)
  local ok_config = config.get()
  if not ok_config.oauth.cache then
    oauth_cache = {}
  end

  local creds = auth.credentials or {}
  local cache_key = table.concat({
    tostring(auth.flow),
    tostring(auth.accessTokenUrl),
    tostring(creds.clientId),
    tostring(auth.scope),
  }, "|")

  local cached = oauth_cache[cache_key]
  if cached and cached.expires_at > os.time() + 30 then
    return cached.token, cached.token_type
  end

  if dry_run then
    env.warn(ctx, "oauth2: access token will be fetched when the request runs")
    return nil
  end

  local token_url = env.interpolate(auth.accessTokenUrl or "", ctx)
  if token_url == "" then
    env.warn(ctx, "oauth2: missing accessTokenUrl")
    return nil
  end

  local args = { ok_config.curl.bin, "-sS", "-X", "POST", "-H", "Accept: application/json" }
  local form = {}

  local function add(key, value)
    if value ~= nil and value ~= "" then
      form[#form + 1] = key .. "=" .. form_encode(value)
    end
  end

  if auth.flow == "client_credentials" then
    add("grant_type", "client_credentials")
    add("scope", env.interpolate(auth.scope or "", ctx))
    if creds.placement == "basic_auth_header" then
      args[#args + 1] = "--user"
      args[#args + 1] = ("%s:%s"):format(
        env.interpolate(creds.clientId or "", ctx),
        env.interpolate(creds.clientSecret or "", ctx)
      )
    else
      add("client_id", env.interpolate(creds.clientId or "", ctx))
      add("client_secret", env.interpolate(creds.clientSecret or "", ctx))
    end
  elseif auth.flow == "resource_owner_password_credentials" then
    local owner = auth.resourceOwner or {}
    add("grant_type", "password")
    add("username", env.interpolate(owner.username or "", ctx))
    add("password", env.interpolate(owner.password or "", ctx))
    add("scope", env.interpolate(auth.scope or "", ctx))
    add("client_id", env.interpolate(creds.clientId or "", ctx))
    add("client_secret", env.interpolate(creds.clientSecret or "", ctx))
  else
    env.warn(
      ctx,
      ("oauth2: flow %q is not supported (use the Bruno app or a bearer token)"):format(tostring(auth.flow))
    )
    return nil
  end

  local extra = auth.additionalParameters and auth.additionalParameters.accessTokenRequest or {}
  for _, param in ipairs(extra) do
    if param.name and param.value then
      local value = env.interpolate(param.value, ctx)
      if param.placement == "header" then
        args[#args + 1] = "-H"
        args[#args + 1] = ("%s: %s"):format(param.name, value)
      elseif param.placement == "query" then
        token_url = url.with_query_param(token_url, param.name, value, true)
      else
        add(param.name, value)
      end
    end
  end

  -- Query parameters are applied above, so the token URL is appended last.
  args[#args + 1] = token_url

  for _, pair in ipairs(form) do
    args[#args + 1] = "--data-urlencode"
    args[#args + 1] = pair
  end

  local result = vim.system(args, { text = true }):wait(20000)
  if result.code ~= 0 then
    env.warn(ctx, ("oauth2: token request failed: %s"):format(vim.trim(result.stderr or "curl error")))
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, result.stdout or "")
  if not ok or type(decoded) ~= "table" or not decoded.access_token then
    env.warn(ctx, "oauth2: token response did not contain access_token")
    return nil
  end

  local token_type = decoded.token_type or "Bearer"
  oauth_cache[cache_key] = {
    token = decoded.access_token,
    token_type = token_type,
    expires_at = os.time() + (tonumber(decoded.expires_in) or 3600),
  }
  return decoded.access_token, token_type
end

--- Apply auth to a prepared request.
---
--- `spec` is mutated: `{ url, headers = { {name, value}, ... }, curl_args = {...} }`.
--- @param auth table|string|nil
--- @param spec table
--- @param ctx table
--- @return boolean applied
--- @param auth table|string|nil
--- @param spec table
--- @param ctx table
--- @param opts table|nil { dry_run = boolean }
--- @return boolean applied
function M.apply(auth, spec, ctx, opts)
  spec.headers = spec.headers or {}
  spec.curl_args = spec.curl_args or {}

  if not auth then
    return false
  end

  local kind = type(auth) == "table" and auth.type or auth
  if kind == nil or kind == "none" then
    return false
  end

  if kind == "bearer" then
    local token = env.interpolate(auth.token or "", ctx)
    if token == "" then
      env.warn(ctx, "bearer auth: token is empty")
      return false
    end
    return set_header(spec, "Authorization", "Bearer " .. token)
  elseif kind == "basic" then
    local username = env.interpolate(auth.username or "", ctx)
    local password = env.interpolate(auth.password or "", ctx)
    local encoded = vim.base64.encode(username .. ":" .. password)
    return set_header(spec, "Authorization", "Basic " .. encoded)
  elseif kind == "apikey" then
    local key = env.interpolate(auth.key or "", ctx)
    local value = env.interpolate(auth.value or "", ctx)
    if key == "" then
      env.warn(ctx, "apikey auth: missing key name")
      return false
    end
    if auth.placement == "query" then
      spec.url = url.with_query_param(spec.url, key, value, true)
      return true
    end
    return set_header(spec, key, value)
  elseif kind == "digest" or kind == "ntlm" then
    local username = env.interpolate(auth.username or "", ctx)
    local password = env.interpolate(auth.password or "", ctx)
    spec.curl_args[#spec.curl_args + 1] = kind == "digest" and "--digest" or "--ntlm"
    spec.curl_args[#spec.curl_args + 1] = "--user"
    spec.curl_args[#spec.curl_args + 1] = username .. ":" .. password
    return true
  elseif kind == "oauth2" then
    local token, token_type = fetch_oauth2(auth, ctx, opts and opts.dry_run)
    if not token then
      return false
    end
    local placement = (auth.tokenConfig and auth.tokenConfig.placement) or { header = "Authorization" }
    local value = (token_type or "Bearer") .. " " .. token
    if placement.query then
      spec.url = url.with_query_param(spec.url, placement.query, token, true)
      return true
    end
    return set_header(spec, placement.header or "Authorization", value)
  elseif kind == "aws-v4" or kind == "wsse" or kind == "oauth1" then
    env.warn(ctx, ("%s auth is not supported yet; add the required headers manually"):format(kind))
    return false
  end

  env.warn(ctx, ("unknown auth type %q"):format(tostring(kind)))
  return false
end

return M
