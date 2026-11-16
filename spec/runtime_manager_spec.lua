--- @diagnostic disable: undefined-global, undefined-field, missing-fields, assign-type-mismatch, param-type-mismatch, need-check-nil
local RuntimeManager = require("artemis.runtime_manager")
local helpers = require("spec.helpers")

local function make_manager(root, overrides)
    overrides = overrides or {}
    local options = {}
    for key, value in pairs(overrides) do
        options[key] = value
    end
    options.cache_dir = options.cache_dir or (root .. "/shared-cache")

    local manager, err = RuntimeManager.new(options)
    assert(manager, err)
    return manager
end

local function make_runtime(manager, version)
    local executable = manager.runtimes_dir .. "/" .. version .. "/bin/lua"
    local directory = executable:match("^(.*)/lua$")
    helpers.make_directory(directory)
    helpers.write_file(executable, "#!/bin/sh\necho Lua " .. version .. "\n")
    helpers.make_executable(executable)
    return executable
end

local function with_environment(overrides, callback)
    local original_getenv = os.getenv
    os.getenv = function(name)
        if overrides[name] ~= nil then
            return overrides[name]
        end
        return original_getenv(name)
    end

    local results = { pcall(callback) }
    os.getenv = original_getenv
    if not results[1] then
        error(results[2], 0)
    end
    table.remove(results, 1)
    return table.unpack(results)
end

describe("artemis.runtime_manager construction", function()
    it("constructs without a project root or manifest", function()
        helpers.with_temp_dir(function(root)
            local manager, err = RuntimeManager.new({ cache_dir = root .. "/cache" })
            assert.is_truthy(manager, err)
            assert.equals(root .. "/cache", manager.cache_dir)
            assert.equals(root .. "/cache/downloads/lua", manager.downloads_dir)
            assert.equals(root .. "/cache/runtimes/lua", manager.runtimes_dir)
            assert.equals(root .. "/cache/build", manager.build_dir)
            assert.is_truthy(manager.installer)
            assert.is_truthy(manager.release_catalog)
            assert.is_nil(manager.project_root)
            assert.is_nil(manager.manifest)
        end)
    end)

    it("rejects malformed global configuration", function()
        local manager, err = RuntimeManager.new("/tmp/cache")
        assert.is_nil(manager)
        assert.matches("options must be a table", err)

        manager, err = RuntimeManager.new({ cache_dir = "" })
        assert.is_nil(manager)
        assert.matches("cache_dir must be a non%-empty path", err)

        manager, err = RuntimeManager.new({ cache_dir = "relative/cache" })
        assert.is_nil(manager)
        assert.matches("Could not detect home directory", err)

        manager, err = RuntimeManager.new({
            cache_dir = "/tmp/artemis-invalid-source-url-cache",
            source_url = "http://example.com/"
        })
        assert.is_nil(manager)
        assert.matches("must be an HTTPS URL", err)

        manager, err = RuntimeManager.new({ cache_dir = "/tmp/artemis-invalid-tool-cache", make = "" })
        assert.is_nil(manager)
        assert.matches("tar and make executable names must be non%-empty", err)
    end)

    it("prefers the explicit cache directory over environment defaults", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root, { cache_dir = root .. "/explicit-cache" })
            assert.equals(root .. "/explicit-cache", manager.cache_dir)
        end)
    end)

    it("uses ARTEMIS_CACHE_DIR when no explicit cache directory is supplied", function()
        helpers.with_temp_dir(function(root)
            with_environment({ ARTEMIS_CACHE_DIR = root .. "/environment-cache" }, function()
                local manager, err = RuntimeManager.new({})
                assert.is_truthy(manager, err)
                assert.equals(root .. "/environment-cache", manager.cache_dir)
            end)
        end)
    end)

    it("uses XDG_CACHE_HOME before HOME for the default cache", function()
        helpers.with_temp_dir(function(root)
            with_environment({
                ARTEMIS_CACHE_DIR = "",
                XDG_CACHE_HOME = root .. "/xdg",
                HOME = root .. "/home"
            }, function()
                local manager, err = RuntimeManager.new({})
                assert.is_truthy(manager, err)
                assert.equals(root .. "/xdg/artemis", manager.cache_dir)
            end)
        end)
    end)

    it("falls back to HOME when XDG_CACHE_HOME is not absolute", function()
        helpers.with_temp_dir(function(root)
            with_environment({
                ARTEMIS_CACHE_DIR = "",
                XDG_CACHE_HOME = "relative-xdg",
                HOME = root .. "/home"
            }, function()
                local manager, err = RuntimeManager.new({})
                assert.is_truthy(manager, err)
                assert.equals(root .. "/home/.cache/artemis", manager.cache_dir)
            end)
        end)
    end)

    it("supports home-relative cache paths and rejects named-user paths", function()
        helpers.with_temp_dir(function(root)
            with_environment({ HOME = root .. "/home" }, function()
                local manager, err = RuntimeManager.new({ cache_dir = "~/.cache/artemis-tests" })
                assert.is_truthy(manager, err)
                assert.equals(root .. "/home/.cache/artemis-tests", manager.cache_dir)

                manager, err = RuntimeManager.new({ cache_dir = "~someone/.cache/artemis" })
                assert.is_nil(manager)
                assert.matches("Named%-user home paths are not supported", err)
            end)
        end)
    end)
