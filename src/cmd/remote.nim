## `remote` -- the named remotes, and the refspecs that go with them.
##
## In scope (docs/11): `add`, `remove`/`rm`, `get-url`, `set-url`, `-v`, and
## the bare listing.  `rename`, `set-head`, `set-branches`, `show`, `prune`
## and `update` are cut.
##
## There is no state here beyond the configuration file: a remote *is* a
## `remote.<name>.url` and one or more `remote.<name>.fetch` lines, which is
## why `add` is two `config` writes and `remove` is a section deletion plus
## the remote-tracking refs it owned.

import std/[os, strutils]
import ../cli, ../config, ../refname, ../refs, ../refspec, ../remotes,
       ../repository, ../util


const
  synopsis = "[-v]\nadd <name> <url>\nremove <name>\nget-url <name>\nset-url <name> <newurl>"
  options = [opt("-v|--verbose", help = "show the URL beside each name")]

proc cmdRemote*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, then the sub-verb -- a listing, or one edit of
  ## `remote.<name>.*` in the config.
  let o = parse(options, args, "remote", synopsis)
  let verbose = o.has "verbose"
  let rest = o.args

  let repo = c.repo
  let cfgPath = repo.commonDir / "config"
  let verb = if rest.len > 0: rest[0] else: ""

  case verb
  of "":
    for n in repo.remoteNames():
      if verbose:
        # git prints each remote twice, once per direction, because the two
        # can differ (`remote.<name>.pushurl`); gittle has no `pushurl`, so
        # both lines carry the same URL.
        let url = repo.cfg.get("remote." & n & ".url")
        echo n & "\t" & url & " (fetch)"
        echo n & "\t" & url & " (push)"
      else:
        echo n
  of "add":
    failIf(rest.len != 3, o.use)
    let name = rest[1]
    failIf(not isValidRefname(refsPrefix & "remotes/" & name & "/x"),
           "'" & name & "' is not a valid remote name")
    if repo.cfg.has("remote." & name & ".url"):
      stderr.write "error: remote " & name & " already exists.\n"
      return 3
    setConfigValue(cfgPath, "remote." & name & ".url", rest[2])
    setConfigValue(cfgPath, "remote." & name & ".fetch",
                   defaultFetchRefspec(name))
  of "remove", "rm":
    failIf(rest.len != 2, o.use)
    let name = rest[1]
    if not repo.cfg.has("remote." & name & ".url"):
      stderr.write "error: No such remote: '" & name & "'\n"
      return 2
    for key in ["url", "fetch", "push", "uploadpack", "receivepack"]:
      discard unsetConfigValue(cfgPath, "remote." & name & "." & key, all = true)
    # The tracking refs the remote owned go with it, and so does any branch's
    # record of following it.
    for r in repo.refs.allRefs("refs/remotes/" & name & "/"):
      repo.refs.deleteRef(r.name, noDeref = true)
    var branches: seq[string]
    for e in repo.cfg.withPrefix("branch"):
      if e.key.toLowerAscii.endsWith(".remote") and e.value == name:
        branches.add e.key[len("branch.") ..< e.key.len - len(".remote")]
    for b in branches:
      discard unsetConfigValue(cfgPath, "branch." & b & ".remote", all = true)
      discard unsetConfigValue(cfgPath, "branch." & b & ".merge", all = true)
  of "get-url":
    failIf(rest.len != 2, o.use)
    let url = repo.cfg.get("remote." & rest[1] & ".url")
    if url.len == 0:
      stderr.write "error: No such remote '" & rest[1] & "'\n"
      return 2
    echo url
  of "set-url":
    failIf(rest.len != 3, o.use)
    if not repo.cfg.has("remote." & rest[1] & ".url"):
      stderr.write "error: No such remote '" & rest[1] & "'\n"
      return 2
    setConfigValue(cfgPath, "remote." & rest[1] & ".url", rest[2])
  of "rename", "set-head", "set-branches", "show", "prune", "update":
    fail("gittle remote " & verb & " is out of scope for v1 (docs/11)")
  else:
    fail("unknown subcommand: " & verb & "\n" & o.use)
  0
