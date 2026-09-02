## `update-ref` -- create, update and delete references.
##
## In scope (docs/10): `<ref> <new> [<old>]`, `-d`, `--stdin`, `-z`, `-m`.
##
## The single-ref form is a convenience.  The interesting one is `--stdin`,
## which reads a batch of commands and applies them as one transaction: either
## every ref moves or none does.  `fetch` and `receive-pack` are both defined
## in terms of that guarantee, so it is built now and reused in phase 8 rather
## than bolted on later.
##
## The command language, from `Documentation/git-update-ref.adoc`:
##
##     update SP <ref> SP <new> [SP <old>] LF
##     create SP <ref> SP <new> LF
##     delete SP <ref> [SP <old>] LF
##     verify SP <ref> [SP <old>] LF
##     symref-update SP <ref> SP <target> [SP (ref SP <old> | oid SP <old>)] LF
##     symref-create SP <ref> SP <target> LF
##     symref-delete SP <ref> [SP <old>] LF
##     symref-verify SP <ref> [SP <old>] LF
##     option SP <option> LF
##     start LF / prepare LF / commit LF / abort LF
##
## With `-z` every field is terminated by NUL instead, and values are taken
## literally; without it a value may be C-quoted, which is how a ref name
## containing a space would be spelled -- except that refname.nim forbids
## spaces, so in practice quoting only ever appears around a value that did not
## need it.

import std/[strutils]
import ../cli, ../oid, ../repository, ../revision, ../util

const usageText = """usage: gittle update-ref [-m <reason>] <ref> <new-oid> [<old-oid>]
   or: gittle update-ref [-m <reason>] -d <ref> [<old-oid>]
   or: gittle update-ref [-m <reason>] [-z] --stdin"""

# ---------------------------------------------------------------------------
# The --stdin command stream
# ---------------------------------------------------------------------------
#
# The wire format, from `builtin/update-ref.c`, is simpler than the
# documentation's grammar makes it look.  Input is a sequence of *records*,
# each ending in a newline -- or, with `-z`, a NUL.  The first record holds the
# verb and, after a space, its first argument.  Every command takes a fixed
# number of arguments, and with `-z` the remaining ones are further records.
#
# Two consequences that a grammar-shaped reader gets wrong and a record-counting
# one gets right:
#
# * An **omitted** argument and an **empty** one are different.  With `-z`,
#   `update <ref> NUL <new> NUL NUL` supplies an empty old value; leaving off
#   that last record supplies none.  Knowing how many records a verb takes is
#   the only way to tell them apart.
# * An empty value does not mean the same thing in both modes.  Without `-z` it
#   is the null object ID; with `-z` an empty *old* value means "unspecified",
#   while an empty *new* value still means the null object ID.
#
# And the null object ID as a new value is a **delete**, not an error -- which
# is how a script deletes a ref and checks its old value in the same command.

type
  Arg = tuple[present: bool, value: string]

  Reader = object
    ## A cursor over the whole of stdin.  Reading it up front is not a
    ## limitation worth avoiding: a transaction has to be held in memory to be
    ## applied atomically anyway, so streaming would buy nothing.
    data: string
    pos: int
    terminator: char   ## '\n', or NUL with -z

proc atEnd(r: Reader): bool = r.pos >= r.data.len

proc nextRecord(r: var Reader): Arg =
  ## Everything up to the next terminator, which is consumed.
  if r.atEnd: return (false, "")
  let stop = r.data.find(r.terminator, r.pos)
  let last = if stop < 0: r.data.len else: stop
  result = (true, r.data[r.pos ..< last])
  r.pos = if stop < 0: r.data.len else: stop + 1

