## The structural merge: three trees in, one index out.
##
## `mergefile.nim` merges the *contents* of one path.  This decides, for every
## path in the three trees, whether a content merge is even the question --
## and it is the engine behind `merge`, `cherry-pick`, `revert`, `rebase` and
## `stash apply`, all of which differ only in which three trees they hand it.
##
## ## The rule
##
## Call the three versions of a path *base*, *ours* and *theirs*, where a
## version is a mode and an object ID and "absent" is mode zero.  Then:
##
## | | |
## |---|---|
## | ours == theirs | take it -- the two sides agree, including agreeing it is gone |
## | base == ours | take theirs -- only they touched it |
## | base == theirs | take ours |
## | both changed, both are regular files | **merge the contents** |
## | one side deleted, the other changed it | **modify/delete conflict** |
## | the two sides disagree about the *type* | **distinct-types conflict** |
##
## The first three rows are why a merge is usually silent: almost every path
## in a repository is untouched by at least one side, and a path only one side
## touched has an answer with no reading of content at all.
##
## ## What a conflict actually is, on disk
##
## Not a marker in a file -- that is only what the user sees.  A conflicted
## path is **three index entries**, at stages 1, 2 and 3 (base, ours, theirs),
## where a resolved path has one entry at stage 0.  `commit` refuses while any
## stage-nonzero entry exists, `status` reports them under `Unmerged paths:`,
## and `add`ing the path replaces all three with one, which is what "resolving"
## means.  The conflict-marked file in the working tree is a *convenience*; the
## index is the state.
##
## ## Recursion, and why more than one merge base is not an error
##
## Two branches can have several equally-good common ancestors -- merge one
## into the other and back, and they will.  Picking one arbitrarily gives an
## answer that depends on which, which is how the older `resolve` strategy
## produced spurious conflicts.  git's `ort` instead **merges the merge bases
## with each other**, recursively, and uses the resulting tree as the base
## (`merge-ort.c:merge_ort_internal`).  A conflict inside that inner merge is
## not reported: the conflict markers simply become part of the virtual base's
## content, where they will match neither side and so widen the real conflict.
##
## ## What is cut, and what that costs
##
## **Rename detection** (v2 backlog, plan.md §8).  git notices that ours
## renamed `a` to `b` while theirs edited `a`, and carries the edit across.
## gittle sees a delete and an add, and reports a modify/delete conflict on
## `a`.  This is the single largest behavioral gap in the phase, and it is
## also the reason `merge-ort.c` is 5,600 lines.
##
## Also cut: submodule merging (a gitlink whose two sides differ is simply a
## conflict), `-X ours`/`-X theirs`, and `--allow-unrelated-histories`.

import std/[algorithm, os, sets, tables]
import index, mergefile, objects, oid, repository, revwalk, trees, util, worktree

type
  MergeOpts* = object
    ## What the caller is merging, in the words the conflict markers use.
    ## `git merge topic` labels the sides `HEAD` and `topic`; a cherry-pick
    ## labels them with the two commits' subjects.
    labelOurs*, labelTheirs*: string

  Merged* = object
    ## What the merge decided for one path.
    ##
    ## `version` is the content that goes into the working tree and into a
    ## tree object -- for a conflicted text file, the one with the markers in
    ## it.  `stages` is what goes into the index, and is all-absent when the
    ## path merged cleanly.
    path*: string
    origPath*: string            ## the tree path, when a D/F conflict moved it
    clean*: bool
    version*: Version
    stages*: array[3, Version]   ## base, ours, theirs
    messages*: seq[string]       ## what to print, in git's words

  MergeResult* = object
    paths*: seq[Merged]          ## sorted by path
    conflicts*: int

# Is there a path on this side at all?  A mode of zero is the absence.
func exists(v: Version): bool = v.mode != 0

