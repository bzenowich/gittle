## SHA-1 (RFC 3174).
##
## Every object in a git repository is named by the SHA-1 of its own bytes, so
## this file is the reason gittle and git agree about anything at all.
##
## The algorithm: the message is padded to a multiple of 64 bytes (a `0x80`
## byte, then zeros, then the original length in bits as a big-endian 64-bit
## number), and each 64-byte block is mixed into a five-word state through 80
## rounds.  `update` may be called with any split of the input -- the state is
## the same however the bytes arrive, which is what lets `hashObject` hash a
## header and a payload without joining them into a third copy.
##
## **Decision 5 in plan.md: this is plain SHA-1, not git's sha1dc.** Object IDs
## match git's for identical content, which is all that compatibility requires.
## What is lost is the hardening that detects the known collision-attack
## patterns and refuses: gittle will happily store a collision pair that git
## rejects.  That is acceptable for a local tool and worth remembering if
## gittle ever accepts pushes from strangers.

type
  Sha1Digest* = array[20, byte]

  Sha1Ctx* = object
    h: array[5, uint32]
    buf: array[64, byte]
    used: int      ## bytes currently in `buf`
    total: uint64  ## message length in bytes

func rotl(x: uint32, n: int): uint32 {.inline.} =
  ## Rotate left, the one bit operation SHA-1 needs beyond and/or/xor.
  (x shl uint32(n)) or (x shr uint32(32 - n))

func init*(c: var Sha1Ctx) =
  ## Reset to the five initial words (FIPS 180-1, §6.1).
  c.h = [0x67452301'u32, 0xEFCDAB89'u32, 0x98BADCFE'u32,
         0x10325476'u32, 0xC3D2E1F0'u32]
  c.used = 0
  c.total = 0

func initSha1*(): Sha1Ctx =
  ## A fresh context.
  init(result)

func compress(c: var Sha1Ctx, blk: openArray[byte], off: int) =
  ## One 64-byte block through the 80 rounds.
  var w: array[80, uint32]
  for i in 0 ..< 16:
    let j = off + i * 4
    w[i] = (uint32(blk[j]) shl 24) or (uint32(blk[j+1]) shl 16) or
           (uint32(blk[j+2]) shl 8) or uint32(blk[j+3])
  for i in 16 ..< 80:
    w[i] = rotl(w[i-3] xor w[i-8] xor w[i-14] xor w[i-16], 1)

  var a = c.h[0]
  var b = c.h[1]
  var cc = c.h[2]
  var d = c.h[3]
  var e = c.h[4]

  for i in 0 ..< 80:
    var f, k: uint32
    if i < 20:
      f = (b and cc) or ((not b) and d);       k = 0x5A827999'u32
    elif i < 40:
      f = b xor cc xor d;                      k = 0x6ED9EBA1'u32
    elif i < 60:
      f = (b and cc) or (b and d) or (cc and d); k = 0x8F1BBCDC'u32
    else:
      f = b xor cc xor d;                      k = 0xCA62C1D6'u32
    let t = rotl(a, 5) + f + e + k + w[i]
    e = d
    d = cc
    cc = rotl(b, 30)
    b = a
    a = t

  c.h[0] += a
  c.h[1] += b
  c.h[2] += cc
  c.h[3] += d
  c.h[4] += e

func update*(c: var Sha1Ctx, data: openArray[byte]) =
  ## Absorb `data`.  May be called any number of times with any split.
  c.total += uint64(data.len)
  var i = 0

  # Top up a partial block first.
  if c.used > 0:
    let n = min(64 - c.used, data.len)
    for k in 0 ..< n:
      c.buf[c.used + k] = data[i + k]
    c.used += n
    i += n
    if c.used == 64:
      c.compress(c.buf, 0)
      c.used = 0

  # Then whole blocks straight out of `data`.
  while data.len - i >= 64:
    c.compress(data, i)
    i += 64

  # Keep the remainder.
  for k in i ..< data.len:
    c.buf[c.used] = data[k]
    inc c.used

func update*(c: var Sha1Ctx, s: string) {.inline.} =
  ## Feed bytes; whole blocks are compressed, the tail is kept.
  update(c, s.toOpenArrayByte(0, s.len - 1))

func finish*(c: var Sha1Ctx): Sha1Digest =
  ## Pad and emit the digest.  `c` must not be used again without `init`.
  ##
  ## The padding is a `0x80` byte, then enough zeros to leave exactly eight
  ## bytes free at the end of a block, then the message length in *bits*.  When
  ## fewer than eight bytes are free the padding runs into a second block,
  ## which is why `pad` is 72 bytes rather than 64.
  let bits = c.total * 8
  var pad: array[72, byte]        # 0x80, up to 63 zeros, 8 length bytes
  pad[0] = 0x80
  let padLen = (if c.used < 56: 56 - c.used else: 120 - c.used)
  for i in 0 ..< 8:
    pad[padLen + i] = byte((bits shr uint64(56 - 8 * i)) and 0xFF)
  update(c, pad.toOpenArray(0, padLen + 7))

  for i in 0 ..< 5:
    result[i*4]   = byte(c.h[i] shr 24)
    result[i*4+1] = byte((c.h[i] shr 16) and 0xFF)
    result[i*4+2] = byte((c.h[i] shr 8) and 0xFF)
    result[i*4+3] = byte(c.h[i] and 0xFF)

func sha1*(data: openArray[byte]): Sha1Digest =
  ## The digest of one buffer in a single call.
  var c = initSha1()
  c.update(data)
  c.finish()

func sha1*(s: string): Sha1Digest =
  ## The digest of one buffer in a single call.
  var c = initSha1()
  c.update(s)
  c.finish()
