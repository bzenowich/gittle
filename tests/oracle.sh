#!/bin/sh
# Differential tests: every claim gittle makes is checked against real git.
#
#   tests/oracle.sh [--full]
#
# Without --full the object sweeps are sampled; with it they run over every
# object in the reference repository (420k objects, ~1 minute).
#
# GITTLE   path to the binary under test   (default ./build/gittle)
# REFREPO  the repository used as the oracle (default the git checkout above)

set -u

GITTLE=${GITTLE:-$(cd "$(dirname "$0")/.." && pwd)/build/gittle}
REFREPO=${REFREPO:-$(cd "$(dirname "$0")/../.." && pwd)}
FULL=0
[ "${1:-}" = "--full" ] && FULL=1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); printf 'FAIL: %s\n' "$1"; }
check(){ # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else
    bad "$1"; printf '  expected: %s\n  actual:   %s\n' "$2" "$3"
  fi
}
report(){ printf '%-28s %s\n' "$1" "$2"; }

command -v git >/dev/null || { echo "no git on PATH"; exit 1; }
[ -x "$GITTLE" ] || { echo "no gittle binary at $GITTLE"; exit 1; }
[ -d "$REFREPO/.git" ] || { echo "no reference repository at $REFREPO"; exit 1; }

echo "gittle:  $GITTLE"
echo "oracle:  $(git --version)"
echo "repo:    $REFREPO ($(git -C "$REFREPO" describe --always))"
echo

