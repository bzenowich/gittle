## `push` -- send refs and the objects they need to a remote.
##
## In scope (docs/08): `<repository>`, `<refspec>`, `--tags`, `-d`/`--delete`,
## `-f`/`--force`, `--force-with-lease`, `-n`/`--dry-run`,
## `--receive-pack`/`--exec`, `-u`/`--set-upstream`, `-q`, `-v`.  `--all`,
## `--mirror`, `--prune`, `--atomic`, `--porcelain`, `--thin`, the signing and
## hook options and `--no-force-with-lease` are cut -- that last because it
## exists to take back a `--force-with-lease` an *alias* supplied, and gittle
## has no aliases (docs/minimize-2.md §B4).
##
## ## What is safe to overwrite is decided *here*, not by the server
##
## The server will do as it is told; every check in `decidePush` is the client
## protecting the user from a command they did not mean:
##
## * a ref that already exists is only moved when the new value is a
##   descendant of the old, unless `--force`;
## * `--force-with-lease` narrows that to "unless the remote has moved since I
##   last looked", which is the only form of force that is safe with a
##   collaborator -- the comparison is against the remote-tracking ref, so a
##   `fetch` in between defeats it, exactly as in git;
## * a deletion is spelled `:<ref>` (or `--delete`) and never happens by
##   accident.
##
## Each refusal carries **one sentence** naming the cause and the way past it,
## and the last one wins: git prints a paragraph of `hint:` lines per reason
## (`transport.c:transport_push`, `advise_pull_before_push` and siblings) and
## the minimization passes kept the cause and the remedy and nothing else
## (docs/minimize.md §3 tier 3, docs/minimize-2.md §A2).  git also varies the
## words by whether the ref is the current branch; gittle does not, because
## the report line directly above already names the ref.
##
## The one thing the client cannot check is a hook on the far side saying no;
## that comes back in the status report and is printed as `[remote rejected]`.

import std/[os, strutils]
import ../cli, ../oid, ../packwrite, ../refspec, ../remotes, ../repository,
       ../revwalk, ../transport, ../util
import gc as cmdgc


type
  Update = object
    src, dst: string      ## full local and remote ref names
    shown: string         ## the source *as typed*: `HEAD:main` reports `HEAD`
    newOid, oldOid: Oid   ## `oldOid` is what the remote advertised
    force, delete: bool
    lease: bool
    leaseOid: Oid

  Line = tuple[code: char, summary, reason, src, dst: string]
    ## One report line, held back rather than printed: the server has the last
    ## word and may turn an `ok` into a `[remote rejected]`.

const
  synopsis = "[<options>] [<repository> [<refspec>…]]"
  options = [
    opt("--tags", help = "also push every tag"),
    opt("-d|--delete", help = "delete the named refs on the remote"),
    opt("-f|--force", help = "allow a non-fast-forward update"),
    opt("--force-with-lease", okOptValue, help = "force only if the remote is where we last saw it"),
    opt("--no-force-with-lease", okRefused,
        help = "gittle has no aliases, so there is no --force-with-lease to take back"),
    opt("-n|--dry-run", help = "do everything except send"),
    opt("--receive-pack|--exec", okValue, arg = "<exec>", help = "the command to run on the far end"),
    opt("-u|--set-upstream", help = "record the pushed branch as this branch's upstream"),
    opt("-q|--quiet", help = "report nothing but errors"),
    opt("-v|--verbose", help = "also report refs that were already up to date"),
    opt("--all|--branches|--mirror|--prune|--atomic|--porcelain|--follow-tags|--signed|" &
        "--thin|--no-thin|--force-if-includes", okRefused, help = "docs/08"),
  ]

