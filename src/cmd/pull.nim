## `pull` -- `fetch`, then `merge FETCH_HEAD` (or `rebase FETCH_HEAD`).
##
## In scope: `<repository>`, `<refspec>`, `-r`/`--rebase`, `--no-rebase`,
## `-q`, and every option `fetch` takes, passed through.
##
## `git-pull.sh` was exactly this until it was translated to C in 2015: run
## `fetch` with the arguments, then integrate whatever it wrote to
## `FETCH_HEAD`.  `FETCH_HEAD` is the interface, not a private channel --
## `fetch` writes the merge candidates before the `not-for-merge` lines
## precisely so that `FETCH_HEAD` as a revision names the thing to merge
## (`builtin/fetch.c:store_updated_refs`), and a `pull` that read anything
## else would stop agreeing with `gittle merge FETCH_HEAD`.
##
## The one decision of its own is git's since 2.27: when `pull.rebase` is set
## neither in the configuration nor on the command line and the two histories
## have diverged, refuse rather than pick (`builtin/pull.c`, "divergent").

import std/[os, strutils]
import ../cli, ../oid, ../remotes, ../repository, ../revision, ../revwalk,
       ../util
import fetch as cmdfetch
import merge as cmdmerge
import rebase as cmdrebase


const
  synopsis = "[-r | --rebase | --no-rebase] [-q] [<fetch options>] [<repository> [<refspec>…]]"
  options = [
    opt("-r|--rebase", okOptValue, help = "rebase the current branch onto what was fetched"),
    opt("--no-rebase", help = "merge it instead (the default)"),
    opt("--ff-only|--squash|--autostash|--no-ff|--ff|-i", okRefused, help = "docs/05, docs/08"),
  ]

proc cmdPull*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, fetch, then merge or rebase onto `FETCH_HEAD`.
  let o = parse(@fetchOptions & @options, args, "pull", synopsis)
  var chosen = c.repo.cfg.has("pull.rebase")
  var rebase = c.repo.cfg.getBool("pull.rebase", false)
  # `--rebase`, `--rebase=true`, `--rebase=false`, `--no-rebase`: the last wins.
  for (k, v) in o.occurrences:
    if k == "rebase": (rebase = v != "false"; chosen = true)
    elif k == "no-rebase": (rebase = false; chosen = true)
  var opt = FetchOpts(reflogAction: ("pull " & args.join(" ")).strip())
  applyFetchOpts(o, opt)
  let positional = o.args
  c.reflogAction = opt.reflogAction
  failIf(cmdfetch.runFetch(c, positional, opt).failed,
         "some refs could not be updated")

  let repo = c.repo
  failIf(readWholeFile(repo.gitDir / "FETCH_HEAD").splitLines[0]
           .contains("not-for-merge"),
         "no candidate for merging in FETCH_HEAD: this branch has no " &
         "upstream, and no <refspec> was given")
  let head = repo.refs.resolveRef(headRef).oid
  let other = repo.resolveRevish("FETCH_HEAD")
  if not chosen and head != nullOid and not repo.isAncestor(head, other) and
     not repo.isAncestor(other, head):
    stderr.write "hint: set pull.rebase, or pass --rebase or --no-rebase, " &
                 "to say whether to rebase or merge\n"
    fail("Need to specify how to reconcile divergent branches.")
  let quiet = if opt.quiet: @["-q"] else: @[]
  # `--rebase` with nothing of our own to replay is a fast-forward, and git
  # runs the merge for it (`builtin/pull.c`: "if (can_ff) ... run_merge()"):
  # a rebase of no commits would still detach HEAD and put it back, and the
  # reflog would say so.  The rebase gets the resolved object ID, as git's
  # does, so its reflog line names what was checked out rather than the file.
  if rebase and not repo.isAncestor(head, other):
    cmdrebase.cmdRebase(c, quiet & $other)
  else: cmdmerge.cmdMerge(c, quiet & "FETCH_HEAD")
