--- Read, validate, create, and persist an Artemis dependency lockfile.
---
--- The lockfile stores the exact LuaRocks versions installed in the project's
--- local tree, including transitive rocks. LuaRocks remains responsible for
--- dependency resolution; this module records the resulting resolution so it
--- can be checked and reused by later Artemis workflows.
---
--- The file is TOML and is intentionally deterministic: project fields,
--- package records, and package metadata are written in a stable order.
---
--- @module 'artemis.lockfile'

local toml = require("tinytoml")

--- @class Artemis.LockfileProject
--- @field name      string  Project name from lua-project.toml.
--- @field lua       string  Lua version requirement from the manifest (for example, "5.4").
--- @field runtime?  string  Exact installed Lua release (for example, "5.4.9").
--- @field version?  string  Optional project version from the manifest.

--- @class Artemis.LockedDependency
--- @field version      string    Exact installed LuaRocks version, including its revision.
--- @field direct       boolean   Whether the package is declared directly in the manifest.
--- @field constraint?  string    Manifest constraint for a direct dependency.
--- @field source?      string    Repository or source URL, when known.
--- @field checksum?    string    Source archive checksum, when known.
--- @field rockspec?    string    Rockspec URL or identifier, when known.
--- @field requires?    string[]  Dependency requirements reported by the resolver, when known.

--- @class Artemis.LockfileData
--- @field lockfile_version  integer                                  Lockfile schema version.
--- @field generated_by      string                                   Tool that generated the lockfile.
--- @field project           Artemis.LockfileProject                  Project and Lua runtime information.
--- @field dependencies      table<string, Artemis.LockedDependency>  Exact package resolutions keyed by rock name.

--- @class Artemis.Lockfile
--- @field data  Artemis.LockfileData  Parsed lockfile data.
--- @field path  string                Path used when the lockfile was loaded or last saved.
local Lockfile = {}
Lockfile.__index = Lockfile

--- Current on-disk lockfile schema version.
--- @type integer
Lockfile.FORMAT_VERSION = 1

--- Default lockfile filename, alongside lua-project.toml.
--- @type string
Lockfile.DEFAULT_FILENAME = "lua-project.lock"


------------------------------------ Local Functions ------------------------------------

--- @type string
local GENERATOR_NAME = "artemis"

--- Create a deep copy so callers cannot mutate internal lockfile state.
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

