## YouTube / podcast-style audio via mpv + yt-dlp.

import std/[os, osproc, json, net]

type
  AudioState* = enum
    asStopped
    asPlaying
    asPaused
    asMissingDeps

  AudioPlayer* = object
    url*: string
    state*: AudioState
    title*: string
    process*: Process
    sockPath*: string
    playBtn*: tuple[x, y, w: int]
    pauseBtn*: tuple[x, y, w: int]
    nextBtn*: tuple[x, y, w: int]

proc depsAvailable*(): bool =
  findExe("mpv").len > 0 and findExe("yt-dlp").len > 0

proc initAudioPlayer*(url: string): AudioPlayer =
  result.url = url
  result.title = ""
  result.sockPath = getTempDir() / ("tai-mpv-" & $getCurrentProcessId() & ".sock")
  if not depsAvailable() and url.len > 0:
    result.state = asMissingDeps
  else:
    result.state = asStopped

proc sendIpc(p: AudioPlayer, cmd: JsonNode): bool =
  if p.sockPath.len == 0:
    return false
  try:
    let sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
    defer: sock.close()
    sock.connectUnix(p.sockPath)
    sock.send($cmd & "\n")
    true
  except CatchableError:
    false

proc stop*(p: var AudioPlayer) =
  if p.process != nil:
    try:
      discard p.sendIpc(%*{"command": ["quit"]})
      if p.process.running:
        terminate(p.process)
      close(p.process)
    except CatchableError:
      discard
    p.process = nil
  if p.sockPath.len > 0:
    try: removeFile(p.sockPath) except CatchableError: discard
  if p.state != asMissingDeps:
    p.state = asStopped

proc play*(p: var AudioPlayer) =
  if p.url.len == 0:
    p.title = "no audio url — :audio url <link>"
    p.state = asStopped
    return
  if not depsAvailable():
    p.state = asMissingDeps
    p.title = "install mpv + yt-dlp"
    return
  if p.state == asPaused and p.process != nil:
    discard p.sendIpc(%*{"command": ["set_property", "pause", false]})
    p.state = asPlaying
    return
  p.stop()
  p.sockPath = getTempDir() / ("tai-mpv-" & $getCurrentProcessId() & ".sock")
  let args = @[
    "--no-video",
    "--really-quiet",
    "--no-terminal",
    "--input-ipc-server=" & p.sockPath,
    p.url,
  ]
  try:
    p.process = startProcess(
      findExe("mpv"),
      args = args,
      options = {poUsePath, poStdErrToStdOut},
    )
    p.state = asPlaying
    p.title = "playing…"
  except CatchableError as e:
    p.state = asStopped
    p.title = "mpv error: " & e.msg

proc pause*(p: var AudioPlayer) =
  if p.state == asPlaying and p.process != nil:
    discard p.sendIpc(%*{"command": ["set_property", "pause", true]})
    p.state = asPaused

proc toggle*(p: var AudioPlayer) =
  case p.state
  of asPlaying: p.pause()
  of asPaused, asStopped: p.play()
  of asMissingDeps: discard

proc nextTrack*(p: var AudioPlayer) =
  if p.process != nil and p.state in {asPlaying, asPaused}:
    discard p.sendIpc(%*{"command": ["playlist-next"]})
    p.title = "next…"
  else:
    p.play()

proc setUrl*(p: var AudioPlayer, url: string) =
  p.url = url
  if p.state in {asPlaying, asPaused}:
    p.play()

proc statusLabel*(p: AudioPlayer): string =
  case p.state
  of asMissingDeps: "audio: install mpv + yt-dlp"
  of asStopped:
    if p.url.len == 0: "audio: off"
    else: "audio: stopped"
  of asPaused: "❚❚ " & (if p.title.len > 0: p.title else: "paused")
  of asPlaying: "▶ " & (if p.title.len > 0: p.title else: "playing")

proc pollAlive*(p: var AudioPlayer) =
  if p.process != nil:
    if not p.process.running:
      try: close(p.process) except CatchableError: discard
      p.process = nil
      if p.state != asMissingDeps:
        p.state = asStopped
      p.title = ""
