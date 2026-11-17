---@diagnostic disable: missing-return
--- Shared contract implemented by Artemis dependency-manager backends.
--- Concrete implementations should be created with `DependencyManager.extend()`.
--- @module 'artemis.dependency_manager.interface'

--- @class Artemis.DependencyManagerOptions
--- @field tree?                 string  Installation tree. Defaults to lua_modules.
--- @field lua_version           string  Lua version used to select compatible rocks.
--- @field lua_runtime_version?  string  Exact selected runtime version.
--- @field lua_dir?              string  Selected Lua installation prefix for native modules.
--- @field metadata_dir?         string  Project-local metadata directory.
--- @field cache_dir?            string  Shared Artemis cache directory.
--- @field server?               string  LuaRocks-compatible repository root URL.

--- @class Artemis.Dependency
--- @field name        string  LuaRocks package name.
--- @field constraint  string  LuaRocks version constraint.

--- @class Artemis.InstalledRock
--- @field name     string  Installed rock name.
--- @field version  string  Installed rock version, including its LuaRocks revision.

--- @class Artemis.DependencyManager
--- @field working_directory  string  Project root used by this manager.
--- @field tree               string  Installation tree.
--- @field lua_version        string  Lua module path version.
local DependencyManager = {}
DependencyManager.__index = DependencyManager

local REQUIRED_METHODS = {
    "install",
    "build_project",
    "verify_versions",
    "uninstall",
    "list_installed",
    "is_installed",
    "get_tree",
    "path"
}

local function raise_abstract(name)
    error(string.format("DependencyManager method '%s' is abstract.", name), 2)
end

--- Create a class that inherits the dependency-manager contract.
--- @return table class
function DependencyManager.extend()
    local class = {}
    class.__index = class
    return setmetatable(class, { __index = DependencyManager })
end

--- Check whether a concrete class implements the full manager contract.
--- @param class table
--- @return boolean valid
--- @return string? error_message
function DependencyManager.validate_implementation(class)
    if type(class) ~= "table" then
        return false, "Dependency manager implementation must be a table."
    end

    for _, method in ipairs(REQUIRED_METHODS) do
        if type(rawget(class, method)) ~= "function" then
            return false, string.format("Dependency manager does not implement '%s'.", method)
        end
    end
    return true
end

--- Install direct dependencies and their transitive dependency graph.
--- @param dependencies Artemis.Dependency[]
--- @param exact_versions? table<string, string> Exact versions from the lockfile.
--- @return boolean success
--- @return string? error_message
function DependencyManager:install(dependencies, exact_versions)
    raise_abstract("install")
end

--- Build and install the current project from its generated rockspec.
--- A LuaRocks-backed implementation may consume only rockspec_path; a native
--- implementation may consume the parsed rockspec table directly.
--- @param rockspec table|string
--- @param rockspec_path? string
--- @return boolean success
--- @return string? error_message
function DependencyManager:build_project(rockspec, rockspec_path)
    raise_abstract("build_project")
end

--- Check that every locked dependency version is installed.
--- @param exact_versions table<string, string>
--- @return boolean valid
--- @return string? error_message
function DependencyManager:verify_versions(exact_versions)
    raise_abstract("verify_versions")
end

--- Remove a rock unless it is still required by another installed rock.
--- @param package_name string
--- @return boolean success
--- @return string? warning_or_error
function DependencyManager:uninstall(package_name)
    raise_abstract("uninstall")
end

--- List rocks installed in this manager's tree.
--- @return Artemis.InstalledRock[]? rocks
--- @return string? error_message
function DependencyManager:list_installed()
    raise_abstract("list_installed")
end

--- Check whether a package is installed.
--- @param package_name string
--- @return boolean? installed
--- @return string? error_message
function DependencyManager:is_installed(package_name)
    raise_abstract("is_installed")
end

--- Return the configured installation tree.
--- @return string
function DependencyManager:get_tree()
    raise_abstract("get_tree")
end

--- Return shell exports that put the configured tree on Lua's module paths.
--- @return string? exports
--- @return string? error_message
function DependencyManager:path()
    raise_abstract("path")
end

return DependencyManager
