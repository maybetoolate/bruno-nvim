--- HTTP execution through curl.
local M = {}

local config = require("bruno.config")
local request = require("bruno.request")

local uv = vim.uv or vim.loop

local function write_file(path, data)
  local fd = assert(io.open(path, "wb"))
  fd:write(data)
  fd:close()
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
  if path then
    pcall(uv.fs_unlink, path)
  end
end

--- Parse a curl `--dump-header` file. Redirect chains produce several blocks;
--- the last one describes the final response.
--- @param text string
--- @return table headers lower-cased name -> value
--- @return string raw
--- @return number|nil status
--- @return string|nil reason
function M.parse_headers(text)
  if not text or text == "" then
    return {}, "", nil, nil
  end

  local blocks = {}
  local current = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    if line == "" then
      if #current > 0 then
        blocks[#blocks + 1] = current
        current = {}
      end
    else
      current[#current + 1] = line
    end
  end
  if #current > 0 then
    blocks[#blocks + 1] = current
  end

  local block = blocks[#blocks] or {}
  local headers = {}
  local status, reason
  local last_name

  for _, line in ipairs(block) do
    local code, rest = line:match("^HTTP/%d+%.?%d*%s+(%d+)%s*(.*)$")
    if code then
      status = tonumber(code)
      reason = rest
      last_name = nil
    elseif line:match("^%s") and last_name then
      headers[last_name] = headers[last_name] .. " " .. vim.trim(line)
    else
      local name, value = line:match("^([^:]+):%s*(.*)$")
      if name then
        last_name = name:lower()
        headers[last_name] = value
      end
    end
  end

  return headers, table.concat(block, "\n"), status, reason
end

local function default_content_type(body_type)
  return ({
    json = "application/json",
    xml = "application/xml",
    text = "text/plain",
    graphql = "application/json",
    ["form-urlencoded"] = "application/x-www-form-urlencoded",
  })[body_type]
end

local function has_header(headers, name)
  for _, header in ipairs(headers or {}) do
    if (header.name or ""):lower() == name:lower() then
      return true
    end
  end
end

--- Build the effective body description for a request.
--- @param body table|nil
--- @return table|nil { kind, data, fields }
function M.prepare_body(body)
  if not body or body.type == "none" then
    return nil
  end

  local kind = body.type
  if kind == "json" or kind == "text" or kind == "xml" or kind == "sparql" or kind == "raw" then
    local data = body.data
    if data == nil then
      return nil
    end
    if type(data) == "table" then
      local ok, encoded = pcall(vim.json.encode, data)
      data = ok and encoded or ""
    end
    return { kind = "raw", data = tostring(data), content_type = default_content_type(kind) }
  elseif kind == "graphql" then
    local payload = request.graphql_payload(body)
    if not payload then
      return nil
    end
    return { kind = "raw", data = payload, content_type = "application/json" }
  elseif kind == "form-urlencoded" then
    local fields = {}
    for _, field in ipairs(body.data or {}) do
      if not field.disabled then
        fields[#fields + 1] = { name = field.name or "", value = field.value or "" }
      end
    end
    return { kind = "form", fields = fields, content_type = "application/x-www-form-urlencoded" }
  elseif kind == "multipart-form" then
    local fields = {}
    for _, field in ipairs(body.data or {}) do
      if not field.disabled then
        fields[#fields + 1] = {
          name = field.name or "",
          value = field.value or "",
          type = field.type or "text",
          content_type = field.contentType,
        }
      end
    end
    return { kind = "multipart", fields = fields }
  elseif kind == "file" then
    local paths = body.data
    if type(paths) == "string" then
      paths = { paths }
    end
    return { kind = "file", paths = paths, content_type = body.contentType }
  end

  return { kind = "raw", data = tostring(body.data or ""), content_type = default_content_type(kind) }
end

--- Build curl arguments for a request spec.
--- @param spec table
--- @param opts table|nil { with_output = boolean, tmp = string }
--- @return table build { args, files }
function M.build_args(spec, opts)
  opts = opts or {}
  local conf = config.get()
  local body = M.prepare_body(spec.body)
  local tmp = opts.tmp or vim.fn.tempname()
  local files = {}
  local args = {
    conf.curl.bin,
    "--silent",
    "--show-error",
    "--globoff",
    "--compressed",
    "--request",
    spec.method or "GET",
  }

  if opts.with_output ~= false then
    files.headers = tmp .. ".headers"
    files.body = tmp .. ".body"
    args[#args + 1] = "--dump-header"
    args[#args + 1] = files.headers
    args[#args + 1] = "--output"
    args[#args + 1] = files.body
    args[#args + 1] = "--write-out"
    args[#args + 1] = "%{json}"
  end

  local timeout = spec.timeout_ms
  if timeout == nil then
    timeout = conf.curl.timeout
  end
  if timeout and timeout > 0 then
    args[#args + 1] = "--max-time"
    args[#args + 1] = ("%.3f"):format(timeout / 1000)
    args[#args + 1] = "--connect-timeout"
    args[#args + 1] = ("%.3f"):format(math.min(timeout / 1000, 10))
  end

  if spec.follow_redirects ~= false then
    args[#args + 1] = "--location"
    args[#args + 1] = "--max-redirs"
    args[#args + 1] = tostring(math.max(0, tonumber(spec.max_redirects) or 5))
  end

  if spec.insecure then
    args[#args + 1] = "--insecure"
  end

  if body then
    if not has_header(spec.headers, "content-type") and body.content_type then
      args[#args + 1] = "--header"
      args[#args + 1] = "Content-Type: " .. body.content_type
    end

    if body.kind == "raw" then
      files.input = tmp .. ".input"
      write_file(files.input, body.data)
      args[#args + 1] = "--data-binary"
      args[#args + 1] = "@" .. files.input
    elseif body.kind == "form" then
      for _, field in ipairs(body.fields) do
        args[#args + 1] = "--data-urlencode"
        args[#args + 1] = (field.name or "") .. "=" .. (field.value or "")
      end
    elseif body.kind == "multipart" then
      for _, field in ipairs(body.fields) do
        if field.type == "file" then
          local value = tostring(field.value or "")
          local part = field.content_type and (field.name .. "=@" .. value .. ";type=" .. field.content_type)
            or (field.name .. "=@" .. value)
          args[#args + 1] = "--form"
          args[#args + 1] = part
        else
          args[#args + 1] = "--form-string"
          args[#args + 1] = (field.name or "") .. "=" .. tostring(field.value or "")
        end
      end
    elseif body.kind == "file" then
      for _, path in ipairs(body.paths or {}) do
        args[#args + 1] = "--data-binary"
        args[#args + 1] = "@" .. path
      end
    end
  end

  for _, header in ipairs(spec.headers or {}) do
    if not header.disabled and header.name and header.name ~= "" then
      local value = tostring(header.value or ""):gsub("[\r\n]", " ")
      args[#args + 1] = "--header"
      args[#args + 1] = header.name .. ": " .. value
    end
  end

  for _, arg in ipairs(spec.curl_args or {}) do
    args[#args + 1] = arg
  end
  for _, arg in ipairs(conf.curl.extra_args or {}) do
    args[#args + 1] = arg
  end

  args[#args + 1] = spec.url
  return { args = args, files = files }
end

local function build_response(spec, meta, headers, raw_headers, status, reason, body, stderr)
  meta = meta or {}
  local code = tonumber(meta.http_code) or status or 0
  local curl_error = meta.errormsg
  if curl_error == vim.NIL then
    curl_error = nil
  end
  local content_type = meta.content_type
  if content_type == vim.NIL then
    content_type = nil
  end
  local effective_url = meta.url_effective
  if effective_url == vim.NIL then
    effective_url = nil
  end
  local error_message
  if curl_error and curl_error ~= "" then
    error_message = curl_error
  elseif stderr and vim.trim(stderr) ~= "" then
    error_message = vim.trim(stderr)
  end

  return {
    request = spec,
    status = code,
    reason = reason or "",
    headers = headers,
    raw_headers = raw_headers,
    body = body or "",
    size = tonumber(meta.size_download) or #(body or ""),
    time_ms = (tonumber(meta.time_total) or 0) * 1000,
    url = effective_url or spec.url,
    redirects = tonumber(meta.num_redirects) or 0,
    content_type = content_type or headers["content-type"],
    error = error_message,
    ok = error_message == nil and code >= 200 and code < 400,
  }
end

--- Execute a request spec asynchronously.
--- @param spec table
--- @param cb fun(response: table)
--- @return table job handle
function M.send(spec, cb)
  if not spec.url or spec.url == "" then
    vim.schedule(function()
      cb({ request = spec, status = 0, error = "empty request URL", body = "", headers = {} })
    end)
    return { cancel = function() end }
  end

  local built = M.build_args(spec)
  local job

  local function finish(result)
    local body = read_file(built.files.body) or ""
    local header_text = read_file(built.files.headers) or ""
    unlink(built.files.headers)
    unlink(built.files.body)
    unlink(built.files.input)

    local headers, raw_headers, status, reason = M.parse_headers(header_text)
    local meta
    if result.stdout and result.stdout ~= "" then
      local ok, decoded = pcall(vim.json.decode, result.stdout)
      if ok then
        meta = decoded
      end
    end

    local response = build_response(spec, meta, headers, raw_headers, status, reason, body, result.stderr)
    if result.code ~= 0 and not response.error then
      response.error = ("curl exited with code %d"):format(result.code)
      response.ok = false
    end
    if response.error then
      response.ok = false
    end
    vim.schedule(function()
      cb(response)
    end)
  end

  job = vim.system(built.args, { text = true }, function(result)
    pcall(finish, result)
  end)

  return {
    cancel = function()
      pcall(function()
        job:kill(15)
      end)
      unlink(built.files.headers)
      unlink(built.files.body)
      unlink(built.files.input)
    end,
  }
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Render the equivalent curl command (for "copy as curl").
--- @param spec table
--- @return string
function M.to_curl(spec)
  local conf = config.get()
  local body = M.prepare_body(spec.body)
  local parts = { conf.curl.bin, "--request", spec.method or "GET" }

  if spec.follow_redirects ~= false then
    parts[#parts + 1] = "--location"
  end
  if spec.insecure then
    parts[#parts + 1] = "--insecure"
  end
  if body and body.content_type and not has_header(spec.headers, "content-type") then
    parts[#parts + 1] = "--header"
    parts[#parts + 1] = shell_quote("Content-Type: " .. body.content_type)
  end
  for _, header in ipairs(spec.headers or {}) do
    if not header.disabled and header.name and header.name ~= "" then
      parts[#parts + 1] = "--header"
      parts[#parts + 1] = shell_quote(header.name .. ": " .. tostring(header.value or ""))
    end
  end

  if body then
    if body.kind == "raw" then
      parts[#parts + 1] = "--data-raw"
      parts[#parts + 1] = shell_quote(body.data)
    elseif body.kind == "form" then
      for _, field in ipairs(body.fields) do
        parts[#parts + 1] = "--data-urlencode"
        parts[#parts + 1] = shell_quote((field.name or "") .. "=" .. (field.value or ""))
      end
    elseif body.kind == "multipart" then
      for _, field in ipairs(body.fields) do
        local value = field.type == "file" and ("@" .. tostring(field.value)) or tostring(field.value)
        parts[#parts + 1] = "--form"
        parts[#parts + 1] = shell_quote((field.name or "") .. "=" .. value)
      end
    elseif body.kind == "file" then
      for _, path in ipairs(body.paths or {}) do
        parts[#parts + 1] = "--data-binary"
        parts[#parts + 1] = shell_quote("@" .. path)
      end
    end
  end

  for _, arg in ipairs(spec.curl_args or {}) do
    parts[#parts + 1] = shell_quote(arg)
  end
  for _, arg in ipairs(conf.curl.extra_args or {}) do
    parts[#parts + 1] = shell_quote(arg)
  end

  parts[#parts + 1] = shell_quote(spec.url)
  return table.concat(parts, " ")
end

return M
