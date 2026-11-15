--- Shared filesystem operations built on LuaFileSystem and the Lua I/O library.
--- @module 'artemis.utils.filesystem'

local lfs = require("lfs")
local Path = require("artemis.utils.path")

local FileSystem = {}

--- Return filesystem attributes for a path, or nil when it does not exist.
--- @param path string
--- @return table? attributes
function FileSystem.attributes(path)
    return lfs.symlinkattributes(path)
end

--- Check whether a regular file exists.
--- @param path string
--- @return boolean
function FileSystem.file_exists(path)
    local attributes = lfs.attributes(path)
    return attributes ~= nil and attributes.mode == "file"
end

--- Check whether a directory exists.
--- @param path string
--- @return boolean
function FileSystem.directory_exists(path)
    local attributes = lfs.attributes(path)
    return attributes ~= nil and attributes.mode == "directory"
end

--- Check whether a file is executable.
--- @param path string
--- @return boolean
function FileSystem.executable_exists(path)
    local attributes = lfs.attributes(path)
    return attributes ~= nil and attributes.mode == "file"
        and attributes.permissions ~= nil and attributes.permissions:match("x") ~= nil
end

--- Create a directory and any missing parents.
--- @param path string
--- @return boolean success
--- @return string? error_message
function FileSystem.make_directory(path)
    if path == "" or path == "." or FileSystem.directory_exists(path) then
        return true
    end

    local parent = Path.parent(path)
    if parent ~= path and parent ~= "." and not FileSystem.directory_exists(parent) then
        local created, create_error = FileSystem.make_directory(parent)
        if not created then
            return false, create_error
        end
    end

    local created, create_error = lfs.mkdir(path)
    if created or FileSystem.directory_exists(path) then
        return true
    end

    return false, string.format("Could not create directory '%s': %s", path, tostring(create_error))
end

--- Read a file as binary data.
--- @param path string
--- @return string? contents
--- @return string? error_message
function FileSystem.read_file(path)
    local file, open_error = io.open(path, "rb")
    if not file then
        return nil, open_error
    end

    local contents, read_error = file:read("a")
    local closed, close_error = file:close()
    if contents == nil then
        return nil, read_error
    end
    if not closed then
        return nil, close_error
    end

    return contents
end

--- Write binary data to a file, creating its parent directory when needed.
--- @param path string
--- @param contents string
--- @return boolean success
--- @return string? error_message
function FileSystem.write_file(path, contents)
    local parent = Path.parent(path)
    if parent ~= "." and parent ~= path then
        local created, create_error = FileSystem.make_directory(parent)
        if not created then
            return false, create_error
        end
    end

    local file, open_error = io.open(path, "wb")
    if not file then
        return false, string.format("Could not open '%s' for writing: %s", path, tostring(open_error))
    end

    local written, write_error = file:write(contents)
    if not written then
        file:close()
        return false, string.format("Could not write '%s': %s", path, tostring(write_error))
    end

    local closed, close_error = file:close()
    if not closed then
        return false, string.format("Could not close '%s': %s", path, tostring(close_error))
    end

    return true
end

--- Write a file only when it does not already exist.
--- @param path string
--- @param contents string
--- @return boolean success
--- @return string? error_message
function FileSystem.write_new_file(path, contents)
    if FileSystem.file_exists(path) then
        return true
    end
    return FileSystem.write_file(path, contents)
end

--- Remove a file or directory tree without following symbolic links.
--- @param path string
--- @return boolean success
--- @return string? error_message
function FileSystem.remove(path)
    local attributes = lfs.symlinkattributes(path)
    if not attributes then
        return true
    end

    if attributes.mode == "directory" then
        local iterator, directory_object = lfs.dir(path)
        if not iterator then
            return false, string.format("Could not list directory '%s': %s", path, tostring(directory_object))
        end

        for name in iterator, directory_object do
            if name ~= "." and name ~= ".." then
                local removed, remove_error = FileSystem.remove(Path.join(path, name))
                if not removed then
                    return false, remove_error
                end
            end
        end

        local removed, remove_error = lfs.rmdir(path)
        if not removed then
            return false, string.format("Could not remove directory '%s': %s", path, tostring(remove_error))
        end
        return true
    end

    local removed, remove_error = os.remove(path)
    if not removed then
        return false, string.format("Could not remove '%s': %s", path, tostring(remove_error))
    end
    return true
end

--- Rename a file or directory.
--- @param source string
--- @param destination string
--- @return boolean success
--- @return string? error_message
function FileSystem.rename(source, destination)
    local parent = Path.parent(destination)
    if parent ~= "." then
        local created, create_error = FileSystem.make_directory(parent)
        if not created then
            return false, create_error
        end
    end

    local renamed, rename_error = os.rename(source, destination)
    if not renamed then
        return false, string.format("Could not move '%s' to '%s': %s", source, destination, tostring(rename_error))
    end
    return true
end

--- List the direct child directories of a directory.
--- @param path string
--- @return string[]? directories
--- @return string? error_message
function FileSystem.list_directories(path)
    local iterator, directory_object = lfs.dir(path)
    if not iterator then
        return nil, tostring(directory_object)
    end

    local directories = {}
    for name in iterator, directory_object do
        if name ~= "." and name ~= ".." then
            local child = Path.join(path, name)
            local attributes = lfs.symlinkattributes(child)
            if attributes and attributes.mode == "directory" then
                directories[#directories + 1] = child
            end
        end
    end

    return directories
end

return FileSystem
