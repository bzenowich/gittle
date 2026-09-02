## Talking to a remote repository: URLs, the child process, and protocol v2.
##
## ## There is only one transport
##
## Every remote gittle can reach is *a program with a pipe on each end*
## (plan.md R4).  `ssh://host/path` runs
##
##     ssh host "git-upload-pack '/path'"
##
## and a local path runs `git-upload-pack /path` directly, with no ssh in the
## way.  That is exactly git's own arrangement (`connect.c:git_connect`): the
## local case is not a second transport, it is the same one with the ssh
## prefix removed, which is why `clone /some/path` exercises every line of the
## protocol code that `clone ssh://…` does.  It is also why the differential
## tests can run at all: no test needs a server, an account or a network.
##
## The consequence worth stating: cloning from a *local* path needs
## `git-upload-pack` on this machine, because gittle does not serve (plan.md
## §6 decision 2) and so cannot answer its own request.  git avoids that for
## local paths by copying the object store instead (its `--local`, on by
## default).  gittle does not: a copy would be a second transport, tested by
## nothing the protocol tests cover, for a case that only arises when two
## repositories sit on one disk.
##
## `git://`, `http://` and `https://` are refused with a message that says so.
##
## ## Two protocol versions, because the server picks
##
## The version is not gittle's to choose.  A v2 request is made by putting
## `GIT_PROTOCOL=version=2` in the server's environment -- over ssh, by asking
## the ssh client to forward it -- and an `sshd` whose `AcceptEnv` does not
## list `GIT_PROTOCOL` simply drops it.  The server then answers in v0 and a
## client that cannot read v0 is a client that fails against an ordinary
## `sshd`.  So both are here, and they differ less than they look:
##
## | | v0 | v2 |
## |---|---|---|
## | first thing the server says | every ref, with capabilities on line one | `version 2` and its capabilities |
## | listing refs | already done, and unfiltered | a `ls-refs` request, with prefixes |
## | asking for objects | `want`/`have` lines, then `done` | `command=fetch`, same lines inside |
## | pushing | `<old> <new> <ref>` lines, then a pack | the same: `receive-pack` has no v2 |
##
## Push is v0 in both columns because git's `receive-pack` has no v2 form at
## all; the version negotiation happens and then the same protocol is spoken.
##
## ## Negotiation, in one round
##
## The client says which objects it *wants* and which it already *has*; the
## server sends the difference.  git plays this over several rounds, offering
## 16 commits at a time and refining on the acknowledgements.  gittle sends one
## round -- up to `haveLimit` commits from the tips of every local ref, newest
## first -- and then `done`, which tells the server to compute the pack from
## what it has been given rather than wait for more.  One round is what makes
## an incremental fetch cheap; further rounds only shave the tail, and each
## costs a round trip.
##
## Reference: `Documentation/gitprotocol-v2.adoc`,
## `Documentation/gitprotocol-pack.adoc`, `connect.c`, `fetch-pack.c`,
## `send-pack.c`.

import std/[os, posix, streams, strutils, tables]
import oid, pktline, util

const
  agent = "gittle/0.1.0"
  haveLimit* = 256
    ## How many commits one negotiation round offers.  git's is 16 per round
    ## with many rounds; one round of 256 costs the same bytes and no round
    ## trips.

type
  UrlKind = enum
    urLocal, urSsh, urUnsupported

  RemoteUrl = object
    kind: UrlKind
    user, host, port: string
    path: string
    scheme: string     ## only for the unsupported ones, to name it in the error

  RemoteRef* = object
    oid*: Oid
    name*: string
    symTarget*: string  ## `symref=HEAD:refs/heads/main`, when asked for
    peeled*: Oid        ## an annotated tag's commit, when asked for
    unborn*: bool       ## HEAD points at a branch that does not exist yet

  Conn* = ref object
    ## A live connection: the child process and the two pipes.
    pid: Pid
    toRemote*, fromRemote*: Stream
    v2*: bool
    caps*: Table[string, string]
    adverts: seq[RemoteRef]   ## v0 announces its refs before being asked
    url*: string

# ---------------------------------------------------------------------------
# URLs
# ---------------------------------------------------------------------------

