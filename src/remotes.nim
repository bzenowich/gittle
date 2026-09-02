## Fetching: the ref map, the pack, and the report.
##
## `clone`, `fetch` and `pull` are one operation with three sets of arguments,
## and this is the operation.  It has five steps, and every one of them is a
## named proc that `fetchFrom` calls in order:
##
## 1. **Ask what is there.**  In protocol v0 there is nothing to ask: the
##    advertisement arrived with the handshake and is every ref the remote
##    will admit to ([transport.nim](transport.nim) says why there is no
##    filtering).
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
##    can trade places -- and then the report.
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
## has both rules and `decideUpdate` below follows it case for case.

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

func prettify*(name: string): string =
  ## `refs.c:prettify_refname`: a plain prefix strip, with none of the
  ## ambiguity checking `shortenRef` does.  The report is display, not naming.
  ##
  ## One strip helper for the whole tree, not three (docs/minimize.md §7.1).
  ## `shortenRefname` takes a bare `refs/` off as well, which git's
  ## `prettify_refname` leaves on -- visible only on a ref outside `heads/`,
  ## `tags/` and `remotes/`, and no refspec puts one in a fetch or push report.
  shortenRefname(name)

# ---------------------------------------------------------------------------
# The report, shared by fetch and push
# ---------------------------------------------------------------------------

type RefReport* = object
  ## The block a fetch or a push prints on **stderr**: a header naming the
  ## other end, then one line per ref that changed.
  ##
  ##     From /tmp/src
  ##      * [new branch] main -> origin/main
  ##      ! [rejected] side -> origin/side (non-fast-forward)
  ##
  ## git right-aligns those into columns whose widths are computed across the
  ## whole batch -- twice the longest object-ID abbreviation plus three for
  ## the summary, the longest ref name for the middle
  ## (`transport.c:transport_summary_width`, `builtin/fetch.c:refcol_width`).
  ## It therefore cannot print anything until the last ref has been decided,
  ## and buffers the lot.  gittle prints each line as it is decided, one space
  ## between fields: the same tokens in the same order, no arithmetic, and no
  ## buffer.  docs/minimize.md tier 3 is the licence -- human-facing prose is
  ## compared for content, not bytes.
  ##
  ## The header is printed lazily, before the first line and only if there is
  ## one, which is what makes a fetch that changed nothing print nothing.
  header*: string        ## "From" for a fetch, "To" for a push
  url*: string
  shown: bool

func displayUrl*(url: string): string =
  ## The URL as the report names it: a trailing "/" or "/.git" is noise
  ## (`transport.c:transport_anonymize_url` and its callers strip them).
  result = url.strip(leading = false, chars = {'/'})
  if result.len > 4 and result.endsWith(".git"): result.setLen(result.len - 4)

proc reportRefUpdate*(r: var RefReport, code: char,
                      summary, reason, src, dst: string) =
  ## One ref: ` <code> <summary> <src> -> <dst> (<reason>)`.
  ##
  ## `src` empty means there is nothing to point away from -- a push deleting
  ## a remote ref -- and the arrow goes with it.  A fetch that prunes has the
  ## opposite shape and passes the literal `(none)` as the source, because
  ## that is what git prints there.
  if not r.shown:
    stderr.write r.header & " " & r.url & "\n"
    r.shown = true
  var line = " " & code & " " & summary
  if src.len > 0: line.add " " & prettify(src) & " ->"
  line.add " " & prettify(dst)
  if reason.len > 0: line.add " (" & reason & ")"
  stderr.write line & "\n"

# ---------------------------------------------------------------------------
# Which remote, and with which refspecs
# ---------------------------------------------------------------------------

