## `init` -- create a repository.
##
## In scope (docs/07): `-q`, `--bare`, `-b`/`--initial-branch`, `[<directory>]`.
## `--template` is cut, which is the one visible difference from git: a
## gittle-created repository has no `hooks/*.sample`, no `description` and no
## `info/exclude`.  None of the three is read by anything -- the samples are
## inert, and an absent `info/exclude` is an empty one -- so the repository is
## still one git opens and operates on without noticing.
##
## `--object-format`, `--ref-format`, `--separate-git-dir` and `--shared` are
## out of scope by decision: sha256 and reftable are refused by the extension
## gate (plan.md 6.1), and the other two are layout variants nothing needs.

import std/[os, strutils]
import ../cli, ../config, ../refs, ../refname, ../util

const usageText = """usage: gittle init [-q] [--bare] [-b <branch-name>] [<directory>]"""

const
  bareConfig = "[core]\n\trepositoryformatversion = 0\n" &
               "\tfilemode = true\n\tbare = true\n"
  workConfig = "[core]\n\trepositoryformatversion = 0\n" &
               "\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n"
    ## Byte-identical to what git writes with an empty template directory.
    ## `filemode` is written true rather than probed: decision 6 makes gittle
    ## Linux-only, and every filesystem it will meet honors the execute bit.

proc createRepository*(gitDir: string, bare: bool, branch: string): bool =
  ## Lay out a repository, and report whether one was already there.
  ##
  ## Shared with `clone`, which is `init` plus a `fetch` plus a `checkout` and
  ## must produce exactly the same directory for the same options.
  ##
  ## A repository already here is re-initialised, not replaced: git creates
  ## whatever is missing and leaves HEAD, the config and every ref alone.  That
  ## is what makes `git init` safe to run twice, and losing a branch to a typed
  ## command that usually does nothing would be unforgivable.
  result = fileExists(gitDir / "HEAD")
  for d in ["objects/info", "objects/pack", "refs/heads", "refs/tags"]:
    createDir(gitDir / d)
  if not result:
    writeFile(gitDir / "HEAD", "ref: refs/heads/" & branch & "\n")
    writeFile(gitDir / "config", if bare: bareConfig else: workConfig)

proc defaultInitialBranch*(): string =
  ## `init.defaultBranch` from the *user's* configuration: there is no
  ## repository yet to read one from.  git 2.55 still defaults to `master` and
  ## warns that 3.0 will change it; gittle follows the version it is
  ## compatible with rather than the one that does not exist.
  result = loadConfig(globalConfigPath()).get("init.defaultBranch")
  if result.len == 0: result = "master"

proc cmdInit*(c: Ctx, args: seq[string]): int =
  var quiet = false
  var bare = c.bare
  var branch = ""
  var dirArg = ""
  var i = 0
  var noMoreOpts = false
  while i < args.len:
    let a = args[i]
    if noMoreOpts or a.len == 0 or a[0] != '-':
      failIf(dirArg.len > 0, "too many arguments\n" & usageText)
      dirArg = a
    elif a == "--": noMoreOpts = true
    elif a == "-q" or a == "--quiet": quiet = true
    elif a == "--bare": bare = true
    elif a == "-b" or a == "--initial-branch":
      inc i
      failIf(i >= args.len, "option '" & a & "' requires a value")
      branch = args[i]
    elif a.startsWith("--initial-branch="):
      branch = a["--initial-branch=".len .. ^1]
    elif a.startsWith("-b"):
      branch = a[2 .. ^1]
    elif a == "-h" or a == "--help":
      echo usageText
      return 0
    elif a in ["--object-format", "--ref-format", "--template",
               "--separate-git-dir", "--shared"] or
         a.startsWith("--object-format=") or a.startsWith("--ref-format=") or
         a.startsWith("--template=") or a.startsWith("--separate-git-dir=") or
         a.startsWith("--shared="):
      fail(a.split('=')[0] & " is not supported by gittle\n" &
           "  gittle creates a sha1, 'files'-backend repository at the given path")
    else:
      fail("unknown option '" & a & "'\n" & usageText)
    inc i

  # The working tree, then the git directory inside it -- or, when bare, the
  # directory *is* the git directory.
  let root = if dirArg.len > 0: absolutePath(dirArg, c.startDir).normalizedPath
             else: c.startDir
  let gitDir = if bare: root else: root / ".git"

  if branch.len == 0: branch = defaultInitialBranch()
  failIf(not isValidRefname(refsPrefix & "heads/" & branch),
         "invalid initial branch name: '" & branch & "'")
  let existing = createRepository(gitDir, bare, branch)

  if not quiet:
    # git prints the git directory with a trailing slash, and says which of the
    # two things it did.
    echo (if existing: "Reinitialized existing" else: "Initialized empty") &
         " Git repository in " & gitDir & "/"
  0
