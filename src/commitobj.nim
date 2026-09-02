## The commit object, and the commit message pipeline.
##
## ## The format
##
##     tree <40 hex>\n
##     parent <40 hex>\n         zero or more, in the order they were given
##     author <ident>\n
##     committer <ident>\n
##     <further headers>\n       gpgsig, encoding, mergetag -- read, never written
##     \n
##     <message bytes, verbatim>
##
## R1 is the whole of this file.  A commit is named by the hash of exactly
## these bytes, so an extra trailing newline, a missing one, or a message whose
## blank lines were tidied differently produces a *valid commit with a
## different object ID* -- which is a silently forked history that no test
## reading back gittle's own output will ever notice.  Compare object IDs
## against git's, not text.
##
## ## Message cleanup
##
## git cleans a message up before committing, and which cleanup it uses depends
## on whether an editor was involved (`sequencer.c:get_cleanup_mode`):
##
## * no editor -- *whitespace*: strip trailing whitespace from every line, drop
##   leading and trailing blank lines, collapse runs of blank lines to one;
## * an editor was opened -- *strip*: the same, plus drop every line that
##   begins with the comment character, which is how the instructions in
##   `COMMIT_EDITMSG` disappear from the commit.
##
## Both end the message with exactly one newline.  `--cleanup=<mode>` itself is
## out of scope (docs/06); these two are what its default selects.
##
## The algorithm is `strbuf.c:strbuf_stripspace`, reproduced rather than
## reinvented: the collapse rule ("a blank line is emitted only *before* a
## following non-blank line, and only if something was already emitted") is
## easy to write three subtly different ways.

import std/strutils
import oid, ident, util

type
  Commit* = object
    tree*: Oid
    parents*: seq[Oid]
    author*: Ident      ## parsed; `authorLine` keeps the bytes as stored
    committer*: Ident
    authorLine*: string
    committerLine*: string
    headers*: string    ## every header line verbatim, including the ones
                        ## gittle does not interpret (`gpgsig`, `mergetag`,
                        ## `encoding`) and their continuations.  `--pretty=raw`
                        ## prints these rather than the four fields above,
                        ## because "raw" means the bytes that are there.
    message*: string

const commentChar* = '#'
  ## `core.commentChar`'s default.  Configuring it is out of scope; the
  ## editor template gittle writes uses this one, so the two always agree.

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

proc parseCommit*(data: string): Commit =
  ## Read a commit object.  Headers run to the first blank line; a header whose
  ## value continues on the next line marks the continuation with a leading
  ## space (`gpgsig` does this), and those lines are skipped rather than
  ## mistaken for headers of their own.
  var i = 0
  var headerEnd = 0
  var sawTree = false
  while i < data.len:
    headerEnd = i
    let eol = data.find('\n', i)
    let line = if eol < 0: data[i .. ^1] else: data[i ..< eol]
    if line.len == 0:
      i = (if eol < 0: data.len else: eol + 1)
      break
    if line[0] != ' ':
      let sp = line.find(' ')
      if sp > 0:
        let name = line[0 ..< sp]
        let value = line[sp + 1 .. ^1]
        case name
        of "tree":
          result.tree = parseOid(value)
          sawTree = true
        of "parent": result.parents.add parseOid(value)
        of "author":
          result.authorLine = value
          result.author = parseIdentLine(value)
        of "committer":
          result.committerLine = value
          result.committer = parseIdentLine(value)
        else: discard
    if eol < 0:
      i = data.len
      break
    i = eol + 1
  failIf(not sawTree, "invalid commit object: no tree header")
  result.headers = data[0 ..< headerEnd]
  result.message = data[i .. ^1]

proc lineEnd(msg: string, at: int): tuple[trimmed, next: int] =
  ## One line of a message: where it ends once trailing whitespace is dropped,
  ## and where the next one begins.  `trimmed == at` means the line was blank.
  ## This is `get_one_line` plus `is_blank_line` from git, which always travel
  ## together and always trim before deciding.
  let eol = msg.find('\n', at)
  let stop = if eol < 0: msg.len else: eol
  var n = stop
  while n > at and msg[n - 1] in Whitespace: dec n
  (n, if eol < 0: msg.len else: eol + 1)

proc skipBlankLines(msg: string, at: int): int =
  result = at
  while result < msg.len:
    let (trimmed, next) = msg.lineEnd(result)
    if trimmed > result: return
    result = next

const signatureMarkers* = ["-----BEGIN PGP SIGNATURE-----",
                           "-----BEGIN PGP MESSAGE-----",
                           "-----BEGIN SIGNED MESSAGE-----",
                           "-----BEGIN SSH SIGNATURE-----"]
  ## `gpg-interface.c:parse_signed_buffer`.  A signed tag keeps its signature
  ## in the message body rather than in a header, so anything reading a tag's
  ## message has to know where the message stops -- otherwise the subject of
  ## every signed tag in the git repository is its first line of base64.
  ## gittle neither makes nor checks signatures (plan.md decision 5); it only
  ## has to know where they begin.

proc stripSignature*(msg: string): string =
  ## The message without a trailing signature block.
  var at = 0
  while at < msg.len:
    for m in signatureMarkers:
      if msg.len - at >= m.len and msg[at ..< at + m.len] == m:
        return msg[0 ..< at]
    let eol = msg.find('\n', at)
    if eol < 0: break
    at = eol + 1
  msg

