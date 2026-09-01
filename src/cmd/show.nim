## `show` -- display objects.
##
## In scope (docs/08): `<object>…`, defaulting to HEAD, plus the pretty and
## date options `log` takes.
##
## `show` is four commands wearing one name, chosen by the type of what it is
## given:
##
## | type | what is printed |
## |---|---|
## | commit | `log -1` for it, **and its diff** -- phase 5 |
## | tag | the tag header and message, then the object it points at |
## | tree | `tree <what you typed>`, a blank line, then the entry names, with a `/` after each directory |
## | blob | the bytes, unaltered |
##
## The commit case is the visible gap in this phase: `gittle show <commit>`
## prints what `git show -s <commit>` prints, and the patch under it arrives
## with the diff engine.  Nothing else about the command changes then.
##
## Note the tree header: git echoes **the name you asked with**, not the object
## ID, so `show HEAD:Documentation` says `tree HEAD:Documentation`.

import std/[strutils, times]
import ../cli, ../commitobj, ../ident, ../pretty, ../repository, ../util

const usageText = """usage: gittle show [<options>] [<object>…]

   --pretty=<fmt>, --format=<fmt>, --oneline, --abbrev-commit, --abbrev=<n>,
   --date=<fmt>, --decorate[=…], -s/--no-patch   -- as for `log`"""

proc showTree(repo: Repository, name: string, tree: Oid) =
  echo "tree " & name & "\n"
  for e in treeEntries(repo.readObject(tree).data):
    echo e.name & (if modeType(e.mode) == otTree: "/" else: "")

proc showTag(repo: Repository, o: Oid, obj: GitObject, opts: PrettyOpts) =
  ## A tag object's own headers, then its message, then whatever it points at.
  let tagger = headerField(obj.data, "tagger")
  echo "tag " & headerField(obj.data, "tag")
  if tagger.len > 0:
    let id = parseIdentLine(tagger)
    echo "Tagger: " & id.name & " <" & id.email & ">"
    echo "Date:   " & formatDate(id.when0, id.tzOffset, opts.dateMode, opts.now)
  echo ""
  let blank = obj.data.find("\n\n")
  if blank >= 0: stdout.write obj.data[blank + 2 .. ^1]

proc cmdShow*(c: Ctx, args: seq[string]): int =
  var opts = PrettyOpts(kind: pkMedium, now: getTime().toUnix())
  var abbrevLen = 0
  var names: seq[string]
  var i = 0

  proc valueFor(a: string): string =
    let eq = a.find('=')
    if eq > 0: return a[eq + 1 .. ^1]
    inc i
    failIf(i >= args.len, "option '" & a & "' requires a value")
    args[i]

  while i < args.len:
    let a = args[i]
    if a.len == 0 or a[0] != '-':
      names.add a
    elif a == "--": discard
    elif a == "-s" or a == "--no-patch": discard   # gittle has no patch yet
    elif a == "--oneline":
      opts.kind = pkOneline
      opts.abbrevCommit = true
    elif a == "--abbrev-commit": opts.abbrevCommit = true
    elif a == "--no-abbrev-commit": opts.abbrevCommit = false
    elif a == "--relative-date": opts.dateMode = DateMode(kind: dkRelative)
    elif a == "--no-decorate": discard
    elif a.startsWith("--abbrev"): abbrevLen = parseInt(valueFor(a))
    elif a.startsWith("--date"): opts.dateMode = parseDateMode(valueFor(a))
    elif a.startsWith("--decorate"): opts.decorate = true
    elif a.startsWith("--pretty") or a.startsWith("--format"):
      parsePretty((if a.contains('='): a[a.find('=') + 1 .. ^1] else: ""), opts)
    elif a == "-h" or a == "--help":
      echo usageText
      return 0
    elif a in ["-p", "-u", "--patch", "--stat", "--name-only", "--name-status",
               "--raw", "--numstat", "--shortstat"]:
      fail(a & " is not implemented in this version\n" &
           "  the diff engine arrives in phase 5")
    else:
      fail("unknown option '" & a & "'\n" & usageText)
    inc i

  if names.len == 0: names.add headRef
  let repo = c.repo
  opts.abbrev = if abbrevLen > 0: abbrevLen else: repo.autoAbbrev

  var shownOne = false
  for name in names:
    # A tag is a pointer, so showing one shows what it points at -- and a tag
    # of a tag (`v1.0rc1` in the repository next door) unwraps all the way
    # down, which is why this is a loop rather than one extra step.
    var o = repo.resolveOid(name)
    var label = name
    while true:
      let obj = repo.readObject(o)
      case obj.kind
      of otCommit:
        # git puts a blank line before every commit but the first shown
        # (`log-tree.c`, the `shown_one` newline), which is also what separates
        # a tag from the commit it names.
        if shownOne: stdout.write entrySeparator(opts.kind)
        stdout.write formatOne(repo, o, parseCommit(obj.data), opts)
      of otTag:
        if shownOne: stdout.write entrySeparator(opts.kind)
        showTag(repo, o, obj, opts)
      of otTree: showTree(repo, label, o)
      of otBlob: stdout.write obj.data
      else: fail("cannot show " & $obj.kind & " object " & $o)
      shownOne = true
      if obj.kind != otTag: break
      o = parseOid(headerField(obj.data, "object"))
      label = $o
  stdout.flushFile()
  0
