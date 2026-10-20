--- Attach Bruno keymaps and buffer metadata to a request file.
local M = {}

local collection = require("bruno.collection")
local config = require("bruno.config")
local util = require("bruno.ui.util")

local function read_header_lines(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, math.min(60, vim.api.nvim_buf_line_count(buf)), false)
  return table.concat(lines, "\n")
end

--- Whether a buffer looks like a Bruno request file.
--- @param buf number
--- @return boolean
function M.is_request(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return false
  end

  local base = vim.fs.basename(path)
  local ext = path:match("%.([%w]+)$")
  if ext == "bru" then
    return base ~= "collection.bru" and base ~= "folder.bru" and collection.find_root(path) ~= nil
  end
  if ext ~= "yml" and ext ~= "yaml" then
    return false
  end
  if base == "opencollection.yml" or base == "folder.yml" then
    return false
  end
  if path:find("/environments/", 1, true) then
    return false
  end

  local root = collection.find_root(path)
  if not root then
    return false
  end

  local text = read_header_lines(buf)
  local has_info, has_request = false, false
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line:match("^%s*info%s*:") then
      has_info = true
    end
    if line:match("^%s*http%s*:") or line:match("^%s*graphql%s*:") then
      has_request = true
    end
  end
  return has_info and has_request
end

--- Attach keymaps/metadata to a request buffer.
--- @param buf number|nil
function M.attach(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if vim.b[buf].bruno_attached then
    return
  end

  local path = vim.api.nvim_buf_get_name(buf)
  local coll = collection.get({ path = path, buffer = buf })
  if not coll then
    return
  end

  vim.b[buf].bruno_attached = true
  vim.b[buf].bruno_root = coll.root
  vim.b[buf].bruno_path = path

  local keys = config.get().keymaps
  local opts = { buffer = buf, nowait = true, silent = true }

  local function map(lhs, fn, desc)
    if not lhs or lhs == "" then
      return
    end
    vim.keymap.set("n", lhs, fn, vim.tbl_extend("force", opts, { desc = "Bruno: " .. desc }))
  end

  map(keys.run, function()
    require("bruno.run").run_target({ buffer = buf })
  end, "run request")

  map(keys.peek, function()
    require("bruno.ui.vars").show_preview(nil, { buffer = buf })
  end, "preview request")

  map(keys.env, function()
    require("bruno.ui.picker").environments(coll)
  end, "select environment")

  map(keys.vars, function()
    require("bruno.ui.vars").show_variables(coll, nil, { buffer = buf })
  end, "variables")

  map(keys.history, function()
    require("bruno.ui.picker").history()
  end, "response history")

  map(keys.copy_curl, function()
    local _, _, req = require("bruno.run").target({ buffer = buf })
    if not req then
      util.notify("no request found in this buffer", vim.log.levels.WARN)
      return
    end
    local command = require("bruno.run").as_curl(req)
    if command then
      util.copy(command)
      util.notify("curl command copied", vim.log.levels.INFO)
    end
  end, "copy as curl")
end

--- Attach to the current buffer when it is a request file.
function M.attach_current()
  local buf = vim.api.nvim_get_current_buf()
  if M.is_request(buf) then
    M.attach(buf)
  end
end

return M
