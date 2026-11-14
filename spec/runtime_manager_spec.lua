---@diagnostic disable: undefined-global, undefined-field, missing-fields, assign-type-mismatch, param-type-mismatch, need-check-nil
local RuntimeManager = require("artemis.runtime_manager")
local helpers = require("spec.helpers")

describe("artemis.runtime_manager", function()
  local function make_manifest(lua_version)
    return helpers.new_manifest({
      name = "sample-project",
      lua = lua_version or "5.4"
    })
  end

  local function make_manager(root)
    local manager, err = RuntimeManager.new(root, make_manifest(), {
      cache_dir = root .. "/shared-cache",
      metadata_dir = ".artemis",
      sha256sum = "sha256sum"
    })
    assert(manager, err)
    return manager
  end

  it("rejects invalid roots and malformed runtime configuration", function()
    local manager, err = RuntimeManager.new("", make_manifest())
    assert.is_nil(manager)
    assert.matches("Project root", err)

    helpers.with_temp_dir(function(root)
      manager, err = RuntimeManager.new(root, make_manifest(), {
        cache_dir = root .. "/cache",
        metadata_dir = "/absolute/path",
        sha256sum = "sha256sum"
      })
      assert.is_nil(manager)
      assert.matches("relative path", err)
    end)
  end)

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

  it("reuses an already installed exact runtime without downloading or building", function()
    helpers.with_temp_dir(function(root)
      local manager = make_manager(root)
      local runtime_path = manager.runtimes_dir .. "/5.4.9"
      local executable = runtime_path .. "/bin/lua"
      os.execute("mkdir -p " .. helpers.shell_quote(runtime_path .. "/bin"))
      helpers.write_file(executable, "#!/bin/sh\necho Lua 5.4.9\n")
      helpers.make_executable(executable)

      manager.resolve_version = function()
        error("resolve_version must not be called for an installed exact runtime")
      end

      local success, err, version = manager:install("5.4.9")
      assert.is_true(success, err)
      assert.equals("5.4.9", version)
      assert.equals("5.4.9\n", helpers.read_file(manager.project_runtime_file))
      assert.equals(runtime_path, manager:get_install_path("5.4.9"))
      assert.equals(executable, manager:get_executable("5.4.9"))
    end)
  end)

  it("uninstalls an exact runtime and clears a matching project selection", function()
    helpers.with_temp_dir(function(root)
      local manager = make_manager(root)
      local runtime_path = manager.runtimes_dir .. "/5.4.9"
      local executable = runtime_path .. "/bin/lua"
      os.execute("mkdir -p " .. helpers.shell_quote(runtime_path .. "/bin"))
      helpers.write_file(executable, "#!/bin/sh\nexit 0\n")
      helpers.make_executable(executable)
      os.execute("mkdir -p " .. helpers.shell_quote(manager.metadata_dir))
      helpers.write_file(manager.project_runtime_file, "5.4.9\n")

      local success, err = manager:uninstall("5.4.9")
      assert.is_true(success, err)
      assert.is_nil(io.open(executable, "rb"))
      assert.is_nil(io.open(manager.project_runtime_file, "rb"))
    end)
  end)

  it("reports cached runtimes and lists exact installed releases", function()
    helpers.with_temp_dir(function(root)
      local manager = make_manager(root)
      local executable = manager.runtimes_dir .. "/5.4.9/bin/lua"
      os.execute("mkdir -p " .. helpers.shell_quote(manager.runtimes_dir .. "/5.4.9/bin"))
      helpers.write_file(executable, "#!/bin/sh\nexit 0\n")
      helpers.make_executable(executable)

      assert.is_true(manager:is_installed("5.4.9"))
      assert.same({ "5.4.9" }, manager:list_installed())
      assert.is_false(manager:is_installed("5.4.8"))
    end)
  end)
end)

