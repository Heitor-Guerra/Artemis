---@diagnostic disable: undefined-global, undefined-field, missing-fields, assign-type-mismatch, param-type-mismatch, need-check-nil
describe("artemis public module", function()
    it("exports the Project API", function()
        local artemis = require("artemis")
        local Project = require("artemis.project")

        assert.equals(Project, artemis.Project)
    end)
end)
