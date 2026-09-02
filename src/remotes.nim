## Fetching: the ref map, the pack, and the report.
##
## `clone`, `fetch` and `pull` are one operation with three sets of arguments,
## and this is the operation.  It has five steps, and every one of them is
## visible in `fetchFrom` below:
##
## 1. **Ask what is there.**  `ls-refs` (or, in protocol v0, the advertisement
##    that already arrived) gives every ref the remote will admit to.
## 2. **Decide what each becomes here.**  Refspecs map remote names to local
##    ones; a remote ref that no refspec matches is not fetched.  This is the
##    *ref map*, and it is the whole of "what does fetching do to my
##    repository".  Three things make it less obvious than it sounds, and all
##    three are git's rules rather than choices: a refspec with no destination
##    (`fetch origin main`) fetches into `FETCH_HEAD` and moves nothing; a
##    refspec typed by hand does not repeal the remote-tracking layout, so
##    every ref it fetched is *also* written where `remote.<name>.fetch` would
##    have put it; and a short name is resolved against the **remote's**
##    namespace, so `main` is `refs/heads/main` because the remote has one.
## 3. **Ask for what is missing.**  A `want` for every mapped ref whose object
##    is not already here, a `have` for the commits we can offer, and one
##    packfile comes back.
## 4. **Check it, then install it.**  `index-pack --fix-thin`, then the
##    connectivity walk, and only then does any ref move
##    ([indexpack.nim](indexpack.nim) has the reasoning).
## 5. **Move the refs, and say so.**  One transaction -- with the *deletions*
##    first, so that a branch deleted upstream and a branch created upstream
##    can trade places -- and then the report, which is fiddlier than it looks
##    and is `initDisplay`, `displayRefUpdate` and `flush`.
##
## ## Tags follow, they are not fetched
##
## The default refspec covers `refs/heads/*` and nothing else, yet a plain
## `git fetch` brings tags with it.  The mechanism is not a second refspec: it
## is the `include-tag` capability, which asks the server to put any annotated
## tag *pointing into the history being sent* into the pack.  Afterwards, any
## remote tag whose object we now have and whose name we do not becomes a
## local tag.  That is why `--tags` is different rather than redundant: it
## fetches every tag, reachable or not.
##
## ## What a fetch may and may not overwrite
##
## A remote-tracking ref is a record of what the remote said, so the default
## refspec carries `+` and a rewind is reported rather than refused.  A local
## *tag* is not: `fetch` refuses to move one that already exists unless
## `--force`, because a tag that changes underneath you is the one thing in
## git that is supposed to be immutable.  `builtin/fetch.c:update_local_ref`
## has both rules and this file follows it case for case.

import std/[algorithm, os, posix, sequtils, sets, strutils]
import indexpack, oid, refname, refs, refspec, repository, revwalk,
       transport, util

type
  Remote* = object
    name*: string          ## "" when the argument was a URL rather than a name
    url*: string
    specs*: seq[Refspec]

  FetchOpts* = object
    tags*, noTags*, prune*, force*, quiet*, verbose*: bool
    uploadPack*: string
    explicitSpecs*: bool   ## refspecs came from the command line, which makes
                           ## every fetched ref a merge candidate in FETCH_HEAD
    report*: bool          ## print the `From <url>` block; `clone` does not
    writeFetchHead*: bool
    reflogAction*: string  ## what the reflog calls this; "fetch <args>"
    autoTags*: bool        ## follow tags into the history being fetched.
                           ## False when the only refspec given was a bare
                           ## `<name>`, which writes no ref and therefore
                           ## brings no tags with it (`get_ref_map`)
    configured*: seq[Refspec]
      ## `remote.<name>.fetch`, kept separately when the refspecs actually
      ## being fetched came from the command line.  See `opportunistic`.
    noReflog*: bool        ## populating a new repository rather than updating
                           ## one: `clone` writes no reflog for the refs it
                           ## creates, and neither does git

  Mapped = object
    ## One line of the ref map: a remote ref, and the local ref it updates.
    remote: RemoteRef
    local: string          ## "" -- fetched, but only into FETCH_HEAD
    force: bool
    fetchHead: bool        ## contributes a line to FETCH_HEAD
    merge: bool            ## ...and that line is a merge candidate
    oppo: bool             ## an opportunistic remote-tracking update
    old: Oid
    isNew: bool

