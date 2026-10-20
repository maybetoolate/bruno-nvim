return function(t)
  local env = require("bruno.env")
  local collection = require("bruno.collection")

  t.describe("env", function()
    local coll = collection.load("tests/fixtures/oc", { force = true })
    t.ok(coll, "fixture collection should load")

    local node = coll.requests[t.path("tests/fixtures/oc/users/get-user.yml")]
    t.ok(node, "get-user fixture should be indexed")

    t.it("loads environments and their variables", function()
      local list = env.load_environments(coll)
      local names = {}
      for _, item in ipairs(list) do
        names[item.name] = item
      end
      t.ok(names.Local, "Local environment missing")
      t.eq(names.Local.vars.host, "http://127.0.0.1:8123")
      t.eq(names.Local.vars.disabledVar, nil)
      t.eq(names.Local.secrets.emptySecret, true)
      t.eq(names.Local.secrets.folderToken, true)
    end)

    t.it("flattens extends chains", function()
      local list = env.load_environments(coll)
      local child
      for _, item in ipairs(list) do
        if item.name == "Child" then
          child = item
        end
      end
      local vars = env.flatten_environment(list, child)
      t.eq(vars.inherited, "from-parent")
      t.eq(vars.own, "from-child")
    end)

    t.it("selects the local environment by default", function()
      t.eq(env.active_name(coll), "Local")
    end)

    t.it("interpolates variables from the environment", function()
      local ctx = env.context(coll, node.request, { env = "Local" })
      t.eq(env.interpolate("{{host}}/users", ctx), "http://127.0.0.1:8123/users")
      t.eq(env.interpolate("Bearer {{token}}", ctx), "Bearer test-token")
      t.eq(#ctx.warnings, 0)
    end)

    t.it("gives runtime variables the highest priority", function()
      local ctx = env.context(coll, node.request, { env = "Local", runtime = { host = "http://runtime" } })
      t.eq(env.interpolate("{{host}}", ctx), "http://runtime")
    end)

    t.it("gives the environment priority over collection variables", function()
      local fake = {
        root = coll.root,
        name = coll.name,
        defaults = { variables = { { name = "host", value = "http://collection" } } },
      }
      local ctx = env.context(fake, node.request, { env = "Local" })
      t.eq(env.interpolate("{{host}}", ctx), "http://127.0.0.1:8123")
      local ctx_none = env.context(fake, node.request, { env = "none" })
      t.eq(env.interpolate("{{host}}", ctx_none), "http://collection")
    end)

    t.it("keeps unresolved variables and records a warning", function()
      local ctx = env.context(coll, node.request, { env = "Local" })
      t.eq(env.interpolate("{{nope}}", ctx), "{{nope}}")
      t.contains(ctx.warnings, "missing variable {{nope}}")
    end)

    t.it("resolves dynamic variables", function()
      local ctx = env.context(coll, node.request, { env = "Local" })
      local guid = env.interpolate("{{$guid}}", ctx)
      t.matches(guid, "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
      t.matches(env.interpolate("{{$timestamp}}", ctx), "^%d+$")
      t.matches(env.interpolate("{{$isoTimestamp}}", ctx), "^%d%d%d%d%-%d%d%-%d%dT")
    end)

    t.it("resolves process.env explicitly", function()
      local ctx = env.context(coll, node.request, { env = "Local" })
      vim.env.BRUNO_NVIM_TEST = "from-process"
      t.eq(env.interpolate("{{process.env.BRUNO_NVIM_TEST}}", ctx), "from-process")
      vim.env.BRUNO_NVIM_TEST = nil
    end)

    t.it("parses dotenv files", function()
      local parsed = env.parse_dotenv([[
# comment
export HOST=http://localhost
TOKEN="abc def"
PLAIN=value
]])
      t.eq(parsed.HOST, "http://localhost")
      t.eq(parsed.TOKEN, "abc def")
      t.eq(parsed.PLAIN, "value")
    end)
  end)
end
