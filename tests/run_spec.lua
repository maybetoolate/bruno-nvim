return function(t)
  local collection = require("bruno.collection")
  local run = require("bruno.run")

  local uv = vim.uv or vim.loop

  local function start_server()
    local server = assert(uv.new_tcp())
    assert(server:bind("127.0.0.1", 0))
    local port = server:getsockname().port
    local captured = {}

    assert(server:listen(128, function(err)
      if err then
        return
      end
      local client = uv.new_tcp()
      server:accept(client)
      local data = ""
      client:read_start(function(read_err, chunk)
        if read_err or not chunk then
          return
        end
        data = data .. chunk
        local header_end = data:find("\r\n\r\n", 1, true)
        if not header_end then
          return
        end
        local length = tonumber(data:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
        if #data < header_end + 3 + length then
          return
        end

        local head = data:sub(1, header_end - 1)
        local request_line = head:match("^[^\r\n]+") or ""
        local method, path = request_line:match("^(%S+)%s+(%S+)")
        local headers = {}
        for name, value in head:gmatch("\r\n([^:]+):%s*([^\r\n]+)") do
          headers[name:lower()] = value
        end
        captured[#captured + 1] = {
          method = method,
          path = path,
          headers = headers,
          body = data:sub(header_end + 4),
        }

        local body = path:find("/echo", 1, true) and '{"id":"abc"}' or '{"ok":true}'
        local response = ("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"):format(
          #body,
          body
        )
        client:read_stop()
        client:write(response, function()
          client:close()
        end)
      end)
    end))

    return {
      port = port,
      captured = captured,
      close = function()
        pcall(function()
          server:close()
        end)
      end,
    }
  end

  t.describe("run", function()
    local coll = collection.load("tests/fixtures/oc", { force = true })
    t.ok(coll, "fixture collection should load")

    local server = start_server()
    local host = "http://127.0.0.1:" .. server.port
    run.set_var(coll.root, "host", host)

    local function request(path)
      local node = coll.requests[t.path("tests/fixtures/oc/" .. path)]
      t.ok(node, "missing fixture request: " .. path)
      return node.request
    end

    t.it("builds interpolated URLs and inherited auth", function()
      local prepared, err = run.prepare(request("users/get-user.yml"), { env = "Local" })
      t.ok(prepared, err)
      t.eq(prepared.spec.url, host .. "/users/42?expand=orders%2Cprofile")
      t.eq(prepared.spec.method, "GET")
      t.eq(prepared.spec.timeout_ms, 2000)
      t.eq(prepared.spec.follow_redirects, false)

      local authorization
      for _, header in ipairs(prepared.spec.headers) do
        if header.name:lower() == "authorization" then
          authorization = header.value
        end
      end
      t.eq(authorization, "Bearer folder-token")
    end)

    t.it("interpolates JSON bodies", function()
      local prepared = run.prepare(request("users/create-user.yml"), { env = "Local" })
      local body = vim.json.decode(prepared.spec.body.data)
      t.eq(body.name, "Ada")
      t.eq(body.token, "test-token")
    end)

    t.it("sends a request and parses the response", function()
      local done = false
      local response
      local handle = run.run(request("users/create-user.yml"), {
        env = "Local",
        silent = true,
        on_done = function(res)
          response = res
          done = true
        end,
      })
      t.ok(handle, "run should return a handle")
      vim.wait(5000, function()
        return done
      end, 10)
      t.ok(done, "response callback should fire")
      t.eq(response.status, 200)
      t.eq(response.content_type, "application/json")
      t.ok(response.ok)
      t.eq(vim.json.decode(response.body).ok, true)
      t.ok(#server.captured > 0, "server should capture the request")
      local last = server.captured[#server.captured]
      t.eq(last.method, "POST")
      t.eq(last.headers.authorization, "Bearer folder-token")
    end)

    t.it("runs before/after scripts and tests end to end", function()
      local done = false
      local response
      run.run(request("scripts.yml"), {
        env = "Local",
        silent = true,
        on_done = function(res)
          response = res
          done = true
        end,
      })
      vim.wait(8000, function()
        return done
      end, 10)
      t.ok(done, "response callback should fire")
      t.eq(response.status, 200)
      t.eq(#response.tests, 2)
      t.eq(response.tests[1].passed, true)
      t.eq(response.tests[2].passed, true)
      t.eq(run.runtime(coll.root).requestVar, "hello")
      t.eq(run.runtime(coll.root).responseId, "abc")

      local last = server.captured[#server.captured]
      local body = vim.json.decode(last.body)
      t.eq(body.greeting, "hello")
    end)

    t.it("applies api key auth to the query string", function()
      local prepared = run.prepare(request("auth-apikey.yml"), { env = "Local" })
      t.eq(prepared.spec.url, host .. "/secure?api_key=test-token")

      local done = false
      local response
      run.run(request("auth-apikey.yml"), {
        env = "Local",
        silent = true,
        on_done = function(res)
          response = res
          done = true
        end,
      })
      vim.wait(5000, function()
        return done
      end, 10)
      t.eq(response.status, 200)
      t.contains(server.captured[#server.captured].path, "api_key=test-token")
    end)

    t.it("reports unresolved variables as warnings", function()
      local prepared = run.prepare(request("users/create-user.yml"), { env = "none" })
      t.ok(prepared, "request should still prepare with missing variables")
      t.contains(prepared.ctx.warnings, "missing variable {{token}}")
    end)

    t.it("previews without touching the network", function()
      local prepared = run.preview(request("users/get-user.yml"), { env = "Local" })
      t.ok(prepared)
      t.eq(prepared.spec.url, host .. "/users/42?expand=orders%2Cprofile")
    end)

    t.it("lists variables and unset secrets", function()
      local rows = run.list_variables(coll, request("users/get-user.yml"), { env = "Local" })
      local by_name = {}
      for _, row in ipairs(rows) do
        by_name[row.name] = row
      end
      t.eq(by_name.folderToken.value, "********")
      t.eq(by_name.folderToken.secret, true)
      t.eq(by_name.emptySecret.value, "(not set)")
      t.eq(by_name.emptySecret.secret, true)
    end)

    server.close()
  end)
end
