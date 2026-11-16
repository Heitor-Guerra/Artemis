--- Project manifest loading, validation, and persistence.
---
--- The manifest module is deliberately limited to project metadata. It does not
--- install runtimes, resolve dependencies, or execute project files.
---
--- TOML parsing and encoding are delegated to `tinytoml`.
--- @module 'artemis.project.manifest'

local toml = require("tinytoml")
local TableUtils = require("artemis.utils.table_utils")
local FileSystem = require("artemis.utils.filesystem")

--- @class Artemis.ManifestData
--- @field name          string                 Project name.
--- @field lua           string                 Lua version required by the project (for example, "5.4").
--- @field version?      string                 Optional project version.
--- @field description?  string                 Optional project description.
--- @field main?         string                 Optional path to the project's entry-point file.
--- @field authors?      string[]               Project authors.
--- @field maintainers?  string[]               Project maintainers.
--- @field license?      string                 SPDX license identifier for generated rockspecs.
--- @field source_url?   string                 Public source URL used in generated rockspecs.
--- @field source_tag?   string                 Git tag used by the generated rockspec.
--- @field modules?      table<string, string>  Explicit Lua module names mapped to project-relative source files.
--- @field dependencies  table<string, string>  Runtime dependencies mapped to version constraints.

--- @class Artemis.Manifest
--- @field data  Artemis.ManifestData  Parsed and validated manifest data.
--- @field path  string                Path used when the manifest was loaded or last saved.
local Manifest = {}
Manifest.__index = Manifest

--- Default filename used by Artemis projects.
--- @type string
Manifest.DEFAULT_FILENAME = "artemis-project.toml"


------------------------------------ Local Functions ------------------------------------

local function is_valid_module_name(name)
    if type(name) ~= "string" or name == "" or name:sub(1, 1) == "." or name:sub(-1) == "." then
        return false
    end
    for segment in name:gmatch("[^.]+") do
        if not segment:match("^[%a_][%w_%-]*$") then return false end
    end
    return not name:match("%.%.")
end

