--- Runs Bruno's JavaScript request scripts in a node subprocess.
local M = {}

local config = require("bruno.config")

local uv = vim.uv or vim.loop

local function runner_path()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.joinpath(vim.fs.dirname(source), "runtime", "runner.js")
end

local function read_file(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local data = fd:read("*a")
  fd:close()
  return data
end

local function unlink(path)
  pcall(uv.fs_unlink, path)
end

--- Whether node and the runner are available.
--- @return boolean
function M.available()
  local conf = config.get().scripts
  return conf.enabled ~= false and vim.fn.executable(conf.node) == 1 and uv.fs_stat(runner_path()) ~= nil
end

--- Execute a set of scripts.
--- @param scripts table[] list of { type, code, name }
--- @param payload table { vars, env_vars, collection_vars, request, response, secrets }
--- @param opts table|nil { cwd = string }
--- @return table result { ok, error, vars, env_vars, collection_vars, request, tests, logs, next_request }
function M.run(scripts, payload, opts)
  opts = opts or {}
  local conf = config.get().scripts

  if #scripts == 0 then
    return {
      ok = true,
      vars = payload.vars or {},
      env_vars = payload.env_vars or {},
      collection_vars = payload.collection_vars or {},
      request = payload.request or {},
      tests = {},
      logs = {},
    }
  end

  if not M.available() then
    return { ok = false, error = "node is not available or scripts are disabled", tests = {}, logs = {} }
  end

  local context = {
    scripts = scripts,
    vars = payload.vars or {},
    envVars = payload.env_vars or {},
    collectionVars = payload.collection_vars or {},
    request = payload.request or {},
    response = payload.response,
    secrets = payload.secrets or {},
  }

  local function as_object(value)
    if type(value) ~= "table" or next(value) == nil then
      return vim.empty_dict()
    end
    return value
  end
  context.vars = as_object(context.vars)
  context.envVars = as_object(context.envVars)
  context.collectionVars = as_object(context.collectionVars)
  if type(context.request) == "table" then
    context.request.headers = as_object(context.request.headers)
  end
  if type(context.response) == "table" then
    context.response.headers = as_object(context.response.headers)
  end

  local base = vim.fn.tempname()
  local context_file = base .. ".json"
  local result_file = base .. ".result.json"

  local fd = io.open(context_file, "wb")
  if not fd then
    return { ok = false, error = "cannot write script context" }
  end
  fd:write(vim.json.encode(context))
  fd:close()

  local proc = vim.system({
    conf.node,
    runner_path(),
    context_file,
    result_file,
  }, {
    text = true,
    cwd = opts.cwd or vim.fn.getcwd(),
  })
  local result = proc:wait(conf.timeout or 10000)
  if result.code == nil then
    -- Timed out: stop the node process so it does not outlive the request.
    pcall(function()
      proc:kill("sigkill")
    end)
  end

  local output = read_file(result_file)
  unlink(context_file)
  unlink(result_file)

  if not output then
    return {
      ok = false,
      error = vim.trim(result.stderr or "") ~= "" and vim.trim(result.stderr) or "script runner produced no result",
      tests = {},
      logs = {},
    }
  end

  local ok, decoded = pcall(vim.json.decode, output)
  if not ok or type(decoded) ~= "table" then
    return { ok = false, error = "invalid script runner output", tests = {}, logs = {} }
  end

  return {
    ok = decoded.ok ~= false,
    error = decoded.error ~= vim.NIL and decoded.error or nil,
    vars = decoded.vars or {},
    env_vars = decoded.envVars or {},
    collection_vars = decoded.collectionVars or {},
    request = decoded.request,
    tests = decoded.tests or {},
    logs = decoded.logs or {},
    next_request = decoded.nextRequest ~= vim.NIL and decoded.nextRequest or nil,
  }
end

--- Filter scripts by lifecycle phase.
--- @param scripts table[]
--- @param phase string
--- @return table[]
function M.filter(scripts, phase)
  local out = {}
  for _, script in ipairs(scripts or {}) do
    if script.type == phase then
      out[#out + 1] = script
    end
  end
  if phase == "after-response" then
    for _, script in ipairs(scripts or {}) do
      if script.type == "tests" then
        out[#out + 1] = script
      end
    end
  end
  return out
end

return M
