--- Generate temporary rockspecs for dependency-only LuaRocks installations.
--- This module validates Artemis dependency declarations and translates them into
--- a temporary rockspec. It does not execute LuaRocks or inspect project metadata.
--- @module 'artemis.dependency_manager.rockspec_generation'

local Path = require("artemis.utils.path")
local FileSystem = require("artemis.utils.filesystem")
local TableUtils = require("artemis.utils.table_utils")
local lfs = require("lfs")
local Process = require("artemis.utils.process")

local RockspecGeneration = {}

local ROCKSPEC_PACKAGE = "artemis-dependencies"
local ROCKSPEC_VERSION = "0.0.0-1"
local ROCKSPEC_FILENAME = ROCKSPEC_PACKAGE .. "-" .. ROCKSPEC_VERSION .. ".rockspec"

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


--- Discover Lua modules below a project source directory.
--- Files named init.lua represent their parent module; a file named after its
--- parent directory (for example project/project.lua) also maps to that parent.
--- @param working_directory string
--- @param source_directory string
--- @param main? string
--- @return table<string, string>? modules
--- @return string? error_message
local function discover_project_modules(working_directory, source_directory, main)
    local modules = {}
    local main_path = type(main) == "string" and main:gsub("\\", "/") or nil

    local function walk(directory, relative)
        local iterator, directory_object = lfs.dir(directory)
        if not iterator then return false, tostring(directory_object) end
        for name in iterator, directory_object do
            if name ~= "." and name ~= ".." then
                local absolute = Path.join(directory, name)
                local child_relative = relative == "" and name or Path.join(relative, name)
                local attributes = lfs.symlinkattributes(absolute)
                if attributes and attributes.mode == "directory" then
                    local success, walk_error = walk(absolute, child_relative)
                    if not success then return false, walk_error end
                elseif attributes and attributes.mode == "file" and name:match("%.lua$") then
                    local project_relative = Path.join(source_directory, child_relative):gsub("\\", "/")
                    project_relative = project_relative:gsub("^%./", "")
                    if project_relative ~= main_path then
                        local module_path = child_relative:gsub("\\", "/"):gsub("%.lua$", "")
                        local segments = {}
                        for segment in module_path:gmatch("[^/]+") do
                            segments[#segments + 1] = segment
                        end
                        if segments[#segments] == "init" then
                            table.remove(segments)
                        elseif #segments > 1 and segments[#segments] == segments[#segments - 1] then
                            table.remove(segments)
                        end
                        local module_name = table.concat(segments, ".")
                        if module_name ~= "" then
                            local previous = modules[module_name]
                            if previous == nil or Path.basename(project_relative) == "init.lua" then
                                modules[module_name] = project_relative
                            end
                        end
                    end
                end
            end
        end
        return true
    end

    local absolute_source = Path.join(working_directory, source_directory)
    local success, walk_error = walk(absolute_source, "")
    if not success then return nil, walk_error end
    return modules
end

local function project_source_url(data, working_directory)
    if data.source_url then return data.source_url end

    local command = "cd " .. Process.shell_quote(working_directory)
        .. " && git config --get remote.origin.url"
    local remote = Process.capture(command)
    if remote and remote:match("%S") then
        remote = remote:match("^%s*(.-)%s*$")
        if remote:match("^https?://") or remote:match("^ssh://") then
            return "git+" .. remote
        elseif remote:match("^git@") then
            local host, path = remote:match("^git@([^:]+):(.+)$")
            if host and path then return "git+https://" .. host .. "/" .. path end
        end
    end

    -- This still produces a valid local-build rockspec. Projects intended for
    -- publication should set source_url in artemis-project.toml.
    return "file://."
end

--- Generate a public project rockspec from an Artemis manifest.
--- The source URL is taken from manifest.source_url or the Git origin; when
--- neither exists, `file://.` is used for local `make`-style builds only.
--- @param manifest Artemis.Manifest|table
--- @param working_directory string
--- @param output_path? string Destination path, relative to the project root unless absolute.
--- @return string? rockspec_path
--- @return table? rockspec_data
--- @return string? error_message
function RockspecGeneration.write_project_rockspec(manifest, working_directory, output_path)
    local data = type(manifest) == "table" and (manifest.data or manifest) or nil
    if type(data) ~= "table" then
        return nil, nil, "A valid Artemis manifest or manifest data table is required."
    end
    local valid, validation_error = RockspecGeneration.validate_package_name(data.name)
    if not valid then return nil, nil, validation_error end
    if type(data.version) ~= "string" or not data.version:match("%S") then
        return nil, nil, "The project manifest must define a version before generating a rockspec."
    end
    local rock_version = data.version
    if not rock_version or not rock_version:match("^[%w%._%+%-]+$") then
        return nil, nil, "Project version may contain only letters, digits, dots, underscores, plus signs, and hyphens."
    end

    if not rock_version:match("%-%d+$") then rock_version = rock_version .. "-1" end

    local source_directory = FileSystem.directory_exists(Path.join(working_directory, "src")) and "src" or "."
    if source_directory == "src" then
        local source_attributes = lfs.symlinkattributes(Path.join(working_directory, "src"))
        if not source_attributes or source_attributes.mode ~= "directory" then
            return nil, nil, "Project src/ must be a regular directory, not a symbolic link."
        end
    end
    local modules = {}
    if type(data.modules) == "table" and next(data.modules) ~= nil then
        for module_name, source_path in pairs(data.modules) do
            if not is_valid_module_name(module_name) then
                return nil, nil,
                    string.format("Invalid Lua module name '%s' in manifest.modules.", tostring(module_name))
            end
            if type(source_path) ~= "string" or source_path == "" or Path.is_absolute(source_path) then
                return nil, nil, string.format("Source path for module '%s' must be a relative path.", module_name)
            end
            if source_path:find("[\r\n]") then
                return nil, nil, string.format("Source path for module '%s' cannot contain line breaks.", module_name)
            end
            local normalized = source_path:gsub("\\", "/")
            for segment in normalized:gmatch("[^/]+") do
                if segment == ".." or segment == "." then
                    return nil, nil,
                        string.format("Source path for module '%s' cannot contain traversal segments.", module_name)
                end
            end
            if not FileSystem.file_exists(Path.join(working_directory, source_path)) then
                return nil, nil,
                    string.format("Source file '%s' for module '%s' does not exist.", source_path, module_name)
            end
            modules[module_name] = normalized
        end
    else
        local discovered, discover_error = discover_project_modules(
            working_directory,
            source_directory,
            data.main
        )
        if not discovered then return nil, nil, discover_error end
        modules = discovered
    end

    if next(modules) == nil then
        return nil, nil, "No Lua modules were found. Add Lua sources under src/ or define [modules] in the manifest."
    end

    local dependencies = {}
    local lua_constraint = lua_version_constraint(data.lua)
    if lua_constraint then dependencies[#dependencies + 1] = lua_constraint end
    for _, package_name in ipairs(TableUtils.sorted_string_keys(data.dependencies or {})) do
        local constraint = data.dependencies[package_name]
        dependencies[#dependencies + 1] = constraint == "*"
            and package_name or (package_name .. " " .. constraint)
    end

    local source = {
        url = project_source_url(data, working_directory)
    }
    if data.source_tag then source.tag = data.source_tag end

    local rockspec_data = {
        rockspec_format = "3.0",
        package = data.name,
        version = rock_version,
        source = source,
        description = {
            summary = data.description or data.name,
            license = data.license or "GPL-3.0-only"
        },
        dependencies = dependencies,
        build = {
            type = "builtin",
            modules = modules
        }
    }
    if type(data.authors) == "table" and #data.authors > 0 then
        rockspec_data.description.authors = data.authors
    end
    if type(data.maintainers) == "table" and #data.maintainers > 0 then
        rockspec_data.description.maintainers = data.maintainers
    end

    local lines = {
        'rockspec_format = "3.0"',
        string.format("package = %q", rockspec_data.package),
        string.format("version = %q", rockspec_data.version),
        "source = {",
        string.format("    url = %q,", source.url)
    }
    if source.tag then lines[#lines + 1] = string.format("    tag = %q,", source.tag) end
    lines[#lines + 1] = "}"
    lines[#lines + 1] = "description = {"
    lines[#lines + 1] = string.format("    summary = %q,", rockspec_data.description.summary)
    lines[#lines + 1] = string.format("    license = %q,", rockspec_data.description.license)
    for _, field in ipairs({ "authors", "maintainers" }) do
        local values = rockspec_data.description[field]
        if type(values) == "table" and #values > 0 then
            local quoted = {}
            for _, value in ipairs(values) do quoted[#quoted + 1] = string.format("%q", value) end
            lines[#lines + 1] = "    " .. field .. " = { " .. table.concat(quoted, ", ") .. " },"
        end
    end
    lines[#lines + 1] = "}"
    lines[#lines + 1] = "dependencies = {"
    for _, dependency in ipairs(dependencies) do
        lines[#lines + 1] = "    " .. string.format("%q", dependency) .. ","
    end
    lines[#lines + 1] = "}"
    lines[#lines + 1] = "build = {"
    lines[#lines + 1] = '    type = "builtin",'
    lines[#lines + 1] = "    modules = {"
    for _, module_name in ipairs(TableUtils.sorted_string_keys(modules)) do
        lines[#lines + 1] = string.format("        [%q] = %q,", module_name, modules[module_name])
    end
    lines[#lines + 1] = "    },"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""

    local filename = string.format("%s-%s.rockspec", data.name, rock_version)
    local destination = output_path or filename
    local absolute_destination = Path.is_absolute(destination)
        and destination or Path.join(working_directory, destination)
    local saved, save_error = FileSystem.write_file(absolute_destination, table.concat(lines, "\n"))
    if not saved then
        return nil, nil, string.format("Could not write project rockspec '%s': %s", absolute_destination, save_error)
    end
    return absolute_destination, rockspec_data
end

return RockspecGeneration
