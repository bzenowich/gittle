## `ls-remote` -- what a remote says it has, without fetching any of it.
##
## In scope (docs/09): `<repository>`, `<patterns>`, `-b`/`--branches`,
## `-t`/`--tags`, `--refs`, `--upload-pack`, `-q`.  `--symref`, `--sort`,
## `--exit-code` and `--get-url` are cut.
##
## The only command in the phase that connects and then does nothing with the
## connection, which makes it the one worth reaching for when a remote is not
## behaving: it exercises the URL parsing, the child process, the handshake
## and the version negotiation, and stops before anything can be written.

import std/strutils
import ../cli, ../oid, ../remotes, ../repository, ../transport, ../util

const usageText = """usage: gittle ls-remote [--branches] [--tags] [--refs] [-q] [<repository>] [<patterns>…]

   -b, --branches      show only refs/heads/
   -t, --tags          show only refs/tags/
   --refs              omit peeled tag entries
   --upload-pack=<exec>  the command to run on the far end
   -q, --quiet         do not echo the remote's URL to standard error"""

proc matchesPattern(name: string, patterns: seq[string]): bool =
  ## git matches a pattern against the *tail* of the ref name at a `/`
  ## boundary, so `main` finds `refs/heads/main` and `foo/main` does not
  ## (`ls-remote.c`).
  if patterns.len == 0: return true
  for p in patterns:
    if name == p or name.endsWith("/" & p): return true
  false

proc cmdLsRemote*(c: Ctx, args: seq[string]): int =
  var branches, tags, refsOnly, quiet = false
  var uploadPack = ""
  var positional: seq[string]
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "-b", "--branches", "--heads": branches = true
    of "-t", "--tags": tags = true
    of "--refs": refsOnly = true
    of "-q", "--quiet": quiet = true
    of "--upload-pack", "--exec":
      inc i
      failIf(i >= args.len, "option '" & a & "' requires a value")
      uploadPack = args[i]
    of "-h", "--help": (echo usageText; return 0)
    else:
      if a.startsWith("--upload-pack="): uploadPack = a["--upload-pack=".len .. ^1]
      elif a.startsWith("--exec="): uploadPack = a["--exec=".len .. ^1]
      elif a.startsWith("-") and a.len > 1:
        fail("unknown option '" & a & "'\n" & usageText)
      else: positional.add a
    inc i

  let patterns = if positional.len > 1: positional[1 .. ^1] else: @[]
  # A URL needs no repository, and git does not demand one -- `ls-remote` is
  # the command you reach for when there is nothing local yet.  A *name*, of
  # course, has to be looked up somewhere.
  var rem: Remote
  var configured = ""
  try:
    let repo = c.repo
    let name = if positional.len > 0: positional[0] else: repo.defaultRemote()
    rem = repo.lookupRemote(name)
    configured = repo.cfg.get("remote." & rem.name & ".uploadpack")
  except GittleError:
    if positional.len == 0: raise
    rem = Remote(url: positional[0])
  # The URL is echoed only when it was *not* given -- the point is to say
  # which remote "the default one" turned out to be, and repeating an argument
  # back at the user says nothing (`builtin/ls-remote.c`).
  if not quiet and positional.len == 0: stderr.write "From " & rem.url & "\n"

  var prefixes: seq[string]
  if branches: prefixes.add "refs/heads/"
  if tags: prefixes.add "refs/tags/"
  if prefixes.len == 0: prefixes = @["HEAD", "refs/"]

  let program = if uploadPack.len > 0: uploadPack
                elif configured.len > 0: configured
                else: "git-upload-pack"
  let conn = connect(rem.url, program, wantV2 = true)
  defer: conn.finish()
  conn.handshake()
  for r in conn.lsRefs(prefixes):
    if not matchesPattern(r.name, patterns): continue
    if r.unborn: continue
    # `--refs` means "refs only": no peeled `^{}` entries and no pseudorefs,
    # which is what makes its output a list of things that can be fetched.
    if refsOnly and not r.name.startsWith("refs/"): continue
    echo $r.oid & "\t" & r.name
    if not refsOnly and not r.peeled.isNull:
      echo $r.peeled & "\t" & r.name & "^{}"
  0
