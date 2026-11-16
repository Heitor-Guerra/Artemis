--- Manage project-selected Lua runtimes and reuse installations from a shared cache.
---
--- RuntimeManager coordinates release resolution, installation, and cache
--- management. Downloading, checksum verification, extraction, and compilation
--- are delegated to RuntimeInstaller.
---
--- @module 'artemis.runtime_manager'

local Path = require("artemis.utils.path")
local FileSystem = require("artemis.utils.filesystem")
local RuntimeInstaller = require("artemis.runtime_manager.runtime_installer")
local ReleaseCatalog = require("artemis.runtime_manager.release_catalog")

--- @class Artemis.RuntimeManagerOptions
--- @field cache_dir? string Shared Artemis cache directory. Defaults to $XDG_CACHE_HOME/artemis or ~/.cache/artemis.
--- @field tar? string tar executable. Defaults to "tar".
--- @field make? string make executable. Defaults to "make".
--- @field source_url? string Official Lua source index URL.
--- @field downloader? table HTTP client override, primarily for tests.
--- @field checksum? table Checksum provider override, primarily for tests.
--- @field release_catalog? table Release catalog override, primarily for tests.
--- @field installer? table Installer override, primarily for tests.

--- @class Artemis.RuntimeManager
--- @field cache_dir string Shared Artemis cache directory.
--- @field downloads_dir string Directory containing downloaded Lua source archives.
--- @field runtimes_dir string Directory containing compiled Lua installations.
--- @field build_dir string Temporary source/build directory.
--- @field installer Artemis.RuntimeInstaller Runtime source installer.
--- @field release_catalog table Lua release catalog.
local RuntimeManager = {}
RuntimeManager.__index = RuntimeManager
RuntimeManager.DEFAULT_SOURCE_URL = RuntimeInstaller.DEFAULT_SOURCE_URL

------------------------------------ Local Functions ------------------------------------

--- Parse a requested Lua version.
--- A series such as "5.4" resolves through the release catalog, while an exact
--- version such as "5.4.0" remains pinned to that release.
--- @param requested_version string
--- @return string? series
--- @return string? exact_version
--- @return string? error_message
local function parse_requested_version(requested_version)
    if type(requested_version) ~= "string" or requested_version == "" then
        return nil, nil, "Lua version must be a non-empty string."
    end

    if requested_version == "jit" or requested_version == "luajit" then
        return nil, nil, "LuaJIT is not supported by the source-build runtime manager yet."
    end

    local major, minor, patch = requested_version:match("^(%d+)%.(%d+)%.(%d+)$")
    if major then
        return major .. "." .. minor, major .. "." .. minor .. "." .. patch
    end

    major, minor = requested_version:match("^(%d+)%.(%d+)$")
    if major then
        return major .. "." .. minor, nil
    end

    return nil, nil, string.format(
        "Invalid Lua version '%s'. Use a release series such as '5.4' or an exact version such as '5.4.9'.",
        requested_version
    )
end

--- Resolve the shared Artemis cache directory.
--- @param requested_cache_dir? string
--- @return string? cache_dir
--- @return string? error_message
local function resolve_cache_dir(requested_cache_dir)
    local candidate = requested_cache_dir
    if candidate == nil then
        candidate = os.getenv("ARTEMIS_CACHE_DIR")
    end

    if candidate == nil or candidate == "" then
        local xdg_cache_home = os.getenv("XDG_CACHE_HOME")
        local home = os.getenv("HOME")

        if xdg_cache_home and xdg_cache_home:match("^/") then
            candidate = Path.join(xdg_cache_home, "artemis")
        elseif home and home:match("^/") then
            candidate = Path.join(Path.join(home, ".cache"), "artemis")
        else
            return nil, "Could not detect home directory."
        end
    end

    if type(candidate) ~= "string" or candidate == "" then
        return nil, "The Artemis cache directory must be a non-empty path string."
    end

    -- Expand the current user's home directory before resolving the path.
    if candidate == "~" or candidate:sub(1, 2) == "~/" then
        local home = os.getenv("HOME")
        if not home or not home:match("^/") then
            return nil, "Cannot expand the cache path because HOME is not an absolute path."
        end
        candidate = candidate == "~" and home or Path.join(home, candidate:sub(3))
    elseif candidate:sub(1, 1) == "~" then
        return nil, "Named-user home paths are not supported for the Artemis cache directory."
    elseif not Path.is_absolute(candidate) then
        return nil, "Could not detect home directory."
    end

    candidate = candidate:gsub("/+$", "")
    if candidate == "" then
        candidate = "/artemis"
    end

    local parent = Path.parent(candidate)
    local parent_created, parent_create_error = FileSystem.make_directory(parent)
    if not parent_created then
        return nil, string.format("Could not create Artemis cache parent directory: %s", parent_create_error)
    end

    local absolute_parent, parent_error = Path.absolute_directory(parent)
    if not absolute_parent then
        return nil, string.format("Could not resolve Artemis cache directory: %s", parent_error)
    end

    return Path.join(absolute_parent, Path.basename(candidate))
