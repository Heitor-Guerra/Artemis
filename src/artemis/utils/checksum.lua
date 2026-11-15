--- Cryptographic checksum operations backed by luaossl/OpenSSL.
--- @module 'artemis.utils.checksum'

local digest = require("openssl.digest")

local Checksum = {}

--- Convert binary data to lowercase hexadecimal.
--- @param value string
--- @return string
local function to_hex(value)
    local hexadecimal = {}
    for index = 1, #value do
        hexadecimal[index] = string.format("%02x", value:byte(index))
    end
    return table.concat(hexadecimal)
end

--- Calculate the SHA-256 checksum of a file without loading it all into memory.
--- @param path string
--- @return string? checksum
--- @return string? error_message
function Checksum.sha256_file(path)
    local file, open_error = io.open(path, "rb")
    if not file then
        return nil, string.format("Could not open '%s' for checksum: %s", path, tostring(open_error))
    end

    local context = digest.new("sha256")
    while true do
        local chunk, read_error = file:read(1024 * 64)
        if not chunk then
            if read_error then
                file:close()
                return nil, string.format("Could not read '%s' for checksum: %s", path, tostring(read_error))
            end
            break
        end
        context:update(chunk)
    end

    local closed, close_error = file:close()
    if not closed then
        return nil, string.format("Could not close '%s' after checksum: %s", path, tostring(close_error))
    end

    return to_hex(context:final())
end

return Checksum
