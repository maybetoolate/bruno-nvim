--- Pickers for requests, environments and response history.
local M = {}

local collection = require("bruno.collection")
local env = require("bruno.env")
local state = require("bruno.state")
local util = require("bruno.ui.util")

local function format_request(item)
  local trail = item.trail and #item.trail > 0 and ("  —  " .. table.concat(item.trail, "/")) or ""
  return ("%-6s %s%s"):format(item.method or "?", item.name or "", trail)
end

local function open_request(item)
  require("bruno.ui.tree").open_path(item.path, item.collection or item.node and item.node.collection)
end

--- Pick a request from the collection.
--- @param coll table|nil
function M.requests(coll)
  coll = coll or collection.get()
  if not coll then
    util.notify("collection not found", vim.log.levels.ERROR)
    return
  end

  local requests = collection.flat_requests(coll)
  if #requests == 0 then
    util.notify("this collection has no requests", vim.log.levels.WARN)
    return
  end

  vim.ui.select(requests, {
    prompt = coll.name .. " requests",
    format_item = format_request,
  }, function(choice)
    if choice then
      open_request(choice)
    end
  end)
end

--- Pick an environment. Choosing "no environment" clears the selection.
--- @param coll table|nil
function M.environments(coll)
  coll = coll or collection.get()
  if not coll then
    util.notify("collection not found", vim.log.levels.ERROR)
    return
  end

  local list = env.load_environments(coll)
  local active = env.active_name(coll)
  local items = {}

  for _, environment in ipairs(list) do
    items[#items + 1] = {
      name = environment.name,
      count = vim.tbl_count(environment.vars or {}),
      active = environment.name == active,
    }
  end

  if #items == 0 then
    util.notify("no environments found; create environments/<name>.yml in " .. coll.root, vim.log.levels.WARN)
    return
  end

  table.insert(items, { name = "", none = true })

  vim.ui.select(items, {
    prompt = "Environment",
    format_item = function(item)
      if item.none then
        return "— no environment —"
      end
      return ("%s %s (%d vars)"):format(item.active and "●" or " ", item.name, item.count)
    end,
  }, function(choice)
    if not choice then
      return
    end
    local name = choice.none and nil or choice.name
    state.set(coll.root, "env", name)
    util.notify("environment: " .. (name or "none"), vim.log.levels.INFO)
    local tree = require("bruno.ui.tree")
    if tree.is_open() then
      tree.refresh()
    end
  end)
end

--- Browse stored responses.
function M.history()
  local entries = state.history()
  if #entries == 0 then
    util.notify("no response history yet", vim.log.levels.INFO)
    return
  end

  vim.ui.select(entries, {
    prompt = "Response history",
    format_item = function(entry)
      local when = os.date("%H:%M:%S", entry.time or 0)
      return ("%s  %-6s %s %s (%dms)"):format(
        when,
        entry.method or "?",
        entry.status or 0,
        entry.name or entry.url or "",
        entry.time_ms or 0
      )
    end,
  }, function(entry)
    if not entry then
      return
    end

    local req
    if entry.path and entry.path ~= "" then
      local ok, loaded = pcall(require("bruno.run").load_request_file, entry.path)
      if ok then
        req = loaded
      end
    end

    local response = {
      status = entry.status,
      reason = entry.reason,
      headers = entry.headers or {},
      body = entry.body or "",
      size = entry.size or #(entry.body or ""),
      time_ms = entry.time_ms or 0,
      url = entry.url,
      content_type = (entry.headers or {})["content-type"],
      spec = { method = entry.method, url = entry.url },
      request = req,
      timestamp = entry.time,
    }

    require("bruno.ui.response").show(response, {
      req = req,
      coll = req and req.node and req.node.collection or collection.get({ path = entry.path }),
      from_history = true,
    })
  end)
end

return M