end

--- Compare numeric Lua version components instead of lexical string order.
--- @param left string
--- @param right string
--- @return boolean
local function version_less_than(left, right)
    local left_major, left_minor, left_patch = left:match("^(%d+)%.(%d+)%.(%d+)$")
    local right_major, right_minor, right_patch = right:match("^(%d+)%.(%d+)%.(%d+)$")

    left_major, left_minor, left_patch = tonumber(left_major), tonumber(left_minor), tonumber(left_patch)
    right_major, right_minor, right_patch = tonumber(right_major), tonumber(right_minor), tonumber(right_patch)

    if left_major ~= right_major then
        return left_major < right_major
    end
    if left_minor ~= right_minor then
        return left_minor < right_minor
    end
    return left_patch < right_patch
end

-----------------------------------------------------------------------------------------

----------------------------------- Manager Functions -----------------------------------

--- Create a runtime manager.
--- @param options? Artemis.RuntimeManagerOptions Runtime manager configuration.
--- @return Artemis.RuntimeManager? manager
--- @return string? error_message
function RuntimeManager.new(options)
    if options == nil then
        options = {}
    end
    if type(options) ~= "table" then
        return nil, "RuntimeManager options must be a table."
    end

    if options.cache_dir ~= nil and (type(options.cache_dir) ~= "string" or options.cache_dir == "") then
        return nil, "options.cache_dir must be a non-empty path string."
    end

    local cache_dir, cache_error = resolve_cache_dir(options.cache_dir)
    if not cache_dir then
        return nil, cache_error
    end

    local tar = options.tar or "tar"
    local make = options.make or "make"
    if type(tar) ~= "string" or tar == "" or type(make) ~= "string" or make == "" then
        return nil, "tar and make executable names must be non-empty strings."
    end

    local source_url = options.source_url or RuntimeManager.DEFAULT_SOURCE_URL
    if type(source_url) ~= "string" or not source_url:match("^https://") then
        return nil, "options.source_url must be an HTTPS URL."
    end

    local self = setmetatable({}, RuntimeManager)
    self.cache_dir = cache_dir
    self.downloads_dir = Path.join(cache_dir, "downloads/lua")
    self.runtimes_dir = Path.join(cache_dir, "runtimes/lua")
    self.build_dir = Path.join(cache_dir, "build")
    self.release_catalog = options.release_catalog or ReleaseCatalog

    if options.installer then
        self.installer = options.installer
    else
        local installer, installer_error = RuntimeInstaller.new({
            downloads_dir = self.downloads_dir,
            runtimes_dir = self.runtimes_dir,
            build_dir = self.build_dir,
            tar = tar,
            make = make,
            source_url = source_url,
            downloader = options.downloader,
            checksum = options.checksum,
        })
        if not installer then
            return nil, installer_error
        end
        self.installer = installer
    end

    return self
end