const
  defaultTermWidth = 80
    ## `term_columns()` when there is no terminal and no `COLUMNS`.  It only
    ## decides whether a ref name is too long to count towards the column
    ## width, so a fixed value costs nothing but a rare column difference.

func prettify*(name: string): string =
  ## `refs.c:prettify_refname`: a plain prefix strip, with none of the
  ## ambiguity checking `shortenRef` does.  The report is display, not naming.
  for p in ["refs/heads/", "refs/tags/", "refs/remotes/"]:
    if name.startsWith(p): return name[p.len .. ^1]
  name

proc summaryColumn*(repo: Repository, oids: openArray[Oid]): int =
  ## How wide the first column of a fetch or push report is:
  ## `2 * <abbreviation length> + 3`, which is exactly enough for
  ## `<old>...<new>` (`transport.c:transport_summary_width`).  The length is
  ## measured over every object either end mentions, so one long
  ## abbreviation widens the whole report rather than one line of it.
  var maxAbbrev = fallbackAbbrev
  for o in oids:
    if not o.isNull and repo.hasObject(o):
      maxAbbrev = max(maxAbbrev, repo.uniqueAbbrev(o, repo.autoAbbrev).len)
  2 * maxAbbrev + 3

# ---------------------------------------------------------------------------
# Which remote, and with which refspecs
# ---------------------------------------------------------------------------

proc remoteNames*(repo: Repository): seq[string] =
  for e in repo.cfg.withPrefix("remote"):
    let rest = e.key[len("remote.") .. ^1]
    let dot = rest.rfind('.')
    if dot <= 0: continue
    let n = rest[0 ..< dot]
    if n notin result: result.add n
  sort(result)

proc lookupRemote*(repo: Repository, arg: string): Remote =
  ## A configured name, or a URL used directly.  git accepts both everywhere a
  ## remote is named, and the difference shows up afterwards: a URL has no
  ## configured refspec, so a fetch through one updates `FETCH_HEAD` and no
  ## ref at all.
  let url = repo.cfg.get("remote." & arg & ".url")
  if url.len > 0:
    result = Remote(name: arg, url: url)
    for s in repo.cfg.getAll("remote." & arg & ".fetch"):
      result.specs.add parseRefspec(s, forPush = false)
  else:
    failIf(arg.len == 0, "no remote configured")
    result = Remote(name: "", url: arg)

proc defaultRemote*(repo: Repository): string =
  ## `git fetch` with no argument: the current branch's remote, else `origin`
  ## (`remote.c:remote_get`).
  let head = repo.headRefName()
  if head.startsWith("refs/heads/"):
    let r = repo.cfg.get("branch." & head["refs/heads/".len .. ^1] & ".remote")
    if r.len > 0 and r != ".": return r
  let names = repo.remoteNames()
  if "origin" in names or names.len == 0: "origin" else: names[0]

# ---------------------------------------------------------------------------
# The ref map
# ---------------------------------------------------------------------------

proc refPrefixes(specs: seq[Refspec], wantTags: bool): seq[string] =
  ## What to ask `ls-refs` for.  Narrowing this is the whole point of v2's
  ## `ref-prefix`: a repository with a hundred thousand tags should not have
  ## to describe all of them to answer `fetch main`.  When a refspec names a
  ## ref that has to be resolved the way `rev-parse` would, the narrowing is
  ## given up rather than guessed at.
  result.add "HEAD"
  if wantTags: result.add "refs/tags/"
  for s in specs:
    let src = if s.pattern: s.src[0 ..< s.src.find('*')] else: s.src
    if not src.startsWith("refs/"): return @[]
    if src notin result: result.add src

