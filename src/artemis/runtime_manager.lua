--- Manage project-selected Lua runtimes and reuse installations from a shared cache.
---
--- Lua source archives are downloaded from the official Lua website, verified
--- against its published SHA-256 checksum, compiled, and installed into the
--- Artemis cache. Projects reference the cached interpreter instead of keeping
--- a separate copy of every Lua installation.
---
--- HTTP and SHA-256 work use Lua libraries. Building Lua source still requires
--- tar, make, and a C compiler available on PATH. LuaJIT is intentionally not
--- supported by this source-build backend yet.
---
--- @module 'artemis.runtime_manager'

local Path = require("artemis.utils.path")
local FileSystem = require("artemis.utils.filesystem")
local Process = require("artemis.utils.process")
local Downloader = require("artemis.utils.downloader")
local Checksum = require("artemis.utils.checksum")

--- @class Artemis.RuntimeManagerOptions
--- @field cache_dir?         string  Shared Artemis cache directory. Defaults to $XDG_CACHE_HOME/artemis or ~/.cache/artemis.
--- @field tar?               string  tar executable. Defaults to "tar".
--- @field make?              string  make executable. Defaults to "make".
--- @field source_url?        string  Official Lua source index URL.
--- @field downloader?        table   HTTP client override, primarily for tests.
--- @field checksum?          table   Checksum provider override, primarily for tests.

--- @class Artemis.LuaRelease
--- @field version      string  Exact Lua release version, such as "5.4.9".
--- @field checksum     string  Published SHA-256 checksum of the source archive.
--- @field archive_url  string  Official source archive URL.

--- @class Artemis.RuntimeManager
--- @field cache_dir             string            Shared Artemis cache directory.
--- @field downloads_dir         string            Directory containing downloaded Lua source archives.
--- @field runtimes_dir          string            Directory containing compiled Lua installations.
--- @field build_dir             string            Temporary source/build directory.
--- @field tar                   string            tar executable.
--- @field make                  string            make executable.
--- @field downloader            table             HTTP downloader implementation.
--- @field checksum              table             Checksum provider.
--- @field source_url            string            Official Lua source index URL.
local RuntimeManager = {}
RuntimeManager.__index = RuntimeManager

--- @type string
RuntimeManager.DEFAULT_SOURCE_URL = "https://www.lua.org/ftp/"

------------------------------------ Local Functions ------------------------------------

--- Resolve the shared Artemis cache directory.
--- @param requested_cache_dir?  string
--- @return string?  cache_dir
--- @return string?  error_message
local function resolve_cache_dir(requested_cache_dir)
    local candidate = requested_cache_dir or os.getenv("ARTEMIS_CACHE_DIR")

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

    -- Expand an explicitly supplied home-relative path before resolving other
    -- relative paths against the project root. Only the current user's home
    -- directory is supported; named-user expansion is shell-specific.
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

    local parent = candidate:match("^(.*)/[^/]+$")
    if not parent or parent == "" then
        parent = "/"
    end
    local parent_created, parent_create_error = FileSystem.make_directory(parent)
    if not parent_created then
        return nil, string.format("Could not create Artemis cache parent directory: %s", parent_create_error)
    end

    local absolute_parent, parent_error = Path.absolute_directory(parent)
    if not absolute_parent then
        return nil, string.format("Could not resolve Artemis cache directory: %s", parent_error)
    end

    local basename = candidate:match("([^/]+)$") or "artemis"
    return Path.join(absolute_parent, basename)
end

--- Parse a requested Lua version.
--- A series such as "5.4" floats to the latest patch release; an exact version
--- such as "5.4.9" remains pinned to that release.
--- @param requested_version  string
--- @return string?  series
--- @return string?  exact_version
--- @return string?  error_message
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

--- Return the checksum token in an HTML table row.
--- @param row  string
--- @return string?  checksum
local function checksum_from_row(row)
    for token in row:gmatch("([%da-fA-F]+)") do
        if #token == 64 then
            return token:lower()
        end
    end

    return nil
