--- Request orchestration: scripts -> interpolation -> auth -> curl -> tests/history.
local M = {}

local collection = require("bruno.collection")
local config = require("bruno.config")
local env = require("bruno.env")
local auth = require("bruno.auth")
local http = require("bruno.http")
local bru = require("bruno.bru")
local request = require("bruno.request")
local scripts = require("bruno.scripts")
local state = require("bruno.state")
local url = require("bruno.url")
local yaml = require("bruno.yaml")

local uv = vim.uv or vim.loop

local runtime_vars = {}
local env_overrides = {}
local active_jobs = {}
local last_responses = {}

local function normalize_path(path)
  return vim.fs.normalize(path or "")
end

local function notify(message, level)
  vim.notify("bruno: " .. message, level or vim.log.levels.INFO)
end

--- Session-scoped variables (`bru.setVar` and `:BrunoVar`).
function M.runtime(root)
  root = normalize_path(root)
  runtime_vars[root] = runtime_vars[root] or {}
  return runtime_vars[root]
end

function M.env_overrides(root)
  root = normalize_path(root)
  env_overrides[root] = env_overrides[root] or {}
  return env_overrides[root]
end

--- Set a variable.
--- @param root string
--- @param name string
--- @param value any
--- @param opts table|nil { persist = boolean }
function M.set_var(root, name, value, opts)
  opts = opts or {}
  if opts.persist and config.get().variables.persist then
    local entry = state.collection(root)
    entry.vars[name] = value
    state.save()
  else
    M.runtime(root)[name] = value
  end
end

function M.unset_var(root, name, opts)
  opts = opts or {}
  if opts.persist and config.get().variables.persist then
    local entry = state.collection(root)
    entry.vars[name] = nil
    state.save()
  end
  M.runtime(root)[name] = nil
end

function M.reset_runtime(root)
  runtime_vars[normalize_path(root)] = {}
  env_overrides[normalize_path(root)] = {}
end

function M.last_response(path)
  return last_responses[normalize_path(path)]
end

--- Resolve the collection/request to operate on.
--- @param opts table|nil
--- @return table|nil collection
--- @return table|nil node
--- @return table|nil req
--- @return string|nil error
function M.target(opts)
  opts = opts or {}

  local coll
  if opts.node then
    coll = opts.node.collection or collection.get({ path = opts.node.path or opts.path })
    if not coll then
      return nil, nil, nil, "collection not found"
    end
    local node = coll.requests and coll.requests[normalize_path(opts.node.path)] or opts.node
    return coll, node, node and node.request, nil
  end

  local bufnr = opts.buffer or vim.api.nvim_get_current_buf()
  local path = opts.path
  if not path or path == "" then
    path = vim.api.nvim_buf_get_name(bufnr)
  end
  if path ~= "" then
    path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  end

  coll = collection.get({ path = path, buffer = bufnr })
  if not coll then
    return nil, nil, nil, ("no Bruno collection for %s"):format(path ~= "" and path or "current directory")
  end

  local node = path ~= "" and coll.requests and coll.requests[normalize_path(path)] or nil

  -- Prefer unsaved buffer contents when the file is open and modified.
  if path ~= "" and vim.api.nvim_buf_is_valid(bufnr) then
    local modified = vim.bo[bufnr].modified
    if modified then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local text = table.concat(lines, "\n")
      local raw, err
      if path:match("%.bru$") then
        raw = bru.parse(text)
      else
        raw, err = yaml.decode(text)
      end
      if raw then
        local fake = node
          or {
            path = path,
            defaults = coll.defaults,
            collection = coll,
          }
        local req = request.normalize(raw, fake)
        req.root = coll.root
        return coll, fake, req, nil
      end
      notify("cannot parse the current buffer: " .. tostring(err), vim.log.levels.ERROR)
    end
  end

  if node and node.request then
    return coll, node, node.request, nil
  end

  if path == "" then
    return nil, nil, nil, "no request in the current buffer"
  end

  -- A file inside the collection that is not a request (folder.yml, docs, ...).
  return coll, nil, nil, ("not a Bruno request: %s"):format(path)
end

local function headers_map(headers)
  local map = {}
  for _, header in ipairs(headers or {}) do
    if header.name and header.name ~= "" and not header.disabled then
      map[header.name] = header.value
    end
  end
  return map
end

