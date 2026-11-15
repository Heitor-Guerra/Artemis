--- Shared path operations used throughout Artemis.
---
--- Paths are represented with forward slashes internally. The current runtime
--- manager targets Unix-like systems, while absolute-path checks also accept
--- Windows drive paths for manifest and CLI validation.
--- @module 'artemis.utils.path'

local lfs = require("lfs")

local Path = {}

--- Join two paths, preserving an absolute second path.
--- @param first string
--- @param second string
--- @return string
function Path.join(first, second)
    if second:sub(1, 1) == "/" or second:match("^%a:[/\\]") then
        return second
    end

    if first == "" then
        local ret = second:gsub("^[/\\]+", "")
        return ret
    end
    if first == "." then
        return "./" .. second:gsub("^[/\\]+", "")
    end

    return first:gsub("[/\\]+$", "") .. "/" .. second:gsub("^[/\\]+", "")
end

--- Check whether a path is absolute on Unix or Windows.
--- @param path string
--- @return boolean
function Path.is_absolute(path)
    return type(path) == "string" and (path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil)
end

--- Return the parent directory of a path.
--- @param path string
--- @return string
function Path.parent(path)
    local normalized = path:gsub("[/\\]+$", "")
    local parent = normalized:match("^(.*)[/\\][^/\\]+$")
    if not parent or parent == "" then
        if normalized:match("^[/\\]") then
            return "/"
        end
        return "."
    end
    return parent
end

--- Return the final path component.
--- @param path string
--- @return string
function Path.basename(path)
    return path:gsub("[/\\]+$", ""):match("([^/\\]+)$") or path
end

--- Resolve an existing directory to an absolute path without spawning a shell.
--- @param path string
--- @return string? absolute_path
--- @return string? error_message
function Path.absolute_directory(path)
    local original, current_error = lfs.currentdir()
    if not original then
        return nil, current_error
    end

    local changed, change_error = lfs.chdir(path)
    if not changed then
        return nil, change_error
    end

    local absolute_path, resolve_error = lfs.currentdir()
    local restored, restore_error = lfs.chdir(original)
    if not restored then
        return nil, string.format("Could not restore working directory '%s': %s", original, tostring(restore_error))
    end
    if not absolute_path then
        return nil, resolve_error
    end

    return absolute_path
end

return Path
