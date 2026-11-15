local helpers = {}
local FileSystem = require("artemis.utils.filesystem")

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function command_succeeded(first, second, third)
    return first == true or first == 0 or (second == "exit" and third == 0)
end

function helpers.temp_dir()
    local path = os.tmpname()
    os.remove(path)

    local created, create_error = FileSystem.make_directory(path)
    assert(created, tostring(create_error or "Could not create temporary test directory"))

    return path
end

function helpers.remove_dir(path)
    if not path then
        return
    end

    local removed, remove_error = FileSystem.remove(path)
    assert(removed, tostring(remove_error or "Could not remove temporary test directory"))
end

function helpers.with_temp_dir(callback)
    local path = helpers.temp_dir()
    local results = { pcall(callback, path) }
    helpers.remove_dir(path)

    if not results[1] then
        error(results[2], 0)
    end

    table.remove(results, 1)
    return table.unpack(results)
end

function helpers.write_file(path, contents)
    local file, open_error = io.open(path, "wb")
    assert(file, tostring(open_error))

    local write_ok, write_error = file:write(contents)
    assert(write_ok, tostring(write_error))

    local close_ok, close_error = file:close()
    assert(close_ok, tostring(close_error))

    return path
end

function helpers.read_file(path)
    local file, open_error = io.open(path, "rb")
    assert(file, tostring(open_error))

    local contents = file:read("*a")
    file:close()
    return contents
end

function helpers.make_executable(path)
    local first, second, third = os.execute("chmod +x " .. shell_quote(path))
    assert(command_succeeded(first, second, third), "Could not mark test script executable")
end

function helpers.make_directory(path)
    local created, create_error = FileSystem.make_directory(path)
    assert(created, tostring(create_error))
    return path
end

function helpers.shell_quote(value)
    return shell_quote(value)
end

function helpers.command_succeeded(first, second, third)
    return command_succeeded(first, second, third)
end

function helpers.new_manifest(data)
    local Manifest = require("artemis.manifest")
    local manifest, err = Manifest.new(data)
    assert(manifest, err)
    return manifest
end

return helpers
