# Phase 8 — transport

The eighth phase of the build order in [plan.md](plan.md) §7: pkt-line,
protocol v2 `ls-refs` and `fetch`, `index-pack`, then `clone`/`fetch`/`pull`;
then `pack-objects` and `push`.

**Status: complete (2026-09-02).** `tests/oracle.sh --full` passes 180 checks
across eight phases. See [Results](#results).

---

## What this phase actually is

Six commands, and underneath them one sentence: **a remote is a program with a
pipe on each end.**

```
     ssh host "git-upload-pack '/srv/repo'"        a remote repository
     git-upload-pack /srv/repo                     a local one
```

Those two lines are the same line with a prefix, and that is the whole of
gittle's transport (plan.md R4). It is also what makes the phase testable:
every differential test below runs the real wire protocol against a real
`git-upload-pack`, with no server, no account and no network — because a local
path is not a short cut around the protocol, it is the protocol with the ssh
removed. git arranges it exactly the same way
(`connect.c:git_connect`).

The consequence worth stating: cloning from a *local* path needs
`git-upload-pack` on this machine, because gittle does not serve (plan.md §6
decision 2) and so cannot answer its own request. git avoids that for local
paths by copying the object store instead — its `--local`, on by default —
and gittle does not. A copy would be a second transport, exercised by none of
the protocol tests, for the case where two repositories sit on one disk.
`docs/12` said "a direct object-store copy for local paths"; this phase
decided against it, and that is the one scope line the phase changed.

## The version is not ours to choose

A protocol v2 request is made by putting `GIT_PROTOCOL=version=2` in the
server's environment — over ssh, by asking the ssh client to forward it with
`-o SendEnv=GIT_PROTOCOL`. An `sshd` whose `AcceptEnv` does not list
`GIT_PROTOCOL` drops it, the server answers in v0, and a client that cannot
read v0 is a client that fails against an ordinary `sshd`. So both are
implemented, and they differ less than they look:

| | v0 | v2 |
|---|---|---|
| the server's first words | every ref, capabilities on line one | `version 2` and its capabilities |
| listing refs | already done, and unfiltered | an `ls-refs` request, with prefixes |
| asking for objects | `want`/`have` lines, then `done` | `command=fetch`, the same lines inside |
| pushing | `<old> <new> <ref>` lines, then a pack | the same: `receive-pack` has no v2 |

Push is v0 in both columns because git's `receive-pack` has no v2 form at all
— `gitprotocol-v2.adoc` defines exactly two commands, `ls-refs` and `fetch`.
The version is negotiated and then the older protocol is spoken anyway.

The v0 fallback is 40 lines and it found a bug the v2 path could not: the
acknowledgement section has **no marker before the packfile**. There may be
any number of `ACK <oid>` lines and then the first side-band packet, so a
reader that consumes "one ACK or a NAK" and then starts demultiplexing throws
`unknown side band 65` — the `A` of the second `ACK`. The loop reads packets
rather than lines and hands the first non-acknowledgement to the side-band
handler itself.

## Negotiation, in one round

The client says which objects it *wants* and which it already *has*; the
server sends the difference. git plays this over several round trips,
offering sixteen commits at a time and refining on the acknowledgements.
gittle sends one round — up to 256 commits, the tips of every local ref — and
then `done`, which tells the server to compute the pack from what it has been
given rather than wait for more. One round is what makes an incremental fetch
cheap; further rounds only shave the tail, and each costs a round trip.

## index-pack is the security surface

It is the one place gittle takes bytes from someone else. The server is cut,
so gittle never accepts a *push* — but a *fetch* is a packfile from the far
end all the same, and a hostile or broken server is as real as a hostile
client. Three checks, in this order, and nothing is installed until all three
pass:

1. **The pack checksum** — the trailing 20 bytes are SHA-1 over everything
   before them. Cheap, and it catches truncation and corruption in transit.
2. **Every object's own hash** — each object's name is *computed* from the
   bytes that arrived, never taken from the sender. A delta that reconstructs
   to different content than the sender intended gets a different name, and
   nothing that referred to the intended one will find it.
3. **Connectivity** — every object the received commits and trees refer to has
   to be present, here or already in the repository. Without it a server could
   hand over a commit whose tree is absent, and the ref would be updated to
   name a history that cannot be read. git runs the same walk
   (`connected.c:check_connected`).

Only then do any refs move, and they move in one transaction.

The `.idx` a pack produces is a pure function of the pack, so it can be
compared byte for byte with git's — object order, CRCs, fan-out and both
trailing hashes. **It is identical over all 420,113 objects of the reference
repository**, a 318 MiB pack, in 60 seconds.

### Thin packs

A sender that knows what the receiver already has may leave the base of a
delta *out* of the pack; that is what the `thin-pack` capability negotiates,
and it is most of why an incremental fetch is small. Such a pack cannot stand
on its own, so `--fix-thin` completes it: the missing bases are appended as
ordinary objects, the object count in the header is corrected, and the
trailing checksum is recomputed (`builtin/index-pack.c:fix_unresolved_deltas`).
What lands on disk is always self-contained.

## R2, on the writing side, measured again

plan.md §3.1 measured what delta *search* is worth: on the repository next
door git's pack is 304 MiB, the same objects with no deltas at all are
3,122 MiB, and the same objects with existing deltas copied through and no
similarity search are 309 MiB. Delta search buys 1.6%, and costs
`diff-delta.c` plus the window and depth machinery in `pack-objects.c`.

So `packwrite.nim` is 54 lines. An object already stored as a delta in a local
pack, whose base is also going out, is copied across still compressed and
still a delta; everything else is written whole. The one piece of bookkeeping
is that an `OBJ_OFS_DELTA` names its base by distance backwards *in this
pack*, so a copied delta is re-headed with the new distance and its base is
emitted first.

The test measures it rather than asserting it: packing two thousand commits of
the reference repository's history reuses **28,284 deltas**, and git reads the
result.

## Tags follow, they are not fetched

The default refspec covers `refs/heads/*` and nothing else, yet a plain
`git fetch` brings tags with it. The mechanism is not a second refspec: it is
the `include-tag` capability, which asks the server to put any annotated tag
*pointing into the history being sent* into the pack. Afterwards, a remote tag
whose object is now here and whose name is not becomes a local tag. That is
why `--tags` is different rather than redundant: it fetches every tag,
reachable or not.

And it is why `gittle fetch origin main` follows no tags at all: git turns tag
following on only when some refspec had a *destination*, and a bare `main`
writes no ref (`builtin/fetch.c:get_ref_map`, `*autotags`).

## What a fetch report costs

The five lines a fetch prints are the fiddliest thing in the phase, and every
detail of them is in `builtin/fetch.c` rather than in any document:

* the first column is `2 * <abbreviation length> + 3` wide, measured over
  every object either end mentions — so one long abbreviation widens the whole
  report;
* the second is at least ten wide, measured over the *remote* names, skipping
  the ones that are up to date, the ones that update no ref, and any line
  whose total would reach the terminal width;
* …and if **anything was refused**, the first column has no width at all,
  because git computes it after the ref transaction and jumps over that line
  on the way to reporting the failure. Reproducing that means buffering the
  report until every ref has been decided, which is what git does too.

Four of the phase's bugs were in those three rules and nowhere else.

## The rules a fetch and a push actually enforce

Neither end is trusted to decide; the client decides and the server obeys or
refuses on its own account.

| | fetch | push |
|---|---|---|
| remote-tracking ref rewound | reported as `+ … (forced update)` — it is a record of what the remote said | — |
| local branch behind | fast-forward | — |
| local branch diverged | `[rejected] non-fast-forward` unless `+`/`--force` | `[rejected] non-fast-forward` unless `--force` |
| the other end moved since we looked | — | `[rejected] stale info`, with `--force-with-lease` |
| we do not have the other end's tip | — | `[rejected] fetch first` |
| a tag that already exists | `[rejected] would clobber existing tag` unless `--force` | `[rejected] already exists` |

`--force-with-lease` compares the remote's advertised value against **this
repository's remote-tracking ref**, so a `fetch` in between defeats it —
exactly as in git, and worth knowing before relying on it.

## What the oracle found

Nine bugs, and the shape of them is worth recording: **one was in an
algorithm and eight were in agreeing with git.**

1. **The pack cache was never reloaded.** `Repository` opens the packs once
   and remembers them, which is right for a process that reads. `fetch` is
   the one that *adds* a pack mid-run — and it has already called
   `hasObject` to work out what to want, so the cache was closed before the
   pack existed and every object that had just arrived was invisible. The
   symptom was the connectivity check on a first clone complaining that the
   remote had not sent what it plainly had.
2. **The v0 acknowledgement section has no end marker.** There may be any
   number of `ACK <oid>` lines and then, with nothing in between, the first
   side-band packet. A reader that consumes one acknowledgement and starts
   demultiplexing reports `unknown side band 65` — the `A` of the second
   `ACK`.
3. **`--prune` deleted `refs/remotes/origin/HEAD`.** It is a symbolic ref
   naming the remote's default branch, not a copy of one of its refs, so
   nothing upstream corresponds to it and every prune removed it.
4. **`FETCH_HEAD` is emptied at the start of a fetch, not written at the
   end.** A fetch that fails therefore leaves an *empty* one, and a `pull`
   after a failure merges nothing rather than the previous fetch's answer.
5. **`--tags` does not carry a `+`.** Its refspec is
   `refs/tags/*:refs/tags/*`, so even `--tags` refuses to move a tag that
   already exists here.
6. **`fetch origin main` follows no tags at all**, because tag following is
   switched on by a refspec having a *destination*, and a bare name has none.
7. **Three rules in the report**, none of them documented anywhere but
   `builtin/fetch.c`: opportunistic remote-tracking updates print *after* the
   followed tags; a fetch that writes no ref still prints
   `* branch main -> FETCH_HEAD`; and if anything was refused the summary
   column has no width at all.
8. **A checkout wrote no directory for a gitlink** — a phase 6 bug that only
   became reachable now, because cloning a repository with a submodule in it
   is what finds it. git creates an empty directory to stand in for the
   submodule (`entry.c:write_entry`, `case S_IFGITLINK`); without it the very
   first `status` after a clone reports the submodule as deleted. Cloning
   the reference repository, which has one, is what showed it.
9. And two in the *tests themselves*. A packfile is created read-only, so
   the `dd` that was supposed to corrupt one for the "this must be refused"
   check silently did nothing and the check passed for the wrong reason; it
   now compares the file with the original first. And the `--date=relative`
   comparison was a comparison of *when the two programs ran* — one of them
   eventually lands on the far side of a "5 months ago" boundary — so "now"
   is pinned with `GIT_TEST_DATE_NOW`, which git already honours
   (`date.c:get_time`) and gittle now does too. A test that passes because
   nothing happened, and a test that fails for no reason, are the two failure
   modes worth naming.

## Results

`tests/oracle.sh --full`, 180 checks across eight phases, all passing.

| Check | Coverage |
|---|---|
| `ls-remote` | 12 forms, over protocol v2 **and** v0, including an empty repository |
| `clone` | 14 clones — bare, `-n`, `-b <branch>`, `-o`, an empty source, a v0 server, a plain path, a repository with a submodule — each compared *whole* against git's |
| `fetch` | 19 fetches: new branches, new tags, a rewind, `--prune`, `--tags`, `--no-tags`, five refspec forms, a bare URL, a tag clobber refused and then forced, and a second fetch that has nothing to say |
| `push` | 19 pushes: new branch, fast-forward, rewind refused and then forced, `--force-with-lease` holding and stale, two deletion spellings, `--tags`, `-u`, `-n`, a pattern refspec, and `Everything up-to-date` |
| `pull` | 7 pulls, merged and rebased, including the divergence git refuses to resolve for you |
| `remote` | 9 subcommand forms, including the three that must fail with git's own status |
| `index-pack` | every pack in the fixture **and the reference repository's own 318 MiB one**, byte-identical `.idx`; a truncated pack and a corrupted one refused |
| `pack-objects` | the object set matches `rev-list --objects`, git verifies the pack, and 28,284 deltas are reused |
| `git fsck --strict` | clean after a gittle clone, a gittle fetch, and on the **server** after a gittle push |

### The end-to-end one

`gittle clone file:///path/to/git.git` — the reference repository itself,
**408,115 objects**, 305 MiB of pack, in 80 seconds. What it produces:

* `git status` in it is **clean**, including the empty directory where the
  `sha1collisiondetection` gitlink is (bug 8 above);
* `git fsck --strict` says **exactly what it says about git's own clone of
  the same repository** — 99 lines of warnings about a tag with no tagger and
  trees with bad file modes, all of them objects from 2005 that gittle copied
  across faithfully;
* and of the four thousand files in the working tree, **three differ from
  git's own clone** — `compat/vcbuild/*.bat`, which `.gitattributes` marks
  `eol=crlf`. They are byte-identical once the carriage returns are removed.
  That is plan.md decision 6 (Linux only, no gitattributes) showing up
  exactly where it was said it would, and `git status` does not report them
  because git normalises on the way in.

### How both ends are tested

Phase 6's rule — run the command in two identical copies and compare
everything either tool could have written — needs a second copy of something
else here, because half of what a push writes is on a machine that is not
this one. `p8mut` therefore keeps **two servers as well as two clients**:

* two bare copies of the source repository, one for git and one for gittle,
  with each client's `remote.origin.url` pointed at its own;
* the command run in each;
* and then `p6state` over all four, so a push that prints the right thing and
  leaves the wrong ref on the far side is caught by the far side.

`p6state` grew `FETCH_HEAD` and learned to read a bare repository. `p8clone`
is the same idea for `clone`, which has no fixture to start from: both tools
clone the same source into two directories and the two results are compared
entire — refs, HEAD, config, every reflog, every file, and the index.

## Layout as built

```
src/
  pktline.nim     the framing, and the side band                          84
  transport.nim   URLs, the child process, v2 and v0                     318
  indexpack.nim   check a pack, resolve its deltas, write the .idx       273
  packwrite.nim   write one, reusing the deltas we were given             54
  refspec.nim     [+]<src>:<dst>, and what it maps to                     47
  remotes.nim     the ref map, the pack, and the report                  335
  cmd/
    clone.nim                                                            162
    fetch.nim                                                             63
    pull.nim                                                              76
    push.nim                                                             282
    remote.nim                                                            77
    lsremote.nim                                                          67
    indexpack.nim                                                         68
    packobjects.nim                                                       65
```

The minimisation pass moved four things and un-exported four:

* **`readEntryAt` and `inflateEntryAt` came out of `packfile.nim`'s `Pack`.**
  `index-pack` has to read exactly those headers out of a pack that has no
  index yet — that being what it is about to write — so the two readers now
  take the mapping rather than a `Pack`, and `Pack`'s own methods call them.
* **`collectTree`, `walkObjects` and `edgeTrees` came out of `rev-list`.**
  `pack-objects` and `push` ask the same question it does, and `objectsBetween`
  is now the one place that answers it. `rev-list --objects` lost 20 lines.
* **`prettify` and `summaryColumn` came out of `push`**, which had copies of
  `fetch`'s.
* **`installPack` is now what `index-pack --stdin` uses too**, so the rule for
  where a received pack lands and what it is called is written once.

And one thing was *added* to a module this phase does not own: `worktree.nim`
now creates a directory for a gitlink instead of skipping it, which is bug 8
above.

## Budget

```
                                          budgeted   actual
wire protocol v2 over ssh                      700      402   pktline 84 + transport 318
pack write + delta reuse                       500      327   packwrite 54 + indexpack 273
refspecs and the fetch engine                  ---      382   refspec 47 + remotes 335
the phase's 8 commands                         ---      860   clone, fetch, pull, push, remote, ls-remote, index-pack, pack-objects
everything else (18 files touched)             ---      123   revwalk +46, packfile +41, the driver +19, rev-list -20, worktree +6, util +11, and a dozen one-liners
                                                    -------
phase 8                                                2,094
```

Total: **12,852 lines of code** (20,502 including comments), against the
~13,000 [plan.md](plan.md) §5.2 projects for v1 with phase 10 still to build.
The static binary is 3.3 MB.

Both algorithm lines came in **under**, and for the same reason each time:
the protocol is small once you stop implementing the parts that are
negotiable, and R2 means the packer has no search in it. The 700 for the wire
assumed a v0/v2 pair costing twice; it does not, because the two differ only
in how the same want/have exchange is framed.

The line §5 does not model is again the one that over-ran, and again it is not
option surface. `push` (282) is the largest file in the phase and its options
are eight flags; what it is full of is **the six ways a ref update can be
refused** and the six paragraphs of advice git prints for them. `remotes.nim`
(335) is mostly the ref map — the rules by which a refspec, a command-line
argument and a configured default combine — and the report's two column
widths. Neither is a state machine of the kind phase 7 warned about; both are
*compatibility surface*, which is the third thing that costs, after option
combinations and state.

Against §5.2's estimate of 1,000 more for the command layer across phases 8
and 10: eight of the fifteen remaining commands have now cost 860.  The seven
left are `gc`, `worktree`, `clean`, `check-ignore`, `mv`, `rm` and `stage`
(which is `add` under another name), and they are mostly small.
**Unrevised: v1 lands near 13,000**, which is where §5.2 put it.

## What was left undone, and where it belongs

| | |
|---|---|
| shallow and partial clone — `--depth`, `--filter`, promisor remotes | **out of v1 by decision** (plan.md §1 non-goals). The extension gate already refuses a partial-clone repository. |
| `--all`, `--multiple`, groups, `--atomic`, `--porcelain`, `--dry-run` for `fetch` | docs/05 cuts them |
| `--mirror`, `--single-branch`, `--reference`, `--separate-git-dir`, `--template`, submodules for `clone` | docs/06 |
| `--all`, `--mirror`, `--prune`, `--atomic`, `--porcelain`, `--follow-tags`, push options and signing for `push` | docs/08 |
| CRLF, and `.gitattributes` generally — `eol=crlf`, `text=auto`, filters | **out of v1 by decision** (plan.md decision 6). Visible for the first time this phase: a clone of the git repository differs from git's in three `*.bat` files and nothing else. |
| `--thin` on the *writing* side: gittle always sends a complete pack | docs/10. It costs a push of new work a little size and nothing else; `--fix-thin` on the reading side is implemented, because a fetch needs it. |
| `remote rename`, `set-head`, `set-branches`, `show`, `prune`, `update` | docs/11 |
| `unpack-objects`, and with it `fetch.unpackLimit` | docs/01 cuts it. git explodes a small fetched pack into loose objects; gittle always keeps the pack, which `gc` (phase 10) will fold in. |
| `--refmap`, negative refspecs (`^refs/heads/wip`) | docs/05; nothing in v1 needs either |
| multi-round negotiation | v2 backlog. One round is what makes an incremental fetch cheap; further rounds shave the tail. |
| `.rev` reverse indexes, bitmaps, multi-pack indexes | R3: caches git writes and gittle declines to read |
| `gc`, `worktree`, `clean`, `check-ignore` | phase 10, the last one |
