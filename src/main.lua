local argparse = require("argparse")

local parser = argparse("my-project", "A simple example")

parser:option("-n --name", "Your name")

local args = parser:parse()

print("Hello, " .. (args.name or "World"))
