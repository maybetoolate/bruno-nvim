--- Shared UI helpers: scratch buffers, windows, floats and formatting.
local M = {}

local config = require("bruno.config")

local ns = vim.api.nvim_create_namespace("bruno-ui")

M.ns = ns

local white = 0xFFFFFF

--- Define the plugin's highlight groups (linked to theme defaults).
function M.highlights()
  local groups = {
    BrunoTreeCollection = { link = "Title" },
    BrunoTreeFolder = { link = "Directory" },
    BrunoTreeCount = { link = "Comment" },
    BrunoTreeCursor = { link = "CursorLine" },
    BrunoMethodGet = { fg = "#98c379", bold = true },
    BrunoMethodPost = { fg = "#61afef", bold = true },
    BrunoMethodPut = { fg = "#e5c07b", bold = true },
    BrunoMethodPatch = { fg = "#c678dd", bold = true },
    BrunoMethodDelete = { fg = "#e06c75", bold = true },
    BrunoMethodHead = { fg = "#56b6c2", bold = true },
    BrunoMethodOptions = { fg = "#56b6c2", bold = true },
    BrunoMethodOther = { link = "Comment" },
    BrunoStatus2xx = { fg = "#98c379", bold = true },
    BrunoStatus3xx = { fg = "#e5c07b", bold = true },
    BrunoStatus4xx = { fg = "#e06c75", bold = true },
    BrunoStatus5xx = { fg = "#e06c75", bold = true },
    BrunoStatusError = { link = "ErrorMsg" },
    BrunoResponseHeader = { link = "Comment" },
    BrunoTestPass = { fg = "#98c379" },
    BrunoTestFail = { fg = "#e06c75", bold = true },
    BrunoVarScope = { link = "Comment" },
    BrunoVarSecret = { link = "DiagnosticWarn" },
  }
  for name, spec in pairs(groups) do
    if spec.link then
      vim.api.nvim_set_hl(0, name, { link = spec.link, default = true })
    else
      vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = true }, spec))
    end
  end
end

function M.method_hl(method)
  local known = { GET = true, POST = true, PUT = true, PATCH = true, DELETE = true, HEAD = true, OPTIONS = true }
  if known[(method or ""):upper()] then
    return "BrunoMethod" .. (method or ""):upper()
  end
  return "BrunoMethodOther"
end

function M.status_hl(status)
  if not status or status == 0 then
    return "BrunoStatusError"
  end
  local class = math.floor(status / 100)
  if class == 2 then
    return "BrunoStatus2xx"
  elseif class == 3 then
    return "BrunoStatus3xx"
  elseif class == 4 then
    return "BrunoStatus4xx"
  end
  return "BrunoStatus5xx"
end

--- Create an unlisted scratch buffer.
--- @param opts table|nil { name, filetype, modifiable }
--- @return number bufnr
function M.scratch(opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end
  if opts.name then
    pcall(vim.api.nvim_buf_set_name, buf, opts.name)
  end
  return buf
end

--- Replace a buffer's contents without leaving it in a modified state.
function M.set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function M.get_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Open a split and return its buffer and window.
--- @param opts table { position = "below"|"right"|"left"|"above", size = number }
--- @return number bufnr, number win
function M.open_split(opts)
  opts = opts or {}
  local position = opts.position or "below"
  local size = opts.size or 0.35

  local cmd
  if position == "right" then
    cmd = "botright vsplit"
  elseif position == "left" then
    cmd = "topleft vsplit"
  elseif position == "above" then
    cmd = "topleft split"
  else
    cmd = "botright split"
  end

  vim.cmd(cmd)
  local win = vim.api.nvim_get_current_win()
  if position == "right" or position == "left" then
    vim.api.nvim_win_set_width(win, math.max(20, math.floor(vim.o.columns * size)))
  else
    vim.api.nvim_win_set_height(win, math.max(5, math.floor(vim.o.lines * size)))
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  return buf, win
end

--- Open a centered floating window.
--- @param opts table { title, lines, filetype, width, height, highlights, keymaps }
--- @return number bufnr, number win
function M.float(opts)
  opts = opts or {}
  local lines = opts.lines or { "" }
  if #lines == 0 then
    lines = { "" }
  end

  local max_width = math.max(20, vim.o.columns - 4)
  local width = math.min(opts.width or math.floor(vim.o.columns * 0.8), max_width)
  local height = math.min(opts.height or math.min(#lines, math.floor(vim.o.lines * 0.7)), math.max(3, vim.o.lines - 4))

  local buf = M.scratch({ filetype = opts.filetype or "text", name = opts.name })
  M.set_lines(buf, lines)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = opts.title,
    title_pos = opts.title and "center" or nil,
    footer = opts.footer,
    footer_pos = opts.footer and "center" or nil,
  })

  vim.wo[win].wrap = opts.wrap ~= false
  vim.wo[win].cursorline = false

  for _, hl in ipairs(opts.highlights or {}) do
    local line = hl[1]
    local start = hl[2]
    local end_col = hl[3]
    if line >= 0 and line < #lines then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, start, {
        end_col = end_col,
        hl_group = hl[4],
      })
    end
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  for lhs, rhs in pairs(opts.keymaps or {}) do
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, silent = true })

  return buf, win
