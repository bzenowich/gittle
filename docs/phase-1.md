# Phase 1 — the object store

The first phase of the build order in [plan.md](plan.md) §7. Ends when
`hash-object` and `cat-file` work and agree with real git byte for byte.

**Status: complete (2026-09-01).** All twelve tasks done; `tests/oracle.sh
--full` passes 36 checks, including every one of the 420,113 objects in the
reference repository read back byte for byte. See [Results](#results).

---

## Environment

Facts a fresh session needs, current as of 2026-09-01.

| | |
|---|---|
| Project root | `/home/bz/code/git/gittle` (its own repo, branch `devel`) |
| **git source, used as the oracle** | `/home/bz/code/git` — a checkout of git `v2.55.0-782-g1630431f32`. Every measurement and citation in `plan.md` comes from this tree. |
| libgit2, for reference | `/home/bz/code/git/libgit2` |
| Real `git` on PATH | yes — this is the oracle binary |
| **Nim toolchain** | **installed** — Nim 2.2.10 (`/home/bz/.choosenim/toolchains/nim-2.2.10`). `nimble` cannot write `~/.nimble`, so builds use `nim c` directly; `gittle.nimble` exists for structure only. |
| zlib headers | present (`/usr/include/zlib.h`), and `libz.a` and `libc.a` are both there, so `-d:static` links |
| `git` on `PATH` | 2.43.0 — *older than the checkout it reads.* Irrelevant to phase 1 (the object and pack formats are unchanged), but worth knowing before trusting it on a newer feature. |

Verify before starting: `nim --version` and `ls /usr/include/zlib.h`.

## Layout as built

Two modules were added to the proposal: `config.nim`, because the extension
gate needs a configuration reader before any command runs, and `cli.nim`, which
holds the driver options and opens the repository lazily (`hash-object` without
`-w` works outside one).

```
src/
  gittle.nim        entry point, argv[0] dispatch (plan.md §6.3)     86
  cli.nim           driver options; the lazily-opened repository     15
  sha1.nim          plain SHA-1 (decision 5)                         91
  zlib.nim          binding to the system zlib (decision 4)         140
  util.nim          errors, atomic writes, exit status                33
  oid.nim           object id type, hex <-> binary, abbreviations     77
  objects.nim       object types; loose read and write; trees        129
  packfile.nim      .idx v2 + .pack reading; delta application       281
  config.nim        the flat INI subset                              138
  repository.nim    discovery, extension gate, object lookup         209
  cmd/
    hashobject.nim                                                    46
    catfile.nim                                                      145
tests/
  oracle.sh         differential tests against real git
  selftest.nim      sha1 and zlib, which have no command in front of them
```

1,390 lines of code (non-comment, non-blank). Against the budget in plan.md §5:
object store 487 of 800, config 138 of 150, support 264 of 400, the extension
gate ~55 of 60. The command layer — the line plan.md says to guard above all
others — is 292 for two commands plus the whole driver.

Build:

```sh
nim c -d:release --out:build/gittle src/gittle.nim            # 309 KiB, links libz
nim c -d:release -d:static --out:build/gittle src/gittle.nim  # 1.0 MiB stripped
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
This is now `tests/oracle.sh`; run it with `--full` to sweep every object
instead of a sample.

The per-object shell loops sketched below are the idea, but two processes per
object times 420k is far too slow to run routinely. `--batch` and
`--batch-check` do the same comparison in one process each, and exercise more
of the code besides.

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

---

## Results

`tests/oracle.sh --full`, 36 checks, all passing, about 70 seconds.

| Check | Coverage |
|---|---|
| SHA-1 | 214 inputs against `sha1sum`, including every block boundary (0, 55–57, 63–65, 119–121 bytes) and adversarial chunk splits |
| zlib | round trips at every size, plus `inflateExact` reporting the exact compressed length with trailing garbage present — the property pack reading depends on |
| `hash-object` | 500 source files, plus 5 awkward inputs (empty, a lone NUL, 4 MiB of random, no trailing newline, binary) times 4 object types |
| `hash-object -w` | the loose files gittle and git write are **byte-identical**, and each tool reads the other's |
| `cat-file --batch-check` | **all 420,113 objects**: type and size identical |
| `cat-file --batch` | **all 420,113 objects**: contents identical, ~3.1 GiB compared by digest |
| `cat-file -t/-s/-e/-p` | 416 objects one at a time; 115 trees pretty-printed, covering modes 040000, 100644, 100755, 120000 and 160000 |
| `cat-file <type>` | assertion and dereference (tag → commit, commit → tree), and a mismatch that must fail |
| abbreviations | 7, 10 and 40 digits resolved out of the pack |
| packs and alternates | blobs read back after `git gc` packs them, and through `objects/info/alternates` |
| extension gate | 10 configurations: reftable, sha256, partialClone, an unknown key and format version 2 all refused; `files`, `sha1`, `worktreeConfig`, `relativeWorktrees` and version 0 all accepted |
| discovery | subdirectory, bare repository, linked worktree (and a subdirectory of one), and a clean refusal outside a repository |

### Two things worth remembering

**A delta base cache is not optional in practice.** The first working version
resolved every delta chain from scratch and ran 20× slower than git on the
blob-heavy part of the pack — 14 seconds per 20k objects. A 64 MiB FIFO cache of
bases, plus writing `applyDelta` into one preallocated buffer instead of
appending a slice per copy instruction, brought that to 1.0 second. The full
sweep went from over two minutes to 23 seconds against git's 19. This does not
violate R3: R3 is about the caches git *writes to disk*, none of which gittle
reads.

**Nim's `quit` clamps the exit status to `int8` on POSIX,** so `quit(128)` exits
127. git uses 128 for a fatal error. `util.exitWith` calls C's `exit` directly.

## Notes carried forward

- **R1 applies from the first line of code.** Read liberally, write minimally,
  write byte-exactly. Object IDs are hashes of exact bytes.
- **Index v4 is read-only** (decision 8) but is a phase 3 concern, not phase 1.
- **Tolerate a zeroed index trailer** (`index.skipHash`) — also phase 3, noted
  here so it is not forgotten.
- Do not implement delta *creation* anywhere. Phase 1 only applies deltas;
  reuse (R2) arrives with pack writing in phase 8.

### Added during phase 1

- **Pack index v1 is refused,** with a message naming `git index-pack` as the
  fix. Git has written v2 by default since 1.6, so this is not the R1 tolerance
  rule being bent — it is a format nothing in the wild produces.
- **`hash-object` reads a whole file into memory.** git streams. It has not
  mattered yet; it will when a repository holds a blob larger than RAM.
- **Object names resolve as object names only** — a full 40-hex name or an
  unambiguous abbreviation of at least four digits. `HEAD`, refs, `^`, `~` and
  `<tree-ish>:<path>` need the ref layer (phase 2) and the revision walk
  (phase 6); until then `cat-file -t HEAD` fails with a clear message.
- **`cat-file --batch=<format>` accepts `%(objectname)`, `%(objecttype)` and
  `%(objectsize)`,** and rejects any other atom rather than printing it
  literally.
