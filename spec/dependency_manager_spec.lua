---@diagnostic disable: undefined-global, undefined-field, missing-fields, assign-type-mismatch, param-type-mismatch, need-check-nil
local DependencyManager = require("artemis.dependency_manager")
local helpers = require("spec.helpers")

describe("artemis.dependency_manager", function()
    local function make_manifest(dependencies)
        return helpers.new_manifest({
            name = "sample-project",
            lua = "5.4",
            dependencies = dependencies or {}
        })
    end

    local function make_fake_luarocks(root, exit_code)
        local script_path = root .. "/fake-luarocks"
        local capture_path = root .. "/captured-luarocks-lock.lua"
        local status_path = root .. "/fake-luarocks-status.txt"
        helpers.write_file(script_path, table.concat({
            "#!/bin/sh",
            "cat " ..
            helpers.shell_quote(root .. "/luarocks.lock") ..
            " > " .. helpers.shell_quote(capture_path) .. " 2>/dev/null || true",
            "printf '%s\\n' \"$@\" > " .. helpers.shell_quote(status_path),
            "exit " .. tostring(exit_code or 0),
            ""
        }, "\n"))
        helpers.make_executable(script_path)
        return script_path, capture_path, status_path
    end

    it("rejects invalid constructor arguments", function()
        local manager, err = DependencyManager.new("", make_manifest())
        assert.is_nil(manager)
        assert.matches("Project root", err)

        manager, err = DependencyManager.new("/tmp", {})
        assert.is_nil(manager)
        assert.matches("valid Artemis.Manifest", err)
    end)

    it("normalizes LuaRocks version identifiers and creates its project config", function()
        helpers.with_temp_dir(function(root)
            local manifest = make_manifest()
            local manager, err = DependencyManager.new(root, manifest, {
                cache_dir = root .. "/shared-cache",
                metadata_dir = ".artemis",
                lua_version = "5.4.9",
                luarocks = "luarocks-test"
            })

            assert.is_truthy(manager, err)
            assert.equals("5.4", manager.lua_version)
            assert.equals("lua_modules", manager.tree)
            assert.is_truthy(manager.luarocks_config)
            local config_file = io.open(manager.luarocks_config, "rb")
            assert.is_truthy(config_file)
            config_file:close()
        end)
    end)

    it("succeeds without invoking LuaRocks when there are no dependencies", function()
        local manager = setmetatable({
            manifest = make_manifest()
        }, DependencyManager)

        local success, err = manager:sync()
        assert.is_true(success, err)
    end)

    it("rejects lockfiles that omit a direct dependency version", function()
        local manager = setmetatable({
            manifest = make_manifest({ argparse = ">= 0.7" })
        }, DependencyManager)

        local success, err = manager:sync({})
        assert.is_false(success)
        assert.matches("no exact version", err)
    end)

    it("adds dependencies and rolls manifest changes back if synchronization fails", function()
        helpers.with_temp_dir(function(root)
            local manifest = make_manifest({ argparse = "0.7.2-1" })
            local manager = setmetatable({
                manifest = manifest,
                manifest_path = root .. "/artemis-project.toml",
                sync = function()
                    return false, "simulated installation failure"
                end
            }, DependencyManager)

            local success, err = manager:add("argparse", "0.8.0-1")
            assert.is_false(success)
            assert.matches("simulated installation failure", err)
            assert.equals("0.7.2-1", manifest:get_dependency("argparse"))
            assert.is_nil(manifest:get_dependency("luasocket"))

            manager.sync = function()
                return true
            end
            success, err = manager:add("luasocket")
            assert.is_true(success, err)
            assert.equals("*", manifest:get_dependency("luasocket"))

            local saved = assert(require("artemis.manifest").load(manager.manifest_path))
            assert.equals("*", saved:get_dependency("luasocket"))
        end)
    end)

    it("removes a dependency from the manifest without uninstalling absent rocks", function()
        helpers.with_temp_dir(function(root)
            local manifest = make_manifest({ argparse = "0.7.2-1" })
            local manager = setmetatable({
                manifest = manifest,
                manifest_path = root .. "/artemis-project.toml",
                list_installed = function()
                    return {}
                end
            }, DependencyManager)

            local success, err = manager:remove("argparse")
            assert.is_true(success, err)
            assert.is_nil(manifest:get_dependency("argparse"))

            local saved = assert(require("artemis.manifest").load(manager.manifest_path))
            assert.is_nil(saved:get_dependency("argparse"))

            success, err = manager:remove("argparse")
            assert.is_false(success)
            assert.matches("not declared", err)
        end)
    end)

    it("verifies exact locked versions from the installed rock list", function()
        local manager = setmetatable({
            list_installed = function()
                return {
                    { name = "argparse",  version = "0.7.2-1" },
                    { name = "luasystem", version = "0.3.0-1" }
                }
            end
        }, DependencyManager)

        local valid, err = manager:verify_locked({
            argparse = { version = "0.7.2-1" },
            luasystem = { version = "0.3.0-1" }
        })
        assert.is_true(valid, err)

        valid, err = manager:verify_locked({ argparse = "0.7.3-1" })
        assert.is_false(valid)
        assert.matches("expected 0.7.3%-1", err)
    end)

    it("rejects an invalid lock argument before querying installed rocks", function()
        local manager = setmetatable({
            list_installed = function()
                error("list_installed should not be called")
            end
        }, DependencyManager)

        local valid, err = manager:verify_locked("not-a-table")
        assert.is_false(valid)
        assert.matches("must be a table", err)
    end)

    it("detects a locked package that is missing from the installed tree", function()
        local manager = setmetatable({
            list_installed = function()
                return { { name = "argparse", version = "0.7.2-1" } }
            end
        }, DependencyManager)

        local valid, err = manager:verify_locked({
            argparse = "0.7.2-1",
            luasystem = "0.7.1-1"
        })
        assert.is_false(valid)
        assert.matches("'luasystem'.*expected 0%.7%.1%-1", err)
    end)

    it("rejects malformed exact pins before creating a rockspec or invoking LuaRocks", function()
        helpers.with_temp_dir(function(root)
            local manifest = make_manifest({ argparse = ">= 0.7" })
            local script_path, _, status_path = make_fake_luarocks(root, 0)
            local manager = assert(DependencyManager.new(root, manifest, {
                cache_dir = root .. "/shared-cache",
                metadata_dir = ".artemis",
                luarocks = script_path
            }))

            local success, err = manager:sync({ argparse = { version = " " } })
            assert.is_false(success)
            assert.matches("no exact version", err)
            assert.is_nil(io.open(status_path, "rb"))
            assert.is_nil(io.open(root .. "/.artemis/dependencies.rockspec", "rb"))
        end)
    end)

    it("stages exact LuaRocks pins and restores a pre-existing native lockfile", function()
        helpers.with_temp_dir(function(root)
            local manifest = make_manifest({ argparse = ">= 0.7" })
            local script_path, capture_path, status_path = make_fake_luarocks(root, 0)
            local old_lock = "return { dependencies = { old = \"1.0-1\" } }\n"
            helpers.write_file(root .. "/luarocks.lock", old_lock)

            local manager, err = DependencyManager.new(root, manifest, {
                cache_dir = root .. "/shared-cache",
                metadata_dir = ".artemis",
                luarocks = script_path
            })
            assert.is_truthy(manager, err)

            local success, sync_error = manager:sync({
                argparse = { version = "0.7.2-1" },
                luasystem = { version = "0.3.0-1" }
            })
            assert.is_true(success, sync_error)

            local captured = assert(loadfile(capture_path))()
            assert.same({
                argparse = "0.7.2-1",
                luasystem = "0.3.0-1"
            }, captured.dependencies)
            assert.equals(old_lock, helpers.read_file(root .. "/luarocks.lock"))
            assert.is_truthy(helpers.read_file(status_path):find("install", 1, true))
            assert.is_nil(io.open(root .. "/luarocks.lock.artemis-tmp", "rb"))
        end)
    end)

    it("removes its temporary native lockfile when no previous lockfile existed", function()
        helpers.with_temp_dir(function(root)
            local manifest = make_manifest({ argparse = "0.7.2-1" })
            local script_path, capture_path = make_fake_luarocks(root, 0)
            local manager = assert(DependencyManager.new(root, manifest, {
                cache_dir = root .. "/shared-cache",
                metadata_dir = ".artemis",
                luarocks = script_path
            }))

            local success, err = manager:sync({ argparse = "0.7.2-1" })
            assert.is_true(success, err)
            assert.is_truthy(helpers.read_file(capture_path))
            assert.is_nil(io.open(root .. "/luarocks.lock", "rb"))
        end)
    end)

    it("restores the previous native lockfile when LuaRocks fails", function()
        helpers.with_temp_dir(function(root)
            local manifest = make_manifest({ argparse = "0.7.2-1" })
            local script_path = make_fake_luarocks(root, 23)
            local old_lock = "return { dependencies = { retained = \"2.0-1\" } }\n"
            helpers.write_file(root .. "/luarocks.lock", old_lock)

            local manager = assert(DependencyManager.new(root, manifest, {
                cache_dir = root .. "/shared-cache",
                metadata_dir = ".artemis",
                luarocks = script_path
            }))

            local success, err = manager:sync({ argparse = "0.7.2-1" })
            assert.is_false(success)
            assert.matches("Could not start LuaRocks:", err)
            assert.equals(old_lock, helpers.read_file(root .. "/luarocks.lock"))
        end)
    end)
end)

