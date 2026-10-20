--- Tiny test harness (no external dependencies).
local M = {
  passed = 0,
  failed = 0,
  failures = {},
  current = nil,
}

function M.describe(name, fn)
  local previous = M.current
  M.current = name
  local ok, err = pcall(fn)
  if not ok then
    M.failed = M.failed + 1
    M.failures[#M.failures + 1] = ("%s: %s"):format(name, tostring(err))
  end
  M.current = previous
end

function M.it(name, fn)
  local label = (M.current and (M.current .. " › ") or "") .. name
  local ok, err = pcall(fn)
  if ok then
    M.passed = M.passed + 1
  else
    M.failed = M.failed + 1
    M.failures[#M.failures + 1] = label .. "\n    " .. tostring(err)
  end
end

--- Absolute, normalized path for a fixture or repo-relative file.
function M.path(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function format(value)
  if type(value) == "table" then
    local ok, encoded = pcall(vim.inspect, value)
    return ok and encoded or tostring(value)
  end
  return tostring(value)
end

function M.eq(actual, expected, message)
  if vim.deep_equal(actual, expected) then
    return
  end
  error(("%sexpected %s, got %s"):format(message and (message .. ": ") or "", format(expected), format(actual)), 2)
end

function M.ok(value, message)
  if not value then
    error(message or "expected a truthy value", 2)
  end
end

function M.not_ok(value, message)
  if value then
    error(message or "expected a falsy value", 2)
  end
end

function M.contains(haystack, needle, message)
  if type(haystack) == "string" then
    if haystack:find(needle, 1, true) then
      return
    end
  elseif type(haystack) == "table" then
    for _, value in ipairs(haystack) do
      if value == needle then
        return
      end
    end
  end
  error(
    ("%sexpected %s to contain %s"):format(message and (message .. ": ") or "", format(haystack), format(needle)),
    2
  )
end

function M.matches(value, pattern, message)
  if not tostring(value):match(pattern) then
    error(("%sexpected %s to match %s"):format(message and (message .. ": ") or "", format(value), pattern), 2)
  end
end

function M.report()
  for _, failure in ipairs(M.failures) do
    io.stderr:write("FAIL " .. failure .. "\n")
  end
  io.stdout:write(("%d passed, %d failed\n"):format(M.passed, M.failed))
  return M.failed == 0
end

return M
