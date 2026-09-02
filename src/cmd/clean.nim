## `clean` -- delete what is in the working tree and in no tree at all.
##
## `-d`, `-f`/`--force`, `-n`/`--dry-run`, `-q`/`--quiet`, `-x`, `--` and
## pathspecs.  `-e`, `-X`, `-i` and `-ff` are cut (docs/minimize.md §3.5).
##
## ## The untracked walk, then unlink
##
## `stash -u` already has the list this command needs: `dir.walkWorkTree`
## returns every untracked, non-ignored *file* under a pathspec, sorted, and
## marks a nested repository as `dir/`.  `clean` over that list is four
## decisions, each about one line:
##
## 1. walk with the ignore files, or with an *empty* ignore list under `-x`.
##    That is what `-x` means -- "there are no ignore files", which is why
##    `builtin/clean.c` skips `setup_standard_excludes` -- and not "delete
##    ignored files too", a reading that only differs once an exclude pattern
##    has to survive it;
## 2. without `-d`, drop every file whose parent directory has nothing tracked
##    under it.  That *is* an untracked directory, which git lists as one
##    entry and then skips (`clean.c`, `S_ISDIR(st.st_mode) &&
##    !remove_directories`); a file whose parent holds something tracked is
##    one git descended to.  A pathspec implies `-d` (`if (argc)
##    remove_directories = 1`);
## 3. skip the nested repositories, as git does without `-ff`
##    (`msg_skip_git_dir`): someone else's history is not this command's;
## 4. unlink each file, then, under `-d`, sweep out every directory that is
##    now empty and has nothing tracked below it.
##
## Step 4 is where git's directory rule comes out for free.  git decides per
## directory whether to name it once (`Removing build/`) or descend and name
## the files -- `DIR_KEEP_UNTRACKED_CONTENTS`, `correct_untracked_entries` --
## and a directory holding an ignored file is never collapsed, so `clean -fd`
## leaves a directory that has `.o` files in it.  Here that directory is
## simply not empty after the unlinks, so its `rmdir` fails, and the failure
## is ignored.  What is lost is the collapsed *report*: gittle prints one line
## per file where git prints the directory.  Stdout is compared for content
## now, not bytes (docs/minimize.md §6); the state on disk is the same.
##
## The sweep is a walk of its own rather than an `rmdir` of each removed
## file's parents because an *empty* untracked directory is not in the file
## walk at all, and `clean -fd` removes those too.  It stops where the file
## walk stopped -- at an ignored directory, at a nested repository (whose own
## `.git` has empty directories in it, `refs/tags` for one), and at anything
## named `.git`, which `dir.c:treat_path` refuses at any depth.  And it
## enters a tracked directory without removing it: `-d` also removes
## `src/scratch/` when `src/` is tracked and `scratch/` is not.

import std/[algorithm, os, posix, strutils]
import ../cli, ../dir, ../ignore, ../index, ../pathspec, ../repository, ../util

proc anyTrackedUnder(idx: Index, dir: string): bool =
  ## Is anything below `dir/` in the index?  The entries are sorted by path,
  ## so the first one at or after `dir/` settles the question.
  let i = idx.entries.lowerBound(dir, proc(e: IndexEntry, d: string): int = cmp(e.path, d))
  i < idx.entries.len and idx.entries[i].path.startsWith(dir)

proc sweep(repo: Repository, idx: Index, ig: Ignore, ps: Pathspec, name: string,
           dryRun, quiet: bool): bool =
  ## Remove every empty untracked directory under `name` ("" for the root),
  ## deepest first, and `name` itself when that empties it.  True when `name`
  ## is gone -- or, dry-running, would be.
  let full = repo.workTree / name
  if name.len > 0 and (ig.isIgnored(name, true) or fileExists(full / ".git") or
                       dirExists(full / ".git")): return false
  result = name.len > 0 and not idx.anyTrackedUnder(name & "/") and ps.matches(name)
  for kind, sub in walkDir(full, relative = true, checkDir = false):
    if kind != pcDir or sub == ".git" or
       not sweep(repo, idx, ig, ps, name / sub, dryRun, quiet): result = false
  result = result and (dryRun or rmdir(cstring(full)) == 0)
  if result and not quiet:
    echo (if dryRun: "Would remove " else: "Removing ") & relativeTo(name, ps.prefix) & "/"

const
  synopsis = "[-d] [-f] [-n] [-q] [-x] [--] [<pathspec>…]"
  options = [
    opt("-f|--force", okCount, help = "actually delete; required unless clean.requireForce is false"),
    opt("-d", help = "recurse into untracked directories"),
    opt("-n|--dry-run", help = "report what would be deleted"),
    opt("-q|--quiet", help = "report only errors"),
    opt("-x", help = "as if there were no ignore files at all"),
    opt("-e|--exclude|-X|-i|--interactive", okRefused, help = "docs/minimize.md §3.5"),
  ]

proc cmdClean*(c: Ctx, argv: seq[string]): int =
  ## Entry point: parse, walk the untracked files, unlink what qualifies,
  ## then sweep the directories that emptied.
  let o = parse(options, argv, "clean", synopsis)
  failIf(o.count("force") > 1, "-ff is cut (docs/minimize.md §3.5)")
  let force = o.has "force"
  var dirs = o.has "d"
  let dryRun = o.has "dry-run"
  let quiet = o.has "quiet"
  let noIgnore = o.has "x"
  let specs = o.args
  let repo = c.repo
  failIf(repo.workTree.len == 0, "this operation must be run in a work tree")
  failIf(repo.cfg.getBool("clean.requireForce", true) and not force and not dryRun,
         "clean.requireForce is true and -f not given: refusing to clean")
  dirs = dirs or specs.len > 0                    # naming a path says what -d says
  let idx = readIndex(repo.indexPath)
  let ig = if noIgnore: newEmptyIgnore(repo) else: newIgnore(repo)
  let ps = parsePathspec(specs, repo.prefix, implicitPrefix = true)
  let verb = if dryRun: "Would remove " else: "Removing "

  for path in walkWorkTree(repo, idx, ig, ps):
    let parent = path[0 .. path.rfind('/')]        # "" at the root
    if path.endsWith("/"):                          # a nested repository
      if dirs and not quiet:
        echo (if dryRun: "Would skip repository " else: "Skipping repository ") &
             relativeTo(path, ps.prefix)
    elif not dirs and parent.len > 0 and not idx.anyTrackedUnder(parent):
      discard                                       # inside an untracked directory
    elif dryRun or tryRemoveFile(repo.workTree / path):
      if not quiet: echo verb & relativeTo(path, ps.prefix)
    else:
      stderr.write "warning: failed to remove " & relativeTo(path, ps.prefix) & "\n"
      result = 1
  if dirs: discard sweep(repo, idx, ig, ps, "", dryRun, quiet)
