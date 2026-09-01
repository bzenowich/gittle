# Phase 1 — the object store

The first phase of the build order in [plan.md](plan.md) §7. Ends when
`hash-object` and `cat-file` work and agree with real git byte for byte.

---

## Environment

Facts a fresh session needs, current as of 2026-09-01.

| | |
|---|---|
| Project root | `/home/bz/code/git/gittle` (its own repo, branch `devel`) |
| **git source, used as the oracle** | `/home/bz/code/git` — a checkout of git `v2.55.0-782-g1630431f32`. Every measurement and citation in `plan.md` comes from this tree. |
| libgit2, for reference | `/home/bz/code/git/libgit2` |
| Real `git` on PATH | yes — this is the oracle binary |
| **Nim toolchain** | **NOT INSTALLED.** Blocked phase 1 in the previous session; the sandbox had no network to install it. |
| zlib headers | present (`/usr/include/zlib.h`) — R2 links the system zlib |

Verify before starting: `nim --version` and `ls /usr/include/zlib.h`.

## Proposed layout

Not yet created; nothing depends on it, so change it freely.

```
src/
  gittle.nim        entry point, argv[0] dispatch (plan.md §6.3)
  sha1.nim          plain SHA-1, ~150 lines (decision 5)
  zlib.nim          binding to the system zlib
  oid.nim           object id type, hex <-> binary
  objects.nim       object types; loose read and write
  packfile.nim      .idx v2 + .pack reading; delta application
  repository.nim    discovery, config subset, extension gate (plan.md §6.1)
  cmd/
    hashobject.nim
    catfile.nim
tests/
  oracle.sh         differential tests against real git
```

## Task list

Ordered so each step is verifiable before the next depends on it.

1. **Skeleton.** `gittle.nimble`, `src/gittle.nim`, `argv[0]` dispatch, a
   `version` verb. Build a static binary.
2. **SHA-1.** Plain implementation. *Verify against `sha1sum` on random inputs.*
3. **zlib.** Bind `inflate`/`deflate` against the system library. Streaming, not
   whole-buffer — pack objects are read incrementally.
4. **OID type.** 20-byte binary, hex parse and format, comparison, abbreviation.
5. **Loose object read.** Path from OID (`objects/ab/cdef…`), inflate, parse the
   `"<type> <size>\0"` header, return type + payload.
6. **Loose object write.** Frame the header, deflate, write via a temp file plus
   rename. *This is where R1 bites: the framing must be byte-exact or the OID
   will not match git's.*
7. **`hash-object`.** `-t`, `-w`, `--stdin`, `<file>…`. *Oracle: gittle and git
   produce identical OIDs for the same input, and `git cat-file -p` reads back
   what gittle wrote with `-w`.*
8. **Pack index read.** `.idx` v2: magic, version, 256-entry fanout, sorted OID
   table, CRC table, 4-byte offsets, 8-byte large offsets. Binary search by OID.
9. **Pack read.** Header, per-object type + size varint, the six object types
   including `OBJ_OFS_DELTA` and `OBJ_REF_DELTA`.
10. **Delta application.** Base size, result size, then copy and insert
    instructions. ~94 lines of C upstream (`patch-delta.c`) — the reference is
    right there in the oracle tree.
11. **Repository discovery + extension gate.** Walk up for `.git`, read the
    config subset, apply the gate from plan.md §6.1. *Refuse reftable cleanly.*
12. **`cat-file`.** `-t`, `-s`, `-e`, `-p`, `<type> <object>`, `--batch`,
    `--batch-check`. *Oracle: identical output to git's for every object in the
    git repository next door.*

## The oracle procedure

Phase 1's whole value is that correctness is mechanically checkable. The git
repository next door has 420,113 objects of every type, including deltas 50 deep.

```sh
# every object, both directions
git -C /home/bz/code/git rev-list --objects --all | awk '{print $1}' > /tmp/oids

# type and size must match for all 420k
while read oid; do
  a=$(git -C /home/bz/code/git cat-file -t "$oid")
  b=$(gittle -C /home/bz/code/git cat-file -t "$oid")
  [ "$a" = "$b" ] || echo "TYPE MISMATCH $oid: git=$a gittle=$b"
done < /tmp/oids

# content must match byte for byte
while read oid; do
  cmp <(git -C /home/bz/code/git cat-file -p "$oid") \
      <(gittle -C /home/bz/code/git cat-file -p "$oid") \
    || echo "CONTENT MISMATCH $oid"
done < /tmp/oids

# and the write side: gittle's hash must equal git's
for f in $(find /home/bz/code/git -name '*.c' | head -500); do
  a=$(git hash-object "$f"); b=$(gittle hash-object "$f")
  [ "$a" = "$b" ] || echo "HASH MISMATCH $f"
done
```

Run the full sweep before declaring phase 1 done. A format bug found in phase 1
is cheap; the same bug found in phase 8 is not.

## Notes carried forward

- **R1 applies from the first line of code.** Read liberally, write minimally,
  write byte-exactly. Object IDs are hashes of exact bytes.
- **Index v4 is read-only** (decision 8) but is a phase 3 concern, not phase 1.
- **Tolerate a zeroed index trailer** (`index.skipHash`) — also phase 3, noted
  here so it is not forgotten.
- Do not implement delta *creation* anywhere. Phase 1 only applies deltas;
  reuse (R2) arrives with pack writing in phase 8.
