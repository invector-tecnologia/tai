## Minimal MCP stdio JSON-RPC client.

import std/[osproc, json, strutils, tables, streams]
import ../config

type
  McpTool* = object
    server*: string
    name*: string
    description*: string
    fullName*: string ## mcp_<server>_<name>

  McpClient* = object
    servers*: seq[McpServerConfig]
    tools*: seq[McpTool]
    processes*: Table[string, Process]
    nextId*: int

proc initMcpClient*(servers: seq[McpServerConfig]): McpClient =
  result.servers = servers
  result.tools = @[]
  result.processes = initTable[string, Process]()
  result.nextId = 1

proc rpcRequest(id: int, methodName: string, params: JsonNode): string =
  $(%*{"jsonrpc": "2.0", "id": id, "method": methodName, "params": params}) & "\n"

proc sendRecv(p: Process, line: string): JsonNode =
  p.inputStream.write(line)
  p.inputStream.flush()
  var resp = ""
  # Read until a complete JSON line
  while true:
    let l = p.outputStream.readLine()
    if l.len == 0 and p.outputStream.atEnd:
      break
    let t = l.strip()
    if t.len == 0: continue
    try:
      return parseJson(t)
    except CatchableError:
      resp.add t
      try:
        return parseJson(resp)
      except CatchableError:
        discard
  newJObject()

proc startServer(c: var McpClient, srv: McpServerConfig): bool =
  if c.processes.hasKey(srv.name):
    return true
  try:
    var args = srv.args
    let p = startProcess(
      command = srv.command,
      args = args,
      options = {poUsePath, poStdErrToStdOut},
    )
    c.processes[srv.name] = p
    let initId = c.nextId
    inc c.nextId
    let initParams = %*{
      "protocolVersion": "2024-11-05",
      "capabilities": {},
      "clientInfo": {"name": "tai", "version": "0.4.0"},
    }
    discard sendRecv(p, rpcRequest(initId, "initialize", initParams))
    # notifications/initialized
    p.inputStream.write($(%*{"jsonrpc": "2.0", "method": "notifications/initialized"}) & "\n")
    p.inputStream.flush()
    let listId = c.nextId
    inc c.nextId
    let listed = sendRecv(p, rpcRequest(listId, "tools/list", newJObject()))
    if listed.hasKey("result") and listed["result"].hasKey("tools"):
      for t in listed["result"]["tools"]:
        let n = t{"name"}.getStr
        c.tools.add McpTool(
          server: srv.name,
          name: n,
          description: t{"description"}.getStr,
          fullName: "mcp_" & srv.name & "_" & n,
        )
    true
  except CatchableError:
    false

proc reload*(c: var McpClient) =
  for _, p in c.processes:
    try:
      terminate(p)
      close(p)
    except CatchableError:
      discard
  c.processes.clear()
  c.tools = @[]
  for srv in c.servers:
    discard c.startServer(srv)

proc ensureStarted*(c: var McpClient) =
  if c.tools.len == 0 and c.servers.len > 0:
    c.reload()

proc listSummary*(c: McpClient): string =
  if c.servers.len == 0:
    return "no MCP servers in config"
  var lines: seq[string]
  lines.add $c.servers.len & " server(s), " & $c.tools.len & " tool(s)"
  for t in c.tools:
    lines.add "  " & t.fullName & " — " & t.description
  lines.join("\n")

proc callTool*(c: var McpClient, fullName, argsJson: string): string =
  c.ensureStarted()
  var server = ""
  var tool = ""
  for t in c.tools:
    if t.fullName == fullName:
      server = t.server
      tool = t.name
      break
  if server.len == 0:
    return "unknown MCP tool: " & fullName
  if not c.processes.hasKey(server):
    return "MCP server not running: " & server
  var args = newJObject()
  try:
    if argsJson.len > 0: args = parseJson(argsJson)
  except CatchableError:
    return "invalid args"
  let id = c.nextId
  inc c.nextId
  let params = %*{"name": tool, "arguments": args}
  try:
    let resp = sendRecv(c.processes[server], rpcRequest(id, "tools/call", params))
    if resp.hasKey("result"):
      return $resp["result"]
    if resp.hasKey("error"):
      return $resp["error"]
    $resp
  except CatchableError as e:
    e.msg

proc mcpToolDefs*(c: McpClient): JsonNode =
  result = newJArray()
  for t in c.tools:
    result.add %*{
      "type": "function",
      "function": {
        "name": t.fullName,
        "description": t.description,
        "parameters": {"type": "object", "properties": {}, "additionalProperties": true},
      },
    }

proc shutdown*(c: var McpClient) =
  for _, p in c.processes:
    try:
      terminate(p)
      close(p)
    except CatchableError:
      discard
  c.processes.clear()