end)

describe("artemis.runtime_manager version resolution", function()
    it("rejects LuaJIT and malformed versions without network access", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local version, checksum, err = manager:resolve_version("luajit")
            assert.is_nil(version)
            assert.is_nil(checksum)
            assert.matches("LuaJIT is not supported", err)

            version, checksum, err = manager:resolve_version("5.x")
            assert.is_nil(version)
            assert.is_nil(checksum)
            assert.matches("Invalid Lua version", err)
        end)
    end)

    it("requires an explicit version for resolution and installation", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local version, checksum, err = manager:resolve_version(nil)
            assert.is_nil(version)
            assert.is_nil(checksum)
            assert.matches("No version was requested", err)

            local installed, install_error = manager:install(nil)
            assert.is_false(installed)
            assert.matches("No version was requested", install_error)
        end)
    end)

    it("resolves exact releases using the bundled official checksum catalog", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local version, checksum, err = manager:resolve_version("5.4.9")
            assert.is_nil(err)
            assert.equals("5.4.9", version)
            assert.equals("2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6", checksum)
        end)
    end)

    it("resolves a major.minor series to its catalog base release", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local version, checksum, err = manager:resolve_version("5.4")
            assert.is_nil(err)
            assert.equals("5.4.0", version)
            assert.equals("eac0836eb7219e421a96b7ee3692b93f0629e4cdb0c788432e3d10ce9ed47e28", checksum)
        end)
    end)

    it("uses an already installed series release before consulting the catalog", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            make_runtime(manager, "5.4.9")
            make_runtime(manager, "5.4.10")

            local version, checksum, err = manager:resolve_version("5.4")
            assert.is_nil(err)
            assert.equals("5.4.10", version)
            assert.is_nil(checksum)
        end)
    end)

    it("prefers a valid cached series mapping over another installed patch", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            make_runtime(manager, "5.4.8")
            make_runtime(manager, "5.4.10")
            helpers.make_directory(manager.cache_dir .. "/metadata")
            helpers.write_file(manager.cache_dir .. "/metadata/lua-series-5.4.txt", "5.4.8\n")

            local version, checksum, err = manager:resolve_version("5.4")
            assert.is_nil(err)
            assert.equals("5.4.8", version)
            assert.is_nil(checksum)
        end)
    end)
end)

