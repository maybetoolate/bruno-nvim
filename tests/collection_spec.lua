return function(t)
  local collection = require("bruno.collection")

  t.describe("collection", function()
    t.it("loads an OpenCollection tree", function()
      local coll, err = collection.load("tests/fixtures/oc", { force = true })
      t.ok(coll, err)
      t.eq(coll.name, "Fixture API")
      t.eq(coll.kind, "opencollection")
      t.eq(#coll.children, 3)
      t.eq(coll.children[1].type, "folder")
      t.eq(coll.children[1].name, "Users")
      t.eq(#coll.children[1].children, 2)
      t.eq(coll.children[1].children[1].name, "Create User")
      t.eq(coll.children[1].children[1].method, "POST")
      t.eq(coll.children[1].children[2].name, "Get User")
      t.eq(#coll.warnings, 0)
    end)

    t.it("merges folder headers and auth into requests", function()
      local coll = collection.load("tests/fixtures/oc", { force = true })
      local node = coll.requests[t.path("tests/fixtures/oc/users/get-user.yml")]
      local req = node.request
      local names = {}
      for _, header in ipairs(req.headers) do
        names[header.name] = header.value
      end
      t.eq(names["X-Folder"], "users")
      t.eq(req.auth, "inherit")
      t.eq(node.defaults.auth.type, "bearer")
      t.eq(node.defaults.auth.token, "{{folderToken}}")
    end)

    t.it("orders requests by seq", function()
      local coll = collection.load("tests/fixtures/oc", { force = true })
      local users = coll.children[1]
      t.eq(users.children[1].name, "Create User")
      t.eq(users.children[2].name, "Get User")
    end)

    t.it("counts requests recursively", function()
      local coll = collection.load("tests/fixtures/oc", { force = true })
      t.eq(collection.count_requests(coll.tree), 4)
    end)

    t.it("indexes every request by path", function()
      local coll = collection.load("tests/fixtures/oc", { force = true })
      t.eq(vim.tbl_count(coll.requests), 4)
      t.ok(coll.requests[t.path("tests/fixtures/oc/scripts.yml")], "scripts.yml should be indexed")
    end)

    t.it("flattens requests with their folder trail", function()
      local coll = collection.load("tests/fixtures/oc", { force = true })
      local flat = collection.flat_requests(coll)
      local users
      for _, item in ipairs(flat) do
        if item.name == "Get User" then
          users = item
        end
      end
      t.ok(users, "Get User missing from flat list")
      t.eq(users.trail[1], "Users")
    end)

    t.it("loads a legacy .bru collection", function()
      local coll, err = collection.load("tests/fixtures/bru", { force = true })
      t.ok(coll, err)
      t.eq(coll.name, "Legacy API")
      t.eq(coll.kind, "bru")
      t.eq(#coll.children, 2)

      local ping = coll.requests[t.path("tests/fixtures/bru/ping.bru")]
      t.ok(ping, "ping.bru missing")
      t.eq(ping.method, "GET")
      t.eq(ping.request.url, "{{host}}/ping")

      local headers = {}
      for _, header in ipairs(ping.request.headers) do
        headers[header.name] = header.value
      end
      t.eq(headers.Accept, "application/json")
      t.eq(headers["X-Collection"], "legacy")
      t.eq(ping.request.auth, "inherit")
      t.eq(ping.request.node.defaults.auth.type, "bearer")

      local create = coll.requests[t.path("tests/fixtures/bru/create.bru")]
      t.eq(create.method, "POST")
      t.eq(create.request.body.type, "json")
      t.eq(#create.request.scripts, 1)
    end)

    t.it("finds the collection root from a nested file", function()
      local root = collection.find_root("tests/fixtures/oc/users/get-user.yml")
      t.eq(root, vim.fs.normalize(vim.fn.fnamemodify("tests/fixtures/oc", ":p")))
    end)
  end)
end
