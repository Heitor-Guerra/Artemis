---@diagnostic disable: undefined-global, undefined-field, missing-fields, assign-type-mismatch, param-type-mismatch, need-check-nil
local Manifest = require("artemis.manifest")
local helpers = require("spec.helpers")

describe("artemis.manifest", function()
    it("creates a validated manifest and supplies an empty dependency table", function()
        local manifest, err = Manifest.new({
            name = "sample-project",
            lua = "5.4"
        })

        assert.is_truthy(manifest, err)
        assert.same({}, manifest.data.dependencies)
        assert.equals("sample-project", manifest.data.name)
        assert.equals(Manifest.DEFAULT_FILENAME, manifest.path)
    end)

    it("copies input data so later caller mutations do not change the manifest", function()
        local source = {
            name = "sample-project",
            lua = "5.4",
            authors = { "Ada" },
            dependencies = { argparse = ">= 0.7" }
        }

        local manifest = assert(Manifest.new(source))
        source.authors[1] = "Grace"
        source.dependencies.argparse = "*"

        assert.equals("Ada", manifest.data.authors[1])
        assert.equals(">= 0.7", manifest:get_dependency("argparse"))
    end)

    it("rejects missing required project information", function()
        local manifest, err = Manifest.new({ name = "sample-project" })

        assert.is_nil(manifest)
        assert.matches("'lua' is required", err)
    end)

    it("rejects malformed dependency constraints and sparse author arrays", function()
        local manifest, err = Manifest.new({
            name = "sample-project",
            lua = "5.4",
            dependencies = { argparse = " " }
        })

        assert.is_nil(manifest)
        assert.matches("version constraint", err)

        manifest, err = Manifest.new({
            name = "sample-project",
            lua = "5.4",
            authors = { [1] = "Ada", [3] = "Grace" }
        })

        assert.is_nil(manifest)
        assert.matches("sparse array", err)
    end)

    it("adds, updates, retrieves, and removes dependencies", function()
        local manifest = helpers.new_manifest({
            name = "sample-project",
            lua = "5.4"
        })

        assert.is_true(manifest:set_dependency("argparse", ">= 0.7, < 1.0"))
        assert.equals(">= 0.7, < 1.0", manifest:get_dependency("argparse"))
        assert.is_true(manifest:set_dependency("argparse", "0.7.2-1"))
        assert.equals("0.7.2-1", manifest:get_dependency("argparse"))
        assert.is_true(manifest:remove_dependency("argparse"))
        assert.is_nil(manifest:get_dependency("argparse"))
        assert.is_false(manifest:remove_dependency("argparse"))
    end)

    it("rejects empty dependency names and constraints", function()
        local manifest = helpers.new_manifest({
            name = "sample-project",
            lua = "5.4"
        })

        local success, err = manifest:set_dependency(" ", "*")
        assert.is_false(success)
        assert.matches("Dependency name", err)

        success, err = manifest:set_dependency("argparse", " ")
        assert.is_false(success)
        assert.matches("version constraint", err)
    end)

    it("returns defensive copies of the manifest and dependency map", function()
        local manifest = helpers.new_manifest({
            name = "sample-project",
            lua = "5.4",
            dependencies = { argparse = "0.7.2-1" }
        })

        local data_copy = manifest:to_table()
        local dependencies_copy = manifest:get_dependencies()
        data_copy.dependencies.argparse = "*"
        dependencies_copy.argparse = "< 0.1"

        assert.equals("0.7.2-1", manifest:get_dependency("argparse"))
    end)

    it("saves and reloads a TOML manifest", function()
        helpers.with_temp_dir(function(root)
            local path = root .. "/artemis-project.toml"
            local manifest = helpers.new_manifest({
                name = "sample-project",
                lua = "5.4",
                version = "1.2.3",
                description = "A small test project",
                authors = { "Ada Lovelace" },
                dependencies = { argparse = ">= 0.7, < 1.0" }
            })

            local saved, save_error = manifest:save(path)
            assert.is_true(saved, save_error)

            local loaded, load_error = Manifest.load(path)
            assert.is_truthy(loaded, load_error)
            assert.equals("sample-project", loaded.data.name)
            assert.equals("1.2.3", loaded.data.version)
            assert.equals(">= 0.7, < 1.0", loaded:get_dependency("argparse"))
        end)
    end)
end)

describe("artemis.manifest error and boundary cases", function()
    it("reports missing and malformed TOML files as returned errors", function()
        helpers.with_temp_dir(function(root)
            local missing, missing_error = Manifest.load(root .. "/missing.toml")
            assert.is_nil(missing)
            assert.is_truthy(missing_error)

            local malformed_path = root .. "/malformed.toml"
            helpers.write_file(malformed_path, "name = [\n")
            local malformed, malformed_error = Manifest.load(malformed_path)
            assert.is_nil(malformed)
            assert.matches("Could not parse manifest", malformed_error)
        end)
    end)

    it("rejects invalid optional field types instead of silently coercing them", function()
        local manifest, err = Manifest.new({
            name = "sample-project",
            lua = "5.4",
            version = 1
        })
        assert.is_nil(manifest)
        assert.matches("version.*non%-empty string", err)

        manifest, err = Manifest.new({
            name = "sample-project",
            lua = "5.4",
            maintainers = "Ada"
        })
        assert.is_nil(manifest)
        assert.matches("maintainers.*array of strings", err)
    end)

    it("keeps the manifest unchanged when callers mutate nested data returned by to_table", function()
        local manifest = helpers.new_manifest({
            name = "sample-project",
            lua = "5.4",
            authors = { "Ada" },
            dependencies = { argparse = ">= 0.7" }
        })

        local copy = manifest:to_table()
        copy.authors[1] = "Grace"
        copy.dependencies.argparse = "*"
        copy.name = "changed"

        assert.equals("sample-project", manifest.data.name)
        assert.equals("Ada", manifest.data.authors[1])
        assert.equals(">= 0.7", manifest:get_dependency("argparse"))
    end)

    it("does not update the saved path when the destination cannot be opened", function()
        helpers.with_temp_dir(function(root)
            local manifest = helpers.new_manifest({
                name = "sample-project",
                lua = "5.4"
            })
            local original_path = manifest.path
            local invalid_path = root .. "/missing-parent/manifest.toml"
            local success, err = manifest:save(invalid_path)
            assert.is_false(success)
            assert.is_truthy(err)
            assert.equals(original_path, manifest.path)
        end)
    end)
end)
