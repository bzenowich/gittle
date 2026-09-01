## Reference names: what counts as one, and how to abbreviate one for display.
##
## A reference name is a slash-separated path that also becomes a *file* path
## under `$GIT_DIR/refs/`, and that has to survive being typed on a command
## line next to a revision expression.  The rules below fall out of those two
## facts, and gittle enforces exactly the ones git enforces
## (`refs.c:check_refname_format`), because a name git rejects but gittle
## accepts would produce a repository git then refuses to operate on.
##
## The rules, and what each is defending against:
##
## * No ASCII control character, space or tab, and none of ``: ? [ \ ^ ~``.
##   Most of these are revision syntax -- `^` and `~` are ancestry operators,
##   `:` separates a ref from a path, `?` and `[` are glob characters.
## * No `..` anywhere.  `a..b` is a range expression.
## * No `@{`.  `HEAD@{2}` is a reflog expression.
## * No component starting with `.`, so nothing hides from a directory listing,
##   and nothing collides with `.` or `..` on the filesystem.
## * No component ending `.lock`, because that is exactly the name the ref
##   store gives its own lock files.
## * No trailing `.`, no empty component, and not the single character `@`
##   (which is shorthand for HEAD).
## * At least two components -- `refs/heads/main`, not `main` -- unless the
##   caller allows one level, which is how HEAD and the other pseudorefs get in.

import std/strutils

const
  refnameLockSuffix = ".lock"

  forbidden = {'\0' .. '\x1F', '\x7F', ' ', '\t', ':', '?', '[', '\\', '^',
               '~', '*'}
    ## `*` is only legal in a refspec pattern, which v1 never builds, so it is
    ## simply forbidden here.

type
  RefnameFlag* = enum
    rfAllowOneLevel  ## permit `HEAD`-style names with no slash in them

func checkComponent(c: string): bool =
  ## One slash-separated piece of a ref name.
  if c.len == 0: return false
  if c[0] == '.': return false
  if c.endsWith(refnameLockSuffix): return false
  var last = '\0'
  for ch in c:
    if ch in forbidden: return false
    if ch == '.' and last == '.': return false   # ".." is a range expression
    if ch == '{' and last == '@': return false   # "@{" is a reflog expression
    last = ch
  true

func isValidRefname*(name: string, flags: set[RefnameFlag] = {}): bool =
  ## Is `name` a well-formed reference name?
  if name.len == 0: return false
  if name == "@": return false
  if name.endsWith("."): return false
  if name.startsWith("/") or name.endsWith("/"): return false
  let parts = name.split('/')
  if parts.len < 2 and rfAllowOneLevel notin flags: return false
  for p in parts:
    if not checkComponent(p): return false
  true

# -- shortening -------------------------------------------------------------
#
# The inverse of the DWIM lookup in refs.nim: strip the longest prefix that
# would still resolve back to this ref and nothing else.  git does the same
# thing by trying each rule and checking for ambiguity; the prefixes here are
# the unambiguous common cases, which is what `--short` is actually used for.

const shortenPrefixes = ["refs/heads/", "refs/tags/", "refs/remotes/", "refs/"]

func shortenRefname*(name: string): string =
  ## `refs/heads/main` -> `main`, `refs/tags/v1` -> `v1`.
  ##
  ## This can be ambiguous in principle: a branch and a tag may share a name,
  ## and the short form then names the tag, because `refs/tags/` comes earlier
  ## in the DWIM order.  git has the same behavior, and warns rather than
  ## refusing; gittle just shortens.
  for p in shortenPrefixes:
    if name.startsWith(p) and name.len > p.len:
      return name[p.len .. ^1]
  name

func lstripRefname*(name: string, n: int): string =
  ## Drop the first `n` slash-separated components, or the last `-n` if `n` is
  ## negative.  `%(refname:lstrip=2)` turns `refs/heads/main` into `main`.
  let parts = name.split('/')
  let drop = if n >= 0: n else: max(0, parts.len + n)
  if drop >= parts.len: "" else: parts[drop .. ^1].join("/")

func rstripRefname*(name: string, n: int): string =
  ## Drop the last `n` components, or all but the first `-n` if negative.
  let parts = name.split('/')
  let keep = if n >= 0: parts.len - n else: min(parts.len, -n)
  if keep <= 0: "" else: parts[0 ..< keep].join("/")
