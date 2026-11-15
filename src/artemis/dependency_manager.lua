--- Install independent dependency declarations into a configured LuaRocks tree.
---
--- This module knows nothing about Artemis project metadata, manifests, or
--- Artemis lockfiles. Callers provide Dependency values and, optionally, exact
--- resolved versions. LuaRocks' own native lockfile format is handled internally.
--- LuaRocks remains responsible for version resolution, transitive dependency
--- resolution, compilation, and installation.
---
--- LuaRocks commands are invoked through the shared process utility.
--- @module 'artemis.dependency_manager'

local Path = require("artemis.utils.path")
local FileSystem = require("artemis.utils.filesystem")
local Process = require("artemis.utils.process")
local TableUtils = require("artemis.utils.table_utils")

--- @class Artemis.DependencyManagerOptions
--- @field tree?             string  LuaRocks tree. Defaults to "lua_modules".
--- @field luarocks?         string  LuaRocks executable. Defaults to "./luarocks" when present, otherwise "luarocks".
--- @field lua_version       string  Lua version used by LuaRocks.
--- @field lua_dir?          string  Exact Lua installation prefix used to compile native rocks.
--- @field metadata_dir?     string  Directory for temporary generated rockspecs. Defaults to ".artemis".
--- @field cache_dir?        string  Shared download cache directory. Defaults to $XDG_CACHE_HOME/artemis or ~/.cache/artemis.
--- @field luarocks_config?  string  Optional existing LuaRocks config to load before cache settings.

--- @class Artemis.Dependency
--- @field name        string  LuaRocks package name.
--- @field constraint  string  LuaRocks version constraint ("*" means any version).

--- @class Artemis.InstalledRock
--- @field name     string  Installed rock name.
--- @field version  string  Installed rock version, including LuaRocks revision.

--- @class Artemis.DependencyManager
--- @field working_directory  string            Working directory for LuaRocks commands and generated files.
--- @field tree               string            Configured LuaRocks tree.
--- @field luarocks           string            LuaRocks executable.
--- @field lua_version        string            Lua version used by LuaRocks.
--- @field lua_dir?           string            Exact Lua installation prefix used for native builds.
--- @field metadata_dir       string            Directory for generated rockspecs.
--- @field cache_dir          string            Shared download cache directory.
--- @field rocks_cache_dir    string            LuaRocks download cache directory.
--- @field luarocks_config    string            Generated LuaRocks config for the shared cache.
local DependencyManager = {}
DependencyManager.__index = DependencyManager

------------------------------------ Local Functions ------------------------------------

--- @type string
local ROCKSPEC_PACKAGE = "artemis-dependencies"

--- @type string
local ROCKSPEC_VERSION = "0.0.0-1"

--- @type string
local ROCKSPEC_FILENAME = ROCKSPEC_PACKAGE .. "-" .. ROCKSPEC_VERSION .. ".rockspec"

