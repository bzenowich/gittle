## Refspecs: which remote ref becomes which local one.
##
## A refspec is `[+]<src>:<dst>`, and it is the whole of git's answer to "what
## does fetching do to my repository".  The default one a `clone` writes is
##
##     +refs/heads/*:refs/remotes/origin/*
##
## which reads: every branch on the remote (`refs/heads/*`) is stored here
## under `refs/remotes/origin/` with the same trailing name, and the `+` means
## do it even when the new value is not a descendant of the old -- a remote
## branch that was rebased or reset is *reported* as forced, not refused,
## because a remote-tracking ref is a record of what the remote says rather
## than work of ours that could be lost.
##
## Three shapes, and only three:
##
## | | fetch | push |
## |---|---|---|
## | `refs/heads/main:refs/remotes/origin/main` | one named ref | one named ref |
## | `refs/heads/*:refs/remotes/origin/*` | every match, name preserved | every match |
## | `main` (no colon) | fetch it, remember it in FETCH_HEAD only | push to the same name |
##
## The `*` may appear once on each side and must be the whole of a path
## component (`refspec.c:check_refspec`); `refs/heads/v*:…` is rejected by git
## and by gittle.  Negative refspecs (`^refs/heads/wip`) are out of scope.

import std/strutils
import util

type
  Refspec* = object
    force*: bool
    src*, dst*: string
    pattern*: bool     ## both sides end in `*`
    hasDst*: bool

func hasStar(s: string): bool = s.find('*') >= 0

proc parseRefspec*(text: string, forPush: bool): Refspec =
  ## `verify_refspec` in `refspec.c`, minus the negative and the `@` forms.
  var s = text
  if s.startsWith("+"):
    result.force = true
    s = s[1 .. ^1]
  failIf(s.startsWith("^"),
         "negative refspecs are out of scope for gittle v1: " & text)
  let colon = s.rfind(':')
  if colon < 0:
    result.src = s
  else:
    result.src = s[0 ..< colon]
    result.dst = s[colon + 1 .. ^1]
    result.hasDst = true
  if hasStar(result.src) or hasStar(result.dst):
    failIf(result.src.count('*') > 1 or result.dst.count('*') > 1,
           "invalid refspec '" & text & "': at most one '*' per side")
    failIf(result.hasDst and (not hasStar(result.src) or not hasStar(result.dst)),
           "invalid refspec '" & text & "': '*' must appear on both sides")
    result.pattern = true
  # A source that is empty means "delete the destination", and only on a push.
  failIf(result.src.len == 0 and not forPush,
         "invalid refspec '" & text & "': no source")

func splitStar(pat: string): tuple[pre, post: string] =
  let star = pat.find('*')
  (pat[0 ..< star], pat[star + 1 .. ^1])

proc mapRef*(rs: Refspec, name: string): tuple[matched: bool, dst: string] =
  ## Does this refspec take `name`, and what does it become locally?
  ##
  ## The two answers are separate because "no match" and "matched, but goes
  ## nowhere" are different: `fetch origin main` matches `refs/heads/main` and
  ## has no destination, which means it is fetched into `FETCH_HEAD` and no
  ## ref moves.  Collapsing the two into an empty string is how a refspec with
  ## no destination comes to fetch nothing at all.
  if not rs.pattern:
    if name != rs.src: return (false, "")
    return (true, rs.dst)
  let (pre, post) = splitStar(rs.src)
  if not name.startsWith(pre) or not name.endsWith(post): return (false, "")
  if name.len < pre.len + post.len: return (false, "")
  let middle = name[pre.len .. name.len - post.len - 1]
  if not rs.hasDst: return (true, "")
  let (dpre, dpost) = splitStar(rs.dst)
  (true, dpre & middle & dpost)

proc defaultFetchRefspec*(remote: string): string =
  "+refs/heads/*:refs/remotes/" & remote & "/*"
