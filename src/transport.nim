## Talking to a remote repository: the framing, the URL, the child process and
## the protocol.
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
## ## ...and only one protocol version: v0
##
## git speaks two wire protocols over that pipe, and the client chooses by
## putting `GIT_PROTOCOL=version=2` in the server's environment.  gittle does
## not choose: it *unsets* that variable and speaks the original protocol,
## called v0, to everything.  R4, "one of everything", applied to the wire.
##
## v0 is the version that cannot be refused.  Over ssh the variable only
## reaches the server if the client forwards it (`-o SendEnv=GIT_PROTOCOL`)
## *and* `sshd` allows it through (`AcceptEnv`); an ordinary `sshd` does not,
## drops it, and the server answers v0 regardless.  So a client that speaks v0
## works everywhere and a client that only speaks v2 does not -- which is why
## the version that survived the cut is the older one.
##
## What v0 costs, and it is the only thing it costs: **there is no way to ask
## for a subset of the refs.**  v2 has an `ls-refs` command that takes
## `ref-prefix` arguments; v0 has no request at all -- the server states every
## ref it has the moment the connection opens, before it is asked anything.
## On a repository the size of git.git that is about a thousand pkt-lines read
## and thrown away, once per connection, and on a repository with a hundred
## thousand tags it is a hundred thousand of them.  Milliseconds either way,
## and in exchange there is one code path from `connect` to the packfile.
##
## Push would have been v0 whatever was decided here: `receive-pack` has no v2
## form at all (`Documentation/gitprotocol-v2.adoc` defines exactly two
## commands, `ls-refs` and `fetch`).
##
## ## The shape of a v0 session
##
## | | |
## |---|---|
## | the server opens with | every ref, one per pkt-line, capabilities NUL-separated on the first |
## | fetch asks | `want` lines carrying the capabilities, `have` lines, `done` |
## | and gets back | `ACK`/`NAK`, then the packfile down side band 1 |
## | push asks | `<old> <new> <ref>` lines, then a packfile |
## | and gets back | `unpack ok`, then `ok <ref>` or `ng <ref> <why>` per ref |
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
## Reference: `Documentation/gitprotocol-pack.adoc`,
## `Documentation/gitprotocol-common.adoc`, `connect.c`, `upload-pack.c`,
## `fetch-pack.c`, `send-pack.c`.

import std/[os, posix, streams, strutils, tables]
import oid, util

const
  agent = "gittle/0.1.0"
  haveLimit* = 256
    ## How many commits one negotiation round offers.  git's is 16 per round
    ## with many rounds; one round of 256 costs the same bytes and no round
    ## trips.

# ---------------------------------------------------------------------------
# pkt-line: the framing under everything below
# ---------------------------------------------------------------------------
#
# Everything git sends over a connection -- ref advertisements, wants and
# haves, packfiles, error messages -- is a sequence of *pkt-lines*.  One is
# four hexadecimal digits giving the total length including those four digits,
# then that many bytes minus four:
#
#     0009hello\n        a 9-byte packet carrying "hello\n"
#     0000               flush-pkt -- end of a section or of a request
#
# Length 0 is therefore *not* an empty packet, it is that marker; 1 and 2 are
# the two v2 added (delim-pkt and response-end) and a v0 server that sends one
# is broken, so they are refused here rather than given a name.  A length of 4
# is a genuinely empty data packet, which the specification permits and gittle
# passes through as an empty string.  The maximum is 65520 bytes of payload
# (`LARGE_PACKET_MAX` minus the header), which is the only reason the packfile
# arrives in slices at all.
#
# Reference: `Documentation/gitprotocol-common.adoc`, `pkt-line.c`.

const
  maxPayload = 65516
    ## `LARGE_PACKET_MAX` (65520) less the four-digit header.  git will not
    ## send more in one packet and neither does gittle.

type
  PktKind = enum
    pkData, pkFlush

  Pkt = object
    kind: PktKind
    data: string   ## with its trailing newline, if the sender wrote one

  Sideband = enum
    sbData = 1, sbProgress = 2, sbError = 3

