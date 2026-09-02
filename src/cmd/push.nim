## `push` -- send refs and the objects they need to a remote.
##
## In scope (docs/08): `<repository>`, `<refspec>`, `--tags`, `-d`/`--delete`,
## `-f`/`--force`, `--force-with-lease`, `-n`/`--dry-run`,
## `--receive-pack`/`--exec`, `-u`/`--set-upstream`, `-q`, `-v`.  `--all`,
## `--mirror`, `--prune`, `--atomic`, `--porcelain`, `--thin` and the signing
## and hook options are cut.
##
## ## Push is protocol v0, whatever the handshake said
##
## `receive-pack` has no protocol v2 form -- `gitprotocol-v2.adoc` defines
## exactly two commands, `ls-refs` and `fetch` -- so the version negotiation
## happens, the server answers with a v0 ref advertisement, and that is the
## protocol.  [transport.nim](../transport.nim) has the shape of it.
##
## ## What is safe to overwrite is decided *here*, not by the server
##
## The server will do as it is told; every check below is the client
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

  Reject = enum
    ## Why a ref was refused, which decides which of git's six paragraphs of
    ## advice is printed at the end (`builtin/push.c`).
    rjNone, rjNonFfHead, rjNonFfOther, rjFetchFirst, rjExists, rjNeedsUpdate

const advice: array[Reject, string] = [
  "",
  "the tip of your current branch is behind its remote counterpart; " &
  "'gittle pull' first, or push with --force",
  "a pushed branch tip is behind its remote counterpart; 'gittle pull' " &
  "first, or push with --force",
  "the remote contains work you do not have locally; 'gittle pull' first, " &
  "or push with --force",
  "the tag already exists in the remote; push with --force to replace it",
  "the remote-tracking branch has moved since the last fetch; 'gittle " &
  "fetch' and look before pushing with --force-with-lease again"]
  ## One sentence per way a ref update can be refused.  git prints a
  ## paragraph of `hint:` lines for each (`transport.c:transport_push`,
  ## `advise_pull_before_push` and siblings); the minimization pass kept the
  ## cause and the way out (docs/minimize.md §3, tier 3).

const
  synopsis = "[<options>] [<repository> [<refspec>…]]"
  options = [
    opt("--tags", help = "also push every tag"),
    opt("-d|--delete", help = "delete the named refs on the remote"),
    opt("-f|--force", help = "allow a non-fast-forward update"),
    opt("--force-with-lease", okOptValue, help = "force only if the remote is where we last saw it"),
    opt("--no-force-with-lease"),
    opt("-n|--dry-run", help = "do everything except send"),
    opt("--receive-pack|--exec", okValue, arg = "<exec>", help = "the command to run on the far end"),
    opt("-u|--set-upstream", help = "record the pushed branch as this branch's upstream"),
    opt("-q|--quiet", help = "report nothing but errors"),
    opt("-v|--verbose", help = "also report refs that were already up to date"),
    opt("--all|--branches|--mirror|--prune|--atomic|--porcelain|--follow-tags|--signed|" &
        "--thin|--no-thin|--force-if-includes", okRefused, help = "docs/08"),
  ]

