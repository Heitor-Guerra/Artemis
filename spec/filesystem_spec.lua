--- @diagnostic disable: undefined-global, undefined-field, param-type-mismatch
local FileSystem = require("artemis.utils.filesystem")
local helpers = require("spec.helpers")

describe("artemis.filesystem", function()
    it("creates nested directories and reads and writes files", function()
        helpers.with_temp_dir(function(root)
            local path = root .. "/one/two/value.txt"
            local saved, save_error = FileSystem.write_file(path, "Artemis")
            assert.is_true(saved, save_error)
            assert.equals("Artemis", FileSystem.read_file(path))
            assert.is_true(FileSystem.file_exists(path))
            assert.is_true(FileSystem.directory_exists(root .. "/one/two"))
        end)
    end)

    it("does not overwrite a file when write_new_file is used", function()
        helpers.with_temp_dir(function(root)
            local path = root .. "/value.txt"
            assert.is_true(FileSystem.write_file(path, "original"))
            assert.is_true(FileSystem.write_new_file(path, "replacement"))
            assert.equals("original", FileSystem.read_file(path))
        end)
    end)

    it("lists direct child directories and recursively removes a tree", function()
        helpers.with_temp_dir(function(root)
            assert.is_true(FileSystem.make_directory(root .. "/parent/child"))
            assert.is_true(FileSystem.write_file(root .. "/parent/child/file.txt", "content"))
            assert.is_true(FileSystem.make_directory(root .. "/sibling"))

            local directories, list_error = FileSystem.list_directories(root)
            assert.is_truthy(directories, list_error)
            table.sort(directories)
            assert.same({ root .. "/parent", root .. "/sibling" }, directories)

            assert.is_true(FileSystem.remove(root .. "/parent"))
            assert.is_false(FileSystem.directory_exists(root .. "/parent"))
        end)
    end)
end)
