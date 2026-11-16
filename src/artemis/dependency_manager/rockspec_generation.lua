--- Generate temporary rockspecs for dependency-only LuaRocks installations.
--- This module validates Artemis dependency declarations and translates them into
--- a temporary rockspec. It does not execute LuaRocks or inspect project metadata.
--- @module 'artemis.dependency_manager.rockspec_generation'

local Path = require("artemis.utils.path")
local FileSystem = require("artemis.utils.filesystem")
local TableUtils = require("artemis.utils.table_utils")

local RockspecGeneration = {}

local ROCKSPEC_PACKAGE = "artemis-dependencies"
local ROCKSPEC_VERSION = "0.0.0-1"
local ROCKSPEC_FILENAME = ROCKSPEC_PACKAGE .. "-" .. ROCKSPEC_VERSION .. ".rockspec"

------------------------------------ Local Functions ------------------------------------

--- Turn the configured Lua version into a LuaRocks dependency constraint.
--- A series value such as "5.4" means any patch release in the 5.4 series.
--- @param version  string
--- @return string?
local function lua_version_constraint(version)
    local major, minor = version:match("^(%d+)%.(%d+)")
    if major and minor then
        return string.format("lua >= %s.%s, < %s.%d", major, minor, major, tonumber(minor) + 1)
    end

    -- LuaJIT exposes Lua 5.1 compatibility to LuaRocks.
    if version == "jit" or version == "luajit" then
        return "lua >= 5.1, < 5.2"
    end

    return nil
end

--- Validate a dense dependency array and return its rockspec lines.
--- @param dependencies  Artemis.Dependency[]
--- @return string[]?  lines
--- @return string?    error_message
local function make_dependency_lines(dependencies)
    if type(dependencies) ~= "table" or not TableUtils.is_dense_array(dependencies) then
        return nil, "Dependencies must be a dense array of Artemis.Dependency values."
    end

    local sorted_dependencies = {}
    local seen = {}
    for index, dependency in ipairs(dependencies) do
        if type(dependency) ~= "table" or not dependency.name then
            return nil, string.format("Dependency at index %d must be an Artemis.Dependency instance.", index)
        end

        local valid, validation_error = RockspecGeneration.validate_package_name(dependency.name)
        if not valid then
            return nil, validation_error
        end

        if type(dependency.constraint) ~= "string" or not dependency.constraint:match("%S") then
            return nil, string.format("Dependency '%s' has an empty version constraint.", dependency.name)
        end
        if dependency.constraint:find("[\r\n]") then
            return nil,
                string.format("Dependency '%s' has a version constraint containing a line break.", dependency.name)
        end
        if seen[dependency.name] then
            return nil, string.format("Dependency '%s' was supplied more than once.", dependency.name)
        end

        seen[dependency.name] = true
        sorted_dependencies[#sorted_dependencies + 1] = dependency
    end

    table.sort(sorted_dependencies, function(left, right)
        return left.name < right.name
    end)

    local lines = {}
    for _, dependency in ipairs(sorted_dependencies) do
        if dependency.constraint == "*" then
            lines[#lines + 1] = dependency.name
        else
            lines[#lines + 1] = dependency.name .. " " .. dependency.constraint
        end
    end

    return lines
end

-----------------------------------------------------------------------------------------


----------------------------------- Public Functions ------------------------------------

--- Validate a LuaRocks package name before placing it in a rockspec or command.
--- @param package_name  any
--- @return boolean
--- @return string?
function RockspecGeneration.validate_package_name(package_name)
    if type(package_name) ~= "string" or package_name == "" then
        return false, "Package name must be a non-empty string."
    end

    -- Rock names commonly contain letters, digits, hyphens, and underscores.
    if not package_name:match("^[%w][%w_.%-]*$") then
        return false, string.format("Invalid LuaRocks package name: %s", package_name)
    end

    return true
end

--- Write a temporary dependency rockspec and return its working-directory-relative path.
--- @param working_directory  string  Absolute project working directory.
--- @param metadata_dir       string  Relative directory for generated metadata.
--- @param lua_version        string  LuaRocks version identifier.
--- @param dependencies       Artemis.Dependency[]
--- @return string?  rockspec_path
--- @return string?  error_message
function RockspecGeneration.write_dependency_rockspec(working_directory, metadata_dir, lua_version, dependencies)
    local dependency_lines, dependency_error = make_dependency_lines(dependencies)
    if not dependency_lines then
        return nil, dependency_error
    end

    local lua_constraint = lua_version_constraint(lua_version)
    if lua_constraint then
        table.insert(dependency_lines, 1, lua_constraint)
    end

    local lines = {
        'rockspec_format = "3.0"',
        string.format("package = %q", ROCKSPEC_PACKAGE),
        string.format("version = %q", ROCKSPEC_VERSION),
        "source = {",
        -- LuaRocks requires source.url in a rockspec. `--only-deps` skips
        -- fetching/building the project itself, so this reserved URL is never fetched.
        '    url = "https://example.invalid/artemis-dependency-spec",',
        "}",
        "description = {",
        '    summary = "Temporary dependency specification for Artemis",',
        '    license = "GPL-3.0-only",',
        "}",
        "dependencies = {"
    }

    for _, dependency in ipairs(dependency_lines) do
        lines[#lines + 1] = "    " .. string.format("%q", dependency) .. ","
    end

    lines[#lines + 1] = "}"
    lines[#lines + 1] = 'build = { type = "none" }'
    lines[#lines + 1] = ""

    local directory = Path.join(working_directory, metadata_dir)
    local parent_created, parent_create_error = FileSystem.make_directory(directory)
    if not parent_created then
        return nil, string.format("Could not create metadata directory '%s': %s", directory, parent_create_error)
    end

    local relative_path = Path.join(metadata_dir, ROCKSPEC_FILENAME)
    local absolute_path = Path.join(working_directory, relative_path)
    local saved, save_error = FileSystem.write_file(absolute_path, table.concat(lines, "\n"))
    if not saved then
        return nil, string.format("Could not write generated rockspec '%s': %s", absolute_path, save_error)
    end

    return relative_path
end

-----------------------------------------------------------------------------------------

return RockspecGeneration
