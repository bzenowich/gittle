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
## Listing is `for-each-ref` over `refs/tags/` -- `collectRefs` in
## `cmd/foreachref.nim` -- printing names, and nothing else.  The selection and formatting options `tag` once
## shared with `branch` (`--contains`, `--merged`, `--points-at`, `--sort`,
## `--format`) and the `-n<num>` annotation listing were trimmed in the
## minimisation pass (docs/minimize.md §3): a survey of use found `tag -l`
## and nothing more, and `for-each-ref refs/tags` answers every other
## question.  The second pass took `-F <file>` for the same reason
## (docs/minimize-2.md B4): a message from a file is `-m "$(cat file)"`.
## Each refuses by name rather than being silently ignored.
## Taking `-n<num>` out is also what lets `tag` bundle short options like
## every other command: `-n2` was the one spelling that was not a cluster.

import std/strutils
import ../cli, ../commitobj, ../ident, ../objects, ../oid,
       ../refname, ../refs, ../repository, ../revision, ../util
import foreachref

const tagsPrefix = refsPrefix & "tags/"

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

const
  synopsis = "[-a] [-f] [-m <msg>] <tagname> [<commit>]\n-d <tagname>…\n[-l] [<pattern>…]"
  options = [
    opt("-a|--annotate", help = "make an annotated tag object, not a plain ref"),
    opt("-f|--force", help = "replace an existing tag"),
    opt("-d|--delete", help = "delete tags"),
    opt("-l|--list", help = "list tags, optionally matching patterns"),
    opt("-m|--message", okValue, arg = "<msg>", help = "the message; repeatable, paragraphs joined; implies -a"),
    opt("-F|--file", okRefused,
        help = "trimmed (docs/minimize-2.md B4); pass the text to -m"),
    opt("-s|--sign|-u|--local-user|-v|--verify", okRefused,
        help = "gittle neither makes nor checks signatures (plan.md decision 5)"),
    opt("-e|--edit|--cleanup|--trailer|--create-reflog", okRefused, help = "docs/08"),
    opt("-n|--sort|--format|--contains|--no-contains|--merged|--no-merged|--points-at",
        okRefused, help = "trimmed (docs/minimize.md §3); use for-each-ref refs/tags"),
  ]

proc cmdTag*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, then delete, list, or create -- a plain ref, or a
  ## tag object first when annotated.
  let o = parse(options, args, "tag", synopsis)
  let force = o.has "force"
  let del = o.has "delete"
  let list = o.has "list"
  let messages = o.vals "message"
  let annotate = o.has("annotate") or messages.len > 0
  let rest = o.args
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

  # A tag name with no `-l` creates.  Everything else lists, and the
  # leftovers are patterns.
  if rest.len > 0 and not list:
    failIf(rest.len > 2, o.use)
    let name = rest[0]
    failIf(not isValidRefname(tagsPrefix & name, {}),
           "'" & name & "' is not a valid tag name.")
    let full = tagsPrefix & name
    let existing = repo.refs.readRef(full)
    failIf(existing.found and not force, "tag '" & name & "' already exists")

    let target = repo.resolveRevish(if rest.len > 1: rest[1] else: "HEAD")
    var oid = target
    if annotate:
      # The same cleanup a commit message gets, minus the comment stripping:
      # `-m` is not an editor session, so a line beginning with `#` is text.
      var msg = cleanupMessage(joinMessages(messages), dropComments = false)
      failIf(msg.len == 0, "no tag message?")
      if not msg.endsWith("\n"): msg.add "\n"
      oid = buildTag(repo, target, repo.objectInfo(target).kind, name, msg)
    repo.refs.updateRef(full, oid)
    if existing.found:
      echo "Updated tag '" & name & "' (was " &
           repo.uniqueAbbrev(existing.oid, repo.autoAbbrev) & ")"
    return 0

  for row in repo.collectRefs([tagsPrefix], RefFilter(patterns: rest)):
    echo row.rf.name[tagsPrefix.len .. ^1]
  0
