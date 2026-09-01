## Object IDs.  20 raw bytes; hex only at the edges.
##
## R4: one hash.  SHA-1 is the only object format v1 understands, and the
## extension gate in repository.nim refuses a sha256 repository outright, so
## nothing below needs to be parameterised by hash size.


import sha1, util

const
  OidLen* = 20
  OidHexLen* = 40

type
  Oid* = object
    b*: array[OidLen, byte]

  OidPrefix* = object
    ## An abbreviated object name: `nybbles` significant hex digits, held
    ## left-aligned in `b` with the rest zeroed.
    b*: array[OidLen, byte]
    nybbles*: int

const
  nullOid* = Oid()

func isNull*(o: Oid): bool = o == nullOid

func `==`*(a, b: Oid): bool = a.b == b.b

func cmp*(a, b: Oid): int =
  ## Byte order, which is the order the pack index and `packed-refs` use.
  for i in 0 ..< OidLen:
    if a.b[i] != b.b[i]:
      return (if a.b[i] < b.b[i]: -1 else: 1)
  0

func `<`*(a, b: Oid): bool = cmp(a, b) < 0

const hexChars = "0123456789abcdef"

func `$`*(o: Oid): string =
  result = newString(OidHexLen)
  for i in 0 ..< OidLen:
    result[i*2] = hexChars[int(o.b[i] shr 4)]
    result[i*2+1] = hexChars[int(o.b[i] and 0x0F)]

func abbrev*(o: Oid, n: int): string =
  ## The first `n` hex digits, for display.
  ($o)[0 ..< clamp(n, 1, OidHexLen)]

func hexVal(c: char): int {.inline.} =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

func tryParseOid*(s: string, o: var Oid): bool =
  ## Strict: exactly 40 hex digits.
  if s.len != OidHexLen: return false
  for i in 0 ..< OidLen:
    let hi = hexVal(s[i*2])
    let lo = hexVal(s[i*2+1])
    if hi < 0 or lo < 0: return false
    o.b[i] = byte(hi shl 4 or lo)
  true

proc parseOid*(s: string): Oid =
  if not tryParseOid(s, result):
    fail("not a valid object name: " & s)

func tryParsePrefix*(s: string, p: var OidPrefix): bool =
  ## An abbreviation of 1..40 hex digits.  Callers decide the minimum length
  ## they will accept; git's floor is 4.
  if s.len == 0 or s.len > OidHexLen: return false
  for i in 0 ..< s.len:
    let v = hexVal(s[i])
    if v < 0: return false
    if (i and 1) == 0:
      p.b[i div 2] = byte(v shl 4)
    else:
      p.b[i div 2] = p.b[i div 2] or byte(v)
  p.nybbles = s.len
  true

func matches*(p: OidPrefix, o: Oid): bool =
  ## Does `o` begin with the abbreviation?
  let whole = p.nybbles div 2
  for i in 0 ..< whole:
    if p.b[i] != o.b[i]: return false
  if (p.nybbles and 1) != 0:
    if (o.b[whole] and 0xF0'u8) != p.b[whole]: return false
  true

func isFull*(p: OidPrefix): bool = p.nybbles == OidHexLen

func toOid*(p: OidPrefix): Oid =
  ## Only meaningful for a full-length prefix.
  result.b = p.b

func lowerBound*(p: OidPrefix): Oid =
  ## The smallest OID the abbreviation can name; the pack index binary-searches
  ## from here.
  result.b = p.b

func toOid*(d: Sha1Digest): Oid =
  for i in 0 ..< OidLen: result.b[i] = d[i]

func toDigest*(o: Oid): Sha1Digest =
  for i in 0 ..< OidLen: result[i] = o.b[i]

func readOid*(buf: openArray[byte], at: int): Oid =
  ## Pull 20 raw bytes out of a buffer.
  for i in 0 ..< OidLen: result.b[i] = buf[at + i]

func toBytes*(o: Oid): string =
  result = newString(OidLen)
  for i in 0 ..< OidLen: result[i] = char(o.b[i])
