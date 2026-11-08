package = "Artemis"
version = "dev-1"
source = {
  url = "git+ssh://git@github.com/Heitor-Guerra/Artemis"
}
description = {
  summary = "A project-first tool for making Lua development easier.",
  detailed =
  "A project-first tool for making Lua development easier. The goal is to provide a consistent way to create Lua projects, select and install a Lua version, manage dependencies, and reproduce a project's local environment.",
  homepage = "https://github.com/Heitor-Guerra/Artemis",
  license = "GNU GPL v3"
}
dependencies = {
  queries = {}
}
build_dependencies = {
  queries = {}
}
build = {
  type = "builtin",
  modules = {
    main = "src/main.lua"
  }
}
test_dependencies = {
  queries = {}
}
