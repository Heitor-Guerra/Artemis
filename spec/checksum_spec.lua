--- @diagnostic disable: undefined-global, undefined-field
local Checksum = require("artemis.utils.checksum")
local helpers = require("spec.helpers")

describe("artemis.checksum", function()
    it("calculates a SHA-256 digest from a file", function()
        helpers.with_temp_dir(function(root)
            local path = root .. "/input.txt"
            helpers.write_file(path, "abc")
            local checksum, checksum_error = Checksum.sha256_file(path)
            assert.is_truthy(checksum, checksum_error)
            assert.equals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", checksum)
        end)
    end)
end)
