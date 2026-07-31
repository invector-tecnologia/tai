# Package

version       = "0.4.0"
author        = "Invector Tecnologia"
description   = "Tai — TUI text editor with AI agent harness"
license       = "AGPL-3.0"
srcDir        = "src"
bin           = @["tai"]

# Dependencies

requires "nim >= 2.0.0"
requires "tatui >= 0.1.0"
requires "parsetoml >= 0.7.0"

task test, "Run the test suite":
  exec "nim c -r --mm:orc --threads:on --hints:off tests/all_tests.nim"

task lint, "Type-check the project":
  exec "nim check --mm:orc --threads:on --hints:off src/tai.nim"

task run, "Build and run Tai in the current directory":
  exec "nim c -r --mm:orc --threads:on -d:release src/tai.nim ."