proc pushSpecs(repo: Repository, positional: seq[string], name, head: string,
               delete, pushTags: bool): seq[Refspec] =
  ## What to push: the refspecs typed, else `remote.<name>.push`, else the
  ## current branch.
  ##
  ## That last default is `push.default = simple`, git's since 2.0: the
  ## current branch, to a branch of the same name -- and refused when the
  ## configured upstream has a *different* name, because the two commands the
  ## user might have meant do different things.
  for s in (if positional.len > 1: positional[1 .. ^1] else: @[]):
    result.add parseRefspec((if delete: ":" & s else: s), forPush = true)
  if result.len == 0 and not delete:
    for s in repo.cfg.getAll("remote." & name & ".push"):
      result.add parseRefspec(s, forPush = true)
  if pushTags: result.add parseRefspec("refs/tags/*:refs/tags/*", forPush = true)
  if result.len > 0: return
  failIf(not head.startsWith("refs/heads/"),
         "HEAD is detached, so there is no branch to push: name the ref, as " &
         "'gittle push " & name & " HEAD:<branch>'")
  let upstream = repo.cfg.get("branch." &
                              head["refs/heads/".len .. ^1] & ".merge")
  failIf(upstream.len > 0 and upstream != head,
         "this branch's upstream has a different name, so which push you meant " &
         "is ambiguous: say 'gittle push " & name & " HEAD:" & upstream & "'")
  result.add parseRefspec(head & ":" & head, forPush = true)

proc remoteRefNamed(advertised: seq[RemoteRef], n: string): string =
  ## The remote ref a short name means *over there*.  It has to be resolved
  ## against the advertisement rather than against our own refs: `push origin
  ## :topic` deletes the remote's `refs/heads/topic` whether or not anything
  ## of that name exists here.
  if n.startsWith("refs/"): return n
  for rule in revParseRules:
    for r in advertised:
      if r.name == rule & n: return r.name
  ""

proc resolveUpdates(repo: Repository, specs: seq[Refspec],
                    advertised: seq[RemoteRef],
                    missing: var bool): seq[Update] =
  ## Turn every refspec into the ref pair it names.  `missing` comes back true
  ## when a deletion named something the remote does not have, which is an
  ## error but not a reason to abandon the other refs.
  for s in specs:
    if s.pattern:
      for r in repo.refs.allRefs(s.src[0 ..< s.src.find('*')]):
        let dst = s.mapRef(r.name).dst
        if dst.len == 0: continue
        result.add Update(src: r.name, dst: dst, shown: r.name, newOid: r.oid,
                          force: s.force)
      continue
    if s.src.len == 0:
      # `:<ref>` -- a deletion.
      let dst = remoteRefNamed(advertised, s.dst)
      if dst.len == 0:
        stderr.write "error: unable to delete '" & s.dst &
                     "': remote ref does not exist\n"
        missing = true
        continue
      result.add Update(dst: dst, delete: true, force: true)
      continue
    let found = repo.refs.dwimRef(s.src)
    failIf(not found.found, "src refspec " & s.src & " does not match any")
    var dst = if s.hasDst: s.dst else: found.full
    if not dst.startsWith("refs/"):
      # `push origin main` puts it where a branch of that name belongs; a tag
      # source keeps its own namespace (`remote.c:match_explicit`).
      dst = (if found.full.startsWith("refs/tags/"): "refs/tags/"
             else: "refs/heads/") & dst
    result.add Update(src: found.full, dst: dst, shown: s.src,
                      newOid: found.oid, force: s.force)

