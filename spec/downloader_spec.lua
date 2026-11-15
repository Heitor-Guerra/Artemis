--- @diagnostic disable: undefined-global, undefined-field
local HttpRequest = require("http.request")
local Downloader = require("artemis.utils.downloader")
local helpers = require("spec.helpers")

describe("artemis.downloader", function()
    local original_new_from_uri

    before_each(function()
        original_new_from_uri = HttpRequest.new_from_uri
    end)

    after_each(function()
        HttpRequest.new_from_uri = original_new_from_uri
    end)

    it("fetches a successful response body", function()
        HttpRequest.new_from_uri = function(url)
            assert.equals("https://example.test/index.html", url)
            return {
                go = function(self, timeout)
                    assert.equals(60, timeout)
                    return {
                        get = function(_, name)
                            assert.equals(":status", name)
                            return "200"
                        end
                    }, {
                        get_body_as_string = function()
                            return "release index"
                        end,
                        shutdown = function() return true end
                    }
                end
            }
        end

        local contents, fetch_error = Downloader.get("https://example.test/index.html")
        assert.equals("release index", contents)
        assert.is_nil(fetch_error)
    end)

    it("streams a successful response to a file", function()
        HttpRequest.new_from_uri = function()
            return {
                go = function()
                    return {
                        get = function() return "200" end
                    }, {
                        save_body_to_file = function(_, file)
                            return file:write("archive contents") ~= nil
                        end,
                        shutdown = function() return true end
                    }
                end
            }
        end

        helpers.with_temp_dir(function(root)
            local destination = root .. "/lua.tar.gz"
            local downloaded, download_error = Downloader.download("https://example.test/lua.tar.gz", destination)
            assert.is_true(downloaded, download_error)
            assert.equals("archive contents", helpers.read_file(destination))
        end)
    end)
end)
