## `update-ref` -- create, update and delete one reference.
##
## In scope: `<ref> <new> [<old>]`, `-d <ref> [<old>]`, `-m <reason>`.
##
## The `--stdin` transaction language (`update`, `create`, `verify`,
## `symref-*`, `start`/`prepare`/`commit`/`abort`, `-z`) was built in phase 2
## and removed in the minimization pass (docs/minimize.md §3, tier 1): it was
## the largest plumbing file in the project and nothing called it.  The
## transaction *engine* it drove is still refs.nim's, because `fetch` moves
## its refs through the same all-or-nothing `prepare`/`commit`; only the
## command-line grammar over it is gone.
##
## What is left is the compare-and-swap in its simplest spelling: a new
## value, and optionally the old one it must currently hold -- an empty old
## value, or the null object ID, meaning "must not exist yet".

import ../cli, ../oid, ../repository, ../revision, ../util


const
  synopsis = "[-m <reason>] <ref> <new-oid> [<old-oid>]\n[-m <reason>] -d <ref> [<old-oid>]"
  options = [
    opt("-d|--delete", help = "delete the ref"),
    opt("-m", okValue, arg = "<reason>", help = "the reflog message"),
    opt("--stdin|-z", okRefused, help = "removed in the minimization pass (docs/minimize.md §3)"),
  ]

proc cmdUpdateRef*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, then one delete or one compare-and-swap.
  let o = parse(options, args, "update-ref", synopsis)
  let del = o.has "delete"
  let msg = o.val "m"
  let rest = o.args
  let repo = c.repo
  if del:
    failIf(rest.len < 1 or rest.len > 2, o.use)
    if rest.len == 2:
      repo.refs.deleteRef(rest[0], repo.resolveRevish(rest[1]), checkOld = true,
                          msg = msg)
    else:
      repo.refs.deleteRef(rest[0], msg = msg)
    return 0

  failIf(rest.len < 2 or rest.len > 3, o.use)
  let newOid = repo.resolveRevish(rest[1])
  if rest.len == 3:
    # An empty old value, or the null OID, both mean "must not exist".
    let oldOid = if rest[2].len == 0: nullOid else: repo.resolveRevish(rest[2])
    repo.refs.updateRef(rest[0], newOid, oldOid, checkOld = true, msg = msg)
  else:
    repo.refs.updateRef(rest[0], newOid, msg = msg)
  0
