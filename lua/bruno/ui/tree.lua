--- Collection sidebar.
local M = {}

local collection = require("bruno.collection")
local config = require("bruno.config")
local env = require("bruno.env")
local state = require("bruno.state")
local util = require("bruno.ui.util")

local tree = {
  buf = nil,
  win = nil,
  coll = nil,
  lines = {},
  nodes = {},
  expanded = {},
  prev_win = nil,
}

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function count_label(count)
  return ("(%d)"):format(count)
end

local function collect_folders(node, depth, out)
  for _, child in ipairs(node.children or {}) do
    if child.type == "folder" then
      out[child.path] = true
      if depth < 1 then
        collect_folders(child, depth + 1, out)
      end
    end
  end
end

local function restore_expanded(coll)
  local saved = state.collection(coll.root).expanded
  tree.expanded = {}
  if saved and next(saved) ~= nil then
    for path, open in pairs(saved) do
      tree.expanded[path] = open and true or false
    end
  else
    -- First visit: expand the top level folders.
    collect_folders(coll.tree, 0, tree.expanded)
  end
end

local function save_expanded()
  if tree.coll then
    state.collection(tree.coll.root).expanded = tree.expanded
    state.save()
  end
end

local function is_open(node)
  return tree.expanded[node.path] ~= false
end

