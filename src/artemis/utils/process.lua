--- The small boundary for unavoidable external process execution.
---
--- Artemis uses this module for LuaRocks, the C build toolchain, archive
--- extraction, and launching a project interpreter. Filesystem and HTTP work
--- should use their dedicated Lua modules instead.
--- @module 'artemis.utils.process'

local Process = {}

--- Quote one value as a POSIX shell argument.
--- @param value string
--- @return string
function Process.shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Interpret Lua's os.execute/io.popen close results.
--- @param success boolean?
--- @param exitcode string?
--- @param code integer?
--- @return boolean
local function command_succeeded(success, exitcode, code)
    return success == true or (exitcode == "exit" and code == 0)
end

--- Run a command without capturing its output.
--- @param command string
--- @return boolean success
--- @return string? error_message
function Process.execute(command)
    local success, exitcode, code = os.execute(command)
    if command_succeeded(success, exitcode, code) then
        return true
    end
    return false, string.format("Command failed (status: %s): %s", tostring(code or exitcode or success), command)
end

--- Run a command and capture combined standard output and standard error.
--- @param command string
--- @return string? output
--- @return string? error_message
function Process.capture(command)
    local handle, open_error = io.popen(command .. " 2>&1", "r")
    if not handle then
        return nil, string.format("Could not execute command: %s", tostring(open_error))
    end

    local output = handle:read("a") or ""
    local success, exitcode, code = handle:close()
    if not command_succeeded(success, exitcode, code) then
        return nil, string.format("Command failed (status: %s):\n%s", tostring(code or exitcode or success), output)
    end
    return output
end

--- Run a command from a specific working directory.
--- @param directory string
--- @param command string
--- @return boolean success
--- @return string? error_message
function Process.execute_in(directory, command)
    return Process.execute("cd " .. Process.shell_quote(directory) .. " && " .. command)
end

return Process
