---@diagnostic disable: undefined-global, undefined-field
local DependencyManager = require("artemis.dependency_manager.interface")

describe("artemis.dependency_manager.interface", function()
    it("provides abstract methods to incomplete implementations", function()
        local Incomplete = DependencyManager.extend()
        local instance = setmetatable({}, Incomplete)

        assert.has_error(function()
            instance:install({})
        end, "DependencyManager method 'install' is abstract.")
    end)
end)