--- Validate the dependency table.
--- @param value  any
--- @return string[]  errors
local function validate_dependencies(value)
    local errors = {}

    if type(value) ~= "table" then
        errors[#errors + 1] = "'dependencies' must be a table of package names and version constraints."
        return errors
    end

    for package_name, constraint in pairs(value) do
        if not TableUtils.is_non_empty_string(package_name) then
            errors[#errors + 1] = "Dependency names must be non-empty strings."
        end

        if not TableUtils.is_non_empty_string(constraint) then
            errors[#errors + 1] = string.format(
                "The version constraint for dependency '%s' must be a non-empty string.",
                tostring(package_name)
            )
        end
    end

    return errors
end

--- Validate manifest data without creating a Manifest instance.
--- @param data  any
--- @return boolean  valid
--- @return string?  error_message
local function validate_data(data)
    if type(data) ~= "table" then
        return false, "The manifest root must be a TOML table."
    end

    local errors = {}

    if not TableUtils.is_non_empty_string(data.name) then
        errors[#errors + 1] = "'name' is required and must be a non-empty string."
    end

    if not TableUtils.is_non_empty_string(data.lua) then
        errors[#errors + 1] = "'lua' is required and must be a non-empty Lua version string (for example, '5.4')."
    end

    if data.version ~= nil and not TableUtils.is_non_empty_string(data.version) then
        errors[#errors + 1] = "'version' must be a non-empty string when provided."
    end

    if data.description ~= nil and type(data.description) ~= "string" then
        errors[#errors + 1] = "'description' must be a string when provided."
    end

    if data.main ~= nil and not TableUtils.is_non_empty_string(data.main) then
        errors[#errors + 1] = "'main' must be a non-empty path string when provided."
    end

    if data.authors ~= nil then
        local author_errors = TableUtils.validate_string_array(data.authors, "authors")
        for _, message in ipairs(author_errors) do
            errors[#errors + 1] = message
        end
    end

    if data.maintainers ~= nil then
        local maintainer_errors = TableUtils.validate_string_array(data.maintainers, "maintainers")
        for _, message in ipairs(maintainer_errors) do
            errors[#errors + 1] = message
        end
    end

    for _, field_name in ipairs({ "license", "source_url", "source_tag" }) do
        local value = data[field_name]
        if value ~= nil and not TableUtils.is_non_empty_string(value) then
            errors[#errors + 1] = string.format("'%s' must be a non-empty string when provided.", field_name)
        elseif type(value) == "string" and value:find("[\r\n]") then
            errors[#errors + 1] = string.format("'%s' cannot contain line breaks.", field_name)
        end
    end

    if data.modules ~= nil then
        if type(data.modules) ~= "table" then
            errors[#errors + 1] = "'modules' must be a table mapping Lua module names to relative source paths."
        else
            for module_name, source_path in pairs(data.modules) do
                if not is_valid_module_name(module_name) then
                    errors[#errors + 1] = string.format("Invalid Lua module name '%s' in 'modules'.", tostring(module_name))
                end
                if not TableUtils.is_non_empty_string(source_path) or source_path:find("[\r\n]")
                    or source_path:sub(1, 1) == "/" or source_path:match("^%a:[/\\]") then
                    errors[#errors + 1] = string.format("Source path for module '%s' must be a non-empty relative path.", tostring(module_name))
                else
                    local normalized_path = source_path:gsub("\\", "/")
                    for segment in normalized_path:gmatch("[^/]+") do
                        if segment == ".." or segment == "." then
                            errors[#errors + 1] = string.format("Source path for module '%s' cannot contain traversal segments.", tostring(module_name))
                            break
                        end
                    end
                end
            end
        end
    end

    if data.dependencies == nil then
        data.dependencies = {}
    else
        local dependency_errors = validate_dependencies(data.dependencies)
        for _, message in ipairs(dependency_errors) do
            errors[#errors + 1] = message
        end
    end

    if #errors > 0 then
        return false, table.concat(errors, "\n")
    end

    return true
end

-----------------------------------------------------------------------------------------



----------------------------------- Manifest Functions ----------------------------------

--- Construct a Manifest from an already decoded Lua table.
--- The manifest is validated immediately. Invalid data returns `nil` and an
--- error message; valid data is copied so the caller retains ownership of its
--- original table.
--- @param data   Artemis.ManifestData  Data to be saved
--- @param path?  string                Path to associate with this manifest.
--- @return Artemis.Manifest?  manifest
--- @return string?            error_message
function Manifest.new(data, path)
    if type(data) ~= "table" then
        return nil, "Manifest.new expects a table as its first argument."
    end

    local copied_data = TableUtils.deep_copy(data)
    local valid, validation_error = validate_data(copied_data)

    if not valid then
        return nil, validation_error
    end

    local self = setmetatable({}, Manifest)
    self.data = copied_data
    self.path = path or Manifest.DEFAULT_FILENAME

    return self
end

--- Load and validate a TOML manifest from disk.
--- @param path?  string  Path to the TOML file. Defaults to artemis-project.toml.
--- @return Artemis.Manifest?  manifest
--- @return string?            error_message
function Manifest.load(path)
    path = path or Manifest.DEFAULT_FILENAME

    if type(path) ~= "string" or not TableUtils.is_non_empty_string(path) then
        return nil, "Manifest path must be a non-empty string."
    end

    local parse_ok, parsed_data = pcall(toml.parse, path)
    if not parse_ok then
        return nil, string.format("Could not parse manifest '%s': %s", path, tostring(parsed_data))
    end

    if type(parsed_data) ~= "table" then
        return nil, string.format("Manifest '%s' did not decode into a TOML table.", path)
    end

    return Manifest.new(parsed_data, path)
end

--- Validate the current manifest data.
--- @return boolean  valid
--- @return string?  error_message
function Manifest:validate()
    return validate_data(self.data)
end

--- Return a deep copy of the manifest data.
--- Mutating the returned table does not modify this Manifest instance.
--- @return Artemis.ManifestData
function Manifest:to_table()
    return TableUtils.deep_copy(self.data)
end

--- Get the version constraint of a dependency.
--- @param package_name  string
--- @return string?  version_constraint
function Manifest:get_dependency(package_name)
    if type(package_name) ~= "string" then
        return nil
    end

    return self.data.dependencies[package_name]
end

--- Return a copy of all runtime dependencies.
--- @return table<string, string>
function Manifest:get_dependencies()
    return TableUtils.deep_copy(self.data.dependencies)
end

--- Add or update a runtime dependency in the manifest data.
--- This only changes the in-memory manifest; call save() to persist it.
--- @param package_name        string  Package/rock name.
--- @param version_constraint  string  Version constraint, such as ">= 0.7, < 1.0".
--- @return boolean  success
--- @return string?  error_message
function Manifest:set_dependency(package_name, version_constraint)
    if not TableUtils.is_non_empty_string(package_name) then
        return false, "Dependency name must be a non-empty string."
    end

    if not TableUtils.is_non_empty_string(version_constraint) then
        return false, "Dependency version constraint must be a non-empty string."
    end

    self.data.dependencies[package_name] = version_constraint
    return true
end

--- Remove a runtime dependency from the manifest data.
--- This only changes the in-memory manifest; call save() to persist it.
--- @param package_name  string  Package/rock name.
--- @return boolean  removed  True if the dependency existed and was removed.
--- @return string?  error_message
function Manifest:remove_dependency(package_name)
    if not TableUtils.is_non_empty_string(package_name) then
        return false, "Dependency name must be a non-empty string."
    end

    if self.data.dependencies[package_name] == nil then
        return false
    end

    self.data.dependencies[package_name] = nil
    return true
end

--- Save the manifest as TOML.
--- The encoder rewrites the document, so comments and original formatting are
--- not preserved. The destination directory must already exist.
--- @param path?  string  Destination path. Defaults to this manifest's path.
--- @return boolean  success
--- @return string?  error_message
function Manifest:save(path)
    path = path or self.path

    if type(path) ~= "string" or not TableUtils.is_non_empty_string(path) then
        return false, "Manifest path must be a non-empty string."
    end

    local valid, validation_error = self:validate()
    if not valid then
        return false, validation_error
    end

    local encode_ok, encoded, encode_error = pcall(toml.encode, self.data, {
        allow_multiline_strings = true
    })

    if not encode_ok then
        return false, string.format("Could not encode manifest: %s", tostring(encoded))
    end

    if type(encoded) ~= "string" then
        return false, string.format("Could not encode manifest: %s", tostring(encode_error or encoded))
    end

    local saved, save_error = FileSystem.write_file(path, encoded)
    if not saved then
        return false, string.format("Could not save manifest '%s': %s", path, tostring(save_error))
    end

    self.path = path
    return true
end

-----------------------------------------------------------------------------------------


return Manifest
