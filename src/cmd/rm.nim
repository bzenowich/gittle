## `rm` -- take paths out of the index, and usually off the disk too.
##
## In scope (docs/08): `<pathspec>…`, `-f`/`--force`, `-n`/`--dry-run`, `-r`,
## `--cached`, `-q`/`--quiet`, `--`.  `--ignore-unmatch`, `--sparse` and the
## `--pathspec-from-file` pair are cut.
##
## ## Almost all of it is the refusal
##
## Removing a file is one call.  What `builtin/rm.c` is actually made of is
## the check that stops it, and the check has three answers because there are
## three ways the content could be lost:
##
## | the index differs from | git says | and the way out is |
## |---|---|---|
## | the file *and* HEAD | staged content different from both | `-f` |
## | HEAD only | changes staged in the index | `--cached` or `-f` |
## | the file only | local modifications | `--cached` or `-f` |
##
## The distinction is not cosmetic: in the middle two rows the content still
## exists somewhere -- in the working file, or in HEAD -- so `--cached` is a
## real answer.  In the first row it exists only in the index, and only `-f`
## will do.
##
## ## `-r` is about the argument, not the files
##
## `gittle rm dir` and `gittle rm 'dir/*'` name the same files, and the first
## is refused without `-r` while the second is not.  What separates them is
## *how* the argument matched -- as a directory prefix, or as a wildcard --
## which is why [pathspec.nim](../pathspec.nim) reports a match kind and not a
## boolean (`dir.c:match_pathspec_item`).

import std/[posix, tables]
import ../cli, ../index, ../pathspec, ../repository, ../util, ../worktree

const usageText = """usage: gittle rm [-f] [-n] [-r] [--cached] [-q] [--] <pathspec>…"""

type Refusal = enum
  ## Which of the three things went wrong, in the order git reports them.
  ## They differ only in their words, so they are a table
  ## (`builtin/rm.c:check_local_mod`).
  rfBoth, rfStaged, rfLocal

const refusalText: array[Refusal, tuple[one, many, hint: string]] = [
  ("the following file has staged content different from both the\n" &
     "file and the HEAD:",
   "the following files have staged content different from both the\n" &
     "file and the HEAD:",
   "\n(use -f to force removal)"),
  ("the following file has changes staged in the index:",
   "the following files have changes staged in the index:",
   "\n(use --cached to keep the file, or -f to force removal)"),
  ("the following file has local modifications:",
   "the following files have local modifications:",
   "\n(use --cached to keep the file, or -f to force removal)")]

proc report(kind: Refusal, files: seq[string]): bool =
  ## git's `print_error_files`: one `error:` per group, the paths indented
  ## under it, then the advice.  Returns whether there was anything to say.
  if files.len == 0: return false
  let (one, many, hint) = refusalText[kind]
  var msg = if files.len == 1: one else: many
  for f in files: msg.add "\n    " & f
  stderr.write "error: " & msg & hint & "\n"
  true

proc cmdRm*(c: Ctx, argv: seq[string]): int =
  let args = expandShortOptions(argv, {})
  var force, dryRun, recursive, cached, quiet = false
  var specs: seq[string]
  var noMoreOpts = false
  for a in args:
    if noMoreOpts or a.len == 0 or a[0] != '-': specs.add a
    elif a == "--": noMoreOpts = true
    elif a == "-f" or a == "--force": force = true
    elif a == "-n" or a == "--dry-run": dryRun = true
    elif a == "-r": recursive = true
    elif a == "--cached": cached = true
    elif a == "-q" or a == "--quiet": quiet = true
    elif a == "-h" or a == "--help": (echo usageText; return 0)
    elif a in ["--ignore-unmatch", "--sparse", "--pathspec-from-file",
               "--pathspec-file-nul"]:
      fail("gittle rm does not support '" & a & "' (docs/08)")
    else: fail("unknown option '" & a & "'\n" & usageText)

  failIf(specs.len == 0, "No pathspec was given. Which files should I remove?")

  let repo = c.repo
  failIf(not cached and repo.workTree.len == 0,
         "this operation must be run in a work tree")
  let ps = parsePathspec(specs, repo.prefix, implicitPrefix = true)
  let idx = readIndex(repo.indexPath)

  var paths: seq[string]          # index order, one entry per stage
  for e in idx.entries:
    if ps.matches(e.path): paths.add e.path

  # Every argument must have named something, and an argument that named a
  # directory must have said `-r`.  Both are fatal before anything is removed.
  let kinds = ps.matchKinds(paths)
  for i in 0 ..< ps.itemCount:
    let raw = ps.itemRaw(i)
    failIf(kinds[i] == pmNone, "pathspec '" & raw & "' did not match any files")
    failIf(not recursive and kinds[i] == pmRecursive,
           "not removing '" & (if raw.len > 0: raw else: ".") &
           "' recursively without -r")

  if not force:
    # Three groups, because there are three different things the user has to
    # be told, and which one appears is what says which mistake was made.
    var head: TreeMap
    let h = repo.refs.resolveRef(headRef)
    if h.found: head = repo.flatten(repo.peelTo(h.oid, otTree).oid)
    var group: array[Refusal, seq[string]]
    var seen: string
    for path in paths:
      if path == seen: continue
      seen = path
      let k = idx.find(path)
      if k < 0: continue              # unmerged: no stage 0, nothing to compare
      let (ok, st) = statPath(repo.workTreePath(path))
      if not ok: continue             # already gone from the working tree
      if S_ISDIR(st.st_mode): continue
      let localChanges = not repo.workingMatches(idx, path)
      let v = idx.versionOf(path)
      let stagedChanges = not head.hasKey(path) or head[path] != v
      if localChanges and stagedChanges: group[rfBoth].add path
      elif not cached:
        if stagedChanges: group[rfStaged].add path
        if localChanges: group[rfLocal].add path
    var errs = false
    for kind in Refusal: errs = report(kind, group[kind]) or errs
    if errs: return 1

  for path in paths:
    if not quiet: echo "rm '" & path & "'"
    discard idx.removePath(path)
  if dryRun: return 0

  if not cached:
    for path in paths: repo.removeWorkingPath(path)
  idx.writeIndex()
  0