local function render()
  if not valid_buf(tree.buf) then
    return
  end

  local coll = tree.coll
  local lines, nodes, marks = {}, {}, {}
  local active_env = env.active_name(coll) or "no environment"
  local total = collection.count_requests({ type = "folder", children = coll.children or {} })

  lines[#lines + 1] = (" %s"):format(coll.name)
  marks[#marks + 1] = { #lines - 1, 0, #coll.name + 1, "BrunoTreeCollection" }
  lines[#lines + 1] = ("  %s · %d requests"):format(active_env, total)
  marks[#marks + 1] = { #lines - 1, 2, #lines[#lines], "BrunoTreeCount" }
  lines[#lines + 1] = ""

  local function walk(children, depth)
    for _, node in ipairs(children) do
      if node.type == "folder" then
        local open = is_open(node)
        local indent = string.rep("  ", depth) .. (open and "▾ " or "▸ ")
        local icon = util.icon("folder")
        local line = indent .. (icon ~= "" and (icon .. " ") or "") .. node.name
        local count = collection.count_requests(node)
        line = line .. "  " .. count_label(count)
        lines[#lines + 1] = line
        nodes[#lines] = node
        local name_start = #indent + (icon ~= "" and #icon + 1 or 0)
        marks[#marks + 1] = { #lines - 1, name_start, name_start + #node.name, "BrunoTreeFolder" }
        local count_start = #line - #count_label(count)
        marks[#marks + 1] = { #lines - 1, count_start, #line, "BrunoTreeCount" }
        if open then
          walk(node.children or {}, depth + 1)
        end
      else
        local indent = string.rep("  ", depth) .. "  "
        local method = (node.method or "?") .. string.rep(" ", math.max(0, 7 - #(node.method or "?")))
        local line = indent .. method .. " " .. node.name
        lines[#lines + 1] = line
        nodes[#lines] = node
        marks[#marks + 1] = { #lines - 1, #indent, #indent + #method, util.method_hl(node.method) }
      end
    end
  end

  walk(coll.children or {}, 0)

  if #lines == 3 then
    lines[#lines + 1] = "  no requests found"
    marks[#marks + 1] = { #lines - 1, 2, #lines[#lines], "BrunoTreeCount" }
  end

  util.set_lines(tree.buf, lines)
  vim.api.nvim_buf_clear_namespace(tree.buf, util.ns, 0, -1)
  for _, mark in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, tree.buf, util.ns, mark[1], mark[2], {
      end_col = mark[3],
      hl_group = mark[4],
    })
  end

  tree.lines = lines
  tree.nodes = nodes

  util.winbar(tree.win, {
    { " bruno ", "Title" },
    { coll.name .. " ", "Comment" },
  })
end

local function node_at_cursor()
  if not valid_win(tree.win) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(tree.win)[1]
  return tree.nodes[row]
end

local function target_window()
  if valid_win(tree.prev_win) and tree.prev_win ~= tree.win then
    return tree.prev_win
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= tree.win and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
end

local function open_node(node)
  if not node then
    return
  end
  if node.type == "folder" then
    tree.expanded[node.path] = not is_open(node)
    save_expanded()
    render()
    return
  end

  local win = target_window()
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd("vsplit")
  end
  vim.cmd("hide edit " .. vim.fn.fnameescape(node.path))
  require("bruno.ui.request").attach(vim.api.nvim_get_current_buf())
end

local function toggle_node()
  local node = node_at_cursor()
  if not node then
    return
  end
  if node.type == "folder" then
    tree.expanded[node.path] = not is_open(node)
    save_expanded()
    render()
  end
end

local function run_node()
  local node = node_at_cursor()
  if not node then
    util.notify("no request under the cursor", vim.log.levels.WARN)
    return
  end
  if node.type == "folder" then
    util.notify("select a request to run", vim.log.levels.WARN)
    return
  end
  require("bruno.run").run_target({ node = node })
end

--- Attach keymaps to the sidebar buffer.
local function keymaps(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Bruno: " .. desc })
  end
  map("<CR>", function()
    local node = node_at_cursor()
    if node and node.type == "folder" then
      toggle_node()
    else
      open_node(node)
    end
  end, "open")
  map("o", toggle_node, "toggle folder")
  map("R", run_node, "run request")
  map("r", function()
    M.refresh()
  end, "reload collection")
  map("e", function()
    require("bruno.ui.picker").environments(tree.coll)
  end, "select environment")
  map("v", function()
    local node = node_at_cursor()
    local req = node and node.request or nil
    require("bruno.ui.vars").show_variables(tree.coll, req)
  end, "variables")
  map("y", function()
    local node = node_at_cursor()
    if node and node.request then
      local command = require("bruno.run").as_curl(node.request)
      if command then
        util.copy(command)
        util.notify("curl command copied", vim.log.levels.INFO)
      end
    end
  end, "copy as curl")
  map("?", function()
    require("bruno.ui.vars").help()
  end, "help")
  map("q", function()
    M.close()
  end, "close")
  map("g?", function()
    require("bruno.ui.vars").help()
  end, "help")
end

local function create()
  local width = config.get().ui.width
  vim.cmd("topleft vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(win, width)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "bruno-tree"

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].winfixwidth = true
  vim.wo[win].list = false

  tree.buf = buf
  tree.win = win
  keymaps(buf)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if tree.buf == buf then
        tree.buf = nil
        tree.win = nil
      end
    end,
  })
end

--- Open (or focus) the sidebar.
--- @param opts table|nil { path = string, toggle = boolean }
function M.open(opts)
  opts = opts or {}
  if valid_win(tree.win) then
    vim.api.nvim_set_current_win(tree.win)
    if opts.toggle then
      M.close()
    end
    return
  end

  local coll, err = collection.get({ path = opts.path })
  if not coll then
    util.notify(err or "collection not found", vim.log.levels.ERROR)
    return
  end

  tree.prev_win = vim.api.nvim_get_current_win()
  tree.coll = coll
  restore_expanded(coll)

  create()
  render()

  vim.api.nvim_win_set_cursor(tree.win, { 1, 0 })
end

function M.toggle(opts)
  opts = opts or {}
  if valid_win(tree.win) then
    M.close()
  else
    M.open(opts)
  end
end

function M.close()
  if valid_win(tree.win) then
    vim.api.nvim_win_close(tree.win, true)
  end
  tree.win = nil
  tree.buf = nil
end

--- Reload the collection from disk and redraw.
function M.refresh()
  if not tree.coll then
    return
  end
  local cursor_line = tree.win and valid_win(tree.win) and vim.api.nvim_win_get_cursor(tree.win)[1] or 1
  local coll, err = collection.load(tree.coll.root, { force = true })
  if not coll then
    util.notify(err or "reload failed", vim.log.levels.ERROR)
    return
  end
  tree.coll = coll
  render()
  if valid_win(tree.win) then
    local line = math.min(cursor_line, math.max(1, #tree.lines))
    pcall(vim.api.nvim_win_set_cursor, tree.win, { line, 0 })
  end
end

function M.open_path(path, coll)
  if coll and tree.coll ~= coll then
    tree.coll = coll
    restore_expanded(coll)
    if valid_buf(tree.buf) then
      render()
    end
  end

  local current = vim.api.nvim_get_current_win()
  local filetype = vim.bo[vim.api.nvim_win_get_buf(current)].filetype
  local win
  if filetype == "bruno-tree" then
    win = target_window()
  end
  if win then
    vim.api.nvim_set_current_win(win)
  elseif filetype == "bruno-tree" then
    vim.cmd("vsplit")
  end

  vim.cmd("hide edit " .. vim.fn.fnameescape(path))
  require("bruno.ui.request").attach(vim.api.nvim_get_current_buf())
end

--- Expand the folders that contain `path` and move the cursor to it.
function M.reveal(path)
  if not tree.coll then
    return
  end
  local node = tree.coll.requests and tree.coll.requests[vim.fs.normalize(path)]
  if not node then
    return
  end
  local parent = node.parent
  while parent and parent.type ~= "collection" do
    tree.expanded[parent.path] = true
    parent = parent.parent
  end
  save_expanded()
  render()
  for i, candidate in ipairs(tree.nodes) do
    if candidate.path == node.path then
      if valid_win(tree.win) then
        vim.api.nvim_win_set_cursor(tree.win, { i, 0 })
      end
      break
    end
  end
end

function M.collection()
  return tree.coll
end

function M.current_node()
  return node_at_cursor()
end

function M.is_open()
  return valid_win(tree.win) ~= nil
end

return M