--- Return sorted string keys from a map.
--- @param value  table
--- @return string[]
local function sorted_string_keys(value)
    local keys = {}

    for key in pairs(value) do
        if type(key) == "string" then
            keys[#keys + 1] = key
        end
    end

    table.sort(keys)
    return keys
end

--- Validate a dense array containing only non-empty strings.
--- @param value       any
--- @param field_name  string
--- @return string[]  errors
local function validate_string_array(value, field_name)
    local errors = {}

    if type(value) ~= "table" then
        errors[#errors + 1] = string.format("'%s' must be an array of strings.", field_name)
        return errors
    end

    local count = 0
    local highest_index = 0

    for key, item in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            errors[#errors + 1] = string.format("'%s' must contain only array elements.", field_name)
        else
            count = count + 1
            if key > highest_index then
                highest_index = key
            end

            if not is_non_empty_string(item) then
                errors[#errors + 1] = string.format("Every item in '%s' must be a non-empty string.", field_name)
            end
        end
    end

    if count ~= highest_index then
        errors[#errors + 1] = string.format("'%s' must not be a sparse array.", field_name)
    end

    return errors
end

--- Check whether a value is a dense, one-based array.
--- @param value  table
--- @return boolean
local function is_dense_array(value)
    local count = 0
    local highest_index = 0

    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false
        end

        count = count + 1
        if key > highest_index then
            highest_index = key
        end
    end

    return count == highest_index
end

--- Validate the complete decoded lockfile structure.
--- @param data  any
--- @return boolean  valid
--- @return string?  error_message
local function validate_data(data)
    if type(data) ~= "table" then
        return false, "The lockfile root must be a TOML table."
    end

    local errors = {}

    if data.lockfile_version ~= Lockfile.FORMAT_VERSION then
        errors[#errors + 1] = string.format(
            "Unsupported lockfile version '%s'; this Artemis version supports format %d.",
            tostring(data.lockfile_version),
            Lockfile.FORMAT_VERSION
        )
    end

    if not is_non_empty_string(data.generated_by) then
        errors[#errors + 1] = "'generated_by' must be a non-empty string."
    end

    if type(data.project) ~= "table" then
        errors[#errors + 1] = "'project' must be a TOML table."
    else
        if not is_non_empty_string(data.project.name) then
            errors[#errors + 1] = "'project.name' is required and must be a non-empty string."
        end

        if not is_non_empty_string(data.project.lua) then
            errors[#errors + 1] = "'project.lua' is required and must be a non-empty string."
        end

        if data.project.runtime ~= nil and not is_non_empty_string(data.project.runtime) then
            errors[#errors + 1] = "'project.runtime' must be a non-empty string when provided."
        end

        if data.project.version ~= nil and not is_non_empty_string(data.project.version) then
            errors[#errors + 1] = "'project.version' must be a non-empty string when provided."
        end
    end

    if data.dependencies == nil then
        data.dependencies = {}
    elseif type(data.dependencies) ~= "table" then
        errors[#errors + 1] = "'dependencies' must be a table keyed by LuaRocks package name."
    else
        for package_name, record in pairs(data.dependencies) do
            if not is_non_empty_string(package_name) then
                errors[#errors + 1] = "Dependency names must be non-empty strings."
            elseif type(record) ~= "table" then
                errors[#errors + 1] = string.format(
                    "Lock record for dependency '%s' must be a TOML table.",
                    package_name
                )
            else
                if not is_non_empty_string(record.version) then
                    errors[#errors + 1] = string.format(
                        "Dependency '%s' must have an exact non-empty 'version'.",
                        package_name
                    )
                end

                if record.direct ~= nil and type(record.direct) ~= "boolean" then
                    errors[#errors + 1] = string.format(
                        "Dependency '%s' field 'direct' must be a boolean.",
                        package_name
                    )
                end

                for _, field_name in ipairs({ "constraint", "source", "checksum", "rockspec" }) do
                    local field_value = record[field_name]
                    if field_value ~= nil and not is_non_empty_string(field_value) then
                        errors[#errors + 1] = string.format(
                            "Dependency '%s' field '%s' must be a non-empty string when provided.",
                            package_name,
                            field_name
                        )
                    end
                end

                if record.requires ~= nil then
                    local requires_errors = validate_string_array(
                        record.requires,
                        string.format("dependencies.%s.requires", package_name)
                    )
                    for _, message in ipairs(requires_errors) do
                        errors[#errors + 1] = message
                    end
                end

                if record.direct == true and not is_non_empty_string(record.constraint) then
                    errors[#errors + 1] = string.format(
                        "Direct dependency '%s' must record its manifest 'constraint'.",
                        package_name
                    )
                end
            end
        end
    end

    if #errors > 0 then
        return false, table.concat(errors, "\n")
    end

    return true
end

--- Escape a Lua string as a TOML basic string.
--- @param value  string
--- @return string
local function quote_toml_string(value)
    local output = { '"' }
    local replacements = {
        ["\b"] = "\\b",
        ["\t"] = "\\t",
        ["\n"] = "\\n",
        ["\f"] = "\\f",
        ["\r"] = "\\r",
        ["\\"] = "\\\\",
        ['"'] = '\\"'
    }

    for index = 1, #value do
        local character = value:sub(index, index)
        local byte = value:byte(index)
        local replacement = replacements[character]

        if replacement then
            output[#output + 1] = replacement
        elseif byte < 32 or byte == 127 then
            output[#output + 1] = string.format("\\u%04X", byte)
        else
            output[#output + 1] = character
        end
    end

    output[#output + 1] = '"'
    return table.concat(output)
end

--- Serialize an array of strings deterministically.
--- @param values  string[]
--- @return string
local function serialize_string_array(values)
    local copied_values = deep_copy(values)
    table.sort(copied_values)

    local serialized = {}
    for index, value in ipairs(copied_values) do
        serialized[index] = quote_toml_string(value)
    end

    return "[" .. table.concat(serialized, ", ") .. "]"
end

--- Serialize lockfile data as deterministic TOML.
--- @param data  Artemis.LockfileData
--- @return string
local function serialize_toml(data)
    local lines = {
        "# Generated by Artemis. Do not edit manually.",
        string.format("lockfile_version = %d", data.lockfile_version),
        "generated_by = " .. quote_toml_string(data.generated_by),
        "",
        "[project]",
        "name = " .. quote_toml_string(data.project.name),
        "lua = " .. quote_toml_string(data.project.lua)
    }

    if data.project.runtime then
        lines[#lines + 1] = "runtime = " .. quote_toml_string(data.project.runtime)
    end

    if data.project.version then
        lines[#lines + 1] = "version = " .. quote_toml_string(data.project.version)
    end

    local dependency_names = sorted_string_keys(data.dependencies)
    for _, package_name in ipairs(dependency_names) do
        local record = data.dependencies[package_name]

        lines[#lines + 1] = ""
        lines[#lines + 1] = "[dependencies." .. quote_toml_string(package_name) .. "]"
        lines[#lines + 1] = "version = " .. quote_toml_string(record.version)
        lines[#lines + 1] = "direct = " .. tostring(record.direct == true)

        if record.constraint then
            lines[#lines + 1] = "constraint = " .. quote_toml_string(record.constraint)
        end
        if record.source then
            lines[#lines + 1] = "source = " .. quote_toml_string(record.source)
        end
        if record.checksum then
            lines[#lines + 1] = "checksum = " .. quote_toml_string(record.checksum)
        end
        if record.rockspec then
            lines[#lines + 1] = "rockspec = " .. quote_toml_string(record.rockspec)
        end
        if record.requires and #record.requires > 0 then
            lines[#lines + 1] = "requires = " .. serialize_string_array(record.requires)
        end
    end

    return table.concat(lines, "\n") .. "\n"
end

--- Extract manifest data from either an Artemis.Manifest or a plain table.
--- @param manifest  any
--- @return table?   manifest_data
--- @return string?  error_message
local function get_manifest_data(manifest)
    if type(manifest) ~= "table" then
        return nil, "A valid manifest or manifest data table is required."
    end

    if type(manifest.validate) == "function" then
        local valid, validation_error = manifest:validate()
        if not valid then
            return nil, validation_error
        end
    end

    local data = type(manifest.data) == "table" and manifest.data or manifest
    if not is_non_empty_string(data.name) or not is_non_empty_string(data.lua) then
        return nil, "The manifest must define non-empty 'name' and 'lua' fields."
    end

    if data.dependencies ~= nil and type(data.dependencies) ~= "table" then
        return nil, "The manifest 'dependencies' field must be a table."
    end

    return data
end

-----------------------------------------------------------------------------------------



----------------------------------- Lockfile Functions ----------------------------------

--- Construct a Lockfile from already decoded data.
--- Missing optional root fields are filled with Artemis defaults; project
--- identity and the requested Lua version are required.
--- @param data   Artemis.LockfileData
--- @param path?  string                Path to associate with this lockfile.
--- @return Artemis.Lockfile?  lockfile
--- @return string?            error_message
function Lockfile.new(data, path)
    if type(data) ~= "table" then
        return nil, "Lockfile.new expects a table as its first argument."
    end

    local copied_data = deep_copy(data)
    copied_data.lockfile_version = copied_data.lockfile_version or Lockfile.FORMAT_VERSION
    copied_data.generated_by = copied_data.generated_by or GENERATOR_NAME
    copied_data.dependencies = copied_data.dependencies or {}

    local valid, validation_error = validate_data(copied_data)
    if not valid then
        return nil, validation_error
    end

    local self = setmetatable({}, Lockfile)
    self.data = copied_data
    self.path = path or Lockfile.DEFAULT_FILENAME

    return self
end

--- Load and validate a TOML lockfile.
--- @param path?  string  Path to the lockfile. Defaults to lua-project.lock.
--- @return Artemis.Lockfile?  lockfile
--- @return string?            error_message
function Lockfile.load(path)
    path = path or Lockfile.DEFAULT_FILENAME

    if not is_non_empty_string(path) then
        return nil, "Lockfile path must be a non-empty string."
    end

    local parse_ok, parsed_data = pcall(toml.parse, path)
    if not parse_ok then
        return nil, string.format("Could not parse lockfile '%s': %s", path, tostring(parsed_data))
    end

    if type(parsed_data) ~= "table" then
        return nil, string.format("Lockfile '%s' did not decode into a TOML table.", path)
    end

    return Lockfile.new(parsed_data, path)
end

--- Create a lockfile from the current LuaRocks installation list.
--- Every installed rock is recorded, including transitive dependencies. The
--- manifest's direct dependencies must all be present in the supplied list.
--- `options.metadata[package_name]` may provide source, checksum, rockspec,
--- and requires fields that are not available in `luarocks list --porcelain`.
--- @param manifest         Artemis.Manifest|table
--- @param installed_rocks  Artemis.InstalledRock[]
--- @param options?         { runtime_version?: string, path?: string, metadata?: table }
--- @return Artemis.Lockfile?  lockfile
--- @return string?  error_message
function Lockfile.from_installed(manifest, installed_rocks, options)
    options = options or {}
    if type(options) ~= "table" then
        return nil, "Lockfile options must be a table."
    end

    local manifest_data, manifest_error = get_manifest_data(manifest)
    if not manifest_data then
        return nil, manifest_error
    end

    if type(installed_rocks) ~= "table" or not is_dense_array(installed_rocks) then
        return nil, "Installed rocks must be a dense array of rock records."
    end

    local direct_dependencies = manifest_data.dependencies or {}
    local locked_dependencies = {}
    local metadata = options.metadata or {}

    if type(metadata) ~= "table" then
        return nil, "Lockfile options.metadata must be a table when provided."
    end

    for index, rock in ipairs(installed_rocks) do
        if type(rock) ~= "table" then
            return nil, string.format("Installed rock at index %d must be a table.", index)
        end

        if not is_non_empty_string(rock.name) or not is_non_empty_string(rock.version) then
            return nil, string.format(
                "Installed rock at index %d must define non-empty name and version fields.",
                index
            )
        end

        if locked_dependencies[rock.name] then
            return nil, string.format("Installed rock '%s' appears more than once.", rock.name)
        end

        local package_metadata = metadata[rock.name] or {}
        if type(package_metadata) ~= "table" then
            return nil, string.format("Metadata for dependency '%s' must be a table.", rock.name)
        end

        local is_direct = direct_dependencies[rock.name] ~= nil
        local record = {
            version = rock.version,
            direct = is_direct
        }

        if is_direct then
            record.constraint = direct_dependencies[rock.name]
        end

        for _, field_name in ipairs({ "source", "checksum", "rockspec", "requires" }) do
            local field_value = package_metadata[field_name]
            if field_value == nil then
                field_value = rock[field_name]
            end
            if field_value ~= nil then
                record[field_name] = deep_copy(field_value)
            end
        end

        locked_dependencies[rock.name] = record
    end

    for package_name in pairs(direct_dependencies) do
        if not locked_dependencies[package_name] then
            return nil, string.format(
                "Direct dependency '%s' is declared in the manifest but is not installed; synchronize dependencies before creating the lockfile.",
                package_name
            )
        end
    end

    local project = {
        name = manifest_data.name,
        lua = manifest_data.lua
    }

    if options.runtime_version ~= nil then
        project.runtime = options.runtime_version
    end
    if manifest_data.version ~= nil then
        project.version = manifest_data.version
    end

    return Lockfile.new({
        lockfile_version = Lockfile.FORMAT_VERSION,
        generated_by = GENERATOR_NAME,
        project = project,
        dependencies = locked_dependencies
    }, options.path or Lockfile.DEFAULT_FILENAME)
end

--- Validate the current in-memory lockfile.
--- @return boolean  valid
--- @return string?  error_message
function Lockfile:validate()
    return validate_data(self.data)
end

--- Return a deep copy of the decoded lockfile data.
--- @return Artemis.LockfileData
function Lockfile:to_table()
    return deep_copy(self.data)
end

--- Get a copy of one locked package record.
--- @param package_name  string
--- @return Artemis.LockedDependency?  dependency
function Lockfile:get_dependency(package_name)
    if type(package_name) ~= "string" then
        return nil
    end

    local record = self.data.dependencies[package_name]
    return record and deep_copy(record) or nil
end

--- Return a copy of every locked package record.
--- @return table<string, Artemis.LockedDependency>
function Lockfile:get_dependencies()
    return deep_copy(self.data.dependencies)
end

--- Add or replace one locked package record.
--- `record` may be an exact version string or a LockedDependency table.
--- @param package_name  string
--- @param record        string|Artemis.LockedDependency
--- @return boolean  success
--- @return string?  error_message
function Lockfile:set_dependency(package_name, record)
    if not is_non_empty_string(package_name) then
        return false, "Dependency name must be a non-empty string."
    end

    if type(record) == "string" then
        record = { version = record, direct = false }
    elseif type(record) == "table" then
        record = deep_copy(record)
    else
        return false, "Dependency record must be an exact version string or a table."
    end

    if record.direct == nil then
        record.direct = false
    end

    local updated_data = deep_copy(self.data)
    updated_data.dependencies[package_name] = record

    local valid, validation_error = validate_data(updated_data)
    if not valid then
        return false, validation_error
    end

    self.data = updated_data
    return true
end

--- Remove one package from the lockfile.
--- This does not uninstall the package from the local LuaRocks tree.
--- @param package_name  string
--- @return boolean  removed
function Lockfile:remove_dependency(package_name)
    if not is_non_empty_string(package_name) then
        return false
    end

    if self.data.dependencies[package_name] == nil then
        return false
    end

    self.data.dependencies[package_name] = nil
    return true
end

--- Set or clear the exact Lua runtime recorded by the lockfile.
--- @param runtime_version  string?
--- @return boolean  success
--- @return string?  error_message
function Lockfile:set_runtime_version(runtime_version)
    if runtime_version ~= nil and not is_non_empty_string(runtime_version) then
        return false, "Runtime version must be a non-empty string when provided."
    end

    if runtime_version == nil then
        self.data.project.runtime = nil
    else
        self.data.project.runtime = runtime_version
    end

    return true
end

--- Check whether this lockfile describes the manifest's current direct inputs.
--- This compares project identity, Lua requirement, direct package names, and
--- exact constraints. It does not attempt to evaluate LuaRocks constraint syntax.
--- @param manifest  Artemis.Manifest|table
--- @return boolean  compatible
--- @return string?  reason
function Lockfile:matches_manifest(manifest)
    local valid, validation_error = self:validate()
    if not valid then
        return false, validation_error
    end

    local manifest_data, manifest_error = get_manifest_data(manifest)
    if not manifest_data then
        return false, manifest_error
    end

    if self.data.project.name ~= manifest_data.name then
        return false, "The lockfile belongs to a different project."
    end

    if self.data.project.lua ~= manifest_data.lua then
        return false, "The Lua version requirement changed; the lockfile must be regenerated."
    end

    if self.data.project.runtime then
        local requested_series = manifest_data.lua:match("^(%d+%.%d+)")
        local locked_series = self.data.project.runtime:match("^(%d+%.%d+)")
        if requested_series and locked_series and requested_series ~= locked_series then
            return false, "The exact Lua runtime in the lockfile does not match the manifest's Lua series."
        end
    end

    local declared_dependencies = manifest_data.dependencies or {}
    if next(declared_dependencies) == nil and next(self.data.dependencies) ~= nil then
        return false, "The lockfile contains packages, but the manifest declares no dependencies."
    end

    for package_name, constraint in pairs(declared_dependencies) do
        local locked = self.data.dependencies[package_name]
        if not locked then
            return false, string.format("Direct dependency '%s' is missing from the lockfile.", package_name)
        end

        if locked.direct ~= true or locked.constraint ~= constraint then
            return false, string.format(
                "The lock entry for '%s' does not match its manifest declaration.",
                package_name
            )
        end
    end

    for package_name, locked in pairs(self.data.dependencies) do
        if locked.direct == true and declared_dependencies[package_name] == nil then
            return false, string.format(
                "Lockfile contains direct dependency '%s', which is no longer declared in the manifest.",
                package_name
            )
        end
    end

    return true
end

--- Save the lockfile as TOML using an atomic temporary-file rename.
--- The destination directory must already exist.
--- @param path?  string  Destination path. Defaults to this lockfile's path.
--- @return boolean  success
--- @return string?  error_message
function Lockfile:save(path)
    path = path or self.path

    if not is_non_empty_string(path) then
        return false, "Lockfile path must be a non-empty string."
    end

    local valid, validation_error = self:validate()
    if not valid then
        return false, validation_error
    end

    local encoded = serialize_toml(self.data)
    local temporary_path = path .. ".tmp"
    local file, open_error = io.open(temporary_path, "wb")
    if not file then
        return false, string.format(
            "Could not open temporary lockfile '%s': %s",
            temporary_path,
            tostring(open_error)
        )
    end

    local write_result, write_error = file:write(encoded)
    if not write_result then
        file:close()
        os.remove(temporary_path)
        return false, string.format("Could not write lockfile '%s': %s", path, tostring(write_error))
    end

    local close_result, close_error = file:close()
    if not close_result then
        os.remove(temporary_path)
        return false, string.format("Could not close lockfile '%s': %s", path, tostring(close_error))
    end

    local rename_result, rename_error = os.rename(temporary_path, path)
    if not rename_result then
        os.remove(temporary_path)
        return false, string.format(
            "Could not replace lockfile '%s': %s",
            path,
            tostring(rename_error)
        )
    end

    self.path = path
    return true
end

-----------------------------------------------------------------------------------------


return Lockfile
