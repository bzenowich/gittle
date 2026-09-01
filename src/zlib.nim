## Binding to the system zlib (decision 4: the one external dependency).
##
## Inflate is streaming, because objects inside a packfile give no compressed
## length -- the only way to find where the next object starts is to inflate and
## ask zlib how many input bytes it consumed.  Deflate is one-shot: gittle only
## ever compresses a whole loose object it already holds in memory.

{.passL: "-lz".}
{.pragma: zlibh, header: "<zlib.h>".}

type
  ZlibError* = object of CatchableError

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
  ZDefaultCompression* = -1.cint

  zlibVersion = "1.2.11"  ## only the major digit is checked by zlib

proc inflateInit2u(strm: var ZStream, windowBits: cint, version: cstring,
                   streamSize: cint): cint
  {.importc: "inflateInit2_", zlibh.}
proc inflateRaw(strm: var ZStream, flush: cint): cint {.importc: "inflate", zlibh.}
proc inflateEnd(strm: var ZStream): cint {.importc: "inflateEnd", zlibh.}
proc compressBound(sourceLen: culong): culong {.importc, zlibh.}
proc compress2(dest: ptr byte, destLen: var culong, source: ptr byte,
               sourceLen: culong, level: cint): cint {.importc, zlibh.}

{.emit: """/*TYPESECTION*/
static const long gittle_zstream_size = (long)sizeof(z_stream);
""".}
let cZStreamSize {.importc: "gittle_zstream_size", nodecl.}: clong

proc assertLayout() =
  if int(cZStreamSize) != sizeof(ZStream):
    raise newException(ZlibError,
      "z_stream layout mismatch: zlib.h says " & $int(cZStreamSize) &
      " bytes, gittle assumes " & $sizeof(ZStream))

proc fail(z: ZStream, code: cint, what: string) {.noreturn.} =
  var detail = ""
  if z.msg != nil: detail = ": " & $z.msg
  raise newException(ZlibError, what & " failed (" & $code & ")" & detail)

type
  Inflater* = object
    ## A single zlib inflate stream.  Not copyable; `close` exactly once.
    strm: ZStream
    live: bool
    finished*: bool  ## the stream reached its end marker

proc close*(z: var Inflater) =
  if z.live:
    discard inflateEnd(z.strm)
    z.live = false

proc openInflater*(): Inflater =
  assertLayout()
  result.strm = ZStream()
  let rc = inflateInit2u(result.strm, 15, zlibVersion, cint(sizeof(ZStream)))
  if rc != ZOk: fail(result.strm, rc, "inflateInit2")
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
    fail(z.strm, rc, "inflate")
  result.consumed = srcLen - int(z.strm.availIn)
  result.produced = dstLen - int(z.strm.availOut)

func offset(p: pointer, n: int): pointer {.inline.} =
  cast[pointer](cast[uint](p) + uint(n))

# -- one-shot helpers -------------------------------------------------------
#
# All three take a raw pointer because their callers are either a memory-mapped
# packfile or a string, and neither wants a copy.

proc inflateExact*(src: pointer, srcLen, outLen: int):
    tuple[data: string, consumed: int] =
  ## Inflate exactly `outLen` bytes.  Returns them together with the number of
  ## compressed bytes they occupied -- which is how the pack reader steps from
  ## one object to the next.
  var z = openInflater()
  defer: z.close()
  result.data = newString(outLen)
  var inPos = 0
  var outPos = 0
  while outPos < outLen:
    let p = z.pump(src.offset(inPos), srcLen - inPos,
                   addr result.data[outPos], outLen - outPos)
    inPos += p.consumed
    outPos += p.produced
    if p.produced == 0 and p.consumed == 0:
      raise newException(ZlibError, "truncated zlib stream")
  # Give zlib the chance to read the trailing adler32 so `consumed` is exact.
  var scratch: byte
  while not z.finished:
    let p = z.pump(src.offset(inPos), srcLen - inPos, addr scratch, 1)
    inPos += p.consumed
    if p.produced != 0:
      raise newException(ZlibError, "zlib stream longer than the declared size")
    if p.consumed == 0 and not z.finished:
      raise newException(ZlibError, "truncated zlib stream")
  result.consumed = inPos

proc inflatePrefix*(src: pointer, srcLen, maxOut: int): string =
  ## Inflate at most `maxOut` bytes and stop; a short result means the stream
  ## ended first.  Used to read a loose object's header without paying for its
  ## body.
  var z = openInflater()
  defer: z.close()
  result = newString(maxOut)
  var inPos = 0
  var outPos = 0
  while outPos < maxOut and not z.finished:
    let p = z.pump(src.offset(inPos), srcLen - inPos,
                   addr result[outPos], maxOut - outPos)
    inPos += p.consumed
    outPos += p.produced
    if p.consumed == 0 and p.produced == 0: break
  result.setLen(outPos)

proc inflateAll*(src: pointer, srcLen: int): string =
  ## Inflate a whole stream of unknown length.
  var z = openInflater()
  defer: z.close()
  var cap = max(srcLen * 4, 4096)
  result = newString(cap)
  var inPos = 0
  var outPos = 0
  while not z.finished:
    if outPos == cap:
      cap *= 2
      result.setLen(cap)
    let p = z.pump(src.offset(inPos), srcLen - inPos,
                   addr result[outPos], cap - outPos)
    inPos += p.consumed
    outPos += p.produced
    if p.consumed == 0 and p.produced == 0:
      raise newException(ZlibError, "truncated zlib stream")
  result.setLen(outPos)

proc deflateAll*(src: pointer, srcLen: int, level: cint): string =
  ## Compress in one shot.  `compress2` uses zlib's defaults for everything but
  ## the level, which is exactly what git does for a loose object.
  var bound = compressBound(culong(srcLen))
  result = newString(int(bound))
  let rc = compress2(cast[ptr byte](addr result[0]), bound,
                     cast[ptr byte](src), culong(srcLen), level)
  if rc != ZOk:
    raise newException(ZlibError, "compress2 failed (" & $rc & ")")
  result.setLen(int(bound))
