--- @diagnostic disable: undefined-global, undefined-field
local TableUtils = require("artemis.utils.table_utils")

describe("artemis.table_utils", function()
    it("deep-copies nested tables and their keys", function()
        local original = { nested = { value = 1 } }
        local copied = TableUtils.deep_copy(original)
        copied.nested.value = 2
        assert.equals(1, original.nested.value)
    end)

    it("validates dense arrays of non-empty strings", function()
        assert.same({}, TableUtils.validate_string_array({ "one", "two" }, "items"))
        assert.is_true(#TableUtils.validate_string_array({ [1] = "one", [3] = "three" }, "items") > 0)
        assert.is_true(#TableUtils.validate_string_array({ "one", "" }, "items") > 0)
    end)
end)
