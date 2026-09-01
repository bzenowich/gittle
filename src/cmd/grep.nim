## `grep` -- search tracked content.
##
## Three things to search and one way to search them:
##
## | | |
## |---|---|
## | the working tree | the default: every tracked file, read from disk |
## | the index | `--cached`: the staged blob, which may differ from the file |
## | a tree | `grep <pattern> <commit>`: paths are prefixed `<what you typed>:` |
## | plain files | `--no-index`, which does not need a repository at all |
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
## ## The `--` between groups
##
## With context enabled, git separates groups of lines that are not adjacent
## with a `--` line -- including across files, and including the gap left by a
## binary file's one-line report.  A binary file is never quoted line by line:
## it gets `Binary file <name> matches` and nothing else, which is why `-c`
## reports 1 for it.

import std/[os, posix, algorithm, strutils]
import ../cli, ../index, ../objects, ../pathspec, ../regex, ../repository,
       ../trees, ../util

const usageText = """usage: gittle grep [<options>] [-e] <pattern> [<rev>…] [[--] <path>…]

   -e <pattern>              the next argument is a pattern
   -i, -w, -v, -E, -F        ignore case, word, invert, ERE (default), literal
   --cached                  search the index instead of the working tree
   --no-index                search plain files, ignoring the repository
   -n, --line-number         prefix matches with their line number
   -h, -H                    suppress or force the file name prefix
   -l, --files-with-matches, --name-only
   -L, --files-without-match
   -c, --count               print a count per file
   -q, --quiet               no output; the exit status is the answer
   -z, --null                NUL after the file name
   -<num>, -C <num>, -A <num>, -B <num>    context lines
   --color[=<when>], --no-color"""

const
  colFile = "\e[35m"
  colSep = "\e[36m"
  colLine = "\e[32m"
  colMatch = "\e[1;31m"
  colReset = "\e[m"
    ## `color.grep.*` defaults (`grep.c`).  Configuring them is out of scope
    ## (docs/11), so the five are constants.

type
  Opts = object
    lineNumbers, invert, quiet, nulTerm, color: bool
    showName: bool
    filesWith, filesWithout, count: bool
    before, after: int

  Blob = object
    name: string     ## what to print, already prefixed with `<tree>:` if any
    text: string

proc searchBlob(b: Blob, re: Regex, o: Opts, out0: var string,
                lastFile: var string, lastLine: var int): int =
  ## Search one blob, appending output.  Returns the number of matching lines,
  ## which is what `-c` prints and what decides `-l` and `-L`.
  ##
  ## `lastFile`/`lastLine` carry across blobs so that the `--` separator can be
  ## decided from what was actually printed last, which is the only way to get
  ## it right at a file boundary.
  # The same splitting rule as the diff engine: a line ends at a newline or at
  # the end of the buffer, and the newline is not part of it.  So a file
  # ending in `\n` has no empty final line -- and an **empty file has no lines
  # at all**, which is not a detail: without it, `-L` and `-v -l` list every
  # empty file, and the reference repository has three.
  var starts: seq[int]
  var ends: seq[int]
  var i = 0
  while i < b.text.len:
    var e = b.text.find('\n', i)
    if e < 0: e = b.text.len
    starts.add i
    ends.add e
    i = e + 1

  var hits: seq[bool] = newSeq[bool](starts.len)
  for k in 0 ..< starts.len:
    let m = re.matchLine(b.text, starts[k], ends[k]).hit
    hits[k] = m != o.invert
    if hits[k]: inc result

  if result == 0 or o.quiet or o.filesWith or o.filesWithout or o.count:
    return
  if isBinary(b.text):
    out0.add "Binary file " &
             (if o.color: colFile & b.name & colReset else: b.name) &
             " matches\n"
    return

  # Which lines to print: every hit, plus its context.  Marked first and
  # emitted after, because two hits' context can overlap and a line must not
  # be printed twice.
  var show = newSeq[bool](starts.len)
  for k in 0 ..< starts.len:
    if not hits[k]: continue
    for j in max(k - o.before, 0) .. min(k + o.after, starts.high): show[j] = true

  for k in 0 ..< starts.len:
    if not show[k]: continue
    if (o.before > 0 or o.after > 0) and lastLine >= 0 and
       (lastFile != b.name or k > lastLine + 1):
      out0.add "--\n"
    let sep = if hits[k]: ":" else: "-"
    if o.showName:
      if o.color: out0.add colFile & b.name & colReset
      else: out0.add b.name
      if o.nulTerm: out0.add "\0"
      elif o.color: out0.add colSep & sep & colReset
      else: out0.add sep
    if o.lineNumbers:
      if o.color: out0.add colLine & $(k + 1) & colReset & colSep & sep & colReset
      elif o.nulTerm: out0.add $(k + 1) & "\0"
      else: out0.add $(k + 1) & sep
    let line = b.text[starts[k] ..< ends[k]]
    if o.color and hits[k] and not o.invert:
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
    lastFile = b.name
    lastLine = k

proc collectFiles(dir: string, out0: var seq[string]) =
  ## `--no-index`: every regular file under a directory, `.git` excluded.
  ## There is no index to consult and no ignore rules to apply -- docs/07 cuts
  ## `--exclude-standard` -- so the walk is as plain as it looks.  Symlinks are
  ## skipped for the same reason as everywhere else here: git searches only
  ## what `S_ISREG` accepts.
  for kind, path in walkDir(dir, relative = false):
    let base = path.lastPathPart
    if base == ".git": continue
    case kind
    of pcDir: collectFiles(path, out0)
    of pcFile: out0.add path
    else: discard