proc unquoteC(s: string): string =
  ## Undo `quote_c_style`, which is how a value containing a space or a quote
  ## is spelled when the stream is not NUL-separated.  Only the escapes git
  ## emits are accepted; anything else is malformed rather than something to
  ## guess at.
  var i = 1  # skip the opening quote
  while i < s.len and s[i] != '"':
    if s[i] != '\\':
      result.add s[i]
      inc i
      continue
    inc i
    failIf(i >= s.len, "badly quoted argument: " & s)
    var found = false
    for (raw, letter) in cEscapes:
      if s[i] == letter:
        result.add raw
        found = true
        break
    if found: discard
    elif s[i] in {'0' .. '7'}:
      var v = 0
      var n = 0
      while n < 3 and i < s.len and s[i] in {'0' .. '7'}:
        v = v * 8 + (ord(s[i]) - ord('0'))
        inc i
        inc n
      dec i
      result.add char(v)
    else:
      fail("badly quoted argument: " & s)
    inc i

proc splitLineArgs(rest: string, want: int, verb: string): seq[Arg] =
  ## Without `-z`, every argument lives in the first record, separated by
  ## spaces and optionally C-quoted.
  var i = 0
  while result.len < want:
    while i < rest.len and rest[i] == ' ': inc i
    if i >= rest.len: break
    if rest[i] == '"':
      var j = i + 1
      while j < rest.len and rest[j] != '"':
        if rest[j] == '\\': inc j
        inc j
      failIf(j >= rest.len, verb & ": unterminated quoted argument")
      result.add (true, unquoteC(rest[i .. j]))
      i = j + 1
    else:
      var j = i
      while j < rest.len and rest[j] != ' ': inc j
      result.add (true, rest[i ..< j])
      i = j
  while i < rest.len and rest[i] == ' ': inc i
  failIf(i < rest.len, verb & ": extra input: " & rest[i .. ^1])

proc readArgs(r: var Reader, first: string, want: int, verb: string): seq[Arg] =
  ## The `want` arguments of one command, each flagged present or absent.
  if r.terminator == '\n':
    result = splitLineArgs(first, want, verb)
  else:
    if want > 0: result.add (true, first)
    while result.len < want:
      let rec = r.nextRecord()
      if not rec.present: break
      result.add rec
  while result.len < want: result.add (false, "")

# ---------------------------------------------------------------------------
# The command grammar, as a table
# ---------------------------------------------------------------------------

type
  NewValue = enum nvNone, nvOid, nvTarget
  OldValue = enum
    ovNone         ## the command takes no old value
    ovOid          ## an optional object ID
    ovTarget       ## an optional symref target
    ovTagged       ## `ref <target>` or `oid <oid>`, as symref-update spells it
    ovMustNotExist ## no argument: the verb itself means "must not exist"

  Grammar = tuple[kind: RefUpdateKind; newValue: NewValue; oldValue: OldValue;
                  args: int; needsNoDeref: bool]

const grammar = [
  # verb             what it does    new value  old value       args  requires
  #                                                                   no-deref
  ("update",        (ruSet,          nvOid,     ovOid,          3,    false)),
  ("create",        (ruSet,          nvOid,     ovMustNotExist, 2,    false)),
  ("delete",        (ruDelete,       nvNone,    ovOid,          2,    false)),
  ("verify",        (ruVerify,       nvNone,    ovOid,          2,    false)),
  ("symref-update", (ruSetSymbolic,  nvTarget,  ovTagged,       4,    false)),
  ("symref-create", (ruSetSymbolic,  nvTarget,  ovNone,         2,    false)),
  ("symref-delete", (ruDelete,       nvNone,    ovTarget,       2,    true)),
  ("symref-verify", (ruVerify,       nvNone,    ovTarget,       2,    true)),
]
  ## Every command is "a ref name, then perhaps a new value, then perhaps an
  ## old value to check", differing only in which of those it takes and what it
  ## does with them.  `args` is git's own count for each verb, and it is what
  ## lets an omitted argument be told from an empty one under `-z`.

proc grammarFor(verb: string): Grammar =
  for (name, g) in grammar:
    if name == verb: return g
  fail("unknown command: " & verb)

type
  Phase = enum
    ## The transaction state machine (`builtin/update-ref.c`).  The order
    ## matters: a command may advance the state but never take it backwards,
    ## which is how an `update` inside a `start` block does not end the block.
    phOpen      ## no explicit transaction; commit at end of input
    phStarted   ## inside `start`
    phPrepared  ## after `prepare`
    phClosed    ## after `commit` or `abort`

