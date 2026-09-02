## `tag` -- create, list and delete tags.
##
## Two different things share the name, and the difference is worth being
## clear about because it is visible everywhere else in git:
##
## * a **lightweight** tag is a ref in `refs/tags/` and nothing more, so it
##   points straight at a commit and carries no message, author or date;
## * an **annotated** tag is a real object -- headers, a tagger, a message --
##   that the ref points at instead, and *it* points at the commit.
##
## That is why `%(objecttype)` says `tag` for one and `commit` for the other,
## why `v1.0^{}` exists, and why `packed-refs` has `^` lines: everything that
## follows a tag has to be prepared to take one more step.
##
##     object <oid>          the thing being tagged
##     type <commit|tree|blob|tag>
##     tag <name>            the tag's own name, which is why renaming a tag
##                           by moving the ref leaves it lying about itself
##     tagger <name> <email> <seconds> <tz>
##                           (blank line)
##     <message>
##
## Listing is `for-each-ref` over `refs/tags/` -- `reffilter.nim` -- with the
## format git builds for `-n<num>`: the name padded to fifteen columns, a
## space, and the first `<num>` lines of the message.  Which message depends
## on which kind of tag it is, and asking for "this ref's object's contents"
## answers both without a special case.

import std/strutils
import ../cli, ../commitobj, ../ident, ../objects, ../oid, ../reffilter,
       ../refname, ../refs, ../repository, ../revision, ../util
import foreachref

const
  usageText = """usage: gittle tag [-a] [-f] [-m <msg> | -F <file>] <tagname> [<commit>]
   or: gittle tag -d <tagname>…
   or: gittle tag [-n[<num>]] -l [<pattern>…]

   -a, --annotate            create an annotated tag object
   -m <msg>, --message=<msg> the tag message; implies -a
   -F <file>, --file=<file>  read the message from a file, or `-` for stdin
   -f, --force               replace an existing tag
   -d, --delete              delete tags
   -l, --list                list tags
   -n[<num>]                 with the listing, show <num> lines of annotation
   --contains, --no-contains, --merged, --no-merged, --points-at
   --sort=<key>, --format=<fmt>"""
  tagsPrefix = refsPrefix & "tags/"
  nameColumn = 15
    ## `builtin/tag.c` builds `%(align:15,left)%(refname:lstrip=2)%(end)` for
    ## the `-n` listing; fifteen is git's number and the listing lines up with
    ## git's only if it is ours too.

proc buildTag(repo: Repository, target: Oid, kind: ObjectType,
              name, message: string): Oid =
  ## The bytes, in this order, with no room for variation: an object ID is the
  ## hash of exactly these (R1).
  var data = "object " & $target & "\n"
  data.add "type " & $kind & "\n"
  data.add "tag " & name & "\n"
  # The tagger is the *committer* identity: git has no `GIT_TAGGER_*`
  # (`builtin/tag.c` calls `git_committer_info`).
  data.add "tagger " & $getIdent(repo.cfg, irCommitter) & "\n"
  data.add "\n"
  data.add message
  repo.writeObject(otTag, data)

proc cmdTag*(c: Ctx, args: seq[string]): int =
  var f = RefFilter()
  var annotate, force, del, list = false
  var lines = -1
  var format = ""
  var messages: seq[string]
  var messageFile = ""
  var rest: seq[string]
  var i = 0
  # No short-option bundling here: `-n2` is not a cluster of two flags, and
  # splitting it would turn the annotation count into an unknown option.
  let a2 = args

  optionValue(a2, i)

  while i < a2.len:
    let a = a2[i]
    if a.len > 1 and a[0] == '-':
      case a
      of "-a", "--annotate": annotate = true
      of "-f", "--force": force = true
      of "-d", "--delete": del = true
      of "-l", "--list": list = true
      of "-n": lines = 1
      of "-h", "--help": (echo usageText; return 0)
      of "-s", "--sign", "-u", "--local-user", "-v", "--verify":
        fail(a & " is out of scope for gittle v1 (plan.md decision 5): " &
             "gittle neither makes nor checks signatures")
      of "-e", "--edit", "--cleanup", "--trailer", "--create-reflog":
        fail(a & " is out of scope for gittle v1 (docs/08)")
      else:
        if a == "-m" or a.startsWith("--message"):
          messages.add valueFor(a, "")
          annotate = true
        elif a.len > 2 and a.startsWith("-m"):
          messages.add a[2 .. ^1]         # the stuck `-mmessage` spelling
          annotate = true
        elif a == "-F" or a.startsWith("--file"):
          messageFile = valueFor(a, "")
          annotate = true
        elif a.len > 2 and a.startsWith("-F"):
          messageFile = a[2 .. ^1]
          annotate = true
        elif a.startsWith("--format"): format = valueFor(a, "")
        elif a.len > 2 and a[1] == 'n' and a[2] in {'0' .. '9'}:
          lines = parseInt(a[2 .. ^1])
        elif parseFilterOpt(c, f, a, valueFor): discard
        else: fail("unknown option '" & a & "'\n" & usageText)
    else:
      rest.add a
    inc i

  let repo = c.repo

  if del:
    failIf(rest.len == 0, "tag name required")
    for name in rest:
      let full = tagsPrefix & name
      let r = repo.refs.readRef(full)
      if not r.found:
        stderr.write "error: tag '" & name & "' not found.\n"
        result = 1
        continue
      repo.refs.deleteRef(full)
      echo "Deleted tag '" & name & "' (was " &
           repo.uniqueAbbrev(r.oid, repo.autoAbbrev) & ")"
    return

  # A tag name, with no `-l` and no listing-only option, creates.  Everything
  # else lists, and the leftovers are patterns.
  if rest.len > 0 and not list and lines < 0 and format.len == 0 and
     f.contains.len + f.noContains.len + f.merged.len + f.noMerged.len +
     f.pointsAt.len == 0:
    failIf(rest.len > 2, usageText)
    let name = rest[0]
    failIf(not isValidRefname(tagsPrefix & name, {}),
           "'" & name & "' is not a valid tag name")
    let full = tagsPrefix & name
    let existing = repo.refs.readRef(full)
    failIf(existing.found and not force, "tag '" & name & "' already exists")

    let target = repo.resolveRevish(if rest.len > 1: rest[1] else: "HEAD")
    var oid = target
    if annotate:
      var parts = messages
      if messageFile.len > 0:
        parts.add(if messageFile == "-": stdin.readAll()
                  else: readWholeFile(messageFile))
      # The same cleanup a commit message gets, minus the comment stripping:
      # `-m` is not an editor session, so a line beginning with `#` is text.
      var msg = cleanupMessage(joinMessages(parts), dropComments = false)
      failIf(msg.len == 0, "no tag message?")
      if not msg.endsWith("\n"): msg.add "\n"
      oid = buildTag(repo, target, repo.objectInfo(target).kind, name, msg)
    repo.refs.updateRef(full, oid)
    if existing.found:
      echo "Updated tag '" & name & "' (was " &
           repo.uniqueAbbrev(existing.oid, repo.autoAbbrev) & ")"
    return 0

  f.patterns.add rest
  var rows = repo.collectRefs([tagsPrefix], f)
  for i in 0 ..< rows.len:
    if format.len > 0:
      echo repo.expand(rows[i], format)
    elif lines >= 0:
      let name = rows[i].rf.name[tagsPrefix.len .. ^1]
      echo name.alignLeft(nameColumn) & " " &
           repo.fieldValue(rows[i], "contents:lines=" & $max(lines, 1))
    else:
      echo rows[i].rf.name[tagsPrefix.len .. ^1]
  0