--- Resolve the shared Artemis cache directory to an absolute path.
--- @param working_directory string  Absolute working directory.
--- @param requested?  string  Explicit cache directory.
--- @return string?  cache_dir
--- @return string?  error_message
local function resolve_cache_dir(working_directory, requested)
    local candidate = requested or os.getenv("ARTEMIS_CACHE_DIR")

    if candidate == nil or candidate == "" then
        local xdg_cache_home = os.getenv("XDG_CACHE_HOME")
        local home = os.getenv("HOME")

        if xdg_cache_home and xdg_cache_home:match("^/") then
            candidate = Path.join(xdg_cache_home, "artemis")
        elseif home and home:match("^/") then
            candidate = Path.join(Path.join(home, ".cache"), "artemis")
        else
            candidate = Path.join(working_directory, ".cache/artemis")
        end
    end

    -- Expand an explicitly supplied home-relative path before resolving other
    -- relative paths against the working directory. Only the current user's home
    -- directory is supported; named-user expansion is shell-specific.
    if candidate == "~" or candidate:sub(1, 2) == "~/" then
        local home = os.getenv("HOME")
        if not home or not home:match("^/") then
            return nil, "Cannot expand the cache path because HOME is not an absolute path."
        end

        candidate = candidate == "~" and home or Path.join(home, candidate:sub(3))
    elseif candidate:sub(1, 1) == "~" then
        return nil, "Named-user home paths are not supported for the Artemis cache directory."
    elseif not Path.is_absolute(candidate) then
        candidate = Path.join(working_directory, candidate)
    end

    candidate = candidate:gsub("/+$", "")
    if candidate == "" then
        candidate = "/artemis"
    end

    local parent = candidate:match("^(.*)/[^/]+$")
    if not parent or parent == "" then
        parent = "/"
    end
    local parent_created, parent_create_error = FileSystem.make_directory(parent)
    if not parent_created then
        return nil, string.format("Could not create Artemis cache parent directory: %s", parent_create_error)
    end

    local absolute_parent, parent_error = Path.absolute_directory(parent)
    if not absolute_parent then
        return nil, string.format("Could not resolve Artemis cache directory: %s", parent_error)
    end

    local basename = candidate:match("([^/]+)$") or "artemis"
    return Path.join(absolute_parent, basename)
end

