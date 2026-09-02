## `worktree` -- a second checkout of the same repository.
##
## In scope (docs/08): `add`, `list`, `move`, `prune`, `remove`, and the
## options `-f`/`--force`, `-b`/`-B`, `-d`/`--detach`, `-q`/`--quiet`.
## `lock`, `unlock`, `repair`, `--porcelain`, `-z`, `--expire`, `--orphan`,
## `--guess-remote`, `--track` and `--relative-paths` are cut.
##
## [worktrees.nim](../worktrees.nim) has the on-disk layout and the reason
## for it; this file is the five verbs over it.
##
## ## `add` is three writes and a checkout
##
## Create the administrative directory, point it and the new working tree at
## each other, write its HEAD -- and then do exactly what `reset --hard`
## does, in the new worktree instead of this one.  git literally runs
## `git reset --hard` as a child process with `GIT_DIR` and `GIT_WORK_TREE`
## set (`builtin/worktree.c:checkout_worktree`); gittle opens a second
## `Repository` on the new directory and calls the same three procs `reset`
## calls, which is the same thing without the fork.
##
## ## Where the branch name comes from
##
## Four arguments' worth of DWIM collapse into one table
## (`builtin/worktree.c:add`):
##
## | given | HEAD becomes | branch created |
## |---|---|---|
## | `add <path>`, basename is a branch | that branch | — |
## | `add <path>`, basename is not | a new branch | named for the basename |
## | `add <path> <branch>` | that branch | — |
## | `add <path> <commit>` | detached | — |
## | `add -b <new> <path> [<start>]` | the new branch | `<new>` from `<start>` |
## | `add --detach <path> [<rev>]` | detached | — |
##
## The one rule underneath is the invariant in `worktrees.nim`: a branch is
## checked out in at most one worktree, so anything that would break that is
## refused unless `-f`.

import std/[os, posix, strutils]
import ../cli, ../config, ../index, ../oid, ../pathspec, ../refs,
       ../repository, ../revision, ../revwalk, ../status, ../util,
       ../worktree, ../worktrees
import ../cmd/branch as cmdbranch

const heads = refsPrefix & "heads/"


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

proc findWorktree(repo: Repository, arg, startDir: string): Worktree =
  ## git accepts either a path or a unique trailing path component, so
  ## `worktree remove wtA` works from anywhere (`worktree.c:find_worktree`).
  let all = repo.allWorktrees
  var hits = 0
  for w in all:
    let start = w.path.len - arg.len
    if arg.len > 0 and start >= 0 and
       (start == 0 or w.path[start - 1] == '/') and w.path[start .. ^1] == arg:
      result = w
      inc hits
  if hits == 1: return
  result = Worktree()
  let want = absolutePath(arg, startDir).normalizedPath
  for w in all:
    if w.path == want: return w

proc linkedWorktree(repo: Repository, arg, startDir: string, force: int,
                    verb: string): Worktree =
  ## The worktree `move` or `remove` was aimed at, with the three refusals
  ## they share: it has to exist, it may not be the main one, and a locked
  ## one takes a second `-f`.
  result = findWorktree(repo, arg, startDir)
  failIf(result.path.len == 0, "'" & arg & "' is not a working tree")
  failIf(result.isMain, "'" & arg & "' is a main working tree")
  failIf(force < 2 and result.locked,
         "cannot " & verb & " a locked working tree;\n" &
         "use '" & verb & " -f -f' to override or unlock first")

proc emptyDir(path: string): bool =
  ## Is the directory empty?
  for _, _ in walkDir(path): return false
  true