describe("artemis.runtime_manager shared cache behavior", function()
    it("makes installations visible to independently constructed managers", function()
        helpers.with_temp_dir(function(root)
            local first = make_manager(root, { cache_dir = root .. "/shared-cache" })
            local second = make_manager(root, { cache_dir = root .. "/shared-cache" })
            make_runtime(first, "5.4.9")

            assert.is_true(second:is_installed("5.4.9"))
            assert.same({ "5.4.9" }, second:list_installed())
            assert.equals(first:get_install_path("5.4.9"), second:get_install_path("5.4.9"))
        end)
    end)

    it("isolates managers that use different cache directories", function()
        helpers.with_temp_dir(function(root)
            local first = make_manager(root, { cache_dir = root .. "/cache-a" })
            local second = make_manager(root, { cache_dir = root .. "/cache-b" })
            make_runtime(first, "5.4.9")

            assert.is_true(first:is_installed("5.4.9"))
            assert.is_false(second:is_installed("5.4.9"))
            assert.same({}, second:list_installed())
        end)
    end)

    it("allows one manager to remove a runtime shared by another manager", function()
        helpers.with_temp_dir(function(root)
            local first = make_manager(root, { cache_dir = root .. "/shared-cache" })
            local second = make_manager(root, { cache_dir = root .. "/shared-cache" })
            local executable = make_runtime(first, "5.4.9")

            local removed, err = second:uninstall("5.4.9")
            assert.is_true(removed, err)
            assert.is_false(first:is_installed("5.4.9"))
            assert.is_nil(io.open(executable, "rb"))
        end)
    end)

    it("lists only complete exact patch releases in numeric version order", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            make_runtime(manager, "5.4.9")
            make_runtime(manager, "5.3.6")
            make_runtime(manager, "5.4.10")
            local incomplete = manager.runtimes_dir .. "/5.4.11/bin"
            local malformed = manager.runtimes_dir .. "/5.4-dev/bin/lua"
            helpers.make_directory(incomplete)
            helpers.make_directory(malformed:match("^(.*)/lua$"))
            helpers.write_file(malformed, "#!/bin/sh\nexit 0\n")
            helpers.make_executable(malformed)

            assert.same({ "5.3.6", "5.4.9", "5.4.10" }, manager:list_installed())
            assert.same({ "5.3.6", "5.4.9", "5.4.10" }, manager:list())
        end)
    end)

    it("resolves a major.minor series to the highest installed patch when no mapping exists", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            make_runtime(manager, "5.4.8")
            make_runtime(manager, "5.4.10")

            assert.is_true(manager:is_installed("5.4"))
            assert.equals(manager.runtimes_dir .. "/5.4.10", manager:get_install_path("5.4"))
            assert.equals(manager.runtimes_dir .. "/5.4.10/bin/lua", manager:get_executable("5.4"))
        end)
    end)

    it("prefers a valid cached series mapping over another installed patch", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            make_runtime(manager, "5.4.8")
            make_runtime(manager, "5.4.10")
            helpers.make_directory(manager.cache_dir .. "/metadata")
            helpers.write_file(manager.cache_dir .. "/metadata/lua-series-5.4.txt", "5.4.8\n")

            assert.equals(manager.runtimes_dir .. "/5.4.8", manager:get_install_path("5.4"))
        end)
    end)

    it("removes a matching series mapping when its selected runtime is uninstalled", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            make_runtime(manager, "5.4.9")
            local mapping = manager.cache_dir .. "/metadata/lua-series-5.4.txt"
            helpers.make_directory(manager.cache_dir .. "/metadata")
            helpers.write_file(mapping, "5.4.9\n")

            local removed, err = manager:uninstall("5.4.9")
            assert.is_true(removed, err)
            assert.is_nil(io.open(mapping, "rb"))
        end)
    end)

    it("leaves an unrelated series mapping intact when removing another exact release", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            make_runtime(manager, "5.4.8")
            make_runtime(manager, "5.4.9")
            local mapping = manager.cache_dir .. "/metadata/lua-series-5.4.txt"
            helpers.make_directory(manager.cache_dir .. "/metadata")
            helpers.write_file(mapping, "5.4.8\n")

            local removed, err = manager:uninstall("5.4.9")
            assert.is_true(removed, err)
            assert.equals("5.4.8\n", helpers.read_file(mapping))
            assert.is_true(manager:is_installed("5.4"))
        end)
    end)

    it("supports the installed-check alias and rejects malformed offline checks", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            make_runtime(manager, "5.4.9")
            assert.is_true(manager:verify_existent("5.4.9"))

            local installed, err = manager:is_installed("5.x")
            assert.is_nil(installed)
            assert.matches("Invalid Lua version", err)
        end)
    end)

    it("uninstalls the selected release when given a version series", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local executable = make_runtime(manager, "5.4.9")
            local mapping = manager.cache_dir .. "/metadata/lua-series-5.4.txt"
            helpers.make_directory(manager.cache_dir .. "/metadata")
            helpers.write_file(mapping, "5.4.9\n")

            local removed, err = manager:uninstall("5.4")
            assert.is_true(removed, err)
            assert.is_nil(io.open(executable, "rb"))
            assert.is_nil(io.open(mapping, "rb"))
        end)
    end)

    it("reports missing exact runtimes and unresolved series clearly", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local path, err = manager:get_install_path("5.4")
            assert.is_nil(path)
            assert.matches("has not been resolved yet", err)

            local executable, executable_error = manager:get_executable("5.4.9")
            assert.is_nil(executable)
            assert.matches("not installed in the Artemis cache", executable_error)

            local removed, remove_error = manager:uninstall("5.4.9")
            assert.is_false(removed)
            assert.matches("is not installed", remove_error)
        end)
    end)

    it("does not touch project metadata when removing a global runtime", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            make_runtime(manager, "5.4.9")
            local project_metadata = root .. "/some-project/.artemis/runtime-version"
            helpers.make_directory(root .. "/some-project/.artemis")
            helpers.write_file(project_metadata, "5.4.9\n")

            local removed, err = manager:uninstall("5.4.9")
            assert.is_true(removed, err)
            assert.equals("5.4.9\n", helpers.read_file(project_metadata))
        end)
    end)
