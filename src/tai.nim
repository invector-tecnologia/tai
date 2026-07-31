## Tai — TUI text editor entrypoint.

import std/os
import tai/[app, config]

when isMainModule:
  var cfg = loadConfig()
  if paramCount() >= 1:
    let p = paramStr(1)
    if dirExists(p):
      cfg.workspace = p.absolutePath
    elif fileExists(p):
      cfg.workspace = p.parentDir.absolutePath
  var a = initApp(cfg)
  if paramCount() >= 1 and fileExists(paramStr(1)):
    a.openPath(paramStr(1).absolutePath)
  a.runApp()