proc decidePush(repo: Repository, u: Update, force: bool):
    tuple[code: char, summary, reason, advice: string] =
  ## What one update becomes: the three fields the report prints, and the
  ## sentence to print afterwards if it was refused.  `=` means already there,
  ## `!` means refused; anything else is sent.
  if u.delete:
    if u.oldOid.isNull:
      return ('!', "[remote rejected]", "remote ref does not exist", "")
    return ('-', "[deleted]", "", "")
  if u.oldOid == u.newOid: return ('=', "[up to date]", "", "")
  if u.lease and u.oldOid != u.leaseOid:
    # No advice for this one: git's `REF_STATUS_REJECT_STALE` is not among the
    # reasons `transport_print_push_status` turns into a hint, and the remedy
    # -- fetch and look again -- is what the words already say.
    return ('!', "[rejected]", "stale info", "")
  if not u.oldOid.isNull and not (force or u.force):
    # A fast-forward can only be judged if we have the object the remote is
    # on; if we do not, it is behind something we never fetched, and saying
    # "non-fast-forward" would send the user to the wrong remedy.
    if not repo.hasObject(u.oldOid):
      return ('!', "[rejected]", "fetch first",
              "the remote contains work you do not have locally; " &
              "'gittle pull' first, or push with --force")
    if u.dst.startsWith("refs/tags/"):
      return ('!', "[rejected]", "already exists",
              "the tag already exists in the remote; push with --force to replace it")
    if not repo.isAncestor(u.oldOid, u.newOid):
      return ('!', "[rejected]", "non-fast-forward",
              "the remote branch has commits yours does not; " &
              "'gittle pull' first, or push with --force")
  if u.oldOid.isNull:
    return ('*', (if u.dst.startsWith("refs/tags/"): "[new tag]"
                  elif u.dst.startsWith("refs/heads/"): "[new branch]"
                  else: "[new reference]"), "", "")
  let a = repo.uniqueAbbrev(u.oldOid, repo.autoAbbrev)
  let b = repo.uniqueAbbrev(u.newOid, repo.autoAbbrev)
  if repo.hasObject(u.oldOid) and repo.isAncestor(u.oldOid, u.newOid):
    return (' ', a & ".." & b, "", "")
  ('+', a & "..." & b, "forced update", "")

proc packFor(repo: Repository, commands: seq[PushCommand],
             advertised: seq[RemoteRef]): string =
  ## What the remote is missing: everything the new tips reach, less
  ## everything every ref it advertised reaches.  A deletion contributes
  ## nothing, and a push of deletions alone sends no pack at all.
  var wants, haves: seq[Oid]
  for cmd in commands:
    if not cmd.newOid.isNull: wants.add cmd.newOid
  for r in advertised:
    if not r.oid.isNull: haves.add r.oid
  if wants.len == 0: return ""
  let objs = repo.objectsBetween(wants, haves)
  if objs.len == 0: return ""
  var pack = ""
  discard writePack(repo, objs, proc (d: string) = pack.add d)
  pack

proc updateTracking(repo: Repository, rem: Remote, commands: seq[PushCommand],
                    results: seq[PushResult]) =
  ## A successful push means the remote-tracking ref is now known to be right,
  ## so it moves without a fetch -- which is what makes `status` correct
  ## immediately afterwards.  A server that sent no report at all accepted
  ## everything (it has no `report-status`), so silence counts as success.
  if rem.name.len == 0: return
  for cmd in commands:
    var ok = results.len == 0
    for r in results:
      if r.name == cmd.name and r.ok: ok = true
    if not ok or not cmd.name.startsWith("refs/heads/"): continue
    let tracking = "refs/remotes/" & rem.name & "/" &
                   cmd.name["refs/heads/".len .. ^1]
    if cmd.newOid.isNull: repo.refs.deleteRef(tracking, msg = "update by push")
    else: repo.refs.updateRef(tracking, cmd.newOid, msg = "update by push")

