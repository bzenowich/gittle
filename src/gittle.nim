## gittle -- a minimal git.
##
## One binary, busybox-style (plan.md 6.3).  `main` looks at
## `basename(argv[0])` first: a `git-<verb>` name dispatches straight to that
## verb, and a `git` symlink makes gittle a drop-in on `PATH`.
##
## This used to be load-bearing rather than a convenience -- a client
## connecting over ssh runs the literal command `git-upload-pack '<path>'`, so
## a serving host had to have that name resolve.  The server was cut after
## phase 6 (plan.md 6 decision 2) and nothing requires the dispatch now; it
## stays because it is twelve lines, already tested, and the `git` symlink is
## what lets a system have both without gittle shadowing a real one.

import std/[os, posix, strutils]
import cli, config, util
import cmd/hashobject, cmd/catfile
import cmd/updateref, cmd/foreachref
import cmd/revparse, cmd/revlist, cmd/mergebase, cmd/mergefile
import cmd/lstree, cmd/writetree, cmd/lsfiles
import cmd/config as cmdconfig
import cmd/init, cmd/add, cmd/log, cmd/commit, cmd/show
import cmd/branch, cmd/tag, cmd/checkout, cmd/reset, cmd/reflog
import cmd/merge as cmdmerge
import cmd/cherrypick, cmd/rebase
import cmd/stash as cmdstash
import cmd/diff as cmddiff
import cmd/status as cmdstatus
import cmd/grep as cmdgrep
import cmd/clone, cmd/fetch
import cmd/push as cmdpush, cmd/remote as cmdremote
import cmd/pull as cmdpull
import cmd/checkignore, cmd/rm as cmdrm, cmd/mv as cmdmv
import cmd/clean as cmdclean
import cmd/worktree as cmdworktree
import cmd/gc as cmdgc

const version = "gittle version 0.1.0"

# The `help` text, built from the command table.
proc usageText(): string
  ## Forward: the `help` row below prints it, and it is built from the rows.

type Command = tuple[name: string, run: proc (c: Ctx, args: seq[string]): int,
                     summary: string]

const commands: array[46, Command] = [
  ("add", cmdAdd, "stage content into the index"),
  ("branch", cmdBranch, "list, create, rename and delete branches"),
  ("cat-file", cmdCatFile, "inspect objects"),
  ("check-ignore", cmdCheckIgnore, "say why a path is ignored"),
  ("checkout", cmdCheckout, "switch branches, or restore files"),
  ("cherry-pick", cmdCherryPick, "replay existing commits onto this branch"),
  ("clean", cmdclean.cmdClean, "delete untracked files"),
  ("clone", cmdClone, "copy a repository into a new directory"),
  ("commit", cmdCommit, "record the staged content as a new commit"),
  ("config", cmdconfig.cmdConfig, "read and write configuration"),
  ("diff", cmddiff.cmdDiff, "show changes between trees, index and working tree"),
  ("fetch", cmdFetch, "download objects and refs from a remote"),
  ("for-each-ref", cmdForEachRef, "list refs through a format string"),
  ("gc", cmdgc.cmdGc, "pack this repository's history, with the remote's help"),
  ("grep", cmdgrep.cmdGrep, "search tracked content"),
  ("hash-object", cmdHashObject, "compute, and optionally store, an object ID"),
  ("init", cmdInit, "create a repository"),
  ("log", cmdLog, "show commit history"),
  ("ls-files", cmdLsFiles, "list index and working-tree files"),
  ("ls-tree", cmdLsTree, "list a tree object's entries"),
  ("merge", cmdmerge.cmdMerge, "join another history into this one"),
  ("merge-base", cmdMergeBase, "find the common ancestor of two commits"),
  ("merge-file", cmdMergeFile, "three-way merge of three files"),
  ("mv", cmdmv.cmdMv, "move or rename a tracked path"),
  ("pull", cmdpull.cmdPull, "fetch from a remote and integrate"),
  ("push", cmdpush.cmdPush, "send refs and objects to a remote"),
  ("rebase", cmdRebase, "replay commits onto a different base"),
  ("reflog", cmdReflog, "show where a ref has been"),
  ("remote", cmdremote.cmdRemote, "manage the set of named remotes"),
  ("reset", cmdReset, "move HEAD, the index and the working tree"),
  ("restore", cmdRestore, "restore working-tree and index files"),
  ("rev-list", cmdRevList, "walk history and list the objects it reaches"),
  ("rev-parse", cmdRevParse, "resolve revisions and report repository layout"),
  ("rm", cmdrm.cmdRm, "remove files from the working tree and the index"),
  ("revert", cmdRevert, "undo commits with new commits"),
  ("show", cmdShow, "display objects"),
  ("stash", cmdstash.cmdStash, "set aside uncommitted work"),
  ("stage", cmdAdd, "stage content into the index (an alias of add)"),
  ("status", cmdstatus.cmdStatus, "report working tree state"),
  ("switch", cmdSwitch, "change branches"),
  ("tag", cmdTag, "create, list and delete tags"),
  ("update-ref", cmdUpdateRef, "create, update and delete refs"),
  ("worktree", cmdworktree.cmdWorktree, "manage linked working trees"),
  ("write-tree", cmdWriteTree, "write the index out as a tree"),
  ("version", proc (c: Ctx, args: seq[string]): int = (echo version; 0),
   "print the version"),
  ("help", proc (c: Ctx, args: seq[string]): int = (echo usageText(); 0),
   "print this message"),
]
  ## Every verb, its entry point and one line for `help`.  The table is the
  ## dispatch and the usage text both, so a command cannot be listed without
  ## being runnable or the other way round.

