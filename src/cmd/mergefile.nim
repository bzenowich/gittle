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


const
  synopsis = "[-p] [-q] [-L <name1> [-L <orig> [-L <name2>]]] <current-file> <base-file> <other-file>"
  options = [
    opt("-p|--stdout", help = "print the result instead of writing <current-file>"),
    opt("-q|--quiet", help = "do not warn about conflicts"),
    opt("-L", okValue, arg = "<label>", help = "a name for the next file, in the markers; up to three"),
    opt("--object-id|--diff3|--zdiff3|--ours|--theirs|--union|--marker-size|--diff-algorithm",
        okRefused, help = "docs/10"),
  ]

proc cmdMergeFile*(c: Ctx, argv: seq[string]): int =
  ## Entry point: parse, read the three files, merge, and write or print
  ## the result; the exit status is the conflict count.
  let o = parse(options, argv, "merge-file", synopsis)
  var labels = o.vals "L"
  failIf(labels.len > 3, "too many labels on the command line")
  let toStdout = o.has "stdout"
  let quiet = o.has "quiet"
  let files = o.args
  if files.len != 3:
    stderr.write o.use & "\n"
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
