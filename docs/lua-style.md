# Lua coding and function documentation

This project follows both the [LuaRocks Lua Style Guide](https://github.com/luarocks/lua-style-guide)
and the [APISIX Lua Coding Style Guide](https://github.com/apache/apisix/blob/master/CODE_STYLE.md).
APISIX takes precedence at gateway integration boundaries and where the guides
conflict. LuaRocks governs the remaining general Lua and documentation choices.

## How the two guides combine

| Area | Project rule |
|---|---|
| Indentation | APISIX: four spaces rather than LuaRocks' three. |
| Line length | APISIX: a hard 100-column limit. |
| Blocks and separation | APISIX: expanded blocks, two blank lines between functions and gaps between branches. |
| Source/test layout | Preserve APISIX's `apisix/plugins` loading path and the existing real-runtime test harness. |
| Names and modules | LuaRocks: descriptive snake_case names, named local module tables and `is_` predicates. |
| Strings and calls | LuaRocks: double quotes by default, single quotes for embedded double quotes, explicit call parentheses. |
| Documentation | LuaRocks: typed LDoc summaries, parameters, return values and failure contracts. |
| Errors | Both: check failures and return a diagnostic string; optional HTTP details follow it. |

Protocol-defined JSON field names and APISIX hook names retain their required
spelling. Dependencies normally use their module basename; disambiguating aliases
such as `resty_string`, `apisix_client` and `table_new` distinguish them from Lua's
standard library or request-local objects. Required functions are then localized
as APISIX recommends. The private codec and bounded worker-local routing cache
are explicit APISIX runtime state; they do not modify shared library configuration.

## Required practices

- Use local variables in the narrowest useful scope, descriptive snake_case names
  and uppercase immutable constants. Module tables use their actual module name,
  not reserved-looking uppercase identifiers. Boolean helpers use `is_` names.
- Split dispatch, initialization, catalog handling and operation forwarding into
  named functions whose contracts can be reviewed independently.
- Localize required modules and frequently called library/OpenResty functions.
  Read request-dependent `ngx` fields at request time, not module load time.
- Use early returns and check fallible operations before consuming their results.
  Expected failures return `nil, message`; HTTP-aware helpers may append a third
  metadata value containing status, JSON-RPC code and allowed response headers.
  APISIX hooks retain their required phase-specific return conventions.
- Preserve JSON null, false, zero and empty arrays/objects deliberately. Do not
  replace explicit nil checks with truthiness where that changes the protocol.
- Preallocate collections when their size is known; accumulate strings in tables
  rather than repeatedly concatenating a growing value inside a hot loop.
- Keep module state limited to the documented worker-local routing cache and
  private JSON codec. Request state and cleanup closures belong to the request.
- Document every function, including local helpers and callbacks, using an LDoc
  summary, typed `@param` entries in signature order and an explicit `@return`.
  Explain side effects, mutation, errors, deadlines and cleanup where applicable.
  Name callbacks so their contracts can be read and checked independently.

The module return values are internal interfaces. Transport/discovery/routing
functions return a diagnostic string as their second failure value and optional
HTTP metadata as their third value. A successful tool response with `isError`
or a JSON-RPC error remains a protocol response, not a transport failure.

## Automated checks

From Linux/WSL with Docker:

```sh
bash scripts/style.sh          # check formatting, contracts and lint
bash scripts/style.sh --write  # apply formatting, then check contracts and lint
bash scripts/test.sh           # execute real APISIX integration and helper tests
```

The development image pins StyLua 2.5.2 and Luacheck 1.2.0. Formatting uses the
Lua 5.1 parser with AST verification, followed by the APISIX function/branch
spacing pass. The checker rejects lines over 100 columns, undocumented functions
and parameter-documentation drift. Luacheck uses its Lua 5.1/OpenResty standards
with no ignored warning classes. CI runs these checks in a separate `lua-style`
job alongside the integration suite. The style image currently targets linux/amd64.

Use the wrapper rather than invoking StyLua directly: default StyLua spacing
collapses blank lines that APISIX requires. `.editorconfig`, `.stylua.toml` and
`.luacheckrc` capture the corresponding editor, formatter and linter settings.
These are development dependencies only; plugin installation still copies Lua
source and requires no formatter, Python, Java or external plugin runner.

Formatting and linting do not prove semantic rules such as correct authorization,
cleanup or bounded discovery. Review the function contracts and run the full
integration suite for changes to those paths.