proc cmdPush*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, work out the ref updates the refspecs ask for,
  ## check each against what the remote advertises, send the pack, and
  ## report.
  let o = parse(options, args, "push", synopsis)
  var lease = false
  for (k, v) in o.occurrences:
    if k == "force-with-lease":
      failIf(v.len > 0, "gittle implements --force-with-lease only in its bare form,\n" &
             "  which compares the remote against this repository's " &
             "remote-tracking ref (docs/08)")
      lease = true
    elif k == "no-force-with-lease": lease = false
  let force = o.has "force"
  let dryRun = o.has "dry-run"
  let quiet = o.has "quiet"
  let verbose = o.has "verbose"
  let setUpstream = o.has "set-upstream"
  let delete = o.has "delete"
  let pushTags = o.has "tags"
  let receivePack = o.val "receive-pack"
  let positional = o.args
  let repo = c.repo
  let head = repo.headRefName()
  let branch = if head.startsWith("refs/heads/"):
                 head["refs/heads/".len .. ^1] else: ""

  # Which remote: the branch's `pushRemote`, then its `remote`, then `origin`
  # (`remote.c:pushremote_for_branch`).
  var name = if positional.len > 0: positional[0] else: ""
  if name.len == 0:
    name = repo.cfg.get("branch." & branch & ".pushRemote")
  if name.len == 0: name = repo.cfg.get("remote.pushDefault")
  if name.len == 0: name = repo.defaultRemote()
  let rem = repo.lookupRemote(name)

  # ---- what to push --------------------------------------------------
  var specs: seq[Refspec]
  for s in (if positional.len > 1: positional[1 .. ^1] else: @[]):
    specs.add parseRefspec((if delete: ":" & s else: s), forPush = true)
  if specs.len == 0 and not delete:
    for s in repo.cfg.getAll("remote." & name & ".push"):
      specs.add parseRefspec(s, forPush = true)
  if pushTags: specs.add parseRefspec("refs/tags/*:refs/tags/*", forPush = true)
  if specs.len == 0:
    # `push.default = simple`, git's default since 2.0: the current branch, to
    # a branch of the same name.  git additionally refuses when the configured
    # upstream has a *different* name, and so does this.
    failIf(branch.len == 0,
           "You are not currently on a branch.\n" &
           "  To push the history leading to the current (detached HEAD)\n" &
           "  state now, use\n\n    gittle push " & name & " HEAD:<name-of-remote-branch>\n")
    let upstream = repo.cfg.get("branch." & branch & ".merge")
    failIf(upstream.len > 0 and upstream != head,
           "The upstream branch of your current branch does not match\n" &
           "  the name of your current branch.  To push to the upstream " &
           "branch\n  on the remote, use\n\n    gittle push " & name & " " &
           "HEAD:" & upstream & "\n")
    specs.add parseRefspec(head & ":" & head, forPush = true)

  # Before connecting, so that it is on screen when ssh is the thing that
  # fails -- which is where git prints it too.
  if verbose: stderr.write "Pushing to " & rem.url & "\n"

  let conn = connect(rem.url,
                     (if receivePack.len > 0: receivePack
                      elif repo.cfg.get("remote." & name & ".receivepack").len > 0:
                        repo.cfg.get("remote." & name & ".receivepack")
                      else: "git-receive-pack"),
                     wantV2 = false)
  defer: conn.finish()
  conn.handshake()
  let advertised = conn.lsRefs([])

  proc advertisedOid(n: string): Oid =
    ## What the remote says a ref holds, or null when it has none.
    for r in advertised:
      if r.name == n: return r.oid
    nullOid

  proc remoteRefNamed(n: string): string =
    ## The remote ref a short name means *over there*.  It has to be resolved
    ## against the advertisement rather than against our own refs: `push
    ## origin :topic` deletes the remote's `refs/heads/topic` whether or not
    ## anything of that name exists here.
    if n.startsWith("refs/"): return n
    for rule in revParseRules:
      for r in advertised:
        if r.name == rule & n: return r.name
    ""

  # ---- resolve every refspec into an update ---------------------------
  var ups: seq[Update]
  var missing = false        ## a deletion of something that is not there
  for s in specs:
    if s.pattern:
      let prefix = s.src[0 ..< s.src.find('*')]
      for r in repo.refs.allRefs(prefix):
        let dst = s.mapRef(r.name).dst
        if dst.len == 0: continue
        ups.add Update(src: r.name, dst: dst, shown: r.name, newOid: r.oid,
                       force: s.force)
      continue
    if s.src.len == 0:
      # `:<ref>` -- a deletion.
      let dst = remoteRefNamed(s.dst)
      if dst.len == 0:
        stderr.write "error: unable to delete '" & s.dst &
                     "': remote ref does not exist\n"
        missing = true
        continue
      ups.add Update(dst: dst, delete: true, force: true)
      continue
    let found = repo.refs.dwimRef(s.src)
    failIf(not found.found,
           "src refspec " & s.src & " does not match any")
    var dst = if s.hasDst: s.dst else: found.full
    if not dst.startsWith("refs/"):
      # `push origin main` puts it where a branch of that name belongs; a tag
      # source keeps its own namespace (`remote.c:match_explicit`).
      dst = (if found.full.startsWith("refs/tags/"): "refs/tags/"
             else: "refs/heads/") & dst
    ups.add Update(src: found.full, dst: dst, shown: s.src, newOid: found.oid,
                   force: s.force)

  for u in ups.mitems:
    u.oldOid = advertisedOid(u.dst)
    if lease and not u.delete:
      u.lease = true
      let tracking = "refs/remotes/" & name & "/" & prettify(u.dst)
      let t = repo.refs.readRef(tracking)
      u.leaseOid = if t.found: t.oid else: nullOid

  # ---- decide, and report --------------------------------------------
  var commands: seq[PushCommand]
  var lines: seq[tuple[flag: char, summary, msg, src, dst: string]]
  var allOids: seq[Oid]
  for u in ups: allOids.add [u.oldOid, u.newOid]
  let width = repo.summaryColumn(allOids)
  var rejected = missing
  var why = rjNone
  for u in ups:
    if u.delete:
      if u.oldOid.isNull:
        lines.add ('!', "[remote rejected]", "remote ref does not exist",
                   "", u.dst)
        rejected = true
        continue
      commands.add PushCommand(name: u.dst, oldOid: u.oldOid, newOid: nullOid)
      lines.add ('-', "[deleted]", "", "", u.dst)
      continue
    if u.oldOid == u.newOid:
      if verbose: lines.add ('=', "[up to date]", "", u.shown, u.dst)
      continue
    if u.lease and u.oldOid != u.leaseOid:
      # No advice for this one: git's `REF_STATUS_REJECT_STALE` is not among
      # the reasons `transport_print_push_status` turns into a hint, and the
      # remedy -- fetch and look again -- is what the words already say.
      lines.add ('!', "[rejected]", "stale info", u.shown, u.dst)
      rejected = true
      continue
    if not u.oldOid.isNull and not (force or u.force):
      # A fast-forward can only be judged if we have the object the remote is
      # on; if we do not, it is behind something we never fetched, and saying
      # "non-fast-forward" would send the user to the wrong remedy.
      if not repo.hasObject(u.oldOid):
        lines.add ('!', "[rejected]", "fetch first", u.shown, u.dst)
        rejected = true
        why = rjFetchFirst
        continue
      if u.dst.startsWith("refs/tags/"):
        lines.add ('!', "[rejected]", "already exists", u.shown, u.dst)
        rejected = true
        why = rjExists
        continue
      if not repo.isAncestor(u.oldOid, u.newOid):
        lines.add ('!', "[rejected]", "non-fast-forward", u.shown, u.dst)
        rejected = true
        why = if u.src == head: rjNonFfHead else: rjNonFfOther
        continue
    commands.add PushCommand(name: u.dst, oldOid: u.oldOid, newOid: u.newOid)
    if u.oldOid.isNull:
      lines.add ('*', (if u.dst.startsWith("refs/tags/"): "[new tag]"
                       elif u.dst.startsWith("refs/heads/"): "[new branch]"
                       else: "[new reference]"), "", u.shown, u.dst)
    elif repo.hasObject(u.oldOid) and repo.isAncestor(u.oldOid, u.newOid):
      lines.add (' ', repo.uniqueAbbrev(u.oldOid, repo.autoAbbrev) & ".." &
                      repo.uniqueAbbrev(u.newOid, repo.autoAbbrev), "",
                 u.shown, u.dst)
    else:
      lines.add ('+', repo.uniqueAbbrev(u.oldOid, repo.autoAbbrev) & "..." &
                      repo.uniqueAbbrev(u.newOid, repo.autoAbbrev),
                 "forced update", u.shown, u.dst)

  proc report() =
    ## The `To <url>` report, one line per update, on stderr like git's.
    if lines.len == 0:
      if not quiet and not rejected: stderr.write "Everything up-to-date\n"
    else:
      stderr.write "To " & rem.url & "\n"
      for l in lines:
        var s = " " & l.flag & " " & l.summary
        while s.len < 3 + width: s.add ' '
        s.add " "
        if l.src.len > 0: s.add prettify(l.src) & " -> "
        s.add prettify(l.dst)
        if l.msg.len > 0: s.add " (" & l.msg & ")"
        stderr.write s & "\n"
    if not rejected: return
    stderr.write "error: failed to push some refs to '" & rem.url & "'\n"
    if why != rjNone:
      for line in advice[why].split('\n'):
        stderr.write "hint: " & line & "\n"

  if dryRun or commands.len == 0:
    report()
    return if rejected: 1 else: 0

  # ---- the pack --------------------------------------------------------
  #
  # What the remote is missing: everything the new tips reach, less everything
  # every ref it advertised reaches.  A deletion contributes nothing.
  var wants, haves: seq[Oid]
  for cmd in commands:
    if not cmd.newOid.isNull: wants.add cmd.newOid
  for r in advertised:
    if not r.oid.isNull: haves.add r.oid
  var pack = ""
  if wants.len > 0:
    let objs = repo.objectsBetween(wants, haves)
    if objs.len > 0:
      discard writePack(repo, objs, proc (d: string) = pack.add d)

  let results = conn.sendPack(commands, pack, quiet)

  # The server has the last word: a hook may have refused one ref while
  # accepting another, so the report is rewritten from what came back.
  for r in results:
    if r.ok: continue
    for k in 0 ..< lines.len:
      if lines[k].dst == r.name:
        lines[k].flag = '!'
        lines[k].summary = "[remote rejected]"
        lines[k].msg = r.reason
    rejected = true
  report()

  # A successful push means the remote-tracking ref is now known to be right,
  # so it moves without a fetch -- which is what makes `status` correct
  # immediately afterwards.
  for cmd in commands:
    var ok = results.len == 0
    for r in results:
      if r.name == cmd.name and r.ok: ok = true
    if not ok: continue
    if rem.name.len == 0: continue
    if not cmd.name.startsWith("refs/heads/"): continue
    let tracking = "refs/remotes/" & rem.name & "/" &
                   cmd.name["refs/heads/".len .. ^1]
    if cmd.newOid.isNull: repo.refs.deleteRef(tracking, msg = "update by push")
    else: repo.refs.updateRef(tracking, cmd.newOid, msg = "update by push")

  if setUpstream and rem.name.len > 0:
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
  if not dryRun and rem.name.len > 0 and threshold > 0 and
     cmdgc.looseObjectEstimate(repo) > threshold:
    if not quiet:
      stderr.write "Auto packing the repository with " & rem.name & "'s help.\n"
    cmdgc.gcRepository(c, rem.name, full = false, quiet = true)
  0
