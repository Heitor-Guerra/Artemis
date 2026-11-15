---@diagnostic disable: undefined-global, undefined-field, missing-fields, assign-type-mismatch, param-type-mismatch, need-check-nil
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

local function make_directory(path)
    local first, second, third = os.execute("mkdir -p " .. helpers.shell_quote(path))
    assert.is_true(helpers.command_succeeded(first, second, third))
end

local function make_runtime(manager, version)
    local executable = manager.runtimes_dir .. "/" .. version .. "/bin/lua"
    local directory = executable:match("^(.*)/lua$")
    make_directory(directory)
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

describe("artemis.runtime_manager global API", function()
    it("constructs without a project root or manifest", function()
        helpers.with_temp_dir(function(root)
            local manager, err = RuntimeManager.new({ cache_dir = root .. "/cache" })
            assert.is_truthy(manager, err)
            assert.equals(root .. "/cache", manager.cache_dir)
            assert.equals(root .. "/cache/downloads/lua", manager.downloads_dir)
            assert.equals(root .. "/cache/runtimes/lua", manager.runtimes_dir)
            assert.equals(root .. "/cache/build", manager.build_dir)
            assert.is_nil(manager.project_root)
            assert.is_nil(manager.manifest)
            assert.is_nil(manager.project_runtime_file)
            assert.is_nil(manager.metadata_dir)
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

        manager, err = RuntimeManager.new({ cache_dir = "/tmp/artemis-invalid-source-url-cache", source_url = "http://example.com/" })
        assert.is_nil(manager)
        assert.matches("must be an HTTPS URL", err)

        manager, err = RuntimeManager.new({ cache_dir = "/tmp/artemis-invalid-curl-cache", curl = "" })
        assert.is_nil(manager)
        assert.matches("executable names must be non%-empty", err)
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

    it("expands an explicit home-relative cache directory", function()
        helpers.with_temp_dir(function(root)
            with_environment({ HOME = root .. "/home" }, function()
                local manager, err = RuntimeManager.new({ cache_dir = "~/.cache/artemis-tests" })
                assert.is_truthy(manager, err)
                assert.equals(root .. "/home/.cache/artemis-tests", manager.cache_dir)
            end)
        end)
    end)

    it("rejects named-user home paths and missing home configuration", function()
        helpers.with_temp_dir(function(root)
            local manager, err = RuntimeManager.new({ cache_dir = "~someone/.cache/artemis" })
            assert.is_nil(manager)
            assert.matches("Named%-user home paths are not supported", err)

            with_environment({
                ARTEMIS_CACHE_DIR = "",
                XDG_CACHE_HOME = "relative-xdg",
                HOME = "relative-home"
            }, function()
                manager, err = RuntimeManager.new({})
                assert.is_nil(manager)
                assert.matches("Could not detect home directory", err)
            end)
        end)
    end)

    it("does not require any project metadata directories", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            assert.is_nil(manager.project_runtime_file)
            assert.is_nil(manager.metadata_dir)

            local installed = manager:list_installed()
            assert.same({}, installed)
            assert.is_nil(io.open(root .. "/.artemis/runtime-version", "rb"))
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

    it("resolves exact releases using the official checksum lookup", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local expected_checksum = string.rep("a", 64)
            manager._get_release_checksum = function(_, version)
                assert.equals("5.4.9", version)
                return expected_checksum
            end

            local version, checksum, err = manager:resolve_version("5.4.9")
            assert.is_nil(err)
            assert.equals("5.4.9", version)
            assert.equals(expected_checksum, checksum)
        end)
    end)

    it("selects the newest patch release from the requested series", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local checksum_old = string.rep("a", 64)
            local checksum_new = string.rep("b", 64)
            manager._fetch_release_index = function()
                return table.concat({
                    "<table>",
                    "<tr><td>lua-5.4.8.tar.gz</td><td>" .. checksum_old .. "</td></tr>",
                    "<tr><td>lua-5.4.10.tar.gz</td><td>" .. checksum_new .. "</td></tr>",
                    "<tr><td>lua-5.3.7.tar.gz</td><td>" .. checksum_old .. "</td></tr>",
                    "</table>"
                }, "\n")
            end

            local version, checksum, err = manager:resolve_version("5.4")
            assert.is_nil(err)
            assert.equals("5.4.10", version)
            assert.equals(checksum_new, checksum)
        end)
    end)

    it("parses release entries when the index uses non-table markup", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local old_checksum = string.rep("a", 64)
            local latest_checksum = string.rep("b", 64)
            manager._fetch_release_index = function()
                return table.concat({
                    "<html><body>",
                    "<div><a href=\"lua-5.4.8.tar.gz\">lua-5.4.8.tar.gz</a>",
                    "<span>SHA-256: " .. old_checksum .. "</span></div>",
                    "<div><a href=\"lua-5.4.9.tar.gz\">lua-5.4.9.tar.gz</a>",
                    "<span>SHA-256: " .. latest_checksum .. "</span></div>",
                    "</body></html>"
                }, "\n")
            end

            local version, checksum, err = manager:resolve_version("5.4")
            assert.is_nil(err)
            assert.equals("5.4.9", version)
            assert.equals(latest_checksum, checksum)
        end)
    end)

    it("uses an installed series mapping without fetching the release index", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            make_runtime(manager, "5.4.9")
            make_directory(manager.cache_dir .. "/metadata")
            helpers.write_file(manager.cache_dir .. "/metadata/lua-series-5.4.txt", "5.4.9\n")
            manager._fetch_release_index = function()
                error("A mapped installed series must not fetch the release index")
            end

            local version, checksum, err = manager:resolve_version("5.4")
            assert.is_nil(err)
            assert.equals("5.4.9", version)
            assert.is_nil(checksum)
        end)
    end)

    it("uses a cached checksum without a network request", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local expected = string.rep("A", 64)
            make_directory(manager.downloads_dir)
            helpers.write_file(manager.downloads_dir .. "/lua-5.4.9.sha256", expected .. "  lua-5.4.9.tar.gz\n")
            manager._fetch_release_index = function()
                error("Cached checksum should avoid a network request")
            end

            local checksum, err = manager:_get_release_checksum("5.4.9")
            assert.is_nil(err)
            assert.equals(expected:lower(), checksum)
        end)
    end)

    it("reuses a verified cached archive without invoking curl", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local expected = string.rep("a", 64)
            make_directory(manager.downloads_dir)
            local archive = manager.downloads_dir .. "/lua-5.4.9.tar.gz"
            helpers.write_file(archive, "cached archive")
            manager._sha256 = function(_, path)
                assert.equals(archive, path)
                return expected
            end
            manager.curl = root .. "/curl-that-must-not-run"

            local result, err = manager:_ensure_archive("5.4.9", expected)
            assert.is_nil(err)
            assert.equals(archive, result)
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

    it("lists only complete exact patch releases in sorted order", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            make_runtime(manager, "5.4.9")
            make_runtime(manager, "5.3.6")
            local incomplete = manager.runtimes_dir .. "/5.4.10/bin"
            local malformed = manager.runtimes_dir .. "/5.4-dev/bin/lua"
            local first, second, third = os.execute("mkdir -p " .. helpers.shell_quote(incomplete))
            assert.is_true(helpers.command_succeeded(first, second, third))
            local fourth, fifth, sixth = os.execute("mkdir -p " .. helpers.shell_quote(malformed:match("^(.*)/lua$")))
            assert.is_true(helpers.command_succeeded(fourth, fifth, sixth))
            helpers.write_file(malformed, "#!/bin/sh\nexit 0\n")
            helpers.make_executable(malformed)

            assert.same({ "5.3.6", "5.4.9" }, manager:list_installed())
            assert.same({ "5.3.6", "5.4.9" }, manager:list())
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
            make_directory(manager.cache_dir .. "/metadata")
            helpers.write_file(manager.cache_dir .. "/metadata/lua-series-5.4.txt", "5.4.8\n")

            assert.equals(manager.runtimes_dir .. "/5.4.8", manager:get_install_path("5.4"))
        end)
    end)

    it("removes a matching series mapping when its selected runtime is uninstalled", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            make_runtime(manager, "5.4.9")
            make_directory(manager.cache_dir .. "/metadata")
            local mapping = manager.cache_dir .. "/metadata/lua-series-5.4.txt"
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
            make_directory(manager.cache_dir .. "/metadata")
            local mapping = manager.cache_dir .. "/metadata/lua-series-5.4.txt"
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
            make_directory(manager.cache_dir .. "/metadata")
            helpers.write_file(manager.cache_dir .. "/metadata/lua-series-5.4.txt", "5.4.9\n")

            local removed, err = manager:uninstall("5.4")
            assert.is_true(removed, err)
            assert.is_nil(io.open(executable, "rb"))
            assert.is_nil(io.open(manager.cache_dir .. "/metadata/lua-series-5.4.txt", "rb"))
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
            local first, second, third = os.execute("mkdir -p " .. helpers.shell_quote(root .. "/some-project/.artemis"))
            assert.is_true(helpers.command_succeeded(first, second, third))
            helpers.write_file(project_metadata, "5.4.9\n")

            local removed, err = manager:uninstall("5.4.9")
            assert.is_true(removed, err)
            assert.equals("5.4.9\n", helpers.read_file(project_metadata))
        end)
    end)