func phaseOf(verb: string): Phase =
  ## The state a command moves the stream into.  Everything that changes a ref
  ## leaves the state alone, which `phOpen` expresses: it is the lowest.
  case verb
  of "start": phStarted
  of "prepare": phPrepared
  of "commit", "abort": phClosed
  else: phOpen

# ---------------------------------------------------------------------------
# Running the stream
# ---------------------------------------------------------------------------

proc runStdin(c: Ctx, nulTerminated: bool, defaultMsg: string): int =
  let repo = c.repo
  var r = Reader(data: readAll(stdin), pos: 0,
                 terminator: if nulTerminated: '\0' else: '\n')
  var tx = repo.refs.newTransaction()
  var phase = phOpen
  # `option no-deref` applies to the command that follows it and to nothing
  # else, so it is cleared after every command that consumes it.
  var noDeref = false

  # An empty old value means "must not exist" without -z and "unspecified"
  # with it (`builtin/update-ref.c:parse_next_oid`).  The `symref-` verbs read
  # their old value with `parse_next_arg` instead, which tolerates a stream
  # that simply stops -- which is why only `ovOid` insists below.
  let emptyOldIsNull = not nulTerminated

  try:
    while true:
      let rec = r.nextRecord()
      if not rec.present: break
      if rec.value.len == 0: continue        # a blank record between commands
      let sp = rec.value.find(' ')
      let verb = if sp < 0: rec.value else: rec.value[0 ..< sp]
      let first = if sp < 0: "" else: rec.value[sp + 1 .. ^1]

      # Advance the state machine before running the command, so an illegal
      # sequence is refused rather than half applied.
      let want = phaseOf(verb)
      case phase
      of phOpen, phStarted:
        failIf(phase == phStarted and want == phStarted,
               "cannot restart ongoing transaction")
        if want >= phase: phase = want
      of phPrepared:
        failIf(want != phClosed, "prepared transactions can only be closed")
        phase = want
      of phClosed:
        # Only `start` may follow a closed transaction, and it opens a new one.
        failIf(want != phStarted, "transaction is closed")
        phase = want
        tx = repo.refs.newTransaction()

      # The four control commands each acknowledge themselves on stdout, which
      # is how a caller driving this stream knows a `prepare` took the locks.
      case verb
      of "start":
        echo "start: ok"
        continue
      of "prepare":
        tx.prepare()
        echo "prepare: ok"
        continue
      of "commit":
        if not tx.isPrepared: tx.prepare()
        tx.commit()
        echo "commit: ok"
        continue
      of "abort":
        tx.abort()
        echo "abort: ok"
        continue
      of "option":
        # `no-deref` is the only option git defines.  It applies to the next
        # command only, and the two `symref-` commands that operate on a
        # symbolic ref itself *require* it to have been given.
        failIf(first != "no-deref", "option unknown: " & first)
        noDeref = true
        continue
      else: discard

      let g = grammarFor(verb)
      failIf(g.needsNoDeref and not noDeref,
             verb & ": cannot operate with deref mode")
      let args = r.readArgs(first, g.args, verb)
      # Note that `symref-update` and `symref-create` deref by default like
      # everything else: only `option no-deref` stops them, and the two verbs
      # that cannot work with dereferencing on demand it above.
      var u = RefUpdate(kind: g.kind, noDeref: noDeref, msg: defaultMsg)
      noDeref = false

      failIf(not args[0].present or args[0].value.len == 0,
             verb & ": missing <ref>")
      u.name = args[0].value
      var next = 1

      case g.newValue
      of nvNone: discard
      of nvTarget:
        failIf(not args[next].present, verb & ": missing <new-target>")
        u.newTarget = args[next].value
        inc next
      of nvOid:
        failIf(not args[next].present, verb & ": missing <new-oid>")
        # An empty new value is the null object ID, and setting a ref to the
        # null object ID is how this stream spells a delete.
        if args[next].value.len == 0: u.kind = ruDelete
        else: u.newOid = repo.resolveRevish(args[next].value)
        inc next

      case g.oldValue
      of ovNone: discard
      of ovMustNotExist:
        u.haveOldOid = true            # an expected value of null: must not exist
      of ovTagged:
        # `symref-update` names the kind of its old value, because either an
        # object ID or a symref target can be asserted.
        if args[next].present and args[next].value.len > 0:
          let kind = args[next].value
          let val = args[next + 1]
          failIf(not val.present, verb & ": expected old value")
          case kind
          of "ref":
            u.haveOldTarget = true
            u.oldTarget = val.value
          of "oid":
            u.haveOldOid = true
            if val.value.len > 0: u.oldOid = repo.resolveRevish(val.value)
          else:
            fail(verb & ": expected 'ref' or 'oid', got '" & kind & "'")
      of ovTarget:
        if args[next].present and args[next].value.len > 0:
          u.haveOldTarget = true
          u.oldTarget = args[next].value
      of ovOid:
        # With -z the record has to be there.  git's `parse_next_oid` treats
        # end of input as an error and only an *empty* record as "unspecified",
        # so a stream that just stops is malformed rather than terse.
        failIf(nulTerminated and not args[next].present,
               verb & ": unexpected end of input when reading <old-oid>")
        if args[next].present and (args[next].value.len > 0 or emptyOldIsNull):
          u.haveOldOid = true
          if args[next].value.len > 0:
            u.oldOid = repo.resolveRevish(args[next].value)

      failIf(g.kind == ruVerify and not (u.haveOldOid or u.haveOldTarget),
             verb & ": missing the value to verify")
      tx.add u

    # At end of input: an implicit transaction commits, but an explicit one
    # that was never committed is **aborted**.  Someone who wrote `start` and
    # then stopped did not ask for these updates.
    case phase
    of phOpen:
      tx.prepare()
      tx.commit()
    of phStarted, phPrepared:
      tx.abort()
    of phClosed:
      discard
  except CatchableError:
    tx.abort()
    raise
  0

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

