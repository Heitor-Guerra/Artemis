package = "artemis"
version = "0.1.0-1"

source = {
  url = "git+https://github.com/Heitor-Guerra/artemis.git",
  tag = "v0.1.0"
}

description = {
  summary = "A project manager for Lua",
  license = "MIT"
}

dependencies = {
  "lua >= 5.4",
  "argparse >= 0.7"
  "tinytoml >= 1.0"
}

build = {
  type = "builtin",

  modules = {
    ["artemis"] = "src/artemis/init.lua",
    ["artemis.cli"] = "src/artemis/cli.lua",
    ["artemis.project"] = "src/artemis/project.lua",
    ["artemis.runtime_manager"] = "src/artemis/runtime_manager.lua",
    ["artemis.dependency_manager"] = "src/artemis/dependency_manager.lua",
    ["artemis.manifest"] = "src/artemis/manifest.lua",
    ["artemis.lockfile"] = "src/artemis/lockfile.lua"
  }
}
