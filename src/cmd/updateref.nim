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
import ../cli, ../oid, ../repository, ../util

const usageText = """usage: gittle update-ref [-m <reason>] <ref> <new-oid> [<old-oid>]
   or: gittle update-ref [-m <reason>] -d <ref> [<old-oid>]
   or: gittle update-ref [-m <reason>] [-z] --stdin"""

# ---------------------------------------------------------------------------
# The --stdin command stream
# ---------------------------------------------------------------------------

type
  Reader = object
    ## A cursor over the whole of stdin.  Reading the lot up front is not a
    ## limitation worth avoiding: a transaction has to be held in memory to be
    ## applied atomically anyway, so streaming would buy nothing.
    data: string
    pos: int
    nulTerminated: bool

proc atEnd(r: Reader): bool = r.pos >= r.data.len

proc unquoteC(s: string, whole: string): string =
  ## Undo git's `quote_c_style`.  Only the escapes git emits are accepted;
  ## anything else is a malformed command rather than something to guess at.
  var i = 1  # skip the opening quote
  while i < s.len and s[i] != '"':
    if s[i] == '\\':
      inc i
      failIf(i >= s.len, "badly quoted argument: " & whole)
      case s[i]
      of 'n': result.add '\n'
      of 't': result.add '\t'
      of 'r': result.add '\r'
      of 'a': result.add '\a'
      of 'b': result.add '\b'
      of 'f': result.add '\f'
      of 'v': result.add '\v'
      of '"': result.add '"'
      of '\\': result.add '\\'
      of '0' .. '7':
        var v = 0
        var n = 0
        while n < 3 and i < s.len and s[i] in {'0' .. '7'}:
          v = v * 8 + (ord(s[i]) - ord('0'))
          inc i
          inc n
        dec i
        result.add char(v)
      else: fail("badly quoted argument: " & whole)
    else:
      result.add s[i]
    inc i

proc nextField(r: var Reader, whole: string): tuple[got: bool, value: string] =
  ## One field of a command.
  ##
  ## In NUL mode a field simply runs to the next NUL, so an empty field is
  ## representable and means "no value" -- that is how `delete <ref>` with no
  ## old value is distinguished from `delete <ref> <null-oid>`.
  if r.nulTerminated:
    if r.atEnd: return (false, "")
    let nul = r.data.find('\0', r.pos)
    failIf(nul < 0, "unterminated field in command stream")
    result = (true, r.data[r.pos ..< nul])
    r.pos = nul + 1
  else:
    while r.pos < r.data.len and r.data[r.pos] == ' ': inc r.pos
    if r.atEnd or r.data[r.pos] == '\n': return (false, "")
    if r.data[r.pos] == '"':
      var i = r.pos + 1
      while i < r.data.len and r.data[i] != '"':
        if r.data[i] == '\\': inc i
        inc i
      failIf(i >= r.data.len, "unterminated quoted argument")
      result = (true, unquoteC(r.data[r.pos .. i], whole))
      r.pos = i + 1
    else:
      var i = r.pos
      while i < r.data.len and r.data[i] notin {' ', '\n'}: inc i
      result = (true, r.data[r.pos ..< i])
      r.pos = i

proc endOfCommand(r: var Reader) =
  ## In line mode, consume the rest of the line; in NUL mode there is nothing
  ## to consume, because every field already ended with its own NUL.
  if r.nulTerminated: return
  while r.pos < r.data.len and r.data[r.pos] != '\n': inc r.pos
  if r.pos < r.data.len: inc r.pos

proc nextCommand(r: var Reader): tuple[got: bool, verb: string] =
  if r.nulTerminated:
    # The verb and its first argument are separated by a space even in NUL
    # mode -- only the *arguments* are NUL-separated (see the documentation's
    # note on `-z`).  Read up to the first space or NUL.
    while not r.atEnd and r.data[r.pos] == '\0': inc r.pos
    if r.atEnd: return (false, "")
    var i = r.pos
    while i < r.data.len and r.data[i] notin {' ', '\0'}: inc i
    result = (true, r.data[r.pos ..< i])
    r.pos = if i < r.data.len and r.data[i] == ' ': i + 1 else: i
  else:
    while not r.atEnd and r.data[r.pos] in {'\n', ' '}: inc r.pos
    if r.atEnd: return (false, "")
    var i = r.pos
    while i < r.data.len and r.data[i] notin {' ', '\n'}: inc i
    result = (true, r.data[r.pos ..< i])
    r.pos = i

