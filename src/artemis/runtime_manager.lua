---@class Artemis.RuntimeManager
---@field install_dir string
local RuntimeManager = {}

RuntimeManager.__index = RuntimeManager

---@param install_dir string
---@return Artemis.RuntimeManager
function RuntimeManager.new(install_dir)
  local self = setmetatable({}, RuntimeManager)

  self.install_dir = install_dir

  return self
end

---@param version string
---@return boolean success
---@return string? error_message
function RuntimeManager:install(version)
end

---@param version string
---@return boolean success
---@return string? error_message
function RuntimeManager:uninstall(version)
end

---@param version string
---@return boolean
function RuntimeManager:is_installed(version)
end

---@return string[]
function RuntimeManager:list_installed()
end

function RuntimeManager:get_install_path(version) end

function RuntimeManager:get_executable(version) end

function RuntimeManager:resolve_version(version) end

return RuntimeManager