proc parseUrl(url: string): RemoteUrl =
  ## The four forms git accepts for an ssh-or-local remote, and the ones it
  ## accepts that gittle does not.
  ##
  ## The scp-like `host:path` is the awkward one: it is recognised only when a
  ## colon appears *before* any slash (`connect.c:parse_connect_url`), so that
  ## `./dir:with:colons` stays a path and `github.com:me/repo` does not.
  for scheme in ["git://", "http://", "https://", "ftp://", "ftps://"]:
    if url.startsWith(scheme):
      return RemoteUrl(kind: urUnsupported, scheme: scheme[0 ..< scheme.len - 3])

  if url.startsWith("file://"):
    return RemoteUrl(kind: urLocal, path: url["file://".len .. ^1])

  if url.startsWith("ssh://"):
    var rest = url["ssh://".len .. ^1]
    let slash = rest.find('/')
    var authority = if slash < 0: rest else: rest[0 ..< slash]
    result.path = if slash < 0: "/" else: rest[slash .. ^1]
    result.kind = urSsh
    let at = authority.rfind('@')
    if at >= 0:
      result.user = authority[0 ..< at]
      authority = authority[at + 1 .. ^1]
    # A bracketed IPv6 literal keeps its colons; only a colon after the
    # closing bracket, or in an unbracketed authority, is a port.
    if authority.startsWith("["):
      let close = authority.find(']')
      failIf(close < 0, "invalid ssh url: " & url)
      result.host = authority[1 ..< close]
      if close + 1 < authority.len and authority[close + 1] == ':':
        result.port = authority[close + 2 .. ^1]
    else:
      let colon = authority.find(':')
      if colon >= 0:
        result.host = authority[0 ..< colon]
        result.port = authority[colon + 1 .. ^1]
      else:
        result.host = authority
    # `ssh://host/~user/repo` means a path relative to a home directory; the
    # leading slash is git's syntax, not part of the path (`connect.c`).
    if result.path.startsWith("/~"): result.path = result.path[1 .. ^1]
    return

  let colon = url.find(':')
  let slash = url.find('/')
  if colon > 0 and (slash < 0 or colon < slash):
    var authority = url[0 ..< colon]
    result.kind = urSsh
    result.path = url[colon + 1 .. ^1]
    let at = authority.rfind('@')
    if at >= 0:
      result.user = authority[0 ..< at]
      authority = authority[at + 1 .. ^1]
    if authority.startsWith("[") and authority.endsWith("]"):
      authority = authority[1 ..< authority.len - 1]
    result.host = authority
    return

  RemoteUrl(kind: urLocal, path: url)

func sqQuote(s: string): string =
  ## Wrap in single quotes for the remote's shell, the way `sq_quote` does:
  ## everything inside is literal, and an embedded quote closes, escapes and
  ## reopens.  The remote command is one shell word and the path goes inside
  ## it, so a repository whose name contains a space is otherwise a different
  ## repository.
  result = "'"
  for c in s:
    if c == '\'': result.add "'\\''"
    else: result.add c
  result.add "'"

# ---------------------------------------------------------------------------
# The child process
# ---------------------------------------------------------------------------

proc spawn(argv: seq[string]): tuple[pid: Pid, toChild, fromChild: cint] =
  ## fork/exec with a pipe on stdin and stdout, and **stderr left alone**.
  ##
  ## That last part is the reason this is not `startProcess`: Nim's osproc
  ## either pipes all three streams or none, and a piped stderr nobody reads
  ## is a deadlock waiting for a server with something to say.  Inheriting it
  ## also puts the remote's messages where the user expects them, which is
  ## what git does.
  var inPipe, outPipe: array[2, cint]
  failIf(pipe(inPipe) != 0 or pipe(outPipe) != 0, "cannot create a pipe")
  let pid = fork()
  failIf(pid < 0, "cannot fork")
  if pid == 0:
    discard dup2(inPipe[0], 0)
    discard dup2(outPipe[1], 1)
    discard close(inPipe[0]);  discard close(inPipe[1])
    discard close(outPipe[0]); discard close(outPipe[1])
    let args = allocCStringArray(argv)
    discard execvp(args[0], args)
    # Only reachable when exec failed; the parent will see the pipe close.
    stderr.write "gittle: cannot run " & argv[0] & ": " &
                 $strerror(errno) & "\n"
    exitWith(127)
  discard close(inPipe[0])
  discard close(outPipe[1])
  (pid, inPipe[1], outPipe[0])

proc streamOf(fd: cint, mode: FileMode): Stream =
  var f: File
  failIf(not open(f, FileHandle(fd), mode), "cannot wrap pipe " & $fd)
  newFileStream(f)

