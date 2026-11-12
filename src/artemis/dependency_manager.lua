--- Project-local LuaRocks dependency management for Artemis.
---
--- Dependencies are recorded in the Artemis manifest, while LuaRocks performs
--- version resolution, transitive dependency resolution, compilation, and
--- installation into a standard project-local LuaRocks tree (lua_modules by
--- default).
---
--- This first implementation invokes the LuaRocks CLI through a POSIX shell.
--- @module 'artemis.dependency_manager'

--- @class Artemis.DependencyManagerOptions
--- @field tree?             string  Project-local LuaRocks tree. Defaults to "lua_modules".
--- @field luarocks?         string  LuaRocks executable or project wrapper. Defaults to "./luarocks" when present, otherwise "luarocks".
--- @field lua_version?      string  Lua version selected by the project. Defaults to manifest.data.lua.
--- @field manifest_path?    string  Path to the project manifest. Defaults to manifest.path.
--- @field metadata_dir?     string  Artemis metadata directory. Defaults to ".artemis".
--- @field cache_dir?        string  Shared Artemis cache directory. Defaults to $XDG_CACHE_HOME/artemis or ~/.cache/artemis.
--- @field luarocks_config?  string  Optional existing LuaRocks config to load before Artemis cache settings.

--- @class Artemis.InstalledRock
--- @field name     string  Installed rock name.
--- @field version  string  Installed rock version, including LuaRocks revision.

--- @class Artemis.DependencyManager
--- @field root             string            Project root directory.
--- @field manifest         Artemis.Manifest  Manifest instance modified by this manager.
--- @field manifest_path    string            Path used to persist the manifest.
--- @field tree             string            Local LuaRocks tree.
--- @field luarocks         string            LuaRocks executable.
--- @field lua_version      string            Lua version used by LuaRocks.
--- @field metadata_dir     string            Directory for Artemis-generated files.
--- @field cache_dir        string            Shared Artemis cache directory.
--- @field rocks_cache_dir  string            LuaRocks download cache directory.
--- @field luarocks_config  string            Generated LuaRocks config that points to the shared cache.

local DependencyManager = {}
DependencyManager.__index = DependencyManager

------------------------------------ Local Functions ------------------------------------

--- @type string
local ROCKSPEC_PACKAGE = "artemis-project-dependencies"

--- @type string
local ROCKSPEC_VERSION = "0.0.0-1"

--- @type string
local ROCKSPEC_FILENAME = ROCKSPEC_PACKAGE .. "-" .. ROCKSPEC_VERSION .. ".rockspec"

--- Join two paths using the slash convention accepted by LuaRocks on Unix.
--- @param first   string
--- @param second  string
--- @return string
local function join_path(first, second)
    if first == "" or first == "." then
        return first == "." and ("./" .. second) or second
    end

    return first:gsub("/+$", "") .. "/" .. second:gsub("^/+", "")
end

--- Check whether a path is absolute on Unix or Windows.
--- @param path  string
--- @return boolean
local function is_absolute_path(path)
    return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

--- Check whether a file can be opened for reading.
--- @param path  string
--- @return boolean
local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end

    file:close()
    return true
end

--- Quote a value for use as one argument in a POSIX shell command.
--- The initial Artemis shell runner targets Unix-like environments (including
--- the Nix development shell); Windows command-shell support can be added later.
--- @param value  string
--- @return string
local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Resolve the shared Artemis cache directory to an absolute path.
--- @param root        string  Absolute project root.
--- @param requested?  string  Explicit cache directory.
--- @return string?  cache_dir
--- @return string?  error_message
local function resolve_cache_dir(root, requested)
    local candidate = requested or os.getenv("ARTEMIS_CACHE_DIR") or "~/.cache/artemis"

    if not candidate or candidate == "" then
        local xdg_cache_home = os.getenv("XDG_CACHE_HOME")
        local home = os.getenv("HOME")

        if xdg_cache_home and xdg_cache_home:match("^/") then
            candidate = join_path(xdg_cache_home, "artemis")
        elseif home and home:match("^/") then
            candidate = join_path(join_path(home, ".cache"), "artemis")
        else
            candidate = join_path(root, ".cache/artemis")
        end
    elseif not is_absolute_path(candidate) then
        candidate = join_path(root, candidate)
    end

    local parent = candidate:match("^(.*)/[^/]+$")
    if not parent or parent == "" then
        parent = "/"
    end
    local mkdir_ok, mkdir_reason, mkdir_code = os.execute("mkdir -p " .. shell_quote(parent))
    local mkdir_succeeded = mkdir_ok == true or mkdir_ok == 0 or (mkdir_reason == "exit" and mkdir_code == 0)
    if not mkdir_succeeded then
        return nil, string.format("Could not create cache parent directory '%s'.", parent)
    end

    local handle, open_error = io.popen("cd " .. shell_quote(parent) .. " && pwd", "r")
    if not handle then
        return nil, string.format("Could not resolve cache parent directory: %s", tostring(open_error))
    end

    local absolute_parent = (handle:read("*l") or ""):gsub("\r$", "")
    handle:close()
    if absolute_parent == "" then
        return nil, "Could not resolve the absolute Artemis cache directory."
    end

    local basename = candidate:match("([^/]+)$") or "artemis"
    return join_path(absolute_parent, basename)