func isRegular(v: Version): bool = (v.mode and 0o170000'u32) == 0o100000'u32
  ## `S_ISREG`, which is *not* `modeType(...) == otBlob`: a symlink is stored
  ## as a blob too, and an absent version's mode of zero would be one as well.
  ## Only a regular file can be merged line by line.

# ---------------------------------------------------------------------------
# One path
# ---------------------------------------------------------------------------

proc contentMerge(repo: Repository, path: string, b, o, t: Version,
                  opts: MergeOpts): Merged =
  ## `merge-ort.c:handle_content_merge`: both sides changed a regular file.
  result = Merged(path: path, clean: true, stages: [b, o, t])

  # The mode is merged separately from the content, and can conflict on its
  # own: two sides that both made a file executable agree; one that did and
  # one that edited it do not disagree either, because only one side had an
  # opinion.  Anything else is ours, and conflicted.
  if o.mode == t.mode or o.mode == b.mode:
    result.version.mode = t.mode
  else:
    result.version.mode = o.mode
    result.clean = t.mode == b.mode

  # The cheap answers first: two sides that produced the same bytes, or a side
  # that produced the base's bytes, need no merge.
  if o.oid == t.oid or o.oid == b.oid:
    result.version.oid = t.oid
  elif t.oid == b.oid:
    result.version.oid = o.oid
  else:
    # A base of a different type -- absent, or a symlink where both sides now
    # have a file -- is treated as empty, which turns the three-way merge into
    # a two-way one where every line of both sides is an addition.
    let baseText = if b.isRegular: repo.readObject(b.oid).data else: ""
    let ourText = repo.readObject(o.oid).data
    let theirText = repo.readObject(t.oid).data
    if baseText.isBinary or ourText.isBinary or theirText.isBinary:
      # There is no way to interleave two binaries, so git keeps ours and says
      # so.  The path is still conflicted, and the index still gets stages.
      result.messages.add "warning: Cannot merge binary files: " & path &
                          " (" & opts.labelOurs & " vs. " & opts.labelTheirs & ")"
      result.version.oid = o.oid
      result.clean = false
    else:
      let (text, conflicts) = mergeText(baseText, ourText, theirText,
                                        opts.labelOurs, opts.labelTheirs)
      result.version.oid = repo.writeObject(otBlob, text)
      if conflicts > 0: result.clean = false
    result.messages.add "Auto-merging " & path

  if not result.clean:
    # `add/add` names the case where there was nothing to merge against; the
    # user reads it as "these two files were never the same file".
    let reason = if b.exists: "content" else: "add/add"
    result.messages.add "CONFLICT (" & reason & "): Merge conflict in " & path

proc mergePath(repo: Repository, path: string, b, o, t: Version,
               opts: MergeOpts): Merged =
  ## The rule in the module header, in the order the header states it.
  if o == t or b == o or b == t:
    let v = if o == t or b == o: t else: o
    return Merged(path: path, clean: true, version: v)

  if o.exists and t.exists and o.isRegular and t.isRegular:
    return repo.contentMerge(path, b, o, t, opts)

  result = Merged(path: path, clean: false, stages: [b, o, t])
  if o.exists and t.exists:
    # A symlink against a file, or a gitlink against either.  There is no
    # merge to attempt; git renames both aside, gittle keeps ours in place and
    # says which one it kept.
    result.version = o
    result.messages.add "CONFLICT (distinct types): " & path &
                        " had different types on each side; kept the " &
                        opts.labelOurs & " version."
  else:
    # Modify/delete.  The surviving version stays in the tree, because the
    # alternative -- deleting it -- silently discards the change that is the
    # whole reason this is a conflict.
    let ourSide = o.exists
    result.version = if ourSide: o else: t
    let modified = if ourSide: opts.labelOurs else: opts.labelTheirs
    let deleted = if ourSide: opts.labelTheirs else: opts.labelOurs
    result.messages.add "CONFLICT (modify/delete): " & path & " deleted in " &
                        deleted & " and modified in " & modified &
                        ".  Version " & modified & " of " & path &
                        " left in tree."

# ---------------------------------------------------------------------------
# The whole tree
# ---------------------------------------------------------------------------

proc uniquePath(taken: HashSet[string], path, label: string): string =
  ## `merge-ort.c:unique_path`: `<path>~<branch>`, with `_<n>` appended until
  ## nothing is standing there.  The label can be a whole revision expression,
  ## and `/` in it would make a directory, so it is flattened first.
  var suffix = label
  for i in 0 ..< suffix.len:
    if suffix[i] == '/': suffix[i] = '_'
  result = path & "~" & suffix
  var n = 0
  while result in taken:
    inc n
    result = path & "~" & suffix & "_" & $n

proc resolveDirFileConflicts(res: var MergeResult, ours: TreeMap,
                             opts: MergeOpts) =
  ## A path that is a file on one side and a directory on the other.
  ##
  ## The flat path map hides this until the working tree is written, where it
  ## is not a preference but an impossibility: `a` cannot be both a file and
  ## the directory holding `a/b`.  git gives the name to the directory and
  ## moves the file to `a~<branch>` (`merge-ort.c:process_entry`), which is
  ## the only resolution that keeps both contents reachable.
  var dirs: HashSet[string]
  var taken: HashSet[string]
  for m in res.paths:
    if not m.version.exists: continue
    taken.incl m.path
    var d = parentDir(m.path)
    while d.len > 0:
      dirs.incl d
      d = parentDir(d)

  for i in 0 ..< res.paths.len:
    let m = res.paths[i]
    if not m.version.exists or m.path notin dirs: continue
    # Which side contributed the *file*?  The one that has it as a file --
    # equivalently, the one that does not have the directory, which is how git
    # asks it (`process_entry` reads the opposite side's `dirmask`).
    let branch = if ours.hasKey(m.path): opts.labelOurs else: opts.labelTheirs
    let moved = uniquePath(taken, m.path, branch)
    taken.incl moved
    res.paths[i].messages.add "CONFLICT (file/directory): directory in the " &
      "way of " & m.path & " from " & branch & "; moving it to " & moved &
      " instead."
    if res.paths[i].clean:
      res.paths[i].clean = false
      # A clean path becoming conflicted has no stages yet, and the index
      # needs one: the file exists on exactly one side, so that is its stage.
      res.paths[i].stages[if branch == opts.labelOurs: 1 else: 2] =
        res.paths[i].version
    res.paths[i].origPath = m.path
    res.paths[i].path = moved

proc mergeTrees*(repo: Repository, base, ours, theirs: TreeMap,
                 opts: MergeOpts): MergeResult =
  ## Three flattened trees in, a decision per path out.
  var paths: HashSet[string]
  for p in base.keys: paths.incl p
  for p in ours.keys: paths.incl p
  for p in theirs.keys: paths.incl p

  var sorted: seq[string]
  for p in paths: sorted.add p
  sort(sorted)

  for path in sorted:
    let m = repo.mergePath(path, base.getOrDefault(path),
                           ours.getOrDefault(path),
                           theirs.getOrDefault(path), opts)
    result.paths.add m

  result.resolveDirFileConflicts(ours, opts)
  # Counted after the D/F pass, which can turn a clean path into a conflicted
  # one, and re-sorted because it renames paths.
  for m in result.paths:
    if not m.clean: inc result.conflicts
  sort(result.paths, proc (a, b: Merged): int = cmp(a.path, b.path))

proc applyMerge*(repo: Repository, idx: Index, res: MergeResult) =
  ## Write the decision into the index and the working tree.
  ##
  ## A path the merge did not change is left strictly alone -- not rewritten
  ## with identical bytes -- because rewriting it would reset its stat data and
  ## make the next `status` read the whole file back to discover nothing had
  ## happened.
  # Every path a directory/file conflict moved aside is removed *first*, in a
  # pass of its own.  `a` sorts before `a/b`, so doing it inside the main loop
  # would try to create the directory `a` while the file `a` was still there.
  for m in res.paths:
    if m.origPath.len > 0:
      repo.removeWorkingPath(m.origPath)
      discard idx.removePath(m.origPath)

  for m in res.paths:
    if not m.version.exists:
      repo.removeWorkingPath(m.path)
      discard idx.removePath(m.path)
      continue

    if modeType(m.version.mode) != otCommit:      # a gitlink is another repo
      if not (m.clean and repo.upToDate(idx, m.path, m.version)):
        repo.writeWorkingPath(m.path, m.version)

    if m.clean:
      repo.applyToIndex(idx, m.path, m.version)
    else:
      # Three entries, or two, or one: a stage exists only for a side that has
      # the path at all, which is how `ls-files -u` reports a modify/delete.
      var stages: seq[IndexEntry]
      for s in 0 .. 2:
        if not m.stages[s].exists: continue
        var e = IndexEntry(path: m.path, mode: m.stages[s].mode,
                           oid: m.stages[s].oid)
        e.setStage(s + 1)
        stages.add e
      idx.addUnmerged(stages)

proc resultTree(repo: Repository, res: MergeResult): Oid =
  ## The merge as a tree object.  Conflicted paths contribute the content that
  ## has the markers in it, which is exactly what a virtual merge base is
  ## supposed to carry.
  let idx = Index(version: 2)
  for m in res.paths:
    if not m.version.exists: continue
    idx.addEntry IndexEntry(path: m.path, mode: m.version.mode,
                            oid: m.version.oid)
  repo.writeTree(idx)

proc resultTreeMap*(res: MergeResult): TreeMap =
  ## The merge as a flat path map, for the two-way safety check: what the
  ## working tree is about to become.
  for m in res.paths:
    if m.version.exists: result[m.path] = m.version

proc virtualBase*(repo: Repository, ours, theirs: Oid): Oid =
  ## The tree two commits should be merged against.
  ##
  ## Usually just the merge base's tree.  When there are several equally-good
  ## merge bases -- which two branches merged into each other and back will
  ## have -- they are folded into one by merging them pairwise, and *that*
  ## tree is the base (`merge-ort.c:merge_ort_internal`).  The inner merges are
  ## labelled the way git labels them, because a conflict inside one becomes
  ## part of the virtual base and its markers can end up in the user's file.
  var bases = repo.mergeBases(ours, [theirs])
  failIf(bases.len == 0, "refusing to merge unrelated histories")
  reverse(bases)   # `merge-ort.c` folds them youngest-last

  result = repo.peelTo(bases[0], otTree).oid
  var prev = bases[0]
  for k in 1 ..< bases.len:
    # Exactly git for two bases.  For a third and beyond git folds against a
    # *virtual* commit whose parents are the two already folded, so that the
    # next inner base is found from there; gittle uses the last real base
    # instead, because a virtual commit would have to be written to the object
    # store to be walkable.  Three equally-good merge bases is rare enough
    # that this is recorded rather than built.
    let inner = repo.mergeTrees(
      repo.flatten(repo.virtualBase(prev, bases[k])),
      repo.flatten(result),
      repo.flatten(repo.peelTo(bases[k], otTree).oid),
      MergeOpts(labelOurs: "Temporary merge branch 1",
                labelTheirs: "Temporary merge branch 2"))
    result = repo.resultTree(inner)
    prev = bases[k]
