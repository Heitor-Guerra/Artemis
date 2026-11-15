--- Command-line interface for Artemis.
---
--- The CLI is intentionally thin: project operations are delegated to
--- Artemis.Project, while argparse owns tokenization, options, subcommands,
--- and generated help text.
--- @module 'artemis.cli'

local argparse = require("argparse")
local Manifest = require("artemis.manifest")
local Lockfile = require("artemis.lockfile")
local Project = require("artemis.project")
local lfs = require("lfs")
local RuntimeManager = require("artemis.runtime_manager")

--- @alias Artemis.CLIWriter fun(message: string)
--- @alias Artemis.CLIProjectFactory fun(root: string, options: Artemis.ProjectOptions): Artemis.Project?, string?
--- @alias Artemis.CLIManifestFactory fun(data: Artemis.ManifestData, path: string): Artemis.Manifest?, string?

--- @class Artemis.CLIServices
--- @field stdout?           Artemis.CLIWriter          Output writer, primarily used by tests.
--- @field stderr?           Artemis.CLIWriter          Error writer, primarily used by tests.
--- @field project_factory?  Artemis.CLIProjectFactory  Project constructor override for tests.
--- @field manifest_factory? Artemis.CLIManifestFactory Manifest constructor override for tests.

--- @class Artemis.CLIArguments
--- @field command?          string    Selected top-level command.
--- @field runtime_command?  string    Selected runtime subcommand.
--- @field directory?        string    Project directory.
--- @field manifest?         string    Manifest path.
--- @field lockfile?         string    Lockfile path.
--- @field cache_dir?        string    Shared cache path.
--- @field pkg?              string    Package name.
--- @field constraint?       string    Package version constraint.
--- @field script?           string    Script path.
--- @field script_args?      string[]  Arguments passed to the script.
--- @field lua_version?      string    Lua version or release.
--- @field name?             string    Project name.
--- @field main?             string    Project entry point.
--- @field description?      string    Project description.
--- @field force?            boolean   Whether init may replace an existing manifest.
--- @field show_version?     boolean   Whether to print the CLI version.

--- @class Artemis.CLI
--- @field VERSION      string  CLI version displayed by `artemis --version`.
--- @field execute      fun(arguments: Artemis.CLIArguments, services?: Artemis.CLIServices): integer
--- @field build_parser fun(): table  Construct the argparse command tree.
--- @field main         fun(argv?: string[], services?: Artemis.CLIServices): integer  Parse arguments and dispatch.
local CLI = {}

--- CLI version displayed by `artemis --version`.
--- @type string
CLI.VERSION = "0.1.0-dev"


------------------------------------ Local Functions ------------------------------------

--- Quote a value as one POSIX shell argument.
--- @param value  string
--- @return string
local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Interpret os.execute/io.popen close results across Lua versions.
--- @param success   true?
--- @param exitcode  "exit"|"signal"?
--- @param code      integer?
--- @return boolean
local function command_succeeded(success, exitcode, code)
    if success == true then
        return true
    end

    return exitcode == "exit" and code == 0
end

--- Create a directory and any missing parent directories.
--- @param path  string
--- @return boolean  success
--- @return string? error_message
local function make_directory(path)
    local first, second, third = os.execute("mkdir -p " .. shell_quote(path))
    if command_succeeded(first, second, third) then
        return true
    end

    return false, string.format("Could not create directory '%s'.", path)
end

--- Resolve an existing directory to an absolute path.
--- @param path  string
--- @return string?  absolute_path
--- @return string?  error_message
local function absolute_directory(path)
    local handle, open_error = io.popen("cd " .. shell_quote(path) .. " && pwd", "r")
    if not handle then
        return nil, string.format("Could not resolve directory '%s': %s", path, open_error)
    end

    local absolute_path = (handle:read("*l") or ""):gsub("\r$", "")
    local first, second, third = handle:close()
    if absolute_path == "" or not command_succeeded(first, second, third) then
        return nil, string.format("Directory '%s' does not exist or cannot be accessed.", path)
    end

    return absolute_path
end

--- Join two paths using the path separator supported by the current CLI.
--- @param first   string
--- @param second  string
--- @return string
local function join_path(first, second)
    if second:sub(1, 1) == "/" or second:match("^%a:[/\\]") then
        return second
    end

    return first:gsub("[/\\]+$", "") .. "/" .. second:gsub("^[/\\]+", "")
end

--- Return the parent directory of a path.
--- @param path  string
--- @return string
local function parent_directory(path)
    local parent = path:match("^(.*)[/\\][^/\\]+$")
    if not parent or parent == "" then
        return "."
    end

    return parent