--- Resolve a version request into an exact release and its expected checksum.
--- An already installed series is reused; otherwise the bundled catalog is used.
--- @param requested_version string
--- @return string? version
--- @return string? checksum
--- @return string? error_message
function RuntimeManager:resolve_version(requested_version)
    if not requested_version then
        return nil, nil, "No version was requested."
    end

    local series, exact_version, parse_error = parse_requested_version(requested_version)
    if not series then
        return nil, nil, parse_error
    end

    if not exact_version then
        local installed_version, lookup_error = self:_find_installed_series_version(series)
        if lookup_error then
            return nil, nil, lookup_error
        end
        if installed_version then
            return installed_version
        end
    end

    return self.release_catalog:resolve_version(requested_version)
end

--- Install the Lua version explicitly requested.
--- The release catalog's series-selection behavior is preserved; for example,
--- the catalog currently resolves "5.4" to the exact base release "5.4.0".
--- @param requested_version string
--- @return boolean success
--- @return string? error_message
--- @return string? installed_version Exact installed version, when successful.
function RuntimeManager:install(requested_version)
    if not requested_version then
        return false, "No version was requested."
    end

    local series, exact_version, parse_error = parse_requested_version(requested_version)
    if not series then
        return false, parse_error
    end

    if exact_version and self:is_installed(exact_version) then
        return true, nil, exact_version
    end

    local version, expected_checksum, resolve_error = self:resolve_version(requested_version)
    if not version then
        return false, resolve_error or string.format("Could not resolve Lua version '%s'.", requested_version)
    end

    if self:is_installed(version) then
        if not exact_version then
            local mapping_saved, mapping_error = FileSystem.write_file(
                Path.join(self.cache_dir, "metadata/lua-series-" .. series .. ".txt"),
                version .. "\n"
            )
            if not mapping_saved then
                return false, mapping_error
            end
        end
        return true, nil, version
    end

    if not expected_checksum then
        return false, string.format("No checksum is available for Lua %s.", version)
    end

    local installed, install_error = self.installer:install(version, expected_checksum)
    if not installed then
        return false, install_error
    end

    if not exact_version then
        local mapping_saved, mapping_error = FileSystem.write_file(
            Path.join(self.cache_dir, "metadata/lua-series-" .. series .. ".txt"),
            version .. "\n"
        )
        if not mapping_saved then
            return false, string.format(
                "Lua %s was installed, but its series mapping could not be saved: %s",
                version,
                mapping_error
            )
        end
    end

    return true, nil, version
end

--- Check whether an exact release or a cached release series is installed.
--- This check is offline and never downloads or builds anything.
--- @param requested_version string
--- @return boolean? installed
--- @return string? error_message
function RuntimeManager:is_installed(requested_version)
    if not requested_version then
        return false, "No version was requested."
    end

    local series, exact_version, parse_error = parse_requested_version(requested_version)
    if not series then
        return nil, parse_error
    end

    local version = exact_version
    if not version then
        local lookup_error
        version, lookup_error = self:_find_installed_series_version(series)
        if lookup_error then
            return nil, lookup_error
        end
    end

    if not version then
        return false
    end

    return FileSystem.executable_exists(Path.join(self.runtimes_dir, version .. "/bin/lua"))
end

--- Compatibility alias for the previous installed-runtime query name.
--- @param requested_version string
--- @return boolean? installed
--- @return string? error_message
function RuntimeManager:verify_existent(requested_version)
    return self:is_installed(requested_version)
end

--- Return the exact cached installation path for a requested release.
--- @param requested_version string
--- @return string? installation_path
--- @return string? error_message
function RuntimeManager:get_install_path(requested_version)
    if not requested_version then
        return nil, "No version was requested."
    end

    local series, exact_version, parse_error = parse_requested_version(requested_version)
    if not series then
        return nil, parse_error
    end

    local version = exact_version
    if not version then
        local lookup_error
        version, lookup_error = self:_find_installed_series_version(series)
        if lookup_error then
            return nil, lookup_error
        end
    end

    if not version then
        return nil, string.format("Lua %s has not been resolved yet. Call install() first.", requested_version)
    end

    local path = Path.join(self.runtimes_dir, version)
    if not FileSystem.executable_exists(Path.join(path, "bin/lua")) then
        return nil, string.format("Lua %s is not installed in the Artemis cache.", version)
    end

    return path
end

