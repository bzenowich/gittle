## Binding to the system zlib (decision 4: the one external dependency).
##
## Inflate is streaming, because objects inside a packfile give no compressed
## length -- the only way to find where the next object starts is to inflate and
## ask zlib how many input bytes it consumed.  Deflate is one-shot: gittle only
## ever compresses a whole loose object it already holds in memory.

import util

{.passL: "-lz".}
{.pragma: zlibh, header: "<zlib.h>".}

type
  ZStream {.pure, final.} = object
    ## zlib's `z_stream`.  Layout is ABI-stable; `assertLayout` below checks it
    ## against the header at startup so a surprise is loud rather than subtle.
    nextIn: ptr byte
    availIn: cuint
    totalIn: culong
    nextOut: ptr byte
    availOut: cuint
    totalOut: culong
    msg: cstring
    state: pointer
    zalloc: pointer
    zfree: pointer
    opaque: pointer
    dataType: cint
    adler: culong
    reserved: culong

const
  ZOk = 0.cint
  ZStreamEnd = 1.cint
  ZBufError = -5.cint
  ZNoFlush = 0.cint

  ZBestSpeed* = 1.cint
    ## What git uses for loose objects (`core.loosecompression`, environment.c).

  zlibVersion = "1.2.11"  ## only the major digit is checked by zlib

# zlib's `inflateInit2_`, with the version and struct size it checks.
proc inflateInit2u(strm: var ZStream, windowBits: cint, version: cstring,
                   streamSize: cint): cint
  {.importc: "inflateInit2_", zlibh.}
# zlib's `inflate`.
proc inflateRaw(strm: var ZStream, flush: cint): cint {.importc: "inflate", zlibh.}
# zlib's `inflateEnd`.
proc inflateEnd(strm: var ZStream): cint {.importc: "inflateEnd", zlibh.}
# zlib's bound on the compressed size of `sourceLen` bytes.
proc compressBound(sourceLen: culong): culong {.importc, zlibh.}
# zlib's `crc32`, which packs' `.idx` files use per object.
proc crc32c(crc: culong, buf: ptr byte, len: cuint): culong
  {.importc: "crc32", zlibh.}
# zlib's one-shot `compress2`, for writing loose objects.
proc compress2(dest: ptr byte, destLen: var culong, source: ptr byte,
               sourceLen: culong, level: cint): cint {.importc, zlibh.}

# The header is included explicitly rather than relied upon arriving from the
# `importc` procs below: in a translation unit that happens not to call one of
# them, it would not, and the size check would fail to compile.
{.emit: """/*INCLUDESECTION*/
#include <zlib.h>
""".}
{.emit: """/*TYPESECTION*/
static const long gittle_zstream_size = (long)sizeof(z_stream);
""".}
let cZStreamSize {.importc: "gittle_zstream_size", nodecl.}: clong

proc assertLayout() =
  ## Refuse to run if this build's zlib disagrees with the `ZStream`
  ## layout declared here.
  failIf(int(cZStreamSize) != sizeof(ZStream),
    "z_stream layout mismatch: zlib.h says " & $int(cZStreamSize) &
    " bytes, gittle assumes " & $sizeof(ZStream))

proc failZ(z: ZStream, code: cint, what: string) {.noreturn.} =
  ## A fatal error carrying zlib's return code and message.
  fail(what & " failed (" & $code & ")" & (if z.msg != nil: ": " & $z.msg else: ""))

type
  Inflater* = object
    ## A single zlib inflate stream.  Not copyable; `close` exactly once.
    strm: ZStream
    live: bool
    finished*: bool  ## the stream reached its end marker

proc close*(z: var Inflater) =
  ## Free the stream, once.
  if z.live:
    discard inflateEnd(z.strm)
    z.live = false

proc openInflater*(): Inflater =
  ## A stream ready to inflate zlib-wrapped data.
  assertLayout()
  result.strm = ZStream()
  let rc = inflateInit2u(result.strm, 15, zlibVersion, cint(sizeof(ZStream)))
  if rc != ZOk: failZ(result.strm, rc, "inflateInit2")
  result.live = true