proc remoteNames*(repo: Repository): seq[string] =
  ## Every remote the config names, in the order their keys appear.
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
      # `expandRule`, not `rule & s.src`: the last rule is
      # `refs/remotes/@/HEAD` and concatenating it matched nothing at all
      # (`remote.c:find_ref_by_name_abbrev` substitutes into every rule).
      for r in adverts:
        if r.name == expandRule(rule, s.src): found = r.name; break
      if found.len > 0: break
    failIf(explicit and found.len == 0, "couldn't find remote ref " & s.src)
    if found.len == 0: continue
    if s.hasDst and not s.dst.startsWith(refsPrefix):
      s.dst = (if found.startsWith("refs/tags/"): "refs/tags/"
               else: "refs/heads/") & s.dst
    s.src = found
  for r in adverts:
    if r.name == "HEAD": continue
    for s in specs:
      let (matched, local) = s.mapRef(r.name)
      if not matched: continue
      failIf(local.len > 0 and not isValidRefname(local),
             "refusing to fetch into '" & local & "': not a valid ref name")
      result.add Mapped(remote: r, local: local, force: s.force,
                        fetchHead: fetchHead)
      break

proc opportunistic(map: seq[Mapped], configured: seq[Refspec]): seq[Mapped] =
  ## A refspec typed by hand says where *this* fetch goes; it does not repeal
  ## the remote-tracking layout.  So every ref it fetched is also written to
  ## wherever `remote.<name>.fetch` would have put it -- reported, but not
  ## written to FETCH_HEAD, where it would only duplicate the line already
  ## there (`builtin/fetch.c:get_ref_map`, "opportunistically-updated
  ## references").
  for e in map:
    for s in configured:
      let (matched, local) = s.mapRef(e.remote.name)
      if not matched or local.len == 0 or local == e.local: continue
      if map.anyIt(it.local == local) or result.anyIt(it.local == local):
        continue
      result.add Mapped(remote: e.remote, local: local, force: s.force,
                        oppo: true)

proc addTags(map: var seq[Mapped], adverts: seq[RemoteRef], all: bool,
             repo: Repository) =
  ## The two ways a tag joins the map, which differ only in the test applied
  ## to each candidate.
  ##
  ## `--tags` is a refspec of its own, added to whatever else was asked for.
  ## It has no leading `+`: every tag is fetched, but one that already exists
  ## here is still refused rather than overwritten (`TAG_REFSPEC`).
  ##
  ## Following, the default, takes only the tags that came along in the pack
  ## -- `include-tag` put them there -- and only those we do not already have
  ## under that name.
  for r in adverts:
    if not r.name.startsWith("refs/tags/"): continue
    if map.anyIt(it.remote.name == r.name): continue
    if not all and (not repo.hasObject(r.oid) or repo.refs.readRef(r.name).found):
      continue
    map.add Mapped(remote: r, local: r.name, isNew: not all, fetchHead: true)

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

proc storeFetchHead(repo: Repository, map: seq[Mapped], url: string) =
  ## Merge candidates first, then the rest: that is what lets `FETCH_HEAD` be
  ## used as a revision naming the thing to merge, which is how `pull` reads
  ## it (`builtin/fetch.c:store_updated_refs`).
  var text: string
  for wantMerge in [true, false]:
    for e in map:
      if not e.fetchHead or e.merge != wantMerge: continue
      text.add $e.remote.oid & "\t" & (if e.merge: "" else: "not-for-merge") &
               "\t" & fetchHeadNote(e.remote.name, url) & "\n"
  writeFile(repo.gitDir / "FETCH_HEAD", text)

# ---------------------------------------------------------------------------
# The operation
# ---------------------------------------------------------------------------