proc cmdPush*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, work out the ref updates the refspecs ask for,
  ## check each against what the remote advertises, send the pack, and
  ## report.
  let o = parse(options, args, "push", synopsis)
  var lease = false
  for (k, v) in o.occurrences:
    if k == "force-with-lease":
      failIf(v.len > 0, "gittle's --force-with-lease has no <ref>:<expect> form; " &
             "bare, it compares the remote against our remote-tracking ref (docs/08)")
      lease = true
  let force = o.has "force"
  let dryRun = o.has "dry-run"
  let quiet = o.has "quiet"
  let verbose = o.has "verbose"
  let positional = o.args
  let repo = c.repo
  let head = repo.headRefName()
  let branch = if head.startsWith("refs/heads/"):
                 head["refs/heads/".len .. ^1] else: ""

  # Which remote: the branch's `pushRemote`, then `remote.pushDefault`, then
  # the branch's `remote`, then `origin` (`remote.c:pushremote_for_branch`).
  var name = if positional.len > 0: positional[0] else: ""
  if name.len == 0:
    name = repo.cfg.get("branch." & branch & ".pushRemote")
  if name.len == 0: name = repo.cfg.get("remote.pushDefault")
  if name.len == 0: name = repo.defaultRemote()
  let rem = repo.lookupRemote(name)
  let specs = pushSpecs(repo, positional, name, head,
                        o.has "delete", o.has "tags")

  # Before connecting, so that it is on screen when ssh is the thing that
  # fails -- which is where git prints it too.
  if verbose: stderr.write "Pushing to " & rem.url & "\n"

  let conn = connect(rem.url,
                     (if o.val("receive-pack").len > 0: o.val "receive-pack"
                      elif repo.cfg.get("remote." & name & ".receivepack").len > 0:
                        repo.cfg.get("remote." & name & ".receivepack")
                      else: "git-receive-pack"))
  defer: conn.finish()
  conn.handshake()
  let advertised = conn.adverts

  var rejected = false
  var ups = resolveUpdates(repo, specs, advertised, rejected)
  for u in ups.mitems:
    for r in advertised:
      if r.name == u.dst: u.oldOid = r.oid; break
    if lease and not u.delete:
      u.lease = true
      let t = repo.refs.readRef("refs/remotes/" & name & "/" & prettify(u.dst))
      u.leaseOid = if t.found: t.oid else: nullOid

  # ---- decide ----------------------------------------------------------
  var commands: seq[PushCommand]
  var lines: seq[Line]
  var advice = ""
  for u in ups:
    let d = decidePush(repo, u, force)
    if d.code == '=':
      if verbose: lines.add (d.code, d.summary, d.reason, u.shown, u.dst)
      continue
    lines.add (d.code, d.summary, d.reason,
               (if u.delete: "" else: u.shown), u.dst)
    if d.code == '!':
      rejected = true
      if d.advice.len > 0: advice = d.advice
      continue
    commands.add PushCommand(name: u.dst, oldOid: u.oldOid,
                             newOid: (if u.delete: nullOid else: u.newOid))

  proc report() =
    ## The `To <url>` block, on stderr like git's, then why it failed.
    if lines.len == 0:
      if not quiet and not rejected: stderr.write "Everything up-to-date\n"
    else:
      var rep = RefReport(header: "To", url: rem.url)
      for l in lines: rep.reportRefUpdate(l.code, l.summary, l.reason, l.src, l.dst)
    if not rejected: return
    stderr.write "error: failed to push some refs to '" & rem.url & "'\n"
    if advice.len > 0: stderr.write "hint: " & advice & "\n"

  if dryRun or commands.len == 0:
    report()
    return if rejected: 1 else: 0

  let results = conn.sendPack(commands, packFor(repo, commands, advertised),
                              quiet)
  # The server has the last word: a hook may have refused one ref while
  # accepting another, so the report is rewritten from what came back.
  for r in results:
    if r.ok: continue
    for k in 0 ..< lines.len:
      if lines[k].dst == r.name:
        lines[k].code = '!'
        lines[k].summary = "[remote rejected]"
        lines[k].reason = r.reason
    rejected = true
  report()

  updateTracking(repo, rem, commands, results)
  if o.has("set-upstream") and rem.name.len > 0:
    for u in ups:
      if not u.src.startsWith("refs/heads/"): continue
      let b = u.src["refs/heads/".len .. ^1]
      setConfigValue(repo.gitDir / "config", "branch." & b & ".remote", rem.name)
      setConfigValue(repo.gitDir / "config", "branch." & b & ".merge", u.dst)
      if not quiet:
        stderr.write "branch '" & b & "' set up to track '" &
                     rem.name & "/" & prettify(u.dst) & "'.\n"
  if rejected: return 1
  # Automatic housekeeping, where git runs `maintenance run --auto` after a
  # commit or a fetch: the end of a successful push is the moment the server
  # holds everything worth packing, and the threshold is git's own
  # (`gc.auto`, 6700 by default; 0 turns it off).
  let threshold = repo.cfg.getInt("gc.auto", 6700)
  if rem.name.len > 0 and threshold > 0 and
     cmdgc.looseObjectEstimate(repo) > threshold:
    if not quiet:
      stderr.write "Auto packing the repository with " & rem.name & "'s help.\n"
    cmdgc.gcRepository(c, rem.name, full = false, quiet = true)
  0