proc cmdGrep*(c: Ctx, args: seq[string]): int =
  # git prints the file name **always**, unlike `grep(1)`, which suppresses it
  # for a single file: `builtin/grep.c` sets `opt.pathname = 1` before parsing
  # and `-h`/`-H` clear and set it as they are seen, so the last one wins.
  var o = Opts(showName: true)
  var patterns: seq[string]
  var icase = false
  var fixed = false
  var word = false
  var cached = false
  var noIndex = false
  var rest: seq[string]      ## revisions and paths, still mixed
  var i = 0
  var seenDashDash = false
  var havePattern = false

  proc valueFor(a: string): string =
    let eq = a.find('=')
    if eq > 0: return a[eq + 1 .. ^1]
    inc i
    failIf(i >= args.len, "option '" & a & "' requires a value")
    args[i]

  while i < args.len:
    let a = args[i]
    if seenDashDash: rest.add a
    elif a == "--": seenDashDash = true
    elif a.len > 1 and a[0] == '-':
      case a
      of "-e":
        patterns.add valueFor(a)
        havePattern = true
      of "-i", "--ignore-case": icase = true
      of "-w", "--word-regexp": word = true
      of "-v", "--invert-match": o.invert = true
      of "-F", "--fixed-strings": fixed = true
      of "-E", "--extended-regexp": discard   # gittle is ERE always -- 6.4
      of "-G", "--basic-regexp", "-P", "--perl-regexp":
        fail(a & " is out of scope for gittle v1 (docs/07): gittle's " &
             "patterns are POSIX extended regular expressions, always")
      of "-n", "--line-number": o.lineNumbers = true
      of "-h": o.showName = false
      of "-H": o.showName = true
      of "-l", "--files-with-matches", "--name-only": o.filesWith = true
      of "-L", "--files-without-match": o.filesWithout = true
      of "-c", "--count": o.count = true
      of "-q", "--quiet": o.quiet = true
      of "-z", "--null": o.nulTerm = true
      of "--cached": cached = true
      of "--no-index": noIndex = true
      of "--no-color": o.color = false
      of "-C", "--context":
        o.before = parseInt(valueFor(a))
        o.after = o.before
      of "-A", "--after-context": o.after = parseInt(valueFor(a))
      of "-B", "--before-context": o.before = parseInt(valueFor(a))
      else:
        if a.startsWith("--color"):
          let w = if a.contains('='): a[a.find('=') + 1 .. ^1] else: "always"
          o.color = case w
            of "always": true
            of "never": false
            of "auto": isatty(stdout.getFileHandle()) != 0
            else: fail("invalid --color argument: " & w)
        elif a.len > 2 and a[1] == 'C' and a[2] in {'0' .. '9'}:
          o.before = parseInt(a[2 .. ^1])      # `-C1`, the attached form
          o.after = o.before
        elif a.len > 2 and a[1] == 'A' and a[2] in {'0' .. '9'}:
          o.after = parseInt(a[2 .. ^1])
        elif a.len > 2 and a[1] == 'B' and a[2] in {'0' .. '9'}:
          o.before = parseInt(a[2 .. ^1])
        elif a.len > 1 and a[1] in {'0' .. '9'}:
          o.before = parseInt(a[1 .. ^1])      # the bare `-3` form
          o.after = o.before
        elif a.startsWith("--after-context="): o.after = parseInt(valueFor(a))
        elif a.startsWith("--before-context="): o.before = parseInt(valueFor(a))
        elif a.startsWith("--context="):
          o.before = parseInt(valueFor(a))
          o.after = o.before
        elif a == "--help":
          echo usageText
          return 0
        else: fail("unknown option '" & a & "'\n" & usageText)
    elif not havePattern:
      # The first bare argument is the pattern unless `-e` already gave one.
      patterns.add a
      havePattern = true
    else: rest.add a
    inc i

  failIf(patterns.len == 0, "no pattern given\n" & usageText)
  failIf(patterns.len > 1,
         "gittle grep takes one pattern; --and/--or/-f are out of scope " &
         "(docs/07)")
  let re = compileRegex(patterns[0], icase, fixed, word)

  var blobs: seq[Blob]

  if noIndex:
    var paths: seq[string]
    if rest.len == 0: rest.add "."
    for p in rest:
      if dirExists(p): collectFiles(p, paths)
      else: paths.add p
    paths.sort()
    for p in paths:
      let rel = if p.startsWith("./"): p[2 .. ^1] else: p
      blobs.add Blob(name: rel, text: readWholeFile(p))
  else:
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
  var lastFile = ""
  var lastLine = -1
  var any = false
  for b in blobs:
    let n = searchBlob(b, re, o, out0, lastFile, lastLine)
    if n > 0: any = true
    if o.quiet:
      if any: break
      continue
    let named = (if o.nulTerm: b.name & "\0" else: b.name)
    if o.filesWith and n > 0: out0.add named & (if o.nulTerm: "" else: "\n")
    elif o.filesWithout and n == 0: out0.add named & (if o.nulTerm: "" else: "\n")
    elif o.count and n > 0:
      if o.showName:
        out0.add b.name & (if o.nulTerm: "\0" else: ":")
      out0.add $n & "\n"

  if not o.quiet:
    stdout.write out0
    stdout.flushFile()
  # git's exit status is `diff(1)`'s: 0 when something matched, 1 when nothing
  # did.  `-L` inverts what "matched" means, because its output *is* the
  # files that did not.
  if o.filesWithout: (if out0.len > 0: 0 else: 1)
  elif any: 0 else: 1
