--- Small read-only panels: variables, request preview and help.
local M = {}

local collection = require("bruno.collection")
local config = require("bruno.config")
local env = require("bruno.env")
local run = require("bruno.run")
local util = require("bruno.ui.util")

local function resolve_request(coll, req, opts)
  if req then
    return coll, req
  end
  local target_coll, _, target_req = run.target(opts)
  coll = coll or target_coll
  req = target_req
  if not coll then
    coll = collection.get(opts)
  end
  return coll, req
end

--- Show resolved variables for the current (or given) request.
--- @param coll table|nil
--- @param req table|nil
--- @param opts table|nil
function M.show_variables(coll, req, opts)
  opts = opts or {}
  coll, req = resolve_request(coll, req, opts)
  if not coll then
    util.notify("collection not found", vim.log.levels.ERROR)
    return
  end

  if not req then
    req = {
      name = coll.name,
      url = "",
      variables = {},
      node = { defaults = coll.defaults },
    }
  end

  local rows, ctx = run.list_variables(coll, req, opts)
  local lines = {
    (" %s · %s"):format(coll.name, ctx.env or "no environment"),
    "",
    (" %-26s %-12s %s"):format("NAME", "SCOPE", "VALUE"),
  }
  local highlights = {
    { 0, 1, #lines[1], "BrunoTreeCollection" },
  }

  for _, row in ipairs(rows) do
    local value = util.truncate(row.value, math.max(20, vim.o.columns - 60))
    lines[#lines + 1] = (" %-26s %-12s %s"):format(util.truncate(row.name, 25), row.scope, value)
    local line = #lines - 1
    highlights[#highlights + 1] = { line, 1, 1 + #util.truncate(row.name, 25), "Normal" }
    highlights[#highlights + 1] = { line, 28, 28 + #row.scope, "BrunoVarScope" }
    if row.secret then
      highlights[#highlights + 1] = { line, 41, #lines[#lines], "BrunoVarSecret" }
    end
    if row.scope == "runtime" then
      highlights[#highlights + 1] = { line, 41, #lines[#lines], "BrunoMethodGet" }
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = " :BrunoVar name=value  set a local variable   :BrunoVar -u name  remove"

  util.float({
    title = " Variables ",
    lines = lines,
    width = math.min(math.max(70, vim.o.columns - 20), 140),
    height = math.min(#lines, math.floor(vim.o.lines * 0.7)),
    highlights = highlights,
    wrap = false,
    footer = " q close ",
  })
end

--- Show the request exactly as it will be sent (without executing it).
--- @param req table|nil
--- @param opts table|nil
function M.show_preview(req, opts)
  opts = opts or {}
  local coll, target = resolve_request(nil, req, opts)
  if not target then
    util.notify("no request in the current buffer", vim.log.levels.WARN)
    return
  end

  local prepared, err = run.preview(target, opts)
  if not prepared then
    util.notify(err or "cannot build request", vim.log.levels.ERROR)
    return
  end

  local spec = prepared.spec
  local lines = {
    (" %s %s"):format(spec.method, spec.url),
    (" environment: %s"):format(prepared.ctx.env or "none"),
    "",
  }
  local highlights = {
    { 0, 1, 1 + #spec.method, util.method_hl(spec.method) },
    { 1, 0, #lines[2], "BrunoResponseHeader" },
  }

  local function section(title)
    lines[#lines + 1] = title
    highlights[#highlights + 1] = { #lines - 1, 0, #title, "Title" }
  end

  section("Headers")
  for _, header in ipairs(spec.headers or {}) do
    lines[#lines + 1] = ("  %s: %s"):format(header.name, header.value)
  end
  if #(spec.headers or {}) == 0 then
    lines[#lines + 1] = "  (none)"
  end

  if spec.body then
    local body = require("bruno.http").prepare_body(spec.body)
    section("Body")
    if body and body.kind == "raw" then
      local pretty = util.pretty_body(body.data, body.content_type)
      for _, line in ipairs(util.split_lines(pretty)) do
        lines[#lines + 1] = "  " .. line
      end
    elseif body then
      lines[#lines + 1] = ("  (%s body)"):format(body.kind)
    end
  end

  if #prepared.ctx.warnings > 0 then
    section("Warnings")
    for _, warning in ipairs(prepared.ctx.warnings) do
      lines[#lines + 1] = "  " .. warning
    end
  end

  util.float({
    title = " Request preview ",
    lines = lines,
    width = math.min(math.max(70, vim.o.columns - 20), 140),
    height = math.min(#lines, math.floor(vim.o.lines * 0.7)),
    highlights = highlights,
    wrap = false,
    footer = " q close ",
  })
end

--- Keymap/command cheatsheet.
function M.help()
  local keys = config.get().keymaps
  local lines = {
    " bruno-nvim",
    "",
    " Commands",
    "   :Bruno [path]           toggle the collection sidebar",
    "   :BrunoOpen              pick a request",
    "   :BrunoRun [path]        send the current request",
    "   :BrunoCurl              copy the current request as curl",
    "   :BrunoEnv [name]        show / select environment",
    "   :BrunoVar [name=value]  show / set a local variable",
    "   :BrunoPeek              preview the resolved request",
    "   :BrunoResponse          show the last response",
    "   :BrunoHistory           browse recent responses",
    "   :BrunoReload            reload the collection",
    "   :BrunoCancel            abort in-flight requests",
    "",
    " Sidebar",
    "   <CR> open / fold    o fold    R run    r reload",
    "   e environment       v variables    y copy as curl",
    "",
    " Request buffer",
    ("   %-18s run request"):format(keys.run),
    ("   %-18s preview request"):format(keys.peek),
    ("   %-18s select environment"):format(keys.env),
    ("   %-18s variables"):format(keys.vars),
    ("   %-18s response history"):format(keys.history),
    ("   %-18s copy as curl"):format(keys.copy_curl),
    "",
    " Response window",
    "   q close   <leader>p pretty   <leader>H headers",
    "   <leader>y copy body   <leader>s save body",
  }

  util.float({
    title = " bruno-nvim help ",
    lines = lines,
    width = 80,
    height = math.min(#lines, math.floor(vim.o.lines * 0.85)),
    wrap = false,
    footer = " q close ",
  })
end

return M
