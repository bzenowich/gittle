## `clone` -- a new repository from an existing one.
##
## In scope (docs/06): `<repository>`, `<directory>`, `-o`/`--origin`,
## `-b`/`--branch`, `-n`/`--no-checkout`, `--bare`, `-q`, `-v`,
## `-u`/`--upload-pack`.  Everything shallow, partial, submodule, template,
## sparse or reference-borrowing is cut, and so is `--local`: gittle has one
## transport and uses it for local paths too
## ([transport.nim](../transport.nim) says why).
##
## `clone` is not a primitive.  It is `init`, then a `remote add`, then a
## `fetch`, then a `checkout`, and it is written that way here -- the whole of
## the transfer is [remotes.nim](../remotes.nim)'s `fetchFrom`, the same call
## `fetch` makes.  What is left is the four decisions clone has to make that
## fetch never does:
##
## * **where** -- the directory name comes off the end of the URL when it is
##   not given, with `.git` and any trailing slashes removed;
## * **which refspec** -- a bare clone maps the remote's branches onto its own
##   (`+refs/heads/*:refs/heads/*`) and keeps no remote-tracking refs at all,
##   which is why its config has a `url` and no `fetch`;
## * **which branch** -- `-b`, or whatever the remote's HEAD points at, and
##   the local branch is created to match and configured to track it;
## * **no reflogs** -- the refs a clone creates are a copy of what the remote
##   has, not a history of changes made here, so git's initial transaction
##   writes none and gittle passes `noReflog` to say the same.

import std/[os, strutils]
import ../cli, ../index, ../objects, ../oid, ../refname, ../refs, ../refspec,
       ../remotes, ../repository, ../util, ../worktree
import init as cmdinit


proc directoryFor(url: string): string =
  ## `guess_dir_name` in `builtin/clone.c`: the last component of the URL,
  ## without a trailing slash, a `.git` suffix or a `:` from an scp-like
  ## address.
  var s = url
  while s.len > 0 and s[^1] == '/': s.setLen(s.len - 1)
  if s.endsWith(".git"): s.setLen(s.len - 4)
  while s.len > 0 and s[^1] == '/': s.setLen(s.len - 1)
  for sep in ['/', ':']:
    let i = s.rfind(sep)
    if i >= 0: s = s[i + 1 .. ^1]
  failIf(s.len == 0, "cannot guess a directory name from '" & url & "'")
  s

proc cloneInto(c: Ctx, gitDir, dir, url, origin, branchArg, uploadPack: string,
               bare, noCheckout, quiet, verbose: bool) =
  ## Everything after `init`: write the remote's configuration, fetch,
  ## point HEAD where the remote's points, and check out unless told not to.
  # The remote, before the fetch, so that the fetch reads its refspec from the
  # configuration like any other -- there is no clone-only code path.
  let fetchSpec = if bare: "+refs/heads/*:refs/heads/*"
                  else: defaultFetchRefspec(origin)
  setConfigValue(gitDir / "config", "remote." & origin & ".url", url)
  if not bare:
    setConfigValue(gitDir / "config", "remote." & origin & ".fetch", fetchSpec)

  # Open it only now: `openRepository` reads the configuration, and the
  # configuration is what has just been written.
  c.gitDirOpt = gitDir
  c.workTreeOpt = if bare: "" else: dir
  c.bare = bare
  let repo = c.repo

  var rem = Remote(name: origin, url: url,
                   specs: @[parseRefspec(fetchSpec, forPush = false)])
  # A clone takes the tags too -- the refspec above covers branches only, and
  # every tag pointing into the history it brings comes along with it.
  var opt = FetchOpts(quiet: quiet, verbose: verbose, uploadPack: uploadPack,
                      report: false, writeFetchHead: false, noReflog: true,
                      autoTags: true)
  let fetched = repo.fetchFrom(rem, opt)

  # What HEAD should become.  The remote's own HEAD is a symbolic ref and
  # `ls-refs symrefs` is the only way to see through it; without one -- an
  # older server, or a detached remote HEAD -- fall back to the first branch.
  var remoteHead = fetched.head
  if remoteHead.len == 0:
    for r in fetched.refs:
      if r.name.startsWith("refs/heads/"): remoteHead = r.name; break

  var wanted = if branchArg.len > 0: branchArg else: remoteHead
  var target: Oid
  var targetRef = ""
  if wanted.len > 0:
    for r in fetched.refs:
      if r.name == wanted or r.name == "refs/heads/" & wanted or
         r.name == "refs/tags/" & wanted:
        target = r.oid
        targetRef = r.name
        break
  failIf(branchArg.len > 0 and targetRef.len == 0,
         "Remote branch " & branchArg & " not found in upstream " & origin)

  let reflog = "clone: from " & url
  if targetRef.len == 0:
    # An empty repository.  There is nothing to check out and no branch to
    # create -- but HEAD still has to name the branch the *remote* would
    # create, so that a first commit here lands on the same one, and the
    # tracking configuration is written for that branch in advance.  git says
    # so out loud even under `--quiet`, because a clone that produced no files
    # otherwise looks broken.
    stderr.write "warning: You appear to have cloned an empty repository.\n"
    if remoteHead.startsWith("refs/heads/"):
      if repo.headRefName() != remoteHead:
        repo.refs.writeSymRef(headRef, remoteHead, noLog = true)
      if not bare:
        let b = remoteHead["refs/heads/".len .. ^1]
        setConfigValue(gitDir / "config", "branch." & b & ".remote", origin)
        setConfigValue(gitDir / "config", "branch." & b & ".merge", remoteHead)
    return

  let onBranch = targetRef.startsWith("refs/heads/")
  let localBranch = if onBranch: "refs/heads/" & targetRef["refs/heads/".len .. ^1]
                    else: ""
  if not bare:
    if onBranch:
      repo.refs.updateRef(localBranch, target, msg = reflog)
      # The message goes on the symref write, not the branch's: HEAD's log has
      # one entry after a clone, and this is it.
      repo.refs.writeSymRef(headRef, localBranch, reflog)
      # `origin/HEAD` records which branch the remote considers its default.
      if remoteHead.startsWith("refs/heads/"):
        repo.refs.writeSymRef("refs/remotes/" & origin & "/HEAD",
                              "refs/remotes/" & origin & "/" &
                              remoteHead["refs/heads/".len .. ^1], reflog)
      setConfigValue(gitDir / "config",
                     "branch." & targetRef["refs/heads/".len .. ^1] & ".remote",
                     origin)
      setConfigValue(gitDir / "config",
                     "branch." & targetRef["refs/heads/".len .. ^1] & ".merge",
                     targetRef)
    else:
      # `-b <tag>` leaves HEAD detached, exactly as a checkout of a tag would.
      repo.refs.updateRef(headRef, target, msg = reflog, noDeref = true)
  else:
    # A bare clone has the branches themselves; HEAD only has to name one.
    if onBranch: repo.refs.writeSymRef(headRef, localBranch)
    else: repo.refs.updateRef(headRef, target, msg = reflog, noDeref = true)

  if not bare and not noCheckout:
    let idx = readIndex(repo.indexPath)
    let tree = repo.flatten(repo.peelTo(target, otTree).oid)
    repo.resetWorkTree(idx, tree)
    repo.resetIndexTo(idx, tree)
    idx.writeIndex()

