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
import ../cli, ../refspec, ../remotes

const
  synopsis = "[<options>] [<repository> [<refspec>…]]"
  fetchOptions* = [
    opt("-t|--tags", help = "fetch all tags"),
    opt("--no-tags", help = "do not follow tags at all"),
    opt("-f|--force", help = "allow a non-fast-forward update of a local ref"),
    opt("-p|--prune", help = "delete remote-tracking refs the remote no longer has"),
    opt("--upload-pack", okValue, arg = "<exec>", help = "the command to run on the far end"),
    opt("-q|--quiet", help = "report nothing but errors"),
    opt("-v|--verbose", help = "also report refs that were already up to date"),
    opt("--all|--multiple|--atomic|--dry-run|--porcelain|--refetch|--unshallow|" &
        "--set-upstream|--append|-a", okRefused, help = "docs/05"),
    opt("--depth|--deepen|--shallow-since|--shallow-exclude|--filter", okRefused,
        help = "gittle has no shallow or partial clone (plan.md §1)"),
  ]

proc applyFetchOpts*(o: Opts, opt: var FetchOpts) =
  ## The fetch half of a parse; `pull` parses `fetchOptions` alongside its
  ## own and hands the result here.
  opt.tags = o.has "tags"
  opt.noTags = o.has "no-tags"
  opt.force = o.has "force"
  opt.prune = o.has "prune"
  opt.quiet = o.has "quiet"
  opt.verbose = o.has "verbose"
  opt.uploadPack = o.val "upload-pack"

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
  ## Entry point: parse into `FetchOpts`, then `runFetch`.
  # git's reflog action is the command line as typed -- `fetch --tags origin`,
  # not `fetch` -- which is why every entry says exactly what produced it
  # (`builtin/fetch.c`, `default_rla`).
  var opt = FetchOpts(reflogAction: ("fetch " & args.join(" ")).strip())
  let o = parse(fetchOptions, args, "fetch", synopsis)
  applyFetchOpts(o, opt)
  if runFetch(c, o.args, opt).failed: 1 else: 0
