## Git wrappers for :git commands.

import std/[os, osproc]

type
  GitResult* = object
    ok*: bool
    output*: string

proc runGit*(cwd: string, args: openArray[string]): GitResult =
  let git = findExe("git")
  if git.len == 0:
    return GitResult(ok: false, output: "git not found on PATH")
  var cmd = quoteShell(git)
  for a in args:
    cmd.add " " & quoteShell(a)
  try:
    let (outp, code) = execCmdEx(cmd, workingDir = cwd)
    result.ok = code == 0
    result.output = if outp.len > 0: outp else: (if code == 0: "(ok)" else: "git exit " & $code)
  except CatchableError as e:
    result = GitResult(ok: false, output: e.msg)

proc truncate*(s: string, limit = 8_000): string =
  if s.len <= limit: s
  else: s[0 ..< limit] & "\n… truncated"

proc gitStatus*(cwd: string): GitResult =
  result = runGit(cwd, ["status", "-sb"])
  result.output = truncate(result.output)

proc gitDiff*(cwd: string, staged = false): GitResult =
  if staged:
    result = runGit(cwd, ["diff", "--cached"])
  else:
    result = runGit(cwd, ["diff"])
  result.output = truncate(result.output)

proc gitLog*(cwd: string, n = 15): GitResult =
  result = runGit(cwd, ["log", "-n", $n, "--oneline"])
  result.output = truncate(result.output)

proc gitBranch*(cwd: string): GitResult =
  result = runGit(cwd, ["branch", "-v"])
  result.output = truncate(result.output)

proc gitAdd*(cwd: string, paths: seq[string]): GitResult =
  var args = @["add"]
  if paths.len == 0:
    args.add "."
  else:
    for p in paths: args.add p
  runGit(cwd, args)

proc gitCommit*(cwd: string, message: string): GitResult =
  if message.len == 0:
    return GitResult(ok: false, output: "empty commit message")
  runGit(cwd, ["commit", "-m", message])