proc receivePack*(repo: Repository, conn: Conn, wants, haves: seq[Oid],
                  includeTag, quiet: bool, thin = true): Oid =
  ## Take the packfile, and put it in the object store only if it survives
  ## every check.  The temporary lives in `objects/pack/` so that the rename
  ## that installs it never crosses a filesystem.  Returns the name of the
  ## pack installed -- its own checksum -- or the null ID when nothing new
  ## arrived.
  ##
  ## `thin` is the one thing `gc` asks for differently (docs/minimize.md
  ## §3.4): a fetch takes a thin pack and appends the bases it is missing,
  ## while `gc` wants the file the server sends to stand on its own, so
  ## that no base is copied out of the pack it is about to keep.
  let dir = repo.objDirs[0] / "pack"
  createDir(dir)
  let tmp = dir / ("tmp_gittle_" & $getCurrentProcessId() & ".pack")
  var f: File
  failIf(not open(f, tmp, fmWrite), "cannot create '" & tmp & "'")
  var bytes = 0
  try:
    conn.fetchPack(wants, haves, thin = thin, includeTag = includeTag,
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
    return nullOid
  let r = installPack(repo, tmp, fixThin = thin)
  repo.reopenPacks()
  if r.nObjects == 0:
    # Nothing new after all; an empty pack in the object store is a file every
    # later command would open for no reason.
    let base = repo.objDirs[0] / "pack" / ("pack-" & $r.hash)
    removeFile(base & ".pack")
    removeFile(base & ".idx")
    repo.reopenPacks()
    return nullOid
  r.hash

proc negotiationHaves(repo: Repository): seq[Oid] =
  ## What to offer as already present: the tip of every local ref, newest
  ## first, capped.  One round (see [transport.nim](transport.nim)).
  var seen: HashSet[Oid]
  for r in repo.refs.allRefs():
    if r.oid.isNull or r.isSymbolic: continue
    if repo.hasObject(r.oid) and not seen.containsOrIncl(r.oid):
      result.add r.oid
      if result.len >= haveLimit: return

proc decideUpdate(repo: Repository, e: Mapped, force: bool):
    tuple[code: char, summary, reason, act: string] =
  ## What one mapped ref becomes: the three fields the report prints, and the
  ## word the reflog records.  A `!` code is a refusal and nothing is written;
  ## every other code is an update.  `builtin/fetch.c:update_local_ref`.
  let isTag = e.remote.name.startsWith("refs/tags/")
  if e.isNew:
    return ('*', (if isTag: "[new tag]"
                  elif e.remote.name.startsWith("refs/heads/"): "[new branch]"
                  else: "[new ref]"), "",
            (if isTag: "storing tag" else: "storing head"))
  if isTag:
    # An existing tag is only replaced on demand: R1's "write minimally"
    # applied to somebody else's history.
    if not force: return ('!', "[rejected]", "would clobber existing tag", "")
    return ('t', "[tag update]", "", "updating tag")
  let a = repo.uniqueAbbrev(e.old, repo.autoAbbrev)
  let b = repo.uniqueAbbrev(e.remote.oid, repo.autoAbbrev)
  if repo.isAncestor(e.old, e.remote.oid):
    return (' ', a & ".." & b, "", "fast-forward")
  if force:
    return ('+', a & "..." & b, "forced update", "forced-update")
  ('!', "[rejected]", "non-fast-forward", "")

proc pruneStale(repo: Repository, specs: seq[Refspec], map: seq[Mapped],
                tx: RefTransaction, reflogMsg: string, rep: var RefReport,
                report: bool) =
  ## Delete the remote-tracking refs the remote no longer has.
  ##
  ## **Pruning goes first** in the transaction, and git orders it this way for
  ## a reason worth keeping: a branch deleted upstream and a branch created
  ## upstream can collide -- `topic` gone and `topic/2` arrived cannot both
  ## exist as loose refs -- and doing the removals first is what lets the
  ## second one land.
  var live: HashSet[string]
  for e in map: live.incl e.local
  for s in specs:
    if not s.pattern or not s.hasDst: continue
    for r in repo.refs.allRefs(s.dst[0 ..< s.dst.find('*')]):
      # `origin/HEAD` is a symbolic ref naming the remote's default branch,
      # not a copy of one of its refs; nothing upstream corresponds to it and
      # pruning it would delete it on every fetch.
      if r.isSymbolic or r.name in live: continue
      tx.add RefUpdate(kind: ruDelete, name: r.name, oldOid: r.oid,
                       haveOldOid: true, msg: reflogMsg & "prune")
      if report: rep.reportRefUpdate('-', "[deleted]", "", "(none)", r.name)

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
                     if program.len > 0: program else: "git-upload-pack")
  defer: conn.finish()
  conn.handshake()
  # No request was sent and none is possible: in v0 the advertisement is the
  # handshake.  Everything the remote has is here, and the refspecs below pick
  # from it.
  let adverts = conn.adverts
  result.refs = adverts
  for r in adverts:
    if r.name == "HEAD": result.head = r.symTarget
  # An empty remote advertises no refs at all, and v0 has no way to say which
  # branch its HEAD names (transport.nim, `handshake`).  git is in the same
  # position and falls back to the branch name it would have used for a fresh
  # repository (`builtin/clone.c`); `init` has already put exactly that in
  # HEAD, so hand `clone` back its own.
  if adverts.len == 0: result.head = repo.headRefName()

  var map: seq[Mapped]
  if rem.specs.len > 0:
    map = buildRefMap(adverts, rem.specs, fetchHead = true,
                      explicit = opt.explicitSpecs)
    if opt.explicitSpecs:
      # Everything named on the command line is a merge candidate -- that is
      # what makes `pull origin main` merge what it just fetched.
      for e in map.mitems: e.merge = true
      map.add opportunistic(map, opt.configured)
  elif not opt.tags:
    # No refspec anywhere -- a bare URL.  git fetches the remote's HEAD into
    # FETCH_HEAD and moves nothing (`get_ref_map`'s last `else`).
    for r in adverts:
      if r.name == "HEAD":
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

  if opt.tags: addTags(map, adverts, all = true, repo = repo)

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
    discard receivePack(repo, conn, wants, negotiationHaves(repo),
                        includeTag = not opt.noTags,
                        quiet = opt.quiet or isatty(2) == 0)
    checkConnected(repo, wants)

  # Tags that came along with the history.  Only when some refspec had a
  # *destination*, though -- `fetch origin main` writes no ref, so it follows
  # no tags either (`get_ref_map`'s `*autotags`).
  if not opt.noTags and not opt.tags and opt.autoTags:
    addTags(map, adverts, all = false, repo = repo)

  # git reports in the order its ref map was built, and the opportunistic
  # entries go on the *end* of it -- after the followed tags, which were added
  # before them (`get_ref_map`: "Now append any refs to be updated
  # opportunistically").  A stable partition puts them there.
  map = map.filterIt(not it.oppo) & map.filterIt(it.oppo)

  # ---- move the refs, reporting each one -------------------------------
  var rep = RefReport(header: "From", url: displayUrl(rem.url))
  let tx = repo.refs.newTransaction()
  let reflogMsg = (if opt.reflogAction.len > 0: opt.reflogAction
                   else: "fetch") & ": "

  if opt.prune:
    pruneStale(repo, rem.specs, map, tx, reflogMsg, rep, opt.report)

  for e in map:
    if e.local.len == 0:
      # Fetched into FETCH_HEAD and nowhere else.  git still says so, naming
      # what kind of thing it was (`builtin/fetch.c:store_updated_refs`).
      if opt.report and opt.writeFetchHead:
        rep.reportRefUpdate('*', (if e.remote.name.startsWith("refs/tags/"):
                                    "tag" else: "branch"),
                            "", e.remote.name, "FETCH_HEAD")
      continue
    if e.old == e.remote.oid:
      if opt.verbose and opt.report:
        rep.reportRefUpdate('=', "[up to date]", "", e.remote.name, e.local)
      continue
    let d = decideUpdate(repo, e, opt.force or e.force)
    if opt.report:
      rep.reportRefUpdate(d.code, d.summary, d.reason, e.remote.name, e.local)
    if d.code == '!':
      result.failed = true
      continue
    tx.add RefUpdate(kind: ruSet, name: e.local, newOid: e.remote.oid,
                     oldOid: e.old, haveOldOid: true, msg: reflogMsg & d.act,
                     noLog: opt.noReflog)

  tx.prepare()
  tx.commit()
  if opt.writeFetchHead: storeFetchHead(repo, map, rep.url)
