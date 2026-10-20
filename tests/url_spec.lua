return function(t)
  local url = require("bruno.url")
  local env = require("bruno.env")

  local function context(vars)
    return {
      scopes = { { name = "runtime", vars = vars } },
      env_vars = {},
      secrets = {},
      warnings = {},
      warned = {},
    }
  end

  t.describe("url", function()
    t.it("replaces path parameters and appends query parameters", function()
      local req = {
        url = "https://api.test/users/:id",
        params = {
          { name = "id", value = "42", type = "path" },
          { name = "expand", value = "orders,profile", type = "query" },
          { name = "skip", value = "1", type = "query", disabled = true },
        },
        settings = {},
      }
      local built = url.build(req, context({}))
      t.eq(built, "https://api.test/users/42?expand=orders%2Cprofile")
    end)

    t.it("uses & when the URL already has a query string", function()
      local req = {
        url = "https://api.test/search?q=x",
        params = { { name = "page", value = "2", type = "query" } },
        settings = {},
      }
      t.eq(url.build(req, context({})), "https://api.test/search?q=x&page=2")
    end)

    t.it("interpolates variables in URL and parameters", function()
      local req = {
        url = "{{host}}/users/:id",
        params = {
          { name = "id", value = "{{userId}}", type = "path" },
          { name = "token", value = "{{token}}", type = "query" },
        },
        settings = {},
      }
      local built = url.build(req, context({ host = "http://localhost:3000", userId = 7, token = "a b" }))
      t.eq(built, "http://localhost:3000/users/7?token=a%20b")
    end)

    t.it("does not encode when encodeUrl is false", function()
      local req = {
        url = "https://api.test/users",
        params = { { name = "q", value = "a,b", type = "query" } },
        settings = { encodeUrl = false },
      }
      t.eq(url.build(req, context({})), "https://api.test/users?q=a,b")
    end)

    t.it("replaces {name} path placeholders", function()
      local req = {
        url = "https://api.test/users/{id}",
        params = { { name = "id", value = "9", type = "path" } },
        settings = {},
      }
      t.eq(url.build(req, context({})), "https://api.test/users/9")
    end)

    t.it("appends query params for api keys", function()
      t.eq(url.with_query_param("https://x.test/a", "key", "v v", true), "https://x.test/a?key=v%20v")
    end)
  end)
end
