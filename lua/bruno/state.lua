--- Small JSON-backed store for selections, local variables and history.
local M = {}

local uv = vim.uv or vim.loop

local function data_dir()
  local dir = vim.fs.joinpath(vim.fn.stdpath("data"), "bruno-nvim")
  vim.fn.mkdir(dir, "p")
  return dir
end

function M.path()
  return vim.fs.joinpath(data_dir(), "state.json")
end

local cache

function M.load()
  if cache then
    return cache
  end
  local path = M.path()
  if uv.fs_stat(path) then
    local fd = io.open(path, "rb")
    if fd then
      local text = fd:read("*a")
      fd:close()
      local ok, decoded = pcall(vim.json.decode, text)
      if ok and type(decoded) == "table" then
        cache = decoded
      end
    end
  end
  cache = cache or {}
  cache.collections = cache.collections or {}
  cache.history = cache.history or {}
  cache.oauth = cache.oauth or {}
  return cache
end

function M.save()
  if not cache then
    return
  end
  local ok, encoded = pcall(vim.json.encode, cache)
  if not ok then
    return
  end
  local path = M.path()
  local tmp = path .. ".tmp"
  local fd = io.open(tmp, "wb")
  if not fd then
    return
  end
  fd:write(encoded)
  fd:close()
  uv.fs_rename(tmp, path)
end

--- Per-collection state: `{ env = "Local", vars = {}, expanded = {} }`.
function M.collection(root, defaults)
  local state = M.load()
  local key = vim.fs.normalize(root)
  local entry = state.collections[key]
  if not entry then
    entry = {
      env = defaults and defaults.env or nil,
      vars = {},
      expanded = {},
    }
    state.collections[key] = entry
  end
  entry.vars = entry.vars or {}
  entry.expanded = entry.expanded or {}
  return entry
end

function M.update_collection(root, patch)
  local entry = M.collection(root)
  for key, value in pairs(patch) do
    entry[key] = value
  end
  M.save()
  return entry
end

function M.get(root, key)
  return M.collection(root)[key]
end

function M.set(root, key, value)
  local entry = M.collection(root)
  entry[key] = value
  M.save()
  return value
end

--- Record a request/response pair in the history ring.
--- @param entry table
--- @param opts table
function M.push_history(entry, opts)
  if not opts.enabled then
    return
  end
  local state = M.load()
  local body = entry.body or ""
  if #body > opts.max_body then
    body = body:sub(1, opts.max_body)
    entry.truncated = true
  end
  entry.body = body
  entry.time = os.time()
  table.insert(state.history, 1, entry)
  while #state.history > opts.size do
    table.remove(state.history)
  end
  M.save()
end

function M.history()
  return M.load().history
end

function M.clear_history()
  M.load().history = {}
  M.save()
end

function M.oauth_get(key)
  return M.load().oauth[key]
end

function M.oauth_set(key, value)
  local state = M.load()
  state.oauth[key] = value
  M.save()
end

return M
