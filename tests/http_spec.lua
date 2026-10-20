return function(t)
  local http = require("bruno.http")
  local config = require("bruno.config")

  t.describe("http", function()
    t.it("prepares json bodies", function()
      local body = http.prepare_body({ type = "json", data = '{"a":1}' })
      t.eq(body.kind, "raw")
      t.eq(body.data, '{"a":1}')
      t.eq(body.content_type, "application/json")
    end)

    t.it("serializes table bodies", function()
      local body = http.prepare_body({ type = "json", data = { a = 1 } })
      t.eq(vim.json.decode(body.data).a, 1)
    end)

    t.it("builds graphql payloads", function()
      local body = http.prepare_body({
        type = "graphql",
        query = "query { me { id } }",
        variables = '{"x":1}',
      })
      local decoded = vim.json.decode(body.data)
      t.eq(decoded.query, "query { me { id } }")
      t.eq(decoded.variables.x, 1)
    end)

    t.it("prepares form and multipart bodies", function()
      local form = http.prepare_body({
        type = "form-urlencoded",
        data = { { name = "a", value = "1" }, { name = "skip", value = "x", disabled = true } },
      })
      t.eq(form.kind, "form")
      t.eq(#form.fields, 1)

      local multipart = http.prepare_body({
        type = "multipart-form",
        data = { { name = "file", value = "/tmp/x", type = "file" }, { name = "field", value = "v", type = "text" } },
      })
      t.eq(multipart.kind, "multipart")
      t.eq(#multipart.fields, 2)
    end)

    t.it("builds curl arguments with a body file", function()
      local spec = {
        method = "POST",
        url = "https://api.test/x",
        headers = { { name = "Content-Type", value = "application/json" } },
        body = { type = "json", data = '{"a":1}' },
      }
      local built = http.build_args(spec)
      t.contains(built.args, "--data-binary")
      t.contains(built.args, "Content-Type: application/json")
      t.eq(built.args[#built.args], "https://api.test/x")
      t.ok(built.files.input, "expected a body file")
      local fd = io.open(built.files.input, "rb")
      t.ok(fd, "body file should exist")
      t.eq(fd:read("*a"), '{"a":1}')
      fd:close()
      os.remove(built.files.input)
      os.remove(built.files.headers)
      os.remove(built.files.body)
    end)

    t.it("honours timeout and redirect settings", function()
      local built = http.build_args({
        method = "GET",
        url = "https://api.test/x",
        headers = {},
        timeout_ms = 1500,
        follow_redirects = false,
      })
      t.contains(built.args, "--max-time")
      t.contains(built.args, "1.500")
      t.not_ok(vim.tbl_contains(built.args, "--location"))
      os.remove(built.files.headers)
      os.remove(built.files.body)
    end)

    t.it("parses the last header block after redirects", function()
      local headers, _, status, reason = http.parse_headers(
        "HTTP/1.1 302 Found\r\nLocation: /next\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Test: yes\r\n\r\n"
      )
      t.eq(status, 200)
      t.eq(reason, "OK")
      t.eq(headers["content-type"], "application/json")
      t.eq(headers["x-test"], "yes")
    end)

    t.it("renders curl commands with safe quoting", function()
      local command = http.to_curl({
        method = "POST",
        url = "https://api.test/x",
        headers = { { name = "X-Test", value = "it's here" } },
        body = { type = "json", data = '{"a":1}' },
      })
      t.contains(command, "--request POST")
      t.contains(command, "'X-Test: it'\\''s here'")
      t.contains(command, "'Content-Type: application/json'")
      t.contains(command, "'{\"a\":1}'")
      t.eq(config.get().curl.bin, "curl")
    end)

    t.it("keeps auth curl flags in copied commands", function()
      local command = http.to_curl({
        method = "GET",
        url = "https://api.test/x",
        headers = {},
        curl_args = { "--digest", "--user", "u:p" },
      })
      t.contains(command, "--digest")
      t.contains(command, "'u:p'")
    end)

    t.it("reports an empty URL without spawning curl", function()
      local called = false
      http.send({ method = "GET", url = "", headers = {} }, function(response)
        called = true
        t.eq(response.error, "empty request URL")
      end)
      vim.wait(1000, function()
        return called
      end, 10)
      t.ok(called, "callback should run")
    end)
  end)
end
