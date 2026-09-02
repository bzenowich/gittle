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
## | commit | `log -1` for it, and its diff against its first parent |
## | tag | the tag header and message, then the object it points at |
## | tree | `tree <what you typed>`, a blank line, then the entry names, with a `/` after each directory |
## | blob | the bytes, unaltered |
##
## A merge commit gets no patch, only its header: the combined-diff formats
## are cut (docs/03), which leaves `--diff-merges=off`.  A root commit is
## diffed against the empty tree, so every path in it is a creation.
##
## Note the tree header: git echoes **the name you asked with**, not the object
## ID, so `show HEAD:Documentation` says `tree HEAD:Documentation`.

import std/strutils
import ../cli, ../commitobj, ../diffcore, ../ident, ../pathspec, ../pretty,
       ../repository, ../revision, ../util

const usageText = """usage: gittle show [<options>] [<object>…]

   --pretty=<fmt>, --format=<fmt>, --oneline, --abbrev-commit, --abbrev=<n>,
   --date=<fmt>, --decorate[=…]                  -- as for `log`
   -p, -s, --stat, --numstat, --raw, --name-only, -U<n>, -w, --color …
                                                -- as for `gittle diff`"""

proc showTree(repo: Repository, name: string, tree: Oid) =
  echo "tree " & name & "\n"
  for e in treeEntries(repo.readObject(tree).data):
    echo e.name & (if modeType(e.mode) == otTree: "/" else: "")

proc showTag(repo: Repository, o: Oid, obj: GitObject, opts: PrettyOpts) =
  ## A tag object's own headers, then its message, then whatever it points at.
  ##
  ## Which header lines appear depends on the pretty format, and not the way a
  ## commit's do (`builtin/log.c:show_tagger` through `pretty.c:pp_user_info`):
  ## `oneline` prints **no** identity at all; `medium` adds a `Date:` line and
  ## `fuller` a `TaggerDate:` one, with the `Tagger:` label padded to match;
  ## `full`, `raw` and any user format get the `Tagger:` line on its own.
  let tagger = headerField(obj.data, "tagger")
  echo "tag " & headerField(obj.data, "tag")
  if tagger.len > 0 and opts.kind != pkOneline:
    let id = parseIdentLine(tagger)
    let pad = if opts.kind == pkFuller: "    " else: ""
    echo "Tagger: " & pad & id.name & " <" & id.email & ">"
    if opts.kind == pkMedium:
      echo "Date:   " & formatDate(id.when0, id.tzOffset, opts.dateMode, opts.now)
    elif opts.kind == pkFuller:
      echo "TaggerDate: " &
           formatDate(id.when0, id.tzOffset, opts.dateMode, opts.now)
  echo ""
  let blank = obj.data.find("\n\n")
  if blank >= 0: stdout.write obj.data[blank + 2 .. ^1]

proc cmdShow*(c: Ctx, args: seq[string]): int =
  var opts = PrettyOpts(kind: pkMedium, now: dateNow())
  var dopts = defaultDiffOpts()
  var abbrevLen = 0
  var names: seq[string]
  var i = 0

  optionValue(args, i)

  while i < args.len:
    let a = args[i]
    if a.len == 0 or a[0] != '-':
      names.add a
    elif a == "--": discard
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
    elif parseDiffOpt(a, dopts, valueFor): discard
    else:
      fail("unknown option '" & a & "'\n" & usageText)
    inc i

  if names.len == 0: names.add headRef
  # `show` patches by default; `log` does not.  That single difference is the
  # whole of what distinguishes them once the walk is limited to one commit.
  if dopts.formats.card == 0: dopts.formats = {dfPatch}
  checkDiffOpts(dopts)
  opts.nulTerminate = dopts.nulTerminate

  let repo = c.repo
  opts.abbrev = if abbrevLen > 0: abbrevLen else: repo.autoAbbrev
  # git has one `--abbrev`, shared by the commit header and the diff's `index`
  # line, so the value has to reach both option sets.
  if abbrevLen > 0: dopts.abbrev = abbrevLen
  let ps = parsePathspec(@[], repo.prefix)

  proc withDiff(o: Oid, commit: Commit): string =
    result = formatOne(repo, o, commit, opts)
    if dopts.formats == {dfNone} or commit.parents.len > 1: return
    let old = if commit.parents.len == 1:
                repo.peelTo(commit.parents[0], otTree).oid
              else: nullOid
    let d = renderDiff(repo, pairsTreeTree(repo, old, commit.tree, ps), dopts)
    if not d.changed: return
    if opts.kind != pkOneline:
      if dfStat in dopts.formats and dfPatch in dopts.formats: result.add "---"
      result.add "\n"
    result.add d.text

  var shownOne = false
  for name in names:
    # A tag is a pointer, so showing one shows what it points at -- and a tag
    # of a tag (`v1.0rc1` in the repository next door) unwraps all the way
    # down, which is why this is a loop rather than one extra step.
    var o = repo.resolveRevish(name)
    var label = name
    while true:
      let obj = repo.readObject(o)
      case obj.kind
      of otCommit:
        # git puts a blank line before every commit but the first shown
        # (`log-tree.c`, the `shown_one` newline), which is also what separates
        # a tag from the commit it names.
        if shownOne: stdout.write entrySeparator(opts.kind, dopts.nulTerminate)
        stdout.write withDiff(o, parseCommit(obj.data))
      of otTag:
        # A tag is separated from whatever preceded it by a bare newline
        # whatever the format is -- `builtin/log.c` prints it directly rather
        # than going through the pretty machinery, so `--oneline`, which
        # separates commits with nothing, still separates tags with a blank.
        if shownOne: stdout.write "\n"
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
