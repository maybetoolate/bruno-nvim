if vim.b.did_bruno_ftplugin then
  return
end
vim.b.did_bruno_ftplugin = true

vim.bo.commentstring = "# %s"

require("bruno.ui.request").attach_current()
