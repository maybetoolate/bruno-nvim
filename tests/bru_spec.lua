return function(t)
  local bru = require("bruno.bru")

  t.describe("bru", function()
    t.it("parses a request file", function()
      local raw = bru.parse_file("tests/fixtures/bru/create.bru")
      t.eq(raw.info.name, "Create Legacy")
      t.eq(raw.http.method, "POST")
      t.eq(raw.http.url, "{{host}}/items")
      t.eq(raw.http.headers[1].name, "Content-Type")
      t.eq(raw.http.body.type, "json")
      t.contains(raw.http.body.data, '"legacy"')
      t.eq(raw.runtime.scripts[1].type, "post-response")
      t.contains(raw.runtime.scripts[1].code, "legacyStatus")
    end)

    t.it("parses query params and docs", function()
      local raw = bru.parse_file("tests/fixtures/bru/ping.bru")
      t.eq(raw.http.method, "GET")
      t.eq(#raw.http.params, 1)
      t.eq(raw.http.params[1].name, "q")
      t.eq(raw.http.params[1].type, "query")
      t.eq(raw.docs, "Legacy format smoke test.")
    end)

    t.it("parses environment files", function()
      local parsed = bru.parse_environment([[
vars {
  host: http://localhost:3000
  token: abc
}
]])
      t.eq(parsed.variables[1].name, "host")
      t.eq(parsed.variables[1].value, "http://localhost:3000")
      t.eq(parsed.variables[2].name, "token")
    end)

    t.it("parses disabled headers and settings", function()
      local raw = bru.parse([[
meta {
  name: Demo
  type: http
}

get {
  url: http://localhost
  body: none
}

headers {
  ~X-Off: 1
  X-On: 2
}

settings {
  encodeUrl: true
  timeout: 1500
}
]])
      t.eq(raw.http.headers[1].name, "X-Off")
      t.eq(raw.http.headers[1].disabled, true)
      t.eq(raw.http.headers[2].disabled, nil)
      t.eq(raw.settings.encodeUrl, true)
      t.eq(raw.settings.timeout, 1500)
    end)
  end)
end
