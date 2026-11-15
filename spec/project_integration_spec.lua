--- @diagnostic disable: undefined-global, undefined-field, missing-fields, assign-type-mismatch, param-type-mismatch, need-check-nil
local Project = require("artemis.project")
local Lockfile = require("artemis.lockfile")
local helpers = require("spec.helpers")

describe("Artemis end-to-end project workflows", function()
    local function make_manifest()
        return helpers.new_manifest({
            name = "integration-project",
            lua = "5.4",
            version = "0.1.0",
            main = "src/main.lua",
            dependencies = {
                argparse = ">= 0.7, < 1.0"
            }
        })
    end

    local function make_fake_luarocks(root, install_status)
        local executable = root .. "/fake-luarocks"
        local installed_file = root .. "/installed-rocks.txt"
        local captured_lock = root .. "/captured-luarocks.lock"
        local events_file = root .. "/luarocks-events.txt"

        helpers.write_file(installed_file, table.concat({
            "argparse 0.7.2-1",
            "luasystem 0.7.1-1",
            "luassert 1.9.0-1",
            ""
        }, "\n"))

        helpers.write_file(executable, table.concat({
            "#!/bin/sh",
            "shift 2",
            "command=\"$1\"",
            "shift",
            "case \"$command\" in",
            "  install)",
            "    printf '%s\\n' install >> " .. helpers.shell_quote(events_file),
            "    if [ -f " .. helpers.shell_quote(root .. "/luarocks.lock") .. " ]; then",
            "      cp " .. helpers.shell_quote(root .. "/luarocks.lock") .. " " .. helpers.shell_quote(captured_lock),
            "    fi",
            "    exit " .. tostring(install_status or 0),
            "    ;;",
            "  list)",
            "    cat " .. helpers.shell_quote(installed_file),
            "    ;;",
            "  path)",
            "    printf '%s\\n' 'export ARTEMIS_FAKE_LUAROCKS_PATH=1'",
            "    ;;",
            "  remove)",
            "    printf '%s\\n' remove >> " .. helpers.shell_quote(events_file),
            "    exit 0",
            "    ;;",
            "  *)",
            "    echo \"unexpected fake LuaRocks command: $command\" >&2",
            "    exit 19",
            "    ;;",
            "esac",
            "exit 0",
            ""
        }, "\n"))
        helpers.make_executable(executable)
        return executable, captured_lock, events_file
    end

    local function resolve_fake_runtime_version(requested_version)
        if not requested_version then
            return "5.4.9"
        end

        if requested_version:match("^%d+%.%d+$") then
            return requested_version .. ".9"
        end

        return requested_version
    end

    local function make_fake_runtime(project, version, argument_capture, exit_status)
        local runtime_directory = project.runtime_manager.runtimes_dir .. "/" .. version
        local executable = runtime_directory .. "/bin/lua"
        helpers.make_directory(runtime_directory .. "/bin")

        helpers.write_file(executable, table.concat({
            "#!/bin/sh",
            "printf '%s\\n' \"$@\" > " .. helpers.shell_quote(argument_capture),
            "exit " .. tostring(exit_status or 0),
            ""
        }, "\n"))
        helpers.make_executable(executable)
        return executable
    end

    local function new_project(root, install_status, runtime_status)
        local manifest = make_manifest()
        local luarocks, captured_lock, events = make_fake_luarocks(root, install_status)
        local project, err = Project.new(root, {
            manifest = manifest,
            cache_dir = root .. "/shared-cache",
            luarocks = luarocks,
            runtime_options = {}
        })
        assert.is_truthy(project, err)

        local runtime_capture = root .. "/fake-lua-arguments.txt"
        project.runtime_manager.install = function(runtime_manager, requested_version)
            local version = resolve_fake_runtime_version(requested_version)
            make_fake_runtime(project, version, runtime_capture, runtime_status)
            return true, nil, version
        end

        return project, captured_lock, events, runtime_capture
    end

    it("runs a complete first sync, writes an Artemis lock, then performs a pinned second sync", function()
        helpers.with_temp_dir(function(root)
            local project, captured_lock, events = new_project(root)

            local success, err, runtime_version = project:sync()
            assert.is_true(success, err)
            assert.equals("5.4.9", runtime_version)
            local lock_handle = io.open(project.lockfile_path, "rb")
            assert.is_truthy(lock_handle)
            lock_handle:close()

            local generated = assert(Lockfile.load(project.lockfile_path))
            assert.equals("5.4.9", generated.data.project.runtime)
            assert.is_nil(io.open(project.root .. "/.artemis/runtime-version", "rb"))
            assert.equals("0.7.2-1", generated:get_dependency("argparse").version)
            assert.equals("0.7.1-1", generated:get_dependency("luasystem").version)
            assert.is_true(generated:get_dependency("argparse").direct)
            assert.is_false(generated:get_dependency("luasystem").direct)

            success, err, runtime_version = project:sync()
            assert.is_true(success, err)
            assert.equals("5.4.9", runtime_version)

            local native_lock = assert(loadfile(captured_lock))()
            assert.same({
                argparse = "0.7.2-1",
                luasystem = "0.7.1-1",
                luassert = "1.9.0-1"
            }, native_lock.dependencies)
            assert.is_nil(io.open(root .. "/luarocks.lock", "rb"))
            assert.is_nil(io.open(root .. "/luarocks.lock.artemis-tmp", "rb"))
            assert.equals("install\ninstall\n", helpers.read_file(events))
        end)
    end)

    it("loads the manifest from disk and synchronizes a real Project instance end to end", function()
        helpers.with_temp_dir(function(root)
            local manifest = make_manifest()
            local manifest_path = root .. "/artemis-project.toml"
            assert.is_true(manifest:save(manifest_path))

            local luarocks, captured_lock = make_fake_luarocks(root)
            local project, project_error = Project.new(root, {
                cache_dir = root .. "/shared-cache",
                luarocks = luarocks,
                runtime_options = {}
            })
            assert.is_truthy(project, project_error)
            assert.equals(manifest_path, project.manifest_path)

            local runtime_capture = root .. "/fake-lua-arguments.txt"
            project.runtime_manager.install = function(runtime_manager, requested_version)
                local version = resolve_fake_runtime_version(requested_version)
                make_fake_runtime(project, version, runtime_capture)
                return true, nil, version
            end

            local success, sync_error, runtime_version = project:sync()
            assert.is_true(success, sync_error)
            assert.equals("5.4.9", runtime_version)

            local generated = assert(Lockfile.load(project.lockfile_path))
            assert.equals("0.7.2-1", generated:get_dependency("argparse").version)
            assert.equals("0.7.1-1", generated:get_dependency("luasystem").version)
            assert.equals("5.4.9", generated.data.project.runtime)
            assert.is_nil(io.open(captured_lock, "rb"))
        end)
    end)

    it("shares one global runtime cache across independent projects", function()
        helpers.with_temp_dir(function(root)
            local first_root = root .. "/first-project"
            local second_root = root .. "/second-project"
            local shared_cache = root .. "/shared-cache"
            helpers.make_directory(first_root)
            helpers.make_directory(second_root)

            local first_luarocks = make_fake_luarocks(first_root)
            local second_luarocks = make_fake_luarocks(second_root)
            local first_project, first_error = Project.new(first_root, {
                manifest = make_manifest(),
                cache_dir = shared_cache,
                luarocks = first_luarocks,
                runtime_options = {}
            })
            assert.is_truthy(first_project, first_error)

            local second_project, second_error = Project.new(second_root, {
                manifest = make_manifest(),
                cache_dir = shared_cache,
                luarocks = second_luarocks,
                runtime_options = {}
            })
            assert.is_truthy(second_project, second_error)
            assert.equals(first_project.runtime_manager.cache_dir, second_project.runtime_manager.cache_dir)

            local executable = first_project.runtime_manager.runtimes_dir .. "/5.4.9/bin/lua"
            helpers.make_directory(executable:match("^(.*)/lua$"))
            helpers.write_file(executable, "#!/bin/sh\necho Lua 5.4.9\n")
            helpers.make_executable(executable)

            assert.is_true(second_project.runtime_manager:is_installed("5.4.9"))
            local removed, remove_error = second_project.runtime_manager:uninstall("5.4.9")
            assert.is_true(removed, remove_error)
            assert.is_false(first_project.runtime_manager:is_installed("5.4.9"))
            assert.is_nil(io.open(first_root .. "/.artemis/runtime-version", "rb"))
            assert.is_nil(io.open(second_root .. "/.artemis/runtime-version", "rb"))
        end)
    end)

    it("runs a script through the selected project interpreter with safely quoted arguments", function()
        helpers.with_temp_dir(function(root)
            local project, _, _, argument_capture = new_project(root)
            local script_path = root .. "/main script.lua"
            helpers.write_file(script_path, "-- fake script file; fake interpreter records argv\n")

            local success, err = project:run("main script.lua", {
                "argument with spaces",
                "single'quote",
                "; this is not a shell command"
            })

            assert.is_true(success, err)
            assert.equals(table.concat({
                script_path,
                "argument with spaces",
                "single'quote",
                "; this is not a shell command",
                ""
            }, "\n"), helpers.read_file(argument_capture))
        end)
    end)

    it("does not write a lockfile when LuaRocks dependency installation fails", function()
        helpers.with_temp_dir(function(root)
            local project = new_project(root, 23)
            local success, err = project:sync()

            assert.is_false(success)
            assert.matches("Could not start LuaRocks", err)
            assert.is_nil(io.open(project.lockfile_path, "rb"))
        end)
    end)

    it("fails closed when the lockfile's recorded versions are not present after installation", function()
        helpers.with_temp_dir(function(root)
            local project, captured_lock = new_project(root)
            local initial_success, initial_error = project:sync()
            assert.is_true(initial_success, initial_error)

            local installed_file = root .. "/installed-rocks.txt"
            helpers.write_file(installed_file, "argparse 0.9.0-1\nluasystem 0.7.1-1\nluassert 1.9.0-1\n")

            local success, err = project:sync()
            assert.is_false(success)
            assert.matches("expected 0%.7%.2%-1", err)
            local captured_handle = io.open(captured_lock, "rb")
            assert.is_truthy(captured_handle)
            captured_handle:close()
        end)
    end)


    it("refreshes stale direct constraints using the newly resolved installed graph", function()
        helpers.with_temp_dir(function(root)
            local project, _, events = new_project(root)
            local initial_success, initial_error = project:sync()
            assert.is_true(initial_success, initial_error)

            assert.is_true(project.manifest:set_dependency("argparse", ">= 0.8, < 1.0"))
            helpers.write_file(root .. "/installed-rocks.txt", table.concat({
                "argparse 0.8.1-1",
                "luasystem 0.7.1-1",
                "luassert 1.9.0-1",
                ""
            }, "\n"))

            local success, err = project:sync()
            assert.is_true(success, err)

            local refreshed = assert(Lockfile.load(project.lockfile_path))
            assert.equals(">= 0.8, < 1.0", refreshed:get_dependency("argparse").constraint)
            assert.equals("0.8.1-1", refreshed:get_dependency("argparse").version)
            assert.equals("install\ninstall\n", helpers.read_file(events))
        end)
    end)

    it("propagates a non-zero exit status from the selected Lua interpreter", function()
        helpers.with_temp_dir(function(root)
            local project = new_project(root, 0, 17)
            helpers.write_file(root .. "/failing.lua", "error('intentional test failure')\n")

            local success, err = project:run("failing.lua")
            assert.is_false(success)
            assert.matches("Command failed %(status: 17%)", err)
        end)
    end)
end)
