## SSE helpers for OpenAI-compatible streaming.

import std/[strutils, json, options]

proc parseSseDataLine*(line: string): Option[JsonNode] =
  if not line.startsWith("data:"):
    return none(JsonNode)
  var payload = line[5 .. ^1].strip()
  if payload.len == 0 or payload == "[DONE]":
    return none(JsonNode)
  try:
    return some(parseJson(payload))
  except CatchableError:
    return none(JsonNode)

proc deltaContent*(j: JsonNode): string =
  try:
    result = j["choices"][0]["delta"]{"content"}.getStr
  except CatchableError:
    result = ""

proc hasDeltaToolCalls*(j: JsonNode): bool =
  try:
    result = j["choices"][0]["delta"].hasKey("tool_calls")
  except CatchableError:
    result = false