end

--- Check whether a file exists.
--- @param path  string
--- @return boolean
local function file_exists(path)
    local mode = lfs.attributes(path, "mode")
    return mode == "file"
end

--- Write a file only when it does not already exist.
--- @param path      string
--- @param contents  string
--- @return boolean  success
--- @return string? error_message
local function write_new_file(path, contents)
    if file_exists(path) then
        return true
    end

    local file, open_error = io.open(path, "wb")
    if not file then
        return false, string.format("Could not create '%s': %s", path, open_error)
    end

    local write_ok, write_error = file:write(contents)
    if not write_ok then
        file:close()
        return false, string.format("Could not write '%s': %s", path, write_error)
    end

    local close_ok, close_reason = file:close()
    if not close_ok then
        return false, string.format("Could not close '%s': %s", path, close_reason)
    end

    return true
end

--- Validate that a generated entry-point path stays inside the project.
--- @param path  string
--- @return boolean  valid
--- @return string? error_message
local function validate_main_path(path)
    if type(path) ~= "string" or not path:match("%S") then
        return false, "The main script path must be a non-empty relative path."
    end

    if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then
        return false, "The main script path must be relative to the project directory."
    end

    local normalized = path:gsub("\\", "/")
    for segment in normalized:gmatch("[^/]+") do
        if segment == ".." then
            return false, "The main script path cannot contain '..' path segments."
        end
    end

    return true
end

