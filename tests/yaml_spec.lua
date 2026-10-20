return function(t)
  local yaml = require("bruno.yaml")

  t.describe("yaml", function()
    t.it("parses nested mappings and sequences", function()
      local doc = yaml.decode([[
opencollection: 1.0.0
info:
  name: Demo
  version: "1.0.0"
items:
  - info:
      name: One
      type: http
    http:
      method: GET
      url: https://example.com/one
  - info:
      name: Two
      type: http
]])
      t.eq(doc.opencollection, "1.0.0")
      t.eq(doc.info.name, "Demo")
      t.eq(doc.info.version, "1.0.0")
      t.eq(#doc.items, 2)
      t.eq(doc.items[1].http.method, "GET")
      t.eq(doc.items[1].info.name, "One")
      t.eq(doc.items[2].info.name, "Two")
    end)

    t.it("keeps block scalars intact and applies chomping", function()
      local doc = yaml.decode([[
literal: |-
  line one
  line two
clip: |
  a
folded: >-
  hello
  world
]])
      t.eq(doc.literal, "line one\nline two")
      t.eq(doc.clip, "a\n")
      t.eq(doc.folded, "hello world")
    end)

    t.it("parses flow collections and quoted values", function()
      local doc = yaml.decode([[
tags: [one, "two three", 4]
meta: {a: 1, b: "x", nested: [true, false]}
quoted: 'it''s here'
]])
      t.eq(doc.tags[2], "two three")
      t.eq(doc.tags[3], 4)
      t.eq(doc.meta.a, 1)
      t.eq(doc.meta.b, "x")
      t.eq(doc.meta.nested[2], false)
      t.eq(doc.quoted, "it's here")
    end)

    t.it("handles comments, null and booleans", function()
      local doc = yaml.decode([[
# leading comment
enabled: true
disabled: false
nothing: null
url: https://example.com/a#fragment
name: value # trailing comment
]])
      t.eq(doc.enabled, true)
      t.eq(doc.disabled, false)
      t.eq(doc.nothing, vim.NIL)
      t.eq(doc.url, "https://example.com/a#fragment")
      t.eq(doc.name, "value")
    end)

    t.it("supports sequences at the same indentation as their key", function()
      local doc = yaml.decode([[
root:
- a
- b
]])
      t.eq(doc.root[1], "a")
      t.eq(doc.root[2], "b")
    end)

    t.it("parses the fixture collection", function()
      local doc, err = yaml.decode_file("tests/fixtures/oc/users/get-user.yml")
      t.ok(doc, err)
      t.eq(doc.info.name, "Get User")
      t.eq(doc.http.params[1].type, "path")
      t.eq(doc.settings.followRedirects, false)
    end)

    t.it("returns an error with a line number for broken input", function()
      local doc, err = yaml.decode("a:\n  b: 1\n c: 2\n")
      t.eq(doc, nil)
      t.ok(err and err:match("line"), "expected a line number in: " .. tostring(err))
    end)
  end)
end