proc buildRefMap(adverts: seq[RemoteRef], inSpecs: seq[Refspec],
                 fetchHead, explicit: bool): seq[Mapped] =
  ## `fetch origin main` names a ref in the *remote's* namespace, so the short
  ## form is resolved against what the remote advertised rather than against
  ## anything here -- `main` is `refs/heads/main` because the remote has one,
  ## and `v1` is `refs/tags/v1` for the same reason
  ## (`remote.c:get_fetch_map`).  A name that matches nothing is fatal when
  ## the user typed it, and silence when a configured pattern produced it.
  var specs = inSpecs
  for s in specs.mitems:
    if s.pattern or s.src.len == 0 or s.src.startsWith(refsPrefix): continue
    var found = ""
    for rule in revParseRules:
      for r in adverts:
        if r.name == rule & s.src: found = r.name; break
      if found.len > 0: break
    failIf(explicit and found.len == 0, "couldn't find remote ref " & s.src)
    if found.len == 0: continue
    if s.hasDst and not s.dst.startsWith(refsPrefix):
      s.dst = (if found.startsWith("refs/tags/"): "refs/tags/"
               else: "refs/heads/") & s.dst
    s.src = found
  for r in adverts:
    if r.name == "HEAD" or r.unborn: continue
    for s in specs:
      let (matched, local) = s.mapRef(r.name)
      if not matched: continue
      failIf(local.len > 0 and not isValidRefname(local),
             "refusing to fetch into '" & local & "': not a valid ref name")
      result.add Mapped(remote: r, local: local, force: s.force,
                        fetchHead: fetchHead)
      break

# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------

type Display = object
  url*: string
  shown: bool
  summaryWidth, refcolWidth: int
  buffered: seq[tuple[code: char, summary, error, remote, local: string]]

proc initDisplay(repo: Repository, url: string, m: seq[Mapped],
                 verbose: bool): Display =
  ## The two column widths git computes before printing anything
  ## (`builtin/fetch.c:refcol_width`, `transport.c:transport_summary_width`).
  ## They are why the report lines up, and why they have to be computed from
  ## the whole map before the first line is written.
  result.url = url
  # A trailing "/" or "/.git" is not shown.
  var n = result.url.len
  while n > 0 and result.url[n - 1] == '/': dec n
  if n > 4 and result.url[n - 4 ..< n] == ".git": n -= 4
  result.url = result.url[0 ..< n]

  var oids: seq[Oid]
  for e in m: oids.add [e.old, e.remote.oid]
  result.summaryWidth = repo.summaryColumn(oids)

  result.refcolWidth = 10
  for e in m:
    if e.local.len == 0 or e.remote.name == "HEAD": continue
    if not verbose and e.old == e.remote.oid: continue
    let rlen = prettify(e.remote.name).len
    let llen = prettify(e.local).len
    if 21 + rlen + 4 + llen >= defaultTermWidth: continue
    result.refcolWidth = max(result.refcolWidth, rlen)

proc emitRefUpdate(d: var Display, width: int, code: char,
                   summary, error, remote, local: string) =
  ## ` %c %-*s %-*s -> %s` plus an optional `  (<error>)`, on **stderr**,
  ## under a `From <url>` header printed before the first line.
  if not d.shown:
    stderr.write "From " & d.url & "\n"
    d.shown = true
  var line = " " & code & " " & summary
  while line.len < 3 + width: line.add ' '
  line.add " "
  var col = prettify(remote)
  while col.len < d.refcolWidth: col.add ' '
  line.add col & " -> " & prettify(local)
  if error.len > 0: line.add "  (" & error & ")"
  stderr.write line & "\n"

proc displayRefUpdate(d: var Display, code: char, summary, error,
                      remote, local: string) =
  ## Held back rather than printed, because the width of the first column is
  ## not known until every ref has been decided: git computes it *after* the
  ## ref transaction and skips the computation entirely when anything was
  ## refused, leaving it zero and the column unpadded
  ## (`builtin/fetch.c`, the `goto cleanup` above `summary_width = ...`).
  ## Reproducing that means buffering, which is what git does too.
  d.buffered.add (code, summary, error, remote, local)

proc flush(d: var Display, rejected: bool) =
  for b in d.buffered:
    d.emitRefUpdate((if rejected: 0 else: d.summaryWidth),
                    b.code, b.summary, b.error, b.remote, b.local)
  d.buffered.setLen(0)

# ---------------------------------------------------------------------------
# FETCH_HEAD
# ---------------------------------------------------------------------------

