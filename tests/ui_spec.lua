return function(t)
  local request = require("bruno.ui.request")
  local response = require("bruno.ui.response")
  local tree = require("bruno.ui.tree")

  local function buffer_for(path)
    local buf = vim.fn.bufadd(t.path(path))
    vim.fn.bufload(buf)
    return buf
  end

  local function lines_of(win)
    local buf = vim.api.nvim_win_get_buf(win)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  t.describe("ui", function()
    t.it("recognizes request buffers only", function()
      local request_buf = buffer_for("tests/fixtures/oc/users/get-user.yml")
      t.ok(request.is_request(request_buf), "get-user.yml should be a request")

      local env_buf = buffer_for("tests/fixtures/oc/environments/local.yml")
      t.not_ok(request.is_request(env_buf), "environment files are not requests")

      local collection_buf = buffer_for("tests/fixtures/oc/opencollection.yml")
      t.not_ok(request.is_request(collection_buf), "collection files are not requests")
    end)

    t.it("renders the collection tree", function()
      tree.open({ path = "tests/fixtures/oc" })
      local win = vim.api.nvim_get_current_win()
      local text = lines_of(win)
      tree.close()

      t.contains(text, "Fixture API")
      t.contains(text, "Users")
      t.contains(text, "POST")
      t.contains(text, "Create User")
    end)

    t.it("replaces the request window and restores it on close", function()
      local req_path = t.path("tests/fixtures/oc/users/get-user.yml")
      vim.cmd("edit " .. vim.fn.fnameescape(req_path))
      local request_win = vim.api.nvim_get_current_win()
      local request_buf = vim.api.nvim_get_current_buf()
      local windows_before = #vim.api.nvim_tabpage_list_wins(0)

      response.show({
        status = 200,
        reason = "OK",
        headers = { ["content-type"] = "application/json" },
        body = '{"ok":true}',
        content_type = "application/json",
        time_ms = 3,
        size = 11,
      }, { req = { path = req_path }, focus = true })

      t.eq(#vim.api.nvim_tabpage_list_wins(0), windows_before, "no split should be opened")
      t.eq(vim.api.nvim_get_current_win(), request_win, "the request window should be reused")
      t.ok(vim.api.nvim_win_get_buf(request_win) ~= request_buf, "response should replace the request buffer")
      t.contains(lines_of(request_win), "ok")

      response.close()
      t.eq(vim.api.nvim_win_get_buf(request_win), request_buf, "closing should restore the request buffer")
    end)

    t.it("renders a response body and headers", function()
      local util = require("bruno.ui.util")
      response.show({
        status = 200,
        reason = "OK",
        headers = { ["content-type"] = "application/json" },
        body = '{"ok":true}',
        content_type = "application/json",
        time_ms = 12,
        size = 11,
      }, { focus = true })
      local win = vim.api.nvim_get_current_win()
      local buf = vim.api.nvim_win_get_buf(win)
      local body = lines_of(win)

      local header = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, util.ns, 0, -1, { details = true })) do
        for _, line in ipairs((mark[4] and mark[4].virt_lines) or {}) do
          for _, chunk in ipairs(line) do
            header[#header + 1] = chunk[1]
          end
        end
      end
      header = table.concat(header, "")
      local current = response.current()
      response.close()

      t.contains(body, "ok")
      t.contains(header, "200 OK")
      t.contains(header, "content-type")
      t.eq(current.status, 200)
    end)
  end)
end
