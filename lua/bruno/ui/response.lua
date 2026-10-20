--- Response viewer.
local M = {}

local config = require("bruno.config")
local util = require("bruno.ui.util")

local S = {
  buf = nil,
  win = nil,
  resp = nil,
  req = nil,
  coll = nil,
  pretty = true,
  headers = true,
  counter = 0,
}

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function origin_window()
  local current = vim.api.nvim_get_current_win()
  local filetype = vim.bo[vim.api.nvim_win_get_buf(current)].filetype
  if filetype ~= "bruno-tree" then
    return current
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= current and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
  return current
end

local function is_json(resp)
  return (resp.content_type or ""):find("json", 1, true) ~= nil
    or (resp.body or ""):match("^%s*{") ~= nil
    or (resp.body or ""):match("^%s*%[") ~= nil
end

local function filetype_for(resp)
  if is_json(resp) then
    return "json"
  end
  local content_type = (resp.content_type or ""):lower()
  if content_type:find("html", 1, true) then
    return "html"
  elseif content_type:find("xml", 1, true) then
    return "xml"
  elseif content_type:find("javascript", 1, true) then
    return "javascript"
  end
  return "text"
end

local function header_chunks(resp, req)
  local lines = {}

  local method = (req and req.method) or (resp.spec and resp.spec.method) or "?"
  local url = (resp.spec and resp.spec.url) or resp.url or (req and req.url) or ""
  lines[#lines + 1] = {
    { " " .. method .. " ", util.method_hl(method) },
    { util.truncate(url, math.max(40, vim.o.columns - 24)), "Normal" },
  }

  local status_text = ("%s %s"):format(resp.status or 0, resp.reason or "")
  local metrics = ("%d ms · %s"):format(math.floor(resp.time_ms or 0), util.human_size(resp.size))
  if resp.content_type and resp.content_type ~= "" then
    metrics = metrics .. " · " .. resp.content_type
  end
  lines[#lines + 1] = {
    { " " .. status_text .. " ", util.status_hl(resp.status) },
    { " " .. metrics .. " ", "BrunoResponseHeader" },
  }

  if resp.error then
    lines[#lines + 1] = { { " " .. resp.error, "BrunoStatusError" } }
  end

  if S.headers then
    local names = vim.tbl_keys(resp.headers or {})
    table.sort(names)
    for i, name in ipairs(names) do
      if i > 25 then
        lines[#lines + 1] = { { ("  … %d more headers"):format(#names - 25), "BrunoResponseHeader" } }
        break
      end
      lines[#lines + 1] = {
        { "  " .. name .. ": ", "BrunoResponseHeader" },
        { tostring(resp.headers[name]):gsub("[\r\n]", " "), "Normal" },
      }
    end
  end

  if resp.tests and #resp.tests > 0 then
    lines[#lines + 1] = { { "", "Normal" } }
    for _, test in ipairs(resp.tests) do
      if test.passed then
        lines[#lines + 1] = { { "  ✓ " .. test.name, "BrunoTestPass" } }
      else
        lines[#lines + 1] =
          { { "  ✗ " .. test.name, "BrunoTestFail" }, { "  " .. tostring(test.error), "BrunoResponseHeader" } }
      end
    end
  end

  if resp.logs and #resp.logs > 0 then
    lines[#lines + 1] = { { "", "Normal" } }
    for i, log in ipairs(resp.logs) do
      if i > 10 then
        break
      end
      local level = log.level or "log"
      local hl = (level == "error" or level == "warn") and "BrunoTestFail" or "BrunoResponseHeader"
      lines[#lines + 1] = { { ("  [%s] "):format(level), hl }, { tostring(log.message), "Normal" } }
    end
  end

  if resp.warnings and #resp.warnings > 0 then
    lines[#lines + 1] = { { "", "Normal" } }
    for _, warning in ipairs(resp.warnings) do
      lines[#lines + 1] = { { "  ! " .. warning, "BrunoStatus4xx" } }
    end
  end

  lines[#lines + 1] =
    { { " " .. string.rep("─", math.max(10, math.min(vim.o.columns - 6, 100))), "BrunoResponseHeader" } }
  return lines
end

local function render()
  if not valid_buf(S.buf) or not S.resp then
    return
  end
  local resp = S.resp
  local use_pretty = S.pretty and is_json(resp)
  local body = resp.body or ""
  if use_pretty then
    local pretty = util.pretty_body(body, resp.content_type)
    body = pretty
  end

  local lines = util.split_lines(body)
  if #lines == 0 then
    lines = { "" }
  end

  util.set_lines(S.buf, lines)
  vim.bo[S.buf].filetype = use_pretty and "json" or filetype_for(resp)

  vim.api.nvim_buf_clear_namespace(S.buf, util.ns, 0, -1)
  local ok = pcall(vim.api.nvim_buf_set_extmark, S.buf, util.ns, 0, 0, {
    virt_lines = header_chunks(resp, S.req),
    virt_lines_above = true,
  })
  if not ok then
    -- Older Neovim without virt_lines_above support.
    pcall(vim.api.nvim_buf_set_extmark, S.buf, util.ns, 0, 0, {
      virt_lines = header_chunks(resp, S.req),
    })
  end

  util.winbar(S.win, {
    { " " .. (S.req and S.req.method or "?") .. " ", util.method_hl(S.req and S.req.method) },
    { util.truncate((resp.spec and resp.spec.url) or resp.url or "", 60), "Comment" },
    { "  " .. tostring(resp.status) .. " " .. (resp.reason or ""), util.status_hl(resp.status) },
    { ("  %dms "):format(math.floor(resp.time_ms or 0)), "Comment" },
  })
end

local function rerun()
  if not S.req then
    util.notify("no request associated with this response", vim.log.levels.WARN)
    return
  end
  local run = require("bruno.run")
  run.run(S.req, {
    on_start = function(prepared)
      util.winbar(S.win, {
        { " " .. prepared.spec.method .. " ", util.method_hl(prepared.spec.method) },
        { util.truncate(prepared.spec.url, 70), "Comment" },
        { "  sending… ", "BrunoStatus3xx" },
      })
    end,
  })
end

local function copy_body()
  if not S.resp then
    return
  end
  util.copy(S.resp.body or "")
  util.notify("response body copied", vim.log.levels.INFO)
end

local function save_body()
  if not S.resp then
    return
  end
  local name = (S.req and S.req.name or "response"):gsub("[^%w%-_%.]+", "-"):lower()
  local default = vim.fs.joinpath(vim.fn.getcwd(), name .. ".json")
  vim.ui.input({ prompt = "Save response body to: ", default = default }, function(path)
    if not path or path == "" then
      return
    end
    local fd = io.open(path, "wb")
    if not fd then
      util.notify("cannot write " .. path, vim.log.levels.ERROR)
      return
    end
    fd:write(S.resp.body or "")
    fd:close()
    util.notify("saved " .. path, vim.log.levels.INFO)
  end)
end

local function keymaps(buf)
  local keys = config.get().keymaps
  local function map(lhs, fn, desc)
    if not lhs or lhs == "" then
      return
    end
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Bruno: " .. desc })
  end
  map(keys.run, rerun, "rerun request")
  map(keys.history, function()
    require("bruno.ui.picker").history()
  end, "history")
  map(keys.vars, function()
    require("bruno.ui.vars").show_variables(S.coll, S.req)
  end, "variables")
  map(keys.env, function()
    require("bruno.ui.picker").environments(S.coll)
  end, "environment")
  map("<localleader>p", function()
    S.pretty = not S.pretty
    render()
  end, "toggle pretty print")
  map("<localleader>H", function()
    S.headers = not S.headers
    render()
  end, "toggle headers")
  map("<localleader>y", copy_body, "copy body")
  map("<localleader>s", save_body, "save body")
  map("q", function()
    if valid_win(S.win) then
      vim.api.nvim_win_close(S.win, true)
    end
  end, "close")
end

--- Show a response in a split.
--- @param resp table
--- @param opts table|nil { req, coll, focus, from_history }
function M.show(resp, opts)
  opts = opts or {}
  S.resp = resp
  S.req = opts.req
  S.coll = opts.coll
  S.pretty = config.get().ui.response.pretty
  S.headers = config.get().ui.response.headers

  local origin = origin_window()
  if origin ~= vim.api.nvim_get_current_win() then
    vim.api.nvim_set_current_win(origin)
  end

  if not (valid_win(S.win) and valid_buf(S.buf)) then
    S.counter = S.counter + 1
    local position = config.get().ui.response.position
    local size = config.get().ui.response.size
    local buf, win = util.open_split({ position = position, size = size })
    S.buf = buf
    S.win = win
    vim.bo[buf].filetype = filetype_for(resp)
    vim.wo[win].wrap = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    keymaps(buf)
  end

  vim.api.nvim_win_set_buf(S.win, S.buf)
  render()

  if opts.focus or config.get().ui.response.focus then
    vim.api.nvim_set_current_win(S.win)
  end
end

--- Reopen the last response for a request path.
function M.open_last(path)
  local run = require("bruno.run")
  local resp = run.last_response(path)
  if not resp then
    util.notify("no response stored for this request", vim.log.levels.WARN)
    return
  end
  M.show(resp, { req = resp.request, coll = resp.request and resp.request.node and resp.request.node.collection })
end

function M.close()
  if valid_win(S.win) then
    vim.api.nvim_win_close(S.win, true)
  end
end

function M.current()
  return S.resp
end

return M
