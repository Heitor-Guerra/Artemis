--- @diagnostic disable: undefined-global, undefined-field, missing-fields, assign-type-mismatch, param-type-mismatch, need-check-nil
local Lockfile = require("artemis.project.lockfile")
local helpers = require("spec.helpers")

describe("artemis.lockfile", function()
    local function manifest_data()
        return {
            name = "sample-project",
            lua = "5.4",
            version = "1.0.0",
            dependencies = {
                argparse = ">= 0.7, < 1.0"
            }
        }
    end

    it("creates a lockfile from direct and transitive installed rocks", function()
        local lockfile, err = Lockfile.from_installed(manifest_data(), {
            { name = "argparse",  version = "0.7.2-1" },
            { name = "luasystem", version = "0.3.0-1" }
        }, {
            runtime_version = "5.4.9",
            path = "sample.lock"
        })

        assert.is_truthy(lockfile, err)
        assert.equals("5.4.9", lockfile.data.project.runtime)
        assert.is_true(lockfile.data.dependencies.argparse.direct)
        assert.equals(">= 0.7, < 1.0", lockfile.data.dependencies.argparse.constraint)
        assert.is_false(lockfile.data.dependencies.luasystem.direct)
        assert.equals("sample.lock", lockfile.path)
    end)

    it("requires every manifest dependency to be present in the installed list", function()
        local lockfile, err = Lockfile.from_installed(manifest_data(), {})

        assert.is_nil(lockfile)
        assert.matches("not installed", err)
    end)

    it("rejects duplicate installed rock names", function()
        local lockfile, err = Lockfile.from_installed(manifest_data(), {
            { name = "argparse", version = "0.7.2-1" },
            { name = "argparse", version = "0.7.3-1" }
        })

        assert.is_nil(lockfile)
        assert.matches("appears more than once", err)
    end)

    it("rejects malformed and sparse installed-rock lists", function()
        local lockfile, err = Lockfile.from_installed(manifest_data(), {
            { name = "argparse", version = " " }
        })
        assert.is_nil(lockfile)
        assert.matches("non%-empty name and version", err)

        lockfile, err = Lockfile.from_installed(manifest_data(), {
            [1] = { name = "argparse", version = "0.7.2-1" },
            [3] = { name = "luasystem", version = "0.7.1-1" }
        })
        assert.is_nil(lockfile)
        assert.matches("dense array", err)
    end)

    it("rejects unsupported lockfile formats and incomplete direct records", function()
        local lockfile, err = Lockfile.new({
            lockfile_version = Lockfile.FORMAT_VERSION + 1,
            generated_by = "artemis",
            project = { name = "sample-project", lua = "5.4" },
            dependencies = {}
        })

        assert.is_nil(lockfile)
        assert.matches("Unsupported lockfile version", err)

        lockfile, err = Lockfile.new({
            generated_by = "artemis",
            project = { name = "sample-project", lua = "5.4" },
            dependencies = {
                argparse = { version = "0.7.2-1", direct = true }
            }
        })

        assert.is_nil(lockfile)
        assert.matches("must record its manifest 'constraint'", err)
    end)

    it("matches the manifest's direct dependency inputs", function()
        local lockfile = assert(Lockfile.from_installed(manifest_data(), {
            { name = "argparse", version = "0.7.2-1" }
        }, { runtime_version = "5.4.9" }))

        assert.is_true(lockfile:matches_manifest(manifest_data()))

        local changed = manifest_data()
        changed.dependencies.argparse = ">= 0.8"
        local matches, reason = lockfile:matches_manifest(changed)
        assert.is_false(matches)
        assert.matches("does not match", reason)

        changed = manifest_data()
        changed.name = "another-project"
        matches, reason = lockfile:matches_manifest(changed)
        assert.is_false(matches)
        assert.matches("different project", reason)
    end)

    it("saves and reloads its deterministic TOML representation", function()
        helpers.with_temp_dir(function(root)
            local path = root .. "/lua-project.lock"
            local lockfile = assert(Lockfile.from_installed(manifest_data(), {
                { name = "luasystem", version = "0.3.0-1" },
                { name = "argparse",  version = "0.7.2-1" }
            }, { runtime_version = "5.4.9" }))

            local saved, save_error = lockfile:save(path)
            assert.is_true(saved, save_error)

            local contents = helpers.read_file(path)
            assert.is_true(contents:find('[dependencies."argparse"]', 1, true) ~= nil)
            assert.is_true(contents:find('[dependencies."luasystem"]', 1, true) ~= nil)

            local loaded, load_error = Lockfile.load(path)
            assert.is_truthy(loaded, load_error)
            assert.equals("5.4.9", loaded.data.project.runtime)
        end)
    end)
end)

describe("artemis.lockfile additional invariants", function()
    local function manifest_data()
        return {
            name = "sample-project",
            lua = "5.4",
            dependencies = { argparse = ">= 0.7" }
        }
    end

    it("returns defensive copies of nested dependency metadata", function()
        local lockfile = assert(Lockfile.from_installed(manifest_data(), {
            { name = "argparse",  version = "0.7.2-1", requires = { "luasystem >= 0.2" } },
            { name = "luasystem", version = "0.7.1-1" }
        }))

        local dependencies = lockfile:get_dependencies()
        dependencies.argparse.requires[1] = "tampered"
        dependencies.argparse.version = "9.9-1"
    end)

    it("detects a locked runtime from a different Lua series", function()
        local lockfile = assert(Lockfile.from_installed(manifest_data(), {
            { name = "argparse", version = "0.7.2-1" }
        }, { runtime_version = "5.3.6" }))

        local compatible, reason = lockfile:matches_manifest(manifest_data())
        assert.is_false(compatible)
        assert.matches("Lua series", reason)
    end)

    it("detects when the manifest removes a formerly direct dependency", function()
        local lockfile = assert(Lockfile.from_installed(manifest_data(), {
            { name = "argparse", version = "0.7.2-1" }
        }))
        local changed = {
            name = "sample-project",
            lua = "5.4",
            dependencies = {}
        }

        local compatible, reason = lockfile:matches_manifest(changed)
        assert.is_false(compatible)
        assert.matches("no dependencies", reason)
    end)

    it("rejects a lockfile with an invalid direct dependency record", function()
        local lockfile, err = Lockfile.new({
            lockfile_version = Lockfile.FORMAT_VERSION,
            generated_by = "artemis",
            project = { name = "sample-project", lua = "5.4" },
            dependencies = {
                argparse = { version = "0.7.2-1", direct = true }
            }
        })
        assert.is_nil(lockfile)
        assert.matches("constraint", err)
    end)
end)
