## `grep` -- search tracked content.
##
## Three things to search and one way to search them:
##
## | | |
## |---|---|
## | the working tree | the default: every tracked file, read from disk |
## | the index | `--cached`: the staged blob, which may differ from the file |
## | a tree | `grep <pattern> <commit>`: paths are prefixed `<what you typed>:` |
##
## In scope: one pattern (`-e` or the first bare argument), `-i`, `-v`, `-E`,
## `-F`, `-n`, `-l`, `-L`, `-q`, `-z`, `--cached`, `--color[=<when>]`,
## revisions and pathspecs.  docs/minimize.md §3 trims the rest -- `-A`/`-B`/
## `-C` context, `-c`, `-w`, `-h`/`-H`, `--no-index` and a second `-e` --
## because none of them appeared in the logs it surveyed.  Each is refused by
## name rather than misread as a pattern or a path.
##
## ## The patterns are ERE, always
##
## git's default is **BRE** (`grep.c:compile_regexp`) with `-E` selecting ERE
## and `-P` selecting PCRE.  docs/07 keeps `-E` and cuts `-G` and `-P`, so
## gittle is ERE-only *by choice*, and `-E` is accepted as a no-op.  It is a
## real divergence and worth remembering: `gittle grep 'a+b'` reads `+` as a
## quantifier where `git grep 'a+b'` reads it as a literal.  `-G` and `-P` are
## refused by name rather than silently treated as ERE.
##
## plan.md §6.4 records why the engine is libc's rather than a vendored one.
##
## ## Binary files
##
## A binary file is never quoted line by line: it gets `Binary file <name>
## matches` and nothing else, and counts as one match for `-l`, `-L` and the
## exit status.

import std/[posix, strutils]
import ../cli, ../index, ../objects, ../pathspec, ../regex, ../repository,
       ../revision, ../trees, ../util


const
  colFile = "\e[35m"
  colSep = "\e[36m"
  colLine = "\e[32m"
  colMatch = "\e[1;31m"
  colReset = "\e[m"
    ## `color.grep.*` defaults (`grep.c`).  Configuring them is out of scope
    ## (docs/11), so the five are constants.

type
  GrepOpts = object
    lineNumbers, invert, quiet, nulTerm, color: bool
    filesWith, filesWithout: bool

  Blob = object
    name: string     ## what to print, already prefixed with `<tree>:` if any
    text: string

proc paint(o: GrepOpts, col, s: string): string =
  ## Wrap `s` in a colour when colour is on.
  if o.color: col & s & colReset else: s

proc searchBlob(b: Blob, re: Regex, o: GrepOpts, out0: var string): int =
  ## Search one blob, appending output.  Returns the number of matching lines,
  ## which is what decides `-l`, `-L` and the exit status.
  # The same splitting rule as the diff engine: a line ends at a newline or at
  # the end of the buffer, and the newline is not part of it.  So a file
  # ending in `\n` has no empty final line -- and an **empty file has no lines
  # at all**, which is not a detail: without it, `-L` and `-v -l` list every
  # empty file, and the reference repository has three.
  let quote = not (o.quiet or o.filesWith or o.filesWithout)
  let binary = isBinary(b.text)
  # git's `-z` puts a NUL after the file name *and* after the line number
  # (`grep.c:output_sep`); otherwise each is followed by a painted `:`.  The
  # file name is always printed, unlike `grep(1)`, which suppresses it for a
  # single file: `builtin/grep.c` sets `opt.pathname = 1` before parsing.
  let sep = if o.nulTerm: "\0" else: o.paint(colSep, ":")
  var i = 0
  var lno = 0
  while i < b.text.len:
    var e = b.text.find('\n', i)
    if e < 0: e = b.text.len
    inc lno
    if re.matchLine(b.text, i, e).hit != o.invert:
      inc result
      if quote and not binary:
        out0.add o.paint(colFile, b.name) & sep
        if o.lineNumbers: out0.add o.paint(colLine, $lno) & sep
        let line = b.text[i ..< e]
        if o.color and not o.invert:
          # Every match on the line is painted, not only the first: `grep` is
          # showing where the pattern is, and a line often holds it twice.
          var at = 0
          while at < line.len:
            let m = re.matchLine(line, at, line.len)
            if not m.hit or m.so == m.eo: break
            out0.add line[at ..< at + m.so]
            out0.add colMatch & line[at + m.so ..< at + m.eo] & colReset
            at += m.eo
          out0.add line[at .. ^1]
        else:
          out0.add line
        out0.add "\n"
    i = e + 1
  if binary and result > 0 and quote:
    out0.add "Binary file " & o.paint(colFile, b.name) & " matches\n"