func hexDigit(c: char): int =
  ## The value of a hex digit, or -1.
  case c
  of '0'..'9': int(c) - int('0')
  of 'a'..'f': int(c) - int('a') + 10
  of 'A'..'F': int(c) - int('A') + 10
  else: -1

proc readExactly(s: Stream, n: int): string =
  ## `readStr` on a pipe can come back short; a packet header that arrives in
  ## two reads is not an error, and treating it as one produces a transport
  ## that works on a fast link and not on a slow one.
  result = newString(n)
  var got = 0
  while got < n:
    let k = s.readData(addr result[got], n - got)
    failIf(k <= 0, "the remote end hung up unexpectedly")
    got += k

proc readPkt(s: Stream): Pkt =
  ## One packet: the four-digit length, then the payload.  Length 0 is the
  ## flush-pkt; 1, 2 and 3 are not payload lengths at all.
  let head = readExactly(s, 4)
  var n = 0
  for c in head:
    let d = hexDigit(c)
    failIf(d < 0, "protocol error: bad line length character: " & head)
    n = n * 16 + d
  case n
  of 0: return Pkt(kind: pkFlush)
  of 1, 2, 3: fail("protocol error: bad line length " & $n)
  else: discard
  failIf(n - 4 > maxPayload, "protocol error: line too long (" & $n & ")")
  Pkt(kind: pkData, data: readExactly(s, n - 4))

proc readPktLine(s: Stream): Pkt =
  ## A data packet with its trailing newline removed, which is how every
  ## textual line of the protocol is meant to be read (`packet_read_line`).
  result = readPkt(s)
  if result.kind == pkData and result.data.len > 0 and
     result.data[^1] == '\n':
    result.data.setLen(result.data.len - 1)

func pktHeader(n: int): string =
  ## The four hex digits of a packet length.
  const hex = "0123456789abcdef"
  result = newString(4)
  for i in 0 .. 3:
    result[3 - i] = hex[(n shr (i * 4)) and 15]

proc writePkt(s: Stream, data: string) =
  ## One data packet.  Payloads longer than the maximum are split, which is
  ## only ever the packfile on a push.
  var at = 0
  while at < data.len:
    let n = min(maxPayload, data.len - at)
    s.write pktHeader(n + 4)
    s.writeData(unsafeAddr data[at], n)
    at += n
  if data.len == 0:
    s.write "0004"

proc writePktLine(s: Stream, line: string) =
  ## A textual packet.  git terminates these with a newline and several
  ## servers require it, so it is added here rather than at each call site.
  writePkt(s, line & "\n")

proc writeFlush(s: Stream) = s.write "0000"
  ## The flush-pkt, `0000`: end of a request, or of a section of a response.

# ## The side band
#
# A packfile cannot simply follow the last pkt-line, because the server also
# wants to send progress text while it is being generated.  So it is
# multiplexed: each data packet's *first byte* is a channel number.
#
#     1  packfile data      -- concatenate these, in order, and that is the pack
#     2  progress           -- for the user's terminal; git prefixes "remote: "
#     3  a fatal error      -- the server is about to hang up

proc sidebandPacket(p: Pkt, sink: proc (data: string), quiet: bool) =
  ## One side-band packet, dispatched by its first byte.
  ##
  ## Channel 2 is the server talking to the user's terminal -- "Counting
  ## objects", "Compressing" -- and git shows it prefixed with `remote: `
  ## (`sideband.c:demultiplex_sideband`).  gittle keeps the prefix and drops
  ## the carriage-return redrawing, so a non-terminal transcript stays
  ## readable; that is the whole of the difference.  It is also the whole of
  ## gittle's progress reporting: gittle prints what the server said and
  ## computes nothing of its own (docs/03 cuts `--progress`).
  failIf(p.data.len == 0, "protocol error: empty side-band packet")
  let band = int(p.data[0])
  let body = p.data[1 .. ^1]
  case band
  of int(sbData): sink(body)
  of int(sbProgress):
    if not quiet:
      for line in body.split('\n'):
        if line.len > 0:
          stderr.write "remote: " & line.strip(leading = false,
                                               chars = {'\r'}) & "\n"
  of int(sbError): fail("remote error: " & body.strip())
  else: fail("protocol error: unknown side band " & $band)