proc checkCandidatePath(repo: Repository, path, shown: string, force: int,
                        verb: string) =
  ## Is this a place a worktree can be made?  An existing non-empty directory
  ## is refused outright; a *registered* path whose directory has gone is
  ## refused with the way out named, because clearing it is destructive.
  failIf((fileExists(path) or dirExists(path)) and
         not (dirExists(path) and emptyDir(path)),
         "'" & shown & "' already exists")
  for w in repo.allWorktrees:
    if w.path != path or w.isMain: continue
    if (not w.locked and force >= 1) or (w.locked and force >= 2):
      repo.removeAdminDir(w.id)
      return
    if w.locked:
      fail("'" & shown & "' is a missing but locked worktree;\n" &
           "use '" & verb & " -f -f' to override, or 'unlock' and 'prune' " &
           "or 'remove' to clear")
    fail("'" & shown & "' is a missing but already registered worktree;\n" &
         "use '" & verb & " -f' to override, or 'prune' or 'remove' to clear")

proc openLinked(c: Ctx, admin, path: string): Repository =
  ## A second `Repository` on a linked worktree, for the two commands that
  ## have to act inside one: `add` checks it out and `remove` asks whether it
  ## is clean.  `core.bare` is overridden because the shared configuration may
  ## say the repository is bare and a linked worktree of a bare repository is
  ## not.
  var ov = Config()
  ov.entries.add ConfigEntry(key: "core.bare", value: "false")
  ov.add c.overrides
  openRepository(admin, path, path, false, ov)

proc linkFiles(repo: Repository, admin, path: string) =
  ## The two files that point at each other.  Both hold absolute paths:
  ## `--relative-paths` is cut, and a relative pair would need the
  ## `relativeWorktrees` extension set as well.
  writeFile(path / ".git", "gitdir: " & admin & "\n")
  writeFile(admin / "gitdir", path / ".git" & "\n")

# ---------------------------------------------------------------------------
# add
# ---------------------------------------------------------------------------

proc sanitizeId(name: string): string =
  ## The basename made into a legal refname component
  ## (`refs.c:sanitize_refname_component`): the characters a refname may not
  ## contain are dropped rather than replaced.
  for ch in name:
    if ch in {'\0' .. ' ', '~', '^', ':', '?', '*', '[', '\\', '\x7f'}: continue
    result.add ch
  while result.len > 0 and result[0] == '.': result = result[1 .. ^1]
  if result.endsWith(".lock"): result.setLen(result.len - 5)
  if result.len == 0: result = "worktree"

proc worktreeCheckout(c: Ctx, repo: Repository, admin, path, branch: string,
                      oid: Oid, isBranch: bool) =
  ## Give the new worktree a HEAD and then populate it.  This is what git does
  ## by running `git reset --hard` as a child process with `GIT_DIR` and
  ## `GIT_WORK_TREE` set (`builtin/worktree.c:checkout_worktree`).
  # The new worktree is a repository in its own right from here on: its HEAD,
  # its index and its reflogs are its own, and only the objects and the shared
  # refs come from this one.
  let wt = openLinked(c, admin, path)
  # This first HEAD write is the *parent* repository's, and git makes it from
  # the parent process -- where a bare repository means `core.logAllRefUpdates`
  # is off and no reflog is created.  Everything after it is the new
  # worktree's own, and the new worktree has a working tree, so its updates do
  # log.  Passing the outer policy here is what reproduces that split.
  if isBranch:
    wt.refs.writeSymRef(headRef, heads & branch, noLog = repo.bare)
  else:
    wt.refs.updateRef(headRef, oid, noDeref = true, noLog = repo.bare)

  # What `reset --hard` does, in there rather than here.
  let idx = readIndex(wt.indexPath)
  let tree = wt.flatten(wt.peelTo(oid, otTree).oid)
  wt.refs.updateRef("ORIG_HEAD", oid, noDeref = true)
  wt.resetWorkTree(idx, tree)
  wt.resetIndexTo(idx, tree)
  discard wt.refreshIndex(idx)
  idx.writeIndex()
  wt.refs.updateRef(headRef, oid, msg = "reset: moving to HEAD")