proc connect*(url: string, program: string,
              wantV2: bool): Conn =
  ## Start `program` (`git-upload-pack` or `git-receive-pack`) on the far end.
  let u = parseUrl(url)
  case u.kind
  of urUnsupported:
    fail("gittle speaks ssh and local paths only; '" & u.scheme &
         "' is not supported\n  " & url)
  of urLocal:
    failIf(u.path.len == 0, "no path in remote '" & url & "'")
  of urSsh:
    failIf(u.host.len == 0, "no host in remote '" & url & "'")

  # The version is requested through the environment, which is why ssh has to
  # be asked to forward it: `sshd` only passes what its `AcceptEnv` allows.
  if wantV2: putEnv("GIT_PROTOCOL", "version=2")
  else: delEnv("GIT_PROTOCOL")

  var argv: seq[string]
  if u.kind == urLocal:
    argv = @[program, u.path]
  else:
    argv = @["ssh"]
    if wantV2: argv.add ["-o", "SendEnv=GIT_PROTOCOL"]
    if u.port.len > 0: argv.add ["-p", u.port]
    argv.add(if u.user.len > 0: u.user & "@" & u.host else: u.host)
    argv.add program & " " & sqQuote(u.path)

  let (pid, toChild, fromChild) = spawn(argv)
  result = Conn(pid: pid, url: url,
                toRemote: streamOf(toChild, fmWrite),
                fromRemote: streamOf(fromChild, fmRead))

proc finish*(c: Conn) =
  ## Say goodbye, close the pipes, and reap the child.
  ##
  ## The goodbye is a flush-pkt and it is not optional: a v0 `upload-pack` that
  ## has advertised its refs is waiting for a want list, and end-of-file
  ## instead of a flush is, to it, a client that crashed -- it says
  ## "the remote end hung up unexpectedly" on its own stderr, which is the
  ## user's terminal.  In v2 the same flush ends the session
  ## (`transport.c:disconnect_git`).
  if c.toRemote != nil:
    try:
      writeFlush(c.toRemote)
      c.toRemote.flush()
    except CatchableError: discard
  if c.toRemote != nil: (try: c.toRemote.close() except CatchableError: discard)
  if c.fromRemote != nil: (try: c.fromRemote.close() except CatchableError: discard)
  var status: cint
  discard waitpid(c.pid, status, 0)

# ---------------------------------------------------------------------------
# The handshake
# ---------------------------------------------------------------------------

proc parseAdvertisedRef(line: string): RemoteRef =
  ## `<oid> <name>` in v0, and the same in a v2 `ls-refs` answer with optional
  ## `symref-target:` and `peeled:` attributes after it.
  let parts = line.split(' ')
  failIf(parts.len < 2, "protocol error: bad ref line: " & line)
  if parts[0] == "unborn":
    return RemoteRef(name: parts[1], unborn: true,
                     symTarget: (if parts.len > 2 and
                                    parts[2].startsWith("symref-target:"):
                                   parts[2]["symref-target:".len .. ^1] else: ""))
  result.oid = parseOid(parts[0])
  result.name = parts[1]
  for extra in parts[2 .. ^1]:
    if extra.startsWith("symref-target:"):
      result.symTarget = extra["symref-target:".len .. ^1]
    elif extra.startsWith("peeled:"):
      result.peeled = parseOid(extra["peeled:".len .. ^1])

proc handshake*(c: Conn) =
  ## Read whatever the server opens with, and decide which protocol this is.
  ##
  ## v2 opens with `version 2` and a list of capabilities.  v0 opens with the
  ## ref advertisement itself, capabilities NUL-separated on the first line --
  ## so by the time the version is known, a v0 client already has its answer
  ## to `ls-refs`, and a v2 client has to go and ask.  v1 is v0 with a
  ## `version 1` line in front.
  var first = true
  while true:
    var p: Pkt
    try:
      p = readPktLine(c.fromRemote)
    except GittleError:
      # Nothing at all came back.  Over ssh this is almost always a bad host
      # name, a refused key or a path that is not a repository -- ssh has
      # already said which on its own stderr, so what is left to add is what
      # gittle was trying to do.  git's wording, because it is the message a
      # user is most likely to have seen before (`connect.c`).
      if first:
        fail("Could not read from remote repository.\n\n" &
             "Please make sure you have the correct access rights\n" &
             "and the repository exists.")
      raise
    if p.kind != pkData: break
    var line = p.data
    if first:
      first = false
      if line == "version 2":
        c.v2 = true
        continue
      if line == "version 1": continue
    if c.v2:
      let sp = line.find('=')
      if sp > 0: c.caps[line[0 ..< sp]] = line[sp + 1 .. ^1]
      else: c.caps[line] = ""
      continue

    # v0: the first ref line carries the capabilities after a NUL.
    let nul = line.find('\0')
    if nul >= 0:
      for cap in line[nul + 1 .. ^1].split(' '):
        if cap.len == 0: continue
        let eq = cap.find('=')
        if eq > 0: c.caps[cap[0 ..< eq]] = cap[eq + 1 .. ^1]
        else: c.caps[cap] = ""
      line = line[0 ..< nul]
    # An empty repository advertises the null OID against `capabilities^{}`.
    if line.endsWith(" capabilities^{}"): continue

    if line.endsWith("^{}"):
      # v0 peels a tag by advertising `<name>^{}` on its own line, right
      # after the tag itself.
      let r = parseAdvertisedRef(line)
      let bare = r.name[0 ..< r.name.len - 3]
      for i in countdown(c.adverts.high, 0):
        if c.adverts[i].name == bare:
          c.adverts[i].peeled = r.oid
          break
      continue
    c.adverts.add parseAdvertisedRef(line)

  # gittle is SHA-1 only (plan.md decision 5), and a repository named in
  # another hash would hand back object IDs nothing here can resolve.  The
  # capability is absent on servers old enough not to have the notion, which
  # means sha1 by definition.
  failIf(c.caps.getOrDefault("object-format", "sha1") != "sha1",
         "the remote uses the '" & c.caps["object-format"] &
         "' object format; gittle implements SHA-1 only\n  " & c.url)

