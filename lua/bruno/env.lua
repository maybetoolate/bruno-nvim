--- Environments, variable scopes and `{{placeholder}}` interpolation.
local M = {}

local yaml = require("bruno.yaml")
local bru = require("bruno.bru")
local state = require("bruno.state")
local config = require("bruno.config")

local uv = vim.uv or vim.loop

local seed = false
local function random_seed()
  if not seed then
    math.randomseed(tonumber(tostring(os.time()):reverse():sub(1, 6)) + math.floor(uv.hrtime() % 100000))
    seed = true
  end
end

local function uuid()
  random_seed()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (
    template:gsub("[xy]", function(c)
      local v = c == "x" and math.random(0, 15) or math.random(8, 11)
      return string.format("%x", v)
    end)
  )
end

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

local function read_file(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local text = fd:read("*a")
  fd:close()
  return text
end

local function normalize_value(value)
  if value == yaml.null then
    return nil
  end
  return value
end

local function var_list_to_map(list)
  local map = {}
  for _, var in ipairs(list or {}) do
    if type(var) == "table" and var.name and var.name ~= "" then
      if not var.disabled then
        map[var.name] = normalize_value(var.value)
      end
    end
  end
  return map
end

--- Parse a dotenv file into a table.
--- @param text string
--- @return table<string, string>
function M.parse_dotenv(text)
  local out = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      trimmed = trimmed:gsub("^export%s+", "")
      local key, value = trimmed:match("^([%w_%.%-]+)%s*=%s*(.*)$")
      if key then
        value = value:gsub("%s+#.*$", "")
        if (value:sub(1, 1) == '"' and value:sub(-1) == '"') or (value:sub(1, 1) == "'" and value:sub(-1) == "'") then
          value = value:sub(2, -2)
        end
        out[key] = value
      end
    end
  end
  return out
end

local function load_env_file(path)
  if path:match("%.bru$") then
    local parsed = bru.parse_environment(read_file(path) or "")
    local name = vim.fs.basename(path):gsub("%.bru$", "")
    local vars = {}
    local secrets = {}
    for _, var in ipairs(parsed.variables or {}) do
      vars[var.name] = normalize_value(var.value)
      if var.value == nil or var.value == "" then
        secrets[var.name] = true
      end
    end
    return { name = name, vars = vars, secrets = secrets, path = path }
  end

  local raw, err = yaml.decode_file(path)
  if not raw then
    return nil, err
  end
  local name = raw.name or vim.fs.basename(path):gsub("%.ya?ml$", "")
  local vars, secrets = {}, {}
  for _, var in ipairs(raw.variables or {}) do
    if type(var) == "table" and var.name and var.name ~= "" then
      if var.secret then
        secrets[var.name] = true
      end
      if var.disabled ~= true and var.enabled ~= false then
        vars[var.name] = normalize_value(var.value)
      end
    end
  end
  return {
    name = name,
    vars = vars,
    secrets = secrets,
    extends = raw.extends,
    dotenv = raw.dotEnvFilePath,
    path = path,
    raw = raw,
  }
end

--- Load all environments for a collection.
--- @param coll table
--- @return table[] list
--- @return table[] warnings
function M.load_environments(coll)
  local dir = vim.fs.joinpath(coll.root, "environments")
  local list, warnings = {}, {}
  if not exists(dir) then
    return list, warnings
  end

  local files = {}
  for name, ftype in vim.fs.dir(dir) do
    if ftype == "file" and (name:match("%.ya?ml$") or name:match("%.bru$")) then
      if name:sub(1, 1) ~= "." then
        files[#files + 1] = vim.fs.joinpath(dir, name)
      end
    end
  end
  table.sort(files)

  for _, path in ipairs(files) do
    local env, err = load_env_file(path)
    if env then
      if env.dotenv then
        local dotenv_path = env.dotenv
        if dotenv_path:sub(1, 1) ~= "/" then
          dotenv_path = vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(path), dotenv_path))
        end
        local text = read_file(dotenv_path)
        if text then
          env.dotenv_vars = M.parse_dotenv(text)
        else
          warnings[#warnings + 1] = ("%s: cannot read dotEnvFilePath %s"):format(env.name, dotenv_path)
        end
      end
      list[#list + 1] = env
    else
      warnings[#warnings + 1] = ("%s: %s"):format(path, tostring(err))
    end
  end

  return list, warnings
end

local function find_env(list, name)
  for _, env in ipairs(list) do
    if env.name == name then
      return env
    end
  end
end

--- Resolve `extends` chains into a flat variable map.
--- @param list table[]
--- @param env table
--- @param seen table|nil
--- @return table vars
--- @return table secrets
function M.flatten_environment(list, env, seen)
  seen = seen or {}
  if seen[env.name] then
    return {}, {}
  end
  seen[env.name] = true

  local vars, secrets = {}, {}
  if env.extends then
    local parent = find_env(list, env.extends)
    if parent then
      vars, secrets = M.flatten_environment(list, parent, seen)
    end
  end
  for key, value in pairs(env.vars or {}) do
    vars[key] = value
  end
  for key, value in pairs(env.dotenv_vars or {}) do
    vars[key] = value
  end
  for key in pairs(env.secrets or {}) do
    secrets[key] = true
  end
  return vars, secrets
end

--- Name of the environment to use.
--- @param coll table
--- @param override string|nil
--- @return string|nil name
function M.active_name(coll, override)
  local names = {}
  local list = M.load_environments(coll)
  for _, env in ipairs(list) do
    names[env.name] = true
  end

  if override and override ~= "" then
    return override
  end
  local persisted = state.collection(coll.root).env
  if persisted and names[persisted] then
    return persisted
  end
  local configured = config.get().env
  if configured and names[configured] then
    return configured
  end
  if coll.default_env and names[coll.default_env] then
    return coll.default_env
  end
  for _, candidate in ipairs({ "local", "development", "dev" }) do
    for _, env in ipairs(list) do
      if env.name:lower() == candidate then
        return env.name
      end
    end
  end
  return list[1] and list[1].name or nil
end

--- Get the active environment and its flattened variables.
--- @param coll table
--- @param override string|nil
--- @return string|nil name
--- @return table vars
--- @return table secrets
function M.active(coll, override)
  local list = M.load_environments(coll)
  local name = M.active_name(coll, override)
  local env = name and find_env(list, name)
  if not env then
    return name, {}, {}
  end
  local vars, secrets = M.flatten_environment(list, env)
  return name, vars, secrets
end

--- Generate a Bruno dynamic variable (`{{$guid}}`, `{{$timestamp}}`, ...).
--- @param name string
--- @param arg string|nil
--- @return string|nil
function M.dynamic(name, arg)
  if name == "$guid" or name == "$randomUUID" or name == "$uuid" then
    return uuid()
  elseif name == "$timestamp" then
    return tostring(os.time())
  elseif name == "$isoTimestamp" then
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
  elseif name == "$localTimestamp" then
    return os.date("%Y-%m-%dT%H:%M:%S")
  elseif name == "$randomInt" then
    random_seed()
    local min = tonumber(arg) or 0
    return tostring(math.random(min, 1000))
  elseif name == "$randomBoolean" then
    random_seed()
    return tostring(math.random(0, 1) == 1)
  elseif name == "$randomIP" then
    random_seed()
    return ("%d.%d.%d.%d"):format(math.random(1, 223), math.random(0, 255), math.random(0, 255), math.random(1, 254))
  elseif name == "$randomEmail" then
    random_seed()
    return ("%s@example.com"):format(("abcdefghijklmnopqrstuvwxyz"):sub(math.random(1, 20), math.random(21, 26)))
  elseif name == "$datetime" then
    local fmt = (arg or "iso8601"):lower()
    if fmt == "rfc3339" or fmt == "iso8601" then
      return os.date("!%Y-%m-%dT%H:%M:%SZ")
    end
    return tostring(os.time())
  end
end

--- Build an interpolation context for a request.
--- @param coll table
--- @param req table
--- @param opts table|nil { env = string, runtime = table }
--- @return table context
function M.context(coll, req, opts)
  opts = opts or {}
  local env_name, env_vars, secrets = M.active(coll, opts.env)
  if opts.env_overrides then
    for key, value in pairs(opts.env_overrides) do
      env_vars[key] = value
    end
  end

  local local_vars = {}
  if config.get().variables.persist then
    local_vars = vim.deepcopy(state.collection(coll.root).vars or {})
  end
  local runtime = vim.tbl_extend("force", local_vars, opts.runtime or {})

  local scopes = {}
  local push = function(name, vars)
    if vars and next(vars) ~= nil then
      scopes[#scopes + 1] = { name = name, vars = vars }
    end
  end

  push("runtime", runtime)
  push("request", var_list_to_map(req.variables))

  -- Folder variables, nearest folder first. Collection-level variables are a
  -- separate, lower-priority scope (below the environment).
  local node = req.node
  local folder = node and (node.type == "request" and node.parent or node) or nil
  while folder do
    if folder.type == "folder" and folder.folder_vars then
      push("folder", var_list_to_map(folder.folder_vars))
    end
    folder = folder.parent
  end

  push("environment", env_vars)
  push("collection", var_list_to_map(coll.defaults and coll.defaults.variables))
  push("process", vim.fn.environ())

  return {
    collection = coll,
    request = req,
    env = env_name,
    env_vars = env_vars,
    secrets = secrets,
    scopes = scopes,
    runtime = runtime,
    warnings = {},
    warned = {},
  }
end

local function stringify(value)
  if value == nil or value == yaml.null then
    return ""
  end
  if type(value) == "table" then
    local ok, encoded = pcall(vim.json.encode, value)
    return ok and encoded or tostring(value)
  end
  if type(value) == "boolean" then
    return value and "true" or "false"
  end
  return tostring(value)
end

function M.warn(ctx, message)
  if ctx.warned[message] then
    return
  end
  ctx.warned[message] = true
  ctx.warnings[#ctx.warnings + 1] = message
end

--- Look up a variable by name across all scopes (highest priority first).
--- @param ctx table
--- @param name string
--- @return any value, boolean found
function M.lookup(ctx, name)
  if name:sub(1, 12) == "process.env." then
    local key = name:sub(13)
    local value = vim.env[key]
    if value ~= nil then
      return value, true
    end
  end

  local bracket = name:match("^(.-)%[(.-)%]$")
  if bracket then
    local value, found = M.lookup(ctx, bracket)
    if found and type(value) == "table" then
      local key = bracket and name:match("%[(.-)%]$")
      local inner = value[key]
      if inner ~= nil then
        return inner, true
      end
    end
  end

  for _, scope in ipairs(ctx.scopes) do
    local value = scope.vars[name]
    if value ~= nil then
      return value, true
    end
  end
  return nil, false
end

--- Replace `{{placeholders}}` in a string.
--- @param input string
--- @param ctx table
--- @param depth number|nil
--- @return string
function M.interpolate(input, ctx, depth)
  if type(input) ~= "string" or not input:find("{{", 1, true) then
    return input
  end
  depth = depth or 0
  if depth > 10 then
    return input
  end

  local changed = false
  local out = input:gsub("{{%s*([^{}]+)%s*}}", function(expr)
    expr = vim.trim(expr)
    local value
    local dynamic_name, dynamic_arg = expr:match("^(%$[%w_]+)%s+(.+)$")
    if dynamic_name then
      value = M.dynamic(dynamic_name, dynamic_arg)
    elseif expr:sub(1, 1) == "$" then
      value = M.dynamic(expr)
    else
      local found
      value, found = M.lookup(ctx, expr)
      if not found then
        local policy = config.get().variables.missing
        if policy == "empty" then
          value = ""
        elseif policy == "error" then
          M.warn(ctx, ("missing variable {{%s}}"):format(expr))
          ctx.errors = ctx.errors or {}
          ctx.errors[#ctx.errors + 1] = ("missing variable {{%s}}"):format(expr)
          return "{{" .. expr .. "}}"
        else
          M.warn(ctx, ("missing variable {{%s}}"):format(expr))
          return "{{" .. expr .. "}}"
        end
      end
    end

    if value == nil then
      return "{{" .. expr .. "}}"
    end

    local text = stringify(value)
    if type(value) == "string" and text:find("{{", 1, true) then
      text = M.interpolate(text, ctx, depth + 1)
    end
    changed = true
    return text
  end)

  if changed and out:find("{{", 1, true) and depth < 10 then
    return M.interpolate(out, ctx, depth + 1)
  end
  return out
end

--- Interpolate every string in a table.
function M.interpolate_deep(value, ctx, depth)
  depth = depth or 0
  if type(value) == "string" then
    return M.interpolate(value, ctx, depth)
  end
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, val in pairs(value) do
    if type(key) == "string" then
      key = M.interpolate(key, ctx, depth)
    end
    out[key] = M.interpolate_deep(val, ctx, depth + 1)
  end
  return out
end

--- True when the variable is declared secret in the active environment.
function M.is_secret(ctx, name)
  return ctx.secrets[name] == true
end

return M
