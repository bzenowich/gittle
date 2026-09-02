## `mv` -- rename a tracked path, on disk and in the index at once.
##
## In scope: `-f`/`--force`, and several sources into an existing directory
## (`mv a b dir/`).  Cut: `-n`, `-v`, `-k`, `--sparse`.
##
## ## It is `rename(2)`, then the same rename over the index entries
##
## The path is renamed on disk, and every index entry equal to the source or
## under `source/` is rewritten to the destination, stat data and all.  That
## is exactly the index `builtin/mv.c` ends up with (`rename_index_entry_at`
## copies the entry and changes its name).  It is deliberately *not* a rename
## followed by `add -A`, for three reasons:
##
## * `add` stages what it finds on disk, so an unstaged edit of the moved file
##   would be staged along with the move; git keeps the old blob staged and
##   the edit unstaged;
## * `rename(2)` carries a directory's untracked files across, and `add`
##   would stage them.  The index has no directories, so git leaves them
##   untracked at the far end;
## * a tracked file moved into an ignored directory stays tracked in git;
##   `add` refuses an ignored path without `-f`.
##
## Rewriting the entries never reads the working tree, so none of the three
## arise.  Of git's eleven refusal checks two protect data and stay: the
## source must be tracked (otherwise there is no entry to rename), and the
## destination must not exist unless `-f`.  The rest are things `rename(2)`
## refuses on its own -- a missing destination directory, a directory moved
## into itself -- and its `errno` is the message.

import std/[algorithm, os, posix, sequtils, strutils]
import ../cli, ../index, ../pathspec, ../repository, ../util

# `rename(2)`.  Nim's `moveFile` refuses a directory and `moveDir` copies
# across filesystems; a rename is what git does and what has to happen
# here, failure included -- "destination directory does not exist" is a
# message the caller is entitled to.
proc rename(oldPath, newPath: cstring): cint {.importc, header: "<stdio.h>".}
  ## `rename(2)`.  Nim's `moveFile` refuses a directory and `moveDir` copies.


const
  synopsis = "[-f] <source>… <destination>"
  options = [
    opt("-f|--force", help = "overwrite an existing destination"),
    opt("-n|--dry-run|-v|--verbose|-k|--sparse", okRefused, help = "docs/minimize.md §3.5"),
  ]

proc cmdMv*(c: Ctx, argv: seq[string]): int =
  ## Entry point: parse, check every move before making any, then rename
  ## on disk and in the index.
  let o = parse(options, argv, "mv", synopsis)
  let force = o.has "force"
  let rest = o.args
  failIf(rest.len < 2, o.use)
  let repo = c.repo
  failIf(repo.workTree.len == 0, "this operation must be run in a work tree")
  let idx = readIndex(repo.indexPath)
  # A working-tree path made absolute.
  proc full(p: string): string = repo.workTreePath(p)
  # Is `p` the directory `dir` or inside it?
  proc under(p, dir: string): bool = p == dir or p.startsWith(dir & "/")

  # Every pair is checked before anything moves, so a refusal leaves both the
  # tree and the index as they were.  A trailing `/` on the destination goes
  # to `rename(2)` and nowhere else: `mv file nosuch/` fails on it, `mv dir
  # newname/` does not, and the index never sees it.
  let dest = inPrefix(rest[^1], repo.prefix)
  let intoDir = dirExists(full(dest))
  let slash = if rest[^1].endsWith("/") and not intoDir: "/" else: ""
  failIf(rest.len > 2 and not intoDir,
         "destination '" & rest[^1] & "' is not a directory")
  var pairs: seq[(string, string)]
  for s in rest[0 ..< ^1]:
    let src = inPrefix(s, repo.prefix)
    let dst = if intoDir: dest / src.lastPathPart else: dest
    failIf(not idx.entries.anyIt(it.path.under(src)),
           "not under version control, source=" & src)
    failIf(not force and statPath(full(dst)).ok,
           "destination exists, source=" & src & ", destination=" & dst)
    pairs.add (src, dst)

  for (src, dst) in pairs:
    failIf(rename(full(src).cstring, (full(dst) & slash).cstring) < 0,
           "renaming '" & src & "' to '" & dst & "' failed: " & $strerror(errno))
    discard idx.removePath(dst)   # whatever `-f` just overwrote
    for e in idx.entries.mitems:
      if e.path.under(src): e.path = dst & e.path[src.len .. ^1]
  idx.entries.sort(cmpEntries)
  idx.writeIndex()
  0
