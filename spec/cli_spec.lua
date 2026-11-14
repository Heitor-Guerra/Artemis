--- @diagnostic disable: undefined-global, undefined-field, missing-fields, assign-type-mismatch, param-type-mismatch, need-check-nil
local CLI = require("artemis.cli")
local Manifest = require("artemis.manifest")
local helpers = require("spec.helpers")

local function capture_writer()
    local lines = {}
    return function(message)
        lines[#lines + 1] = message
    end, lines
end

local function make_project(overrides)
    overrides = overrides or {}
    local project = {
        root = "/tmp/artemis-cli-project",
        manifest = {
            data = {
                name = "cli-project",
                lua = "5.4",
                main = "src/main.lua"
            }
        },
        runtime_manager = {},
        sync_calls = 0,
        add_calls = {},
        remove_calls = {},
        run_calls = {}
    }

    function project.runtime_manager:list_installed()
        return { "5.4.9", "5.3.6" }
    end

    function project.runtime_manager:uninstall(version)
        project.last_uninstalled_runtime = version
        return true
    end

    function project:sync()
        self.sync_calls = self.sync_calls + 1
        if overrides.sync_result ~= nil then
            return overrides.sync_result, overrides.sync_error, overrides.runtime_version or "5.4.9"
        end
        return true, nil, overrides.runtime_version or "5.4.9"
    end

    function project:add_dependency(name, constraint)
        self.add_calls[#self.add_calls + 1] = { name, constraint }
        if overrides.add_result ~= nil then
            return overrides.add_result, overrides.add_error
        end
        return true
    end

    function project:remove_dependency(name)
        self.remove_calls[#self.remove_calls + 1] = name
        if overrides.remove_result ~= nil then
            return overrides.remove_result, overrides.remove_warning
        end
        return true, overrides.remove_warning
    end

    function project:list_installed()
        if overrides.list_error then
            return nil, overrides.list_error
        end
        return overrides.rocks or {
            { name = "luasystem", version = "0.7.1-1" },
            { name = "argparse", version = "0.7.2-1" }
        }
    end

    function project:tree()
        return self:list_installed()
    end

    function project:get_dependencies()
        return overrides.dependencies or { argparse = ">= 0.7" }
    end

    function project:run(script, arguments)
        self.run_calls[#self.run_calls + 1] = { script, arguments }
        if overrides.run_result ~= nil then
            return overrides.run_result, overrides.run_error
        end
        return true
    end

    function project:install_runtime(version)
        self.last_installed_runtime = version
        if overrides.runtime_install_result ~= nil then
            return overrides.runtime_install_result, overrides.runtime_install_error, version or "5.4.9"
        end
        return true, nil, version or "5.4.9"
    end

    return project
end

local function make_services(project)
    local stdout, output = capture_writer()
    local stderr, errors = capture_writer()
    local created_project
    local created_options

    return {
        stdout = stdout,
        stderr = stderr,
        project_factory = function(root, options)
            created_project = project
            created_options = { root = root, options = options }
            return project
        end
    }, output, errors, function()
        return created_project, created_options
    end
end

describe("artemis.cli parser", function()
    it("parses global project options before a command", function()
        local parser = CLI.build_parser()
        local parsed_ok, arguments = parser:pparse({
            "-C", "../sample",
            "--manifest", "custom.toml",
            "--lockfile", "custom.lock",
            "sync"
        })

        assert.is_true(parsed_ok)
        assert.equals("sync", arguments.command)
        assert.equals("../sample", arguments.directory)
        assert.equals("custom.toml", arguments.manifest)
        assert.equals("custom.lock", arguments.lockfile)
    end)

    it("accepts global project options after the command", function()
        local parsed_ok, arguments = CLI.build_parser():pparse({
            "sync",
            "-C", "../sample",
            "--manifest", "custom.toml"
        })

        assert.is_true(parsed_ok)
        assert.equals("sync", arguments.command)
        assert.equals("../sample", arguments.directory)
        assert.equals("custom.toml", arguments.manifest)
    end)

    it("parses an optional dependency constraint", function()
        local parsed_ok, arguments = CLI.build_parser():pparse({ "add", "argparse", ">= 0.7, < 1.0" })

        assert.is_true(parsed_ok)
        assert.equals("add", arguments.command)
        assert.equals("argparse", arguments.package)
        assert.equals(">= 0.7, < 1.0", arguments.constraint)
    end)

    it("parses script arguments after the option terminator", function()
        local parsed_ok, arguments = CLI.build_parser():pparse({
            "run", "src/main.lua", "--", "--trace", "argument with spaces"
        })

        assert.is_true(parsed_ok)
        assert.equals("run", arguments.command)
        assert.equals("src/main.lua", arguments.script)
        assert.same({ "--trace", "argument with spaces" }, arguments.script_args)
    end)

    it("parses nested runtime commands", function()
        local parsed_ok, arguments = CLI.build_parser():pparse({ "runtime", "install", "5.4.9" })

        assert.is_true(parsed_ok)
        assert.equals("runtime", arguments.command)
        assert.equals("install", arguments.runtime_command)
        assert.equals("5.4.9", arguments.lua_version)
    end)


    it("accepts the ls alias for the installed-rock listing", function()
        local parsed_ok, arguments = CLI.build_parser():pparse({ "ls" })

        assert.is_true(parsed_ok)
        assert.equals("list", arguments.command)
    end)

    it("parses the global version flag without a subcommand", function()
        local parsed_ok, arguments = CLI.build_parser():pparse({ "--version" })

        assert.is_true(parsed_ok)
        assert.is_true(arguments.show_version)
        assert.is_nil(arguments.command)
    end)

    it("keeps a custom cache directory in the parsed project options", function()
        local parsed_ok, arguments = CLI.build_parser():pparse({
            "--cache-dir", "/tmp/artemis-cache",
            "sync"
        })

        assert.is_true(parsed_ok)
        assert.equals("/tmp/artemis-cache", arguments.cache_dir)
    end)

    it("provides generated help text when no command is selected", function()
        local parser = CLI.build_parser()
        local parsed_ok, arguments = parser:pparse({})

        assert.is_true(parsed_ok)
        assert.is_nil(arguments.command)
        assert.is_truthy(parser:get_help():find("sync", 1, true))
        assert.is_truthy(parser:get_help():find("runtime", 1, true))
    end)
end)

describe("artemis.cli command dispatch", function()
    it("prints the generated top-level help when no command is selected", function()
        local stdout, output = capture_writer()
        local stderr, errors = capture_writer()
        local exit_code = CLI.main({}, { stdout = stdout, stderr = stderr })

        assert.equals(0, exit_code)
        assert.is_truthy(output[1]:find("Usage:", 1, true))
        assert.equals(0, #errors)
    end)

    it("synchronizes a project using the selected project options", function()
        local project = make_project()
        local services, output, _, captured = make_services(project)
        local exit_code = CLI.main({ "-C", "sample", "--manifest", "custom.toml", "sync" }, services)
        local created, configuration = captured()

        assert.equals(0, exit_code)
        assert.equals(1, project.sync_calls)
        assert.equals("sample", configuration.root)
        assert.equals("custom.toml", configuration.options.manifest_path)
        assert.equals("artemis-project.lock", configuration.options.lockfile_path)
        assert.equals("Synchronized 'cli-project' with Lua 5.4.9.", output[1])
        assert.is_truthy(created)
    end)

    it("adds a dependency and refreshes the Artemis lockfile", function()
        local project = make_project()
        local services, output = make_services(project)
        local exit_code = CLI.execute({
            command = "add",
            package = "argparse",
            constraint = ">= 0.7"
        }, services)

        assert.equals(0, exit_code)
        assert.same({ { "argparse", ">= 0.7" } }, project.add_calls)
        assert.equals(1, project.sync_calls)
        assert.equals("Added dependency 'argparse' (>= 0.7).", output[1])
    end)

    it("reports an add failure without attempting a lockfile refresh", function()
        local project = make_project({ add_result = false, add_error = "resolution failed" })
        local services, _, errors = make_services(project)
        local exit_code = CLI.execute({ command = "add", package = "missing-rock" }, services)

        assert.equals(1, exit_code)
        assert.equals(0, project.sync_calls)
        assert.matches("resolution failed", errors[1])
    end)

    it("removes a dependency and refreshes the lockfile", function()
        local project = make_project()
        local services, output = make_services(project)
        local exit_code = CLI.execute({ command = "remove", package = "argparse" }, services)

        assert.equals(0, exit_code)
        assert.same({ "argparse" }, project.remove_calls)
        assert.equals(1, project.sync_calls)
        assert.equals("Removed dependency 'argparse'.", output[1])
    end)

    it("prints a warning when LuaRocks retains a removed transitive rock", function()
        local project = make_project({ remove_warning = "rock is still required by another package" })
        local services, output, errors = make_services(project)
        local exit_code = CLI.execute({ command = "remove", package = "argparse" }, services)

        assert.equals(0, exit_code)
        assert.matches("warning: rock is still required", errors[1])
        assert.equals("Removed dependency 'argparse'.", output[1])
    end)

    it("lists installed rocks in stable name order and labels direct dependencies", function()
        local project = make_project()
        local services, output = make_services(project)
        local exit_code = CLI.execute({ command = "list" }, services)

        assert.equals(0, exit_code)
        assert.matches("Installed rocks for cli%-project", output[1])
        assert.matches("argparse%s+0%.7%.2%-1 %(direct%)", output[2])
        assert.matches("luasystem%s+0%.7%.1%-1 %(transitive%)", output[3])
    end)

    it("prints an honest flat installed-rock listing for tree", function()
        local project = make_project()
        local services, output = make_services(project)
        local exit_code = CLI.execute({ command = "tree" }, services)

        assert.equals(0, exit_code)
        assert.equals("cli-project", output[1])
        assert.matches("argparse 0%.7%.2%-1 %(direct%)", output[2])
        assert.matches("flat installed%-rock listing", output[4])
    end)

    it("runs the manifest main script when no explicit script is provided", function()
        local project = make_project()
        local services, output = make_services(project)
        local exit_code = CLI.execute({ command = "run" }, services)

        assert.equals(0, exit_code)
        assert.same({ { "src/main.lua", {} } }, project.run_calls)
        assert.equals("Finished running 'src/main.lua'.", output[1])
    end)

    it("passes explicit script arguments through to Project.run", function()
        local project = make_project()
        local services = make_services(project)
        local exit_code = CLI.execute({
            command = "run",
            script = "scripts/task.lua",
            script_args = { "one", "two words" }
        }, services)

        assert.equals(0, exit_code)
        assert.same({ { "scripts/task.lua", { "one", "two words" } } }, project.run_calls)
    end)

    it("fails when run has neither an explicit script nor a manifest main entry", function()
        local project = make_project()
        project.manifest.data.main = nil
        local services, _, errors = make_services(project)
        local exit_code = CLI.execute({ command = "run" }, services)

        assert.equals(1, exit_code)
        assert.matches("manifest has no 'main' entry", errors[1])
        assert.equals(0, #project.run_calls)
    end)

    it("installs the manifest Lua runtime by default", function()
        local project = make_project()
        local services, output = make_services(project)
        local exit_code = CLI.execute({ command = "runtime", runtime_command = "install" }, services)

        assert.equals(0, exit_code)
        assert.is_nil(project.last_installed_runtime)
        assert.matches("Lua 5%.4%.9 is installed", output[1])
    end)

    it("lists runtimes stored in the shared cache", function()
        local project = make_project()
        local services, output = make_services(project)
        local exit_code = CLI.execute({ command = "runtime", runtime_command = "list" }, services)

        assert.equals(0, exit_code)
        assert.equals("Cached Lua runtimes:", output[1])
        assert.equals("  5.3.6", output[2])
        assert.equals("  5.4.9", output[3])
    end)

    it("removes a selected cached runtime", function()
        local project = make_project()
        local services, output = make_services(project)
        local exit_code = CLI.execute({
            command = "runtime",
            runtime_command = "remove",
            lua_version = "5.3.6"
        }, services)

        assert.equals(0, exit_code)
        assert.equals("5.3.6", project.last_uninstalled_runtime)
        assert.matches("shared cache", output[1])
    end)

    it("returns a nonzero status when the project cannot be opened", function()
        local stdout, output = capture_writer()
        local stderr, errors = capture_writer()
        local services = {
            stdout = stdout,
            stderr = stderr,
            project_factory = function()
                return nil, "manifest not found"
            end
        }
        local exit_code = CLI.execute({ command = "sync" }, services)

        assert.equals(1, exit_code)
        assert.matches("manifest not found", errors[1])
        assert.equals(0, #output)
    end)
end)

describe("artemis.cli failure handling", function()
    it("returns a nonzero status when synchronization fails", function()
        local project = make_project({ sync_result = false, sync_error = "runtime build failed" })
        local services, output, errors = make_services(project)
        local exit_code = CLI.execute({ command = "sync" }, services)

        assert.equals(1, exit_code)
        assert.matches("runtime build failed", errors[1])
        assert.equals(0, #output)
    end)

    it("reports a lockfile refresh failure after adding a dependency", function()
        local project = make_project({ sync_result = false, sync_error = "lockfile write failed" })
        local services, _, errors = make_services(project)
        local exit_code = CLI.execute({ command = "add", package = "argparse" }, services)

        assert.equals(1, exit_code)
        assert.matches("was added, but the lockfile could not be refreshed", errors[1])
        assert.matches("lockfile write failed", errors[1])
    end)

    it("does not refresh the lockfile when removing an undeclared dependency fails", function()
        local project = make_project({ remove_result = false, remove_warning = "Dependency is not declared." })
        local services, _, errors = make_services(project)
        local exit_code = CLI.execute({ command = "remove", package = "unknown" }, services)

        assert.equals(1, exit_code)
        assert.equals(0, project.sync_calls)
        assert.matches("not declared", errors[1])
    end)

    it("reports installed-rock listing failures", function()
        local project = make_project({ list_error = "LuaRocks list failed" })
        local services, output, errors = make_services(project)
        local exit_code = CLI.execute({ command = "list" }, services)

        assert.equals(1, exit_code)
        assert.equals(0, #output)
        assert.matches("LuaRocks list failed", errors[1])
    end)

    it("reports script execution failures", function()
        local project = make_project({ run_result = false, run_error = "script exited with status 2" })
        local services, output, errors = make_services(project)
        local exit_code = CLI.execute({ command = "run" }, services)

        assert.equals(1, exit_code)
        assert.equals(0, #output)
        assert.matches("script exited with status 2", errors[1])
    end)

    it("reports runtime installation failures", function()
        local project = make_project({
            runtime_install_result = false,
            runtime_install_error = "could not compile Lua"
        })
        local services, output, errors = make_services(project)
        local exit_code = CLI.execute({ command = "runtime", runtime_command = "install" }, services)

        assert.equals(1, exit_code)
        assert.equals(0, #output)
        assert.matches("could not compile Lua", errors[1])
    end)

    it("reports parser errors with the command usage", function()
        local stdout, output = capture_writer()
        local stderr, errors = capture_writer()
        local exit_code = CLI.main({ "add" }, { stdout = stdout, stderr = stderr })

        assert.equals(2, exit_code)
        assert.is_truthy(errors[1]:find("Usage:", 1, true))
        assert.matches("Error:", errors[2])
        assert.equals(0, #output)
    end)

    it("prints the CLI version", function()
        local stdout, output = capture_writer()
        local stderr, errors = capture_writer()
        local exit_code = CLI.main({ "--version" }, { stdout = stdout, stderr = stderr })

        assert.equals(0, exit_code)
        assert.equals("artemis " .. CLI.VERSION, output[1])
        assert.equals(0, #errors)
    end)
end)

describe("artemis.cli project initialization", function()
    it("creates a manifest and a starter script", function()
        helpers.with_temp_dir(function(root)
            local stdout, output = capture_writer()
            local stderr, errors = capture_writer()
            local exit_code = CLI.execute({
                command = "init",
                directory = root,
                name = "new-project",
                lua_version = "5.4",
                main = "src/main.lua"
            }, {
                stdout = stdout,
                stderr = stderr
            })

            assert.equals(0, exit_code)
            assert.equals(0, #errors)

            local manifest, load_error = Manifest.load(root .. "/artemis-project.toml")
            assert.is_truthy(manifest, load_error)
            assert.equals("new-project", manifest.data.name)
            assert.equals("5.4", manifest.data.lua)
            assert.equals("src/main.lua", manifest.data.main)
            assert.same({}, manifest:get_dependencies())
            assert.matches("Hello from new%-project", helpers.read_file(root .. "/src/main.lua"))
            assert.matches("Initialized project", output[1])
        end)
    end)

    it("derives the project name from the target directory when omitted", function()
        helpers.with_temp_dir(function(root)
            local stdout = capture_writer()
            local stderr = capture_writer()
            local exit_code = CLI.execute({ command = "init", directory = root }, {
                stdout = stdout,
                stderr = stderr
            })

            assert.equals(0, exit_code)
            local manifest = assert(Manifest.load(root .. "/artemis-project.toml"))
            assert.equals(root:match("([^/]+)$"), manifest.data.name)
        end)
    end)

    it("refuses to overwrite an existing manifest unless force is requested", function()
        helpers.with_temp_dir(function(root)
            local manifest_path = root .. "/artemis-project.toml"
            helpers.write_file(manifest_path, "name = 'keep-me'\nlua = '5.4'\n")
            local stdout = capture_writer()
            local stderr, errors = capture_writer()

            local exit_code = CLI.execute({ command = "init", directory = root, name = "replace-me" }, {
                stdout = stdout,
                stderr = stderr
            })

            assert.equals(1, exit_code)
            assert.matches("already exists", errors[1])
            assert.matches("keep%-me", helpers.read_file(manifest_path))
        end)
    end)

    it("allows an explicit force overwrite of the manifest", function()
        helpers.with_temp_dir(function(root)
            helpers.write_file(root .. "/artemis-project.toml", "name = 'old'\nlua = '5.4'\n")
            local stdout = capture_writer()
            local stderr = capture_writer()
            local exit_code = CLI.execute({
                command = "init",
                directory = root,
                name = "updated",
                force = true
            }, {
                stdout = stdout,
                stderr = stderr
            })

            assert.equals(0, exit_code)
            local manifest = assert(Manifest.load(root .. "/artemis-project.toml"))
            assert.equals("updated", manifest.data.name)
        end)
    end)

    it("rejects an entry-point path that escapes the project directory", function()
        helpers.with_temp_dir(function(root)
            local stdout = capture_writer()
            local stderr, errors = capture_writer()
            local exit_code = CLI.execute({
                command = "init",
                directory = root,
                main = "../outside.lua"
            }, {
                stdout = stdout,
                stderr = stderr
            })

            assert.equals(1, exit_code)
            assert.matches("cannot contain '..'", errors[1])
            local manifest_file = io.open(root .. "/artemis-project.toml", "rb")
            assert.is_nil(manifest_file)
        end)
    end)
end)