describe("artemis.runtime_manager cache and offline behavior", function()
  local function make_manifest(lua_version)
    return helpers.new_manifest({
      name = "runtime-cache-project",
      lua = lua_version or "5.4"
    })
  end

  local function make_manager(root)
    local manager, err = RuntimeManager.new(root, make_manifest(), {
      cache_dir = root .. "/shared-cache",
      metadata_dir = ".artemis",
      sha256sum = "sha256sum"
    })
    assert(manager, err)
    return manager
  end

  it("expands an explicit home-relative runtime cache path", function()
    helpers.with_temp_dir(function(root)
      local home = assert(os.getenv("HOME"), "HOME must be set for this test")
      local manager, err = RuntimeManager.new(root, make_manifest(), {
        cache_dir = "~/.cache/artemis-runtime-tests",
        sha256sum = "sha256sum"
      })
      assert.is_truthy(manager, err)
      assert.equals(home .. "/.cache/artemis-runtime-tests", manager.cache_dir)
    end)
  end)

  it("uses the configured shared cache default when no explicit path is supplied", function()
    helpers.with_temp_dir(function(root)
      local manager, err = RuntimeManager.new(root, make_manifest(), {
        sha256sum = "sha256sum"
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
    end)
  end)

  it("resolves an installed version-series mapping without fetching the release index", function()
    helpers.with_temp_dir(function(root)
      local manager = RuntimeManager.new(root, make_manifest(), {
        cache_dir = root .. "/cache",
        sha256sum = "sha256sum"
      })
      assert(manager)
      local executable = manager.runtimes_dir .. "/5.4.9/bin/lua"
      os.execute("mkdir -p " .. helpers.shell_quote(manager.runtimes_dir .. "/5.4.9/bin"))
      helpers.write_file(executable, "#!/bin/sh\nexit 0\n")
      helpers.make_executable(executable)
      os.execute("mkdir -p " .. helpers.shell_quote(manager.cache_dir .. "/metadata"))
      helpers.write_file(manager.cache_dir .. "/metadata/lua-series-5.4.txt", "5.4.9\n")
      manager._fetch_release_index = function()
        error("A cached installed series must not fetch the release index")
      end

      local version, checksum, err = manager:resolve_version("5.4")
      assert.is_nil(err)
      assert.equals("5.4.9", version)
      assert.is_nil(checksum)
    end)
  end)

  it("uses a cached SHA-256 checksum without a network request", function()
    helpers.with_temp_dir(function(root)
      local manager = RuntimeManager.new(root, make_manifest(), {
        cache_dir = root .. "/cache",
        sha256sum = "sha256sum"
      })
      assert(manager)
      os.execute("mkdir -p " .. helpers.shell_quote(manager.downloads_dir))
      local expected = string.rep("A", 64)
      helpers.write_file(manager.downloads_dir .. "/lua-5.4.9.sha256", expected .. "  lua-5.4.9.tar.gz\n")
      manager._fetch_release_index = function()
        error("Cached checksum should avoid a network request")
      end

      local checksum, err = manager:_get_release_checksum("5.4.9")
      assert.is_nil(err)
      assert.equals(expected:lower(), checksum)
    end)
  end)

  it("fails cleanly when a resolved runtime cannot be built", function()
    helpers.with_temp_dir(function(root)
      local manager = RuntimeManager.new(root, make_manifest(), {
        cache_dir = root .. "/cache",
        sha256sum = "sha256sum"
      })
      assert(manager)
      manager.resolve_version = function()
        return "5.4.9", string.rep("a", 64)
      end
      manager._ensure_archive = function(_, version)
        return root .. "/lua-" .. version .. ".tar.gz"
      end
      manager._build_and_install = function()
        return false, "simulated compiler failure"
      end

      local success, err = manager:install("5.4")
      assert.is_false(success)
      assert.matches("simulated compiler failure", err)
      assert.is_nil(io.open(manager.project_runtime_file, "rb"))
    end)
  end)

  it("rejects a downloaded archive whose checksum does not match", function()
    helpers.with_temp_dir(function(root)
      local manager = RuntimeManager.new(root, make_manifest(), {
        cache_dir = root .. "/cache",
        sha256sum = "sha256sum"
      })
      assert(manager)
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
      os.execute("mkdir -p " .. helpers.shell_quote(manager.downloads_dir))
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

  it("reports a missing runtime without attempting to remove another version", function()
    helpers.with_temp_dir(function(root)
      local manager = make_manager(root)
      local success, err = manager:uninstall("5.4.9")
      assert.is_false(success)
      assert.matches("Lua 5%.4%.9 is not installed", err)
    end)
  end)

  it("lists only complete exact patch releases from the shared cache", function()
    helpers.with_temp_dir(function(root)
      local manager = make_manager(root)
      local valid_executable = manager.runtimes_dir .. "/5.4.9/bin/lua"
      local incomplete_directory = manager.runtimes_dir .. "/5.4.10/bin"
      local malformed_executable = manager.runtimes_dir .. "/5.4-dev/bin/lua"

      os.execute("mkdir -p " .. helpers.shell_quote(valid_executable:match("^(.*)/lua$")))
      helpers.write_file(valid_executable, "#!/bin/sh\nexit 0\n")
      helpers.make_executable(valid_executable)
      os.execute("mkdir -p " .. helpers.shell_quote(incomplete_directory))
      os.execute("mkdir -p " .. helpers.shell_quote(malformed_executable:match("^(.*)/lua$")))
      helpers.write_file(malformed_executable, "#!/bin/sh\nexit 0\n")
      helpers.make_executable(malformed_executable)

      assert.same({ "5.4.9" }, manager:list_installed())
    end)
  end)

  it("returns an actionable error when a runtime series has no cached release", function()
    helpers.with_temp_dir(function(root)
      local manager = make_manager(root)
      local path, err = manager:get_install_path("5.4")
      assert.is_nil(path)
      assert.matches("has not been resolved yet", err)
    end)
  end)

  it("rejects malformed versions in offline installation checks", function()
    helpers.with_temp_dir(function(root)
      local manager = make_manager(root)
      local installed, err = manager:is_installed("5.x")
      assert.is_nil(installed)
      assert.matches("Invalid Lua version", err)
    end)
  end)
end)


describe("artemis.runtime_manager build pipeline", function()
  local function make_manifest()
    return helpers.new_manifest({ name = "runtime-build-project", lua = "5.4" })
  end

  it("extracts, builds, tests, stages, verifies, and promotes a Lua runtime", function()
    helpers.with_temp_dir(function(root)
      local manager = assert(RuntimeManager.new(root, make_manifest(), {
        cache_dir = root .. "/cache",
        metadata_dir = ".artemis",
        sha256sum = "sha256sum"
      }))
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
        "    printf '%s\n' '#!/bin/sh' 'echo Lua 5.4.9' 'exit 0' > \"$top/bin/lua\"",
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
      local manager = assert(RuntimeManager.new(root, make_manifest(), {
        cache_dir = root .. "/cache",
        metadata_dir = ".artemis",
        sha256sum = "sha256sum"
      }))
      local existing = manager.runtimes_dir .. "/5.4.9/bin/lua"
      os.execute("mkdir -p " .. helpers.shell_quote(manager.runtimes_dir .. "/5.4.9/bin"))
      helpers.write_file(existing, "#!/bin/sh\necho Lua 5.4.9\n")
      helpers.make_executable(existing)

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

  it("returns an actionable error when a runtime executable is missing", function()
    helpers.with_temp_dir(function(root)
      local manager = assert(RuntimeManager.new(root, make_manifest(), {
        cache_dir = root .. "/cache",
        sha256sum = "sha256sum"
      }))
      local executable, err = manager:get_executable("5.4.9")
      assert.is_nil(executable)
      assert.matches("not installed in the Artemis cache", err)
    end)
  end)
end)
