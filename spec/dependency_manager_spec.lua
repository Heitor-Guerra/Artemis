--- @diagnostic disable: undefined-global, undefined-field, missing-fields, assign-type-mismatch, param-type-mismatch, need-check-nil
local DependencyManager = require("artemis.dependency_manager")
local helpers = require("spec.helpers")

describe("artemis.dependency_manager", function()
    local function dependency(name, constraint)
        return {
            name = name,
            constraint = constraint or "*"
        }
    end

    local function make_manager(root, luarocks, options)
        options = options or {}
        options.lua_version = options.lua_version or "5.4.9"
        options.cache_dir = options.cache_dir or (root .. "/shared-cache")
        options.luarocks = luarocks or options.luarocks or "luarocks-test"
        return DependencyManager.new(root, options)
    end

    local function make_fake_luarocks(root, exit_code)
        local executable = root .. "/fake-luarocks"
        local arguments_file = root .. "/captured-luarocks-arguments.txt"
        local rockspec_file = root .. "/captured-dependency.rockspec"
        local lock_file = root .. "/captured-luarocks-lock.lua"
        local status_file = root .. "/fake-luarocks-status.txt"

        helpers.write_file(executable, table.concat({
            "#!/bin/sh",
            "shift 2",
            "printf '%s\\n' \"$@\" > " .. helpers.shell_quote(arguments_file),
            "command=\"$1\"",
            "for argument in \"$@\"; do",
            "  case \"$argument\" in",
            "    *.rockspec) cp \"$argument\" " .. helpers.shell_quote(rockspec_file) .. " ;;",
            "  esac",
            "done",
            "if [ -f luarocks.lock ]; then cp luarocks.lock " .. helpers.shell_quote(lock_file) .. "; fi",
            "printf '%s\\n' \"$command\" > " .. helpers.shell_quote(status_file),
            "exit " .. tostring(exit_code or 0),
            ""
        }, "\n"))
        helpers.make_executable(executable)

        return executable, {
            arguments = arguments_file,
            rockspec = rockspec_file,
            lock = lock_file,
            status = status_file
        }
    end

    it("rejects invalid constructor arguments and requires only generic configuration", function()
        local manager, err = DependencyManager.new("", {})
        assert.is_nil(manager)
        assert.matches("Working directory", err)

        helpers.with_temp_dir(function(root)
            manager, err = DependencyManager.new(root, {})
            assert.is_nil(manager)
            assert.matches("Lua version", err)

            manager, err = DependencyManager.new(root, {
                lua_version = "5.4",
                tree = " "
            })
            assert.is_nil(manager)
            assert.matches("LuaRocks tree", err)
        end)
    end)

    it("normalizes LuaRocks version identifiers and creates its cache configuration", function()
        helpers.with_temp_dir(function(root)
            local manager, err = make_manager(root, "luarocks-test", {
                lua_version = "5.4.9",
                metadata_dir = ".artemis"
            })

            assert.is_truthy(manager, err)
            assert.equals("5.4", manager.lua_version)
            assert.equals("lua_modules", manager.tree)
            assert.is_truthy(manager.luarocks_config)
            assert.is_truthy(manager.rocks_cache_dir)
            assert.is_nil(manager.manifest)
            assert.is_nil(manager.manifest_path)

            local config_file = io.open(manager.luarocks_config, "rb")
            assert.is_truthy(config_file)
            config_file:close()
        end)
    end)

    it("normalizes LuaJIT to the LuaRocks jit identifier", function()
        helpers.with_temp_dir(function(root)
            local manager, err = make_manager(root, "luarocks-test", {
                lua_version = "luajit"
            })
            assert.is_truthy(manager, err)
            assert.equals("jit", manager.lua_version)
        end)
    end)

    it("succeeds without invoking LuaRocks when the dependency list is empty", function()
        helpers.with_temp_dir(function(root)
            local executable, files = make_fake_luarocks(root, 0)
            local manager = assert(make_manager(root, executable))

            local success, err = manager:install({})
            assert.is_true(success, err)
            assert.is_nil(io.open(files.status, "rb"))
        end)
    end)

    it("rejects exact versions when no direct dependencies were supplied", function()
        local manager = setmetatable({}, DependencyManager)
        local success, err = manager:install({}, { argparse = "0.7.2-1" })
        assert.is_false(success)
        assert.matches("without direct dependencies", err)
    end)

    it("rejects malformed dependency arrays and duplicate package names", function()
        helpers.with_temp_dir(function(root)
            local manager = assert(make_manager(root))

            local path, err = manager:_write_dependency_rockspec({ [2] = dependency("argparse") })
            assert.is_nil(path)
            assert.matches("dense array", err)

            local success
            success, err = manager:install({ dependency("argparse"), dependency("argparse", ">= 0.7") })
            assert.is_false(success)
            assert.matches("supplied more than once", err)

            success, err = manager:install({ dependency("bad;name") })
            assert.is_false(success)
            assert.matches("Invalid LuaRocks package name", err)
        end)
    end)

    it("writes sorted, safely quoted constraints to a generated rockspec", function()
        helpers.with_temp_dir(function(root)
            local manager = assert(make_manager(root, "luarocks-test", {
                metadata_dir = ".artemis/nested"
            }))

            local relative_path, err = manager:_write_dependency_rockspec({
                dependency("zlib"),
                dependency("argparse", ">= 0.7, < 1.0")
            })
            assert.is_truthy(relative_path, err)

            local contents = helpers.read_file(root .. "/" .. relative_path)
            local argparse_position = assert(contents:find('"argparse >= 0.7, < 1.0"', 1, true))
            local zlib_position = assert(contents:find('"zlib"', 1, true))
            assert.is_true(argparse_position < zlib_position)
            assert.is_truthy(contents:find('"lua >= 5.4, < 5.5"', 1, true))
        end)
    end)

    it("rejects empty and multiline constraints before writing a rockspec", function()
        helpers.with_temp_dir(function(root)
            local manager = assert(make_manager(root))

            local path, err = manager:_write_dependency_rockspec({ dependency("argparse", " ") })
            assert.is_nil(path)
            assert.matches("empty version constraint", err)

            path, err = manager:_write_dependency_rockspec({ dependency("argparse", "0.7\npackage = 'bad'") })
            assert.is_nil(path)
            assert.matches("line break", err)

            assert.is_nil(io.open(root .. "/.artemis/artemis-dependencies-0.0.0-1.rockspec", "rb"))
        end)
    end)

    it("installs supplied dependencies through LuaRocks and removes the generated rockspec", function()
        helpers.with_temp_dir(function(root)
            local executable, files = make_fake_luarocks(root, 0)
            local manager = assert(make_manager(root, executable, {
                metadata_dir = ".artemis"
            }))

            local success, err = manager:install({
                dependency("luasocket", "*"),
                dependency("argparse", ">= 0.7, < 1.0")
            })
            assert.is_true(success, err)

            local arguments = helpers.read_file(files.arguments)
            assert.matches("install", arguments)
            assert.matches("%-%-deps%-mode=one", arguments)
            assert.matches("%-%-only%-deps", arguments)
            assert.matches("artemis%-dependencies%-0%.0%.0%-1%.rockspec", arguments)

            local rockspec = helpers.read_file(files.rockspec)
            assert.matches('"argparse >= 0%.7, < 1%.0"', rockspec)
            assert.matches('"luasocket"', rockspec)
            assert.matches('"lua >= 5%.4, < 5%.5"', rockspec)
            assert.is_nil(io.open(root .. "/.artemis/artemis-dependencies-0.0.0-1.rockspec", "rb"))
        end)
    end)

    it("cleans the generated rockspec when LuaRocks installation fails", function()
        helpers.with_temp_dir(function(root)
            local executable = make_fake_luarocks(root, 27)
            local manager = assert(make_manager(root, executable))

            local success, err = manager:install({ dependency("argparse", ">= 0.7") })
            assert.is_false(success)
            assert.matches("Could not start LuaRocks", err)
            assert.is_nil(io.open(root .. "/.artemis/artemis-dependencies-0.0.0-1.rockspec", "rb"))
        end)
    end)

    it("stages exact LuaRocks pins and restores a pre-existing native lockfile", function()
        helpers.with_temp_dir(function(root)
            local executable, files = make_fake_luarocks(root, 0)
            local original_lock = 'return { dependencies = { retained = "1.0-1" } }\n'
            helpers.write_file(root .. "/luarocks.lock", original_lock)
            local manager = assert(make_manager(root, executable))

            local success, err = manager:install({
                dependency("argparse", ">= 0.7")
            }, {
                argparse = "0.7.2-1",
                luasystem = "0.3.0-1"
            })
            assert.is_true(success, err)

            local captured = assert(loadfile(files.lock))()
            assert.same({
                argparse = "0.7.2-1",
                luasystem = "0.3.0-1"
            }, captured.dependencies)
            assert.equals(original_lock, helpers.read_file(root .. "/luarocks.lock"))
            assert.is_nil(io.open(root .. "/luarocks.lock.artemis-tmp", "rb"))
        end)
    end)

    it("removes its temporary native lockfile when no previous lockfile existed", function()
        helpers.with_temp_dir(function(root)
            local executable, files = make_fake_luarocks(root, 0)
            local manager = assert(make_manager(root, executable))

            local success, err = manager:install({ dependency("argparse", "0.7.2-1") }, {
                argparse = "0.7.2-1"
            })
            assert.is_true(success, err)
            assert.is_truthy(helpers.read_file(files.lock))
            assert.is_nil(io.open(root .. "/luarocks.lock", "rb"))
            assert.is_nil(io.open(root .. "/luarocks.lock.artemis-tmp", "rb"))
        end)
    end)

    it("restores the previous native lockfile when LuaRocks fails", function()
        helpers.with_temp_dir(function(root)
            local executable = make_fake_luarocks(root, 23)
            local original_lock = 'return { dependencies = { retained = "2.0-1" } }\n'
            helpers.write_file(root .. "/luarocks.lock", original_lock)
            local manager = assert(make_manager(root, executable))

            local success, err = manager:install({ dependency("argparse", "0.7.2-1") }, {
                argparse = "0.7.2-1"
            })
            assert.is_false(success)
            assert.matches("Could not start LuaRocks", err)
            assert.equals(original_lock, helpers.read_file(root .. "/luarocks.lock"))
        end)
    end)

    it("requires exact locked versions for every direct dependency", function()
        helpers.with_temp_dir(function(root)
            local executable, files = make_fake_luarocks(root, 0)
            local manager = assert(make_manager(root, executable))

            local success, err = manager:install({ dependency("argparse", ">= 0.7") }, {})
            assert.is_false(success)
            assert.matches("no exact locked version", err)
            assert.is_nil(io.open(files.status, "rb"))
        end)
    end)

    it("verifies exact versions from the installed rock list", function()
        local manager = setmetatable({
            list_installed = function()
                return {
                    { name = "argparse", version = "0.7.2-1" },
                    { name = "luasystem", version = "0.3.0-1" }
                }
            end
        }, DependencyManager)

        local valid, err = manager:verify_versions({
            argparse = "0.7.2-1",
            luasystem = "0.3.0-1"
        })
        assert.is_true(valid, err)

        valid, err = manager:verify_versions({ argparse = "0.7.3-1" })
        assert.is_false(valid)
        assert.matches("expected 0%.7%.3%-1", err)
    end)

    it("rejects invalid exact-version input before listing installed rocks", function()
        local manager = setmetatable({
            list_installed = function()
                error("list_installed should not be called")
            end
        }, DependencyManager)

        local valid, err = manager:verify_versions("not-a-table")
        assert.is_false(valid)
        assert.matches("must be a table", err)
    end)

    it("propagates installed-rock listing errors when verifying exact versions", function()
        local manager = setmetatable({
            list_installed = function()
                return nil, "simulated local tree listing error"
            end
        }, DependencyManager)

        local valid, err = manager:verify_versions({ argparse = "0.7.2-1" })
        assert.is_false(valid)
        assert.equals("simulated local tree listing error", err)
    end)

    it("expands an explicit home-relative cache path", function()
        helpers.with_temp_dir(function(root)
            local home = assert(os.getenv("HOME"), "HOME must be set for this test")
            local manager, err = make_manager(root, "luarocks-test", {
                cache_dir = "~/.cache/artemis-tests"
            })

            assert.is_truthy(manager, err)
            assert.equals(home .. "/.cache/artemis-tests", manager.cache_dir)
        end)
    end)

    it("uses the XDG or home cache by default", function()
        helpers.with_temp_dir(function(root)
            local manager, err = DependencyManager.new(root, {
                lua_version = "5.4",
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

    it("parses LuaRocks porcelain output into installed rock records", function()
        helpers.with_temp_dir(function(root)
            local executable = root .. "/fake-luarocks-list"
            helpers.write_file(executable, table.concat({
                "#!/bin/sh",
                "shift 2",
                "[ \"$1\" = list ] || exit 18",
                "printf '%s\\n' 'argparse 0.7.2-1' 'luasystem 0.7.1-1'",
                ""
            }, "\n"))
            helpers.make_executable(executable)

            local manager = assert(make_manager(root, executable))
            local rocks, err = manager:list_installed()
            assert.is_truthy(rocks, err)
            assert.same({
                { name = "argparse", version = "0.7.2-1" },
                { name = "luasystem", version = "0.7.1-1" }
            }, rocks)
            assert.is_true(manager:is_installed("argparse"))
            assert.is_false(manager:is_installed("does-not-exist"))
        end)
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

    it("uninstalls an installed rock without accessing any project metadata", function()
        helpers.with_temp_dir(function(root)
            local command_log = root .. "/commands.txt"
            local executable = root .. "/fake-luarocks-remove"
            helpers.write_file(executable, table.concat({
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
            helpers.make_executable(executable)

            local manager = assert(make_manager(root, executable))
            local success, warning = manager:uninstall("argparse")
            assert.is_true(success)
            assert.is_nil(warning)
            assert.matches("remove %-%-deps%-mode=one argparse", helpers.read_file(command_log))
            assert.is_nil(manager.manifest)
        end)
    end)

    it("reports when LuaRocks retains a rock required by another package", function()
        helpers.with_temp_dir(function(root)
            local executable = root .. "/fake-luarocks-remove-failure"
            helpers.write_file(executable, table.concat({
                "#!/bin/sh",
                "shift 2",
                "if [ \"$1\" = list ]; then printf '%s\\n' 'argparse 0.7.2-1'; exit 0; fi",
                "if [ \"$1\" = remove ]; then echo 'required by another rock' >&2; exit 23; fi",
                "exit 18",
                ""
            }, "\n"))
            helpers.make_executable(executable)

            local manager = assert(make_manager(root, executable))
            local success, warning = manager:uninstall("argparse")
            assert.is_true(success)
            assert.is_truthy(warning)
            assert.matches("LuaRocks kept 'argparse'", warning)
        end)
    end)

    it("returns an error when listing the local tree fails", function()
        helpers.with_temp_dir(function(root)
            local executable = root .. "/fake-luarocks-list-failure"
            helpers.write_file(executable, "#!/bin/sh\nshift 2\nexit 31\n")
            helpers.make_executable(executable)
            local manager = assert(make_manager(root, executable))

            local rocks, err = manager:list_installed()
            assert.is_nil(rocks)
            assert.is_truthy(err)
            assert.matches("Could not start LuaRocks", err)
        end)
    end)

    it("returns LuaRocks path exports for the configured tree", function()
        helpers.with_temp_dir(function(root)
            local executable = root .. "/fake-luarocks-path"
            helpers.write_file(executable, table.concat({
                "#!/bin/sh",
                "shift 2",
                "[ \"$1\" = path ] || exit 18",
                "printf '%s\\n' 'export LUA_PATH=project-path' 'export LUA_CPATH=project-cpath'",
                ""
            }, "\n"))
            helpers.make_executable(executable)

            local manager = assert(make_manager(root, executable, { tree = "project-rocks" }))
            local exports, err = manager:path()
            assert.is_truthy(exports, err)
            assert.matches("LUA_PATH=project%-path", exports)
            assert.matches("LUA_CPATH=project%-cpath", exports)
            assert.equals("project-rocks", manager:get_tree())
        end)
    end)
end)
