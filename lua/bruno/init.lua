local M = {}

local collection = require("bruno.collection")
local config = require("bruno.config")
local env = require("bruno.env")
local state = require("bruno.state")
local util = require("bruno.ui.util")

--- Configure bruno-nvim. All options are optional.
--- @param opts table|nil
function M.setup(opts)
  config.setup(opts)
  util.highlights()
  return M
end

--- Open (or close) the collection sidebar.
--- @param opts table|nil
function M.open(opts)
  require("bruno.ui.tree").toggle(opts)
end

--- Open the request picker.
function M.pick()
  require("bruno.ui.picker").requests()
end

--- Run the current request or a request at `opts.path`.
--- @param opts table|nil
function M.run(opts)
  return require("bruno.run").run_target(opts or {})
end

--- Open the environment picker, or select an environment by name.
--- @param name string|nil
function M.env(name)
  local coll, err = collection.get()
  if not coll then
    util.notify(err or "collection not found", vim.log.levels.ERROR)
    return
  end

  if not name or name == "" then
    require("bruno.ui.picker").environments(coll)
    return
  end

  local list = env.load_environments(coll)
  for _, environment in ipairs(list) do
    if environment.name == name then
      state.set(coll.root, "env", name)
      util.notify("environment: " .. name, vim.log.levels.INFO)
      local tree = require("bruno.ui.tree")
      if tree.is_open() then
        tree.refresh()
      end
      return
    end
  end

  local names = {}
  for _, environment in ipairs(list) do
    names[#names + 1] = environment.name
  end
  util.notify(
    ("unknown environment %q (available: %s)"):format(name, #names > 0 and table.concat(names, ", ") or "none"),
    vim.log.levels.ERROR
  )
end

--- Set, remove or list local variables.
--- @param argument string|nil
function M.var(argument)
  local coll, err = collection.get()
  if not coll then
    util.notify(err or "collection not found", vim.log.levels.ERROR)
    return
  end

  if not argument or argument == "" then
    require("bruno.ui.vars").show_variables(coll)
    return
  end

  local unset, name = argument:match("^%-%-unset%s+(.+)$")
  if not unset then
    unset, name = argument:match("^%-u%s+(.+)$")
  end
  if unset then
    require("bruno.run").unset_var(coll.root, vim.trim(name), { persist = true })
    util.notify("removed variable " .. name, vim.log.levels.INFO)
    return
  end

  local key, value = argument:match("^([^=]+)=(.*)$")
  if key then
    key = vim.trim(key)
    require("bruno.run").set_var(coll.root, key, value, { persist = true })
    util.notify(("variable %s set"):format(key), vim.log.levels.INFO)
    return
  end

  local runtime = require("bruno.run").runtime(coll.root)
  local value = runtime[vim.trim(argument)] or state.collection(coll.root).vars[vim.trim(argument)]
  if value == nil then
    util.notify("variable not set: " .. argument, vim.log.levels.WARN)
  else
    util.notify(("%s = %s"):format(argument, tostring(value)), vim.log.levels.INFO)
  end
end

--- Preview the resolved request.
function M.peek()
  require("bruno.ui.vars").show_preview()
end

--- Browse response history.
function M.history()
  require("bruno.ui.picker").history()
end

--- Reopen the last response for the current request.
function M.response()
  local path = vim.api.nvim_buf_get_name(0)
  require("bruno.ui.response").open_last(path)
end

--- Copy the current request as a curl command.
function M.copy_curl()
  local _, _, req = require("bruno.run").target()
  if not req then
    util.notify("no request in the current buffer", vim.log.levels.WARN)
    return
  end
  local command = require("bruno.run").as_curl(req)
  if command then
    util.copy(command)
    util.notify("curl command copied", vim.log.levels.INFO)
  end
end

--- Reload collections from disk.
function M.reload()
  collection.clear()
  local tree = require("bruno.ui.tree")
  if tree.is_open() then
    tree.refresh()
  end
  util.notify("collections reloaded", vim.log.levels.INFO)
end

function M.help()
  require("bruno.ui.vars").help()
end

return M
