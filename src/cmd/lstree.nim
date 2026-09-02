## `ls-tree` -- list a tree object's entries.
##
## In scope (docs/09): `<tree-ish>`, `[<path>…]`, `-d`, `-r`, `-t`, `-l`,
## `-z`, `--name-only`, `--abbrev`.
##
## The default line is `<mode> <type> <oid>\t<name>`, with the mode padded to
## six octal digits -- the *display* form, not the form stored in the tree
## (see `trees.nim:formatTree`).  `-l` inserts the object's size, right-aligned
## in a seven-column field, with `-` for anything that is not a blob.

import std/[strutils]
import ../cli, ../objects, ../oid, ../repository, ../revision,
       ../trees, ../util

const usageText = "usage: gittle ls-tree [-d] [-r] [-t] [-l] [-z] " &
                  "[--name-only] [--abbrev[=<n>]] <tree-ish> [<path>…]"

proc matchesPaths(name: string, mode: uint32, paths: seq[string]): bool =
  ## Does this entry match one of the path arguments?
  ##
  ## **`ls-tree` does no wildcard matching**, despite its manual page calling
  ## the arguments "a list of patterns to match".  `git ls-tree -r HEAD -- '*.c'`
  ## lists nothing at all, where `git ls-files -- '*.c'` lists 641 files; the
  ## command allows only `literal` and `top` pathspec magic
  ## (`builtin/ls-tree.c:420`).  Matching is therefore exact paths and directory
  ## prefixes, and a `*` in an argument is a literal asterisk.
  ##
  ## A directory also matches on the way *down* to something that matches, so
  ## that `-t` can print the trees leading to a named file.
  if paths.len == 0: return true
  for p in paths:
    let pat = p.strip(leading = false, chars = {'/'})
    if name == pat: return true
    if name.startsWith(pat & "/"): return true
    if mode == modeTree and pat.startsWith(name & "/"): return true
  false

proc cmdLsTree*(c: Ctx, args: seq[string]): int =
  var recurse = false
  var showTrees = false
  var dirsOnly = false
  var long = false
  var nameOnly = false
  var nulTerminated = false
  var abbrevLen = 0
  var rest: seq[string]
  var i = 0
  var noMoreOpts = false
  while i < args.len:
    let a = args[i]
    if noMoreOpts or a.len == 0 or a[0] != '-':
      rest.add a
    elif a == "--": noMoreOpts = true
    elif a == "-r": recurse = true
    elif a == "-t": showTrees = true
    elif a == "-d": dirsOnly = true
    elif a == "-l" or a == "--long": long = true
    elif a == "-z": nulTerminated = true
    elif a == "--name-only" or a == "--name-status": nameOnly = true
    elif a == "--abbrev": abbrevLen = -1   # resolved below, once the repo is open
    elif a.startsWith("--abbrev="): abbrevLen = parseInt(a["--abbrev=".len .. ^1])
    elif a == "-h" or a == "--help":
      echo usageText
      return 0
    else: fail("unknown option '" & a & "'\n" & usageText)
    inc i

  failIf(rest.len < 1, usageText)
  let repo = c.repo
  let root = repo.resolveTree(rest[0])
  let paths = rest[1 .. ^1]
  if abbrevLen < 0: abbrevLen = repo.autoAbbrev()
  let terminator = if nulTerminated: '\0' else: '\n'

  # `-d -r` together imply `-t`, since otherwise they would print nothing.
  if dirsOnly and recurse: showTrees = true

  # Descend into a directory when `-r` says so, or when a path argument names
  # something strictly below it (`builtin/ls-tree.c:show_recursive`).  That
  # second case is why `ls-tree HEAD -- t/x.sh` finds the file without `-r`.
  let descend = proc (e: TreeEntry): bool =
    if recurse: return true
    for p in paths:
      # The *raw* argument, trailing slash and all: `ls-tree HEAD -- t/`
      # descends into `t` where `-- t` does not, because git compares the spec
      # as written and the slash is what makes it name something below.
      if p.len > e.name.len and p.startsWith(e.name) and p[e.name.len] == '/':
        return true
    false

  for e in repo.walkTree(root, descend = descend):
    let kind = modeType(e.mode)
    # git's two filters, exactly (`show_tree_common`): `-d` drops **blobs** --
    # not everything that is not a tree, so a gitlink still shows -- and a tree
    # is dropped when it was descended into unless `-t` asks for it.
    if dirsOnly and kind == otBlob: continue
    if kind == otTree and descend(e) and not showTrees: continue
    if not matchesPaths(e.name, e.mode, paths): continue

    let shown = if nulTerminated: e.name else: quotePath(e.name)
    if nameOnly:
      stdout.write shown, terminator
      continue
    stdout.write formatMode(e.mode), " ", $kind, " "
    stdout.write(if abbrevLen > 0: repo.uniqueAbbrev(e.oid, abbrevLen)
                 else: $e.oid)
    if long:
      let size = if kind == otBlob: $repo.objectInfo(e.oid).size else: "-"
      stdout.write " ", align(size, 7)
    stdout.write "\t", shown, terminator
  stdout.flushFile()
  0