--- Return the Lua interpreter executable for a requested release.
--- @param requested_version string
--- @return string? executable_path
--- @return string? error_message
function RuntimeManager:get_executable(requested_version)
    if not requested_version then
        return nil, "A Lua version must be specified."
    end

    local installation_path, path_error = self:get_install_path(requested_version)
    if not installation_path then
        return nil, path_error
    end

    return Path.join(installation_path, "bin/lua")
end

--- List exact Lua releases installed in the shared Artemis cache.
--- @return string[] versions
--- @return string? error_message
function RuntimeManager:list_installed()
    if not FileSystem.directory_exists(self.runtimes_dir) then
        return {}
    end

    local directories, list_error = FileSystem.list_directories(self.runtimes_dir)
    if not directories then
        return {}, list_error
    end

    local versions = {}
    for _, path in ipairs(directories) do
        local version = Path.basename(path)
        if version and version:match("^%d+%.%d+%.%d+$")
            and FileSystem.executable_exists(Path.join(path, "bin/lua")) then
            versions[#versions + 1] = version
        end
    end

    table.sort(versions, version_less_than)
    return versions
end

--- Compatibility alias for callers that use the shorter list() name.
--- @return string[] versions
--- @return string? error_message
function RuntimeManager:list()
    return self:list_installed()
end

--- Find the selected locally installed patch release for a major.minor series.
--- A valid cached mapping is preferred; otherwise the highest installed patch is used.
--- @param series string Major.minor version, such as "5.4".
--- @return string? version
--- @return string? error_message
function RuntimeManager:_find_installed_series_version(series)
    local mapping = FileSystem.read_file(Path.join(self.cache_dir, "metadata/lua-series-" .. series .. ".txt"))
    local mapped_version = mapping and mapping:match("^%s*([%d%.]+)") or nil
    if mapped_version and mapped_version:match("^(%d+%.%d+)%.%d+$") == series
        and FileSystem.executable_exists(Path.join(self.runtimes_dir, mapped_version .. "/bin/lua")) then
        return mapped_version
    end

    local installed_versions, list_error = self:list_installed()
    if not installed_versions then
        return nil, list_error
    end

    local selected_version
    --- @type integer?
    local highest_patch = -1
    for _, installed_version in ipairs(installed_versions) do
        local installed_series, patch = installed_version:match("^(%d+%.%d+)%.(%d+)$")
        if installed_series == series and tonumber(patch) > highest_patch then
            selected_version = installed_version
            highest_patch = tonumber(patch)
        end
    end

    return selected_version
end

--- Remove an exact Lua runtime or the selected release of a series from the shared cache.
--- This affects every project that reuses this cached installation.
--- @param requested_version string Exact version or cached series such as "5.4".
--- @return boolean success
--- @return string? error_message
function RuntimeManager:uninstall(requested_version)
    if not requested_version then
        return false, "A Lua version must be specified."
    end

    local series, exact_version, parse_error = parse_requested_version(requested_version)
    if not series then
        return false, parse_error
    end

    local version = exact_version
    if not version then
        local lookup_error
        version, lookup_error = self:_find_installed_series_version(series)
        if lookup_error then
            return false, lookup_error
        end
    end

    if not version then
        return false, string.format("No cached Lua installation was found for '%s'.", requested_version)
    end

    local installation_path = Path.join(self.runtimes_dir, version)
    if not FileSystem.directory_exists(installation_path) then
        return false, string.format("Lua %s is not installed.", version)
    end

    local removed, remove_error = FileSystem.remove(installation_path)
    if not removed then
        return false, string.format("Could not remove Lua %s: %s", version, remove_error)
    end

    local series_mapping_path = Path.join(self.cache_dir, "metadata/lua-series-" .. series .. ".txt")
    local cached_series_version = FileSystem.read_file(series_mapping_path)
    local mapped_version = cached_series_version and cached_series_version:match("^%s*([%d%.]+)") or nil
    if not exact_version or mapped_version == version then
        local mapping_removed, mapping_error = FileSystem.remove(series_mapping_path)
        if not mapping_removed then
            return false, string.format("Lua %s was removed, but its series mapping could not be removed: %s", version,
                mapping_error)
        end
    end

    return true
end

-----------------------------------------------------------------------------------------

return RuntimeManager
