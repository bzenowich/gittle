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
##
## This module has no glob in it, and the forbidden set is why: every character
## [glob.nim](glob.nim) would treat as a metacharacter is banned from a ref
## name outright, so a ref name is always safe to hand a matcher as a literal
## and never needs escaping first.  `reffilter.nim` relies on that.

import std/strutils

const
  forbidden = {'\0' .. '\x1F', '\x7F', ' ', '\t', ':', '?', '[', '\\', '^',
               '~', '*'}
    ## `*` is only legal in a refspec pattern, which v1 never builds, so it is
    ## simply forbidden here.

type
  RefnameFlag* = enum
    rfAllowOneLevel  ## permit `HEAD`-style names with no slash in them

func checkComponent(c: string): bool =
  ## One slash-separated piece of a ref name.  The two-character rules (`..`
  ## and `@{`) are checked against the previous character rather than by
  ## searching, so one pass over the component settles every rule at once.
  if c.len == 0 or c[0] == '.' or c.endsWith(".lock"): return false
  var last = '\0'
  for ch in c:
    if ch in forbidden or (ch == '.' and last == '.') or
       (ch == '{' and last == '@'): return false
    last = ch
  true

func isValidRefname*(name: string, flags: set[RefnameFlag] = {}): bool =
  ## Is `name` a well-formed reference name?
  if name.len == 0 or name == "@" or name.endsWith(".") or
     name.startsWith("/") or name.endsWith("/"): return false
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
