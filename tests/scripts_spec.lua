return function(t)
  local scripts = require("bruno.scripts")

  if not scripts.available() then
    return
  end

  local function payload(extra)
    return vim.tbl_extend("force", {
      vars = { existing = "value" },
      env_vars = {},
      collection_vars = {},
      request = { url = "http://localhost/x", method = "GET", headers = {}, body = nil },
    }, extra or {})
  end

  t.describe("scripts", function()
    t.it("exposes bru.setVar to before-request scripts", function()
      local result = scripts.run({
        { type = "before-request", code = 'bru.setVar("added", "yes");' },
      }, payload(), { cwd = "." })
      t.ok(result.ok, result.error)
      t.eq(result.vars.added, "yes")
      t.eq(result.vars.existing, "value")
    end)

    t.it("collects passing tests", function()
      local result = scripts.run({
        {
          type = "tests",
          code = [[
test("status", function () { expect(200).to.equal(200); });
test("body", function () { expect({ a: 1 }.a).to.be.above(0); });
]],
        },
      }, payload(), { cwd = "." })
      t.ok(result.ok, result.error)
      t.eq(#result.tests, 2)
      t.eq(result.tests[1].passed, true)
      t.eq(result.tests[2].passed, true)
    end)

    t.it("records failing assertions", function()
      local result = scripts.run({
        { type = "tests", code = 'test("fails", function () { expect(1).to.equal(2); });' },
      }, payload(), { cwd = "." })
      t.eq(#result.tests, 1)
      t.eq(result.tests[1].passed, false)
      t.contains(result.tests[1].error, "expected 1 to equal 2")
    end)

    t.it("supports type assertions", function()
      local result = scripts.run({
        {
          type = "tests",
          code = [[
test("string", function () { expect("x").to.be.a("string"); });
test("object", function () { expect({}).to.be.an("object"); });
test("array", function () { expect([]).to.be.an("array"); });
test("negated", function () { expect("x").to.not.be.a("number"); });
]],
        },
      }, payload(), { cwd = "." })
      t.ok(result.ok, result.error)
      t.eq(#result.tests, 4)
      for _, item in ipairs(result.tests) do
        t.eq(item.passed, true, item.error)
      end
    end)

    t.it("gives scripts access to the parsed response", function()
      local result = scripts.run(
        {
          {
            type = "after-response",
            code = [[
bru.setVar("id", res.body.id);
bru.setVar("status", res.status);
]],
          },
        },
        payload({
          response = {
            status = 200,
            statusText = "OK",
            headers = { ["content-type"] = "application/json" },
            body = '{"id":"abc"}',
            contentType = "application/json",
            responseTime = 5,
          },
        }),
        { cwd = "." }
      )
      t.ok(result.ok, result.error)
      t.eq(result.vars.id, "abc")
      t.eq(result.vars.status, 200)
    end)

    t.it("captures console output", function()
      local result = scripts.run({
        { type = "before-request", code = 'console.log("hello", { a: 1 });' },
      }, payload(), { cwd = "." })
      t.eq(result.logs[1].message, 'hello {"a":1}')
    end)

    t.it("mutates the request", function()
      local result = scripts.run({
        {
          type = "before-request",
          code = 'req.setHeader("X-Added", "1"); req.setUrl("http://localhost/y");',
        },
      }, payload(), { cwd = "." })
      t.ok(result.ok, result.error)
      t.eq(result.request.headers["X-Added"], "1")
      t.eq(result.request.url, "http://localhost/y")
    end)
  end)
end