const
  synopsis = "add [-f] [-b <branch> | -B <branch>] [-d] [-q] <path> [<commit-ish>]\nlist\nmove <worktree> <new-path>\nremove [-f] <worktree>\nprune"
  addOptions = [
    opt("-f|--force", okCount, help = "add over a branch another worktree has; -ff over a locked one"),
    opt("-d|--detach", help = "detach HEAD in the new worktree"),
    opt("-q|--quiet", help = "say nothing"),
    opt("-b", okValue, arg = "<branch>", help = "create the branch first"),
    opt("-B", okValue, arg = "<branch>", help = "create or reset the branch first"),
    opt("--orphan|--lock|--reason|--track|--no-track|--guess-remote|--relative-paths|--no-checkout",
        okRefused, help = "docs/08"),
  ]
  forceOption = [opt("-f|--force", okCount, help = "remove even when dirty or locked")]

proc worktreeAdd(c: Ctx, args: seq[string]): int =
  ## `worktree add`: validate the path and the branch, write the admin
  ## directory and the `.git` file, then check the tree out.
  let o = parse(addOptions, args, "worktree", synopsis)
  let force = o.count "force"
  let detach = o.has "detach"
  let quiet = o.has "quiet"
  let newBranch = o.val "b"
  let newBranchForce = o.val "B"
  let rest = o.args
  failIf(int(detach) + int(newBranch.len > 0) + int(newBranchForce.len > 0) > 1,
         "options '-b', '-B', and '--detach' cannot be used together")
  failIf(rest.len < 1 or rest.len > 2, o.use)

  let repo = c.repo
  let path = absolutePath(rest[0], c.startDir).normalizedPath
  # git quotes the path back as it was typed and only resolves it to look the
  # worktree up (`prefix_filename`), so the two forms are carried separately.
  let shown = if isAbsolute(rest[0]): rest[0] else: repo.prefix & rest[0]

  var branch = if rest.len > 1: rest[1] else: headRef
  var creating = newBranch
  if newBranchForce.len > 0:
    creating = newBranchForce
    if force == 0:
      let where = repo.checkedOutAt(heads & newBranchForce)
      failIf(where.len > 0, "'" & newBranchForce &
             "' is already used by worktree at '" & where & "'")
  elif not detach and rest.len < 2 and newBranch.len == 0:
    # No commit-ish and no `-b`: the basename names the branch, existing or
    # about to exist.
    let guess = path.lastPathPart
    if repo.refs.readRef(heads & guess).found: branch = guess
    else: creating = guess

  var oid: Oid
  try: oid = repo.resolveCommittish(branch)
  except GittleError: fail("invalid reference: " & branch)

  if not quiet:
    if newBranchForce.len > 0 and repo.refs.readRef(heads & creating).found:
      stderr.write "Preparing worktree (resetting branch '" & creating &
                   "'; was at " &
                   repo.uniqueAbbrev(repo.refs.readRef(heads & creating).oid,
                                     repo.autoAbbrev) & ")\n"
    elif creating.len > 0:
      stderr.write "Preparing worktree (new branch '" & creating & "')\n"
    elif not detach and repo.refs.readRef(heads & branch).found:
      stderr.write "Preparing worktree (checking out '" & branch & "')\n"
    else:
      stderr.write "Preparing worktree (detached HEAD " &
                   repo.uniqueAbbrev(oid, repo.autoAbbrev) & ")\n"

  if creating.len > 0:
    # git runs `git branch` as a child process here, so a failure to create
    # the branch surfaces as that command's status rather than this one's --
    # `run_command` returning non-zero makes `add` return -1, which is exit
    # 255.  The branch that could not be created is the whole result.
    try:
      cmdbranch.createBranch(c, creating, branch, newBranchForce.len > 0,
                             quiet, false, false)
    except GittleError as e:
      stderr.write "gittle: " & e.msg & "\n"
      return 255
    branch = creating

  # Where git checks it: after the branch has been created, so a failure here
  # leaves the branch behind exactly as git does.
  checkCandidatePath(repo, path, shown, force, "add")

  # A branch, unless the user asked for a detached HEAD or named something
  # that is not one.
  let isBranch = not detach and repo.refs.readRef(heads & branch).found
  if isBranch and force == 0:
    let where = repo.checkedOutAt(heads & branch)
    failIf(where.len > 0, "'" & branch & "' is already used by worktree at '" &
           where & "'")
  oid = repo.resolveCommittish(branch)

  # A number is appended until the name is free; the id is a label, and after
  # a `move` it no longer matches the path at all.
  var id = sanitizeId(path.lastPathPart)
  var n = 0
  while dirExists(repo.adminDir(id)):
    inc n
    id = sanitizeId(path.lastPathPart) & $n
  let admin = repo.adminDir(id)
  createDir(admin)

  # `locked` while the worktree is half-built, so a concurrent `prune` does
  # not collect it; removed on the way out.
  writeFile(admin / "locked", "initializing\n")
  createDir(path)
  linkFiles(repo, admin, path)
  writeFile(admin / "commondir", "../..\n")
  createDir(admin / "refs")

  # From here on the half-built worktree is junk if anything fails: a `locked`
  # file `prune` will not collect, and a `.git` pointing into it.  git guards
  # the same window with an `atexit` handler (`builtin/worktree.c:remove_junk`).
  try:
    worktreeCheckout(c, repo, admin, path, branch, oid, isBranch)
  except CatchableError:
    # Safe to remove outright: `checkCandidatePath` established that the
    # directory was absent or empty, so everything in it now was put there by
    # the lines above.  git removes it the same way.
    try: removeDir(path) except OSError: discard
    try: removeDir(admin) except OSError: discard
    raise

  discard tryRemoveFile(admin / "locked")
  if not quiet: echo repo.headLine(oid)
  0

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

