--- @diagnostic disable: undefined-global, undefined-field, missing-fields, assign-type-mismatch, param-type-mismatch, need-check-nil
describe("Artemis LuaRocks packaging", function()
    local function load_rockspec()
        local environment = {}
        setmetatable(environment, { __index = _G })
        local chunk, load_error = loadfile("artemis-dev-1.rockspec", "t", environment)
        assert(chunk, load_error)
        local ok, run_error = pcall(chunk)
        assert.is_true(ok, run_error)
        return environment
    end

    it("declares Busted as a test-only LuaRocks dependency", function()
        local rockspec = load_rockspec()
        assert.equals("3.0", rockspec.rockspec_format)
        assert.is_table(rockspec.test_dependencies)
        assert.equals(1, #rockspec.test_dependencies)
        assert.matches("^busted%s+>=%s*2%.2,?%s*<%s*3%.0$", rockspec.test_dependencies[1])
        assert.equals("busted", rockspec.test.type)

        for _, dependency in ipairs(rockspec.dependencies) do
            assert.is_false(dependency:match("^busted%s") ~= nil)
        end
    end)

    it("uses Lua libraries for HTTP downloads and SHA-256 checksums", function()
        local rockspec = load_rockspec()
        local dependencies = table.concat(rockspec.dependencies, "\n")
        assert.is_truthy(dependencies:find("http >= 0.4", 1, true))
        assert.is_truthy(dependencies:find("luaossl >= 20200709", 1, true))
        assert.is_nil(dependencies:find("luasocket", 1, true))
        assert.is_nil(dependencies:find("luasec", 1, true))
    end)

    it("maps every exported Artemis module to an existing source file", function()
        local rockspec = load_rockspec()
        assert.equals("builtin", rockspec.build.type)

        for module_name, source_path in pairs(rockspec.build.modules) do
            local file, open_error = io.open(source_path, "rb")
            assert(file, module_name .. " maps to missing source " .. source_path .. ": " .. tostring(open_error))
            file:close()
        end
    end)

    it("keeps a Busted project configuration that discovers the spec directory", function()
        local file, open_error = io.open(".busted", "rb")
        assert(file, open_error)
        local contents = file:read("*a")
        file:close()
        assert.is_truthy(contents:find('ROOT = { "spec" }', 1, true))
        assert.is_truthy(contents:find("./src/?.lua", 1, true))
        assert.is_truthy(contents:find("./?/init.lua", 1, true))
    end)

    it("does not install Busted from Nix when the rockspec owns the test dependency", function()
        local file, open_error = io.open("flake.nix", "rb")
        assert(file, open_error)
        local contents = file:read("*a")
        file:close()
        assert.is_nil(contents:find("lua54Packages.busted", 1, true))

        local rockspec = load_rockspec()
        assert.equals("busted >= 2.2, < 3.0", rockspec.test_dependencies[1])
    end)

    it("makes Nix configure and verify RT_LIBDIR through the project LuaRocks wrapper", function()
        local file, open_error = io.open("flake.nix", "rb")
        assert(file, open_error)
        local contents = file:read("*a")
        file:close()

        assert.is_truthy(contents:find("./luarocks config variables.RT_LIBDIR", 1, true))
        assert.is_truthy(contents:find("./luarocks config variables.RT_DIR", 1, true))
        assert.is_truthy(contents:find('active_rt_libdir="$(./luarocks config variables.RT_LIBDIR)"', 1, true))
        assert.is_truthy(contents:find('if [ "$active_rt_libdir" != "${glibcLibraryDirectory}" ]', 1, true))
        assert.is_truthy(contents:find("return 1", 1, true))
    end)

    it("keeps native build tools in Nix while leaving Busted to LuaRocks", function()
        local file, open_error = io.open("flake.nix", "rb")
        assert(file, open_error)
        local contents = file:read("*a")
        file:close()

        assert.is_truthy(contents:find("gcc", 1, true))
        assert.is_truthy(contents:find("gnumake", 1, true))
        assert.is_truthy(contents:find("glibc.dev", 1, true))
        assert.is_nil(contents:find("lua54Packages.busted", 1, true))
    end)
end)
