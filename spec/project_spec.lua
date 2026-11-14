---@diagnostic disable: undefined-global, undefined-field, missing-fields, assign-type-mismatch, param-type-mismatch, need-check-nil
local Project = require("artemis.project")
local Lockfile = require("artemis.lockfile")
local helpers = require("spec.helpers")

describe("artemis.project", function()
    local function make_manifest(constraint)
        return helpers.new_manifest({
            name = "sample-project",
            lua = "5.4",
            dependencies = constraint and { argparse = constraint } or {}
        })
    end

    local function make_project(root, manifest, installed_rocks)
        local dependency_manager = {
            sync_calls = {},
            verify_calls = {}
        }

        function dependency_manager:sync(locked_dependencies)
            self.sync_calls[#self.sync_calls + 1] = locked_dependencies
            return true
        end

        function dependency_manager:verify_locked(locked_dependencies)
            self.verify_calls[#self.verify_calls + 1] = locked_dependencies
            return true
        end

        function dependency_manager:list_installed()
            return installed_rocks or {}
        end

        local runtime_manager = {
            install_calls = {}
        }

        function runtime_manager:install(requested_version)
            self.install_calls[#self.install_calls + 1] = requested_version or "<manifest-default>"
            return true, nil, requested_version or "5.4.9"
        end

        function runtime_manager:get_install_path(version)
            return root .. "/shared-cache/runtimes/lua/" .. version
        end

        function runtime_manager:get_executable(version)
            return root .. "/shared-cache/runtimes/lua/" .. version .. "/bin/lua"
        end

        local project = setmetatable({
            root = root,
            manifest = manifest,
            manifest_path = root .. "/artemis-project.toml",
            lockfile_path = root .. "/artemis-project.lock",
            runtime_manager = runtime_manager,
            dependency_manager = dependency_manager,
            cache_dir = root .. "/shared-cache",
            metadata_dir = ".artemis",
            _dependency_options = {}
        }, Project)

        function project:_create_dependency_manager()
            return dependency_manager
        end

        return project, dependency_manager, runtime_manager
    end

    it("uses the exact runtime and dependency versions from a compatible lockfile", function()
        helpers.with_temp_dir(function(root)
            local manifest = make_manifest(">= 0.7")
            local lockfile = assert(Lockfile.from_installed(manifest, {
                { name = "argparse",  version = "0.7.2-1" },
                { name = "luasystem", version = "0.3.0-1" }
            }, { runtime_version = "5.4.9" }))
            local saved, save_error = lockfile:save(root .. "/artemis-project.lock")
            assert.is_true(saved, save_error)

            local project, dependency_manager, runtime_manager = make_project(root, manifest)
            local success, err, version = project:sync()

            assert.is_true(success, err)
            assert.equals("5.4.9", version)
            assert.equals("5.4.9", runtime_manager.install_calls[1])
            assert.equals("0.7.2-1", dependency_manager.sync_calls[1].argparse.version)
            assert.equals("0.3.0-1", dependency_manager.sync_calls[1].luasystem.version)
            assert.same(dependency_manager.sync_calls[1], dependency_manager.verify_calls[1])
        end)
    end)

    it("resolves dependencies and creates a lockfile when none exists", function()
        helpers.with_temp_dir(function(root)
            local manifest = make_manifest(">= 0.7")
            local project, dependency_manager = make_project(root, manifest, {
                { name = "argparse",  version = "0.7.2-1" },
                { name = "luasystem", version = "0.3.0-1" }
            })

            local success, err, version = project:sync()
            assert.is_true(success, err)
            assert.equals("5.4.9", version)
            assert.is_nil(dependency_manager.sync_calls[1])

            local saved_lockfile, load_error = Lockfile.load(project.lockfile_path)
            assert.is_truthy(saved_lockfile, load_error)
            assert.equals("5.4.9", saved_lockfile.data.project.runtime)
            assert.equals("0.7.2-1", saved_lockfile:get_dependency("argparse").version)
            assert.is_false(saved_lockfile:get_dependency("luasystem").direct)
        end)
    end)


    it("creates an empty lockfile without querying installed rocks for an empty project", function()
        helpers.with_temp_dir(function(root)
            local project, dependency_manager = make_project(root, make_manifest())
            local list_calls = 0
            dependency_manager.list_installed = function()
                list_calls = list_calls + 1
                return nil, "there should be no list call for an empty project"
            end

            local success, err = project:sync()
            assert.is_true(success, err)
            assert.equals(0, list_calls)

            local lockfile = assert(Lockfile.load(project.lockfile_path))
            assert.same({}, lockfile:get_dependencies())
            assert.equals("5.4.9", lockfile.data.project.runtime)
        end)
    end)

    it("refreshes a lockfile whose manifest constraints have changed", function()
        helpers.with_temp_dir(function(root)
            local old_manifest = make_manifest(">= 0.7")
            local old_lockfile = assert(Lockfile.from_installed(old_manifest, {
                { name = "argparse", version = "0.7.2-1" }
            }, { runtime_version = "5.4.9" }))
            assert.is_true(old_lockfile:save(root .. "/artemis-project.lock"))

            local current_manifest = make_manifest(">= 0.8")
            local project, dependency_manager = make_project(root, current_manifest, {
                { name = "argparse", version = "0.8.1-1" }
            })

            local success, err = project:sync()
            assert.is_true(success, err)
            assert.is_nil(dependency_manager.sync_calls[1])

            local refreshed = assert(Lockfile.load(project.lockfile_path))
            assert.equals(">= 0.8", refreshed:get_dependency("argparse").constraint)
            assert.equals("0.8.1-1", refreshed:get_dependency("argparse").version)
        end)
    end)

    it("fails before installation when an existing lockfile cannot be parsed", function()
        helpers.with_temp_dir(function(root)
            local manifest = make_manifest()
            helpers.write_file(root .. "/artemis-project.lock", "lockfile_version = [\n")
            local project, _, runtime_manager = make_project(root, manifest)

            local success, err = project:sync()
            assert.is_false(success)
            assert.matches("Could not load Artemis lockfile", err)
            assert.equals(0, #runtime_manager.install_calls)
        end)
    end)

    it("validates script paths and arguments before synchronizing", function()
        helpers.with_temp_dir(function(root)
            local project = make_project(root, make_manifest())

            local success, err = project:run(" ")
            assert.is_false(success)
            assert.matches("Script path", err)

            success, err = project:run("main.lua", { "valid", 42 })
            assert.is_false(success)
            assert.matches("must be a string", err)
        end)
    end)

    it("does not resolve LuaRocks paths when synchronization fails", function()
        helpers.with_temp_dir(function(root)
            local project, dependency_manager = make_project(root, make_manifest())
            local script_path = root .. "/main.lua"
            helpers.write_file(script_path, "print('not executed')\n")

            dependency_manager.sync = function()
                return false, "simulated dependency resolution failure"
            end

            local path_calls = 0
            dependency_manager.path = function()
                path_calls = path_calls + 1
                return "export LUA_PATH=unexpected"
            end

            local success, err = project:run("main.lua")
            assert.is_false(success)
            assert.matches("simulated dependency resolution failure", err)
            assert.equals(0, path_calls)
        end)
    end)

    it("does not replace its dependency manager when runtime executable lookup fails", function()
        helpers.with_temp_dir(function(root)
            local project, dependency_manager = make_project(root, make_manifest())
            project.runtime_manager.get_executable = function()
                return nil, "simulated missing interpreter"
            end

            local success, err = project:install_runtime()
            assert.is_false(success)
            assert.matches("simulated missing interpreter", err)
            assert.equals(dependency_manager, project.dependency_manager)
        end)
    end)

    it("resolves a custom nested lockfile path relative to the project root", function()
        helpers.with_temp_dir(function(root)
            local project, err = Project.new(root, {
                manifest = make_manifest(),
                lockfile_path = "locks/project.lock",
                cache_dir = root .. "/cache",
                runtime_options = { sha256sum = "sha256sum" }
            })

            assert.is_truthy(project, err)
            assert.equals(root .. "/locks/project.lock", project.lockfile_path)
        end)
    end)

    it("loads the default manifest and constructs both managers", function()
        helpers.with_temp_dir(function(root)
            local manifest = make_manifest(">= 0.7")
            assert.is_true(manifest:save(root .. "/artemis-project.toml"))

            local project, err = Project.new(root, {
                cache_dir = root .. "/shared-cache",
                luarocks = "luarocks-test",
                runtime_options = { sha256sum = "sha256sum" }
            })

            assert.is_truthy(project, err)
            assert.equals("sample-project", project.manifest.data.name)
            assert.equals(root .. "/artemis-project.toml", project.manifest_path)
            assert.equals(root .. "/artemis-project.lock", project.lockfile_path)
            assert.is_truthy(project.runtime_manager)
            assert.is_truthy(project.dependency_manager)
            assert.equals("lua_modules", project.dependency_manager:get_tree())
        end)
    end)

    it("returns a clear error when the default manifest is missing", function()
        helpers.with_temp_dir(function(root)
            local project, err = Project.new(root, {
                cache_dir = root .. "/cache",
                luarocks = "luarocks-test",
                runtime_options = { sha256sum = "sha256sum" }
            })
            assert.is_nil(project)
            assert.matches("Could not parse manifest", err)
        end)
    end)

    it("adds dependencies only after the runtime is ready and exposes safe dependency copies", function()
        helpers.with_temp_dir(function(root)
            local project, dependency_manager, runtime_manager = make_project(root, make_manifest())
            local add_call
            dependency_manager.add = function(_, package_name, constraint)
                add_call = { package_name, constraint }
                return true
            end

            local success, err = project:add_dependency("argparse", ">= 0.7")
            assert.is_true(success, err)
            assert.equals(1, #runtime_manager.install_calls)
            assert.same({ "argparse", ">= 0.7" }, add_call)

            local dependencies = project:get_dependencies()
            dependencies.argparse = "*"
            assert.is_nil(project.manifest:get_dependency("argparse"))
        end)
    end)

    it("removes dependencies without installing a runtime and exposes the legacy aliases", function()
        helpers.with_temp_dir(function(root)
            local manifest = make_manifest("0.7.2-1")
            local project, dependency_manager, runtime_manager = make_project(root, manifest)
            local removed
            dependency_manager.remove = function(_, package_name)
                removed = package_name
                return true
            end
            dependency_manager.add = function(_, package_name, constraint)
                return true, package_name .. ":" .. tostring(constraint)
            end

            local success, err = project:remove("argparse")
            assert.is_true(success, err)
            assert.equals("argparse", removed)
            assert.equals(0, #runtime_manager.install_calls)

            success, err = project:add("luasystem", "0.7.1-1")
            assert.is_true(success, err)
            assert.equals(1, #runtime_manager.install_calls)
        end)
    end)

    it("returns installed rocks through tree()", function()
        helpers.with_temp_dir(function(root)
            local installed = {
                { name = "argparse", version = "0.7.2-1" }
            }
            local project, dependency_manager = make_project(root, make_manifest(), installed)
            local list_calls = 0
            dependency_manager.list_installed = function()
                list_calls = list_calls + 1
                return installed
            end
            local rocks, err = project:tree()
            assert.is_truthy(rocks, err)
            assert.same(installed, rocks)
            assert.equals(1, list_calls)
        end)
    end)
end)

describe("artemis.project failure handling", function()
    local function make_manifest()
        return helpers.new_manifest({
            name = "failure-project",
            lua = "5.4",
            dependencies = { argparse = ">= 0.7" }
        })
    end

    local function make_project(root)
        local project = setmetatable({
            root = root,
            manifest = make_manifest(),
            manifest_path = root .. "/artemis-project.toml",
            lockfile_path = root .. "/artemis-project.lock",
            cache_dir = root .. "/cache",
            metadata_dir = ".artemis",
            _dependency_options = {},
            runtime_manager = {
                install = function()
                    return true, nil, "5.4.9"
                end,
                get_install_path = function()
                    return root .. "/cache/runtimes/lua/5.4.9"
                end,
                get_executable = function()
                    return root .. "/cache/runtimes/lua/5.4.9/bin/lua"
                end
            },
            dependency_manager = {
                sync = function() return true end,
                verify_locked = function() return true end,
                list_installed = function()
                    return { { name = "argparse", version = "0.7.2-1" } }
                end,
                path = function() return "export LUA_PATH=example" end
            }
        }, Project)
        function project:_create_dependency_manager()
            return self.dependency_manager
        end

        return project
    end

    it("stops synchronization when runtime installation fails", function()
        helpers.with_temp_dir(function(root)
            local project = make_project(root)
            project.runtime_manager.install = function()
                return false, "simulated runtime build error"
            end

            local success, err = project:sync()
            assert.is_false(success)
            assert.matches("simulated runtime build error", err)
            assert.is_nil(io.open(project.lockfile_path, "rb"))
        end)
    end)

    it("stops synchronization when dependency installation fails", function()
        helpers.with_temp_dir(function(root)
            local project = make_project(root)
            project.dependency_manager.sync = function()
                return false, "simulated rock installation error"
            end

            local success, err = project:sync()
            assert.is_false(success)
            assert.matches("simulated rock installation error", err)
            assert.is_nil(io.open(project.lockfile_path, "rb"))
        end)
    end)

    it("stops synchronization when exact locked versions cannot be verified", function()
        helpers.with_temp_dir(function(root)
            local manifest = make_manifest()
            local lockfile = assert(Lockfile.from_installed(manifest, {
                { name = "argparse", version = "0.7.2-1" }
            }, { runtime_version = "5.4.9" }))
            assert.is_true(lockfile:save(root .. "/artemis-project.lock"))

            local project = make_project(root)
            project.dependency_manager.verify_locked = function()
                return false, "simulated locked version mismatch"
            end

            local success, err = project:sync()
            assert.is_false(success)
            assert.matches("simulated locked version mismatch", err)
        end)
    end)

    it("rejects a missing script before invoking synchronization", function()
        helpers.with_temp_dir(function(root)
            local project = make_project(root)
            project.sync = function()
                error("sync should not run for a missing script")
            end

            local success, err = project:run("does-not-exist.lua")
            assert.is_false(success)
            assert.matches("does not exist", err)
        end)
    end)
end)