proc worktreeList(c: Ctx, args: seq[string]): int =
  ## `worktree list`: the main worktree first, then each linked one, with
  ## its HEAD and branch.
  discard parse([], args, "worktree", synopsis)
  let repo = c.repo
  let all = repo.allWorktrees

  # Two column widths, both measured over every row first: git aligns the
  # object IDs under each other, and the abbreviation length is whatever the
  # longest one needed.
  var pathWidth = 0
  var abbrevLen = repo.autoAbbrev
  for w in all:
    pathWidth = max(pathWidth, w.path.len)
    if not w.isBare:
      abbrevLen = max(abbrevLen,
                      repo.uniqueAbbrev(w.headOid, repo.autoAbbrev).len)
  for w in all:
    var line = w.path & spaces(1 + pathWidth - w.path.len)
    if w.isBare:
      line.add "(bare)"
    else:
      line.add alignLeft(repo.uniqueAbbrev(w.headOid, repo.autoAbbrev),
                         abbrevLen) & " "
      if w.headRef.len == 0: line.add "(detached HEAD)"
      else: line.add "[" & repo.refs.shortenRef(w.headRef) & "]"
    if w.locked: line.add " locked"
    if not w.isMain and repo.pruneReason(w.id).len > 0: line.add " prunable"
    echo line
  0

# ---------------------------------------------------------------------------
# move, remove, prune
# ---------------------------------------------------------------------------

proc validateWorktree(repo: Repository, w: Worktree, verb: string) =
  ## The `.git` file and the `gitdir` file must still agree.  A worktree
  ## somebody moved with `mv(1)` fails here rather than being half-updated
  ## (`worktree.c:validate_worktree`).  `remove` tolerates the directory
  ## having gone entirely -- clearing up after that is what it is for.
  let dotGit = w.path / ".git"
  let why = "validation failed, cannot " & verb & " working tree: "
  if verb == "remove" and not dirExists(w.path) and not fileExists(w.path):
    return
  failIf(not fileExists(dotGit), why & "'" & dotGit & "' does not exist")
  let text = readWholeFile(dotGit).strip()
  let target = if text.startsWith("gitdir:"): text[7 .. ^1].strip() else: ""
  failIf(target.normalizedPath != repo.adminDir(w.id).normalizedPath,
         why & "'" & w.path & "' does not point back to '" &
         repo.adminDir(w.id) & "'")