-- Additional command-boundary and configuration coverage.
describe("artemis.dependency_manager integration surfaces", function()
    local function make_manifest(dependencies)
        return helpers.new_manifest({
            name = "cache-test-project",
            lua = "5.4",
            dependencies = dependencies or {}
        })
    end

    it("expands an explicit home-relative shared cache path", function()
        helpers.with_temp_dir(function(root)
            local home = assert(os.getenv("HOME"), "HOME must be set for this test")
            local manager, err = DependencyManager.new(root, make_manifest(), {
                cache_dir = "~/.cache/artemis-tests",
                luarocks = "luarocks-test"
            })

            assert.is_truthy(manager, err)
            assert.equals(home .. "/.cache/artemis-tests", manager.cache_dir)
        end)
    end)

    it("uses the XDG or home shared cache by default instead of a project-relative tilde path", function()
        helpers.with_temp_dir(function(root)
            local manager, err = DependencyManager.new(root, make_manifest(), {
                luarocks = "luarocks-test"
            })
            assert.is_truthy(manager, err)

            local configured = os.getenv("ARTEMIS_CACHE_DIR")
            local expected
            if configured and configured:match("^/") then
                expected = configured
            elseif configured and configured ~= "" then
                expected = root .. "/" .. configured
            elseif os.getenv("XDG_CACHE_HOME") and os.getenv("XDG_CACHE_HOME"):match("^/") then
                expected = os.getenv("XDG_CACHE_HOME") .. "/artemis"
            elseif os.getenv("HOME") and os.getenv("HOME"):match("^/") then
                expected = os.getenv("HOME") .. "/.cache/artemis"
            else
                expected = root .. "/.cache/artemis"
            end
            assert.equals(expected, manager.cache_dir)
            assert.is_nil(manager.cache_dir:find("/~", 1, true))
        end)
    end)

    it("writes its generated rockspec with sorted, safely quoted dependency constraints", function()
        helpers.with_temp_dir(function(root)
            local manifest = make_manifest({
                zlib = "*",
                argparse = ">= 0.7, < 1.0"
            })
            local manager = assert(DependencyManager.new(root, manifest, {
                cache_dir = root .. "/cache",
                luarocks = "luarocks-test"
            }))

            local relative_path, err = manager:_write_dependency_rockspec()
            assert.is_truthy(relative_path, err)
            local contents = helpers.read_file(root .. "/" .. relative_path)
            local argparse_position = assert(contents:find('"argparse >= 0.7, < 1.0"', 1, true))
            local zlib_position = assert(contents:find('"zlib"', 1, true))
            assert.is_true(argparse_position < zlib_position)
            assert.is_true(contents:find('"lua >= 5.4, < 5.5"', 1, true) ~= nil)
        end)
    end)

    it("rejects line breaks in dependency constraints before writing a rockspec", function()
        helpers.with_temp_dir(function(root)
            local manifest = make_manifest({ argparse = "0.7\npackage = 'bad'" })
            local manager = assert(DependencyManager.new(root, manifest, {
                cache_dir = root .. "/cache",
                luarocks = "luarocks-test"
            }))

            local path, err = manager:_write_dependency_rockspec()
            assert.is_nil(path)
            assert.matches("line break", err)
        end)
    end)

    it("parses LuaRocks porcelain output into exact installed rock records", function()
        helpers.with_temp_dir(function(root)
            local script_path = root .. "/fake-luarocks-list"
            helpers.write_file(script_path, table.concat({
                "#!/bin/sh",
                "shift 2",
                "if [ \"$1\" = \"list\" ]; then",
                "  printf '%s\\n' 'argparse 0.7.2-1' 'luasystem 0.7.1-1'",
                "  exit 0",
                "fi",
                "if [ \"$1\" = \"path\" ]; then",
                "  printf '%s\\n' 'export LUA_PATH=example'",
                "  exit 0",
                "fi",
                "exit 17",
                ""
            }, "\n"))
            helpers.make_executable(script_path)

            local manager = assert(DependencyManager.new(root, make_manifest(), {
                cache_dir = root .. "/cache",
                luarocks = script_path
            }))
            local rocks, err = manager:list_installed()
            assert.is_truthy(rocks, err)
            assert.same({
                { name = "argparse",  version = "0.7.2-1" },
                { name = "luasystem", version = "0.7.1-1" }
            }, rocks)
            assert.is_true(manager:is_installed("argparse"))
            assert.is_false(manager:is_installed("does-not-exist"))
        end)
    end)

    it("returns LuaRocks path exports from the configured project tree", function()
        helpers.with_temp_dir(function(root)
            local script_path = root .. "/fake-luarocks-path"
            helpers.write_file(script_path, table.concat({
                "#!/bin/sh",
                "shift 2",
                "[ \"$1\" = \"path\" ] || exit 18",
                "printf '%s\\n' 'export LUA_PATH=project-path' 'export LUA_CPATH=project-cpath'",
                ""
            }, "\n"))
            helpers.make_executable(script_path)

            local manager = assert(DependencyManager.new(root, make_manifest(), {
                cache_dir = root .. "/cache",
                luarocks = script_path,
                tree = "project-rocks"
            }))
            local exports, err = manager:path()
            assert.is_truthy(exports, err)
            assert.matches("LUA_PATH=project%-path", exports)
            assert.matches("LUA_CPATH=project%-cpath", exports)
            assert.equals("project-rocks", manager:get_tree())
        end)
    end)

    it("removes an installed direct dependency from the local tree", function()
        helpers.with_temp_dir(function(root)
            local script_path = root .. "/fake-luarocks-remove"
            local command_log = root .. "/commands.txt"
            helpers.write_file(script_path, table.concat({
                "#!/bin/sh",
                "shift 2",
                "command=\"$1\"",
                "shift",
                "case \"$command\" in",
                "  list) printf '%s\\n' 'argparse 0.7.2-1' ;;",
                "  remove) printf '%s\\n' \"remove $*\" >> " .. helpers.shell_quote(command_log) .. " ;;",
                "  *) exit 18 ;;",
                "esac",
                "exit 0",
                ""
            }, "\n"))
            helpers.make_executable(script_path)

            local manifest = make_manifest({ argparse = "0.7.2-1" })
            local manifest_path = root .. "/artemis-project.toml"
            assert.is_true(manifest:save(manifest_path))
            local manager = assert(DependencyManager.new(root, manifest, {
                cache_dir = root .. "/cache",
                manifest_path = manifest_path,
                luarocks = script_path
            }))

            local success, err = manager:remove("argparse")
            assert.is_true(success, err)
            assert.is_nil(manifest:get_dependency("argparse"))
            assert.matches("remove %-%-deps%-mode=one argparse", helpers.read_file(command_log))
        end)
    end)

    it("keeps the manifest change but reports when LuaRocks refuses to uninstall a dependency", function()
        helpers.with_temp_dir(function(root)
            local script_path = root .. "/fake-luarocks-remove-failure"
            helpers.write_file(script_path, table.concat({
                "#!/bin/sh",
                "shift 2",
                "if [ \"$1\" = list ]; then printf '%s\\n' 'argparse 0.7.2-1'; exit 0; fi",
                "if [ \"$1\" = remove ]; then echo 'required by another rock' >&2; exit 23; fi",
                "exit 18",
                ""
            }, "\n"))
            helpers.make_executable(script_path)

            local manifest = make_manifest({ argparse = "0.7.2-1" })
            local manifest_path = root .. "/artemis-project.toml"
            assert.is_true(manifest:save(manifest_path))
            local manager = assert(DependencyManager.new(root, manifest, {
                cache_dir = root .. "/cache",
                manifest_path = manifest_path,
                luarocks = script_path
            }))

            local success, warning = manager:remove("argparse")
            assert.is_true(success)
            assert.is_truthy(warning)
            assert.matches("LuaRocks kept it in the local tree", warning)
            assert.is_nil(manifest:get_dependency("argparse"))
        end)
    end)

    it("returns the LuaRocks process error when listing the local tree fails", function()
        helpers.with_temp_dir(function(root)
            local script_path = root .. "/fake-luarocks-list-failure"
            helpers.write_file(script_path, "#!/bin/sh\nshift 2\nexit 31\n")
            helpers.make_executable(script_path)
            local manager = assert(DependencyManager.new(root, make_manifest(), {
                cache_dir = root .. "/cache",
                luarocks = script_path
            }))

            local rocks, err = manager:list_installed()
            assert.is_nil(rocks)
            assert.is_truthy(err)
            assert.matches("Could not start LuaRocks", err)
        end)
    end)
end)


