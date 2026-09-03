## Colour: `--color[=<when>]`, reduced to one on/off switch.
##
## Every colourable command takes the same three spellings -- `always`,
## `never`, `auto` -- and `auto` asks the same question `--decorate=auto`
## already asks: is stdout a terminal, or a pipe that would have to strip
## codes it never wanted.  Before this module the check was three separate
## copies, one apiece in `diffcore`, `grep` and (planned but never built)
## `pretty` (docs/minimize.md §4.4); one lives here now, and colour is never
## on without one of the three being asked for -- there is no `color.ui`-style
## default, because gittle has no colour configuration to drive one.
##
## The escape sequences below are git's own defaults (`diff.c`'s
## `diff_colors`, `wt-status.c`'s colour slots, `branch.c`'s).  Making them
## configurable through `color.diff.*`, `color.status.*` and `color.branch.*`
## is out of scope, the same cut `color.grep.*` already made (docs/11).

import std/posix
import util

const
  cReset* = "\e[m"
  cBold* = "\e[1m"
  cRed* = "\e[31m"
  cGreen* = "\e[32m"
  cCyan* = "\e[36m"

proc isTty*(): bool =
  ## `--decorate=auto` and `--color=auto` both ask this.  Decoration is for a
  ## human reading a terminal; a pipe is a program, and a program parsing the
  ## output should not have to strip codes or ref names it never asked for.
  isatty(stdout.getFileHandle()) != 0

proc resolveColor*(v: string): bool =
  ## A bare `--color` is `--color=always`; otherwise it is `always`, `never`
  ## or `auto` by name.
  case (if v.len == 0: "always" else: v)
  of "always": true
  of "never": false
  of "auto": isTty()
  else: fail("invalid --color argument: " & v)
