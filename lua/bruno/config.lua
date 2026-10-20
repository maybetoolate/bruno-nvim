local M = {}

--- @class BrunoConfig
M.defaults = {
  --- Collection root. When nil, the plugin walks up from the current buffer
  --- (or cwd) looking for `opencollection.yml` / `bruno.json`.
  collection = nil,
  --- Environment selected on startup. Falls back to the collection default and
  --- then the persisted selection.
  env = nil,

  keymaps = {
    run = "<leader>r",
    peek = "<leader>p",
    env = "<leader>e",
    vars = "<leader>v",
    history = "<leader>h",
    copy_curl = "<leader>c",
  },

  curl = {
    bin = "curl",
    --- Skip TLS verification (`-k`). Prefer per-collection config over this.
    insecure = false,
    --- Default timeout in milliseconds; 0 disables `--max-time`.
    timeout = 30000,
    extra_args = {},
  },

  scripts = {
    enabled = true,
    node = "node",
    timeout = 10000,
  },

  ui = {
    --- Width of the collection sidebar.
    width = 40,
    icons = true,
    winbar = true,
    response = {
      position = "below", -- "below" | "right"
      size = 0.35,
      pretty = true,
      headers = true,
      --- Keep the response window focused after a run.
      focus = false,
    },
  },

  variables = {
    --- What to do with `{{unknown}}`: "keep", "empty" or "error".
    missing = "keep",
    --- Persist `:BrunoVar` values per collection.
    persist = true,
  },

  history = {
    enabled = true,
    size = 50,
    --- Maximum response body bytes stored per entry.
    max_body = 64 * 1024,
  },

  oauth = {
    --- Reuse fetched OAuth2 access tokens until they expire.
    cache = true,
  },

  --- "auto" uses snacks.nvim when available and `vim.ui.select` otherwise.
  picker = "auto",
}

local options

--- @param opts table|nil
--- @return table
function M.setup(opts)
  options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return options
end

--- @return table
function M.get()
  if not options then
    M.setup()
  end
  return options
end

function M.reset()
  options = nil
end

return M