const
  synopsis = "[<options>] <repository> [<directory>]"
  options = [
    opt("-o|--origin", okValue, arg = "<name>", help = "name of the remote to create (default: origin)"),
    opt("-b|--branch", okValue, arg = "<name>", help = "check out this branch (or tag) instead of the remote's HEAD"),
    opt("-n|--no-checkout", help = "do not check out a working tree"),
    opt("--bare", help = "create a bare repository"),
    opt("-u|--upload-pack|--exec", okValue, arg = "<exec>", help = "the command to run on the far end"),
    opt("-q|--quiet", help = "report nothing but errors"),
    opt("-v|--verbose", help = "report more"),
    opt("--mirror|--sparse|--separate-git-dir|--template|--reference|--dissociate|" &
        "--recurse-submodules|--single-branch|--no-single-branch|-l|--local|--no-hardlinks|" &
        "-s|--shared|--revision|--ref-format|--bundle-uri", okRefused, help = "docs/06"),
    opt("--depth|--deepen|--shallow-since|--shallow-exclude|--filter", okRefused,
        help = "gittle has no shallow or partial clone (plan.md §1)"),
  ]

proc cmdClone*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, pick the directory, create the repository, then
  ## `cloneInto` -- and remove the directory again if anything fails.
  let o = parse(options, args, "clone", synopsis)
  let origin = o.val("origin", "origin")
  let branchArg = o.val "branch"
  let uploadPack = o.val "upload-pack"
  let bare = c.bare or o.has "bare"
  let noCheckout = o.has "no-checkout"
  let quiet = o.has "quiet"
  let verbose = o.has "verbose"
  let positional = o.args
  failIf(positional.len == 0 or positional.len > 2, o.use)
  failIf(not isValidRefname(refsPrefix & "remotes/" & origin & "/x"),
         "'" & origin & "' is not a valid remote name")

  let url = positional[0]
  let dir = absolutePath(if positional.len > 1: positional[1]
                         else: directoryFor(url), c.startDir).normalizedPath
  if dirExists(dir):
    for _, _ in walkDir(dir):
      fail("destination path '" & dir.lastPathPart &
           "' already exists and is not an empty directory.")
  failIf(fileExists(dir), "'" & dir & "' exists and is not a directory")

  if not quiet:
    echo (if bare: "Cloning into bare repository '" else: "Cloning into '") &
         (if positional.len > 1: positional[1] else: directoryFor(url)) & "'..."

  let gitDir = if bare: dir else: dir / ".git"
  let madeDir = not dirExists(dir)
  createDir(dir)
  discard cmdinit.createRepository(gitDir, bare, cmdinit.defaultInitialBranch())

  # Anything that fails from here on has already created a directory, and a
  # half-cloned repository left where the user asked for a whole one is worse
  # than the error: the next command finds a repository with no HEAD.  git
  # calls this its "junk" and removes it the same way.
  try:
    cloneInto(c, gitDir, dir, url, origin, branchArg, uploadPack,
              bare, noCheckout, quiet, verbose)
  except CatchableError:
    removeDir(gitDir)
    if madeDir: removeDir(dir)
    raise
  0
