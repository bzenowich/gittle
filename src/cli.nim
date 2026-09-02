## What every command shares: the repository it was pointed at, and the way
## it reads its options.
##
## ## The context
##
## Every command receives a `Ctx`: the directory to act as though we started
## in (`-C`), an explicit git directory or work tree if one was given, and any
## `-c name=value` overrides.
##
## The repository itself is opened **lazily**, on first use, and that is a
## deliberate choice rather than a micro-optimisation.  Opening it runs
## repository discovery and the extension gate, either of which can fail --
## and several commands must work where that would: `hash-object` without `-w`
## hashes a file that need not be in a repository at all, `config --global`
## edits a file outside any repository, and `version` must never go looking for
## one.  A command that genuinely needs a repository simply touches `c.repo`
## and gets the error for free.
##
## ## Options are a table
##
## An option is data -- a spelling, a kind, a name the command asks for it by,
## and a line of help -- and R7 says a family of cases that differs only in
## constants is a table.  So each command declares a `const` table of `Opt`
## rows and calls `parse`, which returns every occurrence in order plus the
## positionals, and the usage text is generated from the same rows.  Forty
## commands used to carry the same loop by hand (`var i`, `while`, `case`, a
## `-h` clause, an `unknown option` clause); this is that loop, once.
##
## The rules it implements are git's own (`parse-options.c`), reduced to what
## gittle's commands use:
##
## | spelling | reading |
## |---|---|
## | `--opt=value`, `--opt value` | a value |
## | `-o value`, `-ovalue` | the same, short |
## | `-abc` | three flags, `-a -b -c`; `-am msg` is `-a -m msg` |
## | `--opt`, `--opt=value` on an optional-value option | absent or attached; `--opt value` leaves `value` alone, as git's `PARSE_OPT_OPTARG` does |
## | `--contains`, `--contains v1` on a next-word option | the ref-filter family: the next word unless it starts with `-` |
## | `-u`, `-uno` on an optional-value option | the attached spelling only; the next word is never taken |
## | `-5`, when the command allows it | the key `n` with value `5` (`log -5`) |
## | `--` | the end of the options; everything after is positional |
## | `-` | positional: a file name meaning standard input |
## | `-h`, `--help` | the generated usage, exit 0 -- unless the table claims `-h` for itself (`grep -h`) |
##
## What is *not* here: unambiguous abbreviation of long options (`--cach`),
## which git accepts and nothing in the tool-call logs ever typed, and an
## automatic `--no-` form -- a command that takes a negation declares it as a
## row, because where the negation lands is command-specific.
##
## Two things the shape of `Opts` is chosen for.  Occurrences are kept **in
## order**, because a few option families are order-sensitive (`diff -s
## --stat` and `diff --stat -s` differ) and the group that owns them replays
## the sequence.  And repeated values are all kept (`commit -m one -m two`),
## so `val` returns the last and `vals` returns them all.

import std/strutils
import config, repository, util

type
  Ctx* = ref object
    startDir*: string
    gitDirOpt*, workTreeOpt*: string
    bare*: bool
    overrides*: Config
    reflogAction*: string
      ## What the reflog should call whatever happens next, when it is not the
      ## running command's own name.  git carries this in `GIT_REFLOG_ACTION`
      ## and it exists for exactly one situation: `pull` runs a fetch and then
      ## a merge or a rebase, and every entry all three write says `pull`.
    cached: Repository

proc repo*(c: Ctx): Repository =
  ## The repository, opened on first use -- see the module comment for why
  ## not before.
  if c.cached == nil:
    c.cached = openRepository(c.gitDirOpt, c.workTreeOpt, c.startDir,
                              c.bare, c.overrides)
  c.cached

# ---------------------------------------------------------------------------
# The option table
# ---------------------------------------------------------------------------

type
  OptKind* = enum
    okFlag       ## present or not
    okCount      ## how many times: `-v`, `-vv`
    okValue      ## takes one argument
    okOptValue   ## takes an argument only when attached: `--opt=v`, `-uno`
                 ## (git's `PARSE_OPT_OPTARG`; the next word is never taken)
    okOptNext    ## takes the next word unless it is absent or starts with
                 ## `-`: `--contains`, `--contains v1` (`PARSE_OPT_LASTARG_DEFAULT`)
    okRefused    ## a git option gittle deliberately does not have, refused
                 ## by name so that the user learns it is a cut and not a typo

  Opt* = object
    names*: seq[string]  ## as spelled on the command line: `-l`, `--list`
    kind*: OptKind
    key*: string         ## what the command asks for it by
    arg*: string         ## the placeholder in the usage line, `<upstream>`
    help*: string        ## one line of usage; for `okRefused`, the reason

  Opts* = object
    ## One parse: every option occurrence in order, and the positionals.
    seen: seq[tuple[key, value: string]]
    args*: seq[string]     ## everything that was not an option, in order
    dashDash*: bool        ## a `--` was given
    dashDashAt*: int       ## how many positionals came before it; -1 if none
    use*: string           ## the usage text, for the command's own refusals

proc opt*(names: string, kind = okFlag, key = "", arg = "", help = ""): Opt =
  ## One row.  `names` is `-l|--list`; the key defaults to the first long
  ## name without its dashes, or the short letter when there is no long one,
  ## so `opt("-q|--quiet")` is asked for as `"quiet"` and `opt("-D")` as
  ## `"D"`.
  result = Opt(names: names.split('|'), kind: kind, key: key, arg: arg,
               help: help)
  if result.key.len == 0:
    for n in result.names:
      if n.startsWith("--"): (result.key = n[2 .. ^1]; break)
    if result.key.len == 0: result.key = result.names[0].strip(chars = {'-'})