proc usageText(): string =
  ## The `help` text, built from the command table.
  result = """usage: gittle [<options>] <command> [<args>]

Options before the command:
   -C <path>             run as if started in <path>
   --git-dir=<path>      set the repository directory
   --work-tree=<path>    set the working tree root
   --bare                treat the repository as bare
   -c <name>=<value>     override a configuration variable
   -P, --no-pager        never page output (gittle never pages)
   -v, --version         print the version
   -h, --help            print this message

Commands:"""
  for cmd in commands:
    result.add "\n   " & cmd.name.alignLeft(22) & cmd.summary

proc runVerb(c: Ctx, verb: string, args: seq[string]): int =
  ## Dispatch a verb through the table.
  for cmd in commands:
    if cmd.name == verb: return cmd.run(c, args)
  fail("'" & verb & "' is not a gittle command. See 'gittle help'.")

proc parseDriver(c: Ctx, argv: seq[string]): tuple[verb: string, rest: seq[string]] =
  ## Consume the options the `git` wrapper itself takes, stopping at the first
  ## thing that is not one (docs/02).
  var i = 0
  while i < argv.len:
    let a = argv[i]
    if a.len == 0 or a[0] != '-':
      return (a, argv[i + 1 .. ^1])
    case a
    of "-v", "--version":
      echo version
      exitWith(0)
    of "-h", "--help":
      echo usageText()
      exitWith(0)
    of "-C":
      inc i
      failIf(i >= argv.len, "option '-C' requires a value")
      # Repeatable and cumulative, so each one is resolved against the last.
      c.startDir = absolutePath(argv[i], c.startDir).normalizedPath
      failIf(not dirExists(c.startDir), "cannot change to '" & argv[i] & "'")
    of "-c":
      inc i
      failIf(i >= argv.len, "option '-c' requires a value")
      let eq = argv[i].find('=')
      failIf(eq <= 0, "invalid config format: " & argv[i])
      c.overrides.entries.add ConfigEntry(key: argv[i][0 ..< eq],
                                          value: argv[i][eq + 1 .. ^1])
    of "--bare":
      c.bare = true
    of "-P", "--no-pager":
      discard  # gittle never pages
    else:
      if a.startsWith("--git-dir="):
        c.gitDirOpt = a["--git-dir=".len .. ^1]
      elif a.startsWith("--work-tree="):
        c.workTreeOpt = a["--work-tree=".len .. ^1]
      elif a.startsWith("-C"):
        c.startDir = absolutePath(a[2 .. ^1], c.startDir).normalizedPath
      else:
        fail("unknown option: " & a & "\n" & usageText())
    inc i
  ("", @[])

proc main(): int =
  ## argv[0] dispatch, then the driver options, then the verb.
  var c = Ctx(startDir: getCurrentDir())
  let argv = commandLineParams()

  # argv[0] dispatch.  `git-<verb>` runs that verb directly; `gittle` and `git`
  # parse a subcommand normally.  It has to be argv[0] as invoked, not
  # `getAppFilename`, which resolves the symlink back to the real binary.
  let self = paramStr(0).lastPathPart
  if self.startsWith("git-"):
    return runVerb(c, self[4 .. ^1], argv)

  let (verb, rest) = parseDriver(c, argv)
  if verb.len == 0:
    echo usageText()
    return 1
  runVerb(c, verb, rest)

when isMainModule:
  try:
    exitWith(main())
  except GittleError as e:
    stderr.write "gittle: " & e.msg & "\n"
    exitWith(128)   # git's status for a fatal error
  except IOError as e:
    # A closed pipe (`gittle cat-file -p ... | head`) is not an error, and it
    # is the only write failure that is not: everything else -- a full disk,
    # a directory where a file should be -- has to be reported, or a command
    # that wrote half its output would exit 0.
    if errno == EPIPE: exitWith(0)
    stderr.write "gittle: " & e.msg & "\n"
    exitWith(128)