proc demuxSideband(s: Stream, sink: proc (data: string), quiet: bool) =
  ## Read side-band-64k packets until the flush that ends the section.
  while true:
    let p = readPkt(s)
    case p.kind
    of pkFlush: return
    of pkData: sidebandPacket(p, sink, quiet)

# ---------------------------------------------------------------------------
# URLs
# ---------------------------------------------------------------------------

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
    symTarget*: string  ## HEAD's branch, from the `symref=` capability
    peeled*: Oid        ## an annotated tag's commit, from its `^{}` line

  Conn* = ref object
    ## A live connection: the child process, the two pipes, and everything the
    ## server said before it was asked anything.
    pid: Pid
    toRemote*, fromRemote*: Stream
    caps*: Table[string, string]
    adverts*: seq[RemoteRef]  ## every ref the server has; see `handshake`
    url*: string

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
  ## A stream over one end of a pipe.
  var f: File
  failIf(not open(f, FileHandle(fd), mode), "cannot wrap pipe " & $fd)
  newFileStream(f)

proc connect*(url: string, program: string): Conn =
  ## Start `program` (`git-upload-pack` or `git-receive-pack`) on the far end.
  ##
  ## `GIT_PROTOCOL` is **removed** from the environment rather than left alone:
  ## it is how a client asks for protocol v2, gittle speaks only v0, and this
  ## process may well have been started by a git that set it for its own
  ## children (git exports it around hooks and aliases).  Inheriting it would
  ## make a *local* server answer in a protocol nothing here can read.  Over
  ## ssh it would not travel anyway -- forwarding it takes an explicit
  ## `-o SendEnv=GIT_PROTOCOL`, which is deliberately not passed.
  let u = parseUrl(url)
  case u.kind
  of urUnsupported:
    fail("gittle speaks ssh and local paths only; '" & u.scheme &
         "' is not supported\n  " & url)
  of urLocal:
    failIf(u.path.len == 0, "no path in remote '" & url & "'")
  of urSsh:
    failIf(u.host.len == 0, "no host in remote '" & url & "'")
  delEnv("GIT_PROTOCOL")

  var argv: seq[string]
  if u.kind == urLocal:
    argv = @[program, u.path]
  else:
    argv = @["ssh"]
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
  ## The goodbye is a flush-pkt and it is not optional: an `upload-pack` that
  ## has advertised its refs is waiting for a want list, and end-of-file
  ## instead of a flush is, to it, a client that crashed -- it says
  ## "the remote end hung up unexpectedly" on its own stderr, which is the
  ## user's terminal (`transport.c:disconnect_git`).
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
# The handshake, which is the whole ref advertisement
# ---------------------------------------------------------------------------

proc parseAdvertisedRef(line: string): RemoteRef =
  ## `<oid> <name>`, and nothing else: v0 has no per-ref attributes.
  let parts = line.split(' ')
  failIf(parts.len < 2, "protocol error: bad ref line: " & line)
  RemoteRef(oid: parseOid(parts[0]), name: parts[1])