end

--- Set the winbar of a window with highlight groups.
--- @param win number
--- @param chunks table[] { text, hl }
function M.winbar(win, chunks)
  if not config.get().ui.winbar or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local parts = {}
  for _, chunk in ipairs(chunks or {}) do
    local text = tostring(chunk[1] or ""):gsub("%%", "%%%%")
    if chunk[2] then
      parts[#parts + 1] = "%#" .. chunk[2] .. "#" .. text
    else
      parts[#parts + 1] = text
    end
  end
  vim.wo[win].winbar = table.concat(parts)
end

--- Pretty-print a decoded JSON value.
--- @param value any
--- @param level number|nil
--- @return string
function M.format_json(value, level)
  level = level or 0
  local pad = string.rep("  ", level)

  if value == vim.NIL then
    return "null"
  end

  if type(value) == "table" then
    if vim.islist(value) then
      if #value == 0 then
        return "[]"
      end
      local parts = {}
      for _, item in ipairs(value) do
        parts[#parts + 1] = pad .. "  " .. M.format_json(item, level + 1)
      end
      return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
    end
    local keys = vim.tbl_keys(value)
    if #keys == 0 then
      return "{}"
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, key in ipairs(keys) do
      parts[#parts + 1] = pad .. "  " .. vim.json.encode(tostring(key)) .. ": " .. M.format_json(value[key], level + 1)
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
  end

  local ok, encoded = pcall(vim.json.encode, value)
  return ok and encoded or tostring(value)
end

--- Pretty-print a JSON body when possible; otherwise return the raw body.
--- @param body string
--- @param content_type string|nil
--- @return string text
--- @return boolean is_json
function M.pretty_body(body, content_type)
  body = body or ""
  local looks_json = (content_type or ""):find("json", 1, true) or body:match("^%s*{") or body:match("^%s*%[")
  if not looks_json then
    return body, false
  end
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok then
    return body, false
  end
  return M.format_json(decoded), true
end

--- Human readable byte size.
function M.human_size(bytes)
  bytes = tonumber(bytes) or 0
  if bytes < 1024 then
    return ("%d B"):format(bytes)
  elseif bytes < 1024 * 1024 then
    return ("%.1f KB"):format(bytes / 1024)
  end
  return ("%.1f MB"):format(bytes / (1024 * 1024))
end

function M.truncate(text, width)
  if #text <= width then
    return text
  end
  return text:sub(1, math.max(0, width - 1)) .. "…"
end

--- Split a multiline string into lines, trimming a trailing newline.
function M.split_lines(text)
  if not text or text == "" then
    return {}
  end
  text = text:gsub("\r\n", "\n")
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

function M.icon(name)
  if not config.get().ui.icons then
    return ""
  end
  if vim.g.have_nerd_font then
    return ({ folder = "󰉋", request = "󰈈" })[name] or ""
  end
  return ""
end

function M.notify(message, level)
  vim.notify("bruno: " .. message, level or vim.log.levels.INFO)
end

--- Copy text to the system clipboard, falling back to the unnamed register.
--- @param text string
--- @return boolean
function M.copy(text)
  if pcall(vim.fn.setreg, "+", text) then
    return true
  end
  return pcall(vim.fn.setreg, '"', text)
end

M.white = white

return M
