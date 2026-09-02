## pkt-line: the framing under every git transport.
##
## Everything git sends over a connection -- ref advertisements, wants and
## haves, packfiles, error messages -- is a sequence of *pkt-lines*.  One is
## four hexadecimal digits giving the total length including those four digits,
## then that many bytes minus four:
##
##     0009hello\n        a 9-byte packet carrying "hello\n"
##     0000               flush-pkt      -- end of a section or a request
##     0001               delim-pkt      -- v2's separator between the command
##                                          and its arguments
##     0002               response-end   -- v2 stateless-rpc only; gittle never
##                                          sends it and treats it as an end
##
## Lengths 0, 1 and 2 are therefore *not* empty packets: they are the three
## special markers.  A length of 4 is a genuinely empty data packet, which the
## specification permits and gittle passes through as an empty string.  The
## maximum is 65520 bytes of payload (`LARGE_PACKET_MAX` minus the header),
## which is the only reason the packfile arrives in slices at all.
##
## ## The side band
##
## A packfile cannot simply follow the last pkt-line, because the server also
## wants to send progress text while it is being generated.  So it is
## multiplexed: each data packet's *first byte* is a channel number.
##
##     1  packfile data      -- concatenate these, in order, and that is the pack
##     2  progress           -- for the user's terminal; git prefixes "remote: "
##     3  a fatal error      -- the server is about to hang up
##
## `demuxSideband` below is that loop, and it is the whole of gittle's progress
## reporting: gittle prints what the server said and computes nothing of its
## own (docs/03 cuts `--progress`).
##
## Reference: `Documentation/gitprotocol-common.adoc`, `pkt-line.c`.

import std/[streams, strutils]
import util

const
  maxPayload = 65516
    ## `LARGE_PACKET_MAX` (65520) less the four-digit header.  git will not
    ## send more in one packet and neither does gittle.

type
  PktKind* = enum
    pkData, pkFlush, pkDelim, pkResponseEnd

  Pkt* = object
    kind*: PktKind
    data*: string   ## with its trailing newline, if the sender wrote one

  Sideband* = enum
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

proc readPkt*(s: Stream): Pkt =
  ## One packet: the four-digit length, then the payload; `flush`, `delim`
  ## and `response-end` are the lengths 0, 1 and 2.
  let head = readExactly(s, 4)
  var n = 0
  for c in head:
    let d = hexDigit(c)
    failIf(d < 0, "protocol error: bad line length character: " & head)
    n = n * 16 + d
  case n
  of 0: return Pkt(kind: pkFlush)
  of 1: return Pkt(kind: pkDelim)
  of 2: return Pkt(kind: pkResponseEnd)
  of 3: fail("protocol error: bad line length 3")
  else: discard
  failIf(n - 4 > maxPayload, "protocol error: line too long (" & $n & ")")
  Pkt(kind: pkData, data: readExactly(s, n - 4))

proc readPktLine*(s: Stream): Pkt =
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

proc writePkt*(s: Stream, data: string) =
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

proc writeLine*(s: Stream, line: string) =
  ## A textual packet.  git terminates these with a newline and several
  ## servers require it, so it is added here rather than at each of the
  ## thirty call sites.
  writePkt(s, line & "\n")

proc writeFlush*(s: Stream) = s.write "0000"
proc writeDelim*(s: Stream) = s.write "0001"

proc sidebandPacket*(p: Pkt, sink: proc (data: string), quiet: bool) =
  ## One side-band packet, dispatched by its first byte.
  ##
  ## Channel 2 is the server talking to the user's terminal -- "Counting
  ## objects", "Compressing" -- and git shows it prefixed with `remote: `
  ## (`sideband.c:demultiplex_sideband`).  gittle keeps the prefix and drops
  ## the carriage-return redrawing, so a non-terminal transcript stays
  ## readable; that is the whole of the difference.
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

proc demuxSideband*(s: Stream, sink: proc (data: string), quiet: bool) =
  ## Read side-band-64k packets until the flush that ends the section.
  while true:
    let p = readPkt(s)
    case p.kind
    of pkFlush, pkResponseEnd: return
    of pkDelim: fail("protocol error: unexpected delimiter in side band")
    of pkData: sidebandPacket(p, sink, quiet)
