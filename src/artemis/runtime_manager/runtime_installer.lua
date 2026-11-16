--- Download, verify, build, and install an exact Lua source release.
--- @module 'artemis.runtime_manager.runtime_installer'

local Path = require("artemis.utils.path")
local FileSystem = require("artemis.utils.filesystem")
local Process = require("artemis.utils.process")
local Downloader = require("artemis.utils.downloader")
local Checksum = require("artemis.utils.checksum")

--- @class Artemis.RuntimeInstallerOptions
--- @field downloads_dir string
--- @field runtimes_dir string
--- @field build_dir string
--- @field tar? string
--- @field make? string
--- @field source_url? string
--- @field downloader? table
--- @field checksum? table

--- @class Artemis.RuntimeInstaller
--- @field downloads_dir string
--- @field runtimes_dir string
--- @field build_dir string
--- @field tar string
--- @field make string
--- @field source_url string
--- @field downloader table
--- @field checksum table
local RuntimeInstaller = {}
RuntimeInstaller.__index = RuntimeInstaller

RuntimeInstaller.DEFAULT_SOURCE_URL = "https://www.lua.org/ftp/"

--- Create an installer for the supplied cache locations and tools.
--- @param options Artemis.RuntimeInstallerOptions
--- @return Artemis.RuntimeInstaller? installer
--- @return string? error_message
function RuntimeInstaller.new(options)
    if type(options) ~= "table" then
        return nil, "RuntimeInstaller options must be a table."
    end

    for _, field in ipairs({ "downloads_dir", "runtimes_dir", "build_dir" }) do
        if type(options[field]) ~= "string" or options[field] == "" then
            return nil, string.format("options.%s must be a non-empty path string.", field)
        end
    end

    local tar = options.tar or "tar"
    local make = options.make or "make"
    if type(tar) ~= "string" or tar == "" or type(make) ~= "string" or make == "" then
        return nil, "tar and make executable names must be non-empty strings."
    end

    local source_url = options.source_url or RuntimeInstaller.DEFAULT_SOURCE_URL
    if type(source_url) ~= "string" or not source_url:match("^https://") then
        return nil, "options.source_url must be an HTTPS URL."
    end
    if source_url:sub(-1) ~= "/" then
        source_url = source_url .. "/"
    end

    local self = setmetatable({}, RuntimeInstaller)
    self.downloads_dir = options.downloads_dir
    self.runtimes_dir = options.runtimes_dir
    self.build_dir = options.build_dir
    self.tar = tar
    self.make = make
    self.source_url = source_url
    self.downloader = options.downloader or Downloader
    self.checksum = options.checksum or Checksum

    return self
end

--- Download a source archive once, verify it, and retain it in the shared cache.
--- @param version string
--- @param expected_checksum string
--- @return string? archive_path
--- @return string? error_message
function RuntimeInstaller:_ensure_archive(version, expected_checksum)
    expected_checksum = expected_checksum:lower()
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
            return nil, string.format(
                "Cached Lua archive is invalid and could not be removed: %s",
                remove_error
            )
        end
    end

    local temporary_path = archive_path .. ".part"
    local cleaned, clean_error = FileSystem.remove(temporary_path)
    if not cleaned then
        return nil, string.format("Could not clear the temporary archive: %s", clean_error)
    end

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
--- @param version string
--- @param archive_path string
--- @return boolean success
--- @return string? error_message
function RuntimeInstaller:_build_and_install(version, archive_path)
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
        return false, string.format(
            "The Lua %s archive did not contain the expected source directory.",
            version
        )
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
        return false, string.format(
            "Lua %s built successfully, but its staged interpreter was not found.",
            version
        )
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
    local backup_removed, backup_remove_error = FileSystem.remove(backup_directory)
    if not backup_removed then
        return false, string.format("Could not clear the previous runtime backup: %s", backup_remove_error)
    end

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

--- Install an exact Lua release using its expected official checksum.
--- @param version string
--- @param expected_checksum string
--- @return boolean success
--- @return string? error_message
function RuntimeInstaller:install(version, expected_checksum)
    if type(version) ~= "string" or not version:match("^%d+%.%d+%.%d+$") then
        return false, "RuntimeInstaller requires an exact Lua version."
    end
    if type(expected_checksum) ~= "string" or not expected_checksum:match("^[%da-fA-F]+$")
        or #expected_checksum ~= 64 then
        return false, "RuntimeInstaller requires a valid SHA-256 checksum."
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

    local archive_path, archive_error = self:_ensure_archive(version, expected_checksum:lower())
    if not archive_path then
        return false, archive_error
    end

    return self:_build_and_install(version, archive_path)
end

return RuntimeInstaller