proc capValues(c: Conn, name: string): seq[string] =
  ## A v2 capability's value is a space-separated set of features.
  if c.caps.hasKey(name): c.caps[name].split(' ') else: @[]

# ---------------------------------------------------------------------------
# ls-refs
# ---------------------------------------------------------------------------

proc lsRefs*(c: Conn, prefixes: openArray[string],
             symrefs = true, peel = true): seq[RemoteRef] =
  ## Every ref the remote will show, filtered by prefix.
  ##
  ## In v0 there is nothing to send: the advertisement already arrived, and
  ## the prefixes are applied here instead.  In v2 the prefixes go to the
  ## server, which is the point of the command -- a repository with 200,000
  ## tags does not have to describe all of them to answer `fetch main`.
  if not c.v2:
    for r in c.adverts:
      if prefixes.len == 0: result.add r
      else:
        for p in prefixes:
          if r.name.startsWith(p): result.add r; break
    return
  let s = c.toRemote
  writeLine(s, "command=ls-refs")
  writeLine(s, "agent=" & agent)
  # Only when the server said it understands the notion: a capability it never
  # advertised is one it is entitled to reject.
  if c.caps.hasKey("object-format"): writeLine(s, "object-format=sha1")
  writeDelim(s)
  if symrefs: writeLine(s, "symrefs")
  if peel: writeLine(s, "peel")
  if "unborn" in c.capValues("ls-refs"): writeLine(s, "unborn")
  for p in prefixes: writeLine(s, "ref-prefix " & p)
  writeFlush(s)
  s.flush()
  while true:
    let p = readPktLine(c.fromRemote)
    if p.kind != pkData: break
    result.add parseAdvertisedRef(p.data)

# ---------------------------------------------------------------------------
# fetch
# ---------------------------------------------------------------------------

proc fetchV2(c: Conn, wants, haves: openArray[Oid],
             thin, includeTag, quiet: bool, sink: proc (data: string)) =
  let s = c.toRemote
  writeLine(s, "command=fetch")
  writeLine(s, "agent=" & agent)
  if c.caps.hasKey("object-format"): writeLine(s, "object-format=sha1")
  writeDelim(s)
  if thin: writeLine(s, "thin-pack")
  if includeTag: writeLine(s, "include-tag")
  writeLine(s, "ofs-delta")
  if quiet: writeLine(s, "no-progress")
  for w in wants: writeLine(s, "want " & $w)
  for h in haves: writeLine(s, "have " & $h)
  writeLine(s, "done")
  writeFlush(s)
  s.flush()
  # The response is a series of named sections.  Having sent `done` we expect
  # to go straight to `packfile`, but a server is free to send
  # `shallow-info` or `wanted-refs` first, and each is skipped to its
  # delimiter rather than assumed absent.
  while true:
    let p = readPktLine(c.fromRemote)
    case p.kind
    of pkFlush: return
    of pkDelim: continue
    of pkResponseEnd: return
    of pkData:
      if p.data == "packfile":
        demuxSideband(c.fromRemote, sink, quiet)
        return

