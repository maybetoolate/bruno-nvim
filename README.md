# bruno-nvim

A Neovim client for [Bruno](https://www.usebruno.com/) API collections. Browse
collections, edit and send requests, inspect responses, switch environments and
run Bruno's pre-request/after-response scripts — without leaving Neovim and
without installing the Bruno app or CLI.

The plugin talks to the network with `curl` and runs collection scripts with
`node`. Everything else is plain Lua with no required Lua dependencies.

## Features

- **Both collection formats** — Bruno 2.x OpenCollection YAML
  (`opencollection.yml`, `folder.yml`, `*.yml`) and the legacy `.bru` format.
- **Collection sidebar** with folders, request methods and request counts.
- **Request editor integration** — open a request file, edit it, and run it with
  your local keymap. Modified buffers are parsed from the buffer, so unsaved
  edits are used.
- **Response viewer** in a split with status, timing, headers, pretty-printed
  JSON and test results. Toggle pretty-printing and headers, copy or save the
  body.
- **Environments** with inheritance (`extends`), variable interpolation,
  secret masking, dynamic variables (`{{$guid}}`, `{{$timestamp}}`, ...) and
  `process.env.*`.
- **Authentication**: inherit, bearer, basic, API key (header or query),
  digest, NTLM, and OAuth2 client-credentials / password flows. OAuth2 access
  tokens are cached in memory only.
- **Scripts and tests**: `bru`, `req`, `res`, `expect`, `test`, and `console`
  in pre-request, post-response and tests phases.
- **Response history** and per-collection persisted variables/environment.
- **`:checkhealth bruno`** checks Neovim, `curl`, `node`, and the current
  collection.

## Requirements

- Neovim 0.10 or newer (developed against 0.12).
- `curl` on `PATH`.
- `node` on `PATH` for scripts and tests (optional; requests still work
  without it).

The plugin deliberately has no Lua dependencies. It uses `vim.ui.select` for
pickers, so any picker that overrides `vim.ui.select` (such as
`snacks.nvim`) is used automatically.

## Installation

With `lazy.nvim`:

```lua
{
  dir = "/path/to/bruno-nvim",
  name = "bruno-nvim",
  ft = { "bruno" },
  cmd = { "Bruno", "BrunoOpen", "BrunoRun", "BrunoEnv", "BrunoPeek" },
  opts = {},
}
```

Or with `vim.pack` / `packadd`, put the repository on `runtimepath` and call:

```lua
require("bruno").setup()
```

`setup()` is optional unless you want to change defaults.

## Quick start

```vim
:Bruno /path/to/your/collection
```

If the current file is inside a collection, `:Bruno` finds the collection root
automatically. Open a request from the sidebar with `<CR>`, then press
`<localleader>r` to send it.

Useful first commands:

| Command | Description |
| --- | --- |
| `:Bruno [path]` | Toggle the collection sidebar |
| `:BrunoOpen [path]` | Pick a request from the collection |
| `:BrunoRun [path]` | Send the current request (or the file at `path`) |
| `:BrunoEnv [name]` | Select an environment, or list them |
| `:BrunoPeek` | Preview the resolved request without sending it |
| `:BrunoResponse` | Reopen the last response for the current request |
| `:BrunoHistory` | Browse recent responses |
| `:BrunoCurl` | Copy the current request as a `curl` command |
| `:BrunoVar name=value` | Set a local variable (persisted per collection) |
| `:BrunoVar -u name` | Remove a local variable |
| `:BrunoVar` | Show resolved variables and their scopes |
| `:BrunoReload` | Reload collections from disk |
| `:BrunoCancel` | Cancel in-flight requests |
| `:BrunoHelp` | Show the keymap cheatsheet |

## Default keymaps

Request buffers (YAML or `.bru` inside a collection):

| Key | Action |
| --- | --- |
| `<localleader>r` | Run request |
| `<localleader>p` | Preview resolved request |
| `<localleader>e` | Select environment |
| `<localleader>v` | Show variables |
| `<localleader>h` | Response history |
| `<localleader>c` | Copy as curl |

Sidebar:

| Key | Action |
| --- | --- |
| `<CR>` | Open request / toggle folder |
| `o` | Toggle folder |
| `R` | Run request under cursor |
| `r` | Reload collection |
| `e` | Select environment |
| `v` | Show variables |
| `y` | Copy request as curl |
| `?` / `g?` | Help |
| `q` | Close sidebar |

Response window:

| Key | Action |
| --- | --- |
| `q` | Close |
| `<localleader>p` | Toggle pretty-print |
| `<localleader>H` | Toggle headers |
| `<localleader>y` | Copy body |
| `<localleader>s` | Save body to a file |

## Configuration

Defaults:

```lua
require("bruno").setup({
  -- nil: discover from the current buffer or cwd
  collection = nil,
  -- nil: use the persisted/default environment
  env = nil,

  keymaps = {
    run = "<localleader>r",
    peek = "<localleader>p",
    env = "<localleader>e",
    vars = "<localleader>v",
    history = "<localleader>h",
    copy_curl = "<localleader>c",
  },

  curl = {
    bin = "curl",
    insecure = false,       -- -k
    timeout = 30000,        -- ms; 0 disables --max-time
    extra_args = {},
  },

  scripts = {
    enabled = true,
    node = "node",
    timeout = 10000,        -- ms
  },

  ui = {
    width = 40,
    icons = true,
    winbar = true,
    response = {
      position = "below",   -- "below" | "right"
      size = 0.35,
      pretty = true,
      headers = true,
      focus = false,
    },
  },

  variables = {
    missing = "keep",       -- "keep" | "empty" | "error"
    persist = true,
  },

  history = {
    enabled = true,
    size = 50,
    max_body = 64 * 1024,
  },

  oauth = {
    cache = true,
  },

  picker = "auto",          -- reserved; uses vim.ui.select
})
```

Set a key to `""` to disable it.

## Formats

### OpenCollection YAML

A collection is a directory containing `opencollection.yml`. Folders use
`folder.yml`, environments live in `environments/*.yml`, and every other YAML
file is treated as a request:

```yaml
info:
  name: Get user
  type: http
  seq: 1

http:
  method: GET
  url: "{{host}}/users/{{userId}}"

headers:
  - name: Accept
    value: application/json

auth: inherit
```

GraphQL requests use a `graphql` block and are sent as JSON automatically.
Bodies can be JSON, text, XML, form-urlencoded, multipart or file.

### Legacy `.bru`

Collections with `bruno.json` and `collection.bru` are supported too. The
plugin normalizes `meta`, `get`/`post`, `headers`, `body:*`, `auth`, `vars`,
`script:*` and environment blocks into the same internal model.

## Variable resolution

Variables are resolved from highest to lowest priority:

1. Runtime variables (`bru.setVar`, `:BrunoVar`, script updates)
2. Request variables
3. Folder variables (nearest folder first)
4. Active environment
5. Collection variables
6. Process environment

Unknown variables are kept as `{{name}}` by default and reported in the
preview and response warnings. `variables.missing = "empty"` replaces them
with an empty string; `"error"` makes the run fail.

Secrets are marked in environment files with `secret: true`. Their values are
masked in the variables panel. Scripts cannot read secret variables; the
`bru.getSecretVar` call reports that secrets are unavailable.

## Scripts

Scripts run in a `node` subprocess. Each lifecycle phase receives the same
sandbox:

```js
// pre-request
bru.setVar("userId", "42")
req.setHeader("X-Debug", "1")

// after-response / tests
test("status is 200", function () {
  expect(res.status).to.equal(200)
  expect(res.body.id).to.be.a("string")
})
```

Supported globals: `bru`, `req`, `res`, `expect`, `test`, `console`,
`require`, `process.env`, `Buffer`, `URL`, `URLSearchParams`, `atob`, `btoa`.

Common assertions include `.to.equal`, `.to.eql`, `.to.be.above`, `.to.be.a`,
`.to.include`, `.to.match`, `.to.have.property`, `.to.have.keys`, `.to.be.ok`,
`.to.be.true`, `.to.be.null`, `.to.exist`, and `.not`.

Scripts are **not** a security sandbox: they run with the full permissions of
your user account. Only run collections you trust.

## Persistence

Per-collection state (selected environment, local variables, expanded folders)
and response history live in:

```
stdpath("data")/bruno-nvim/state.json
```

Set `history.enabled = false` or `variables.persist = false` to avoid writing
those parts. OAuth2 access tokens are only kept in memory for the current
Neovim session.

## Health and tests

```vim
:checkhealth bruno
```

Run the test suite (all fixtures are local; no network access required except
to a loopback test server):

```sh
make test
```

Formatting uses StyLua:

```sh
make fmt
make lint
```

## Limitations

- No Bruno CLI or GUI integration; requests are sent with `curl`.
- AWS Signature v4, WSSE and OAuth1 auth are not implemented. They produce a
  warning; add the required headers manually if needed.
- The YAML reader supports the subset used by OpenCollection files. Anchors,
  aliases and multi-document YAML are not supported.
- Scripts run outside a VM sandbox and cannot access Bruno secret variables.
- Multipart and file bodies expect file paths that `curl` can read.

## License

MIT
