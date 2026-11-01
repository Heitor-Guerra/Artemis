# Artemis

A project-first tool for making Lua development easier. The goal is to provide a consistent way to create Lua projects, select and install a Lua version, manage dependencies, and reproduce a project's local environment.

The workflow takes inspiration from modern language tooling while remaining focused on Lua and its ecosystem.

> **Project status:** This repository currently describes the proposed project and conventions.

---

## Goals

- **Project metadata:** keep a project's name, description, maintainer, Lua version, and entry point in one manifest.
- **Lua version management:** select and install the Lua version requested by a project without requiring users to manage it globally themselves.
- **Dependency management:** declare, add, and resolve project dependencies.
- **Environment synchronization:** install the selected Lua runtime and declared dependencies into a project-local working directory.
- **Reproducibility:** use a lockfile so that different machines can install the same dependency versions.

---

## Proposed workflow

The command names are provisional. They are intended to communicate the planned user experience.

### Initialize a project

```sh
artms init
```

Creates a project manifest and a starter source file in the current directory. An optional project name could be accepted:

```sh
artms init my-project
```

### Add a dependency

```sh
artms add luasocket
```

Adds the package to the project's dependency declarations and, once dependency resolution is implemented, updates the lockfile.

### Synchronize the project

```sh
artms sync
```

Reads the manifest (and, when available, the lockfile), installs the requested Lua version, and installs the project's dependencies into a local environment directory.

---

## Project manifest

The following is the **expected TOML format**. It is an example to make the project shape concrete.

```toml
[project]
name = "artemis"
description = "A feature-rich lua project manager"
lua = "5.5"
maintainer = "Heitor Guerra Proveti <heitor.guerra@proton.me>"

[dependencies]
argparse = "0.7.2-1"

[run]
args = [ "src/main.lua" ]

[build]
type = "builtin"
```

---

### Planned files and directories

```text
my-project/
├── artemis.toml           # Project metadata and dependency declarations
├── artemis.lock           # Resolved dependency versions
├── src/
│   └── main.lua           # Main file selected by the project
└── .artemis/              # Project-local Lua runtime and installed packages
```

---

## Initial scope and roadmap

The first milestone should focus on the core project lifecycle:

1. Initialize a project and create its manifest.
2. Parse and validate the manifest.
3. Install and select supported Lua versions.
4. Add and resolve dependencies.
5. Synchronize the project-local runtime and dependencies.
6. Write and read a lockfile for repeatable installs.

Running project scripts (for example, `artms run`) is a possible later feature and is intentionally outside the initial scope. Other future ideas include dependency removal and upgrade commands, dependency-tree inspection, cache management, and support for additional Lua distributions or package sources.

---

## Development

Contributions are welcome. Before opening a pull request, read [CONTRIBUTING.md](CONTRIBUTING.md) and follow the project's Lua documentation and typing conventions. In particular, use [LuaLS](https://luals.github.io/) and add LuaCATS annotations for public APIs and values whose types are not obvious.

---

## Inspirations and credits

This project is independently designed and implemented. However, its workflow is heavily inspired by existing tools in other language ecosystems and in the Lua ecosystem:

- **[uv](https://github.com/astral-sh/uv)** by **[Astral](https://astral.sh/)** — inspiration for a project-centric workflow, including project initialization, dependency addition, environment synchronization, and language-version management.
- **[Lux](https://github.com/lumen-oss/lux)** by **[Lumen Labs / lumen-oss](https://github.com/lumen-oss)** — a Lua and Luau package manager that serves as a direct point of reference for Lua project and dependency management.

These projects are acknowledged as conceptual and workflow inspirations. This project is not affiliated with, sponsored by, or endorsed by Astral, Lumen Labs, or the maintainers of uv or Lux. No code from those projects is implied to be included here; any direct code reuse must be separately reviewed and credited in accordance with its original license.

---

## License

This project is released under the MIT License. See [LICENSE](LICENSE).
