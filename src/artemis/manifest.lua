--- Project manifest loading, validation, and persistence.
---
--- The manifest module is deliberately limited to project metadata. It does not
--- install runtimes, resolve dependencies, or execute project files.
---
--- TOML parsing and encoding are delegated to `tinytoml`.
--- @module 'artemis.manifest'

local toml = require("tinytoml")

--- @class Artemis.ManifestData
--- @field name          string                 Project name.
--- @field lua           string                 Lua version required by the project (for example, "5.4").
--- @field version?      string                 Optional project version.
--- @field description?  string                 Optional project description.
--- @field main?         string                 Optional path to the project's entry-point file.
--- @field authors?      string[]               Project authors.
--- @field maintainers?  string[]               Project maintainers.
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


--- Create a deep copy of a Lua table.
--- This prevents callers from accidentally changing the source table passed to
--- Manifest.new() after the manifest has been created.
--- @generic T
--- @param value  T
--- @return T
local function deep_copy(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}

    for key, item in pairs(value) do
        copy[deep_copy(key)] = deep_copy(item)
    end

    return copy
end

--- Check whether a value is a non-empty string.
--- @param value  any
--- @return boolean
local function is_non_empty_string(value)
    return type(value) == "string" and value:match("%S") ~= nil
end

--- Validate a string array such as `authors` or `maintainers`.
--- @param value       any
--- @param field_name  string
--- @return string[]  errors
local function validate_string_array(value, field_name)
    local errors = {}

    if type(value) ~= "table" then
        errors[#errors + 1] = string.format("'%s' must be an array of strings.", field_name)
        return errors
    end

    -- TOML arrays map to dense, one-based Lua arrays. Reject dictionary keys
    -- and sparse arrays instead of silently ignoring malformed values.
    local item_count = 0
    local highest_index = 0

    for key, item in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            errors[#errors + 1] = string.format("'%s' must contain only array elements.", field_name)
        else
            item_count = item_count + 1
            if key > highest_index then
                highest_index = key
            end

            if not is_non_empty_string(item) then
                errors[#errors + 1] = string.format("Every item in '%s' must be a non-empty string.", field_name)
            end
        end
    end

    if item_count ~= highest_index then
        errors[#errors + 1] = string.format("'%s' must not be a sparse array.", field_name)
    end

    return errors
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
        if not is_non_empty_string(package_name) then
            errors[#errors + 1] = "Dependency names must be non-empty strings."
        end

        if not is_non_empty_string(constraint) then
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

    if not is_non_empty_string(data.name) then
        errors[#errors + 1] = "'name' is required and must be a non-empty string."
    end

    if not is_non_empty_string(data.lua) then
        errors[#errors + 1] = "'lua' is required and must be a non-empty Lua version string (for example, '5.4')."
    end

    if data.version ~= nil and not is_non_empty_string(data.version) then
        errors[#errors + 1] = "'version' must be a non-empty string when provided."
    end

    if data.description ~= nil and type(data.description) ~= "string" then
        errors[#errors + 1] = "'description' must be a string when provided."
    end

    if data.main ~= nil and not is_non_empty_string(data.main) then
        errors[#errors + 1] = "'main' must be a non-empty path string when provided."
    end

    if data.authors ~= nil then
        local author_errors = validate_string_array(data.authors, "authors")
        for _, message in ipairs(author_errors) do
            errors[#errors + 1] = message
        end
    end

    if data.maintainers ~= nil then
        local maintainer_errors = validate_string_array(data.maintainers, "maintainers")
        for _, message in ipairs(maintainer_errors) do
            errors[#errors + 1] = message
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

    local copied_data = deep_copy(data)
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

    if type(path) ~= "string" or not is_non_empty_string(path) then
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
    return deep_copy(self.data)
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
    return deep_copy(self.data.dependencies)
end

--- Add or update a runtime dependency in the manifest data.
--- This only changes the in-memory manifest; call save() to persist it.
--- @param package_name        string  Package/rock name.
--- @param version_constraint  string  Version constraint, such as ">= 0.7, < 1.0".
--- @return boolean  success
--- @return string?  error_message
function Manifest:set_dependency(package_name, version_constraint)
    if not is_non_empty_string(package_name) then
        return false, "Dependency name must be a non-empty string."
    end

    if not is_non_empty_string(version_constraint) then
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
    if not is_non_empty_string(package_name) then
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

    if type(path) ~= "string" or not is_non_empty_string(path) then
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

    local file, open_error = io.open(path, "wb")
    if not file then
        return false, string.format("Could not open '%s' for writing: %s", path, open_error)
    end

    local write_result, write_error = file:write(encoded)
    if not write_result then
        file:close()
        return false, string.format("Could not write manifest '%s': %s", path, write_error)
    end

    local close_result, close_reason = file:close()
    if not close_result then
        return false, string.format("Could not close manifest '%s': %s", path, close_reason)
    end

    self.path = path
    return true
end

-----------------------------------------------------------------------------------------


return Manifest