end

--- Find an existing LuaRocks configuration that should be preserved.
--- @param root              string  Project root.
--- @param lua_version       string  LuaRocks version identifier, such as "5.4".
--- @param explicit_config?  string  Explicit config path.
--- @return string[] paths
local function find_luarocks_configs(root, lua_version, explicit_config)
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
        local xdg = os.getenv("XDG_CONFIG_HOME") or join_path(home, ".config")
        candidates[#candidates + 1] = join_path(join_path(xdg, "luarocks"), "config-" .. lua_version .. ".lua")
        candidates[#candidates + 1] = join_path(join_path(home, ".luarocks"), "config-" .. lua_version .. ".lua")
        candidates[#candidates + 1] = join_path(join_path(xdg, "luarocks"), "config.lua")
        candidates[#candidates + 1] = join_path(join_path(home, ".luarocks"), "config.lua")
    end

    -- `luarocks init` may provide project-specific settings in this file.
    candidates[#candidates + 1] = join_path(join_path(root, ".luarocks"), "config-" .. lua_version .. ".lua")

    local paths = {}
    local seen = {}
    for _, path in ipairs(candidates) do
        if path and path ~= "" and not seen[path] then
            local file = io.open(path, "rb")
            if file then
                file:close()
                paths[#paths + 1] = path
                seen[path] = true
            end
        end
    end

    return paths
end

--- Create a LuaRocks config that redirects source downloads to the Artemis cache.
--- @param root              string  Project root.
--- @param cache_dir         string  Shared Artemis cache directory.
--- @param lua_version       string  LuaRocks version identifier.
--- @param explicit_config?  string  Existing LuaRocks config to preserve.
--- @return string?  config_path
--- @return string?  rocks_cache_dir
--- @return string?  error_message
local function create_luarocks_cache_config(root, cache_dir, lua_version, explicit_config)
    local rocks_cache_dir = join_path(cache_dir, "rocks/downloads")
    local config_directory = join_path(cache_dir, "luarocks")
    local config_path = join_path(config_directory, "config-" .. lua_version .. ".lua")

    local mkdir_ok, mkdir_reason, mkdir_code = os.execute(
        "mkdir -p " .. shell_quote(rocks_cache_dir) .. " " .. shell_quote(config_directory)
    )
    local mkdir_succeeded = mkdir_ok == true or mkdir_ok == 0 or (mkdir_reason == "exit" and mkdir_code == 0)
    if not mkdir_succeeded then
        return nil, nil, string.format("Could not create LuaRocks cache directory '%s'.", rocks_cache_dir)
    end

    local lines = {
        "-- Generated by Artemis. Do not edit; change the Artemis cache settings instead."
    }

    for _, existing_config in ipairs(find_luarocks_configs(root, lua_version, explicit_config)) do
        if existing_config ~= config_path then
            lines[#lines + 1] = "dofile(" .. string.format("%q", existing_config) .. ")"
        end
    end

    lines[#lines + 1] = "local_cache = " .. string.format("%q", rocks_cache_dir)
    lines[#lines + 1] = "aggressive_cache = true"
    lines[#lines + 1] = ""

    local file, open_error = io.open(config_path, "wb")
    if not file then
        return nil, nil,
            string.format("Could not write LuaRocks cache config '%s': %s", config_path, tostring(open_error))
    end

    local write_ok, write_error = file:write(table.concat(lines, "\n"))
    if not write_ok then
        file:close()
        return nil, nil, string.format("Could not write LuaRocks cache config: %s", tostring(write_error))
    end

    local close_ok, close_error = file:close()
    if not close_ok then
        return nil, nil, string.format("Could not close LuaRocks cache config: %s", tostring(close_error))
    end

    return config_path, rocks_cache_dir
end


--- Interpret the return values of os.execute/io.popen:close across Lua versions.
--- @param first   any
--- @param second  any
--- @param third   any
--- @return boolean
local function command_succeeded(first, second, third)
    if first == true or first == 0 then
        return true
    end

    return second == "exit" and third == 0
end

--- Execute a command in the project root.
--- @param self       Artemis.DependencyManager
--- @param arguments  string[]                   Arguments following the LuaRocks executable.
--- @return boolean  success
--- @return string?  error_message
local function execute_luarocks(self, arguments)
    local command_parts = {
        "cd " .. shell_quote(self.root) .. " &&",
        "LUAROCKS_CONFIG=" .. shell_quote(self.luarocks_config),
        "LUAROCKS_CONFIG_" .. self.lua_version:gsub("%.", "_") .. "=" .. shell_quote(self.luarocks_config),
        shell_quote(self.luarocks),
        "--tree=" .. shell_quote(self.tree),
        "--lua-version=" .. shell_quote(self.lua_version)
    }

    for _, argument in ipairs(arguments) do
        command_parts[#command_parts + 1] = shell_quote(argument)
    end

    local command = table.concat(command_parts, " ")
    local first, second, third = os.execute(command)

    if command_succeeded(first, second, third) then
        return true
    end

    local status = third or second or first
    return false, string.format("LuaRocks command failed (status: %s): %s", tostring(status), command)
end

--- Execute a LuaRocks command and capture its combined output.
--- @param self       Artemis.DependencyManager
--- @param arguments  string[]                   Arguments following the LuaRocks executable.
--- @return string?  output
--- @return string?  error_message
local function capture_luarocks(self, arguments)
    local command_parts = {
        "cd " .. shell_quote(self.root) .. " &&",
        "LUAROCKS_CONFIG=" .. shell_quote(self.luarocks_config),
        "LUAROCKS_CONFIG_" .. self.lua_version:gsub("%.", "_") .. "=" .. shell_quote(self.luarocks_config),
        shell_quote(self.luarocks),
        "--tree=" .. shell_quote(self.tree),
        "--lua-version=" .. shell_quote(self.lua_version)
    }

    for _, argument in ipairs(arguments) do
        command_parts[#command_parts + 1] = shell_quote(argument)
    end

    local command = table.concat(command_parts, " ") .. " 2>&1"
    local handle, open_error = io.popen(command, "r")

    if not handle then
        return nil, string.format("Could not start LuaRocks: %s", tostring(open_error))
    end

    local output = handle:read("*a") or ""
    local first, second, third = handle:close()

    if not command_succeeded(first, second, third) then
        local status = third or second or first
        return nil, string.format("LuaRocks command failed (status: %s):\n%s", tostring(status), output)
    end

    return output
end

--- Validate a LuaRocks package name before placing it in a rockspec.
--- @param package_name  any
--- @return boolean
--- @return string?
local function validate_package_name(package_name)
    if type(package_name) ~= "string" or package_name == "" then
        return false, "Package name must be a non-empty string."
    end

    -- Rock names commonly contain letters, digits, hyphens, and underscores.
    if not package_name:match("^[%w][%w_.%-]*$") then
        return false, string.format("Invalid LuaRocks package name: %s", package_name)
    end

    return true
end

--- Turn the project's Lua version into a LuaRocks dependency constraint.
--- A manifest value such as "5.4" means any patch release in the 5.4 series.
--- @param version  string
--- @return string?
local function lua_version_constraint(version)
    local major, minor = version:match("^(%d+)%.(%d+)")
    if major and minor then
        return string.format("lua >= %s.%s, < %s.%d", major, minor, major, tonumber(minor) + 1)
    end

    -- LuaJIT exposes Lua 5.1 compatibility to LuaRocks.
    if version == "jit" or version == "luajit" then
        return "lua >= 5.1, < 5.2"
    end

    return nil
end

--- Return dependency entries in deterministic package-name order.
--- @param dependencies  table<string, string>
--- @return string[]?  lines
--- @return string?    error_message
local function make_dependency_lines(dependencies)
    local names = {}
    for name in pairs(dependencies) do
        names[#names + 1] = name
    end
    table.sort(names)

    local lines = {}
    for _, name in ipairs(names) do
        local constraint = dependencies[name]
        local valid, validation_error = validate_package_name(name)
        if not valid then
            return nil, validation_error
        end

        if constraint == "*" then
            -- An unconstrained Artemis dependency becomes a bare LuaRocks dependency.
            lines[#lines + 1] = name
        elseif type(constraint) ~= "string" or not constraint:match("%S") then
            return nil, string.format("Dependency '%s' has an empty version constraint.", name)
        elseif constraint:find("[\r\n]") then
            return nil, string.format("Dependency '%s' has a version constraint containing a line break.", name)
        else
            lines[#lines + 1] = name .. " " .. constraint
        end
    end

    return lines
end

-----------------------------------------------------------------------------------------


----------------------------------- Manager Functions -----------------------------------


--- Build a temporary rockspec from the current Artemis manifest.
--- @return string?  rockspec_path Relative rockspec path from the project root.
--- @return string?  error_message
function DependencyManager:_write_dependency_rockspec()
    local dependencies = self.manifest:get_dependencies()
    local dependency_lines, dependency_error = make_dependency_lines(dependencies)
    if not dependency_lines then
        return nil, dependency_error
    end

    local lua_constraint = lua_version_constraint(self.lua_version)
    if lua_constraint then
        table.insert(dependency_lines, 1, lua_constraint)
    end

    local lines = {
        'rockspec_format = "3.0"',
        string.format("package = %q", ROCKSPEC_PACKAGE),
        string.format("version = %q", ROCKSPEC_VERSION),
        "source = {",
        -- LuaRocks requires source.url in a rockspec. `--only-deps` skips
        --fetching/building the project itself, so this reserved URL is never fetched.
        '    url = "https://example.invalid/artemis-dependency-spec",',
        "}",
        "description = {",
        '    summary = "Generated dependency specification for an Artemis project",',
        '    license = "MIT",',
        "}",
        "dependencies = {"
    }

    for _, dependency in ipairs(dependency_lines) do
        lines[#lines + 1] = "    " .. string.format("%q", dependency) .. ","
    end

    lines[#lines + 1] = "}"
    lines[#lines + 1] = "build = { type = \"none\" }"
    lines[#lines + 1] = ""

    local directory = join_path(self.root, self.metadata_dir)
    local mkdir_command = "mkdir -p " .. shell_quote(directory)
    local mkdir_ok, mkdir_reason, mkdir_code = os.execute(mkdir_command)

    if not command_succeeded(mkdir_ok, mkdir_reason, mkdir_code) then
        return nil, string.format("Could not create Artemis metadata directory '%s'.", directory)
    end

    local relative_path = join_path(self.metadata_dir, ROCKSPEC_FILENAME)
    local absolute_path = join_path(self.root, relative_path)
    local file, open_error = io.open(absolute_path, "wb")

    if not file then
        return nil, string.format("Could not write generated rockspec '%s': %s", absolute_path, tostring(open_error))
    end

    local write_ok, write_error = file:write(table.concat(lines, "\n"))
    if not write_ok then
        file:close()
        os.remove(absolute_path)
        return nil, string.format("Could not write generated rockspec '%s': %s", absolute_path, tostring(write_error))
    end

    local close_ok, close_error = file:close()
    if not close_ok then
        os.remove(absolute_path)
        return nil, string.format("Could not close generated rockspec '%s': %s", absolute_path, tostring(close_error))
    end

    return relative_path
end

--- Create a dependency manager bound to a project and its manifest.
--- @param project_root  string                            Project root directory.
--- @param manifest      Artemis.Manifest                  Manifest instance.
--- @param options?      Artemis.DependencyManagerOptions  Optional configuration.
--- @return Artemis.DependencyManager?  manager
--- @return string?                     error_message
function DependencyManager.new(project_root, manifest, options)
    if type(project_root) ~= "string" or not project_root:match("%S") then
        return nil, "Project root must be a non-empty string."
    end

    if type(manifest) ~= "table" or type(manifest.get_dependencies) ~= "function"
        or type(manifest.set_dependency) ~= "function" or type(manifest.remove_dependency) ~= "function"
        or type(manifest.save) ~= "function" then
        return nil, "DependencyManager.new expects a valid Artemis.Manifest instance."
    end

    options = options or {}
    if type(options) ~= "table" then
        return nil, "DependencyManager options must be a table."
    end

    local root_command = io.popen("cd " .. shell_quote(project_root) .. " && pwd", "r")
    if not root_command then
        return nil, "Could not resolve project root directory."
    end

    local root = (root_command:read("*l") or ""):gsub("\r$", "")
    root_command:close()
    if root == "" then
        return nil, "Could not resolve project root directory."
    end


    local manifest_path = options.manifest_path or manifest.path or "lua-project.toml"
    if type(manifest_path) ~= "string" or not manifest_path:match("%S") then
        return nil, "Manifest path must be a non-empty string."
    end

    if not is_absolute_path(manifest_path) then
        local normalized_root = root:gsub("/+$", "")
        local already_rooted = normalized_root ~= ""
            and manifest_path:sub(1, #normalized_root + 1) == normalized_root .. "/"

        if not already_rooted then
            manifest_path = join_path(root, manifest_path)
        end
    end

    local local_wrapper = join_path(root, "luarocks")
    local luarocks = options.luarocks
    if not luarocks then
        luarocks = file_exists(local_wrapper) and "./luarocks" or "luarocks"
    end

    local lua_version = options.lua_version or (manifest.data and manifest.data.lua)
    if type(lua_version) ~= "string" or not lua_version:match("%S") then
        return nil, "The manifest must declare a Lua version before dependencies can be managed."
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
    if type(metadata_dir) ~= "string" or not metadata_dir:match("%S") or is_absolute_path(metadata_dir) then
        return nil, "Artemis metadata directory must be a non-empty relative path."
    end

    if options.luarocks_config ~= nil
        and (type(options.luarocks_config) ~= "string" or not options.luarocks_config:match("%S")) then
        return nil, "LuaRocks config path must be a non-empty string."
    end

    if options.cache_dir ~= nil and (type(options.cache_dir) ~= "string" or options.cache_dir == "") then
        return nil, "options.cache_dir must be a non-empty path string."
    end

    local cache_dir, cache_error = resolve_cache_dir(root, options.cache_dir)
    if not cache_dir then
        return nil, cache_error
    end

    local luarocks_config, rocks_cache_dir, config_error = create_luarocks_cache_config(
        root,
        cache_dir,
        lua_version,
        options.luarocks_config
    )
    if not luarocks_config then
        return nil, config_error
    end

    local self = setmetatable({}, DependencyManager)
    self.root = root
    self.manifest = manifest
    self.manifest_path = manifest_path
    self.tree = tree
    self.luarocks = luarocks
    self.lua_version = lua_version
    self.metadata_dir = metadata_dir
    self.cache_dir = cache_dir
    self.rocks_cache_dir = rocks_cache_dir
    self.luarocks_config = luarocks_config

    return self
end

--- Install all direct and transitive dependencies declared in the manifest.
--- LuaRocks handles version resolution and installs rocks into the configured tree.
--- This operation does not remove rocks that are no longer referenced; removal is
--- deliberately conservative because a rock may still be required transitively.
--- @return boolean  success
--- @return string?  error_message
function DependencyManager:sync()
    local valid, validation_error = self.manifest:validate()
    if not valid then
        return false, validation_error
    end

    local dependencies = self.manifest:get_dependencies()
    if next(dependencies) == nil then
        return true
    end

    local rockspec_path, rockspec_error = self:_write_dependency_rockspec()
    if not rockspec_path then
        return false, rockspec_error
    end

    local success, install_error = execute_luarocks(self, {
        "install",
        "--deps-mode=one",
        "--only-deps",
        rockspec_path
    })

    os.remove(join_path(self.root, rockspec_path))

    if not success then
        return false, install_error
    end

    return true
end

--- Add a rock to the manifest and install the resulting dependency set.
--- When no constraint is supplied, "*" is stored in the manifest and emitted as
--- an unconstrained dependency in the generated LuaRocks rockspec.
--- @param package_name         string  LuaRocks package name.
--- @param version_constraint?  string  LuaRocks constraint, e.g. ">= 0.7, < 1.0".
--- @return boolean  success
--- @return string?  error_message
function DependencyManager:add(package_name, version_constraint)
    local valid, validation_error = validate_package_name(package_name)
    if not valid then
        return false, validation_error
    end

    version_constraint = version_constraint or "*"
    if type(version_constraint) ~= "string" or not version_constraint:match("%S") then
        return false, "Version constraint must be a non-empty string."
    end

    if version_constraint:find("[\r\n]") then
        return false, "Version constraint cannot contain line breaks."
    end

    local previous_constraint = self.manifest:get_dependency(package_name)
    local updated, update_error = self.manifest:set_dependency(package_name, version_constraint)
    if not updated then
        return false, update_error
    end

    local installed, install_error = self:sync()
    if not installed then
        if previous_constraint then
            self.manifest:set_dependency(package_name, previous_constraint)
        else
            self.manifest:remove_dependency(package_name)
        end
        return false, install_error
    end

    local saved, save_error = self.manifest:save(self.manifest_path)
    if not saved then
        if previous_constraint then
            self.manifest:set_dependency(package_name, previous_constraint)
        else
            self.manifest:remove_dependency(package_name)
        end

        return false, string.format(
            "Dependencies were installed, but the manifest could not be saved. The local tree may now contain the package. %s",
            tostring(save_error)
        )
    end

    return true
end

--- Remove a direct dependency from the manifest and try to uninstall its rock.
--- LuaRocks is allowed to refuse removal when another installed rock depends on
--- the package. In that case the manifest change is kept and the rock remains in
--- the local tree because it may still be a transitive dependency.
--- @param package_name  string  LuaRocks package name.
--- @return boolean  success
--- @return string?  warning_or_error
function DependencyManager:remove(package_name)
    local valid, validation_error = validate_package_name(package_name)
    if not valid then
        return false, validation_error
    end

    local previous_constraint = self.manifest:get_dependency(package_name)
    if not previous_constraint then
        return false, string.format("Dependency '%s' is not declared in the manifest.", package_name)
    end

    local removed, remove_error = self.manifest:remove_dependency(package_name)
    if not removed then
        return false, remove_error or string.format("Could not remove dependency '%s'.", package_name)
    end

    local saved, save_error = self.manifest:save(self.manifest_path)
    if not saved then
        self.manifest:set_dependency(package_name, previous_constraint)
        return false, save_error
    end

    local installed_rocks, list_error = self:list_installed()
    if not installed_rocks then
        return true, string.format(
            "Removed '%s' from the manifest, but could not check the local tree for an installed copy: %s",
            package_name,
            tostring(list_error)
        )
    end

    local is_installed = false
    for _, rock in ipairs(installed_rocks) do
        if rock.name == package_name then
            is_installed = true
            break
        end
    end

    if not is_installed then
        return true
    end

    local uninstall_ok, uninstall_error = execute_luarocks(self, {
        "remove",
        "--deps-mode=one",
        package_name
    })

    if not uninstall_ok then
        return true, string.format(
            "Removed '%s' from the manifest, but LuaRocks kept it in the local tree. It may still be required by another installed rock. Details: %s",
            package_name,
            tostring(uninstall_error)
        )
    end

    return true
end

--- List rocks currently installed in the project's local LuaRocks tree.
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

--- Check whether a rock is installed in this project's local tree.
--- @param package_name  string
--- @return boolean?  installed
--- @return string?   error_message
function DependencyManager:is_installed(package_name)
    local valid, validation_error = validate_package_name(package_name)
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

--- Return the LuaRocks path command output for this project tree.
--- The output contains shell exports such as LUA_PATH and LUA_CPATH.
--- @return string?  output
--- @return string?  error_message
function DependencyManager:path()
    return capture_luarocks(self, { "path" })
end

--- Alias for add(), matching install-oriented terminology.
--- @param package_name         string
--- @param version_constraint?  string
--- @return boolean  success
--- @return string?  error_message
function DependencyManager:install(package_name, version_constraint)
    return self:add(package_name, version_constraint)
end

--- Alias for remove(), matching uninstall-oriented terminology.
--- @param package_name  string
--- @return boolean  success
--- @return string?  warning_or_error
function DependencyManager:uninstall(package_name)
    return self:remove(package_name)
end

-----------------------------------------------------------------------------------------


return DependencyManager