describe("artemis.dependency_manager synchronization contract", function()
    local function make_manifest()
        return helpers.new_manifest({
            name = "sync-contract-project",
            lua = "5.4.7",
            dependencies = {
                argparse = ">= 0.7, < 1.0",
                luasocket = "*"
            }
        })
    end

    local function make_fake_luarocks(root, exit_code)
        local executable = root .. "/fake-luarocks-sync"
        local arguments_file = root .. "/captured-install-arguments.txt"
        local rockspec_file = root .. "/captured-dependency.rockspec"
        helpers.write_file(executable, table.concat({
            "#!/bin/sh",
            "shift 2",
            "printf '%s\n' \"$@\" > " .. helpers.shell_quote(arguments_file),
            "for argument in \"$@\"; do rockspec_path=\"$argument\"; done",
            "cp \"$rockspec_path\" " .. helpers.shell_quote(rockspec_file),
            "exit " .. tostring(exit_code or 0),
            ""
        }, "\n"))
        helpers.make_executable(executable)
        return executable, arguments_file, rockspec_file
    end

    it("installs unlocked manifest constraints through LuaRocks and cleans the generated rockspec", function()
        helpers.with_temp_dir(function(root)
            local executable, arguments_file, rockspec_file = make_fake_luarocks(root, 0)
            local manager = assert(DependencyManager.new(root, make_manifest(), {
                cache_dir = root .. "/cache",
                metadata_dir = ".artemis",
                luarocks = executable
            }))

            local success, err = manager:sync()
            assert.is_true(success, err)

            local arguments = helpers.read_file(arguments_file)
            assert.matches("install", arguments)
            assert.matches("%-%-deps%-mode=one", arguments)
            assert.matches("%-%-only%-deps", arguments)
            assert.matches("artemis%-project%-dependencies%-0%.0%.0%-1%.rockspec", arguments)

            local generated_rockspec = helpers.read_file(rockspec_file)
            assert.matches('"lua >= 5%.4, < 5%.5"', generated_rockspec)
            assert.matches('"argparse >= 0%.7, < 1%.0"', generated_rockspec)
            assert.matches('"luasocket"', generated_rockspec)
            assert.is_nil(io.open(root .. "/.artemis/artemis-project-dependencies-0.0.0-1.rockspec", "rb"))
        end)
    end)

    it("cleans the generated rockspec when an unlocked installation fails", function()
        helpers.with_temp_dir(function(root)
            local executable = root .. "/fake-luarocks-failure"
            helpers.write_file(executable, "#!/bin/sh\nshift 2\nexit 27\n")
            helpers.make_executable(executable)
            local manager = assert(DependencyManager.new(root, make_manifest(), {
                cache_dir = root .. "/cache",
                metadata_dir = ".artemis",
                luarocks = executable
            }))

            local success, err = manager:sync()
            assert.is_false(success)
            assert.matches("Could not start LuaRocks", err)
            assert.is_nil(io.open(root .. "/.artemis/artemis-project-dependencies-0.0.0-1.rockspec", "rb"))
        end)
    end)

    it("propagates installed-rock listing errors when verifying lockfile entries", function()
        local manager = setmetatable({
            list_installed = function()
                return nil, "simulated local tree listing error"
            end
        }, DependencyManager)

        local valid, err = manager:verify_locked({ argparse = "0.7.2-1" })
        assert.is_false(valid)
        assert.equals("simulated local tree listing error", err)
    end)

    it("rejects an invalid package name before querying the local tree", function()
        local manager = setmetatable({
            list_installed = function()
                error("list_installed must not run for an invalid package name")
            end
        }, DependencyManager)

        local installed, err = manager:is_installed("argparse; touch /tmp/pwned")
        assert.is_nil(installed)
        assert.matches("Invalid LuaRocks package name", err)
    end)
end)
