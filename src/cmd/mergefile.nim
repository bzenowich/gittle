## `merge-file` -- run the three-way file merge from the command line.
##
## In scope (docs/10): `<current> <base> <other>`, `-L`, `-p`, `-q`.  Cut:
## `--object-id`, `--diff3`/`--zdiff3`, `--ours`/`--theirs`/`--union`,
## `--diff-algorithm`, `--marker-size`.
##
## The argument order is the one thing about this command that surprises
## everybody: the **base is in the middle**, because the three arguments are
## `<current> <base> <other>` rather than the base-first order the operation is
## usually described in.  The `-L` labels are given in the same order, and the
## middle one labels a base that only the cut `--diff3` styles ever print.
##
## The exit status is the **number of conflicts**, capped at 127 -- not a
## success/failure boolean.  A script's `if git merge-file ...` therefore reads
## "merged cleanly", which is why the count is worth preserving exactly.

import std/os
import ../cli, ../mergefile, ../objects, ../util

const usageText = """usage: gittle merge-file [-p] [-q] [-L <name1> [-L <orig> [-L <name2>]]]
                         <current-file> <base-file> <other-file>"""

proc cmdMergeFile*(c: Ctx, argv: seq[string]): int =
  var labels: seq[string]
  var files: seq[string]
  var toStdout = false
  var quiet = false
  var i = 0
  var noMoreOpts = false
  let args = expandShortOptions(argv, {'L'})

  optionValue(args, i)
  while i < args.len:
    let a = args[i]
    if noMoreOpts or a.len == 0 or a[0] != '-': files.add a
    elif a == "--": noMoreOpts = true
    elif a == "-p" or a == "--stdout": toStdout = true
    elif a == "-q" or a == "--quiet": quiet = true
    elif a == "-L":
      failIf(labels.len >= 3, "too many labels on the command line")
      labels.add valueFor(a)
    elif a == "-h" or a == "--help":
      echo usageText
      return 0
    elif a in ["--object-id", "--diff3", "--zdiff3", "--ours", "--theirs",
               "--union", "--marker-size", "--diff-algorithm"]:
      fail(a & " is out of scope for gittle v1 (docs/10)")
    else: fail("unknown option '" & a & "'\n" & usageText)
    inc i

  if files.len != 3:
    stderr.write usageText & "\n"
    return 129

  var text: array[3, string]
  for k in 0 .. 2:
    failIf(not fileExists(files[k]), "failed to read file '" & files[k] & "'")
    text[k] = readWholeFile(files[k])
    if text[k].isBinary:
      # Not a fatal: the command line was fine.  git's own status here is the
      # error return, not a conflict count.
      if not quiet:
        stderr.write "error: Cannot merge binary files: " & files[k] & "\n"
      return 255
    if labels.len <= k: labels.add files[k]

  # `merge-file` is the one caller that runs a level higher, treating a gap
  # with no letter or digit in it as no reason to keep two conflicts apart.
  let (merged, conflicts) = mergeText(text[1], text[0], text[2],
                                      labels[0], labels[2],
                                      level = mlZealousAlnum)
  if toStdout: stdout.write merged
  else: writeFile(files[0], merged)
  min(conflicts, 127)
