--- @diagnostic disable: undefined-global, undefined-field, missing-fields, assign-type-mismatch, param-type-mismatch, need-check-nil
local LuaRocksConfig = require("artemis.dependency_manager.luarocks_config")
local helpers = require("spec.helpers")

describe("artemis.dependency_manager.luarocks_config", function()
    it("resolves a relative cache directory against the working directory", function()
        helpers.with_temp_dir(function(root)
            local cache_dir, err = LuaRocksConfig.resolve_cache_dir(root, ".cache/artemis")
            assert.is_truthy(cache_dir, err)
            assert.equals(root .. "/.cache/artemis", cache_dir)
        end)
    end)

    it("expands a home-relative cache directory", function()
        helpers.with_temp_dir(function(root)
            local home = assert(os.getenv("HOME"), "HOME must be set for this test")
            local cache_dir, err = LuaRocksConfig.resolve_cache_dir(root, "~/.cache/artemis-tests")
            assert.is_truthy(cache_dir, err)
            assert.equals(home .. "/.cache/artemis-tests", cache_dir)
        end)
    end)

    it("rejects named-user cache paths", function()
        helpers.with_temp_dir(function(root)
            local cache_dir, err = LuaRocksConfig.resolve_cache_dir(root, "~somebody/.cache/artemis")
            assert.is_nil(cache_dir)
            assert.matches("Named%-user home paths are not supported", err)
        end)
    end)

    it("returns cache-configuration creation errors in the third result", function()
        helpers.with_temp_dir(function(root)
            local blocking_file = root .. "/not-a-directory"
            helpers.write_file(blocking_file, "file")

            local config_path, rocks_cache_dir, err = LuaRocksConfig.create_luarocks_cache_config(
                root,
                blocking_file,
                "5.4"
            )

            assert.is_nil(config_path)
            assert.is_nil(rocks_cache_dir)
            assert.matches("Could not create LuaRocks cache directory", err)
        end)
    end)

    it("creates a cache config while preserving the existing config and selected Lua runtime", function()
        helpers.with_temp_dir(function(root)
            local cache_dir = root .. "/shared-cache"
            local existing_config = root .. "/user-config.lua"
            helpers.write_file(existing_config, "rocks_servers = {}\n")

            local config_path, rocks_cache_dir, err = LuaRocksConfig.create_luarocks_cache_config(
                root,
                cache_dir,
                "5.4",
                existing_config,
                root .. "/lua-5.4.9"
            )

            assert.is_truthy(config_path, err)
            assert.equals(cache_dir .. "/rocks/downloads", rocks_cache_dir)

            local contents = helpers.read_file(config_path)
            assert.matches("dofile%(", contents)
            assert.matches("rocks/downloads", contents)
            assert.matches("aggressive_cache = true", contents)
            assert.matches("variables%.LUA_DIR", contents)
            assert.matches("lua%-5%.4%.9", contents)
        end)
    end)
end)
