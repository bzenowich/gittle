## `fetch` -- bring a remote's refs and objects up to date here.
##
## In scope (docs/05 `fetch-options`, docs/07): `<repository>`, `<refspec>`,
## `-t`/`--tags`, `--no-tags`, `-f`/`--force`, `-p`/`--prune`,
## `--upload-pack`, `-q`, `-v`.  Everything shallow, everything partial,
## `--all`, `--multiple`, `--atomic`, `--dry-run` and `--porcelain` are cut.
##
## The command is thin because the work is in [remotes.nim](../remotes.nim);
## what is here is the decision of *which refspecs apply*, which has three
## cases and no fourth:
##
## * refspecs on the command line -- exactly those, and every ref they fetch
##   is a merge candidate in `FETCH_HEAD` (that is what makes
##   `gittle pull origin main` work);
## * a configured remote and no refspecs -- `remote.<name>.fetch`, all of them;
## * a bare URL -- no refspec at all, so nothing but `FETCH_HEAD` is written.
##   `gittle fetch https://…` updating no ref surprises people, and it is what
##   git does.

import std/[sequtils, strutils]
import ../cli, ../refspec, ../remotes, ../util

const usageText = """usage: gittle fetch [<options>] [<repository> [<refspec>…]]

   -t, --tags            fetch all tags
   --no-tags             do not follow tags at all
   -f, --force           allow a non-fast-forward update of a local ref
   -p, --prune           delete remote-tracking refs the remote no longer has
   --upload-pack <exec>  the command to run on the far end
   -q, --quiet           report nothing but errors
   -v, --verbose         also report refs that were already up to date"""

proc parseFetchArgs*(args: seq[string], opt: var FetchOpts): seq[string] =
  ## Shared with `pull`, which takes the same options and passes them through.
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "-t", "--tags": opt.tags = true
    of "--no-tags": opt.noTags = true
    of "-f", "--force": opt.force = true
    of "-p", "--prune": opt.prune = true
    of "-q", "--quiet": opt.quiet = true
    of "-v", "--verbose": opt.verbose = true
    of "--upload-pack":
      inc i
      failIf(i >= args.len, "option '--upload-pack' requires a value")
      opt.uploadPack = args[i]
    of "-h", "--help": (echo usageText; return @["--help"])
    of "--all", "--multiple", "--atomic", "--dry-run", "--porcelain",
       "--refetch", "--unshallow", "--set-upstream", "--append", "-a":
      fail(a & " is out of scope for gittle v1 (docs/05)")
    else:
      if a.startsWith("--upload-pack="):
        opt.uploadPack = a["--upload-pack=".len .. ^1]
      elif a.startsWith("--depth") or a.startsWith("--shallow") or
           a.startsWith("--filter"):
        fail(a.split('=')[0] & " is out of scope for gittle v1: gittle has no " &
             "shallow or partial clone (plan.md §1)")
      elif a.startsWith("-") and a.len > 1 and a != "--":
        fail("unknown option '" & a & "'\n" & usageText)
      else: result.add a
    inc i

proc runFetch*(c: Ctx, positional: seq[string], opt: var FetchOpts):
    tuple[remote: Remote, failed: bool] =
  ## Resolve the remote and its refspecs, then fetch.  Returns the remote so
  ## that `pull` can name it in its own messages.
  let repo = c.repo
  let name = if positional.len > 0: positional[0] else: repo.defaultRemote()
  result.remote = repo.lookupRemote(name)
  opt.configured = result.remote.specs
  opt.autoTags = result.remote.specs.anyIt(it.hasDst)
  if positional.len > 1:
    opt.explicitSpecs = true
    opt.autoTags = false
    result.remote.specs = @[]
    for s in positional[1 .. ^1]:
      let rs = parseRefspec(s, forPush = false)
      if rs.hasDst: opt.autoTags = true
      result.remote.specs.add rs
  opt.report = not opt.quiet
  opt.writeFetchHead = true
  result.failed = repo.fetchFrom(result.remote, opt).failed

proc cmdFetch*(c: Ctx, args: seq[string]): int =
  # git's reflog action is the command line as typed -- `fetch --tags origin`,
  # not `fetch` -- which is why every entry says exactly what produced it
  # (`builtin/fetch.c`, `default_rla`).
  var opt = FetchOpts(reflogAction: ("fetch " & args.join(" ")).strip())
  let positional = parseFetchArgs(args, opt)
  if positional == @["--help"]: return 0
  if runFetch(c, positional, opt).failed: 1 else: 0
