--- Command-line interface for Artemis.
---
--- The CLI is intentionally thin: project operations are delegated to
--- Artemis.Project, while argparse owns tokenization, options, subcommands,
--- and generated help text.
--- @module 'artemis.cli'

local argparse = require("argparse")
local Manifest = require("artemis.project.manifest")
local Lockfile = require("artemis.project.lockfile")
local Project = require("artemis.project")
local RuntimeManager = require("artemis.runtime_manager")
local Path = require("artemis.utils.path")
local FileSystem = require("artemis.utils.filesystem")

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
--- @field dependency_backend? string   Dependency installation backend.
--- @field server?            string   LuaRocks-compatible repository URL.
--- @field output?            string   Generated rockspec path.
--- @field pkg?              string   Package name.
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
  local current, resolve_error = Path.absolute_directory(start_directory)
  if not current then
    return nil, resolve_error
  end

  local starting_directory = current

  -- Resolve HOME so it can be compared with the current directory.
  local home_directory
  local home = os.getenv("HOME")

  if home and home ~= "" then
    home_directory = Path.absolute_directory(home)
  end

  while true do
    local manifest_path = Path.join(current, manifest_name)

    if FileSystem.file_exists(manifest_path) then
      return current
    end

    -- Stop after checking HOME.
    if current == home_directory or current == "/" then
      break
    end

    local parent = Path.parent(current)

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
    cache_dir = arguments.cache_dir,
    dependency_backend = arguments.dependency_backend,
    server = arguments.server
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
  local directory_created, directory_error = FileSystem.make_directory(requested_directory)
  if not directory_created then
    return fail(services, directory_error)
  end

  local absolute_path, resolve_error = Path.absolute_directory(requested_directory)
  if not absolute_path then
    return fail(services, resolve_error)
  end

  local manifest_name = arguments.manifest or Manifest.DEFAULT_FILENAME
  local manifest_path = Path.join(absolute_path, manifest_name)
  local main_path = arguments.main or "src/main.lua"
  local main_is_valid, main_error = validate_main_path(main_path)
  if not main_is_valid then
    return fail(services, main_error)
  end

  if FileSystem.file_exists(manifest_path) and not arguments.force then
    return fail(services, string.format(
      "A manifest already exists at '%s'. Use --force to replace it.",
      manifest_path
    ))
  end

  local name = arguments.name or default_project_name(absolute_path)
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

  local manifest_parent_created, manifest_parent_error = FileSystem.make_directory(Path.parent(manifest_path))
  if not manifest_parent_created then
    return fail(services, manifest_parent_error)
  end

  local manifest_saved, save_error = manifest:save(manifest_path)
  if not manifest_saved then
    return fail(services, save_error)
  end

  local script_absolute_path = Path.join(absolute_path, main_path)
  local script_parent_created, script_parent_error = FileSystem.make_directory(Path.parent(script_absolute_path))
  if not script_parent_created then
    return fail(services, script_parent_error)
  end

  local starter = string.format("print(%q)\n", "Hello from " .. name .. "!")
  local script_created, script_error = FileSystem.write_new_file(script_absolute_path, starter)
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
      and command ~= "run" and command ~= "rockspec" and command ~= "build" then
    return fail(services, "No command was selected. Run 'artemis --help' to see available commands.")
  end

  local project, project_error = open_project(arguments, services)
  if not project then
    return fail(services, project_error)
  end

  if command == "rockspec" then
    local rockspec_path, _, generation_error = project:generate_rockspec(arguments.output)
    if not rockspec_path then return fail(services, generation_error) end
    write_line(services.stdout, string.format("Generated rockspec '%s'.", rockspec_path), io.stdout)
    if project.manifest.data.source_url == nil then
      write_line(services.stderr,
        "warning: no source_url or Git origin was found; this rockspec uses file://. and is intended for local builds only.",
        io.stderr)
    end
    return 0
  end

  if command == "build" then
    local built, build_error, rockspec_path = project:build(arguments.output)
    if not built then return fail(services, build_error) end
    write_line(services.stdout, string.format(
      "Built '%s' and installed it into '%s'.",
      project.manifest.data.name,
      project.dependency_manager:get_tree()
    ), io.stdout)
    write_line(services.stdout, string.format("Used rockspec '%s'.", rockspec_path), io.stdout)
    return 0
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
  parser:option("--dependency-backend", "Dependency installer: native (default) or luarocks.", "luarocks")
  parser:option("--server", "LuaRocks-compatible package repository for the native backend.")
  parser:flag("-v --version", "Show Artemis version."):target("show_version")

  local init = parser:command("init", "Create a project manifest and starter script.")
  init:argument("name", "Project name."):args("?")
  init:option("--lua-version", "Lua version requirement.", "5.4")
  init:option("--main", "Project entry-point path.", "src/main.lua")
  init:option("--description", "Project description.")
  init:flag("-f --force", "Replace an existing manifest.")

  parser:command("sync", "Synchronize the runtime and dependencies with the lockfile.")

  local rockspec = parser:command("rockspec", "Generate a LuaRocks-compatible rockspec from the project manifest.")
  rockspec:option("-o --output", "Generated rockspec path.")

  local build = parser:command("build", "Build and install the current project into lua_modules.")
  build:option("-o --output", "Generated rockspec path used for the build.")

  local add = parser:command("add", "Add a dependency and update the lockfile.")
  add:argument("package", "LuaRocks-compatible rock name."):target("pkg")
  add:argument("constraint", "Optional LuaRocks version constraint."):args("?")

  local remove = parser:command("remove", "Remove a direct dependency and update the lockfile.")
  remove:argument("package", "LuaRocks-compatible rock name."):target("pkg")

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