proc fetchHeadNote(name, url: string): string =
  ## git names the thing and then the place: `branch 'main' of <url>`.  A bare
  ## `HEAD` has no name to give, so the line is just the URL.
  if name == "HEAD": return url
  if name.startsWith("refs/heads/"):
    "branch '" & name["refs/heads/".len .. ^1] & "' of " & url
  elif name.startsWith("refs/tags/"):
    "tag '" & name["refs/tags/".len .. ^1] & "' of " & url
  elif name.startsWith("refs/remotes/"):
    "remote-tracking branch '" & name["refs/remotes/".len .. ^1] &
      "' of " & url
  else:
    "'" & name & "' of " & url

# ---------------------------------------------------------------------------
# The operation
# ---------------------------------------------------------------------------

proc receivePack(repo: Repository, conn: Conn, wants, haves: seq[Oid],
                 includeTag, quiet: bool) =
  ## Take the packfile, and put it in the object store only if it survives
  ## every check.  The temporary lives in `objects/pack/` so that the rename
  ## that installs it never crosses a filesystem.
  let dir = repo.objDirs[0] / "pack"
  createDir(dir)
  let tmp = dir / ("tmp_gittle_" & $getCurrentProcessId() & ".pack")
  var f: File
  failIf(not open(f, tmp, fmWrite), "cannot create '" & tmp & "'")
  var bytes = 0
  try:
    conn.fetchPack(wants, haves, thin = true, includeTag = includeTag,
                   quiet = quiet,
                   sink = proc (data: string) =
                     if data.len > 0:
                       failIf(f.writeBuffer(unsafeAddr data[0],
                                            data.len) != data.len,
                              "short write to " & tmp)
                     bytes += data.len)
  finally:
    f.close()
  if bytes == 0:
    removeFile(tmp)
    return
  let r = installPack(repo, tmp, fixThin = true)
  repo.reopenPacks()
  if r.nObjects == 0:
    # Nothing new after all; an empty pack in the object store is a file every
    # later command would open for no reason.
    let base = repo.objDirs[0] / "pack" / ("pack-" & $r.hash)
    removeFile(base & ".pack")
    removeFile(base & ".idx")
    repo.reopenPacks()

proc negotiationHaves(repo: Repository): seq[Oid] =
  ## What to offer as already present: the tip of every local ref, newest
  ## first, capped.  One round (see [transport.nim](transport.nim)).
  var seen: HashSet[Oid]
  for r in repo.refs.allRefs():
    if r.oid.isNull or r.isSymbolic: continue
    if repo.hasObject(r.oid) and not seen.containsOrIncl(r.oid):
      result.add r.oid
      if result.len >= haveLimit: return

