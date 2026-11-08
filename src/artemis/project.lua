---@class Artemis.Project
---@field root string
---@field manifest Artemis.Manifest
---@field runtime_manager Artemis.RuntimeManager
---@field dependency_manager Artemis.DependencyManager
local Project = {}

Project.__index = Project

---@param root string
---@return Artemis.Project
function Project.new(root)
  local self = setmetatable({}, Project)

  self.root = root

  return self
end

---@param name string
---@param version? string
---@return boolean success
---@return string? error_message
function Project:add_dependency(name, version)
end

---@param name string
---@return boolean success
---@return string? error_message
function Project:remove_dependency(name)
end

---@return boolean success
---@return string? error_message
function Project:sync()
end

---@return boolean success
---@return string? error_message
function Project:lock()
end

---@return table
function Project:tree()
end

---@param script string
---@param args? string[]
---@return boolean success
---@return string? error_message
function Project:run(script, args)
end

return Project
