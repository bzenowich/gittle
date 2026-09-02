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


proc showTree(repo: Repository, name: string, tree: Oid) =
  ## `show` on a tree: its name, then one entry per line as git prints it.
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

const
  synopsis = "[<options>] [<object>…]"
  options = [
    opt("--oneline", help = "one line per commit: abbreviated ID and subject"),
    opt("--abbrev-commit", help = "abbreviate the commit ID"),
    opt("--no-abbrev-commit"),
    opt("--relative-date", okRefused, help = "docs/minimize.md §3"),
    opt("--decorate", okOptValue, arg = "[=short]", help = "show the refs at each commit"),
    opt("--no-decorate"),
    opt("--abbrev", okValue, arg = "<n>", help = "abbreviate object IDs to <n> digits"),
    opt("--date", okValue, arg = "<format>", help = "the date format"),
    opt("--pretty|--format", okOptValue, key = "format", arg = "[=<format>]",
        help = "the commit format: oneline, medium, full, fuller, raw, format:<fmt>"),
  ]

proc cmdShow*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, then show each object by type -- a commit with
  ## its diff, a tag with what it points at, a tree's entries, a blob's
  ## bytes.
  let p = parse(@options & @diffOptions, args, "show", synopsis)
  var opts = PrettyOpts(kind: pkMedium, now: dateNow())
  var dopts = defaultDiffOpts()
  applyDiffOpts(p, dopts)
  var abbrevLen = 0
  for (k, v) in p.occurrences:
    case k
    of "oneline": (opts.kind = pkOneline; opts.abbrevCommit = true)
    of "abbrev-commit": opts.abbrevCommit = true
    of "no-abbrev-commit": opts.abbrevCommit = false
    of "abbrev": abbrevLen = parseInt(v)
    of "date": opts.dateMode = parseDateMode(v)
    of "decorate": opts.decorate = true
    of "format": parsePretty(v, opts)
    else: discard
  var names = p.args
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
    ## A commit's text followed by its diff against its first parent (none
    ## for a merge, as `--diff-merges=off` says).
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