proc handshake*(c: Conn) =
  ## Read the advertisement the server sends unprompted, which in v0 *is* the
  ## whole of "what refs do you have".  Fills `c.adverts` and `c.caps`.
  ##
  ## Four things arrive in the one stream and each needs its own treatment:
  ##
  ## * the **capabilities** hang off the first ref line after a NUL byte, so
  ##   the first line is a ref and a capability list at once;
  ## * `symref=HEAD:refs/heads/main` is among them, and it is the only way to
  ##   see which branch the remote's HEAD points at -- `clone` needs it to
  ##   decide which branch to create.  It is attached to the named ref here so
  ##   that callers never have to know it came from a capability;
  ## * an annotated tag is advertised twice, the second line named `<tag>^{}`
  ##   and holding the commit it points at.  That is v0's peeling, and it is
  ##   folded into the tag's own entry rather than left as a ref of its own;
  ## * an **empty repository** has no refs to state, so it advertises the null
  ##   ID against the pseudo-ref `capabilities^{}` purely to have something to
  ##   hang the capability list on.  It is not a ref and is dropped -- which
  ##   means an empty remote yields no adverts at all, and, unlike v2's
  ##   `unborn` line, says nothing about which branch its HEAD names.
  ##   `remotes.fetchFrom` says what is done about that.
  var symrefs: seq[string]
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
      # A server only answers `version <n>` when a client asked for that
      # version, and `connect` unset the variable that asks.  If one arrives
      # anyway, say so rather than failing later on an unparsable ref line.
      failIf(line.startsWith("version "),
             "the remote answered protocol '" & line["version ".len .. ^1] &
             "'; gittle speaks v0 only\n  " & c.url)
      # The first ref line carries the capabilities after a NUL.
      let nul = line.find('\0')
      if nul >= 0:
        for cap in line[nul + 1 .. ^1].split(' '):
          if cap.len == 0: continue
          if cap.startsWith("symref="): symrefs.add cap["symref=".len .. ^1]
          let eq = cap.find('=')
          if eq > 0: c.caps[cap[0 ..< eq]] = cap[eq + 1 .. ^1]
          else: c.caps[cap] = ""
        line = line[0 ..< nul]
      if line.endsWith(" capabilities^{}"): continue

    if line.endsWith("^{}"):
      let r = parseAdvertisedRef(line)
      let bare = r.name[0 ..< r.name.len - 3]
      for i in countdown(c.adverts.high, 0):
        if c.adverts[i].name == bare:
          c.adverts[i].peeled = r.oid
          break
      continue
    c.adverts.add parseAdvertisedRef(line)

  for spec in symrefs:
    # `<ref>:<target>`, e.g. `HEAD:refs/heads/main`.
    let colon = spec.find(':')
    if colon <= 0: continue
    for r in c.adverts.mitems:
      if r.name == spec[0 ..< colon]: r.symTarget = spec[colon + 1 .. ^1]

  # gittle is SHA-1 only (plan.md decision 5), and a repository named in
  # another hash would hand back object IDs nothing here can resolve.  The
  # capability is absent on servers old enough not to have the notion, which
  # means sha1 by definition.
  failIf(c.caps.getOrDefault("object-format", "sha1") != "sha1",
         "the remote uses the '" & c.caps["object-format"] &
         "' object format; gittle implements SHA-1 only\n  " & c.url)

# ---------------------------------------------------------------------------
# fetch
# ---------------------------------------------------------------------------

proc fetchPack*(c: Conn, wants, haves: openArray[Oid],
                thin, includeTag, quiet: bool, sink: proc (data: string)) =
  ## Ask for everything reachable from `wants` that is not reachable from
  ## `haves`, and hand the packfile to `sink` as it arrives.
  ##
  ## The capabilities ride on the *first* `want` line -- that is v0's only
  ## place to put them -- and each is asked for only when the server said it
  ## understands it, because a capability it never advertised is one it is
  ## entitled to reject.
  ##
  ## `includeTag` is how tags follow a fetch without being asked for by name:
  ## the server adds any annotated tag that points into the history it is
  ## sending, and the caller decides afterwards which of them to keep.
  failIf(wants.len == 0, "nothing to fetch")
  let s = c.toRemote
  var caps = "side-band-64k ofs-delta agent=" & agent
  if thin and c.caps.hasKey("thin-pack"): caps = "thin-pack " & caps
  if includeTag and c.caps.hasKey("include-tag"): caps = "include-tag " & caps
  if quiet and c.caps.hasKey("no-progress"): caps = "no-progress " & caps
  writePktLine(s, "want " & $wants[0] & " " & caps)
  for w in wants[1 .. ^1]: writePktLine(s, "want " & $w)
  writeFlush(s)
  # Without `multi_ack` the server stops reading at the first common commit,
  # so the offer has to be small enough to fit a pipe buffer unread.
  for h in haves: writePktLine(s, "have " & $h)
  writePktLine(s, "done")
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
  ## `<old> <new> <ref>` for every ref to move, then the packfile, then the
  ## server's verdict on each.
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
