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
local LuaRocksConfig = require("artemis.dependency_manager.luarocks_config")
local RockspecGeneration = require("artemis.dependency_manager.rockspec_generation")

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
        local valid, validation_error = RockspecGeneration.validate_package_name(package_name)
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


    local cache_dir, cache_error = LuaRocksConfig.resolve_cache_dir(absolute_working_directory, options.cache_dir)
    if not cache_dir then
        return nil, cache_error
    end

    local luarocks_config, rocks_cache_dir, config_error = LuaRocksConfig.create_luarocks_cache_config(
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

    local rockspec_path, rockspec_error = RockspecGeneration.write_dependency_rockspec(self.working_directory,
        self.metadata_dir, self.lua_version, dependencies)
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
        return capture_luarocks(self, {
            "install",
            "--deps-mode=one",
            "--only-deps",
            rockspec_path
        })
    end

    local output, install_error
    if native_lock_contents then
        output, install_error = with_luarocks_lockfile(self, native_lock_contents, install_dependencies)
    else
        output, install_error = install_dependencies()
    end

    FileSystem.remove(Path.join(self.working_directory, rockspec_path))

    if not output then
        return false, install_error
    end

    return true
end

--- Build and install the current project from a generated or existing rockspec.
--- This is the LuaRocks compatibility implementation of `artemis build`.
--- @param rockspec_path string
--- @return boolean success
--- @return string? error_message
function DependencyManager:build(rockspec_path)
    if type(rockspec_path) ~= "string" or not rockspec_path:match("%S") then
        return false, "A rockspec path is required to build the project."
    end
    local output, build_error = capture_luarocks(self, { "make", rockspec_path })
    if not output then return false, build_error end
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
        local valid, validation_error = RockspecGeneration.validate_package_name(package_name)
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
    local valid, validation_error = RockspecGeneration.validate_package_name(package_name)
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

    local output, uninstall_error = capture_luarocks(self, {
        "remove",
        "--deps-mode=one",
        package_name
    })

    if not output then
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
    local valid, validation_error = RockspecGeneration.validate_package_name(package_name)
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