proc subject*(message: string): string =
  ## The first paragraph, folded onto one line -- what `--oneline`, `%s` and a
  ## reflog entry show.  A wrapped first paragraph is *one* subject, joined
  ## with single spaces (`pretty.c:format_subject`), and only *trailing*
  ## whitespace is dropped: a subject that was indented stays indented.
  var i = message.skipBlankLines(0)
  var first = true
  while i < message.len:
    let (trimmed, next) = message.lineEnd(i)
    if trimmed == i: break
    if not first: result.add ' '
    result.add message[i ..< trimmed]
    first = false
    i = next

proc subjectLine*(message: string): string =
  ## Just the **first** line of the subject, unfolded and untrimmed.
  ##
  ## `%f` uses this where `%s` uses the folded subject
  ## (`pretty.c`: `strchrnul(..., '\n')` before `format_sanitized_subject`), so
  ## a commit whose subject wraps onto a second line sanitises to the first
  ## line alone.  Two placeholders, two different notions of "the subject".
  let start = message.skipBlankLines(0)
  let eol = message.find('\n', start)
  if eol < 0: message[start .. ^1] else: message[start ..< eol]

proc body*(message: string): string =
  ## Everything after the subject and the blank lines under it, **verbatim**.
  ##
  ## Verbatim matters: a commit message that does not end in a newline exists
  ## in real history, and `%b` prints it without one.  Adding a newline here
  ## would be a formatter quietly editing the data.
  var i = message.skipBlankLines(0)
  while i < message.len:
    let (trimmed, next) = message.lineEnd(i)
    let blank = trimmed == i
    i = next
    if blank: break
  message[message.skipBlankLines(i) .. ^1]

# ---------------------------------------------------------------------------
# The message pipeline
# ---------------------------------------------------------------------------

func stripTrailingSpace(s: string): string =
  var n = s.len
  while n > 0 and s[n - 1] in Whitespace: dec n
  s[0 ..< n]

proc cleanupMessage*(msg: string, dropComments: bool): string =
  ## `strbuf.c:strbuf_stripspace`.
  ##
  ## Every line loses its trailing whitespace.  A line that is then empty is
  ## not emitted; it only causes *one* blank line to be emitted before the next
  ## non-empty one, and only if something has been emitted already.  That one
  ## rule does leading blanks, trailing blanks and collapsing runs all at once.
  var empties = 0
  for rawLine in msg.split('\n'):
    if dropComments and rawLine.len > 0 and rawLine[0] == commentChar:
      continue
    let line = stripTrailingSpace(rawLine)
    if line.len == 0:
      inc empties
      continue
    if empties > 0 and result.len > 0: result.add '\n'
    empties = 0
    result.add line
    result.add '\n'

proc joinMessages*(parts: openArray[string]): string =
  ## How `-m` and `-F` accumulate (`builtin/commit-tree.c`,
  ## `builtin/commit.c:opt_parse_m`): each new piece is separated from what is
  ## already there by a newline, and every piece is completed to a whole line.
  ## Two `-m` arguments therefore end up one blank line apart, which is what
  ## makes `-m subject -m body` a subject and a body.
  for p in parts:
    if result.len > 0: result.add '\n'
    result.add p
    if result.len > 0 and result[^1] != '\n': result.add '\n'

proc appendSignoff*(msg: string, id: Ident): string =
  ## `Signed-off-by: Name <email>`, separated from the message by a blank line
  ## unless the message already ends in a trailer-looking line.
  let line = "Signed-off-by: " & id.name & " <" & id.email & ">"
  result = msg
  if result.len == 0:
    return line & "\n"
  if not result.endsWith("\n"): result.add "\n"
  # A blank line goes in unless the last paragraph is already trailers.  git's
  # trailer machinery is far larger than this; the case that matters is not
  # separating `Signed-off-by` from a `Signed-off-by` that is already there.
  var lastPara = ""
  for line2 in result.strip(leading = false).splitLines:
    if line2.strip().len == 0: lastPara = ""
    else: lastPara.add line2 & "\n"
  var allTrailers = lastPara.len > 0
  for l in lastPara.splitLines:
    if l.len == 0: continue
    let colon = l.find(": ")
    if colon <= 0: allTrailers = false
  if not allTrailers: result.add "\n"
  result.add line & "\n"

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

proc buildCommit*(tree: Oid, parents: seq[Oid], author, committer: Ident,
                  message: string): string =
  ## The bytes of a commit object, in git's order
  ## (`commit.c:write_commit_tree`).
  ##
  ## The message is appended verbatim: every rule about what it should look
  ## like has already been applied by `cleanupMessage`, and applying one here
  ## as well is how the two disagree.  A NUL in it is refused for the reason
  ## git refuses it -- the object framing is NUL-terminated, so a message
  ## containing one could not be read back.
  failIf(message.contains('\0'), "a NUL byte in a commit message is not allowed")
  result.add "tree " & $tree & "\n"
  for p in parents: result.add "parent " & $p & "\n"
  result.add "author " & $author & "\n"
  result.add "committer " & $committer & "\n"
  result.add "\n"
  result.add message