# `rename(2)`, for moving a worktree directory in one step.
proc rename(oldPath, newPath: cstring): cint {.importc, header: "<stdio.h>".}

proc forceAndPaths(args: seq[string], want: int):
    tuple[force: int, rest: seq[string]] =
  ## `rename(2)`, for moving a worktree directory in one step.
  let o = parse(forceOption, args, "worktree", synopsis)
  failIf(o.args.len != want, o.use)
  (o.count "force", o.args)

proc worktreeMove(c: Ctx, args: seq[string]): int =
  ## `worktree move`: rename the directory and fix the two files that
  ## point at each other.
  let (force, rest) = forceAndPaths(args, 2)
  let repo = c.repo
  let w = repo.linkedWorktree(rest[0], c.startDir, force, "move")

  var dst = absolutePath(rest[1], c.startDir).normalizedPath
  var shown = if isAbsolute(rest[1]): rest[1] else: repo.prefix & rest[1]
  if dirExists(dst):
    dst = dst / w.path.lastPathPart
    shown = shown / w.path.lastPathPart
  checkCandidatePath(repo, dst, shown, force, "move")
  validateWorktree(repo, w, "move")

  failIf(rename(w.path.cstring, dst.cstring) < 0,
         "failed to move '" & w.path & "' to '" & shown & "': " &
         $strerror(errno))
  linkFiles(repo, repo.adminDir(w.id), dst)
  0

proc worktreeRemove(c: Ctx, args: seq[string]): int =
  ## `worktree remove`: refuse a dirty tree without `-f`, delete the
  ## directory and the admin directory.
  let (force, rest) = forceAndPaths(args, 1)
  let repo = c.repo
  let w = repo.linkedWorktree(rest[0], c.startDir, force, "remove")
  validateWorktree(repo, w, "remove")

  if dirExists(w.path):
    if force == 0:
      # git runs its own `status --porcelain` in there and refuses on any
      # output at all.  Same question, asked in process.
      let other = openLinked(c, repo.adminDir(w.id), w.path)
      let st = computeStatus(other, readIndex(other.indexPath),
                             parsePathspec([]), umNormal)
      failIf(st.entries.len > 0 or st.untracked.len > 0, "'" & rest[0] &
             "' contains modified or untracked files, use --force to delete it")
    try: removeDir(w.path)
    except OSError: fail("failed to delete '" & w.path & "'")
  repo.removeAdminDir(w.id)
  if dirExists(repo.worktreesDir):
    var empty = true
    for _, _ in walkDir(repo.worktreesDir): (empty = false; break)
    if empty:
      try: removeDir(repo.worktreesDir) except OSError: discard
  0

proc cmdWorktree*(c: Ctx, args: seq[string]): int =
  ## Entry point: the sub-verb is the first argument; each has its own
  ## parse.
  let use = usage("worktree", synopsis, [])
  failIf(args.len == 0, use)
  let rest = args[1 .. ^1]
  case args[0]
  of "add": worktreeAdd(c, rest)
  of "list": worktreeList(c, rest)
  of "move": worktreeMove(c, rest)
  of "remove": worktreeRemove(c, rest)
  of "prune":
    failIf(rest.len > 0, use)
    pruneWorktrees(c.repo, dryRun = false, verbose = false)
    0
  of "lock", "unlock", "repair":
    fail("gittle worktree " & args[0] & " is out of scope for v1 (docs/08)")
  of "-h", "--help": (echo use; 0)
  else: fail("unknown subcommand: " & args[0] & "\n" & use)
