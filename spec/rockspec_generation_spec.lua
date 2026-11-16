--- @diagnostic disable: undefined-global, undefined-field, missing-fields, assign-type-mismatch, param-type-mismatch, need-check-nil
local RockspecGeneration = require("artemis.dependency_manager.rockspec_generation")
local helpers = require("spec.helpers")

describe("artemis.dependency_manager.rockspec_generation", function()
    local function dependency(name, constraint)
        return { name = name, constraint = constraint or "*" }
    end

    it("validates LuaRocks package names", function()
        local valid, err = RockspecGeneration.validate_package_name("lua-filesystem")
        assert.is_true(valid, err)

        valid, err = RockspecGeneration.validate_package_name("bad;name")
        assert.is_false(valid)
        assert.matches("Invalid LuaRocks package name", err)
    end)

    it("writes dependencies in sorted order with the configured Lua constraint", function()
        helpers.with_temp_dir(function(root)
            local relative_path, err = RockspecGeneration.write_dependency_rockspec(
                root,
                ".artemis/nested",
                "5.4",
                {
                    dependency("zlib"),
                    dependency("argparse", ">= 0.7, < 1.0")
                }
            )

            assert.is_truthy(relative_path, err)
            local contents = helpers.read_file(root .. "/" .. relative_path)
            local argparse_position = assert(contents:find('"argparse >= 0.7, < 1.0"', 1, true))
            local zlib_position = assert(contents:find('"zlib"', 1, true))
            assert.is_true(argparse_position < zlib_position)
            assert.is_truthy(contents:find('"lua >= 5.4, < 5.5"', 1, true))
        end)
    end)

    it("rejects sparse arrays, duplicate names, and invalid constraints", function()
        helpers.with_temp_dir(function(root)
            local path, err = RockspecGeneration.write_dependency_rockspec(
                root,
                ".artemis",
                "5.4",
                { [2] = dependency("argparse") }
            )
            assert.is_nil(path)
            assert.matches("dense array", err)

            path, err = RockspecGeneration.write_dependency_rockspec(
                root,
                ".artemis",
                "5.4",
                { dependency("argparse"), dependency("argparse", ">= 0.7") }
            )
            assert.is_nil(path)
            assert.matches("supplied more than once", err)

            path, err = RockspecGeneration.write_dependency_rockspec(
                root,
                ".artemis",
                "5.4",
                { dependency("argparse", "0.7\npackage = 'invalid'") }
            )
            assert.is_nil(path)
            assert.matches("line break", err)
        end)
    end)

    it("uses LuaJIT's LuaRocks compatibility constraint", function()
        helpers.with_temp_dir(function(root)
            local relative_path, err = RockspecGeneration.write_dependency_rockspec(
                root,
                ".artemis",
                "jit",
                { dependency("luasocket") }
            )
            assert.is_truthy(relative_path, err)
            assert.matches('"lua >= 5%.1, < 5%.2"', helpers.read_file(root .. "/" .. relative_path))
        end)
    end)
end)
