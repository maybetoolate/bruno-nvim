-- Headless test runner: nvim --headless --clean -l tests/run.lua
local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
package.path = root .. "/tests/?.lua;" .. package.path

require("bruno").setup({
  variables = { persist = false },
  history = { enabled = false },
})

local helpers = require("helpers")

for _, spec in ipairs({
  "yaml_spec",
  "bru_spec",
  "env_spec",
  "url_spec",
  "collection_spec",
  "auth_spec",
  "http_spec",
  "scripts_spec",
  "run_spec",
  "ui_spec",
}) do
  local ok, module = pcall(require, spec)
  if not ok then
    io.stderr:write(("FAIL could not load %s: %s\n"):format(spec, tostring(module)))
    helpers.failed = helpers.failed + 1
    helpers.failures[#helpers.failures + 1] = spec .. ": " .. tostring(module)
  else
    local ran, err = pcall(module, helpers)
    if not ran then
      helpers.failed = helpers.failed + 1
      helpers.failures[#helpers.failures + 1] = spec .. " crashed: " .. tostring(err)
    end
  end
end

local ok = helpers.report()
vim.cmd(ok and "qa!" or "cq!")