proc pump*(z: var Inflater, src: pointer, srcLen: int,
           dst: pointer, dstLen: int): tuple[consumed, produced: int] =
  ## Push up to `srcLen` bytes in, take up to `dstLen` bytes out.  Sets
  ## `z.finished` when zlib reports the end of the stream.
  z.strm.nextIn = cast[ptr byte](src)
  z.strm.availIn = cuint(srcLen)
  z.strm.nextOut = cast[ptr byte](dst)
  z.strm.availOut = cuint(dstLen)
  let rc = inflateRaw(z.strm, ZNoFlush)
  if rc == ZStreamEnd:
    z.finished = true
  elif rc != ZOk and rc != ZBufError:
    failZ(z.strm, rc, "inflate")
  result.consumed = srcLen - int(z.strm.availIn)
  result.produced = dstLen - int(z.strm.availOut)

func offset(p: pointer, n: int): pointer {.inline.} =
  ## A pointer `n` bytes further on.
  cast[pointer](cast[uint](p) + uint(n))

# -- one-shot helpers -------------------------------------------------------
#
# All of these take a raw pointer, because every caller is either a
# memory-mapped packfile or a string and neither wants a copy.

proc inflateInto(src: pointer, srcLen, limit: int, drain: bool):
    tuple[data: string, consumed: int] =
  ## The one inflate loop.  Two knobs cover every way gittle reads a stream:
  ##
  ## * `limit` -- how many output bytes are wanted.  Negative means "however
  ##   many there turn out to be", and the buffer doubles as it fills.
  ## * `drain` -- after `limit` bytes, keep feeding zlib until it reports the
  ##   end of the stream.  That is what makes `consumed` exact, which is the
  ##   only way the pack reader can find where the next object starts.
  var z = openInflater()
  defer: z.close()
  var cap = if limit >= 0: limit else: max(srcLen * 4, 4096)
  result.data = newString(cap)
  var inPos = 0
  var outPos = 0
  while not z.finished and (limit < 0 or outPos < limit):
    if outPos == cap:
      cap *= 2
      result.data.setLen(cap)
    let p = z.pump(src.offset(inPos), srcLen - inPos,
                   addr result.data[outPos], cap - outPos)
    inPos += p.consumed
    outPos += p.produced
    if p.consumed == 0 and p.produced == 0: break
  result.data.setLen(outPos)

  if drain:
    var scratch: byte
    while not z.finished:
      let p = z.pump(src.offset(inPos), srcLen - inPos, addr scratch, 1)
      failIf(p.produced != 0, "zlib stream is longer than its declared size")
      failIf(p.consumed == 0, "truncated zlib stream")
      inPos += p.consumed
  result.consumed = inPos

proc inflateExact*(src: pointer, srcLen, outLen: int):
    tuple[data: string, consumed: int] =
  ## Inflate exactly `outLen` bytes, and report how many compressed bytes they
  ## occupied -- which is how the pack reader steps from one object to the next.
  result = inflateInto(src, srcLen, outLen, drain = true)
  failIf(result.data.len != outLen, "truncated zlib stream")

proc inflatePrefix*(src: pointer, srcLen, maxOut: int): string =
  ## Inflate at most `maxOut` bytes and stop; a short result means the stream
  ## ended first.  Reads a loose object's header without paying for its body.
  inflateInto(src, srcLen, maxOut, drain = false).data

proc inflateAll*(src: pointer, srcLen: int): string =
  ## Inflate a whole stream of unknown length.
  inflateInto(src, srcLen, -1, drain = false).data

proc deflateAll*(src: pointer, srcLen: int, level: cint): string =
  ## Compress in one shot.  `compress2` uses zlib's defaults for everything but
  ## the level, which is exactly what git does for a loose object.
  var bound = compressBound(culong(srcLen))
  result = newString(int(bound))
  let rc = compress2(cast[ptr byte](addr result[0]), bound,
                     cast[ptr byte](src), culong(srcLen), level)
  failIf(rc != ZOk, "compress2 failed (" & $rc & ")")
  result.setLen(int(bound))

proc crc32*(data: pointer, len: int): uint32 =
  ## The checksum a pack index records for every object's stored bytes.  zlib
  ## has it already -- it needs one for the gzip container -- so the alternative
  ## was a table nobody would ever read.
  uint32(crc32c(crc32c(0, nil, 0), cast[ptr byte](data), cuint(len)))
