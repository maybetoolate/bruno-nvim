--- Collection discovery, loading and the in-memory tree model.
local M = {}

local yaml = require("bruno.yaml")
local bru = require("bruno.bru")
local request = require("bruno.request")

local uv = vim.uv or vim.loop

local cache = {}

local function is_dir(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == "directory"
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

--- Walk up from a file or directory until a collection root is found.
--- @param start string|nil
--- @return string|nil root
--- @return string|nil kind "opencollection" | "bru"
function M.find_root(start)
  local path = vim.fs.normalize(vim.fn.fnamemodify(start or vim.fn.getcwd(), ":p"))
  local stat = uv.fs_stat(path)
  if stat and stat.type ~= "directory" then
    path = vim.fs.dirname(path)
  end
  while path and path ~= "" do
    if exists(vim.fs.joinpath(path, "opencollection.yml")) then
      return path, "opencollection"
    end
    if exists(vim.fs.joinpath(path, "bruno.json")) then
      return path, "bru"
    end
    local parent = vim.fs.dirname(path)
    if not parent or parent == path then
      break
    end
    path = parent
  end
end

--- Merge request defaults (collection -> folder), keeping arrays ordered and
--- letting the nearest definition win for headers and settings.
--- @param parent table|nil
--- @param child table|nil
--- @return table
function M.merge_defaults(parent, child)
  parent = parent or {}
  if not child then
    return parent
  end

  local auth = child.auth
  if auth == nil or auth == "inherit" then
    auth = parent.auth
  end

  local merged = {
    headers = vim.deepcopy(parent.headers or {}),
    variables = vim.deepcopy(parent.variables or {}),
    scripts = vim.deepcopy(parent.scripts or {}),
    auth = auth,
    settings = vim.tbl_deep_extend("force", parent.settings or {}, child.settings or {}),
  }

  local index = {}
  for i, header in ipairs(merged.headers) do
    index[(header.name or ""):lower()] = i
  end
  for _, header in ipairs(child.headers or {}) do
    local key = (header.name or ""):lower()
    if index[key] then
      merged.headers[index[key]] = vim.deepcopy(header)
    else
      merged.headers[#merged.headers + 1] = vim.deepcopy(header)
      index[key] = #merged.headers
    end
  end

  for _, variable in ipairs(child.variables or {}) do
    merged.variables[#merged.variables + 1] = vim.deepcopy(variable)
  end
  for _, script in ipairs(child.scripts or {}) do
    merged.scripts[#merged.scripts + 1] = vim.deepcopy(script)
  end

  return merged
end

local function defaults_from_raw(raw)
  if not raw then
    return {}
  end
  local source = raw.request or raw
  local defaults = {
    headers = (raw.http and raw.http.headers) or source.headers,
    auth = (raw.http and raw.http.auth) or source.auth,
    variables = raw.variables or source.variables,
    scripts = (raw.runtime and raw.runtime.scripts) or source.scripts or raw.scripts,
    settings = source.settings or raw.settings,
  }
  if raw.vars then
    defaults.variables = raw.vars
  end
  return request.normalize_defaults(defaults)
end

local function load_collection_config(root)
  local oc = vim.fs.joinpath(root, "opencollection.yml")
  if exists(oc) then
    local raw, err = yaml.decode_file(oc)
    if not raw then
      return nil, "opencollection.yml: " .. tostring(err)
    end
    local name = (raw.info and raw.info.name) or raw.name or vim.fs.basename(root)
    local ignore = raw.ignore or (raw.info and raw.info.ignore) or {}
    local default_env = raw.defaultEnvironment
      or (raw.extensions and raw.extensions.bruno and raw.extensions.bruno.defaultEnvironment)
    return {
      kind = "opencollection",
      name = name,
      raw = raw,
      ignore = ignore,
      default_env = default_env,
      defaults = defaults_from_raw(raw),
    }
  end

  local bj = vim.fs.joinpath(root, "bruno.json")
  if exists(bj) then
    local text = read_file(bj)
    local ok, raw = pcall(vim.json.decode, text or "")
    if not ok or type(raw) ~= "table" then
      return nil, "bruno.json: invalid JSON"
    end
    local defaults = {}
    local collection_bru = vim.fs.joinpath(root, "collection.bru")
    if exists(collection_bru) then
      local parsed = bru.parse(read_file(collection_bru) or "")
      defaults = defaults_from_raw(parsed)
    end
    return {
      kind = "bru",
      name = raw.name or vim.fs.basename(root),
      raw = raw,
      ignore = raw.ignore or {},
      default_env = raw.defaultEnvironment,
      defaults = defaults,
    }
  end

  return nil, "no opencollection.yml or bruno.json in " .. root
end

local function read_folder_meta(dir, kind)
  local name = vim.fs.joinpath(dir, "folder.yml")
  if exists(name) then
    local raw = yaml.decode_file(name)
    if raw then
      return raw, "folder.yml"
    end
  end
  local bru_name = vim.fs.joinpath(dir, "folder.bru")
  if exists(bru_name) then
    local parsed = bru.parse(read_file(bru_name) or "")
    return parsed, "folder.bru"
  end
  return nil, kind == "bru" and "folder.bru" or "folder.yml"
end

local function ignored(name, ignore_set)
  if name:sub(1, 1) == "." then
    return true
  end
  if ignore_set[name] then
    return true
  end
  return false
end

local function build_ignore_set(ignore)
  local set = {
    [".git"] = true,
    ["node_modules"] = true,
    ["environments"] = true,
    ["opencollection.yml"] = true,
    ["bruno.json"] = true,
    ["folder.yml"] = true,
    ["folder.bru"] = true,
    ["collection.bru"] = true,
  }
  for _, item in ipairs(ignore or {}) do
    if type(item) == "string" then
      set[item] = true
    end
  end
  return set
end

local function sort_nodes(nodes)
  table.sort(nodes, function(a, b)
    local sa, sb = tonumber(a.seq), tonumber(b.seq)
    if sa and sb and sa ~= sb then
      return sa < sb
    end
    if sa and not sb then
      return true
    end
    if sb and not sa then
      return false
    end
    if a.type ~= b.type then
      return a.type == "folder"
    end
    return a.name:lower() < b.name:lower()
  end)
end

local function scan_dir(coll, dir, parent, defaults, ignore_set, warnings)
  local entries = {}
  local ok, iter = pcall(vim.fs.dir, dir)
  if not ok then
    return entries
  end
  for name, ftype in iter do
    if not ignored(name, ignore_set) then
      entries[#entries + 1] = { name = name, type = ftype }
    end
  end
  table.sort(entries, function(a, b)
    return a.name:lower() < b.name:lower()
  end)

  local nodes = {}

  for _, entry in ipairs(entries) do
    local path = vim.fs.joinpath(dir, entry.name)
    if entry.type == "directory" then
      if not is_dir(vim.fs.joinpath(path, ".git")) then
        local meta, meta_file = read_folder_meta(path, coll.kind)
        local own_defaults = {}
        local folder_defaults = defaults
        if meta then
          own_defaults = defaults_from_raw(meta)
          folder_defaults = M.merge_defaults(defaults, own_defaults)
        end
        local info = (meta and meta.info) or meta or {}
        local node = {
          type = "folder",
          name = info.name or entry.name,
          path = path,
          seq = info.seq,
          docs = meta and meta.docs,
          meta_file = meta_file,
          defaults = folder_defaults,
          folder_vars = own_defaults.variables,
          parent = parent,
        }
        node.children = scan_dir(coll, path, node, folder_defaults, ignore_set, warnings)
        if #node.children > 0 or meta then
          nodes[#nodes + 1] = node
        end
      end
    elseif entry.type == "file" then
      local ext = entry.name:match("%.(%w+)$")
      if ext == "yml" or ext == "yaml" or ext == "bru" then
        if entry.name ~= "folder.yml" and entry.name ~= "folder.bru" and entry.name ~= "opencollection.yml" then
          local node = {
            type = "request",
            path = path,
            parent = parent,
            defaults = defaults,
          }
          local raw, err
          if ext == "bru" then
            raw, err = bru.parse_file(path)
          else
            raw, err = yaml.decode_file(path)
          end
          if raw then
            local req = request.normalize(raw, node)
            node.raw = raw
            node.request = req
            node.name = req.name
            node.seq = req.seq
            node.method = req.method
          else
            node.name = entry.name:gsub("%.ya?ml$", ""):gsub("%.bru$", "")
            node.method = "?"
            node.error = err
            warnings[#warnings + 1] = ("%s: %s"):format(path, tostring(err))
          end
          nodes[#nodes + 1] = node
        end
      end
    end
  end

  sort_nodes(nodes)
  return nodes
end

local function count_requests(node)
  if node.type == "request" then
    return 1
  end
  local n = 0
  for _, child in ipairs(node.children or {}) do
    n = n + count_requests(child)
  end
  return n
end

M.count_requests = count_requests

--- Load (or reuse) a collection rooted at `root`.
--- @param root string
--- @param opts table|nil { force = boolean }
--- @return table|nil collection
--- @return string|nil error
function M.load(root, opts)
  opts = opts or {}
  root = vim.fs.normalize(vim.fn.fnamemodify(root, ":p"))
  local oc_path = vim.fs.joinpath(root, "opencollection.yml")
  local bj_path = vim.fs.joinpath(root, "bruno.json")
  local config_stat = uv.fs_stat(oc_path) or uv.fs_stat(bj_path)
  local stamp = config_stat and (tostring(config_stat.mtime.sec) .. ":" .. tostring(config_stat.mtime.nsec)) or "0"

  local cached = cache[root]
  if cached and cached.stamp == stamp and not opts.force then
    return cached.collection
  end

  local conf, err = load_collection_config(root)
  if not conf then
    return nil, err
  end

  local warnings = {}
  local ignore_set = build_ignore_set(conf.ignore)
  local collection = {
    root = root,
    name = conf.name,
    kind = conf.kind,
    config = conf.raw,
    defaults = conf.defaults or {},
    default_env = conf.default_env,
    warnings = warnings,
    stamp = stamp,
  }

  collection.children = scan_dir(collection, root, nil, collection.defaults, ignore_set, warnings)

  collection.tree = {
    type = "collection",
    name = collection.name,
    path = root,
    children = collection.children,
    count = count_requests({ type = "folder", children = collection.children }),
  }

  local function index(node, parent)
    node.parent = parent
    node.collection = collection
    if node.type == "request" then
      collection.requests = collection.requests or {}
      collection.requests[vim.fs.normalize(node.path)] = node
    else
      for _, child in ipairs(node.children or {}) do
        index(child, node)
      end
    end
  end
  index(collection.tree, nil)

  cache[root] = { stamp = stamp, collection = collection }
  return collection
end

--- Invalidate cached collections that contain `path`.
function M.invalidate(path)
  path = vim.fs.normalize(path)
  for root, _ in pairs(cache) do
    if path:sub(1, #root + 1) == root .. "/" or path == root then
      cache[root] = nil
    end
  end
end

function M.clear()
  cache = {}
end

--- Resolve the collection to operate on.
--- @param opts table|nil { path = string, buffer = number }
--- @return table|nil collection
--- @return string|nil error
function M.get(opts)
  opts = opts or {}
  local config = require("bruno.config").get()
  local root, err

  if opts.path and opts.path ~= "" then
    local path = vim.fs.normalize(vim.fn.fnamemodify(opts.path, ":p"))
    if
      is_dir(path)
      and not exists(vim.fs.joinpath(path, "opencollection.yml"))
      and not exists(vim.fs.joinpath(path, "bruno.json"))
    then
      root = M.find_root(path)
    elseif exists(vim.fs.joinpath(path, "opencollection.yml")) or exists(vim.fs.joinpath(path, "bruno.json")) then
      root = path
    else
      root = M.find_root(path)
      if not root then
        return nil, "not inside a Bruno collection: " .. path
      end
    end
  elseif config.collection then
    root = M.find_root(config.collection) or vim.fs.normalize(vim.fn.fnamemodify(config.collection, ":p"))
  else
    local buf = opts.buffer or vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(buf)
    root = M.find_root(name ~= "" and name or vim.fn.getcwd())
    if not root then
      root = M.find_root(vim.fn.getcwd())
    end
  end

  if not root then
    return nil, err or "no Bruno collection found (looked for opencollection.yml / bruno.json)"
  end

  return M.load(root, opts)
end

--- Find a request node by file path.
--- @param coll table
--- @param path string
--- @return table|nil
function M.request_by_path(coll, path)
  local node = coll.requests and coll.requests[vim.fs.normalize(path)]
  return node
end

--- Flatten the tree into a list of request nodes, in display order.
--- @param coll table
--- @return table[]
function M.flat_requests(coll)
  local out = {}
  local function walk(node, trail)
    if node.type == "request" then
      out[#out + 1] = vim.tbl_extend("force", node, { trail = trail })
    else
      local next_trail = vim.deepcopy(trail)
      if node.type == "folder" then
        next_trail[#next_trail + 1] = node.name
      end
      for _, child in ipairs(node.children or {}) do
        walk(child, next_trail)
      end
    end
  end
  for _, child in ipairs(coll.children or {}) do
    walk(child, {})
  end
  return out
end

return M
