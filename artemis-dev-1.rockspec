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
  "luafilesystem >= 1.9.0",
  "http >= 0.4",
  "luaossl >= 20200709"
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
    ["artemis.project"] = "src/artemis/project/project.lua",
    ["artemis.project.manifest"] = "src/artemis/project/manifest.lua",
    ["artemis.project.lockfile"] = "src/artemis/project/lockfile.lua",
    ["artemis.runtime_manager"] = "src/artemis/runtime_manager/runtime_manager.lua",
    ["artemis.runtime_manager.runtime_installer"] = "src/artemis/runtime_manager/runtime_installer.lua",
    ["artemis.runtime_manager.release_catalog"] = "src/artemis/runtime_manager/release_catalog.lua",
    ["artemis.dependency_manager"] = "src/artemis/dependency_manager/dependency_manager.lua",
    ["artemis.dependency_manager.luarocks_config"] = "src/artemis/dependency_manager/luarocks_config.lua",
    ["artemis.dependency_manager.rockspec_generation"] = "src/artemis/dependency_manager/rockspec_generation.lua",
    ["artemis.cli"] = "src/artemis/cli.lua",
    ["artemis.utils.path"] = "src/artemis/utils/path.lua",
    ["artemis.utils.filesystem"] = "src/artemis/utils/filesystem.lua",
    ["artemis.utils.process"] = "src/artemis/utils/process.lua",
    ["artemis.utils.downloader"] = "src/artemis/utils/downloader.lua",
    ["artemis.utils.checksum"] = "src/artemis/utils/checksum.lua",
    ["artemis.utils.table_utils"] = "src/artemis/utils/table_utils.lua"
  },

  install = {
    bin = { "bin/artemis" }
  }
}
