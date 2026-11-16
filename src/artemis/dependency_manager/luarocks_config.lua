--- Resolve and generate LuaRocks configuration for Artemis-managed trees.
--- This module is responsible for the shared download cache and for preserving
--- applicable user/project LuaRocks configuration files.
--- @module 'artemis.dependency_manager.luarocks_config'

local Path = require("artemis.utils.path")
local FileSystem = require("artemis.utils.filesystem")

local LuaRocksConfig = {}

------------------------------------ Local Functions ------------------------------------

--- Find existing LuaRocks configuration files that should be preserved.
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

-----------------------------------------------------------------------------------------


----------------------------------- Public Functions ------------------------------------

--- Resolve the shared Artemis cache directory to an absolute path.
--- @param working_directory string  Absolute working directory.
--- @param requested?  string  Explicit cache directory.
--- @return string?  cache_dir
--- @return string?  error_message
function LuaRocksConfig.resolve_cache_dir(working_directory, requested)
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

--- Create a LuaRocks config that redirects source downloads to the Artemis cache.
--- Existing user/project settings are loaded before Artemis cache and runtime settings.
--- @param working_directory string  Working directory.
--- @param cache_dir         string  Shared Artemis cache directory.
--- @param lua_version       string  LuaRocks version identifier.
--- @param explicit_config?  string  Existing LuaRocks config to preserve.
--- @param lua_dir?          string  Exact Lua installation prefix.
--- @return string?  config_path
--- @return string?  rocks_cache_dir
--- @return string?  error_message
function LuaRocksConfig.create_luarocks_cache_config(working_directory, cache_dir, lua_version, explicit_config, lua_dir)
    local rocks_cache_dir = Path.join(cache_dir, "rocks/downloads")
    local config_directory = Path.join(cache_dir, "luarocks")
    local config_path = Path.join(config_directory, "config-" .. lua_version .. ".lua")

    local parent_created, parent_create_error = FileSystem.make_directory(rocks_cache_dir)
    if parent_created then
        parent_created, parent_create_error = FileSystem.make_directory(config_directory)
    end
    if not parent_created then
        return nil, nil,
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

-----------------------------------------------------------------------------------------

return LuaRocksConfig
