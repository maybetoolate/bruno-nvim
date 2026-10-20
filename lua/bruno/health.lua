--- :checkhealth bruno
local M = {}

local config = require("bruno.config")

local function ok(message)
  vim.health.ok(message)
end

local function warn(message)
  vim.health.warn(message)
end

local function error(message)
  vim.health.error(message)
end

local function info(message)
  vim.health.info(message)
end

function M.check()
  vim.health.start("bruno-nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    ok("Neovim " .. tostring(vim.version()))
  else
    error("Neovim 0.10 or newer is required (found " .. tostring(vim.version()) .. ")")
  end

  local conf = config.get()
  local curl = conf.curl.bin
  if vim.fn.executable(curl) == 1 then
    local version = vim.fn.system({ curl, "--version" })
    local text = (version or ""):match("^[^\n]*") or curl
    ok(("curl found: %s"):format(text))
    -- `--write-out %{json}` (timing/size metadata) needs curl >= 7.75.
    local major, minor = text:match("^curl%s+(%d+)%.(%d+)")
    if major and (tonumber(major) < 7 or (tonumber(major) == 7 and tonumber(minor) < 75)) then
      warn("curl < 7.75: response timing/size metadata is unavailable; received data still works")
    end
  else
    error(("curl executable not found (%q); requests cannot be sent"):format(curl))
  end

  if vim.fn.executable(conf.scripts.node) == 1 then
    local version = vim.trim(vim.fn.system({ conf.scripts.node, "--version" }) or "")
    ok(("node found: %s"):format(version))
  else
    warn("node not found; pre-request/after-response scripts and tests will be skipped")
  end

  if conf.scripts.enabled == false then
    warn("scripts are disabled in config")
  end

  local collection = require("bruno.collection")
  local root, kind = collection.find_root(vim.fn.getcwd())
  if not root and vim.api.nvim_buf_get_name(0) ~= "" then
    root, kind = collection.find_root(vim.api.nvim_buf_get_name(0))
  end

  if root then
    local coll, err = collection.load(root)
    if coll then
      ok(("collection: %s (%s, %s)"):format(coll.name, coll.kind, root))
      info(("%d request(s), %d folder(s)"):format(vim.tbl_count(coll.requests or {}), #(coll.children or {})))
      local environments = require("bruno.env").load_environments(coll)
      if #environments > 0 then
        ok(("%d environment(s): %s"):format(
          #environments,
          table.concat(
            vim.tbl_map(function(environment)
              return environment.name
            end, environments),
            ", "
          )
        ))
      else
        info("no environments found (optional; create environments/<name>.yml)")
      end
      if #coll.warnings > 0 then
        warn(table.concat(coll.warnings, "\n"))
      end
    else
      error("collection failed to load: " .. tostring(err))
    end
  else
    warn("no collection found from the current directory; set `collection` in setup() or open a file inside one")
  end

  if conf.variables.missing == "keep" then
    info('unresolved {{variables}} are left in place (config.variables.missing = "keep")')
  end

  if vim.fn.exists(":CheckHealth") == 1 then
    info("run :checkhealth bruno")
  end
end

return M
