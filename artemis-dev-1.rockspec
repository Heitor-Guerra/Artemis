rockspec_format = "3.0"

package = "artemis"
version = "dev-1"

source = {
  url = "git+https://github.com/Heitor-Guerra/artemis.git",
  tag = "v0.1.0"
}

description = {
  summary = "A project manager for Lua",
  license = "GPL-3.0-only"
}

dependencies = {
  "lua >= 5.4",
  "tinytoml >= 1.0",
  "argparse >= 0.7.2, < 1.0",
  "luafilesystem >= 1.9.0"
}

test_dependencies = {
  "busted >= 2.2, < 3.0"
}

test = {
  type = "busted"
}


build = {
  type = "builtin",

  modules = {
    ["artemis"] = "src/artemis/init.lua",
    ["artemis.project"] = "src/artemis/project.lua",
    ["artemis.runtime_manager"] = "src/artemis/runtime_manager.lua",
    ["artemis.dependency_manager"] = "src/artemis/dependency_manager.lua",
    ["artemis.manifest"] = "src/artemis/manifest.lua",
    ["artemis.lockfile"] = "src/artemis/lockfile.lua",
    ["artemis.cli"] = "src/artemis/cli.lua"
  },

  install = {
    bin = { "bin/artemis" }
  }
}