local function body_text(body)
  if not body then
    return nil
  end
  local prepared = http.prepare_body(body)
  if not prepared then
    return nil
  end
  if prepared.kind == "raw" then
    return prepared.data
  elseif prepared.kind == "form" then
    local parts = {}
    for _, field in ipairs(prepared.fields) do
      parts[#parts + 1] = field.name .. "=" .. field.value
    end
    return table.concat(parts, "&")
  end
  return nil
end

local function apply_script_request(eff, mutated)
  if type(mutated) ~= "table" then
    return
  end
  if mutated.url and mutated.url ~= "" then
    eff.url = mutated.url
  end
  if mutated.method and mutated.method ~= "" then
    eff.method = tostring(mutated.method):upper()
  end
  if type(mutated.headers) == "table" then
    local headers = {}
    for name, value in pairs(mutated.headers) do
      headers[#headers + 1] = { name = name, value = value }
    end
    table.sort(headers, function(a, b)
      return a.name < b.name
    end)
    eff.headers = headers
  end
  if mutated.body ~= nil then
    local body = mutated.body
    if type(body) == "table" then
      local ok, encoded = pcall(vim.json.encode, body)
      body = ok and encoded or nil
    end
    if body ~= nil then
      eff.body = {
        type = (eff.body and eff.body.type) or "json",
        data = tostring(body),
      }
    end
  end
end

--- Resolve variables, run pre-request scripts and build the curl spec.
--- Does not send anything.
--- @param req table
--- @param opts table|nil { env, dry_run, buffer }
--- @return table|nil prepared { spec, ctx, req, coll }
--- @return string|nil error
function M.prepare(req, opts)
  opts = opts or {}
  if not req then
    return nil, "no request"
  end

  local coll = req.node and req.node.collection or collection.get({ path = req.root or req.path })
  if not coll then
    return nil, "collection not found for " .. tostring(req.path or req.url)
  end

  local ctx = env.context(coll, req, {
    env = opts.env,
    runtime = M.runtime(coll.root),
    env_overrides = M.env_overrides(coll.root),
  })

  local eff = {
    name = req.name,
    type = req.type,
    method = req.method,
    url = req.url,
    headers = vim.deepcopy(req.headers or {}),
    params = vim.deepcopy(req.params or {}),
    body = vim.deepcopy(req.body),
    auth = req.auth,
    scripts = req.scripts,
    settings = vim.deepcopy(req.settings or {}),
    variables = req.variables,
    path = req.path,
    root = coll.root,
    node = req.node,
    docs = req.docs,
  }

  local pre = scripts.filter(eff.scripts, "before-request")
  if #pre > 0 and not opts.dry_run and scripts.available() then
    local result = scripts.run(pre, {
      vars = vim.deepcopy(ctx.runtime),
      env_vars = vim.deepcopy(ctx.env_vars),
      collection_vars = vim.deepcopy(state.collection(coll.root).vars or {}),
      request = {
        url = eff.url,
        method = eff.method,
        headers = headers_map(eff.headers),
        body = body_text(eff.body),
      },
      secrets = ctx.secrets,
    }, { cwd = coll.root })

    if result.ok then
      for key, value in pairs(result.vars or {}) do
        M.runtime(coll.root)[key] = value
        ctx.runtime[key] = value
      end
      for key, value in pairs(result.env_vars or {}) do
        if value == vim.NIL then
          M.env_overrides(coll.root)[key] = nil
          ctx.env_vars[key] = nil
        else
          M.env_overrides(coll.root)[key] = value
          ctx.env_vars[key] = value
        end
      end
      apply_script_request(eff, result.request)
      ctx.script_logs = result.logs
    else
      env.warn(ctx, "pre-request script failed: " .. tostring(result.error))
    end
  end

  local headers = {}
  local omit = {}
  for _, name in ipairs(eff.settings.omitHeaders or {}) do
    omit[tostring(name):lower()] = true
  end
  for _, header in ipairs(eff.headers) do
    if not header.disabled and header.name and header.name ~= "" and not omit[header.name:lower()] then
      headers[#headers + 1] = {
        name = env.interpolate(header.name, ctx),
        value = env.interpolate(tostring(header.value or ""), ctx),
      }
    end
  end

  local final_url = url.build(eff, ctx)
  local body = eff.body and env.interpolate_deep(eff.body, ctx) or nil

  local timeout = tonumber(eff.settings.timeout)
  local spec = {
    method = eff.method,
    url = final_url,
    headers = headers,
    body = body,
    curl_args = {},
    timeout_ms = timeout and timeout > 0 and timeout or nil,
    follow_redirects = eff.settings.followRedirects ~= false,
    max_redirects = tonumber(eff.settings.maxRedirects) or 5,
    insecure = config.get().curl.insecure,
    settings = eff.settings,
  }

  auth.apply(auth.resolve(eff), spec, ctx, { dry_run = opts.dry_run })

  if spec.url == "" then
    return nil, "request URL is empty"
  end

  return { spec = spec, ctx = ctx, req = eff, coll = coll }
end

local function merge_runtime(coll, result, ctx)
  if not result then
    return
  end
  for key, value in pairs(result.vars or {}) do
    M.runtime(coll.root)[key] = value
    ctx.runtime[key] = value
  end
  for key, value in pairs(result.env_vars or {}) do
    if value == vim.NIL then
      M.env_overrides(coll.root)[key] = nil
      ctx.env_vars[key] = nil
    else
      M.env_overrides(coll.root)[key] = value
      ctx.env_vars[key] = value
    end
  end
end

local function response_scripts(prepared, response)
  local after = scripts.filter(prepared.req.scripts, "after-response")
  if #after == 0 or not scripts.available() then
    return nil
  end

  return scripts.run(after, {
    vars = vim.deepcopy(prepared.ctx.runtime),
    env_vars = vim.deepcopy(prepared.ctx.env_vars),
    collection_vars = vim.deepcopy(state.collection(prepared.coll.root).vars or {}),
    request = {
      url = prepared.spec.url,
      method = prepared.spec.method,
      headers = headers_map(prepared.spec.headers),
      body = body_text(prepared.spec.body),
    },
    response = {
      status = response.status,
      statusText = response.reason,
      headers = response.headers,
      body = response.body,
      contentType = response.content_type,
      responseTime = response.time_ms,
      size = response.size,
      url = response.url,
    },
    secrets = prepared.ctx.secrets,
  }, { cwd = prepared.coll.root })
end

local function finish_response(prepared, response, opts)
  local coll = prepared.coll
  local ctx = prepared.ctx

  local result = response_scripts(prepared, response)
  if result then
    if result.ok then
      merge_runtime(coll, result, ctx)
    else
      env.warn(ctx, "after-response script failed: " .. tostring(result.error))
    end
    response.tests = result.tests or {}
    response.logs = result.logs or {}
    response.script_error = (not result.ok) and result.error or nil
    response.next_request = result.next_request
    response.script_request = result.request
  end

  response.request = prepared.req
  response.spec = prepared.spec
  response.env = ctx.env
  response.warnings = ctx.warnings
  response.timestamp = os.time()
  last_responses[normalize_path(prepared.req.path or prepared.spec.url)] = response

  if config.get().history.enabled then
    state.push_history({
      name = prepared.req.name,
      path = prepared.req.path,
      method = prepared.spec.method,
      url = response.url or prepared.spec.url,
      status = response.status,
      reason = response.reason,
      time_ms = math.floor(response.time_ms or 0),
      size = response.size or #(response.body or ""),
      body = response.body,
      headers = response.headers,
    }, config.get().history)
  end

  if #ctx.warnings > 0 then
    notify(table.concat(ctx.warnings, "; "), vim.log.levels.WARN)
  end

  if response.script_error then
    notify("after-response script failed: " .. tostring(response.script_error), vim.log.levels.ERROR)
  end

  local failed = {}
  for _, test in ipairs(response.tests or {}) do
    if not test.passed then
      failed[#failed + 1] = test.name .. ": " .. tostring(test.error)
    end
  end
  if #failed > 0 then
    notify(("%d test(s) failed: %s"):format(#failed, table.concat(failed, "; ")), vim.log.levels.ERROR)
  elseif #(response.tests or {}) > 0 then
    notify(("%d test(s) passed"):format(#response.tests), vim.log.levels.INFO)
  end

  local level = response.ok and vim.log.levels.INFO or vim.log.levels.ERROR
  notify(
    ("%s %s -> %s (%dms)"):format(
      prepared.spec.method,
      prepared.spec.url,
      response.status,
      math.floor(response.time_ms or 0)
    ),
    level
  )

  if not opts.silent then
    require("bruno.ui.response").show(response, { req = prepared.req, coll = coll })
  end

  if opts.on_done then
    opts.on_done(response)
  end
end

--- Execute a request. Prefer `run_target` when starting from a buffer/tree node.
--- @param req table
--- @param opts table|nil { env, focus, on_start, on_done, dry_run }
--- @return table|nil handle
function M.run(req, opts)
  opts = opts or {}
  local prepared, err = M.prepare(req, opts)
  if not prepared then
    notify(err or "cannot prepare request", vim.log.levels.ERROR)
    return nil
  end

  if opts.dry_run then
    return prepared
  end

  local errors = prepared.ctx.errors
  if errors and #errors > 0 then
    notify(table.concat(errors, "; "), vim.log.levels.ERROR)
    return nil
  end

  local key = normalize_path(req.path or req.url)
  if active_jobs[key] then
    active_jobs[key].cancel()
    active_jobs[key] = nil
  end

  if opts.on_start then
    opts.on_start(prepared)
  end

  local job = http.send(prepared.spec, function(response)
    active_jobs[key] = nil
    finish_response(prepared, response, opts)
  end)

  active_jobs[key] = job
  return { prepared = prepared, cancel = job.cancel, key = key }
end

--- Resolve a target and run it.
--- @param opts table|nil same as `target` plus `run` options
--- @return table|nil handle
function M.run_target(opts)
  opts = opts or {}
  local coll, _, req, err = M.target(opts)
  if not req then
    notify(err or "no request found", vim.log.levels.ERROR)
    return nil
  end
  if not req.root and coll then
    req.root = coll.root
  end
  return M.run(req, opts)
end

function M.cancel(path)
  local key = normalize_path(path)
  if active_jobs[key] then
    active_jobs[key].cancel()
    active_jobs[key] = nil
    notify("request cancelled", vim.log.levels.WARN)
  end
end

function M.cancel_all()
  for key, job in pairs(active_jobs) do
    job.cancel()
    active_jobs[key] = nil
  end
end

--- Render the request exactly as it will be sent (no scripts, no network).
--- @param req table
--- @param opts table|nil
--- @return table|nil prepared
--- @return string|nil error
function M.preview(req, opts)
  return M.prepare(req, vim.tbl_extend("force", opts or {}, { dry_run = true }))
end

--- Copy the request as a curl command.
--- @param req table
--- @param opts table|nil
--- @return string|nil
function M.as_curl(req, opts)
  local prepared, err = M.preview(req, opts)
  if not prepared then
    notify(err or "cannot prepare request", vim.log.levels.ERROR)
    return nil
  end
  return http.to_curl(prepared.spec)
end

--- List resolved variables for display, highest priority first.
--- @param coll table
--- @param req table
--- @param opts table|nil
--- @return table[] rows { name, value, scope, secret }
function M.list_variables(coll, req, opts)
  opts = opts or {}
  local ctx = env.context(coll, req, {
    env = opts.env,
    runtime = M.runtime(coll.root),
    env_overrides = M.env_overrides(coll.root),
  })

  local seen = {}
  local rows = {}
  for _, scope in ipairs(ctx.scopes) do
    if scope.name ~= "process" or opts.include_process then
      local names = vim.tbl_keys(scope.vars)
      table.sort(names)
      for _, name in ipairs(names) do
        if not seen[name] then
          seen[name] = true
          local secret = scope.name == "environment" and ctx.secrets[name]
          rows[#rows + 1] = {
            name = name,
            value = secret and "********" or tostring(scope.vars[name]),
            scope = scope.name,
            secret = secret or false,
          }
        end
      end
    end
  end
  local secret_names = vim.tbl_keys(ctx.secrets or {})
  table.sort(secret_names)
  for _, name in ipairs(secret_names) do
    if not seen[name] then
      seen[name] = true
      rows[#rows + 1] = {
        name = name,
        value = "(not set)",
        scope = "environment",
        secret = true,
      }
    end
  end
  return rows, ctx
end

--- Read a request file from disk and normalize it without a loaded tree.
--- @param path string
--- @return table|nil req
--- @return string|nil error
function M.load_request_file(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local coll, err = collection.get({ path = path })
  if not coll then
    return nil, err
  end
  local node = coll.requests and coll.requests[normalize_path(path)]
  if node and node.request then
    return node.request
  end
  local text
  local fd = io.open(path, "rb")
  if not fd then
    return nil, "cannot open " .. path
  end
  text = fd:read("*a")
  fd:close()
  local raw
  if path:match("%.bru$") then
    raw = bru.parse(text)
  else
    raw, err = yaml.decode(text)
  end
  if not raw then
    return nil, err
  end
  local fake = { path = path, defaults = coll.defaults, collection = coll }
  local req = request.normalize(raw, fake)
  req.root = coll.root
  return req
end

return M
