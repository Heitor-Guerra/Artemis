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

RuntimeManager.VERSIONS_CHECKSUM = {
    ["5.5.1"] = "1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce",
    ["5.5.0"] = "57ccc32bbbd005cab75bcc52444052535af691789dba2b9016d5c50640d68b3d",

    ["5.4.9"] = "2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6",
    ["5.4.8"] = "4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae",
    ["5.4.7"] = "9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30",
    ["5.4.6"] = "7d5ea1b9cb6aa0b59ca3dde1c6adcb57ef83a1ba8e5432c0ecd06bf439b3ad88",
    ["5.4.5"] = "59df426a3d50ea535a460a452315c4c0d4e1121ba72ff0bdde58c2ef31d6f444",
    ["5.4.4"] = "164c7849653b80ae67bec4b7473b884bf5cc8d2dca05653475ec2ed27b9ebf61",
    ["5.4.3"] = "f8612276169e3bfcbcfb8f226195bfc6e466fe13042f1076cbde92b7ec96bbfb",
    ["5.4.2"] = "11570d97e9d7303c0a59567ed1ac7c648340cd0db10d5fd594c09223ef2f524f",
    ["5.4.1"] = "4ba786c3705eb9db6567af29c91a01b81f1c0ac3124fdbf6cd94bdd9e53cca7d",
    ["5.4.0"] = "eac0836eb7219e421a96b7ee3692b93f0629e4cdb0c788432e3d10ce9ed47e28",

    ["5.3.6"] = "fc5fd69bb8736323f026672b1b7235da613d7177e72558893a0bdcd320466d60",
    ["5.3.5"] = "0c2eed3f960446e1a3e4b9a1ca2f3ff893b6ce41942cf54d5dd59ab4b3b058ac",
    ["5.3.4"] = "f681aa518233bc407e23acf0f5887c884f17436f000d453b2491a9f11a52400c",
    ["5.3.3"] = "5113c06884f7de453ce57702abaac1d618307f33f6789fa870e87a59d772aca2",
    ["5.3.2"] = "c740c7bb23a936944e1cc63b7c3c5351a8976d7867c5252c8854f7b2af9da68f",
    ["5.3.1"] = "072767aad6cc2e62044a66e8562f51770d941e972dc1e4068ba719cd8bffac17",
    ["5.3.0"] = "ae4a5eb2d660515eb191bfe3e061f2b8ffe94dce73d32cfd0de090ddcc0ddb01",

    ["5.2.4"] = "b9e2e4aad6789b3b63a056d442f7b39f0ecfca3ae0f1fc0ae4e9614401b69f4b",
    ["5.2.3"] = "13c2fb97961381f7d06d5b5cea55b743c163800896fd5c5e2356201d3619002d",
    ["5.2.2"] = "3fd67de3f5ed133bf312906082fa524545c6b9e1b952e8215ffbd27113f49f00",
    ["5.2.1"] = "64304da87976133196f9e4c15250b70f444467b6ed80d7cfd7b3b982b5177be5",
    ["5.2.0"] = "cabe379465aa8e388988073d59b69e76ba0025429d2c1da80821a252cdf6be0d",

    ["5.1.5"] = "2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333",
    ["5.1.4"] = "b038e225eaf2a5b57c9bcc35cd13aa8c6c8288ef493d52970c9545074098af3a",
    ["5.1.3"] = "6b5df2edaa5e02bf1a2d85e1442b2e329493b30b0c0780f77199d24f087d296d",
    ["5.1.2"] = "5cf098c6fe68d3d2d9221904f1017ff0286e4a9cc166a1452a456df9b88b3d9e",
    ["5.1.1"] = "c5daeed0a75d8e4dd2328b7c7a69888247868154acbda69110e97d4a6e17d1f0",
    ["5.1"] = "7f5bb9061eb3b9ba1e406a5aa68001a66cb82bac95748839dc02dd10048472c1",

    ["5.0.3"] = "1193a61b0e08acaa6eee0eecf29709179ee49c71baebc59b682a25c3b5a45671",
    ["5.0.2"] = "a6c85d85f912e1c321723084389d63dee7660b81b8292452b190ea7190dd73bc",
    ["5.0.1"] = "7a09d0e70dcaff7feae97cf9c154da05b1e5b92eaea2df7150b54bcaf8f3b9c6",
    ["5.0"] = "4a23b3bcb812538c653033cd39fe9c9bd8030286b945c56eff280d452e4e244e",

    ["4.0.1"] = "df746e149cf6939e90009d2e540eee918d585b4d1bc6d68b19316a050d484d2a",
    ["4.0"] = "b476abc737bf82781cb215e59a259bf23adbdc82425907b51f37ba29c0e71337",

    ["3.2.2"] = "4e04059f43acdcde5f7fd491c731df9279dac87d288a08c6eaeb31760c9876e0",
    ["3.2.1"] = "00d156f5b0c99bf46ed2fc2471b2a4bc5762aee83a809ab87bd7ec9ccc6220ea",
    ["3.2"] = "bf8beabd41e65cbf8cb41c688eca0588fff81e1e5f67cb42bd370e1ecc585c33",

    ["3.1"] = "797ceabe28df53ce6dd6bfb4397d6e0b2e349b3bd0a1883c9c8ae0212d8cd7ed",
    ["3.0"] = "a3ae0fb0ffc6b365d187fea0d121772fc2a8810853b14b7e48ed31eae8494215",

    ["2.5"] = "8ba8cc089b6ee7b5ed7fe9e0764756838943a1e52dde8bbfa70b758556056cd5",
    ["2.4"] = "38ee28cd5ec5c0b75f31d65c12f587f192174c8b7fcca3decd08cdb35af282e3",
    ["2.2"] = "a13cc27035b8d16bd9d29f5a1eb4403476deecd149c1d3979ad9d2ad015994f3",
    ["2.1"] = "d65ee99f8e63d12fa952425671854add39c1233e4a9c6669ec552b16279df664",

    ["1.1"] = "e44506793fee609202d7f42e529afbc3c9a541e0fc715b3834d758f0ae41c38f",
    ["1.0"] = "d8ee432490a4679a4edb0abbef2d3b7b0f1fc29a39398988c4bb5eeb8d2180a6",
}

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
--- such as "5.4.0" remains pinned to that release.
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

-----------------------------------------------------------------------------------------



----------------------------------- Manager Functions -----------------------------------

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

    if not exact_version and not self.VERSIONS_CHECKSUM[series] then
        exact_version = series .. ".0"
    elseif not exact_version and self.VERSIONS_CHECKSUM[series] then
        exact_version = series
    end

    if not self.VERSIONS_CHECKSUM[exact_version] then
        return nil, nil, "Could not resolve the requested_version."
    end

    return exact_version, self.VERSIONS_CHECKSUM[exact_version]
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
        local actual_checksum, checksum_error = self.checksum.sha256_file(archive_path)
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

    local actual_checksum, checksum_error = self.checksum.sha256_file(temporary_path)
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
    if not version or not checksum then
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

-----------------------------------------------------------------------------------------


return RuntimeManager