end)

describe("artemis.runtime_manager installation", function()
    it("reuses an already installed exact runtime without resolving or building", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local executable = make_runtime(manager, "5.4.9")

            manager.resolve_version = function()
                error("resolve_version must not be called for an installed exact runtime")
            end

            local success, err, version = manager:install("5.4.9")
            assert.is_true(success, err)
            assert.equals("5.4.9", version)
            assert.equals(manager.runtimes_dir .. "/5.4.9", manager:get_install_path("5.4.9"))
            assert.equals(executable, manager:get_executable("5.4.9"))
            assert.is_nil(io.open(root .. "/.artemis/runtime-version", "rb"))
        end)
    end)

    it("installs a resolved series release and records its shared series mapping", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local archive = root .. "/lua-5.4.9.tar.gz"
            helpers.write_file(archive, "fixture archive")
            local expected_checksum = string.rep("a", 64)

            manager.resolve_version = function(_, requested)
                assert.equals("5.4", requested)
                return "5.4.9", expected_checksum
            end
            manager._ensure_archive = function(_, version, checksum)
                assert.equals("5.4.9", version)
                assert.equals(expected_checksum, checksum)
                return archive
            end
            manager._build_and_install = function(self, version)
                assert.equals("5.4.9", version)
                make_runtime(self, version)
                return true
            end

            local success, err, version = manager:install("5.4")
            assert.is_true(success, err)
            assert.equals("5.4.9", version)
            assert.equals("5.4.9\n", helpers.read_file(manager.cache_dir .. "/metadata/lua-series-5.4.txt"))
            assert.is_true(manager:is_installed("5.4"))
        end)
    end)

    it("does not write a series mapping when the build fails", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            manager.resolve_version = function()
                return "5.4.9", string.rep("a", 64)
            end
            manager._ensure_archive = function()
                return root .. "/lua-5.4.9.tar.gz"
            end
            manager._build_and_install = function()
                return false, "simulated compiler failure"
            end

            local success, err = manager:install("5.4")
            assert.is_false(success)
            assert.matches("simulated compiler failure", err)
            assert.is_nil(io.open(manager.cache_dir .. "/metadata/lua-series-5.4.txt", "rb"))
        end)
    end)

    it("rejects a downloaded archive whose checksum does not match", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local curl = root .. "/fake-curl"
            helpers.write_file(curl, table.concat({
                "#!/bin/sh",
                "while [ $# -gt 0 ]; do",
                "  if [ \"$1\" = --output ]; then shift; printf 'not-a-real-lua-archive' > \"$1\"; exit 0; fi",
                "  shift",
                "done",
                "exit 9",
                ""
            }, "\n"))
            helpers.make_executable(curl)
            make_directory(manager.downloads_dir)
            manager.curl = curl
            manager._sha256 = function()
                return string.rep("b", 64)
            end

            local archive, err = manager:_ensure_archive("5.4.9", string.rep("a", 64))
            assert.is_nil(archive)
            assert.matches("SHA%-256 mismatch", err)
            assert.is_nil(io.open(manager.downloads_dir .. "/lua-5.4.9.tar.gz.part", "rb"))
            assert.is_nil(io.open(manager.downloads_dir .. "/lua-5.4.9.tar.gz", "rb"))
        end)
    end)