proc requireField(r: var Reader, verb, what: string): string =
  let f = r.nextField(verb)
  failIf(not f.got, verb & ": missing <" & what & ">")
  f.value

proc runStdin(c: Ctx, nulTerminated: bool, defaultMsg: string): int =
  ## Read the whole command stream, then apply it as one transaction.
  let repo = c.repo
  var r = Reader(data: readAll(stdin), pos: 0, nulTerminated: nulTerminated)
  let tx = repo.refs.newTransaction()
  var explicitCommit = false

  try:
    while true:
      let (got, verb) = r.nextCommand()
      if not got: break
      var u = RefUpdate(msg: defaultMsg)

      case verb
      of "update", "create", "delete", "verify":
        u.name = r.requireField(verb, "ref")
        if verb == "update" or verb == "create":
          let newVal = r.requireField(verb, "new-oid")
          u.kind = ruSet
          u.newOid = repo.resolveOid(newVal)
        elif verb == "delete":
          u.kind = ruDelete
        else:
          u.kind = ruVerify
        if verb == "create":
          # `create` means "must not exist", which is the null old value.
          u.haveOldOid = true
          u.oldOid = nullOid
        else:
          let old = r.nextField(verb)
          if old.got and old.value.len > 0:
            u.haveOldOid = true
            u.oldOid = repo.resolveOid(old.value)
          elif old.got:
            u.haveOldOid = true
            u.oldOid = nullOid
        if verb == "verify":
          failIf(not u.haveOldOid, "verify: missing <old-oid>")

      of "symref-update", "symref-create", "symref-delete", "symref-verify":
        u.noDeref = true
        u.name = r.requireField(verb, "ref")
        case verb
        of "symref-update", "symref-create":
          u.kind = ruSetSymbolic
          u.newTarget = r.requireField(verb, "new-target")
        of "symref-delete":
          u.kind = ruDelete
        else:
          u.kind = ruVerify
        if verb == "symref-create":
          u.haveOldOid = true
          u.oldOid = nullOid
        elif verb == "symref-update":
          # The optional old value is introduced by the word `ref` or `oid`.
          let tag = r.nextField(verb)
          if tag.got and tag.value.len > 0:
            case tag.value
            of "ref":
              u.haveOldTarget = true
              u.oldTarget = r.requireField(verb, "old-target")
            of "oid":
              u.haveOldOid = true
              let v = r.requireField(verb, "old-oid")
              u.oldOid = if v.len == 0: nullOid else: repo.resolveOid(v)
            else:
              fail("symref-update: expected 'ref' or 'oid', got '" &
                   tag.value & "'")
        else:
          let old = r.nextField(verb)
          if old.got and old.value.len > 0:
            u.haveOldTarget = true
            u.oldTarget = old.value
        if verb == "symref-verify":
          failIf(not u.haveOldTarget, "symref-verify: missing <old-target>")

      of "option":
        # The only option git defines is `no-deref`, and it applies to the
        # update that follows.  gittle has no use for it yet (docs/10 leaves
        # `--no-deref` out of scope), so it is accepted and ignored rather
        # than making a caller's script fail on a word that changes nothing
        # it asked for.
        discard r.nextField(verb)
        r.endOfCommand()
        continue

      of "start":
        r.endOfCommand()
        continue
      of "prepare":
        tx.prepare()
        r.endOfCommand()
        continue
      of "commit":
        if not tx.isPrepared: tx.prepare()
        tx.commit()
        explicitCommit = true
        r.endOfCommand()
        continue
      of "abort":
        tx.abort()
        r.endOfCommand()
        return 0
      else:
        fail("unknown command: " & verb)

      r.endOfCommand()
      tx.add u

    if not explicitCommit:
      tx.prepare()
      tx.commit()
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
      repo.refs.deleteRef(rest[0], repo.resolveOid(rest[1]), checkOld = true,
                          msg = msg)
    else:
      repo.refs.deleteRef(rest[0], msg = msg)
    return 0

  failIf(rest.len < 2 or rest.len > 3, usageText)
  let newOid = repo.resolveOid(rest[1])
  if rest.len == 3:
    # An empty old value, or the null OID, both mean "must not exist".
    let oldOid = if rest[2].len == 0: nullOid else: repo.resolveOid(rest[2])
    repo.refs.updateRef(rest[0], newOid, oldOid, checkOld = true, msg = msg)
  else:
    repo.refs.updateRef(rest[0], newOid, msg = msg)
  0
