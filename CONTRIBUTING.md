# Contributing

Thank you for considering a contribution! This project aims to make Lua development more predictable and approachable. Contributions should be small, understandable, tested, and documented.

---

## Before you start

- For a substantial change, open an issue or discussion first so the design can be agreed on before significant work is done.
- Search existing issues and pull requests to avoid duplicating work.
- Keep pull requests focused. Explain the problem, the proposed solution, and any behavior or compatibility changes.
- Do not include unrelated formatting changes in a functional patch.

---

## Lua tooling is expected

Use **[LuaLS (Lua Language Server)](https://luals.github.io/)** while developing. Configure it for the Lua version and libraries used by the part of the codebase you are changing. Contributors should address relevant diagnostics before submitting a pull request rather than relying only on whether the code happens to run locally.

LuaLS uses LuaCATS annotations to document symbols and provide type information. Refer to the [official annotations guide](https://luals.github.io/wiki/annotations/).

Other useful tools include:

- **[StyLua](https://github.com/JohnnyMorganz/StyLua)** for consistent formatting.
- **[Luacheck](https://github.com/lunarmodules/luacheck)** for static linting.

Use the repository's configured versions and commands when they are available. If a tool reports a false positive, explain it in the code or pull request instead of silently disabling broad diagnostics.

---

## Documentation and type annotations

Lua is dynamically typed, so explicit documentation is important. Keep annotations accurate and update them whenever a function, value, or data structure changes.

- Document every public or exported function with a short description, `---@param` annotations for its parameters, and `---@return` annotations for every return value.
- Give public classes/tables and structured data types a `---@class` definition with `---@field` annotations.
- Use `---@alias` for reusable domain types and `---@type` for module-level values, constants, and locals whose type is not obvious from their initializer or use.
- Annotate callback signatures and function-valued fields instead of leaving them implicit.
- Mark optional values as optional (for example, `string?`) and describe when a function can return `nil` or an error value.
- Keep annotations truthful. Do not use `any` as a shortcut when a narrower type can be expressed.
- Prefer local variables and local functions. Avoid creating globals unless a global is an intentional part of the public API.
- When a function can fail, document the failure behavior and the returned error information. Do not invent a `---@throws` annotation; use the project's documented error-return convention.
- Add comments for non-obvious decisions and invariants, not for every self-explanatory line.

### Example

```lua
---@alias DependencyMap table<string, string>

---@class Project
---@field name string
---@field lua_version string
---@field main string
---@field dependencies DependencyMap

---@param project_root string Directory containing the project manifest.
---@return Project? project Parsed project, or nil if loading failed.
---@return string? error_message Present when the project could not be loaded.
local function load_project(project_root)
    -- Implementation goes here.
end

---@type string
local manifest_filename = "lua-project.toml"
```

The example uses LuaCATS annotations recognized by LuaLS. Follow the syntax supported by the version of LuaLS pinned or documented by this repository.

---

## Code conventions

- Follow the existing style in the files you touch. Use `snake_case` for local variables and functions.
- Make dependencies explicit; avoid hidden global state and unnecessary side effects during module loading.
- Keep modules focused and expose the smallest reasonable public API.
- Handle filesystem, process, network, and parsing errors explicitly. Error messages should explain what failed and, where useful, how to fix it.
- Do not silently overwrite project files or user data. Destructive behavior must be explicit and documented.
- Keep platform-specific behavior isolated and test it on the relevant operating systems when possible.
- Preserve compatibility with the Lua versions the project claims to support. Do not accidentally use syntax or standard-library APIs unavailable on the supported baseline.

---

## Tests and pull requests

- Add or update tests for behavior changes and bug fixes.
- Include edge cases for malformed manifests, missing executables, unavailable Lua versions, dependency conflicts, interrupted downloads, and filesystem failures where relevant.
- Run the test suite, formatter, linter, and LuaLS diagnostics available in the repository before submitting.
- Do not mark checks as passing if they were not run. Mention any checks you could not run and why.
- Update the README or other documentation when commands, manifest fields, supported versions, or user-visible behavior change.
- Include a concise summary and testing notes in the pull request description.

---

## Dependency and security considerations

- Prefer maintained dependencies with clear licenses and a reasonable maintenance history.
- Do not commit downloaded runtimes, package archives, credentials, access tokens, or machine-specific paths.
- Validate package names, versions, archive contents, and extraction paths. Avoid path traversal and unsafe extraction behavior.
- Treat package metadata and remote content as untrusted input.
- Do not add telemetry or network behavior without documenting it and obtaining an explicit design decision.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