proc cmdUpdateRef*(c: Ctx, args: seq[string]): int =
  var del = false
  var fromStdin = false
  var nulTerminated = false
  var msg = ""
  var rest: seq[string]
  var i = 0
  var noMoreOpts = false
  while i < args.len:
    let a = args[i]
    if noMoreOpts:
      rest.add a
    elif a == "--":
      noMoreOpts = true
    elif a == "-d" or a == "--delete":
      del = true
    elif a == "--stdin":
      fromStdin = true
    elif a == "-z":
      nulTerminated = true
    elif a == "-m":
      inc i
      failIf(i >= args.len, "option '-m' requires a value")
      msg = args[i]
    elif a == "-h" or a == "--help":
      echo usageText
      return 0
    elif a.len > 1 and a[0] == '-':
      fail("unknown option '" & a & "'\n" & usageText)
    else:
      rest.add a
    inc i

  if fromStdin:
    failIf(rest.len > 0 or del, usageText)
    return runStdin(c, nulTerminated, msg)
  failIf(nulTerminated, "-z is only meaningful with --stdin")

  let repo = c.repo
  if del:
    failIf(rest.len < 1 or rest.len > 2, usageText)
    if rest.len == 2:
      repo.refs.deleteRef(rest[0], repo.resolveRevish(rest[1]), checkOld = true,
                          msg = msg)
    else:
      repo.refs.deleteRef(rest[0], msg = msg)
    return 0

  failIf(rest.len < 2 or rest.len > 3, usageText)
  let newOid = repo.resolveRevish(rest[1])
  if rest.len == 3:
    # An empty old value, or the null OID, both mean "must not exist".
    let oldOid = if rest[2].len == 0: nullOid else: repo.resolveRevish(rest[2])
    repo.refs.updateRef(rest[0], newOid, oldOid, checkOld = true, msg = msg)
  else:
    repo.refs.updateRef(rest[0], newOid, msg = msg)
  0
