return function(t)
  local auth = require("bruno.auth")
  local collection = require("bruno.collection")
  local env = require("bruno.env")

  local coll = collection.load("tests/fixtures/oc", { force = true })
  local node = coll.requests[t.path("tests/fixtures/oc/users/get-user.yml")]

  local function context()
    return env.context(coll, node.request, { env = "Local" })
  end

  local function spec(url)
    return { url = url or "https://api.test/x", headers = {}, curl_args = {} }
  end

  local function header(spec_, name)
    for _, item in ipairs(spec_.headers) do
      if item.name:lower() == name:lower() then
        return item.value
      end
    end
  end

  t.describe("auth", function()
    t.it("resolves inherited auth from the folder chain", function()
      local resolved = auth.resolve(node.request)
      t.eq(resolved.type, "bearer")
      t.eq(resolved.token, "{{folderToken}}")
    end)

    t.it("applies bearer tokens", function()
      local s = spec()
      t.ok(auth.apply({ type = "bearer", token = "{{token}}" }, s, context()))
      t.eq(header(s, "Authorization"), "Bearer test-token")
    end)

    t.it("does not overwrite an explicit authorization header", function()
      local s = spec()
      s.headers[1] = { name = "Authorization", value = "Bearer explicit" }
      auth.apply({ type = "bearer", token = "other" }, s, context())
      t.eq(header(s, "Authorization"), "Bearer explicit")
    end)

    t.it("applies basic auth", function()
      local s = spec()
      auth.apply({ type = "basic", username = "user", password = "pass" }, s, context())
      t.eq(header(s, "Authorization"), "Basic " .. vim.base64.encode("user:pass"))
    end)

    t.it("applies api keys as query parameters", function()
      local s = spec("https://api.test/secure")
      auth.apply({ type = "apikey", key = "api_key", value = "{{token}}", placement = "query" }, s, context())
      t.eq(s.url, "https://api.test/secure?api_key=test-token")
      t.eq(header(s, "api_key"), nil)
    end)

    t.it("applies api keys as headers by default", function()
      local s = spec()
      auth.apply({ type = "apikey", key = "X-Key", value = "secret" }, s, context())
      t.eq(header(s, "X-Key"), "secret")
    end)

    t.it("adds digest flags for curl", function()
      local s = spec()
      auth.apply({ type = "digest", username = "u", password = "p" }, s, context())
      t.contains(s.curl_args, "--digest")
      t.contains(s.curl_args, "u:p")
    end)

    t.it("warns about unsupported auth", function()
      local s = spec()
      local ctx = context()
      auth.apply({ type = "aws-v4" }, s, ctx)
      t.contains(ctx.warnings, "aws-v4 auth is not supported yet; add the required headers manually")
    end)

    t.it("keeps the POST method when an oauth2 query parameter is added", function()
      local original = vim.system
      local captured
      vim.system = function(args)
        captured = args
        return {
          wait = function()
            return { code = 0, stdout = '{"access_token":"oauth-token","token_type":"Bearer"}' }
          end,
        }
      end
      local s = spec()
      local ctx = context()
      local ok = auth.apply({
        type = "oauth2",
        flow = "client_credentials",
        accessTokenUrl = "https://auth.test/token",
        credentials = { clientId = "client", clientSecret = "secret" },
        additionalParameters = {
          accessTokenRequest = { { name = "audience", value = "api", placement = "query" } },
        },
      }, s, ctx)
      vim.system = original

      t.ok(ok, "oauth2 auth should apply")
      t.eq(s.headers[1].value, "Bearer oauth-token")
      t.eq(captured[3], "-X")
      t.eq(captured[4], "POST")

      local urls = 0
      for _, arg in ipairs(captured) do
        if arg == "https://auth.test/token?audience=api" then
          urls = urls + 1
        end
      end
      t.eq(urls, 1)
    end)
  end)
end