--- Find an existing LuaRocks configuration that should be preserved.
--- @param working_directory string  Working directory.
--- @param lua_version       string  LuaRocks version identifier, such as "5.4".
--- @param explicit_config?  string  Explicit config path.
--- @return string[]  paths
local function find_luarocks_configs(working_directory, lua_version, explicit_config)
    local candidates = {}
    local specific_env = os.getenv("LUAROCKS_CONFIG_" .. lua_version:gsub("%.", "_"))
    local generic_env = os.getenv("LUAROCKS_CONFIG")

    if explicit_config then
        candidates[#candidates + 1] = explicit_config
    elseif specific_env then
        candidates[#candidates + 1] = specific_env
    elseif generic_env then
        candidates[#candidates + 1] = generic_env
    else
        local home = os.getenv("HOME") or ""
        local xdg = os.getenv("XDG_CONFIG_HOME") or Path.join(home, ".config")
        candidates[#candidates + 1] = Path.join(Path.join(xdg, "luarocks"), "config-" .. lua_version .. ".lua")
        candidates[#candidates + 1] = Path.join(Path.join(home, ".luarocks"), "config-" .. lua_version .. ".lua")
        candidates[#candidates + 1] = Path.join(Path.join(xdg, "luarocks"), "config.lua")
        candidates[#candidates + 1] = Path.join(Path.join(home, ".luarocks"), "config.lua")
    end

    -- `luarocks init` may provide working-directory-specific settings in this file.
    candidates[#candidates + 1] = Path.join(Path.join(working_directory, ".luarocks"), "config-" .. lua_version .. ".lua")

    local paths = {}
    local seen = {}
    for _, path in ipairs(candidates) do
        if path and path ~= "" and not seen[path] then
            if FileSystem.file_exists(path) then
                paths[#paths + 1] = path
                seen[path] = true
            end
        end
    end

    return paths
end

--- Create a LuaRocks config that redirects source downloads to the Artemis cache.
--- @param working_directory string  Working directory.
--- @param cache_dir         string  Shared Artemis cache directory.
--- @param lua_version       string  LuaRocks version identifier.
--- @param explicit_config?  string  Existing LuaRocks config to preserve.
--- @param lua_dir?          string  Exact Lua installation prefix.
--- @return string?  config_path
--- @return string?  rocks_cache_dir
--- @return string?  error_message
local function create_luarocks_cache_config(working_directory, cache_dir, lua_version, explicit_config, lua_dir)
    local rocks_cache_dir = Path.join(cache_dir, "rocks/downloads")
    local config_directory = Path.join(cache_dir, "luarocks")
    local config_path = Path.join(config_directory, "config-" .. lua_version .. ".lua")

    local parent_created, parent_create_error = FileSystem.make_directory(rocks_cache_dir)
    if parent_created then
        parent_created, parent_create_error = FileSystem.make_directory(config_directory)
    end
    if not parent_created then
        return nil,
            string.format("Could not create LuaRocks cache directory '%s': %s.", rocks_cache_dir, parent_create_error)
    end

    local lines = {
        "-- Generated by Artemis. Do not edit; change the Artemis cache settings instead."
    }

    for _, existing_config in ipairs(find_luarocks_configs(working_directory, lua_version, explicit_config)) do
        if existing_config ~= config_path then
            lines[#lines + 1] = "dofile(" .. string.format("%q", existing_config) .. ")"
        end
    end

    lines[#lines + 1] = "local_cache = " .. string.format("%q", rocks_cache_dir)
    lines[#lines + 1] = "aggressive_cache = true"

    -- Configure LuaRocks to compile native rocks against the exact Lua runtime
    -- selected by Artemis, rather than whichever interpreter happens to be on PATH.
    if lua_dir then
        local lua_bindir = Path.join(lua_dir, "bin")
        local lua_executable = Path.join(lua_bindir, "lua")
        local lua_include = Path.join(lua_dir, "include")
        local lua_library = Path.join(lua_dir, "lib")

        lines[#lines + 1] = "variables = variables or {}"
        lines[#lines + 1] = "variables.LUA = " .. string.format("%q", lua_executable)
        lines[#lines + 1] = "variables.LUA_DIR = " .. string.format("%q", lua_dir)
        lines[#lines + 1] = "variables.LUA_BINDIR = " .. string.format("%q", lua_bindir)
        lines[#lines + 1] = "variables.LUA_INCDIR = " .. string.format("%q", lua_include)
        lines[#lines + 1] = "variables.LUA_LIBDIR = " .. string.format("%q", lua_library)
    end

    lines[#lines + 1] = ""

    local saved, save_error = FileSystem.write_file(config_path, table.concat(lines, "\n"))
    if not saved then
        return nil, nil, string.format("Could not write LuaRocks cache config '%s': %s", config_path, save_error)
    end

    return config_path, rocks_cache_dir
end

--- Execute a command in the configured working directory.
--- @param self       Artemis.DependencyManager
--- @param arguments  string[]                   Arguments following the LuaRocks executable.
--- @return boolean  success
--- @return string?  error_message
local function execute_luarocks(self, arguments)
    local command_parts = {
        "cd " .. Process.shell_quote(self.working_directory) .. " &&",
        "LUAROCKS_CONFIG=" .. Process.shell_quote(self.luarocks_config),
        "LUAROCKS_CONFIG_" .. self.lua_version:gsub("%.", "_") .. "=" .. Process.shell_quote(self.luarocks_config),
        Process.shell_quote(self.luarocks),
        "--tree=" .. Process.shell_quote(self.tree),
        "--lua-version=" .. Process.shell_quote(self.lua_version)
    }

    for _, argument in ipairs(arguments) do
        command_parts[#command_parts + 1] = Process.shell_quote(argument)
    end

    local command = table.concat(command_parts, " ")

    local success, run_error = Process.execute(command)
    if not success then
        return false, string.format("Could not start LuaRocks: %s", run_error)
    end

    return true
end

--- Execute a LuaRocks command and capture its combined output.
--- @param self       Artemis.DependencyManager
--- @param arguments  string[]                   Arguments following the LuaRocks executable.
--- @return string?  output
--- @return string?  error_message
local function capture_luarocks(self, arguments)
    local command_parts = {
        "cd " .. Process.shell_quote(self.working_directory) .. " &&",
        "LUAROCKS_CONFIG=" .. Process.shell_quote(self.luarocks_config),
        "LUAROCKS_CONFIG_" .. self.lua_version:gsub("%.", "_") .. "=" .. Process.shell_quote(self.luarocks_config),
        Process.shell_quote(self.luarocks),
        "--tree=" .. Process.shell_quote(self.tree),
        "--lua-version=" .. Process.shell_quote(self.lua_version)
    }

    for _, argument in ipairs(arguments) do
        command_parts[#command_parts + 1] = Process.shell_quote(argument)
    end
    local command = table.concat(command_parts, " ")

    local output, run_error = Process.capture(command)
    if not output then
        return nil, string.format("Could not start LuaRocks: %s", run_error)
    end

    return output
end

--- Validate a LuaRocks package name before placing it in a rockspec.
--- @param package_name  any
--- @return boolean
--- @return string?
local function validate_package_name(package_name)
    if type(package_name) ~= "string" or package_name == "" then
        return false, "Package name must be a non-empty string."
    end

    -- Rock names commonly contain letters, digits, hyphens, and underscores.
    if not package_name:match("^[%w][%w_.%-]*$") then
        return false, string.format("Invalid LuaRocks package name: %s", package_name)
    end

    return true
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

        local valid, validation_error = validate_package_name(dependency.name)
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


--- Convert exact package versions to LuaRocks' native lockfile format.
--- LuaRocks expects a Lua chunk returning { dependencies = { name = version } }.
--- @param exact_versions  table<string, string>
--- @return string?  contents
--- @return string?  error_message
local function serialize_luarocks_lock(exact_versions)
    if type(exact_versions) ~= "table" then
        return nil, "Exact versions must be a table."
    end

    local names = {}
    for package_name, version in pairs(exact_versions) do
        local valid, validation_error = validate_package_name(package_name)
        if not valid then
            return nil, validation_error
        end

        if type(version) ~= "string" or not version:match("%S") then
            return nil, string.format("Exact version for '%s' must be a non-empty string.", package_name)
        end

        names[#names + 1] = package_name
    end
    table.sort(names)

    local lines = {
        "-- Generated temporarily by Artemis from supplied exact dependency versions.",
        "return {",
        "    dependencies = {"
    }

    for _, package_name in ipairs(names) do
        lines[#lines + 1] = string.format("        [%q] = %q,", package_name, exact_versions[package_name])
    end

    lines[#lines + 1] = "    },"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""

    return table.concat(lines, "\n")
end

--- Run a callback while LuaRocks' native lockfile is staged in the working directory.
--- Any pre-existing LuaRocks lockfile is restored, including when installation fails.
--- @param self      Artemis.DependencyManager
--- @param contents  string                     Serialized LuaRocks lockfile.
--- @param callback  fun(): boolean, string?
--- @return boolean  success
--- @return string?  error_message
local function with_luarocks_lockfile(self, contents, callback)
    local lock_path = Path.join(self.working_directory, "luarocks.lock")
    local temporary_path = lock_path .. ".artemis-tmp"
    local had_previous = FileSystem.file_exists(lock_path)
    local previous_contents

    if had_previous then
        local read_error
        previous_contents, read_error = FileSystem.read_file(lock_path)
        if previous_contents == nil then
            return false, string.format("Could not preserve existing '%s': %s", lock_path, read_error)
        end
    end

    FileSystem.remove(temporary_path)
    local staged, stage_error = FileSystem.write_file(temporary_path, contents)
    if not staged then
        FileSystem.remove(temporary_path)
        return false, string.format("Could not stage LuaRocks lockfile: %s", stage_error)
    end

    local moved, move_error = FileSystem.rename(temporary_path, lock_path)
    if not moved then
        FileSystem.remove(temporary_path)
        return false, string.format("Could not activate temporary LuaRocks lockfile: %s", move_error)
    end

    local callback_ok, command_ok, command_error = pcall(callback)

    local restored, restore_error
    if had_previous then
        local restore_temp = lock_path .. ".artemis-restore-tmp"
        FileSystem.remove(restore_temp)
        restored, restore_error = FileSystem.write_file(restore_temp, previous_contents)
        if restored then
            restored, restore_error = FileSystem.rename(restore_temp, lock_path)
        end
        if not restored then
            FileSystem.remove(restore_temp)
        end
    else
        restored, restore_error = FileSystem.remove(lock_path)
        if restored == nil then
            restored = not FileSystem.file_exists(lock_path)
        end
    end

    if not restored then
        return false,
            string.format(
                "Dependency installation finished, but Artemis could not restore the previous 'luarocks.lock': %s",
                restore_error)
    end

    if not callback_ok then
        return false, string.format("LuaRocks synchronization raised an error: %s", tostring(command_ok))
    end

    return command_ok, command_error
end

-----------------------------------------------------------------------------------------


----------------------------------- Manager Functions -----------------------------------


--- Build a temporary rockspec from supplied dependency declarations.
--- @param dependencies  Artemis.Dependency[]
--- @return string?  rockspec_path Relative path from the working directory.
--- @return string?  error_message
function DependencyManager:_write_dependency_rockspec(dependencies)
    local dependency_lines, dependency_error = make_dependency_lines(dependencies)
    if not dependency_lines then
        return nil, dependency_error
    end

    local lua_constraint = lua_version_constraint(self.lua_version)
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
    lines[#lines + 1] = "build = { type = \"none\" }"
    lines[#lines + 1] = ""

    local directory = Path.join(self.working_directory, self.metadata_dir)
    local parent_created, parent_create_error = FileSystem.make_directory(directory)
    if not parent_created then
        return nil, string.format("Could not create metadata directory '%s': %s", directory, parent_create_error)
    end

    local relative_path = Path.join(self.metadata_dir, ROCKSPEC_FILENAME)
    local absolute_path = Path.join(self.working_directory, relative_path)
    local saved, save_error = FileSystem.write_file(absolute_path, table.concat(lines, "\n"))
    if not saved then
        return nil, string.format("Could not write generated rockspec '%s': %s", absolute_path, save_error)
    end

    return relative_path
end

--- Create a dependency manager for a working directory and LuaRocks tree.
--- The manager does not load or retain project metadata or dependency sources.
--- @param working_directory  string                            Working directory for commands and temporary files.
--- @param options?           Artemis.DependencyManagerOptions  Optional configuration.
--- @return Artemis.DependencyManager?  manager
--- @return string?                     error_message
function DependencyManager.new(working_directory, options)
    if type(working_directory) ~= "string" or not working_directory:match("%S") then
        return nil, "Working directory must be a non-empty string."
    end

    options = options or {}
    if type(options) ~= "table" then
        return nil, "DependencyManager options must be a table."
    end
    local absolute_working_directory, directory_error = Path.absolute_directory(working_directory)
    if not absolute_working_directory then
        return nil, string.format("Could not resolve working directory: %s", directory_error)
    end

    local local_wrapper = Path.join(absolute_working_directory, "luarocks")
    local luarocks = options.luarocks
    if not luarocks then
        luarocks = FileSystem.file_exists(local_wrapper) and "./luarocks" or "luarocks"
    end

    local lua_version = options.lua_version
    if type(lua_version) ~= "string" or not lua_version:match("%S") then
        return nil, "A non-empty Lua version must be configured before dependencies can be installed."
    end

    -- LuaRocks uses `jit` (not `luajit`) as the --lua-version identifier.
    if lua_version == "luajit" then
        lua_version = "jit"
    else
        -- LuaRocks selects a Lua series (5.4), not an individual patch release (5.4.7).
        lua_version = lua_version:match("^(%d+%.%d+)") or lua_version
    end

    local tree = options.tree or "lua_modules"
    if type(tree) ~= "string" or not tree:match("%S") then
        return nil, "LuaRocks tree must be a non-empty path."
    end

    if type(luarocks) ~= "string" or not luarocks:match("%S") then
        return nil, "LuaRocks executable must be a non-empty string."
    end

    local metadata_dir = options.metadata_dir or ".artemis"
    if type(metadata_dir) ~= "string" or not metadata_dir:match("%S") or Path.is_absolute(metadata_dir) then
        return nil, "Generated rockspec directory must be a non-empty relative path."
    end

    if options.luarocks_config ~= nil
        and (type(options.luarocks_config) ~= "string" or not options.luarocks_config:match("%S")) then
        return nil, "LuaRocks config path must be a non-empty string."
    end

    if options.cache_dir ~= nil and (type(options.cache_dir) ~= "string" or options.cache_dir == "") then
        return nil, "options.cache_dir must be a non-empty path string."
    end

    if options.lua_dir ~= nil and (type(options.lua_dir) ~= "string" or not options.lua_dir:match("%S")) then
        return nil, "options.lua_dir must be a non-empty path string."
    end


    local cache_dir, cache_error = resolve_cache_dir(absolute_working_directory, options.cache_dir)
    if not cache_dir then
        return nil, cache_error
    end

    local luarocks_config, rocks_cache_dir, config_error = create_luarocks_cache_config(
        absolute_working_directory,
        cache_dir,
        lua_version,
        options.luarocks_config,
        options.lua_dir
    )
    if not luarocks_config or not rocks_cache_dir then
        return nil, config_error
    end

    local self = setmetatable({}, DependencyManager)
    self.working_directory = absolute_working_directory
    self.tree = tree
    self.luarocks = luarocks
    self.lua_version = lua_version
    self.lua_dir = options.lua_dir
    self.metadata_dir = metadata_dir
    self.cache_dir = cache_dir
    self.rocks_cache_dir = rocks_cache_dir
    self.luarocks_config = luarocks_config

    return self
end

--- Install the supplied direct dependencies and their transitive dependencies.
--- Exact resolved versions may be supplied separately to constrain the full graph.
--- This operation does not read or mutate the Artemis manifest or lockfile.
--- @param dependencies     Artemis.Dependency[]     Direct dependency declarations.
--- @param exact_versions? table<string, string>    Exact versions for direct and transitive rocks.
--- @return boolean  success
--- @return string?  error_message
function DependencyManager:install(dependencies, exact_versions)
    if #dependencies == 0 then
        if exact_versions ~= nil then
            if type(exact_versions) ~= "table" then
                return false, "Exact versions must be supplied as a table."
            end
            if next(exact_versions) ~= nil then
                return false, "Exact versions cannot be supplied without direct dependencies."
            end
        end
        return true
    end

    local rockspec_path, rockspec_error = self:_write_dependency_rockspec(dependencies)
    if not rockspec_path then
        return false, rockspec_error
    end

    local native_lock_contents
    if exact_versions ~= nil then
        if type(exact_versions) ~= "table" then
            return false, "Exact versions must be supplied as a table."
        end

        for _, dependency in ipairs(dependencies) do
            local version = exact_versions[dependency.name]
            if type(version) ~= "string" or not version:match("%S") then
                return false, string.format("Dependency '%s' has no exact locked version.", dependency.name)
            end
        end

        local lock_error
        native_lock_contents, lock_error = serialize_luarocks_lock(exact_versions)
        if not native_lock_contents then
            return false, lock_error
        end
    end

    local function install_dependencies()
        return execute_luarocks(self, {
            "install",
            "--deps-mode=one",
            "--only-deps",
            rockspec_path
        })
    end

    local success, install_error
    if native_lock_contents then
        success, install_error = with_luarocks_lockfile(self, native_lock_contents, install_dependencies)
    else
        success, install_error = install_dependencies()
    end

    FileSystem.remove(Path.join(self.working_directory, rockspec_path))

    if not success then
        return false, install_error
    end

    return true
end

--- Verify that each supplied exact package version is installed.
--- This detects LuaRocks releases that do not honor the native lockfile adapter.
--- @param exact_versions  table<string, string>
--- @return boolean  valid
--- @return string?  error_message
function DependencyManager:verify_versions(exact_versions)
    if type(exact_versions) ~= "table" then
        return false, "Exact versions must be a table."
    end

    for package_name, expected_version in pairs(exact_versions) do
        local valid, validation_error = validate_package_name(package_name)
        if not valid then
            return false, validation_error
        end
        if type(expected_version) ~= "string" or not expected_version:match("%S") then
            return false, string.format("Exact version for '%s' must be a non-empty string.", package_name)
        end
    end

    local installed, list_error = self:list_installed()
    if not installed then
        return false, list_error
    end

    local installed_versions = {}
    for _, rock in ipairs(installed) do
        installed_versions[rock.name] = installed_versions[rock.name] or {}
        installed_versions[rock.name][rock.version] = true
    end

    local names = {}
    for package_name in pairs(exact_versions) do
        names[#names + 1] = package_name
    end
    table.sort(names)

    for _, package_name in ipairs(names) do
        local expected_version = exact_versions[package_name]
        if not installed_versions[package_name] or not installed_versions[package_name][expected_version] then
            return false, string.format(
                "LuaRocks did not install the expected version of '%s' (expected %s). "
                ..
                "Check that the configured LuaRocks version supports exact-version lockfile installs and that the version is available.",
                package_name,
                tostring(expected_version)
            )
        end
    end

    return true
end

--- Uninstall a rock from the configured LuaRocks tree.
--- The caller owns any declaration or lockfile changes. LuaRocks may refuse to
--- remove a package that is still required by another installed rock.
--- @param package_name  string  LuaRocks package name.
--- @return boolean  success
--- @return string?  warning_or_error
function DependencyManager:uninstall(package_name)
    local valid, validation_error = validate_package_name(package_name)
    if not valid then
        return false, validation_error
    end

    local installed, list_error = self:is_installed(package_name)
    if installed == nil then
        return true, string.format(
            "Could not check the local tree for an installed copy of '%s': %s",
            package_name,
            list_error
        )
    end

    if not installed then
        return true
    end

    local uninstalled, uninstall_error = execute_luarocks(self, {
        "remove",
        "--deps-mode=one",
        package_name
    })

    if not uninstalled then
        return true, string.format(
            "LuaRocks kept '%s' in the local tree. It may still be required by another installed rock. Details: %s",
            package_name,
            uninstall_error
        )
    end

    return true
end

--- List rocks currently installed in the configured LuaRocks tree.
--- @return Artemis.InstalledRock[]?  rocks
--- @return string?                   error_message
function DependencyManager:list_installed()
    local output, command_error = capture_luarocks(self, { "list", "--porcelain" })
    if not output then
        return nil, command_error
    end

    local rocks = {}
    for line in output:gmatch("[^\r\n]+") do
        local name, version = line:match("^%s*([^%s]+)%s+([^%s]+)")
        if name and version then
            rocks[#rocks + 1] = {
                name = name,
                version = version
            }
        end
    end

    return rocks
end

--- Check whether a rock is installed in the configured LuaRocks tree.
--- @param package_name  string
--- @return boolean?  installed
--- @return string?   error_message
function DependencyManager:is_installed(package_name)
    local valid, validation_error = validate_package_name(package_name)
    if not valid then
        return nil, validation_error
    end

    local rocks, list_error = self:list_installed()
    if not rocks then
        return nil, list_error
    end

    for _, rock in ipairs(rocks) do
        if rock.name == package_name then
            return true
        end
    end

    return false
end

--- Return the configured local LuaRocks tree path.
--- @return string
function DependencyManager:get_tree()
    return self.tree
end

--- Return the LuaRocks path command output for the configured tree.
--- The output contains shell exports such as LUA_PATH and LUA_CPATH.
--- @return string?  output
--- @return string?  error_message
function DependencyManager:path()
    return capture_luarocks(self, { "path" })
end

-----------------------------------------------------------------------------------------


return DependencyManager
