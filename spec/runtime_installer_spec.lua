--- @diagnostic disable: undefined-global, undefined-field, missing-fields, assign-type-mismatch, param-type-mismatch, need-check-nil
local RuntimeManager = require("artemis.runtime_manager")
local helpers = require("spec.helpers")

local function make_manager(root, overrides)
    overrides = overrides or {}
    overrides.cache_dir = overrides.cache_dir or (root .. "/cache")
    local manager, err = RuntimeManager.new(overrides)
    assert(manager, err)
    return manager
end

local function make_runtime(manager, version)
    local executable = manager.runtimes_dir .. "/" .. version .. "/bin/lua"
    helpers.make_directory(executable:match("^(.*)/lua$"))
    helpers.write_file(executable, "#!/bin/sh\necho Lua " .. version .. "\n")
    helpers.make_executable(executable)
    return executable
end

describe("artemis.runtime_manager.runtime_installer archive handling", function()
    it("reuses a verified cached archive without invoking the downloader", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local installer = manager.installer
            local expected = string.rep("a", 64)
            helpers.make_directory(installer.downloads_dir)
            local archive = installer.downloads_dir .. "/lua-5.4.9.tar.gz"
            helpers.write_file(archive, "cached archive")
            installer.checksum = {
                sha256_file = function(path)
                    assert.equals(archive, path)
                    return expected
                end
            }
            installer.downloader = {
                download = function()
                    error("A verified cached archive should not be downloaded")
                end
            }

            local result, err = installer:_ensure_archive("5.4.9", expected)
            assert.is_nil(err)
            assert.equals(archive, result)
        end)
    end)

    it("rejects a downloaded archive whose checksum does not match", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local installer = manager.installer
            helpers.make_directory(installer.downloads_dir)
            installer.downloader = {
                download = function(_, destination)
                    helpers.write_file(destination, "not-a-real-lua-archive")
                    return true
                end
            }
            installer.checksum = {
                sha256_file = function()
                    return string.rep("b", 64)
                end
            }

            local archive, err = installer:_ensure_archive("5.4.9", string.rep("a", 64))
            assert.is_nil(archive)
            assert.matches("SHA%-256 mismatch", err)
            assert.is_nil(io.open(installer.downloads_dir .. "/lua-5.4.9.tar.gz.part", "rb"))
            assert.is_nil(io.open(installer.downloads_dir .. "/lua-5.4.9.tar.gz", "rb"))
        end)
    end)
end)

describe("artemis.runtime_manager.runtime_installer build pipeline", function()
    it("extracts, builds, tests, stages, verifies, and promotes a Lua runtime", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local installer = manager.installer
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

            installer.tar = fake_tar
            installer.make = fake_make
            local archive = root .. "/lua-5.4.9.tar.gz"
            helpers.write_file(archive, "fake archive input")

            local success, err = installer:_build_and_install("5.4.9", archive)
            assert.is_true(success, err)
            assert.is_true(manager:is_installed("5.4.9"))
            assert.equals(manager.runtimes_dir .. "/5.4.9", manager:get_install_path("5.4.9"))
            assert.equals(manager.runtimes_dir .. "/5.4.9/bin/lua", manager:get_executable("5.4.9"))
            assert.is_nil(io.open(installer.build_dir .. "/lua-5.4.9/staging/bin/lua", "rb"))
        end)
    end)

    it("does not replace an existing cached runtime when the rebuild fails", function()
        helpers.with_temp_dir(function(root)
            local manager = make_manager(root)
            local installer = manager.installer
            local existing = make_runtime(manager, "5.4.9")

            local failing_tar = root .. "/failing-tar"
            helpers.write_file(failing_tar, "#!/bin/sh\nexit 1\n")
            helpers.make_executable(failing_tar)
            installer.tar = failing_tar

            local archive = root .. "/lua-5.4.9.tar.gz"
            helpers.write_file(archive, "fake archive")
            local success, err = installer:_build_and_install("5.4.9", archive)

            assert.is_false(success)
            assert.matches("Could not extract Lua 5%.4%.9", err)
            assert.equals("#!/bin/sh\necho Lua 5.4.9\n", helpers.read_file(existing))
        end)
    end)

    it("requires an exact version and a SHA-256 checksum", function()
        helpers.with_temp_dir(function(root)
            local installer = make_manager(root).installer
            local success, err = installer:install("5.4", string.rep("a", 64))
            assert.is_false(success)
            assert.matches("exact Lua version", err)

            success, err = installer:install("5.4.0", "bad-checksum")
            assert.is_false(success)
            assert.matches("valid SHA%-256 checksum", err)
        end)
    end)
end)
