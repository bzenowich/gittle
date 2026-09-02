## `pull` -- fetch, then integrate.
##
## In scope (docs/08): `<repository>`, `<refspec>`, `-r`/`--rebase`,
## `--no-rebase`, `-q`, `-v`.
##
## It is glue and nothing else: [fetch](fetch.nim) does the transfer, and
## then either [merge](merge.nim) or [rebase](rebase.nim) does the rest.  The
## only decision of its own is *what to integrate*, and that is the ref the
## fetch just marked as the merge candidate -- the current branch's upstream,
## or, when refspecs were given on the command line, the first thing they
## fetched.  git reads it back out of `FETCH_HEAD`; so does this, for the same
## reason it writes one at all: `FETCH_HEAD` is the interface, and a `pull`
## that used a private channel would stop agreeing with `gittle merge
## FETCH_HEAD`.

import std/[os, strutils]
import ../cli, ../oid, ../remotes, ../repository, ../revision,
       ../revwalk, ../util
import fetch as cmdfetch
import merge as cmdmerge
import rebase as cmdrebase

const usageText = """usage: gittle pull [<options>] [<repository> [<refspec>…]]

   -r, --rebase          rebase the current branch onto the upstream instead
                         of merging
   --no-rebase           merge (the default)
   -q, --quiet           report nothing but errors
   -v, --verbose         report more"""

proc mergeCandidates(repo: Repository): seq[string] =
  ## The `FETCH_HEAD` lines *not* marked `not-for-merge`, in order.
  let path = repo.gitDir / "FETCH_HEAD"
  if not fileExists(path): return
  for line in readWholeFile(path).splitLines():
    if line.len == 0: continue
    let parts = line.split('\t')
    if parts.len < 2 or parts[1] == "not-for-merge": continue
    result.add parts[0]

proc cmdPull*(c: Ctx, args: seq[string]): int =
  # `pull.rebase` sets the default; the options below override it either way.
  # Whether it was *specified at all* matters as much as its value -- see the
  # divergence check below.
  let configured = c.repo.cfg.has("pull.rebase")
  var rebase = c.repo.cfg.getBool("pull.rebase", false)
  var chosen = configured
  var opt = FetchOpts(reflogAction: ("pull " & args.join(" ")).strip())
  var passthrough: seq[string]
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "-r", "--rebase", "--rebase=true": (rebase = true; chosen = true)
    of "--no-rebase", "--rebase=false": (rebase = false; chosen = true)
    of "-h", "--help": (echo usageText; return 0)
    of "--ff-only", "--squash", "--autostash", "--no-ff", "--ff",
       "--rebase=merges", "--rebase=interactive", "-i":
      fail(a & " is out of scope for gittle v1 (docs/05, docs/08)")
    else: passthrough.add a
    inc i

  let positional = cmdfetch.parseFetchArgs(passthrough, opt)
  if positional == @["--help"]: return 0
  c.reflogAction = opt.reflogAction
  failIf(cmdfetch.runFetch(c, positional, opt).failed,
         "some refs could not be updated")

  let repo = c.repo
  let candidates = mergeCandidates(repo)
  failIf(candidates.len == 0,
         "There is no candidate for merging in FETCH_HEAD.\n" &
         "  You asked to pull from the remote, but did not specify a branch,\n" &
         "  and this branch has no upstream configured.")
  # **Divergence.**  When the fetched tip is neither behind nor ahead, merging
  # and rebasing give different histories and git refuses to pick for you
  # (`builtin/pull.c`: "Need to specify how to reconcile divergent branches").
  # The check is skipped entirely when the answer was given, however it was
  # given.
  if not chosen:
    let head = c.repo.refs.resolveRef(headRef)
    if head.oid != nullOid and candidates.len == 1:
      let other = c.repo.resolveRevish(candidates[0])
      if not c.repo.isAncestor(head.oid, other) and
         not c.repo.isAncestor(other, head.oid):
        stderr.write "hint: You have divergent branches and need to specify " &
          "how to reconcile them.\n" &
          "hint: You can do so by running one of the following commands " &
          "sometime before\nhint: your next pull:\n" &
          "hint:\nhint:   gittle config pull.rebase false  # merge\n" &
          "hint:   gittle config pull.rebase true   # rebase\n" &
          "hint:   gittle config pull.ff only       # fast-forward only\n" &
          "hint:\nhint: You can replace \"gittle config\" with " &
          "\"gittle config --global\" to set a default\n" &
          "hint: preference for all repositories. You can also pass " &
          "--rebase, --no-rebase,\nhint: or --ff-only on the command line to " &
          "override the configured default per\nhint: invocation.\n"
        fail("Need to specify how to reconcile divergent branches.")

  # `--rebase` with nothing of our own to replay is a fast-forward, and git
  # runs the merge for it rather than the rebase (`builtin/pull.c`: "if
  # (can_ff) ... run_merge()").  The visible difference is the output and the
  # reflog line, but the reason is that a rebase of no commits would still
  # detach HEAD and put it back.
  if rebase and not (candidates.len == 1 and
                     c.repo.isAncestor(c.repo.refs.resolveRef(headRef).oid,
                                       c.repo.resolveRevish(candidates[0]))):
    failIf(candidates.len > 1, "cannot rebase onto several commits at once")
    return cmdrebase.cmdRebase(c, candidates)
  var mergeArgs = candidates
  if opt.quiet: mergeArgs.add "-q"
  cmdmerge.cmdMerge(c, mergeArgs)
