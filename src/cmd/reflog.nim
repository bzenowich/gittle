## `reflog show` -- where a ref has been.
##
## A reflog is the only record of a value a ref *used* to have.  Nothing in
## the object graph points at the commit an amended `HEAD` left behind, or at
## the branch tip a `reset --hard` discarded; the reflog does, and that is why
## it is the first thing to reach for after a mistake.
##
##     <old-oid> SP <new-oid> SP <who> TAB <message> LF
##
## One line per change, appended, so the file is oldest first and `@{0}` --
## the current value -- is the last line.  `revision.nim` reads it, because
## `HEAD@{2}` is revision syntax and has to.
##
## `reflog show` is documented as an alias for `log -g`, and the default
## output is that of `log --oneline` with the reflog selector in place of the
## decoration:
##
##     1630431 HEAD@{0}: commit: the subject line
##
## `expire`, `delete` and `drop` are cut (docs/11): they are the pruning half,
## and a repository whose reflogs are never pruned is merely larger.

import std/strutils
import ../cli, ../commitobj, ../refs, ../repository, ../revision,
       ../revwalk, ../util

const
  synopsis = "[show] [-n <count>] [<ref>]"
  options = [
    opt("-n|--max-count", okValue, key = "n", arg = "<count>",
        help = "show only the newest <count> entries; -<count> says the same"),
  ]

proc cmdReflog*(c: Ctx, args: seq[string]): int =
  ## Only `show` is implemented; `expire`, `delete`, `drop`, `exists` and
  ## `write` are out of scope (docs/11).
  let o = parse(options, args, "reflog", synopsis, numeric = true)
  var rest: seq[string]
  for a in o.args:
    if a in ["expire", "delete", "drop", "exists", "write", "list"]:
      fail("'reflog " & a & "' is out of scope for gittle v1 (docs/11)")
    elif a != "show": rest.add a
  let maxCount = if o.has "n": parseInt(o.val "n") else: -1
  let repo = c.repo
  # A bare name is a ref, and `HEAD` is the default -- the same DWIM every
  # other command uses, so `reflog main` and `reflog refs/heads/main` agree.
  var name = headRef
  if rest.len > 0:
    # Expanded, not resolved: `reflog HEAD` wants HEAD's own log, and HEAD is
    # a symbolic ref whose log is a different file from the branch's.
    name = repo.refs.expandRefName(rest[0])
    failIf(name.len == 0, "'" & rest[0] & "' is not a valid ref")

  let log = repo.refs.readReflog(name)
  let short = repo.refs.shortenRef(name)
  var shown = 0
  # Newest first: the file is written oldest first, and `@{0}` is the newest,
  # so the numbering and the listing both run backwards through it.
  for k in countdown(log.high, 0):
    if maxCount >= 0 and shown >= maxCount: break
    inc shown
    let e = log[k]
    var line = repo.uniqueAbbrev(e.newOid, repo.autoAbbrev) & " " &
               short & "@{" & $(log.high - k) & "}: " & e.message
    # An entry written by a tool that passed no message still names a commit,
    # and the subject is what identifies it.
    if e.message.len == 0:
      line.add subject(repo.readCommit(e.newOid).message)
    echo line
  stdout.flushFile()
  0