end

--- Find a release entry and its SHA-256 checksum in the official download index.
--- The Lua download page is HTML, but this parser deliberately does not depend
--- on lowercase table tags or on the filename appearing only once per row.
--- @param html     string
--- @param version  string
--- @return string?  checksum
local function find_release_checksum(html, version)
    local filename = "lua-" .. version .. ".tar.gz"
    local lower_html = html:lower()
    local search_position = 1

    while true do
        local filename_start, filename_end = lower_html:find(filename, search_position, true)
        if not filename_start then
            return nil
        end

        -- Include the complete table row when one is present. Some pages or
        -- mirrors may omit table rows, so fall back to the next release entry.
        local row_start = filename_start
        for position in lower_html:gmatch("()<tr") do
            if position > filename_start then
                break
            end
            ---@diagnostic disable-next-line: cast-local-type
            row_start = position
        end

        local row_end = lower_html:find("</tr>", filename_end, true)
        local next_filename_start = lower_html:find(
            "lua%-[%d]+%.%d+%.%d+%.tar%.gz",
            filename_end + 1
        )

        if next_filename_start and (not row_end or next_filename_start < row_end) then
            row_end = next_filename_start - 1
        end

        if not row_end then
            row_end = math.min(#html, filename_end + 2048)
        end

        ---@diagnostic disable-next-line: param-type-mismatch
        local row = html:sub(row_start, row_end)
        local checksum = checksum_from_row(row)
        if checksum then
            return checksum
        end

        -- An anchor may contain the filename both in href and link text. Try
        -- the next occurrence before giving up on this release entry.
        search_position = filename_end + 1
    end
end

-----------------------------------------------------------------------------------------



----------------------------------- Manager Functions -----------------------------------

--- Fetch the official Lua download index.
--- @return string?  html
--- @return string?  error_message
function RuntimeManager:_fetch_release_index()
    return self.downloader.get(self.source_url .. "index.html", { attempts = 3 })
end

--- Retrieve the official checksum for an exact Lua release.
--- @param version  string
--- @return string?  checksum
--- @return string?  error_message
function RuntimeManager:_get_release_checksum(version)
    local checksum_path = Path.join(self.downloads_dir, "lua-" .. version .. ".sha256")
    local cached_checksum = FileSystem.read_file(checksum_path)

    if cached_checksum then
        local checksum = cached_checksum:match("^%s*([%da-fA-F]+)")
        if checksum and #checksum == 64 then
            return checksum:lower()
        end
    end

    local html, index_error = self:_fetch_release_index()
    if not html then
        return nil,
            string.format("Could not retrieve the official Lua release index to verify Lua %s: %s", version, index_error)
    end

    local checksum = find_release_checksum(html, version)
    if not checksum then
        return nil,
            string.format(
                "Lua %s was not found in the official download index, or its SHA-256 checksum could not be parsed.",
                version)
    end

    local saved, save_error = FileSystem.write_file(checksum_path, checksum .. "\n")
    if not saved then
        return nil, save_error
    end

    return checksum
end

--- Resolve a series (for example, 5.4) to the newest official patch release.
--- @param series  string
--- @return string?  version
--- @return string?  checksum
--- @return string?  error_message
function RuntimeManager:_resolve_latest_series(series)
    local mapping_path = Path.join(self.cache_dir, "metadata/lua-series-" .. series .. ".txt")
    local mapped_version = FileSystem.read_file(mapping_path)
    if mapped_version then
        mapped_version = mapped_version:match("^%s*([%d%.]+)")
        if mapped_version then
            local mapped_series = mapped_version:match("^(%d+%.%d+)")
            if mapped_series == series then
                -- A completed installation needs no network lookup or checksum.
                if self:is_installed(mapped_version) then
                    local checksum = FileSystem.read_file(Path.join(self.downloads_dir,
                        "lua-" .. mapped_version .. ".sha256"))
                    checksum = checksum and checksum:match("^%s*([%da-fA-F]+)") or nil
                    return mapped_version, checksum
                end

                local checksum, checksum_error = self:_get_release_checksum(mapped_version)
                if checksum then
                    return mapped_version, checksum
                end

                if checksum_error then
                    return nil, nil, checksum_error
                end
            end
        end
    end

    local html, index_error = self:_fetch_release_index()
    if not html then
        return nil, nil,
            string.format("Could not resolve Lua %s without the official release index: %s", series, index_error)
    end

    local latest_version
    --- @type number?
    local latest_patch = -1
    local latest_checksum
    local seen_versions = {}

    -- Search for release filenames across the whole document instead of
    -- depending on a particular <tr> layout. The official index may change its
    -- surrounding HTML without changing the release filenames/checksums.
    for version in html:lower():gmatch("lua%-(%d+%.%d+%.%d+)%.tar%.gz") do
        if not seen_versions[version] then
            seen_versions[version] = true
            local row_series, patch = version:match("^(%d+%.%d+)%.(%d+)$")
            patch = tonumber(patch)

            if row_series == series and patch and patch > latest_patch then
                latest_version = version
                latest_patch = patch
                latest_checksum = find_release_checksum(html, version)
            end
        end
    end

    if not latest_version then
        return nil, nil, string.format(
            "No released Lua versions matching series %s were found at %s. "
            .. "The download index was retrieved, but no matching release filename was recognized.",
            series,
            self.source_url
        )
    end

    if not latest_checksum then
        return nil, nil, string.format(
            "Lua %s appears in the official download index, but Artemis could not parse its SHA-256 checksum from %s.",
            latest_version,
            self.source_url
        )
    end

    return latest_version, latest_checksum
end

--- Resolve a requested series or exact release to an exact version and checksum.
--- @param requested_version  string
--- @return string?  version
--- @return string?  checksum
--- @return string?  error_message
function RuntimeManager:resolve_version(requested_version)
    if not requested_version then
        return nil, nil, "No version was requested."
    end

    local series, exact_version, parse_error = parse_requested_version(requested_version)
    if not series then
        return nil, nil, parse_error
    end

    if exact_version then
        local checksum, checksum_error = self:_get_release_checksum(exact_version)
        if not checksum then
            return nil, nil, checksum_error
        end

        return exact_version, checksum
    end

    return self:_resolve_latest_series(series)
end

--- Verify a cached archive with the shared OpenSSL-backed checksum module.
--- @param archive_path  string
--- @return string?  actual_checksum
--- @return string?  error_message
function RuntimeManager:_sha256(archive_path)
    return self.checksum.sha256_file(archive_path)
end

--- Download a source archive once, verify it, and retain it in the shared cache.
--- @param version            string
--- @param expected_checksum  string
--- @return string?  archive_path
--- @return string?  error_message
function RuntimeManager:_ensure_archive(version, expected_checksum)
    local archive_name = "lua-" .. version .. ".tar.gz"
    local archive_path = Path.join(self.downloads_dir, archive_name)

    if FileSystem.file_exists(archive_path) then
        local actual_checksum, checksum_error = self:_sha256(archive_path)
        if not actual_checksum then
            return nil, checksum_error
        end

        if actual_checksum == expected_checksum then
            return archive_path
        end

        local removed, remove_error = FileSystem.remove(archive_path)
        if not removed then
            return nil,
                string.format("Cached Lua archive is invalid and could not be removed: %s", remove_error)
        end
    end

    local temporary_path = archive_path .. ".part"
    FileSystem.remove(temporary_path)

    local downloaded, download_error = self.downloader.download(
        self.source_url .. archive_name,
        temporary_path,
        { attempts = 3 }
    )
    if not downloaded then
        FileSystem.remove(temporary_path)
        return nil, string.format("Could not download Lua %s: %s", version, download_error)
    end

    local actual_checksum, checksum_error = self:_sha256(temporary_path)
    if not actual_checksum then
        FileSystem.remove(temporary_path)
        return nil, checksum_error
    end

    if actual_checksum ~= expected_checksum then
        FileSystem.remove(temporary_path)
        return nil, string.format(
            "SHA-256 mismatch for Lua %s. Expected %s, received %s.",
            version,
            expected_checksum,
            actual_checksum
        )
    end

    local moved, move_error = FileSystem.rename(temporary_path, archive_path)
    if not moved then
        FileSystem.remove(temporary_path)
        return nil, string.format("Could not move the verified archive into the cache: %s", move_error)
    end

    local checksum_saved, save_error = FileSystem.write_file(
        Path.join(self.downloads_dir, "lua-" .. version .. ".sha256"),
        expected_checksum .. "\n"
    )
    if not checksum_saved then
        return nil, save_error
    end

    return archive_path
end

--- Build an exact Lua release and atomically place it in the shared runtime cache.
--- @param version       string
--- @param archive_path  string
--- @return boolean  success
--- @return string?  error_message
function RuntimeManager:_build_and_install(version, archive_path)
    local build_directory = Path.join(self.build_dir, "lua-" .. version)
    local source_directory = Path.join(build_directory, "lua-" .. version)
    local staging_directory = Path.join(build_directory, "staging")
    local final_directory = Path.join(self.runtimes_dir, version)
    local executable = Path.join(staging_directory, "bin/lua")

    local cleaned, clean_error = FileSystem.remove(build_directory)
    if not cleaned then
        return false, string.format("Could not prepare the Lua build directory: %s", clean_error)
    end

    local made, make_error = FileSystem.make_directory(build_directory)
    if not made then
        return false, make_error
    end

    local extracted, extract_error = Process.execute(
        Process.shell_quote(self.tar) .. " -xzf " .. Process.shell_quote(archive_path)
        .. " -C " .. Process.shell_quote(build_directory)
    )
    if not extracted then
        return false, string.format("Could not extract Lua %s: %s", version, extract_error)
    end

    if not FileSystem.directory_exists(source_directory) then
        return false, string.format("The Lua %s archive did not contain the expected source directory.", version)
    end

    local built, build_error = Process.execute_in(source_directory, Process.shell_quote(self.make) .. " all test")
    if not built then
        return false, string.format("Could not build or test Lua %s: %s", version, build_error)
    end

    local installed, install_error = Process.execute_in(
        source_directory,
        Process.shell_quote(self.make) .. " install INSTALL_TOP=" .. Process.shell_quote(staging_directory)
    )
    if not installed then
        return false, string.format("Could not stage the Lua %s installation: %s", version, install_error)
    end

    if not FileSystem.executable_exists(executable) then
        return false, string.format("Lua %s built successfully, but its staged interpreter was not found.", version)
    end

    local version_output, version_error = Process.capture(Process.shell_quote(executable) .. " -v")
    if not version_output then
        return false, string.format("Could not execute the newly built Lua interpreter: %s", version_error)
    end

    if not version_output:match("Lua " .. version:gsub("%.", "%%.") .. "[%s]") then
        return false, string.format(
            "The built interpreter reported an unexpected version: %s",
            version_output:gsub("%s+$", "")
        )
    end

    local parent_created, parent_error = FileSystem.make_directory(self.runtimes_dir)
    if not parent_created then
        return false, parent_error
    end

    -- Keep a previously cached directory until the new build has passed all checks.
    local backup_directory = final_directory .. ".old"
    FileSystem.remove(backup_directory)

    if FileSystem.directory_exists(final_directory) then
        local backed_up, backup_error = FileSystem.rename(final_directory, backup_directory)
        if not backed_up then
            return false, string.format("Could not back up the previous Lua runtime: %s", backup_error)
        end
    end

    local promoted, promote_error = FileSystem.rename(staging_directory, final_directory)

    if not promoted then
        if FileSystem.directory_exists(backup_directory) then
            FileSystem.rename(backup_directory, final_directory)
        end

        return false, string.format("Could not activate the Lua runtime: %s", promote_error)
    end

    FileSystem.remove(backup_directory)
    FileSystem.remove(build_directory)

    return true
end

--- Create a runtime manager.
--- @param options?      Artemis.RuntimeManagerOptions  Runtime manager configuration.
--- @return Artemis.RuntimeManager?  manager
--- @return string?                  error_message
function RuntimeManager.new(options)
    options = options or {}

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
    self.tar = tar
    self.make = make
    self.source_url = source_url
    self.downloader = options.downloader or Downloader
    self.checksum = options.checksum or Checksum

    return self
end

--- Install the Lua version explicitly requested.
--- A major.minor request selects the latest official patch release in that series.
--- The resulting installation is shared by every Artemis project using this cache.
--- @param requested_version  string
--- @return boolean  success
--- @return string?  error_message
--- @return string?  installed_version Exact installed version, when successful.
function RuntimeManager:install(requested_version)
    if not requested_version then
        return false, "No version was requested"
    end

    local series, exact_version, parse_error = parse_requested_version(requested_version)
    if not series then
        return false, parse_error
    end

    if exact_version and self:is_installed(exact_version) then
        return true, nil, exact_version
    end

    local version, checksum, resolve_error = self:resolve_version(requested_version)
    if not version then
        return false, resolve_error
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

    local dirs_created, dirs_error = FileSystem.make_directory(self.downloads_dir)
    if dirs_created then
        dirs_created, dirs_error = FileSystem.make_directory(self.runtimes_dir)
    end
    if dirs_created then
        dirs_created, dirs_error = FileSystem.make_directory(self.build_dir)
    end
    if not dirs_created then
        return false, string.format("Could not create Artemis cache directories: %s", dirs_error)
    end

    if not checksum then
        checksum, resolve_error = self:_get_release_checksum(version)
        if not checksum then
            return false, resolve_error
        end
    end

    local archive_path, archive_error = self:_ensure_archive(version, checksum)
    if not archive_path then
        return false, archive_error
    end

    local installed, install_error = self:_build_and_install(version, archive_path)
    if not installed then
        return false, install_error
    end

    if not exact_version then
        local mapping_saved, mapping_error = FileSystem.write_file(
            Path.join(self.cache_dir, "metadata/lua-series-" .. series .. ".txt"),
            version .. "\n"
        )
        if not mapping_saved then
            return false,
                string.format("Lua %s was installed, but its series mapping could not be saved: %s", version,
                    mapping_error)
        end
    end

    return true, nil, version
end

--- Check whether an exact release or a cached release series is installed.
--- This check is offline and never downloads or builds anything.
--- @param requested_version  string
--- @return boolean?  installed
--- @return string?   error_message
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

--- Return the exact cached installation path for a requested release.
--- @param requested_version  string
--- @return string?  installation_path
--- @return string?  error_message
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
--- @param requested_version  string
--- @return string?  executable_path
--- @return string?  error_message
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
--- @return string[]  versions
--- @return string?   error_message
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

    table.sort(versions)
    return versions
end

--- Find the newest locally installed patch release for a major.minor series.
--- The cached series mapping is preferred when it points to an installed runtime.
--- @param series  string  Major.minor version, such as "5.4".
--- @return string?  version
--- @return string?  error_message
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
    --- @type number?
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

--- Remove an exact Lua runtime from the shared cache.
--- This affects every project that reuses this cached installation.
--- @param requested_version  string  Exact version or cached series such as "5.4".
--- @return boolean  success
--- @return string?  error_message
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
    if not exact_version or (cached_series_version and cached_series_version:match("^%s*([%d%.]+)") == version) then
        FileSystem.remove(series_mapping_path)
    end

    return true
end

--- Alias for list_installed(), using concise list terminology.
--- @return string[]  versions
--- @return string?   error_message
function RuntimeManager:list()
    return self:list_installed()
end

--- Alias for is_installed(), using the earlier API name from the initial sketch.
--- @param requested_version?  string
--- @return boolean?  installed
--- @return string?   error_message
function RuntimeManager:verify_existent(requested_version)
    return self:is_installed(requested_version)
end

return RuntimeManager
