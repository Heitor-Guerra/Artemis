--- HTTP and HTTPS downloads for Artemis, backed by lua-http.
--- @module 'artemis.utils.downloader'

local HttpRequest = require("http.request")
local FileSystem = require("artemis.utils.filesystem")

local Downloader = {}

--- Perform an HTTP request and return its response stream.
--- @param url string
--- @param timeout number
--- @return table? headers
--- @return table? stream
--- @return number? status
--- @return string? error_message
local function request(url, timeout)
    local created, http_request = pcall(HttpRequest.new_from_uri, url)
    if not created or type(http_request) ~= "table" then
        return nil, nil, nil, tostring(http_request or "Could not create an HTTP request.")
    end

    http_request.follow_redirects = true
    http_request.max_redirects = 5

    local completed, headers, stream, request_error = pcall(http_request.go, http_request, timeout)
    if not completed then
        return nil, nil, nil, tostring(headers)
    end
    if not headers then
        return nil, nil, nil, tostring(stream or request_error)
    end

    local status = tonumber(headers:get(":status"))
    if not status then
        stream:shutdown()
        return nil, nil, nil, "The HTTP server returned an invalid status code."
    end

    return headers, stream, status
end

--- Fetch a URL into a string.
--- @param url string
--- @param options? table
--- @return string? contents
--- @return string? error_message
function Downloader.get(url, options)
    options = options or {}
    local attempts = options.attempts or 1
    local timeout = options.timeout or 60
    local last_error

    for _ = 1, attempts do
        local _, stream, status, request_error = request(url, timeout)
        if stream and status and status >= 200 and status < 300 then
            local contents, read_error = stream:get_body_as_string(timeout)
            stream:shutdown()
            if contents then
                return contents
            end
            last_error = tostring(read_error)
        else
            last_error = request_error or string.format("HTTP request failed with status %s.", tostring(status))
            if stream then
                stream:shutdown()
            end
        end
    end

    return nil, last_error
end

--- Download a URL to a file, streaming the response to disk.
--- @param url string
--- @param destination string
--- @param options? table
--- @return boolean success
--- @return string? error_message
function Downloader.download(url, destination, options)
    options = options or {}
    local attempts = options.attempts or 1
    local timeout = options.timeout or 60
    local last_error

    for _ = 1, attempts do
        local _, stream, status, request_error = request(url, timeout)
        if not stream or not status or status < 200 or status >= 300 then
            last_error = request_error or string.format("HTTP request failed with status %s.", tostring(status))
            if stream then
                stream:shutdown()
            end
        else
            local file, open_error = io.open(destination, "wb")
            if not file then
                stream:shutdown()
                return false, string.format("Could not open download destination '%s': %s", destination,
                    tostring(open_error))
            end

            local saved, save_error = stream:save_body_to_file(file, timeout)
            local closed, close_error = file:close()
            stream:shutdown()

            if saved and closed then
                return true
            end

            last_error = tostring(save_error or close_error or "Could not save the HTTP response body.")
            FileSystem.remove(destination)
        end
    end

    return false, last_error
end

return Downloader
