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
import cmd/updateref, cmd/symbolicref, cmd/foreachref
import cmd/revparse, cmd/revlist, cmd/mergebase, cmd/mergefile
import cmd/lstree, cmd/writetree, cmd/readtree, cmd/updateindex, cmd/lsfiles
import cmd/config as cmdconfig
import cmd/init, cmd/committree, cmd/add, cmd/log, cmd/commit, cmd/show
import cmd/branch, cmd/tag, cmd/checkout, cmd/reset, cmd/reflog
import cmd/merge as cmdmerge
import cmd/cherrypick, cmd/rebase
import cmd/stash as cmdstash
import cmd/diff as cmddiff
import cmd/status as cmdstatus
import cmd/grep as cmdgrep

const
  version = "gittle version 0.1.0"
  usageText = """usage: gittle [<options>] <command> [<args>]

Options before the command:
   -C <path>             run as if started in <path>
   --git-dir=<path>      set the repository directory
   --work-tree=<path>    set the working tree root
   --bare                treat the repository as bare
   -c <name>=<value>     override a configuration variable
   -P, --no-pager        never page output (gittle never pages)
   -v, --version         print the version
   -h, --help            print this message

Commands:
   add                   stage content into the index
   branch                list, create, rename and delete branches
   cat-file              inspect objects
   checkout              switch branches, or restore files
   cherry-pick           replay existing commits onto this branch
   commit                record the staged content as a new commit
   commit-tree           create a commit object
   config                read and write configuration
   diff                  show changes between trees, index and working tree
   for-each-ref          list refs through a format string
   grep                  search tracked content
   hash-object           compute, and optionally store, an object ID
   init                  create a repository
   log                   show commit history
   ls-files              list index and working-tree files
   ls-tree               list a tree object's entries
   merge                 join another history into this one
   merge-base            find the common ancestor of two commits
   merge-file            three-way merge of three files
   rebase                replay commits onto a different base
   read-tree             load a tree into the index
   reflog                show where a ref has been
   reset                 move HEAD, the index and the working tree
   restore               restore working-tree and index files
   rev-list              walk history and list the objects it reaches
   rev-parse             resolve revisions and report repository layout
   revert                undo commits with new commits
   show                  display objects
   stash                 set aside uncommitted work
   status                report working tree state
   switch                change branches
   symbolic-ref          read and write symbolic refs
   tag                   create, list and delete tags
   update-index          modify the index
   update-ref            create, update and delete refs
   write-tree            write the index out as a tree
   version               print the version"""

proc runVerb(c: Ctx, verb: string, args: seq[string]): int =
  case verb
  of "hash-object": cmdHashObject(c, args)
  of "cat-file": cmdCatFile(c, args)
  of "init": cmdInit(c, args)
  of "add": cmdAdd(c, args)
  of "branch": cmdBranch(c, args)
  of "checkout": cmdCheckout(c, args)
  of "switch": cmdSwitch(c, args)
  of "restore": cmdRestore(c, args)
  of "reset": cmdReset(c, args)
  of "reflog": cmdReflog(c, args)
  of "tag": cmdTag(c, args)
  of "log": cmdLog(c, args)
  of "commit": cmdCommit(c, args)
  of "cherry-pick": cmdCherryPick(c, args)
  of "revert": cmdRevert(c, args)
  of "rebase": cmdRebase(c, args)
  of "show": cmdShow(c, args)
  of "diff": cmddiff.cmdDiff(c, args)
  of "stash": cmdstash.cmdStash(c, args)
  of "status": cmdstatus.cmdStatus(c, args)
  of "grep": cmdgrep.cmdGrep(c, args)
  of "commit-tree": cmdCommitTree(c, args)
  of "merge": cmdmerge.cmdMerge(c, args)
  of "merge-base": cmdMergeBase(c, args)
  of "merge-file": cmdMergeFile(c, args)
  of "rev-list": cmdRevList(c, args)
  of "rev-parse": cmdRevParse(c, args)
  of "update-ref": cmdUpdateRef(c, args)
  of "symbolic-ref": cmdSymbolicRef(c, args)
  of "for-each-ref": cmdForEachRef(c, args)
  of "ls-tree": cmdLsTree(c, args)
  of "write-tree": cmdWriteTree(c, args)
  of "read-tree": cmdReadTree(c, args)
  of "update-index": cmdUpdateIndex(c, args)
  of "ls-files": cmdLsFiles(c, args)
  of "config": cmdconfig.cmdConfig(c, args)
  of "version": (echo version; 0)
  of "help": (echo usageText; 0)
  else:
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
      echo usageText
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
        fail("unknown option: " & a & "\n" & usageText)
    inc i
  ("", @[])

proc main(): int =
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
    echo usageText
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