# ------------------------------------------------------- sha1 and zlib
# The two modules with no git command in front of them.  `nim` is not required
# to run the rest of the suite, so skip these if it is missing.
SELF="$WORK/selftest"
if command -v nim >/dev/null && \
   nim c --hints:off -d:release --path:"$(dirname "$0")/../src" \
       -o:"$SELF" "$(dirname "$0")/selftest.nim" >/dev/null 2>&1; then

  # Every 64-byte block boundary, plus the padding cases at 55/56 and 119/120.
  sha_ok=1; nsha=0
  for n in 0 1 2 55 56 57 63 64 65 119 120 121 1000 100000; do
    head -c "$n" /dev/urandom > "$WORK/s.bin"; nsha=$((nsha+1))
    a=$(sha1sum < "$WORK/s.bin" | cut -d' ' -f1)
    b=$("$SELF" sha1 < "$WORK/s.bin")
    [ "$a" = "$b" ] || { sha_ok=0; echo "  n=$n sha1sum=$a gittle=$b"; }
  done
  i=0
  while [ $i -lt 200 ]; do
    head -c $(( (i * 137) % 5000 )) /dev/urandom > "$WORK/s.bin"; nsha=$((nsha+1))
    a=$(sha1sum < "$WORK/s.bin" | cut -d' ' -f1)
    b=$("$SELF" sha1 < "$WORK/s.bin")
    [ "$a" = "$b" ] || { sha_ok=0; echo "  len $(( (i*137)%5000 )) differs"; }
    i=$((i+1))
  done
  [ $sha_ok = 1 ] && { ok; report "sha1" "$nsha inputs match sha1sum"; } \
                  || bad "sha1"

  z_ok=1; nz=0
  for n in 0 1 100 4096 65536 1000000; do
    head -c "$n" /dev/urandom > "$WORK/z.bin"; nz=$((nz+1))
    "$SELF" zlib < "$WORK/z.bin" >/dev/null || { z_ok=0; echo "  random n=$n"; }
  done
  # highly compressible, and real source text
  yes "the quick brown fox" | head -50000 > "$WORK/z.bin"; nz=$((nz+1))
  "$SELF" zlib < "$WORK/z.bin" >/dev/null || { z_ok=0; echo "  repetitive"; }
  cat "$REFREPO"/*.c > "$WORK/z.bin" 2>/dev/null; nz=$((nz+1))
  "$SELF" zlib < "$WORK/z.bin" >/dev/null || { z_ok=0; echo "  source text"; }
  [ $z_ok = 1 ] && { ok; report "zlib" "$nz round trips, consumed exact"; } \
                || bad "zlib"
else
  report "sha1 and zlib" "skipped (no nim)"
fi

# ---------------------------------------------------------------- hash-object
# R1: the framing must be byte-exact or the object ID will not match git's.

hash_files=$(find "$REFREPO" -maxdepth 2 -name '*.c' -o -maxdepth 2 -name '*.h' \
             -o -maxdepth 2 -name '*.sh' | head -500)
: > "$WORK/hash.bad"
for f in $hash_files; do
  a=$(git hash-object "$f")
  b=$("$GITTLE" hash-object "$f")
  [ "$a" = "$b" ] || echo "$f git=$a gittle=$b" >> "$WORK/hash.bad"
done
n=$(echo "$hash_files" | wc -l)
if [ -s "$WORK/hash.bad" ]; then bad "hash-object on $n source files"; head -3 "$WORK/hash.bad"
else ok; report "hash-object" "$n source files match"; fi

# Awkward content: empty, a lone NUL, binary, no trailing newline, 4 MiB.
: > "$WORK/empty"
printf '\0' > "$WORK/nul"
head -c 4000000 /dev/urandom > "$WORK/big"
printf 'no trailing newline' > "$WORK/nonl"
head -c 100000 /dev/urandom > "$WORK/bin"
edge_ok=1
for f in empty nul big nonl bin; do
  for t in blob commit tree tag; do
    a=$(git hash-object -t "$t" --literally "$WORK/$f" 2>/dev/null)
    b=$("$GITTLE" hash-object -t "$t" "$WORK/$f" 2>/dev/null)
    [ "$a" = "$b" ] || { edge_ok=0; echo "  $f/$t git=$a gittle=$b"; }
  done
done
[ $edge_ok = 1 ] && { ok; report "hash-object edge cases" "5 inputs x 4 types match"; } \
                 || bad "hash-object edge cases"

# --stdin, and the type flag in both spellings.
check "hash-object --stdin" \
  "$(git hash-object --stdin < "$WORK/bin")" \
  "$("$GITTLE" hash-object --stdin < "$WORK/bin")"
check "hash-object -t commit" \
  "$(git hash-object -t commit --literally --stdin < "$WORK/nonl")" \
  "$("$GITTLE" hash-object -t commit --stdin < "$WORK/nonl")"

# ------------------------------------------------------- loose objects, -w
# gittle writes; git must read it back.  git writes; gittle must read it back.

git init -q "$WORK/gw" && git init -q "$WORK/tw"
lo_ok=1
for f in empty nul big nonl bin; do
  a=$(git -C "$WORK/gw" hash-object -w "$WORK/$f")
  b=$("$GITTLE" -C "$WORK/tw" hash-object -w "$WORK/$f")
  [ "$a" = "$b" ] || { lo_ok=0; echo "  $f: oid differs"; continue; }
  # the file on disk should be byte-identical, not merely equivalent
  p=$(echo "$a" | sed 's|^\(..\)|\1/|')
  cmp -s "$WORK/gw/.git/objects/$p" "$WORK/tw/.git/objects/$p" \
    || { lo_ok=0; echo "  $f: loose file bytes differ"; }
  # each tool reads the other's object
  git -C "$WORK/tw" cat-file -p "$a" | cmp -s - "$WORK/$f" \
    || { lo_ok=0; echo "  $f: git cannot read gittle's object"; }
  "$GITTLE" -C "$WORK/gw" cat-file -p "$a" | cmp -s - "$WORK/$f" \
    || { lo_ok=0; echo "  $f: gittle cannot read git's object"; }
done
[ $lo_ok = 1 ] && { ok; report "loose objects" "5 inputs round-trip both ways"; } \
               || bad "loose object round trip"

# gittle must also find a loose object that shadows nothing, and report -e.
o=$("$GITTLE" -C "$WORK/tw" hash-object -w "$WORK/bin")
"$GITTLE" -C "$WORK/tw" cat-file -e "$o" && ok || bad "cat-file -e on a loose object"
"$GITTLE" -C "$WORK/tw" cat-file -e 0000000000000000000000000000000000000001 \
  && bad "cat-file -e on a missing object" || ok

# ------------------------------------- packs written by git, and alternates
# The same blobs, made reachable and then packed by git, must still resolve --
# and must resolve through an alternate object database too.
git init -q "$WORK/pk"
for f in empty nul big nonl bin; do cp "$WORK/$f" "$WORK/pk/$f"; done
git -C "$WORK/pk" add -A
git -C "$WORK/pk" -c user.name=t -c user.email=t@e commit -q -m packed
git -C "$WORK/pk" -c gc.auto=0 gc -q --prune=now 2>/dev/null
packed_ok=1
ls "$WORK/pk/.git/objects/pack"/*.pack >/dev/null 2>&1 \
  || { packed_ok=0; echo "  git gc produced no pack"; }
for f in empty nul big nonl bin; do
  a=$(git hash-object "$WORK/$f")
  [ -e "$WORK/pk/.git/objects/$(echo "$a" | sed 's|^\(..\)|\1/|')" ] \
    && { packed_ok=0; echo "  $f: still loose, the test proves nothing"; }
  "$GITTLE" -C "$WORK/pk" cat-file -p "$a" | cmp -s - "$WORK/$f" \
    || { packed_ok=0; echo "  $f: not readable out of the pack"; }
done
[ $packed_ok = 1 ] && { ok; report "objects after git gc" "5 blobs out of a pack"; } \
                   || bad "objects after git gc"

git init -q "$WORK/alt"
mkdir -p "$WORK/alt/.git/objects/info"
echo "$WORK/pk/.git/objects" > "$WORK/alt/.git/objects/info/alternates"
alt_ok=1
for f in empty big bin; do
  a=$(git hash-object "$WORK/$f")
  "$GITTLE" -C "$WORK/alt" cat-file -p "$a" | cmp -s - "$WORK/$f" \
    || { alt_ok=0; echo "  $f: not found through alternates"; }
done
[ $alt_ok = 1 ] && { ok; report "objects/info/alternates" "3 objects borrowed"; } \
                || bad "objects/info/alternates"

# ------------------------------------------------------------------ cat-file
git -C "$REFREPO" rev-list --objects --all | awk '{print $1}' > "$WORK/oids"
total=$(wc -l < "$WORK/oids")

if [ $FULL = 1 ]; then
  sweep="$WORK/oids"; label="all $total objects"
else
  awk 'NR % 97 == 0' "$WORK/oids" > "$WORK/sample"; sweep="$WORK/sample"
  label="$(wc -l < "$WORK/sample" | tr -d ' ') of $total objects"
fi

git -C "$REFREPO" cat-file --batch-check < "$sweep" > "$WORK/bc.git"
"$GITTLE" -C "$REFREPO" cat-file --batch-check < "$sweep" > "$WORK/bc.gittle"
cmp -s "$WORK/bc.git" "$WORK/bc.gittle" \
  && { ok; report "cat-file --batch-check" "$label"; } \
  || bad "cat-file --batch-check"

a=$(git -C "$REFREPO" cat-file --batch < "$sweep" | sha1sum)
b=$("$GITTLE" -C "$REFREPO" cat-file --batch < "$sweep" | sha1sum)
check "cat-file --batch ($label)" "$a" "$b"

# --batch on an unresolvable name prints "<name> missing" and exits 0.
check "cat-file --batch-check missing" \
  "$(printf 'notanoid\n0000000000000000000000000000000000000001\n' \
     | git -C "$REFREPO" cat-file --batch-check)" \
  "$(printf 'notanoid\n0000000000000000000000000000000000000001\n' \
     | "$GITTLE" -C "$REFREPO" cat-file --batch-check)"

# -t, -s, -p one object at a time, over a sample of each type.
awk 'NR % 1009 == 0' "$WORK/oids" > "$WORK/small"
single_ok=1; nsingle=0
while read -r oid; do
  nsingle=$((nsingle+1))
  for flag in -t -s; do
    a=$(git -C "$REFREPO" cat-file $flag "$oid")
    b=$("$GITTLE" -C "$REFREPO" cat-file $flag "$oid")
    [ "$a" = "$b" ] || { single_ok=0; echo "  $flag $oid: git=$a gittle=$b"; }
  done
  git -C "$REFREPO" cat-file -p "$oid" > "$WORK/p.git"
  "$GITTLE" -C "$REFREPO" cat-file -p "$oid" > "$WORK/p.gittle"
  cmp -s "$WORK/p.git" "$WORK/p.gittle" || { single_ok=0; echo "  -p $oid differs"; }
  "$GITTLE" -C "$REFREPO" cat-file -e "$oid" || { single_ok=0; echo "  -e $oid failed"; }
done < "$WORK/small"
[ $single_ok = 1 ] && { ok; report "cat-file -t/-s/-e/-p" "$nsingle objects"; } \
                   || bad "cat-file -t/-s/-e/-p"

# -p must pretty-print trees, and every mode git can store must render.
git -C "$REFREPO" rev-list --objects --all | awk 'NF>1 {print $1}' > "$WORK/named"
tree_ok=1; ntree=0
for oid in $(head -4000 "$WORK/named"); do
  [ "$(git -C "$REFREPO" cat-file -t "$oid")" = tree ] || continue
  ntree=$((ntree+1))
  git -C "$REFREPO" cat-file -p "$oid" > "$WORK/t.git"
  "$GITTLE" -C "$REFREPO" cat-file -p "$oid" > "$WORK/t.gittle"
  cmp -s "$WORK/t.git" "$WORK/t.gittle" || { tree_ok=0; echo "  tree $oid differs"; }
  [ $ntree -ge 300 ] && break
done
# a tree with a gitlink and one with a symlink, so 160000 and 120000 are covered
for oid in $(git -C "$REFREPO" rev-parse HEAD^{tree}); do
  git -C "$REFREPO" cat-file -p "$oid" | cmp -s - <("$GITTLE" -C "$REFREPO" cat-file -p "$oid") \
    || tree_ok=0
done
[ $tree_ok = 1 ] && { ok; report "cat-file -p on trees" "$ntree trees"; } \
                 || bad "cat-file -p on trees"

# <type> <object>: assert, and dereference a tag or a commit.
tag=$(git -C "$REFREPO" rev-parse v2.30.0 2>/dev/null || git -C "$REFREPO" tag | head -1)
if [ -n "$tag" ]; then
  tagname=$(git -C "$REFREPO" tag | head -1)
  for form in "commit $tagname" "tree $tagname" "tree HEAD"; do
    t=${form%% *}; r=${form##* }
    oid=$(git -C "$REFREPO" rev-parse "$r^{}" 2>/dev/null) || continue
    a=$(git -C "$REFREPO" cat-file "$t" "$oid" | sha1sum)
    b=$("$GITTLE" -C "$REFREPO" cat-file "$t" "$oid" | sha1sum)
    check "cat-file $form" "$a" "$b"
  done
fi

# A type assertion that cannot be satisfied must fail, not print garbage.
head=$(git -C "$REFREPO" rev-parse HEAD)
"$GITTLE" -C "$REFREPO" cat-file blob "$head" >/dev/null 2>&1 \
  && bad "cat-file blob <commit> should fail" || ok

# ------------------------------------------------------------- abbreviations
abbrev_ok=1
for oid in $(head -20 "$WORK/small"); do
  for n in 7 10 40; do
    short=$(echo "$oid" | cut -c1-$n)
    a=$(git -C "$REFREPO" rev-parse "$short" 2>/dev/null) || continue
    b=$("$GITTLE" -C "$REFREPO" cat-file -t "$short" 2>/dev/null)
    c=$(git -C "$REFREPO" cat-file -t "$a")
    [ "$b" = "$c" ] || { abbrev_ok=0; echo "  $short: git=$c gittle=$b"; }
  done
done
[ $abbrev_ok = 1 ] && { ok; report "abbreviated object names" "7, 10 and 40 digits"; } \
                   || bad "abbreviated object names"

# ---------------------------------------------------- the extension gate (6.1)
gate() { # gate <expect-refusal:0|1> <config lines...>
  want=$1; shift
  rm -rf "$WORK/gate"; git init -q "$WORK/gate"
  printf '%s\n' "$@" >> "$WORK/gate/.git/config"
  if "$GITTLE" -C "$WORK/gate" cat-file -t 0000000000000000000000000000000000000001 \
       >/dev/null 2>"$WORK/gate.err"; then st=0; else st=$?; fi
  refused=0
  grep -q 'cannot operate on this repository' "$WORK/gate.err" && refused=1
  if [ "$refused" = "$want" ]; then ok; else
    bad "extension gate: expected refusal=$want for '$*'"
    head -4 "$WORK/gate.err" | sed 's/^/    /'
  fi
}
gate 1 '[core]' '	repositoryformatversion = 1' '[extensions]' '	refStorage = reftable'
gate 1 '[core]' '	repositoryformatversion = 1' '[extensions]' '	objectFormat = sha256'
gate 1 '[core]' '	repositoryformatversion = 1' '[extensions]' '	partialClone = origin'
gate 1 '[core]' '	repositoryformatversion = 1' '[extensions]' '	somethingNew = 1'
gate 1 '[core]' '	repositoryformatversion = 2'
gate 0 '[core]' '	repositoryformatversion = 1' '[extensions]' '	refStorage = files'
gate 0 '[core]' '	repositoryformatversion = 1' '[extensions]' '	objectFormat = sha1'
gate 0 '[core]' '	repositoryformatversion = 1' '[extensions]' '	worktreeConfig = true'
gate 0 '[core]' '	repositoryformatversion = 1' '[extensions]' '	relativeWorktrees = true'
gate 0 '[core]' '	repositoryformatversion = 0'
report "extension gate" "10 configurations"

# -------------------------------------------------------------- discovery
# The same object must be found from a subdirectory, from a bare clone, and
# from a linked worktree -- and must not be found outside a repository at all.
mkdir -p "$WORK/gw/sub"
cp "$WORK/bin" "$WORK/gw/sub/data"
echo hello > "$WORK/gw/file"
git -C "$WORK/gw" add -A
git -C "$WORK/gw" -c user.name=t -c user.email=t@e commit -q -m one
t=$(git -C "$WORK/gw" rev-parse HEAD^{tree})

mkdir -p "$WORK/gw/a/b/c"
( cd "$WORK/gw/a/b/c" && [ "$("$GITTLE" cat-file -t "$t")" = tree ] ) \
  && ok || bad "discovery from a subdirectory"

git clone -q --bare "$WORK/gw" "$WORK/bare.git"
[ "$("$GITTLE" -C "$WORK/bare.git" cat-file -t "$t" 2>&1)" = tree ] \
  && ok || bad "discovery in a bare repository"

git -C "$WORK/gw" worktree add -q "$WORK/wt" 2>/dev/null
if [ -d "$WORK/wt" ]; then
  [ "$("$GITTLE" -C "$WORK/wt" cat-file -t "$t" 2>&1)" = tree ] \
    && ok || bad "discovery in a linked worktree"
  # ... including from a subdirectory of one
  mkdir -p "$WORK/wt/x/y"
  ( cd "$WORK/wt/x/y" && [ "$("$GITTLE" cat-file -t "$t")" = tree ] ) \
    && ok || bad "discovery from a linked worktree subdirectory"
fi

"$GITTLE" -C / cat-file -t "$t" >/dev/null 2>&1 \
  && bad "should refuse to run outside a repository" || ok
report "repository discovery" "subdir, bare, worktree, none"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