const
  synopsis = "[<options>] [-e] <pattern> [<tree>…] [--] [<pathspec>…]"
  options = [
    opt("-e", okValue, arg = "<pattern>", help = "the pattern, when it starts with a dash"),
    opt("-i|--ignore-case", help = "case-insensitive"),
    opt("-v|--invert-match", help = "lines that do not match"),
    opt("-F|--fixed-strings", help = "a literal string, not a regular expression"),
    opt("-E|--extended-regexp", help = "POSIX ERE, which is what gittle always uses (plan.md 6.4)"),
    opt("-n|--line-number", help = "prefix each line with its number"),
    opt("-l|--files-with-matches|--name-only", help = "names only"),
    opt("-L|--files-without-match", help = "names of files with no match"),
    opt("-q|--quiet", help = "print nothing; the exit status is the answer"),
    opt("-z|--null", help = "NUL after each file name"),
    opt("--cached", help = "search the index rather than the working tree"),
    opt("--color", okOptValue, arg = "[=<when>]", help = "colour matches: always, never or auto"),
    opt("--no-color"),
    opt("-G|--basic-regexp|-P|--perl-regexp", okRefused,
        help = "gittle's patterns are POSIX extended regular expressions, always (docs/07)"),
    opt("-c|--count|-w|--word-regexp|-h|-H|--no-index|--and|--or|--not|-f", okRefused,
        help = "docs/minimize.md §3"),
    opt("-A|-B|-C|--context|--after-context|--before-context", okRefused,
        help = "context lines are out of scope (docs/minimize.md §3)"),
  ]

proc cmdGrep*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, compile the pattern, choose the blobs (a tree's,
  ## the index's, or the working tree's), and search each.
  let p = parse(options, args, "grep", synopsis)
  var o = GrepOpts(color: isatty(stdout.getFileHandle()) != 0)
    # git's `color.ui=auto`; `--color`/`--no-color` below can override.
  failIf(p.vals("e").len > 1, "gittle grep takes one pattern; a second -e, " &
         "--and, --or and -f are out of scope (docs/minimize.md §3)")
  var pattern = p.val "e"
  var havePattern = p.has "e"
  var rest = p.args
  if not havePattern and rest.len > 0:
    pattern = rest[0]
    havePattern = true
    rest.delete(0)
  let icase = p.has "ignore-case"
  let fixed = p.has "fixed-strings"
  let cached = p.has "cached"
  o.invert = p.has "invert-match"
  o.lineNumbers = p.has "line-number"
  o.filesWith = p.has "files-with-matches"
  o.filesWithout = p.has "files-without-match"
  o.quiet = p.has "quiet"
  o.nulTerm = p.has "null"
  for (k, v) in p.occurrences:
    if k == "no-color": o.color = false
    elif k == "color":
      o.color = case (if v.len == 0: "always" else: v)
        of "always": true
        of "never": false
        of "auto": isatty(stdout.getFileHandle()) != 0
        else: fail("invalid --color argument: " & v)
  failIf(not havePattern, "no pattern given\n" & p.use)
  let re = compileRegex(pattern, icase, fixed)
  let repo = c.repo

  # Anything in `rest` that names a tree is a revision; everything from the
  # first non-revision on is a path, which is the same rule `log` uses.
  var trees: seq[tuple[label: string, oid: Oid]]
  var specs: seq[string]
  for r in rest:
    if specs.len == 0:
      var t: Oid
      var ok = true
      try: t = repo.resolveTree(r) except GittleError: ok = false
      if ok:
        trees.add (r, t)
        continue
    specs.add r
  let ps = parsePathspec(specs, repo.prefix)

  var blobs: seq[Blob]
  if trees.len > 0:
    for (label, t) in trees:
      for e in repo.walkTree(t):
        if e.mode != modeRegular and e.mode != modeExecutable: continue
        if not ps.matches(e.name): continue
        blobs.add Blob(name: label & ":" & ps.displayPath(e.name),
                       text: repo.readObject(e.oid).data)
  else:
    let idx = readIndex(repo.indexPath)
    for e in idx.entries:
      if e.stage != 0: continue
      # Only regular files are searched.  git's rule, not a simplification
      # of it: `builtin/grep.c:grep_cache` skips any entry that is not
      # `S_ISREG`, which drops both gitlinks -- there is nothing here to
      # search -- and symlinks, whose blob is a path rather than content.
      if e.mode != modeRegular and e.mode != modeExecutable: continue
      if not ps.matches(e.path): continue
      # Printed relative to the directory the command was run in, which is
      # `grep(1)`'s behavior and git's default; `--full-name` would make it
      # root-relative and docs/07 cuts it.
      let shown = ps.displayPath(e.path)
      if cached:
        blobs.add Blob(name: shown, text: repo.readObject(e.oid).data)
      else:
        let full = repo.workTreePath(e.path)
        let (ok, st) = statPath(full)
        if not ok: continue           # deleted from the working tree
        blobs.add Blob(name: shown, text: readWorkingFile(full, st))

  var out0 = ""
  var any = false
  for b in blobs:
    let n = searchBlob(b, re, o, out0)
    if n > 0: any = true
    if o.quiet:
      if any: break
    elif (o.filesWith and n > 0) or (o.filesWithout and n == 0):
      out0.add b.name & (if o.nulTerm: "\0" else: "\n")

  if not o.quiet:
    stdout.write out0
    stdout.flushFile()
  # git's exit status is `diff(1)`'s: 0 when something matched, 1 when nothing
  # did.  `-L` inverts what "matched" means, because its output *is* the
  # files that did not.
  if o.filesWithout: (if out0.len > 0: 0 else: 1)
  elif any: 0 else: 1