proc fetchV0(c: Conn, wants, haves: openArray[Oid],
             thin, includeTag, quiet: bool, sink: proc (data: string)) =
  ## The original protocol: capabilities ride on the first `want` line, and
  ## the server answers `NAK` (or one `ACK`) before the pack.
  failIf(wants.len == 0, "nothing to fetch")
  let s = c.toRemote
  var caps = "side-band-64k ofs-delta agent=" & agent
  if thin and c.caps.hasKey("thin-pack"): caps = "thin-pack " & caps
  if includeTag and c.caps.hasKey("include-tag"): caps = "include-tag " & caps
  if quiet and c.caps.hasKey("no-progress"): caps = "no-progress " & caps
  writeLine(s, "want " & $wants[0] & " " & caps)
  for w in wants[1 .. ^1]: writeLine(s, "want " & $w)
  writeFlush(s)
  # Without `multi_ack` the server stops reading at the first common commit,
  # so the offer has to be small enough to fit a pipe buffer unread.
  for h in haves: writeLine(s, "have " & $h)
  writeLine(s, "done")
  s.flush()
  # The acknowledgements come first, and there may be any number of them --
  # `ACK <oid>` for each `have` the server recognises, then `NAK` if none.
  # There is no marker between them and the packfile: the first packet that
  # is not one of those two words is already side-band data, so it has to be
  # handled here rather than skipped.
  while true:
    let p = readPkt(c.fromRemote)
    failIf(p.kind != pkData, "protocol error: no packfile after 'done'")
    let line = p.data.strip(chars = {'\n'})
    if line == "NAK" or line.startsWith("ACK "): continue
    sidebandPacket(p, sink, quiet)
    break
  demuxSideband(c.fromRemote, sink, quiet)

proc fetchPack*(c: Conn, wants, haves: openArray[Oid],
                thin, includeTag, quiet: bool, sink: proc (data: string)) =
  ## Ask for everything reachable from `wants` that is not reachable from
  ## `haves`, and hand the packfile to `sink` as it arrives.
  ##
  ## `includeTag` is how tags follow a fetch without being asked for by name:
  ## the server adds any annotated tag that points into the history it is
  ## sending, and the caller decides afterwards which of them to keep.
  if c.v2: fetchV2(c, wants, haves, thin, includeTag, quiet, sink)
  else: fetchV0(c, wants, haves, thin, includeTag, quiet, sink)

# ---------------------------------------------------------------------------
# push
# ---------------------------------------------------------------------------

type
  PushCommand* = object
    name*: string
    oldOid*, newOid*: Oid

  PushResult* = object
    name*: string
    ok*: bool
    reason*: string

proc sendPack*(c: Conn, commands: openArray[PushCommand],
               pack: string, quiet: bool): seq[PushResult] =
  ## The push half, which is v0 whatever the handshake said: `receive-pack`
  ## has no protocol v2 form (`Documentation/gitprotocol-v2.adoc` lists only
  ## `ls-refs` and `fetch`).
  ##
  ## `side-band-64k` is deliberately *not* requested.  It would wrap the
  ## status report in a second layer of framing to carry progress text that
  ## already reaches the user's terminal down the child's own stderr, which
  ## gittle never redirected.
  let s = c.toRemote
  var caps = "report-status ofs-delta agent=" & agent
  if quiet and c.caps.hasKey("quiet"): caps = "quiet " & caps
  var first = true
  for cmd in commands:
    var line = $cmd.oldOid & " " & $cmd.newOid & " " & cmd.name
    if first:
      line.add '\0'
      line.add caps
      first = false
    writePkt(s, line & "\n")
  writeFlush(s)
  # Deletions alone need no objects, and a zero-object pack is legal but a
  # receiver is not obliged to like it.
  if pack.len > 0: s.write pack
  s.flush()

  if not c.caps.hasKey("report-status"): return
  let unpack = readPktLine(c.fromRemote)
  failIf(unpack.kind != pkData or not unpack.data.startsWith("unpack "),
         "protocol error: no unpack status from the remote")
  failIf(unpack.data != "unpack ok", "remote " & unpack.data)
  while true:
    let p = readPktLine(c.fromRemote)
    if p.kind != pkData: break
    let sp = p.data.find(' ')
    failIf(sp < 0, "protocol error: bad status line: " & p.data)
    let verb = p.data[0 ..< sp]
    let rest = p.data[sp + 1 .. ^1]
    if verb == "ok":
      result.add PushResult(name: rest, ok: true)
    elif verb == "ng":
      let sp2 = rest.find(' ')
      if sp2 < 0: result.add PushResult(name: rest, ok: false)
      else: result.add PushResult(name: rest[0 ..< sp2], ok: false,
                                  reason: rest[sp2 + 1 .. ^1])