--- Resolve a project directory's leaf name for the default project name.
--- @param absolute_path  string
--- @return string
local function default_project_name(absolute_path)
    local name = absolute_path:gsub("[/\\]+$", ""):match("([^/\\]+)$") or "lua-project"
    name = name:gsub("[^%w%._%-]", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    if name == "" then
        return "lua-project"
    end

    return name
end

--- Send one line to an injected writer or a standard output stream.
--- @param writer   any
--- @param message  string
--- @param fallback any
--- @return nil
local function write_line(writer, message, fallback)
    if type(writer) == "function" then
        writer(message)
    elseif writer and type(writer.write) == "function" then
        writer:write(message, "\n")
    else
        fallback:write(message, "\n")
    end
end

--- Report a command error and return the standard failure status.
--- @param services  Artemis.CLIServices
--- @param message   string|integer?
--- @return integer
local function fail(services, message)
    write_line(services.stderr, "error: " .. tostring(message), io.stderr)
    return 1
end

--- Find the nearest ancestor containing an Artemis manifest.
--- Search stops at the home directory or filesystem root.
--- @param start_directory string
--- @param manifest_name string
--- @return string? project_root
--- @return string? error_message
local function find_project_root(start_directory, manifest_name)
    local current, resolve_error = absolute_directory(start_directory)
    if not current then
        return nil, resolve_error
    end

    local starting_directory = current

    -- Resolve HOME so it can be compared with the current directory.
    local home_directory
    local home = os.getenv("HOME")

    if home and home ~= "" then
        home_directory = absolute_directory(home)
    end

    while true do
        local manifest_path = join_path(current, manifest_name)

        if file_exists(manifest_path) then
            return current
        end

        -- Stop after checking HOME.
        if current == home_directory or current == "/" then
            break
        end

        local parent = parent_directory(current)

        if parent == current then
            break
        end

        current = parent
    end

    return nil, string.format(
        "Could not find '%s' starting from '%s'.",
        manifest_name,
        starting_directory
    )
end

--- Construct a Project for a parsed command.
--- @param arguments  Artemis.CLIArguments
--- @param services   Artemis.CLIServices
--- @return Artemis.Project?  project
--- @return string?           error_message
local function open_project(arguments, services)
    local options = {
        manifest_path = arguments.manifest or Manifest.DEFAULT_FILENAME,
        lockfile_path = arguments.lockfile or Lockfile.DEFAULT_FILENAME,
        cache_dir = arguments.cache_dir
    }

    local root, root_error = find_project_root(
        arguments.directory or ".",
        options.manifest_path
    )

    if not root then
        return nil, root_error
    end

    local factory = services.project_factory or Project.new
    return factory(root, options)
end

--- Initialize a new project manifest and starter script.
--- @param arguments  Artemis.CLIArguments
--- @param services   Artemis.CLIServices
--- @return integer  exit_code
local function initialize_project(arguments, services)
    local requested_directory = arguments.directory or "."
    local directory_created, directory_error = make_directory(requested_directory)
    if not directory_created then
        return fail(services, directory_error)
    end

    local absolute_directory, resolve_error = absolute_directory(requested_directory)
    if not absolute_directory then
        return fail(services, resolve_error)
    end

    local manifest_name = arguments.manifest or Manifest.DEFAULT_FILENAME
    local manifest_path = join_path(absolute_directory, manifest_name)
    local main_path = arguments.main or "src/main.lua"
    local main_is_valid, main_error = validate_main_path(main_path)
    if not main_is_valid then
        return fail(services, main_error)
    end

    if file_exists(manifest_path) and not arguments.force then
        return fail(services, string.format(
            "A manifest already exists at '%s'. Use --force to replace it.",
            manifest_path
        ))
    end

    local name = arguments.name or default_project_name(absolute_directory)
    local data = {
        name = name,
        version = "0.1.0",
        description = arguments.description or "A Lua project managed by Artemis",
        lua = arguments.lua_version or "5.4",
        main = main_path,
        dependencies = {}
    }

    local manifest_factory = services.manifest_factory or Manifest.new
    local manifest, manifest_error = manifest_factory(data, manifest_path)
    if not manifest then
        return fail(services, manifest_error)
    end

    local manifest_parent_created, manifest_parent_error = make_directory(parent_directory(manifest_path))
    if not manifest_parent_created then
        return fail(services, manifest_parent_error)
    end

    local manifest_saved, save_error = manifest:save(manifest_path)
    if not manifest_saved then
        return fail(services, save_error)
    end

    local script_absolute_path = join_path(absolute_directory, main_path)
    local script_parent_created, script_parent_error = make_directory(parent_directory(script_absolute_path))
    if not script_parent_created then
        return fail(services, script_parent_error)
    end

    local starter = string.format("print(%q)\n", "Hello from " .. name .. "!")
    local script_created, script_error = write_new_file(script_absolute_path, starter)
    if not script_created then
        return fail(services, script_error)
    end

    write_line(services.stdout, string.format("Initialized empty project '%s'", name),
        io.stdout)
    return 0
end

--- Print installed rocks with direct/transitive labels.
--- @param project   Artemis.Project
--- @param services  Artemis.CLIServices
--- @param tree_mode boolean
--- @return integer  exit_code
local function print_installed_rocks(project, services, tree_mode)
    local rocks, list_error
    if tree_mode then
        rocks, list_error = project:tree()
    else
        rocks, list_error = project:list_installed()
    end

    if not rocks then
        return fail(services, list_error)
    end

    table.sort(rocks, function(left, right)
        if left.name == right.name then
            return left.version < right.version
        end
        return left.name < right.name
    end)

    local direct_dependencies = project:get_dependencies()
    if #rocks == 0 then
        write_line(services.stdout, "No rocks are installed in this project.", io.stdout)
        return 0
    end

    if tree_mode then
        write_line(services.stdout, project.manifest.data.name, io.stdout)
        for index, rock in ipairs(rocks) do
            local branch = index == #rocks and "└──" or "├──"
            local relation = direct_dependencies[rock.name] and "direct" or "transitive"
            write_line(
                services.stdout,
                string.format("%s %s %s (%s)", branch, rock.name, rock.version, relation),
                io.stdout
            )
        end
        write_line(
            services.stdout,
            "Note: this is a flat installed-rock listing; dependency parent-child relationships are not yet available.",
            io.stdout
        )
        return 0
    end

    write_line(services.stdout, string.format("Installed rocks for %s:", project.manifest.data.name), io.stdout)
    for _, rock in ipairs(rocks) do
        local relation = direct_dependencies[rock.name] and "direct" or "transitive"
        write_line(services.stdout, string.format("%-24s %s (%s)", rock.name, rock.version, relation), io.stdout)
    end

    return 0
end

--- Execute a project command after its arguments have been parsed.
--- @param arguments  Artemis.CLIArguments
--- @param services?  Artemis.CLIServices
--- @return integer  exit_code  0 on success, 1 on command failure.
function CLI.execute(arguments, services)
    services = services or {}
    if type(arguments) ~= "table" then
        return fail(services, "Parsed command arguments must be a table.")
    end

    if arguments.show_version then
        write_line(services.stdout, "artemis " .. CLI.VERSION, io.stdout)
        return 0
    end

    local command = arguments.command
    if command == "init" then
        return initialize_project(arguments, services)
    end

    if command == "runtime" then
        local runtime_manager, manager_error = RuntimeManager.new({
            cache_dir = arguments.cache_dir
        })

        if not runtime_manager then
            return fail(services, manager_error)
        end

        local runtime_command = arguments.runtime_command

        if runtime_command == "install" then
            if not arguments.lua_version then
                return fail(services, "A Lua version must be specified.")
            end

            local installed, install_error, version =
                runtime_manager:install(arguments.lua_version)

            if not installed then
                return fail(services, install_error)
            end

            write_line(
                services.stdout,
                string.format("Lua %s is installed.", version),
                io.stdout
            )

            return 0
        end

        if runtime_command == "list" then
            local versions, list_error = runtime_manager:list_installed()

            if not versions then
                return fail(services, list_error)
            end

            if #versions == 0 then
                write_line(services.stdout, "No Lua runtimes are installed in the shared Artemis cache.", io.stdout)
                return 0
            end

            table.sort(versions)
            write_line(services.stdout, "Cached Lua runtimes:", io.stdout)
            for _, version in ipairs(versions) do
                write_line(services.stdout, "  " .. version, io.stdout)
            end

            return 0
        end

        if runtime_command == "remove" then
            local removed, remove_error =
                runtime_manager:uninstall(arguments.lua_version)

            if not removed then
                return fail(services, remove_error)
            end

            write_line(services.stdout,
                string.format(
                    "Removed Lua %s from the shared cache. Other projects using this runtime may need to reinstall it.",
                    arguments.lua_version), io.stdout)
            return 0
        end

        return fail(services, "Choose a runtime subcommand: install, list, or remove.")
    end

    if command ~= "sync" and command ~= "add" and command ~= "remove"
        and command ~= "list" and command ~= "ls" and command ~= "tree"
        and command ~= "run" then
        return fail(services, "No command was selected. Run 'artemis --help' to see available commands.")
    end

    local project, project_error = open_project(arguments, services)
    if not project then
        return fail(services, project_error)
    end

    if command == "sync" then
        local synchronized, sync_error, version = project:sync()
        if not synchronized then
            return fail(services, sync_error)
        end

        write_line(services.stdout, string.format(
            "Synchronized '%s' with Lua %s.",
            project.manifest.data.name,
            tostring(version or project.manifest.data.lua)
        ), io.stdout)
        return 0
    end

    if command == "add" then
        local added, add_error = project:add_dependency(arguments.pkg, arguments.constraint)
        if not added then
            local message = add_error or string.format("Could not add dependency '%s'.", arguments.pkg)
            return fail(services, message)
        end

        -- Project:add_dependency() resolves and persists the manifest. A second
        -- Project:sync() refreshes Artemis' lockfile after that manifest change.
        local synchronized, sync_error = project:sync()
        if not synchronized then
            return fail(services,
                string.format("Dependency '%s' was added, but the lockfile could not be refreshed: %s", arguments.pkg,
                    sync_error))
        end

        write_line(services.stdout, string.format(
            "Added dependency '%s' (%s).",
            arguments.pkg,
            arguments.constraint or "*"
        ), io.stdout)
        return 0
    end

    if command == "remove" then
        local removed, remove_warning = project:remove_dependency(arguments.pkg)
        if not removed then
            local message = remove_warning or
                string.format("Could not remove dependency '%s'.", arguments.pkg)
            return fail(services, message)
        end

        local synchronized, sync_error = project:sync()
        if not synchronized then
            return fail(services,
                string.format(
                    "Dependency '%s' was removed from the manifest, but the lockfile could not be refreshed: %s",
                    arguments.pkg, sync_error))
        end

        if remove_warning then
            write_line(services.stderr, "warning: " .. remove_warning, io.stderr)
        end

        write_line(services.stdout, string.format("Removed dependency '%s'.", arguments.pkg), io.stdout)
        return 0
    end

    if command == "list" or command == "ls" then
        return print_installed_rocks(project, services, false)
    end

    if command == "tree" then
        return print_installed_rocks(project, services, true)
    end

    if command == "run" then
        local script = arguments.script or project.manifest.data.main
        if not script then
            return fail(services, "No script was provided and the manifest has no 'main' entry.")
        end

        local ran, run_error = project:run(script, arguments.script_args or {})
        if not ran then
            return fail(services, run_error)
        end

        write_line(services.stdout, string.format("Finished running '%s'.", script), io.stdout)
        return 0
    end

    if command == "runtime" then
        local runtime_command = arguments.runtime_command
        if runtime_command == "install" then
            local installed, install_error, version = project:install_runtime(arguments.lua_version)
            if not installed then
                return fail(services, install_error)
            end

            write_line(
                services.stdout,
                string.format("Lua %s is installed and selected for this project.", version),
                io.stdout
            )
            return 0
        end

        if runtime_command == "list" then
            local versions, list_error = project.runtime_manager:list_installed()
            if not versions then
                return fail(services, list_error)
            end

            if #versions == 0 then
                write_line(services.stdout, "No Lua runtimes are installed in the shared Artemis cache.", io.stdout)
                return 0
            end

            table.sort(versions)
            write_line(services.stdout, "Cached Lua runtimes:", io.stdout)
            for _, version in ipairs(versions) do
                write_line(services.stdout, "  " .. version, io.stdout)
            end
            return 0
        end

        if runtime_command == "remove" then
            local removed, remove_error = project.runtime_manager:uninstall(arguments.lua_version)
            if not removed then
                return fail(services, remove_error)
            end

            write_line(services.stdout,
                string.format(
                    "Removed Lua %s from the shared cache. Other projects using this runtime may need to reinstall it.",
                    arguments.lua_version), io.stdout)
            return 0
        end

        return fail(services, "Choose a runtime subcommand: install, list, or remove.")
    end

    return fail(services, "Unsupported command.")
end

--- Build the argparse command tree.
--- @return any  parser  Argparse parser; the library constructs its API dynamically.
function CLI.build_parser()
    local parser = argparse("artemis", "A project manager for Lua.")
    parser:description("Manage Lua runtimes, project dependencies, lockfiles, and scripts.")
    parser:epilog("Run 'artemis <command> --help' for details about a command.")
    parser:command_target("command")
    parser:require_command(false)

    parser:option("-C --directory", "Project directory.", ".")
    parser:option("--manifest", "Manifest path.", Manifest.DEFAULT_FILENAME)
    parser:option("--lockfile", "Lockfile path.", Lockfile.DEFAULT_FILENAME)
    parser:option("--cache-dir", "Shared Artemis cache directory.")
    parser:flag("-v --version", "Show Artemis version."):target("show_version")

    local init = parser:command("init", "Create a project manifest and starter script.")
    init:argument("name", "Project name."):args("?")
    init:option("--lua-version", "Lua version requirement.", "5.4")
    init:option("--main", "Project entry-point path.", "src/main.lua")
    init:option("--description", "Project description.")
    init:flag("-f --force", "Replace an existing manifest.")

    parser:command("sync", "Synchronize the runtime and dependencies with the lockfile.")

    local add = parser:command("add", "Add a dependency and update the lockfile.")
    add:argument("package", "LuaRocks package name."):target("pkg")
    add:argument("constraint", "Optional LuaRocks version constraint."):args("?")

    local remove = parser:command("remove", "Remove a direct dependency and update the lockfile.")
    remove:argument("package", "LuaRocks package name."):target("pkg")

    parser:command("list ls", "List rocks installed in the project tree.")
    parser:command("tree", "Show installed rocks grouped as direct or transitive dependencies.")

    local run = parser:command("run", "Run a script using the selected project Lua runtime.")
    run:argument("script", "Script path; defaults to the manifest main entry."):args("?")
    run:argument("script_args", "Arguments passed to the script."):args("*")

    local runtime = parser:command("runtime", "Manage Lua runtimes in the shared Artemis cache.")
    runtime:command_target("runtime_command")

    local runtime_install = runtime:command(
        "install",
        "Install the Lua version requested by the project or a specified release."
    )
    runtime_install:argument("lua_version", "Lua version or exact release."):args("?")

    runtime:command("list", "List Lua releases installed in the shared Artemis cache.")

    local runtime_remove = runtime:command("remove", "Remove a Lua release from the shared Artemis cache.")
    runtime_remove:argument("lua_version", "Lua version or exact release.")

    return parser
end

--- Parse arguments and dispatch the requested command.
--- @param argv?      string[]              Arguments to parse; defaults to the process argument vector.
--- @param services?  Artemis.CLIServices   Optional writers and project factory for tests.
--- @return integer  exit_code
function CLI.main(argv, services)
    local parser = CLI.build_parser()
    local parsed_ok, parsed_or_error = parser:pparse(argv)
    if not parsed_ok then
        write_line(services and services.stderr, parser:get_usage(), io.stderr)
        write_line(services and services.stderr, "Error: " .. tostring(parsed_or_error), io.stderr)
        return 2
    end

    local arguments = parsed_or_error
    if arguments.show_version then
        return CLI.execute(arguments, services)
    end

    if not arguments.command then
        write_line(services and services.stdout, parser:get_help(), io.stdout)
        return 0
    end

    local ok, exit_code = pcall(CLI.execute, arguments, services)
    if not ok then
        return fail(services or {}, exit_code)
    end

    return exit_code
end

-----------------------------------------------------------------------------------------


return CLI