proc has*(o: Opts, key: string): bool =
  ## Was the option given at all?
  for s in o.seen:
    if s.key == key: return true

proc count*(o: Opts, key: string): int =
  ## How many times the option was given (`-v -v`).
  for s in o.seen:
    if s.key == key: inc result

proc val*(o: Opts, key: string, dflt = ""): string =
  ## The last value given -- git's rule when an option is repeated.
  result = dflt
  for s in o.seen:
    if s.key == key: result = s.value

proc vals*(o: Opts, key: string): seq[string] =
  ## Every value given, for the options that accumulate (`-m`, `-e`).
  for s in o.seen:
    if s.key == key: result.add s.value

iterator occurrences*(o: Opts): tuple[key, value: string] =
  ## In command-line order, for the families whose meaning depends on it.
  ## Positionals are in the sequence too, under the empty key, and `--` under
  ## its own: `rev-list A --not B` has to know which side of `--not` each
  ## revision was on.
  for s in o.seen: yield s

proc usage*(cmd, synopsis: string, spec: openArray[Opt]): string =
  ## `usage: gittle <cmd> <line>`, `or:` for each further line of the
  ## synopsis, then one line per option that has help.
  var first = true
  for line in synopsis.splitLines:
    result.add (if first: "usage: gittle " else: "\n   or: gittle ") & cmd &
               (if line.len > 0: " " & line else: "")
    first = false
  var rows = false
  for o in spec:
    if o.help.len == 0 or o.kind == okRefused: continue
    if not rows: (result.add "\n"; rows = true)
    var left = o.names.join(", ")
    if o.arg.len > 0: left.add " " & o.arg
    result.add "\n   " & left & spaces(max(1, 26 - left.len)) & o.help

proc parse*(spec: openArray[Opt], argv: openArray[string], cmd, synopsis: string,
            numeric = false): Opts =
  ## Read `argv` against the table.  `numeric` admits `-<digits>` as the key
  ## `n`, which `log` and `rev-list` take and nothing else does -- a command
  ## that allows it cannot bundle short options that are digits, which none
  ## are.
  let use = usage(cmd, synopsis, spec)
  result.use = use
  let table = @spec   # a closure cannot capture an openArray
  proc find(name: string): int =
    ## The row a spelling belongs to, or -1.
    for i, o in table:
      if name in o.names: return i
    -1
  proc record(o: var Opts, i: int, name: string, value = "") =
    ## Note one occurrence -- or refuse it, when the row says the option is
    ## out of scope.
    case table[i].kind
    of okRefused:
      fail(name & " is out of scope for gittle" &
           (if table[i].help.len > 0: ": " & table[i].help
            else: " (docs/minimize.md)"))
    else: o.seen.add (table[i].key, value)

  result.dashDashAt = -1
  var i = 0
  while i < argv.len:
    let a = argv[i]
    inc i
    if result.dashDash or a.len < 2 or a[0] != '-':
      result.args.add a
      result.seen.add ("", a)          # positionals keep their place in order
    elif a == "--":
      result.dashDash = true
      result.dashDashAt = result.args.len
      result.seen.add ("--", "")
    elif a == "--help" or (a == "-h" and find("-h") < 0):
      echo use
      exitWith(0)
    elif a[1] == '-':
      # A long option, with or without `=value`.
      let eq = a.find('=')
      let name = if eq > 0: a[0 ..< eq] else: a
      let k = find(name)
      failIf(k < 0, "unknown option '" & name & "'\n" & use)
      case table[k].kind
      of okValue:
        if eq > 0: result.record(k, name, a[eq + 1 .. ^1])
        else:
          failIf(i >= argv.len, "option '" & name & "' requires a value")
          result.record(k, name, argv[i])
          inc i
      of okOptValue:
        result.record(k, name, if eq > 0: a[eq + 1 .. ^1] else: "")
      of okOptNext:
        if eq > 0: result.record(k, name, a[eq + 1 .. ^1])
        elif i < argv.len and (argv[i].len == 0 or argv[i][0] != '-'):
          result.record(k, name, argv[i])
          inc i
        else: result.record(k, name)
      of okRefused: result.record(k, a)   # as typed: `--prune=now`
      else:
        failIf(eq > 0, "option '" & name & "' takes no value")
        result.record(k, name)
    elif numeric and a[1] in {'0' .. '9'}:
      result.seen.add ("n", a[1 .. ^1])
    else:
      # A cluster of short options.  One that takes a value takes the rest of
      # the cluster as that value (`-mfoo`), or the next word (`-m foo`).
      var j = 1
      while j < a.len:
        let name = "-" & a[j]
        let k = find(name)
        failIf(k < 0, "unknown option '" & name & "'\n" & use)
        inc j
        case table[k].kind
        of okValue:
          if j < a.len: result.record(k, name, a[j .. ^1])
          else:
            failIf(i >= argv.len, "option '" & name & "' requires a value")
            result.record(k, name, argv[i])
            inc i
          break
        of okOptValue, okOptNext:
          # `-uno`: attached only.  `-u no` would eat a path.
          if j < a.len: result.record(k, name, a[j .. ^1])
          else: result.record(k, name)
          break
        of okRefused: result.record(k, "-" & a[j - 1 .. ^1])  # `-n2`, not `-n`
        else: result.record(k, name)