end)

describe("artemis.runtime_manager installation coordination", function()
    it("reuses an already installed exact runtime without resolving or building", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local executable = make_runtime(manager, "5.4.9")

            manager.resolve_version = function()
                error("resolve_version must not be called for an installed exact runtime")
            end
            manager.installer.install = function()
                error("installer must not be called for an installed exact runtime")
            end

            local success, err, version = manager:install("5.4.9")
            assert.is_true(success, err)
            assert.equals("5.4.9", version)
            assert.equals(manager.runtimes_dir .. "/5.4.9", manager:get_install_path("5.4.9"))
            assert.equals(executable, manager:get_executable("5.4.9"))
        end)
    end)

    it("delegates the exact resolved release to the installer and records a series mapping", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local expected_checksum = "eac0836eb7219e421a96b7ee3692b93f0629e4cdb0c788432e3d10ce9ed47e28"

            manager.installer.install = function(_, version, checksum)
                assert.equals("5.4.0", version)
                assert.equals(expected_checksum, checksum)
                make_runtime(manager, version)
                return true
            end

            local success, err, version = manager:install("5.4")
            assert.is_true(success, err)
            assert.equals("5.4.0", version)
            assert.equals("5.4.0\n", helpers.read_file(manager.cache_dir .. "/metadata/lua-series-5.4.txt"))
            assert.is_true(manager:is_installed("5.4"))
        end)
    end)

    it("does not write a series mapping when installation fails", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            manager.installer.install = function()
                return false, "simulated compiler failure"
            end

            local success, err = manager:install("5.4")
            assert.is_false(success)
            assert.matches("simulated compiler failure", err)
            assert.is_nil(io.open(manager.cache_dir .. "/metadata/lua-series-5.4.txt", "rb"))
        end)
    end)
end)