end)

describe("artemis.runtime_manager build pipeline", function()
    it("extracts, builds, tests, stages, verifies, and promotes a Lua runtime", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local fake_tar = root .. "/fake-tar"
            local fake_make = root .. "/fake-make"

            helpers.write_file(fake_tar, table.concat({
                "#!/bin/sh",
                "[ \"$1\" = -xzf ] || exit 31",
                "archive=\"$2\"",
                "shift 2",
                "[ \"$1\" = -C ] || exit 32",
                "destination=\"$2\"",
                "version=\"${archive##*/lua-}\"",
                "version=\"${version%.tar.gz}\"",
                "mkdir -p \"$destination/lua-$version\"",
                ""
            }, "\n"))
            helpers.make_executable(fake_tar)

            helpers.write_file(fake_make, table.concat({
                "#!/bin/sh",
                "case \"$1\" in",
                "  all|test) exit 0 ;;",
                "  install)",
                "    top=\"${2#INSTALL_TOP=}\"",
                "    mkdir -p \"$top/bin\"",
                "    printf '%s\\n' '#!/bin/sh' 'echo Lua 5.4.9' 'exit 0' > \"$top/bin/lua\"",
                "    chmod +x \"$top/bin/lua\"",
                "    exit 0",
                "    ;;",
                "  *) exit 33 ;;",
                "esac",
                ""
            }, "\n"))
            helpers.make_executable(fake_make)

            manager.tar = fake_tar
            manager.make = fake_make
            local archive = root .. "/lua-5.4.9.tar.gz"
            helpers.write_file(archive, "fake archive input")

            local success, err = manager:_build_and_install("5.4.9", archive)
            assert.is_true(success, err)
            assert.is_true(manager:is_installed("5.4.9"))
            assert.equals(manager.runtimes_dir .. "/5.4.9", manager:get_install_path("5.4.9"))
            assert.equals(manager.runtimes_dir .. "/5.4.9/bin/lua", manager:get_executable("5.4.9"))
            assert.is_nil(io.open(manager.build_dir .. "/lua-5.4.9/staging/bin/lua", "rb"))
        end)
    end)

    it("does not replace an existing cached runtime when the rebuild fails", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local existing = make_runtime(manager, "5.4.9")

            local failing_tar = root .. "/failing-tar"
            helpers.write_file(failing_tar, "#!/bin/sh\nexit 1\n")
            helpers.make_executable(failing_tar)
            manager.tar = failing_tar

            local archive = root .. "/lua-5.4.9.tar.gz"
            helpers.write_file(archive, "fake archive")
            local success, err = manager:_build_and_install("5.4.9", archive)

            assert.is_false(success)
            assert.matches("Could not extract Lua 5%.4%.9", err)
            assert.equals("#!/bin/sh\necho Lua 5.4.9\n", helpers.read_file(existing))
        end)
    end)
end)
