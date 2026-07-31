## Skill discovery (SKILL.md).

import std/[os, strutils, tables]

type
  Skill* = object
    name*: string
    description*: string
    body*: string
    path*: string

proc parseFrontmatter(content: string): tuple[meta: Table[string, string], body: string] =
  result.meta = initTable[string, string]()
  result.body = content
  if not content.startsWith("---"):
    return
  let rest = content[3 .. ^1]
  let endIdx = rest.find("---")
  if endIdx < 0:
    return
  let fm = rest[0 ..< endIdx]
  result.body = rest[endIdx + 3 .. ^1].strip()
  for line in fm.splitLines():
    let t = line.strip()
    if t.len == 0: continue
    let colon = t.find(':')
    if colon > 0:
      result.meta[t[0 ..< colon].strip()] = t[colon + 1 .. ^1].strip().strip(chars = {'"', '\''})

proc loadSkillsFromDir(dir: string, into: var Table[string, Skill]) =
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    if kind != pcDir: continue
    let skillFile = path / "SKILL.md"
    if not fileExists(skillFile): continue
    try:
      let raw = readFile(skillFile)
      let (meta, body) = parseFrontmatter(raw)
      var s = Skill(
        name: meta.getOrDefault("name", path.extractFilename),
        description: meta.getOrDefault("description", ""),
        body: body,
        path: skillFile,
      )
      into[s.name.toLowerAscii] = s
    except CatchableError:
      discard

proc discoverSkills*(workspace: string): Table[string, Skill] =
  result = initTable[string, Skill]()
  loadSkillsFromDir(getConfigDir() / "tai" / "skills", result)
  loadSkillsFromDir(workspace / ".tai" / "skills", result)

proc skillsPromptBlock*(skills: Table[string, Skill]): string =
  if skills.len == 0: return ""
  var parts = @["Available skills (invoke_skill):"]
  for name, s in skills:
    parts.add "- " & s.name & ": " & s.description
  parts.join("\n")

proc getSkillBody*(skills: Table[string, Skill], name: string): string =
  let key = name.toLowerAscii
  if skills.hasKey(key):
    return "# Skill: " & skills[key].name & "\n" & skills[key].body
  ""