proc fetchFrom*(repo: Repository, rem: Remote, opt: FetchOpts):
    tuple[refs: seq[RemoteRef], head: string, failed: bool] =
  ## Do the whole thing.  Returns every ref the remote advertised, what its
  ## HEAD points at -- `clone` needs both and would otherwise ask twice -- and
  ## whether any ref was refused, which is the command's exit status and not
  ## an error: the refs that could be updated *were*.
  # `FETCH_HEAD` is emptied before anything else, not written at the end.
  # git opens it for writing as the fetch begins, so a fetch that fails
  # leaves an empty one rather than the *previous* fetch's answer -- and a
  # `pull` that ran into an error therefore merges nothing rather than
  # something stale.
  if opt.writeFetchHead: writeFile(repo.gitDir / "FETCH_HEAD", "")
  let program = if opt.uploadPack.len > 0: opt.uploadPack
                else: repo.cfg.get("remote." & rem.name & ".uploadpack")
  let conn = connect(rem.url,
                     if program.len > 0: program else: "git-upload-pack",
                     wantV2 = true)
  defer: conn.finish()
  conn.handshake()
  let adverts = conn.lsRefs(refPrefixes(rem.specs, opt.tags or not opt.noTags))
  result.refs = adverts
  for r in adverts:
    if r.name == "HEAD": result.head = r.symTarget

  var map: seq[Mapped]
  if rem.specs.len > 0:
    map = buildRefMap(adverts, rem.specs, fetchHead = true,
                      explicit = opt.explicitSpecs)
    if opt.explicitSpecs:
      # Everything named on the command line is a merge candidate -- that is
      # what makes `pull origin main` merge what it just fetched.
      for e in map.mitems: e.merge = true
      # **Opportunistic updates.**  A refspec typed by hand says where *this*
      # fetch goes; it does not repeal the remote-tracking layout.  So every
      # ref it fetched is also written to wherever `remote.<name>.fetch` would
      # have put it -- reported, but not written to FETCH_HEAD, where it would
      # only duplicate the line already there
      # (`builtin/fetch.c:get_ref_map`, "opportunistically-updated
      # references").
      var extra: seq[Mapped]
      for e in map:
        for s in opt.configured:
          let (matched, local) = s.mapRef(e.remote.name)
          if not matched or local.len == 0 or local == e.local: continue
          if map.anyIt(it.local == local) or extra.anyIt(it.local == local):
            continue
          extra.add Mapped(remote: e.remote, local: local, force: s.force,
                           oppo: true)
      map.add extra
  elif not opt.tags:
    # No refspec anywhere -- a bare URL.  git fetches the remote's HEAD into
    # FETCH_HEAD and moves nothing (`get_ref_map`'s last `else`).
    for r in adverts:
      if r.name == "HEAD" and not r.unborn:
        map.add Mapped(remote: r, fetchHead: true, merge: true)
        break

  # A branch's configured upstream is a merge candidate even when the refspec
  # that fetched it is a pattern (`add_merge_config`).
  if not opt.explicitSpecs:
    let head = repo.headRefName()
    if head.startsWith("refs/heads/"):
      let b = head["refs/heads/".len .. ^1]
      if repo.cfg.get("branch." & b & ".remote") == rem.name:
        let want = repo.cfg.get("branch." & b & ".merge")
        for e in map.mitems:
          if e.remote.name == want: e.merge = true

  if opt.tags:
    # `--tags` is a refspec of its own, added to whatever else was asked for.
    # No leading `+`: `--tags` fetches every tag, but a tag that already
    # exists here is still refused rather than overwritten (`TAG_REFSPEC`).
    let all = parseRefspec("refs/tags/*:refs/tags/*", forPush = false)
    for r in adverts:
      if not r.name.startsWith("refs/tags/"): continue
      if map.anyIt(it.remote.name == r.name): continue
      map.add Mapped(remote: r, local: all.mapRef(r.name).dst,
                     fetchHead: true)

  # What we do not have yet.  A ref whose object is already here needs no
  # transfer even when the local ref is behind.
  var wants: seq[Oid]
  var seen: HashSet[Oid]
  for e in map.mitems:
    let cur = if e.local.len > 0: repo.refs.readRef(e.local) else: Ref()
    e.old = if cur.found and not cur.isSymbolic: cur.oid else: nullOid
    e.isNew = not cur.found
    if not repo.hasObject(e.remote.oid) and not seen.containsOrIncl(e.remote.oid):
      wants.add e.remote.oid

  if wants.len > 0:
    # Progress is asked for only when there is a terminal to draw it on, which
    # is what makes a scripted fetch silent; git decides the same way and
    # `--progress`, which overrides it, is cut (docs/03).
    receivePack(repo, conn, wants, negotiationHaves(repo),
                includeTag = not opt.noTags,
                quiet = opt.quiet or isatty(2) == 0)
    var tips: seq[Oid]
    for w in wants: tips.add w
    checkConnected(repo, tips)

  # Tags that came along with the history: `include-tag` put them in the pack,
  # and a remote tag whose object is now here becomes a local tag.  Only when
  # some refspec had a *destination*, though -- `fetch origin main` writes no
  # ref, so it follows no tags either (`get_ref_map`'s `*autotags`).
  if not opt.noTags and not opt.tags and opt.autoTags:
    for r in adverts:
      if not r.name.startsWith("refs/tags/"): continue
      if map.anyIt(it.remote.name == r.name): continue
      if not repo.hasObject(r.oid): continue
      if repo.refs.readRef(r.name).found: continue
      map.add Mapped(remote: r, local: r.name, isNew: true, fetchHead: true)

  # git reports in the order its ref map was built, and the opportunistic
  # entries go on the *end* of it -- after the followed tags, which were added
  # before them (`get_ref_map`: "Now append any refs to be updated
  # opportunistically").  A stable partition puts them there.
  map = map.filterIt(not it.oppo) & map.filterIt(it.oppo)

  # ---- move the refs, reporting each one -------------------------------
  var d = initDisplay(repo, rem.url, map, opt.verbose)
  let tx = repo.refs.newTransaction()
  let reflogMsg = (if opt.reflogAction.len > 0: opt.reflogAction
                   else: "fetch") & ": "
  var failed = false

  # **Pruning comes first**, and git orders it this way for a reason worth
  # keeping: a branch deleted upstream and a branch created upstream can
  # collide -- `topic` gone and `topic/2` arrived cannot both exist as loose
  # refs -- and doing the removals first is what lets the second one land.
  if opt.prune:
    var live: HashSet[string]
    for e in map: live.incl e.local
    for s in rem.specs:
      if not s.pattern or not s.hasDst: continue
      let prefix = s.dst[0 ..< s.dst.find('*')]
      for r in repo.refs.allRefs(prefix):
        # `origin/HEAD` is a symbolic ref naming the remote's default branch,
        # not a copy of one of its refs; nothing upstream corresponds to it
        # and pruning it would delete it on every fetch.
        if r.isSymbolic or r.name in live: continue
        tx.add RefUpdate(kind: ruDelete, name: r.name, oldOid: r.oid,
                         haveOldOid: true, msg: reflogMsg & "prune")
        if opt.report:
          # Pruning has a width of its own, measured over the stale refs
          # alone, and prints before anything else (`builtin/fetch.c:1494`).
          d.emitRefUpdate(d.summaryWidth, '-', "[deleted]", "", "(none)", r.name)

  for e in map:
    let isTag = e.remote.name.startsWith("refs/tags/")
    if e.local.len == 0:
      # Fetched into FETCH_HEAD and nowhere else.  git still says so, naming
      # what kind of thing it was (`builtin/fetch.c:store_updated_refs`).
      if opt.report and opt.writeFetchHead:
        d.displayRefUpdate('*', (if isTag: "tag" else: "branch"), "",
                           e.remote.name, "FETCH_HEAD")
      continue
    if e.old == e.remote.oid:
      if opt.verbose and opt.report:
        d.displayRefUpdate('=', "[up to date]", "", e.remote.name, e.local)
      continue
    var code = '*'
    var summary = ""
    var error = ""
    var act = "storing ref"
    if e.isNew:
      summary = if isTag: "[new tag]"
                elif e.remote.name.startsWith("refs/heads/"): "[new branch]"
                else: "[new ref]"
      act = if isTag: "storing tag" else: "storing head"
    elif isTag:
      # An existing tag is only replaced on demand: R1's "write minimally"
      # applied to somebody else's history.
      if not (opt.force or e.force):
        code = '!'; summary = "[rejected]"; error = "would clobber existing tag"
        if opt.report: d.displayRefUpdate(code, summary, error, e.remote.name, e.local)
        failed = true
        continue
      code = 't'; summary = "[tag update]"; act = "updating tag"
    elif repo.isAncestor(e.old, e.remote.oid):
      code = ' '
      summary = repo.uniqueAbbrev(e.old, repo.autoAbbrev) & ".." &
                repo.uniqueAbbrev(e.remote.oid, repo.autoAbbrev)
      act = "fast-forward"
    elif opt.force or e.force:
      code = '+'
      summary = repo.uniqueAbbrev(e.old, repo.autoAbbrev) & "..." &
                repo.uniqueAbbrev(e.remote.oid, repo.autoAbbrev)
      error = "forced update"
      act = "forced-update"
    else:
      code = '!'; summary = "[rejected]"; error = "non-fast-forward"
      if opt.report: d.displayRefUpdate(code, summary, error, e.remote.name, e.local)
      failed = true
      continue
    tx.add RefUpdate(kind: ruSet, name: e.local, newOid: e.remote.oid,
                     oldOid: e.old, haveOldOid: true, msg: reflogMsg & act,
                     noLog: opt.noReflog)
    if opt.report: d.displayRefUpdate(code, summary, error, e.remote.name, e.local)

  if opt.report: d.flush(failed)
  tx.prepare()
  tx.commit()

  # ---- FETCH_HEAD -----------------------------------------------------
  if opt.writeFetchHead:
    var text: string
    for e in map:
      if not e.fetchHead: continue
      text.add $e.remote.oid & "\t" & (if e.merge: "" else: "not-for-merge") &
               "\t" & fetchHeadNote(e.remote.name, d.url) & "\n"
    writeFile(repo.gitDir / "FETCH_HEAD", text)

  result.failed = failed
