if vim.g.loaded_bruno_nvim then
  return
end
vim.g.loaded_bruno_nvim = 1

vim.filetype.add({
  extension = {
    bru = "bruno",
  },
})

local function command(name, fn, opts)
  opts = opts or {}
  vim.api.nvim_create_user_command(name, fn, vim.tbl_extend("force", { force = true }, opts))
end

command("Bruno", function(args)
  require("bruno").open({ path = args.args ~= "" and args.args or nil })
end, { nargs = "?", desc = "Toggle the Bruno collection sidebar" })

command("BrunoOpen", function(args)
  require("bruno.ui.picker").requests(args.args ~= "" and require("bruno.collection").get({ path = args.args }) or nil)
end, { nargs = "?", desc = "Pick a Bruno request" })

command("BrunoRun", function(args)
  local path = args.args ~= "" and args.args or nil
  if path and vim.fn.filereadable(path) == 1 then
    path = vim.fn.fnamemodify(path, ":p")
  end
  require("bruno.run").run_target({ path = path })
end, { nargs = "?", desc = "Send the current Bruno request" })

command("BrunoEnv", function(args)
  require("bruno").env(args.args ~= "" and args.args or nil)
end, { nargs = "?", desc = "Select a Bruno environment" })

command("BrunoVar", function(args)
  require("bruno").var(args.args ~= "" and args.args or nil)
end, { nargs = "*", desc = "Set/list Bruno local variables" })

command("BrunoPeek", function()
  require("bruno").peek()
end, { desc = "Preview the resolved Bruno request" })

command("BrunoResponse", function()
  require("bruno").response()
end, { desc = "Show the last Bruno response" })

command("BrunoHistory", function()
  require("bruno").history()
end, { desc = "Browse Bruno response history" })

command("BrunoCurl", function()
  require("bruno").copy_curl()
end, { desc = "Copy the current Bruno request as curl" })

command("BrunoReload", function()
  require("bruno").reload()
end, { desc = "Reload Bruno collections" })

command("BrunoCancel", function()
  require("bruno.run").cancel_all()
  require("bruno.ui.util").notify("in-flight requests cancelled", vim.log.levels.WARN)
end, { desc = "Cancel in-flight Bruno requests" })

command("BrunoHelp", function()
  require("bruno").help()
end, { desc = "Show bruno-nvim keymaps" })

local group = vim.api.nvim_create_augroup("BrunoNvim", { clear = true })

vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = "bruno",
  callback = function()
    require("bruno.ui.request").attach_current()
  end,
})

vim.api.nvim_create_autocmd("BufReadPost", {
  group = group,
  pattern = { "*.yml", "*.yaml" },
  callback = function(args)
    local request = require("bruno.ui.request")
    if request.is_request(args.buf) then
      request.attach(args.buf)
    end
  end,
})

vim.api.nvim_create_autocmd("BufWritePost", {
  group = group,
  pattern = { "*.yml", "*.yaml", "*.bru" },
  callback = function(args)
    local path = vim.api.nvim_buf_get_name(args.buf)
    if path == "" then
      return
    end
    local request = require("bruno.ui.request")
    if request.is_request(args.buf) then
      request.attach(args.buf)
    end
    require("bruno.collection").invalidate(path)
    local tree = require("bruno.ui.tree")
    if tree.is_open() then
      tree.refresh()
    end
  end,
})

vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = function()
    require("bruno.ui.util").highlights()
  end,
})

require("bruno.ui.util").highlights()
