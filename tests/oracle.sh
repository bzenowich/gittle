#!/bin/bash
# Differential tests: every claim gittle makes is checked against real git.
#
# bash, not sh: the suite compares two command's output with `diff <(a) <(b)`
# throughout, and process substitution is not POSIX.
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

# Prefer a git built from the reference tree over whatever is on PATH: the
# system one may be years older than the checkout it is being asked to explain.
# GIT_EXEC_PATH makes that binary find its own subcommands rather than the
# installed ones, and GIT_TEMPLATE_DIR keeps `git init` from warning about a
# templates directory that only exists after `make install`.
if [ -x "$REFREPO/git" ]; then
  GIT="$REFREPO/git"
  GIT_EXEC_PATH="$REFREPO"; export GIT_EXEC_PATH
  [ -d "$REFREPO/templates/blt" ] && { GIT_TEMPLATE_DIR="$REFREPO/templates/blt"; export GIT_TEMPLATE_DIR; }
else
  GIT=git
fi
git() { "$GIT" "$@"; }

# Tests that write refs need an identity for the reflog, and must not depend on
# whichever one the developer happens to have configured.  The dates are pinned
# too: a commit is named by the hash of its own bytes, so two tools committing
# the same tree agree only if they are told the same instant.
GIT_AUTHOR_NAME="Oracle Test"; GIT_AUTHOR_EMAIL="oracle@example.com"
GIT_COMMITTER_NAME="Oracle Test"; GIT_COMMITTER_EMAIL="oracle@example.com"
GIT_AUTHOR_DATE="1700000000 +0000"; GIT_COMMITTER_DATE="1700000060 +0100"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
export GIT_AUTHOR_DATE GIT_COMMITTER_DATE

# git applies `.mailmap` to `log` and `show` by default (log.mailmap, true
# since 2.34).  gittle does not implement it (docs/07 cuts --mailmap), so every
# comparison against the reference repository -- which has a 700-line .mailmap
# -- has to turn it off or it is comparing that, and nothing else.
NOMAILMAP=--no-use-mailmap

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
echo "oracle:  $(git --version) ($GIT)"
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

  if "$SELF" glob > "$WORK/glob.out" 2>&1; then
    ok; report "glob engine" "$(sed 's/^ok //' "$WORK/glob.out") checked"
  else
    bad "glob engine"; head -8 "$WORK/glob.out"
  fi

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

# ===========================================================================
# Phase 2 -- refs and config
# ===========================================================================

# A repository with a branch, a lightweight tag, an annotated tag and a commit
# on a second branch, so every ref shape below is represented.
REFS="$WORK/refs"
git init -q "$REFS"
echo one > "$REFS/f"; git -C "$REFS" add f; git -C "$REFS" commit -qm one
git -C "$REFS" tag lightweight
git -C "$REFS" tag -a -m annotated annotated
git -C "$REFS" branch side
echo two > "$REFS/f"; git -C "$REFS" add f; git -C "$REFS" commit -qm two
H=$(git -C "$REFS" rev-parse HEAD)
H1=$(git -C "$REFS" rev-parse HEAD~1)

# ---------------------------------------------------------------- ref names
# `check-ref-format` is the oracle.  `--allow-onelevel` is the right comparison
# because `update-ref` accepts a top-level pseudoref: `git update-ref FOO <oid>`
# works, and `git check-ref-format FOO` on its own does not.
# In its own copy: some of these names are HEAD and `main`, and creating then
# deleting those moves and removes the branch HEAD points at.
NAMES="$WORK/names"; cp -r "$REFS" "$NAMES"
name_ok=1; nnames=0
for n in \
  refs/heads/main refs/tags/v1.0 refs/heads/feature/x HEAD refs/heads/a-b_c \
  refs/heads/.hidden refs/heads/a..b refs/heads/a.lock refs/heads/a@{0} \
  'refs/heads/a b' refs/heads/a~1 refs/heads/a^ refs/heads/a: refs/heads/a? \
  'refs/heads/a[' 'refs/heads/a\\b' refs/heads/a. refs/heads//b refs/heads/ \
  @ main refs/heads/a*
do
  nnames=$((nnames+1))
  if git -C "$NAMES" check-ref-format --allow-onelevel "$n" 2>/dev/null; then
    want=0
  else want=1; fi
  # gittle has no check-ref-format command; update-ref is the same validator.
  if "$GITTLE" -C "$NAMES" update-ref "$n" "$H" 2>"$WORK/rn.err"; then got=0
  elif grep -q "invalid ref name" "$WORK/rn.err"; then got=1
  else got=0; fi   # rejected for some other reason: the name itself was fine
  [ "$want" = "$got" ] || { name_ok=0; echo "  '$n': git says $want, gittle says $got"; }
  git -C "$NAMES" update-ref -d "$n" 2>/dev/null
done
[ $name_ok = 1 ] && { ok; report "ref name validation" "$nnames names agree with git"; } \
                 || bad "ref name validation"

# ------------------------------------------------------------- for-each-ref
fer_ok=1
for a in "" "--sort=-refname" "--sort=objecttype --sort=refname" "--count=2" \
         "refs/heads" "refs/tags" "refs/heads/*" "refs/*/side"; do
  diff <(git -C "$REFS" for-each-ref $a) <("$GITTLE" -C "$REFS" for-each-ref $a) \
    >/dev/null || { fer_ok=0; echo "  for-each-ref $a differs"; }
done
for f in '%(refname)' '%(refname:short)' '%(refname:lstrip=2)' \
         '%(refname:rstrip=1)' '%(objectname)' '%(objectname:short)' \
         '%(objectname:short=12)' '%(objecttype)' '%(objectsize)' \
         '%(HEAD)%(refname)' '%(symref)' '%(upstream)' \
         '%(*objectname)' '%(*objecttype)' '%(*objectsize)' \
         'x%%y%09z' '%(refname)|%(objecttype)|%(objectsize)'; do
  diff <(git -C "$REFS" for-each-ref --format="$f") \
       <("$GITTLE" -C "$REFS" for-each-ref --format="$f") >/dev/null \
    || { fer_ok=0; echo "  --format=$f differs"; }
done
[ $fer_ok = 1 ] && { ok; report "for-each-ref" "8 option sets, 17 formats"; } \
                || bad "for-each-ref"

# Refs packed by git must read back exactly the same as loose ones.
cp -r "$REFS" "$WORK/packed"
before=$("$GITTLE" -C "$WORK/packed" for-each-ref)
git -C "$WORK/packed" pack-refs --all
[ ! -f "$WORK/packed/.git/refs/heads/side" ] || bad "pack-refs left loose refs"
after=$("$GITTLE" -C "$WORK/packed" for-each-ref)
check "packed-refs reads the same" "$before" "$after"

# A loose ref must shadow a packed one of the same name.
git -C "$WORK/packed" update-ref refs/heads/side "$H1"
check "loose ref shadows packed" \
  "$(git -C "$WORK/packed" rev-parse refs/heads/side)" \
  "$("$GITTLE" -C "$WORK/packed" for-each-ref --format='%(objectname)' refs/heads/side)"

# ---------------------------------------------------------------- symbolic-ref
check "symbolic-ref HEAD" \
  "$(git -C "$REFS" symbolic-ref HEAD)" "$("$GITTLE" -C "$REFS" symbolic-ref HEAD)"
check "symbolic-ref --short" \
  "$(git -C "$REFS" symbolic-ref --short HEAD)" \
  "$("$GITTLE" -C "$REFS" symbolic-ref --short HEAD)"
"$GITTLE" -C "$REFS" symbolic-ref refs/heads/alias refs/heads/side
check "gittle's symref, read by git" \
  "refs/heads/side" "$(git -C "$REFS" symbolic-ref refs/heads/alias)"
check "symref resolves to its target" \
  "$(git -C "$REFS" rev-parse refs/heads/side)" \
  "$(git -C "$REFS" rev-parse refs/heads/alias)"
"$GITTLE" -C "$REFS" symbolic-ref -d refs/heads/alias
git -C "$REFS" symbolic-ref refs/heads/alias >/dev/null 2>&1 \
  && bad "symbolic-ref -d left the ref behind" || ok
# -q on a ref that is not symbolic exits 1 without complaining
"$GITTLE" -C "$REFS" symbolic-ref -q refs/heads/side >/dev/null 2>&1
[ $? = 1 ] && ok || bad "symbolic-ref -q on a direct ref should exit 1"
report "symbolic-ref" "read, write, --short, -d, -q"

# ------------------------------------------------------------------ update-ref
"$GITTLE" -C "$REFS" update-ref refs/heads/written "$H" -m "by gittle"
check "gittle writes, git reads" "$H" "$(git -C "$REFS" rev-parse refs/heads/written)"
check "reflog entry gittle wrote" \
  "0000000000000000000000000000000000000000 $H" \
  "$(cut -d' ' -f1,2 < "$REFS/.git/logs/refs/heads/written")"
check "reflog message" "by gittle" \
  "$(sed 's/.*\t//' < "$REFS/.git/logs/refs/heads/written")"

# The reflog line gittle writes and the one git writes must have the same shape.
git -C "$REFS" update-ref refs/heads/gitwrote "$H" -m "by git"
check "reflog shape matches git's" \
  "$(awk '{print NF}' < "$REFS/.git/logs/refs/heads/gitwrote")" \
  "$(awk '{print NF}' < "$REFS/.git/logs/refs/heads/written")"

# Compare-and-swap: a wrong old value must fail and change nothing.
"$GITTLE" -C "$REFS" update-ref refs/heads/written "$H1" \
  0000000000000000000000000000000000000001 >/dev/null 2>&1 \
  && bad "CAS with a wrong old value should fail" || ok
check "CAS failure changed nothing" "$H" \
  "$(git -C "$REFS" rev-parse refs/heads/written)"

# A ref may not name an object that is not there, and a branch must be a commit.
"$GITTLE" -C "$REFS" update-ref refs/heads/bogus \
  deadbeefdeadbeefdeadbeefdeadbeefdeadbeef >/dev/null 2>&1 \
  && bad "should refuse a nonexistent object" || ok
TREE=$(git -C "$REFS" rev-parse "HEAD^{tree}")
"$GITTLE" -C "$REFS" update-ref refs/heads/bogus "$TREE" >/dev/null 2>&1 \
  && bad "should refuse a tree as a branch" || ok
git -C "$REFS" fsck --strict >/dev/null 2>&1 && ok || bad "fsck after gittle's writes"

# Deleting: loose, packed, and the reflog that went with it.
"$GITTLE" -C "$REFS" update-ref -d refs/heads/gitwrote
git -C "$REFS" rev-parse refs/heads/gitwrote >/dev/null 2>&1 \
  && bad "delete left the ref" || ok
[ -f "$REFS/.git/logs/refs/heads/gitwrote" ] \
  && bad "delete left the reflog" || ok
git -C "$WORK/packed" pack-refs --all
"$GITTLE" -C "$WORK/packed" update-ref -d refs/heads/side
git -C "$WORK/packed" rev-parse refs/heads/side >/dev/null 2>&1 \
  && bad "delete left a packed ref" || ok
git -C "$WORK/packed" fsck --strict >/dev/null 2>&1 && ok \
  || bad "fsck after deleting a packed ref"

# HEAD is followed, not overwritten, and both logs record the move.
: > "$REFS/.git/logs/HEAD"
: > "$REFS/.git/logs/$(git -C "$REFS" symbolic-ref HEAD)"
"$GITTLE" -C "$REFS" update-ref HEAD "$H1" -m "deref"
check "update-ref HEAD keeps it symbolic" "ref: $(git -C "$REFS" symbolic-ref HEAD)" \
  "$(cat "$REFS/.git/HEAD")"
check "the branch moved, not HEAD" "$H1" "$(git -C "$REFS" rev-parse HEAD)"
check "both reflogs recorded it" "1 1" \
  "$(wc -l < "$REFS/.git/logs/HEAD" | tr -d ' ') $(wc -l < "$REFS/.git/logs/$(git -C "$REFS" symbolic-ref HEAD)" | tr -d ' ')"
git -C "$REFS" update-ref HEAD "$H"
report "update-ref" "write, CAS, delete, deref, validation"

# --stdin: run the identical command stream through git and through gittle and
# require the same exit status, the same stdout, and the same refs afterwards.
# Comparing against git rather than against a hand-written expectation is what
# caught `symref-update` dereferencing, `option no-deref` being mandatory for
# two verbs, and `start` without `commit` meaning abort.
STDIN_A="$WORK/stdin-git"; STDIN_B="$WORK/stdin-gittle"
mk_stdin_repo() {  # a fixed date, so both copies get the same commit ID
  rm -rf "$1"; git init -q "$1"
  ( cd "$1" && echo a > f && git add f \
    && GIT_COMMITTER_DATE='1700000000 +0000' GIT_AUTHOR_DATE='1700000000 +0000' \
       git commit -qm one \
    && git branch b1 && git branch b2 \
    && git symbolic-ref refs/heads/s refs/heads/b1 ) >/dev/null 2>&1
}
mk_stdin_repo "$WORK/stdin-seed"
SH=$(git -C "$WORK/stdin-seed" rev-parse HEAD)

stdin_ok=1; nstdin=0
try_stdin() {  # try_stdin <stream> <flags> <name>
  mk_stdin_repo "$STDIN_A"; mk_stdin_repo "$STDIN_B"; nstdin=$((nstdin+1))
  printf "$1" > "$WORK/stream"
  git -C "$STDIN_A" update-ref $2 --stdin < "$WORK/stream" \
    > "$WORK/out.git" 2>/dev/null; ea=$?
  "$GITTLE" -C "$STDIN_B" update-ref $2 --stdin < "$WORK/stream" \
    > "$WORK/out.gittle" 2>/dev/null; eb=$?
  ra=$(git -C "$STDIN_A" for-each-ref --format='%(refname) %(objectname) %(symref)')
  rb=$(git -C "$STDIN_B" for-each-ref --format='%(refname) %(objectname) %(symref)')
  if [ "$ea" != "$eb" ] || [ "$ra" != "$rb" ] || \
     ! cmp -s "$WORK/out.git" "$WORK/out.gittle"; then
    stdin_ok=0
    printf '  %-40s git=%s gittle=%s\n' "$3" "$ea" "$eb"
    diff <(echo "$ra") <(echo "$rb") | head -4
    diff "$WORK/out.git" "$WORK/out.gittle" | head -3
  fi
}
try_stdin "update refs/heads/b1 $SH\n" "" "update"
try_stdin "update refs/heads/b2 $SH $SH\n" "" "update with old"
try_stdin "update refs/heads/b1 $SH 0000000000000000000000000000000000000000\n" "" "old=null"
try_stdin "delete refs/heads/b1\n" "" "delete"
try_stdin "delete refs/heads/nope\n" "" "delete missing"
try_stdin 'update refs/heads/b1 ""\n' "" "empty new value is a delete"
try_stdin "update refs/heads/b1 $SH \"\"\n" "" "empty old value"
try_stdin "create refs/heads/new $SH\n" "" "create"
try_stdin "create refs/heads/b1 $SH\n" "" "create existing"
try_stdin "verify refs/heads/b1 $SH\n" "" "verify"
try_stdin "verify refs/heads/b1\n" "" "verify with no value"
try_stdin "bogus x\n" "" "unknown command"
try_stdin "start\nupdate refs/heads/b1 $SH\ncommit\n" "" "start/commit"
try_stdin "start\nupdate refs/heads/new $SH\n" "" "start without commit aborts"
try_stdin "start\nupdate refs/heads/new $SH\nabort\n" "" "start/abort"
try_stdin "start\nstart\n" "" "double start"
try_stdin "prepare\nupdate refs/heads/b1 $SH\n" "" "update after prepare"
try_stdin "update refs/heads/new $SH\nprepare\ncommit\n" "" "prepare then commit"
try_stdin "commit\nupdate refs/heads/b1 $SH\n" "" "command after commit"
try_stdin "commit\nstart\nupdate refs/heads/new $SH\ncommit\n" "" "new transaction after commit"
try_stdin "option no-deref\nsymref-delete refs/heads/s\n" "" "no-deref + symref-delete"
try_stdin "symref-delete refs/heads/s\n" "" "symref-delete needs no-deref"
try_stdin "option bogus\n" "" "unknown option"
try_stdin "option no-deref\nupdate refs/heads/s $SH\n" "" "no-deref update on a symref"
try_stdin "symref-update refs/heads/s refs/heads/b2\n" "" "symref-update dereferences"
try_stdin "option no-deref\nsymref-update refs/heads/s refs/heads/b2\n" "" "no-deref symref-update"
try_stdin "symref-create refs/heads/ns refs/heads/b2\n" "" "symref-create"
try_stdin "update refs/heads/b1\0$SH\0\0" -z "z: empty old value"
try_stdin "update refs/heads/b1\0$SH\0" -z "z: missing old record"
try_stdin "update refs/heads/b1\0\0\0" -z "z: empty new value"
try_stdin "delete refs/heads/b1\0\0" -z "z: delete"
try_stdin "symref-create refs/heads/n\0refs/heads/b1\0" -z "z: symref-create"
try_stdin "symref-update refs/heads/s\0refs/heads/b2\0" -z "z: symref-update"
try_stdin "option no-deref\0symref-verify refs/heads/s\0refs/heads/b1\0" -z "z: symref-verify"
[ $stdin_ok = 1 ] && { ok; report "update-ref --stdin" "$nstdin streams match git exactly"; } \
                  || bad "update-ref --stdin"

# A held lock must stop a second writer rather than corrupt the ref.
touch "$REFS/.git/refs/heads/t1.lock"
"$GITTLE" -C "$REFS" update-ref refs/heads/t1 "$H1" >/dev/null 2>&1 \
  && bad "should refuse a locked ref" || ok
rm -f "$REFS/.git/refs/heads/t1.lock"
report "ref locking" "a held .lock is respected"

# ---------------------------------------------------------------------- config
CG="$WORK/cfg-git"; CT="$WORK/cfg-gittle"
git init -q "$CG"; git init -q "$CT"
cfg_both() { git -C "$CG" config "$@" >/dev/null 2>&1
             "$GITTLE" -C "$CT" config "$@" >/dev/null 2>&1; }
cfg_both set core.foo bar
cfg_both set section.key value
cfg_both set remote.origin.url 'git@example.com:p.git'
cfg_both set core.foo baz
cfg_both set 'a.sub.with.dots.key' 'has  spaces  '
cfg_both set quoting.v 'x#y;z"q\w'
cfg_both set branch.main.merge refs/heads/main
cfg_both unset section.key
cfg_both unset remote.origin.url
cmp -s "$CG/.git/config" "$CT/.git/config" \
  && { ok; report "config set/unset" "file is byte-identical to git's"; } \
  || { bad "config set/unset"; diff "$CG/.git/config" "$CT/.git/config" | head -8; }

diff <(git -C "$CT" config list --local) <("$GITTLE" -C "$CT" config list --local) \
  >/dev/null && ok || bad "config list --local"
check "config get" "baz" "$("$GITTLE" -C "$CT" config get core.foo)"
"$GITTLE" -C "$CT" config get no.such.key >/dev/null 2>&1
[ $? = 1 ] && ok || bad "config get on a missing key should exit 1"
printf '[multi]\n\tk = 1\n\tk = 2\n' >> "$CT/.git/config"
check "config get takes the last value" "2" "$("$GITTLE" -C "$CT" config get multi.k)"
check "config get --all" "1 2" \
  "$("$GITTLE" -C "$CT" config get --all multi.k | tr '\n' ' ' | sed 's/ $//')"
"$GITTLE" -C "$CT" config unset multi.k >/dev/null 2>&1
[ $? = 5 ] && ok || bad "config unset on a multi-valued key should exit 5"
"$GITTLE" -C "$CT" config unset --all multi.k
"$GITTLE" -C "$CT" config get multi.k >/dev/null 2>&1 \
  && bad "config unset --all left a value" || ok
report "config get/list" "scopes, --all, exit status"

# The parser has to survive the shapes a human writes by hand.
cat > "$WORK/hand.config" <<'CFG'
# a comment
[core] ; trailing comment
	bare = false
[remote "with space"]
	url = "  padded  "
	fetch = +refs/heads/*:refs/remotes/o/*
[bool]
	implicit
[cont]
	v = one\
two
CFG
diff <(git config --file "$WORK/hand.config" --list) \
     <("$GITTLE" config --file "$WORK/hand.config" list) >/dev/null \
  && { ok; report "config parser" "comments, subsections, continuations"; } \
  || { bad "config parser"; diff <(git config --file "$WORK/hand.config" --list) \
       <("$GITTLE" config --file "$WORK/hand.config" list) | head -8; }

# ===========================================================================
# Phase 3 -- the index and trees
# ===========================================================================

# ------------------------------------------------------- ls-tree, against git
# The reference repository's own HEAD tree: 561 top-level entries, 4,850
# recursive, every mode git can store including a gitlink.
lst_ok=1; nlst=0
for o in "" "-r" "-r -t" "-t" "-d" "-d -r" "-l" "-r -l" "--name-only" \
         "--abbrev" "--abbrev=8" "--abbrev=4" "-z"; do
  for p in "" "Documentation" "t/" "t" "Makefile" "Doc*" "*.c" "Documenta" \
           "Documentation/git-add.adoc" "Documentation/technical" "nope"; do
    nlst=$((nlst+1))
    if [ -z "$p" ]; then
      git -C "$REFREPO" ls-tree $o HEAD > "$WORK/lt.git" 2>&1
      "$GITTLE" -C "$REFREPO" ls-tree $o HEAD > "$WORK/lt.gittle" 2>&1
    else
      git -C "$REFREPO" ls-tree $o HEAD -- "$p" > "$WORK/lt.git" 2>&1
      "$GITTLE" -C "$REFREPO" ls-tree $o HEAD -- "$p" > "$WORK/lt.gittle" 2>&1
    fi
    cmp -s "$WORK/lt.git" "$WORK/lt.gittle" \
      || { lst_ok=0; echo "  ls-tree $o -- '$p'";
           diff "$WORK/lt.git" "$WORK/lt.gittle" | head -3; }
  done
done
[ $lst_ok = 1 ] && { ok; report "ls-tree" "$nlst option and path combinations"; } \
                || bad "ls-tree"

# -------------------------------------- the index git wrote, read by gittle
# 4,850 entries of somebody else's index, without touching it.
cp "$REFREPO/.git/index" "$WORK/big.index"
check "write-tree over git's own index" \
  "$(GIT_INDEX_FILE=$WORK/big.index git -C "$REFREPO" write-tree)" \
  "$(GIT_INDEX_FILE=$WORK/big.index "$GITTLE" -C "$REFREPO" write-tree)"
big_ok=1
for o in "" "-s"; do
  GIT_INDEX_FILE="$WORK/big.index" git -C "$REFREPO" ls-files $o > "$WORK/lf.git"
  GIT_INDEX_FILE="$WORK/big.index" "$GITTLE" -C "$REFREPO" ls-files $o > "$WORK/lf.gittle"
  cmp -s "$WORK/lf.git" "$WORK/lf.gittle" || { big_ok=0; echo "  ls-files $o"; }
done
for p in "*.c" "Documentation" "t/" "Makefile" "Documentation/*.adoc"; do
  GIT_INDEX_FILE="$WORK/big.index" git -C "$REFREPO" ls-files -- "$p" > "$WORK/lf.git"
  GIT_INDEX_FILE="$WORK/big.index" "$GITTLE" -C "$REFREPO" ls-files -- "$p" > "$WORK/lf.gittle"
  cmp -s "$WORK/lf.git" "$WORK/lf.gittle" || { big_ok=0; echo "  ls-files -- $p"; }
done
[ $big_ok = 1 ] && { ok; report "ls-files" "4850 entries, 5 pathspecs"; } \
                || bad "ls-files on git's index"

# ---------------------------------------------- interleaving on one repository
IDX="$WORK/idx"
git init -q "$IDX"
( cd "$IDX" && mkdir -p a/b && echo hello > f.txt && echo deep > a/b/deep.txt \
  && printf '#!/bin/sh\n' > run.sh && chmod +x run.sh && ln -s f.txt link )

# gittle stages; git must see exactly that, and agree on the tree.
( cd "$IDX" && "$GITTLE" update-index --add f.txt a/b/deep.txt run.sh link )
check "git sees what gittle staged" \
  "A  a/b/deep.txt
A  f.txt
A  link
A  run.sh" "$(git -C "$IDX" status --porcelain)"
check "the same tree object" \
  "$(git -C "$IDX" write-tree)" "$("$GITTLE" -C "$IDX" write-tree)"
diff <(git -C "$IDX" ls-files -s) <("$GITTLE" -C "$IDX" ls-files -s) >/dev/null \
  && ok || bad "ls-files -s after gittle staged"
git -C "$IDX" commit -qm one
git -C "$IDX" fsck --strict >/dev/null 2>&1 && ok || bad "fsck after gittle wrote the index"
report "gittle writes, git reads" "modes 100644, 100755 and 120000"

# Every ls-files selector, against a working tree that is modified, deleted
# and chmod'd at once -- git emits up to three lines per entry, so the
# combinations are where the structure shows.
( cd "$IDX" && echo changed > f.txt && rm a/b/deep.txt && chmod -x run.sh )
sel_ok=1; nsel=0
for o in "" "-c" "-s" "-m" "-d" "-u" "-c -m" "-d -m" "-c -d -m" "-m -s" "-z" \
         "-c -s" "-u -s" "-c -u" "-c -d" "-d -s"; do
  nsel=$((nsel+1))
  git -C "$IDX" ls-files $o > "$WORK/s.git" 2>&1
  "$GITTLE" -C "$IDX" ls-files $o > "$WORK/s.gittle" 2>&1
  cmp -s "$WORK/s.git" "$WORK/s.gittle" \
    || { sel_ok=0; echo "  ls-files $o"; diff "$WORK/s.git" "$WORK/s.gittle" | head -3; }
done
[ $sel_ok = 1 ] && { ok; report "ls-files selectors" "$nsel combinations"; } \
                || bad "ls-files selectors"

# --refresh must leave an index git calls clean.
( cd "$IDX" && git checkout -q -- . && touch f.txt run.sh \
  && "$GITTLE" update-index --refresh >/dev/null )
check "git status after gittle --refresh" "" "$(git -C "$IDX" status --porcelain)"

# --cacheinfo stages without a working-tree file at all.
BLOB=$(echo staged-directly | git -C "$IDX" hash-object -w --stdin)
"$GITTLE" -C "$IDX" update-index --add --cacheinfo "100644,$BLOB,virtual.txt"
check "--cacheinfo, read by git" "100644 $BLOB 0	virtual.txt" \
  "$(git -C "$IDX" ls-files -s virtual.txt)"
git -C "$IDX" reset -q --hard

# ---------------------------------------------------------- index formats
FMT="$WORK/fmt"
git init -q "$FMT"
( cd "$FMT" && mkdir -p d && for i in 1 2 3; do echo "file $i" > "d/f$i.txt"; done \
  && echo top > top.txt && git add -A && git commit -qm one )
fmt_ok=1
for v in 2 3 4; do
  git -C "$FMT" update-index --index-version $v >/dev/null 2>&1
  diff <(git -C "$FMT" ls-files -s) <("$GITTLE" -C "$FMT" ls-files -s) >/dev/null \
    || { fmt_ok=0; echo "  index v$v reads differently"; }
  [ "$(git -C "$FMT" write-tree)" = "$("$GITTLE" -C "$FMT" write-tree)" ] \
    || { fmt_ok=0; echo "  index v$v gives a different tree"; }
done
[ $fmt_ok = 1 ] && { ok; report "index versions" "2, 3 and 4 all read"; } \
                || bad "index versions"

git -C "$FMT" update-index --index-version 2 >/dev/null
git -C "$FMT" update-index --skip-worktree top.txt
( cd "$FMT" && "$GITTLE" update-index --add d/f1.txt )
check "extended flags survive a gittle rewrite" "S top.txt" \
  "$(git -C "$FMT" ls-files -v top.txt)"
git -C "$FMT" update-index --no-skip-worktree top.txt

# index.skipHash writes an all-zero trailer, which is valid and must be read.
git -C "$FMT" -c index.skipHash=true add -A
check "a zeroed checksum is accepted" \
  "$(git -C "$FMT" ls-files -s | head -1)" \
  "$("$GITTLE" -C "$FMT" ls-files -s | head -1)"

# A split index is a *required* extension gittle does not implement, so it must
# be refused by name rather than half-read.
git -C "$FMT" update-index --split-index >/dev/null 2>&1
"$GITTLE" -C "$FMT" ls-files >/dev/null 2>"$WORK/split.err"
grep -q "this index is split" "$WORK/split.err" && ok \
  || { bad "split index should be refused by name"; head -2 "$WORK/split.err"; }
git -C "$FMT" update-index --no-split-index >/dev/null 2>&1
report "index formats" "v2/v3/v4, skipHash, split refused"

# ------------------------------------- paths that need quoting, and exit codes
# git C-quotes a path containing a quote, a backslash, a control character or
# any byte above ASCII -- but not under -z, where the NUL already delimits.
QP="$WORK/quote"
git init -q "$QP"
( cd "$QP" && printf x > "sp ace.txt" && printf y > 'quo"te.txt' \
  && printf z > "$(printf 'uni\303\251.txt')" && git add -A && git commit -qm q ) >/dev/null 2>&1
quote_ok=1
for o in "" "-s" "-z"; do
  diff <(git -C "$QP" ls-files $o) <("$GITTLE" -C "$QP" ls-files $o) >/dev/null \
    || { quote_ok=0; echo "  ls-files $o"; diff <(git -C "$QP" ls-files $o) <("$GITTLE" -C "$QP" ls-files $o) | head -3; }
done
for o in "" "-r" "--name-only" "-z"; do
  diff <(git -C "$QP" ls-tree $o HEAD) <("$GITTLE" -C "$QP" ls-tree $o HEAD) >/dev/null \
    || { quote_ok=0; echo "  ls-tree $o"; }
done
[ $quote_ok = 1 ] && { ok; report "path quoting" "quote, space and UTF-8, and -z"; } \
                  || bad "path quoting"

# --error-unmatch is a status code, and only the cached pass satisfies it.
git -C "$QP" ls-files --error-unmatch nope >/dev/null 2>&1; ea=$?
"$GITTLE" -C "$QP" ls-files --error-unmatch nope >/dev/null 2>&1; eb=$?
check "--error-unmatch on a missing path" "$ea" "$eb"
git -C "$QP" ls-files --error-unmatch -m "sp ace.txt" >/dev/null 2>&1; ea=$?
"$GITTLE" -C "$QP" ls-files --error-unmatch -m "sp ace.txt" >/dev/null 2>&1; eb=$?
check "--error-unmatch counts only the cached pass" "$ea" "$eb"

# ------------------------------------------------------------------ read-tree
RT="$WORK/rt"
git clone -q "$IDX" "$RT" 2>/dev/null
( cd "$RT" && "$GITTLE" read-tree HEAD )
check "read-tree then git write-tree" "$(git -C "$RT" rev-parse "HEAD^{tree}")" \
  "$(git -C "$RT" write-tree)"
( cd "$RT" && "$GITTLE" read-tree --empty )
check "read-tree --empty" "" "$(git -C "$RT" ls-files)"
( cd "$RT" && "$GITTLE" read-tree HEAD )
diff <(git -C "$RT" ls-files -s) <("$GITTLE" -C "$RT" ls-files -s) >/dev/null \
  && ok || bad "read-tree produced a different index"
git -C "$RT" fsck --strict >/dev/null 2>&1 && ok || bad "fsck after read-tree"
report "read-tree" "a tree, and --empty"

# An unmerged index has three stages for one path; neither tool may write a
# tree from it.
MG="$WORK/merge"
git init -q "$MG"
( cd "$MG" && echo base > f && git add f && git commit -qm base \
  && git checkout -qb side && echo side > f && git commit -qam side \
  && git checkout -q - && echo main > f && git commit -qam main \
  && git merge side ) >/dev/null 2>&1
diff <(git -C "$MG" ls-files -u) <("$GITTLE" -C "$MG" ls-files -u) >/dev/null \
  && ok || bad "ls-files -u on a conflicted index"
"$GITTLE" -C "$MG" write-tree >/dev/null 2>&1 \
  && bad "write-tree should refuse an unmerged index" || ok
report "unmerged entries" "three stages read, write-tree refuses"

# ===========================================================================
# Phase 4: init, add, commit, log, show, and the ignore/pathspec engine
# ===========================================================================

# `git init` copies a template directory; `--template` is cut from gittle, so
# the two are compared with an empty one.  Otherwise this would be measuring
# whether gittle ships `hooks/pre-commit.sample`, which it deliberately does not.
EMPTYTPL="$WORK/empty-template"
mkdir -p "$EMPTYTPL"

# ---------------------------------------------------------------------- init
IN="$WORK/init"; mkdir -p "$IN"
( cd "$IN" && GIT_TEMPLATE_DIR="$EMPTYTPL" git init -q a >/dev/null 2>&1 \
           && "$GITTLE" init -q b >/dev/null )
diff <(cd "$IN/a" && find . | sort) <(cd "$IN/b" && find . | sort) >/dev/null \
  && ok || { bad "init created a different tree"; diff <(cd "$IN/a" && find . | sort) <(cd "$IN/b" && find . | sort); }
cmp -s "$IN/a/.git/config" "$IN/b/.git/config" && ok || bad "init config differs"
cmp -s "$IN/a/.git/HEAD" "$IN/b/.git/HEAD" && ok || bad "init HEAD differs"
( cd "$IN" && GIT_TEMPLATE_DIR="$EMPTYTPL" git init -q --bare ba >/dev/null 2>&1 \
           && "$GITTLE" init -q --bare bb >/dev/null )
cmp -s "$IN/ba/config" "$IN/bb/config" && ok || bad "init --bare config differs"
diff <(cd "$IN/ba" && find . | sort) <(cd "$IN/bb" && find . | sort) >/dev/null \
  && ok || bad "init --bare created a different tree"
# -b names the initial branch, and a second init must not disturb anything.
( cd "$IN" && "$GITTLE" init -q -b trunk c >/dev/null )
check "init -b" "ref: refs/heads/trunk" "$(cat "$IN/c/.git/HEAD")"
( cd "$IN/c" && echo x > f && "$GITTLE" add f && "$GITTLE" commit -qm one )
before=$(git -C "$IN/c" rev-parse HEAD)
out=$( cd "$IN/c" && "$GITTLE" init )
case "$out" in Reinitialized*) ok;; *) bad "re-init message: $out";; esac
check "re-init keeps HEAD" "$before" "$(git -C "$IN/c" rev-parse HEAD)"
git -C "$IN/c" fsck --strict >/dev/null 2>&1 && ok || bad "fsck after gittle init+commit"
report "init" "layout, config bytes, --bare, -b, re-init"

# --------------------------------------------------- commit-tree, byte-exact
# The command with no index, no hooks and no message cleanup in front of it:
# whatever the two tools disagree about here is the commit format itself.
CT="$WORK/ct"
git init -q "$CT"
( cd "$CT" && echo one > a && mkdir -p d && echo two > d/b && git add . )
T1=$(git -C "$CT" write-tree)
( cd "$CT" && echo three >> a && git add . )
T2=$(git -C "$CT" write-tree)
ct_ok=1; nct=0
P1=$(git -C "$CT" commit-tree "$T1" -m base)
for spec in "$T1||one" "$T2||one" "$T1|$P1|child" "$T2|$P1|child" \
            "$T1|$P1 $P1|dup" "$T1||multi
line
message" "$T1||trailing   spaces   " "$T1||#looks like a comment" \
            "$T1||" "$T2|$P1|a
"; do
  tree=${spec%%|*}; rest=${spec#*|}; par=${rest%%|*}; msg=${rest#*|}
  args=""
  for p in $par; do args="$args -p $p"; done
  nct=$((nct+1))
  a=$(printf '%s' "$msg" | git -C "$CT" commit-tree $args "$tree" 2>/dev/null)
  b=$(printf '%s' "$msg" | "$GITTLE" -C "$CT" commit-tree $args "$tree" 2>/dev/null)
  [ "$a" = "$b" ] || { ct_ok=0; echo "  commit-tree differs: tree=$tree parents='$par'"; }
done
# -m is repeatable and paragraphs join with a blank line; -F reads a file.
printf 'from a file\n' > "$WORK/msg.txt"
for args in "-m one" "-m one -m two" "-m one -m two -m three" \
            "-F $WORK/msg.txt" "-m one -F $WORK/msg.txt"; do
  nct=$((nct+1))
  a=$(git -C "$CT" commit-tree $args "$T1")
  b=$("$GITTLE" -C "$CT" commit-tree $args "$T1")
  [ "$a" = "$b" ] || { ct_ok=0; echo "  commit-tree $args: git=$a gittle=$b"; }
done
[ $ct_ok = 1 ] && { ok; report "commit-tree" "$nct object IDs match git's"; } \
               || bad "commit-tree"
git -C "$CT" fsck --strict >/dev/null 2>&1 && ok || bad "fsck after commit-tree"

# ------------------------------------------------ commit message cleanup (R1)
# The pipeline that decides the bytes hashed into the commit.  Compared by
# object ID, never by text: a message differing by one trailing newline prints
# identically under `log` and is a different commit.
mk_msg_repo() { rm -rf "$1"; git init -q "$1"; ( cd "$1" && echo x > f && git add f ); }
msg_ok=1; nmsg=0
while IFS= read -r m; do
  [ -z "$m" ] && continue
  msg=$(printf '%b' "$m")
  mk_msg_repo "$WORK/m1"; mk_msg_repo "$WORK/m2"
  ( cd "$WORK/m1" && git commit -q -m "$msg" >/dev/null 2>&1 )
  ( cd "$WORK/m2" && "$GITTLE" commit -q -m "$msg" >/dev/null 2>&1 )
  a=$(git -C "$WORK/m1" rev-parse HEAD 2>/dev/null)
  b=$(git -C "$WORK/m2" rev-parse HEAD 2>/dev/null)
  nmsg=$((nmsg+1))
  [ "$a" = "$b" ] || { msg_ok=0; printf '  message %s: git=%s gittle=%s\n' "$m" "$a" "$b"; }
done <<'MSGS'
plain
  leading spaces kept
trailing spaces stripped\t
\n\n\nleading blank lines
trailing blank lines\n\n\n
a\n\n\n\nb collapsed to one blank
# a comment survives -m
line one\nline two
a\tb tab inside
unicode \xc3\xa9\xc3\xa8
MSGS
[ $msg_ok = 1 ] && { ok; report "commit message cleanup" "$nmsg messages, identical object IDs"; } \
                || bad "commit message cleanup"

# -F, and the message a hook rewrote, go through the same pipeline.
mk_msg_repo "$WORK/m1"; mk_msg_repo "$WORK/m2"
printf '  subject  \n\n\n\nbody\n\n\n' > "$WORK/msg2.txt"
( cd "$WORK/m1" && git commit -q -F "$WORK/msg2.txt" )
( cd "$WORK/m2" && "$GITTLE" commit -q -F "$WORK/msg2.txt" )
check "commit -F" "$(git -C "$WORK/m1" rev-parse HEAD)" "$(git -C "$WORK/m2" rev-parse HEAD)"
# An empty message aborts rather than committing nothing.
mk_msg_repo "$WORK/m3"
( cd "$WORK/m3" && "$GITTLE" commit -q -m "   " >/dev/null 2>&1 ) \
  && bad "an empty message should abort" || ok

# ------------------------------------------------------- the ignore engine
# A generated matrix, checked through `ls-files`, which is the shared engine's
# only observable surface until `check-ignore` arrives in phase 10.
IG="$WORK/ignore"
git init -q "$IG"
( cd "$IG"
  mkdir -p a/b/c doc build sub/build tmp "sp ace" deep/x/y out nested
  for f in a/x.c a/b/y.c a/b/c/z.c doc/d.txt doc/d.log build/o.o sub/build/p.o \
           sub/q.txt tmp/t1 "sp ace/s.txt" top.txt top.log Makefile keep.log \
           deep/x/y/f.c deep/x/g.c out/x nested/note.md 'hash#file'; do
    echo content > "$f"
  done
  cat > .gitignore <<'PATTERNS'
# a comment line
*.log
!keep.log
build/
/tmp
a/b/*.c
out
**/y/*.c
deep/**/g.c
\#hash*
PATTERNS
  printf '!*.log\n*.txt\n' > doc/.gitignore
  printf 'q.txt\n' > sub/.gitignore )
ig_ok=1; nig=0
for opts in "-o --exclude-standard" "-o -i --exclude-standard" "-o" \
            "-o --exclude-standard -- a" "-o --exclude-standard -- '*.c'" \
            "-o --exclude-standard -- ':(glob)*.c'" \
            "-o --exclude-standard -- doc sub"; do
  nig=$((nig+1))
  diff <(eval git -C "$IG" ls-files $opts) <(eval "$GITTLE" -C "$IG" ls-files $opts) \
    >/dev/null || { ig_ok=0; echo "  ls-files $opts differs"; }
done
# From a subdirectory: the pathspec prefix and the relative output both apply.
for d in a doc sub deep/x; do
  for opts in "-o --exclude-standard" "-o --exclude-standard ." "-o --exclude-standard ':(top).'"; do
    nig=$((nig+1))
    diff <(cd "$IG/$d" && eval git ls-files $opts) \
         <(cd "$IG/$d" && eval "$GITTLE" ls-files $opts) >/dev/null \
      || { ig_ok=0; echo "  ls-files $opts in $d differs"; }
  done
done
# The trap: a file under an excluded directory cannot be re-included.
( cd "$IG" && printf 'nested/\n!nested/note.md\n' >> .gitignore )
nig=$((nig+1))
diff <(git -C "$IG" ls-files -o --exclude-standard) \
     <("$GITTLE" -C "$IG" ls-files -o --exclude-standard) >/dev/null \
  || { ig_ok=0; echo "  re-include under an excluded directory differs"; }
[ $ig_ok = 1 ] && { ok; report "ignore and pathspec" "$nig listings match git"; } \
               || bad "ignore engine"

# check-ignore is phase 10, so the per-path answer is cross-checked through
# `add`, which refuses an ignored path named outright.
ci_ok=1; nci=0
for p in top.log keep.log build/o.o tmp/t1 a/b/y.c a/b/c/z.c out/x doc/d.txt \
         doc/d.log sub/q.txt 'hash#file' deep/x/y/f.c deep/x/g.c Makefile \
         nested/note.md; do
  nci=$((nci+1))
  git -C "$IG" check-ignore -q "$p" && want=ignored || want=not
  "$GITTLE" -C "$IG" add -n "$p" >/dev/null 2>&1 && got=not || got=ignored
  [ "$want" = "$got" ] || { ci_ok=0; echo "  $p: git says $want, gittle says $got"; }
done
[ $ci_ok = 1 ] && { ok; report "ignored-path decisions" "$nci paths agree with check-ignore"; } \
               || bad "ignored-path decisions"

# ------------------------------------------------------------------------ add
mk_add() {  # mk_add <dir> <tool>
  rm -rf "$1"; git init -q "$1"
  ( cd "$1"
    mkdir -p src doc build
    for f in src/a.c src/b.c doc/d.txt build/o.o top.txt ignored.txt; do
      echo original > "$f"
    done
    printf 'build/\nignored.txt\n' > .gitignore )
}
add_ok=1; nadd=0
for args in "." "-A" "-n ." "-v ." "src" "src doc" "'*.c'" "':(glob)*.c'" \
            "-f ignored.txt" "-f ." "--" "-- ." "top.txt src/a.c"; do
  nadd=$((nadd+1))
  mk_add "$WORK/a1"; mk_add "$WORK/a2"
  ao=$(cd "$WORK/a1" && eval git add $args 2>&1); arc=$?
  bo=$(cd "$WORK/a2" && eval "$GITTLE" add $args 2>&1); brc=$?
  # The hint lines differ (git advertises `git config` keys gittle has not
  # got), so the comparison is on the index, the status and the exit code.
  [ "$arc" = "$brc" ] || { add_ok=0; echo "  add $args: exit $arc vs $brc"; }
  diff <(git -C "$WORK/a1" ls-files -s) <(git -C "$WORK/a2" ls-files -s) >/dev/null \
    || { add_ok=0; echo "  add $args: index differs"; }
done
# -u stages modifications and removals of tracked paths and nothing else.
for pre in "modify" "delete" "both"; do
  for args in "-u" "-u src" "-A" "." "src"; do
    nadd=$((nadd+1))
    mk_add "$WORK/a1"; mk_add "$WORK/a2"
    for d in "$WORK/a1" "$WORK/a2"; do
      ( cd "$d" && git add . >/dev/null 2>&1
        case "$pre" in
          modify) echo changed > src/a.c;;
          delete) rm src/b.c;;
          both)   echo changed > src/a.c; rm src/b.c; echo new > src/c.c;;
        esac )
    done
    ( cd "$WORK/a1" && eval git add $args >/dev/null 2>&1 )
    ( cd "$WORK/a2" && eval "$GITTLE" add $args >/dev/null 2>&1 )
    diff <(git -C "$WORK/a1" ls-files -s) <(git -C "$WORK/a2" ls-files -s) >/dev/null \
      || { add_ok=0; echo "  add $args after $pre: index differs"; }
  done
done
# --dry-run prints what would happen and changes nothing.
mk_add "$WORK/a1"; mk_add "$WORK/a2"
diff <(cd "$WORK/a1" && git add -n .) <(cd "$WORK/a2" && "$GITTLE" add -n .) >/dev/null \
  && ok || { add_ok=0; bad "add -n output differs"; }
[ -f "$WORK/a2/.git/index" ] && { add_ok=0; bad "add -n wrote the index"; } || ok
# From a subdirectory, and with a path that climbs out of one.
mk_add "$WORK/a1"; mk_add "$WORK/a2"
diff <(cd "$WORK/a1/src" && git add -n . ../doc) \
     <(cd "$WORK/a2/src" && "$GITTLE" add -n . ../doc) >/dev/null \
  && ok || { add_ok=0; bad "add from a subdirectory differs"; }
[ $add_ok = 1 ] && { ok; report "add" "$nadd option and pathspec combinations"; } \
                || bad "add"

# ------------------------------------------------------------------- commit
# One scripted history, built twice, compared as objects.  Every step that
# differs shows up as a different commit ID and every later step inherits it,
# so this is the strongest single check in the suite.
build_history() {  # build_history <dir> <tool>
  rm -rf "$1"; git init -q "$1"
  cd "$1"
  echo a > f; echo b > g; mkdir -p d; echo c > d/h; printf 'build/\n' > .gitignore
  mkdir -p build; echo junk > build/o.o
  $2 add .                       >/dev/null
  $2 commit -q -m "first commit" >/dev/null
  echo a2 >> f
  $2 add f                                    >/dev/null
  $2 commit -q -m subject -m "and a body"     >/dev/null
  echo b2 >> g
  $2 commit -qam "staged with -a"             >/dev/null
  rm g
  $2 commit -qam "a removal"                  >/dev/null
  echo x > only.txt; $2 add only.txt >/dev/null; echo y >> f
  $2 commit -q -m "a partial commit" f        >/dev/null
  $2 commit -q --amend -m "amended"           >/dev/null
  $2 commit -q --allow-empty -m "empty"       >/dev/null
  $2 commit -q --allow-empty -s -m "signed"   >/dev/null
  $2 commit -q --allow-empty -m "other" --author="Other Person <o@p.example>" >/dev/null
  $2 commit -q --allow-empty -m "dated" --date="1600000000 +0200"            >/dev/null
  cd - >/dev/null
}
build_history "$WORK/h1" "$GIT"
build_history "$WORK/h2" "$GITTLE"
diff <(git -C "$WORK/h1" log --pretty=raw) <(git -C "$WORK/h2" log --pretty=raw) \
  >/dev/null && ok || { bad "commit histories differ"; \
  diff <(git -C "$WORK/h1" log --pretty=raw) <(git -C "$WORK/h2" log --pretty=raw) | head -12; }
diff <(git -C "$WORK/h1" ls-files -s) <(git -C "$WORK/h2" ls-files -s) >/dev/null \
  && ok || bad "commit left a different index"
diff <(git -C "$WORK/h1" status --porcelain) <(git -C "$WORK/h2" status --porcelain) \
  >/dev/null && ok || bad "git status disagrees after gittle committed"
diff <(cat "$WORK/h1/.git/logs/HEAD") <(cat "$WORK/h2/.git/logs/HEAD") >/dev/null \
  && ok || { bad "reflogs differ"; diff <(cat "$WORK/h1/.git/logs/HEAD") <(cat "$WORK/h2/.git/logs/HEAD") | head -6; }
diff <(cat "$WORK/h1/.git/logs/refs/heads/"*) <(cat "$WORK/h2/.git/logs/refs/heads/"*) \
  >/dev/null && ok || bad "branch reflogs differ"
git -C "$WORK/h2" fsck --strict >/dev/null 2>&1 && ok || bad "fsck after gittle commit"
# git can carry on in gittle's repository and vice versa.
( cd "$WORK/h2" && echo z >> f && git commit -qam "git continues" )
( cd "$WORK/h2" && echo w >> f && "$GITTLE" commit -qam "gittle continues" )
git -C "$WORK/h2" fsck --strict >/dev/null 2>&1 && ok || bad "fsck after interleaving"
check "interleaved history length" "11" "$(git -C "$WORK/h2" rev-list --count HEAD)"
report "commit" "9 commits either way, identical objects, reflogs and index"

# Refusals, with the exit status git uses.
NT="$WORK/nothing"
rm -rf "$NT"; git init -q "$NT"
( cd "$NT" && echo a > f && "$GITTLE" add f && "$GITTLE" commit -qm one )
( cd "$NT" && "$GITTLE" commit -m two >/dev/null 2>&1 ) && bad "commit with nothing staged should fail" || ok
( cd "$NT" && "$GITTLE" commit -am two -a f >/dev/null 2>&1 ) && bad "-a with paths should fail" || ok
BR="$WORK/bare"; rm -rf "$BR"; git init -q --bare "$BR"
( cd "$BR" && "$GITTLE" commit -m x >/dev/null 2>&1 ) && bad "commit in a bare repo should fail" || ok
report "commit refusals" "nothing staged, -a with paths, bare"

# ------------------------------------------------------------------- hooks
HK="$WORK/hooks"
rm -rf "$HK"; git init -q "$HK"; mkdir -p "$HK/.git/hooks"
( cd "$HK" && echo a > f && "$GITTLE" add f )
printf '#!/bin/sh\nexit 1\n' > "$HK/.git/hooks/pre-commit"; chmod +x "$HK/.git/hooks/pre-commit"
( cd "$HK" && "$GITTLE" commit -qm x >/dev/null 2>&1 ) && bad "pre-commit did not stop the commit" || ok
( cd "$HK" && "$GITTLE" commit -q --no-verify -m x >/dev/null 2>&1 ) && ok || bad "--no-verify did not bypass pre-commit"
rm "$HK/.git/hooks/pre-commit"
printf '#!/bin/sh\nsed -i "s/^/hooked /" "$1"\n' > "$HK/.git/hooks/commit-msg"
chmod +x "$HK/.git/hooks/commit-msg"
( cd "$HK" && echo b >> f && "$GITTLE" commit -qam rewritten )
check "commit-msg rewrote the message" "hooked rewritten" \
  "$(git -C "$HK" log -1 --format=%s)"
# The editor is a shell command line, and its result goes through the same
# cleanup -- so the comment line the template adds does not reach the commit.
rm "$HK/.git/hooks/commit-msg"
( cd "$HK" && echo c >> f && GIT_EDITOR='sh -c "printf \"from the editor\n# a comment\n\" > $1" --' "$GITTLE" commit -qa )
check "editor message, comments stripped" "from the editor" \
  "$(git -C "$HK" log -1 --format=%B | head -1)"
check "editor comment line dropped" "1" "$(git -C "$HK" log -1 --format=%B | grep -c .)"
# A pre-commit hook exists to inspect what is about to be committed, so under
# `-a` it must see the staged state and not the index still on disk.  Both
# tools point it at a temporary index through GIT_INDEX_FILE.
HK2="$WORK/hooks2"
for d in "$HK2/a" "$HK2/b"; do
  rm -rf "$d"; git init -q "$d"; mkdir -p "$d/.git/hooks"
  printf '#!/bin/sh\n%s diff --cached --name-only\n' "$GIT" > "$d/.git/hooks/pre-commit"
  chmod +x "$d/.git/hooks/pre-commit"
  ( cd "$d" && echo a > f && echo b > g && git add . \
    && git commit -qm base --no-verify && echo a2 >> f )
done
diff <(cd "$HK2/a" && git commit -qam second 2>&1) \
     <(cd "$HK2/b" && "$GITTLE" commit -qam second 2>&1) >/dev/null \
  && ok || bad "pre-commit sees a different index under -a"
[ -z "$(ls "$HK2/b/.git" | grep next-index)" ] && ok \
  || bad "commit left a temporary index behind"
report "hooks and editor" "pre-commit, --no-verify, commit-msg, \$GIT_EDITOR, GIT_INDEX_FILE"

# --------------------------------------------------------------------- log
# The formatting vocabulary, enumerated against the reference repository.
LOGN=400
[ $FULL = 1 ] && LOGN=20000
log_ok=1; nlog=0
for f in "" "--oneline" "--pretty=oneline" "--pretty=raw" "--pretty=full" \
         "--pretty=fuller" "--date=iso8601" "--date=iso8601-strict" \
         "--date=rfc2822" "--date=short" "--date=raw" "--date=unix" \
         "--date=human" "--date=relative" "--date=local" "--date=iso-local" \
         "--relative-date" "--parents" "--abbrev-commit" "--abbrev=12" \
         "--abbrev=12 --abbrev-commit" "--reverse" "--skip=7" \
         "--first-parent" "--no-walk" "--format=%B" "--format=%b" \
         "--format=%s" "--format=%f" "--format=%H" \
         "--pretty=format:%h|%p|%T|%t|%ci|%cr|%f|%an|%ae|%ad" \
         "--pretty=format:%ai|%aI|%as|%at|%ar|%cd|%cD|%ct" \
         "--pretty=tformat:%h%x09%s"; do
  nlog=$((nlog+1))
  a=$(git -C "$REFREPO" log -$LOGN $NOMAILMAP $f 2>&1 | md5sum)
  b=$("$GITTLE" -C "$REFREPO" log -$LOGN $f 2>&1 | md5sum)
  [ "$a" = "$b" ] || { log_ok=0; echo "  log $f differs"; }
done
# Formats containing a space have to be passed as one argument, so they are
# checked outside the loop rather than fought with through word splitting.
for f in "--date=format:%Y/%m/%d %H:%M:%S %a %b" "--format=%h %t %p" \
         "--format=%ai %aI %as %at %ar" "--format=%an <%ae> %ad%n%s"; do
  nlog=$((nlog+1))
  a=$(git -C "$REFREPO" log -$LOGN $NOMAILMAP "$f" | md5sum)
  b=$("$GITTLE" -C "$REFREPO" log -$LOGN "$f" | md5sum)
  [ "$a" = "$b" ] || { log_ok=0; echo "  log '$f' differs"; }
done
[ $log_ok = 1 ] && { ok; report "log formats" "$nlog vocabularies over $LOGN commits"; } \
                || bad "log formats"

# Path limiting is history simplification, not a filter: a commit whose tree is
# unchanged under the pathspec is skipped and only that parent is followed.
path_ok=1; npath=0
for p in Makefile diff.c Documentation t/t0000-basic.sh compat builtin/log.c \
         contrib po "*.h" "Documentation/git-log.adoc"; do
  npath=$((npath+1))
  a=$(git -C "$REFREPO" log --oneline -60 $NOMAILMAP -- "$p")
  b=$("$GITTLE" -C "$REFREPO" log --oneline -60 -- "$p")
  [ "$a" = "$b" ] || { path_ok=0; echo "  log -- $p differs"; }
done
# Without `--`, and from a subdirectory.
npath=$((npath+1))
[ "$(git -C "$REFREPO" log --oneline -30 $NOMAILMAP Makefile)" \
= "$("$GITTLE" -C "$REFREPO" log --oneline -30 Makefile)" ] \
  || { path_ok=0; echo "  bare path argument differs"; }
npath=$((npath+1))
[ "$(cd "$REFREPO/Documentation" && git log --oneline -30 $NOMAILMAP -- git-log.adoc)" \
= "$(cd "$REFREPO/Documentation" && "$GITTLE" log --oneline -30 -- git-log.adoc)" ] \
  || { path_ok=0; echo "  path limiting from a subdirectory differs"; }
[ $path_ok = 1 ] && { ok; report "log path limiting" "$npath pathspecs, simplification included"; } \
                 || bad "log path limiting"

# Options that are out of scope must refuse by name rather than be ignored --
# a `log` that silently dropped `--grep` would answer a different question and
# look like it had answered.
# `-p`, `--stat`, `--grep` and `--author` came off this list at phase 5, and
# the whole revision-walking group at phase 6; what is left is cut outright.
def_ok=1
ndef=0
for o in --graph --follow --full-diff --min-parents=1 --max-parents=1 \
         --ancestry-path --cherry-pick --boundary --simplify-merges --objects \
         --walk-reflogs --children --source \
         -M -C --patience --histogram --word-diff --summary; do
  ndef=$((ndef+1))
  "$GITTLE" -C "$REFREPO" log -1 "$o" >/dev/null 2>&1 && { def_ok=0; echo "  $o was accepted"; }
done
[ $def_ok = 1 ] && { ok; report "log deferrals" "$ndef out-of-scope options refuse by name"; } \
               || bad "log deferrals"

# --------------------------------------------------------------------- show
show_ok=1; nshow=0
for f in "" "--oneline" "--pretty=raw" "--pretty=fuller" "--format=%H%n%s"; do
  nshow=$((nshow+1))
  a=$(git -C "$REFREPO" show -s $NOMAILMAP $f HEAD 2>&1)
  b=$("$GITTLE" -C "$REFREPO" show -s $f HEAD 2>&1)
  [ "$a" = "$b" ] || { show_ok=0; echo "  show $f differs"; }
done
# Every tag in the reference repository: annotated, signed, nested, and one
# that points at a blob.
ntag=0; TAGS=$(git -C "$REFREPO" tag)
[ $FULL = 1 ] || TAGS=$(printf '%s\n' "$TAGS" | head -40)
for t in $TAGS; do
  ntag=$((ntag+1))
  a=$(git -C "$REFREPO" show -s $NOMAILMAP "$t" 2>&1)
  b=$("$GITTLE" -C "$REFREPO" show -s "$t" 2>&1)
  [ "$a" = "$b" ] || { show_ok=0; echo "  show $t differs"; }
done
# A tree lists names with a trailing slash on directories; a blob is raw bytes.
TREE=$(git -C "$REFREPO" rev-parse "HEAD^{tree}")
BLOB=$(git -C "$REFREPO" rev-parse "HEAD:README.md")
nshow=$((nshow+2))
diff <(git -C "$REFREPO" show "$TREE") <("$GITTLE" -C "$REFREPO" show "$TREE") >/dev/null \
  || { show_ok=0; echo "  show <tree> differs"; }
diff <(git -C "$REFREPO" show "$BLOB") <("$GITTLE" -C "$REFREPO" show "$BLOB") >/dev/null \
  || { show_ok=0; echo "  show <blob> differs"; }
[ $show_ok = 1 ] && { ok; report "show" "$nshow objects and $ntag tags"; } || bad "show"

# ===========================================================================
# Phase 5 -- diff, status and grep
# ===========================================================================
#
# Three divergences are deliberate (phase-5.md) and each is tested by pointing
# git at the option that selects the matching behavior, rather than left
# untested:
#
#   --no-renames        gittle never detects a rename (plan.md §4)
#   --minimal           gittle's Myers is always minimal; git's is not
#   --diff-merges=off   combined merge diffs are cut (docs/03)
#
NOREN="--no-renames --minimal"
NOCC="--diff-merges=off"
# The reference repository's own .gitattributes sets `*.[ch] diff=cpp` (and
# perl and python), and a userdiff driver replaces the rule that picks the
# name on a `@@` line: the cpp pattern rejects jump targets, so git says
# `static int f(...)` where gittle -- which has no gitattributes, decision 6
# -- says `out:`.  Overriding each driver's xfuncname with git's own built-in
# default is what makes the two comparable.
NOATTR="-c diff.cpp.xfuncname=^[A-Za-z_$].*$ -c diff.perl.xfuncname=^[A-Za-z_$].*$ -c diff.python.xfuncname=^[A-Za-z_$].*$"

# ------------------------------------------------- the diff engine, alone
# Every file pair of real commits through both engines, with git's four header
# lines stripped.  Comparing *pairs* rather than commits is what makes a
# failure point at the file (phase-5.md, "The oracle procedure").
if [ -x "$SELF" ]; then
  PAIRN=120
  [ $FULL = 1 ] && PAIRN=900
  eng_ok=1; npair=0
  for c in $(git -C "$REFREPO" rev-list --no-merges -n $PAIRN HEAD); do
    for f in $(git -C "$REFREPO" diff-tree -r --no-renames --name-only "$c^" "$c"); do
      git -C "$REFREPO" cat-file blob "$c^:$f" > "$WORK/p5.a" 2>/dev/null || continue
      git -C "$REFREPO" cat-file blob "$c:$f"  > "$WORK/p5.b" 2>/dev/null || continue
      npair=$((npair+1))
      case $((npair % 7)) in
        0) fl="";;  1) fl="-U0";; 2) fl="-U10";; 3) fl="-w";;
        4) fl="-b";; 5) fl="--ignore-space-at-eol";; 6) fl="-U1";;
      esac
      git diff --no-index --minimal --no-color $fl -- "$WORK/p5.a" "$WORK/p5.b" \
        | tail -n +5 > "$WORK/p5.pg"
      "$SELF" diff $fl "$WORK/p5.a" "$WORK/p5.b" > "$WORK/p5.pt"
      cmp -s "$WORK/p5.pg" "$WORK/p5.pt" || { eng_ok=0; echo "  $c $f [$fl] differs"; }
    done
  done
  [ $eng_ok = 1 ] && { ok; report "diff engine" "$npair file pairs, hunk for hunk"; } \
                  || bad "diff engine"
else
  report "diff engine" "skipped (no nim)"
fi

# ------------------------------------------------------------------- diff
# A repository in a state that has one of everything: a modification, a
# deletion, a creation, a staged file, a type change and a mode change.
DR="$WORK/diffrepo"
git init -q "$DR"
( cd "$DR" && printf 'one\ntwo\nthree\n' > a.txt && printf 'x\n' > b.txt \
  && mkdir sub && printf 'deep\n' > sub/c.txt && ln -s a.txt l \
  && printf 'bin\000ary\n' > bin.dat \
  && git add -A && git commit -qm one )
( cd "$DR" && printf 'one\nTWO\nthree\nfour\n' > a.txt && rm b.txt \
  && printf 'new\n' > d.txt && git add d.txt && rm l && printf 'nolink\n' > l \
  && chmod +x sub/c.txt )

diff_ok=1; ndiff=0
for f in "" "--raw" "--stat" "--numstat" "--shortstat" "--name-only" \
         "--name-status" "--cached" "--cached --raw" "--cached --stat" \
         "HEAD" "HEAD --raw" "HEAD --stat" "HEAD --name-status" \
         "-U0" "-U1" "-U10" "-R" "-R --raw" "--full-index" "--no-prefix" \
         "--abbrev=12" "--abbrev=12 --raw" "-w" "-b" "--ignore-space-at-eol" \
         "--ignore-cr-at-eol" "-a" "--diff-filter=D" "--diff-filter=A" \
         "--diff-filter=M" "--diff-filter=T" "-S four" "-S nothing" \
         "--stat -p" "--numstat --name-only" "--name-only --numstat" \
         "--raw --name-only" "--raw --name-status" "--color" "-s" \
         "-s -p" "-p -s" "-s --stat" "--stat -s" "-s --raw" "--raw -s" \
         "-- a.txt" "-- sub" "HEAD -- a.txt" "--cached -- d.txt"; do
  ndiff=$((ndiff+1))
  ( cd "$DR" && git diff $NOREN $f ) > "$WORK/p5.dg" 2>&1
  ( cd "$DR" && "$GITTLE" diff $f ) > "$WORK/p5.dt" 2>&1
  cmp -s "$WORK/p5.dg" "$WORK/p5.dt" || { diff_ok=0; echo "  diff $f differs"; }
done
# -z is compared as bytes; the shell cannot hold a NUL in a variable.
for f in "-z --raw" "-z --name-only" "-z --name-status" "-z --numstat"; do
  ndiff=$((ndiff+1))
  ( cd "$DR" && git diff $NOREN $f ) > "$WORK/p5.dg" 2>&1
  ( cd "$DR" && "$GITTLE" diff $f ) > "$WORK/p5.dt" 2>&1
  cmp -s "$WORK/p5.dg" "$WORK/p5.dt" || { diff_ok=0; echo "  diff $f differs"; }
done
# Two trees, and the exit status --exit-code reports.
ndiff=$((ndiff+1))
diff <(git -C "$REFREPO" $NOATTR diff $NOREN HEAD~1 HEAD --stat 2>&1) \
     <("$GITTLE" -C "$REFREPO" diff "$(git -C "$REFREPO" rev-parse HEAD~1)" HEAD --stat 2>&1) \
  >/dev/null || { diff_ok=0; echo "  diff <tree> <tree> --stat differs"; }
( cd "$DR" && git diff --quiet ); a=$?
( cd "$DR" && "$GITTLE" diff --quiet ); b=$?
ndiff=$((ndiff+1))
[ "$a" = "$b" ] && [ "$a" = 1 ] || { diff_ok=0; echo "  --quiet exit status $a vs $b"; }
( cd "$DR" && git diff --quiet -- nosuchfile ); a=$?
( cd "$DR" && "$GITTLE" diff --quiet -- nosuchfile ); b=$?
ndiff=$((ndiff+1))
[ "$a" = "$b" ] && [ "$a" = 0 ] || { diff_ok=0; echo "  --quiet clean exit status $a vs $b"; }
# `-s` is an assignment in git, not a suppression, so it is order-sensitive
# against every other format -- and it is a hard error with the name formats.
( cd "$DR" && git diff -s --name-only ) >/dev/null 2>&1; a=$?
( cd "$DR" && "$GITTLE" diff -s --name-only ) >/dev/null 2>&1; b=$?
ndiff=$((ndiff+1))
{ [ "$a" != 0 ] && [ "$b" != 0 ]; } \
  || { diff_ok=0; echo "  -s --name-only should be refused ($a/$b)"; }
# --no-index needs no repository at all.
ndiff=$((ndiff+1))
printf 'p\nq\n' > "$WORK/p5.n1"; printf 'p\nr\n' > "$WORK/p5.n2"
diff <(git diff --no-index --minimal "$WORK/p5.n1" "$WORK/p5.n2" 2>&1) \
     <("$GITTLE" diff --no-index "$WORK/p5.n1" "$WORK/p5.n2" 2>&1) >/dev/null \
  || { diff_ok=0; echo "  diff --no-index differs"; }
[ $diff_ok = 1 ] && { ok; report "diff" "$ndiff option and invocation forms"; } \
                 || bad "diff"

# --------------------------------------------- log and show, with the diff
LOGD=60
[ $FULL = 1 ] && LOGD=400
ld_ok=1; nld=0
for f in "-p" "--stat" "--numstat" "--shortstat" "--raw" "--name-only" \
         "--name-status" "-p --stat" "-p --oneline" "--stat --oneline" \
         "-p --format=%s" "-p --format=format:%s" "-p -U1" "-p -w" \
         "-p --full-index" "--stat --format=full" "--numstat -z" \
         "-p --abbrev=12"; do
  nld=$((nld+1))
  a=$(git -C "$REFREPO" $NOATTR log $NOMAILMAP $NOREN -n$LOGD $f 2>&1 | md5sum)
  b=$("$GITTLE" -C "$REFREPO" log -n$LOGD $f 2>&1 | md5sum)
  [ "$a" = "$b" ] || { ld_ok=0; echo "  log $f differs"; }
done
# show: a commit, a merge, a root commit, a tag and a tag of a tag.
SHOWOBJ="HEAD $(git -C "$REFREPO" rev-parse HEAD~3) \
         $(git -C "$REFREPO" rev-list --max-parents=0 HEAD | tail -1) \
         v2.50.0 v1.0rc1"
for f in "" "-s" "--stat" "--numstat" "-p --stat" "--oneline" "--name-status" \
         "--raw" "-U1" "--shortstat" "--name-only" "--format=raw" \
         "--format=full" "--format=fuller" "--format=%s"; do
  for obj in $SHOWOBJ; do
    nld=$((nld+1))
    a=$(git -C "$REFREPO" $NOATTR show $NOMAILMAP $NOREN $NOCC $f $obj 2>&1 | md5sum)
    b=$("$GITTLE" -C "$REFREPO" show $f $obj 2>&1 | md5sum)
    [ "$a" = "$b" ] || { ld_ok=0; echo "  show $f $obj differs"; }
  done
done
[ $ld_ok = 1 ] && { ok; report "log and show diffs" "$nld format combinations"; } \
               || bad "log and show diffs"

# --------------------------------------------- log's limiting patterns
# --grep, --author and --committer, and how they combine.  Measured against
# git rather than read off the manual: different kinds AND, repeats of one
# kind OR, and --all-match turns the message group into an AND too.
lim_ok=1; nlim=0
LIMN=3000
[ $FULL = 1 ] && LIMN=20000
for f in "--grep=pack" "--grep=pack --grep=ref" "--grep=pack --grep=ref --all-match" \
         "--grep=pack --invert-grep" "--author=Junio" "--committer=Junio" \
         "--author=Junio --grep=pack" "--author=Junio --committer=Taylor" \
         "--grep=PACK -i" "--grep=pack -F" "--grep=p.ck" "--author=gitster@pobox.com"; do
  nlim=$((nlim+1))
  a=$(git -C "$REFREPO" log $NOMAILMAP -n$LIMN --format=%H -E $f 2>&1 | md5sum)
  b=$("$GITTLE" -C "$REFREPO" log -n$LIMN --format=%H $f 2>&1 | md5sum)
  [ "$a" = "$b" ] || { lim_ok=0; echo "  log $f differs"; }
done
[ $lim_ok = 1 ] && { ok; report "log --grep/--author" "$nlim pattern combinations"; } \
                || bad "log --grep/--author"

# ----------------------------------------------------------------- status
# Swept over repository *states*, not only over options: the four formats are
# cheap to enumerate, and what is hard to get right is the state they describe.
SR="$WORK/statusrepo"
git init -q "$SR"
st_ok=1; nst=0
status_all() {  # status_all <label>
  for f in "" "-s" "-s -b" "--porcelain" "--porcelain=v2" "--porcelain=v2 -b" \
           "-uall" "-uno" "-s -uall" "-s -uno" "--long -uno" "-b" \
           "-z" "--porcelain=v2 -z" "-s -- sub" "-- a.txt"; do
    nst=$((nst+1))
    ( cd "$SR" && git status $f ) > "$WORK/p5.sg" 2>&1
    ( cd "$SR" && "$GITTLE" status $f ) > "$WORK/p5.st" 2>&1
    cmp -s "$WORK/p5.sg" "$WORK/p5.st" || { st_ok=0; echo "  [$1] status $f differs"; }
  done
}
status_all "empty repository"
( cd "$SR" && printf 'a\n' > a.txt && mkdir -p sub/deep && printf 'c\n' > sub/deep/c.txt )
status_all "untracked, no commit"
( cd "$SR" && git add -A )
status_all "staged, no commit"
( cd "$SR" && git commit -qm one )
status_all "clean"
( cd "$SR" && printf 'A\n' > a.txt )
status_all "unstaged"
( cd "$SR" && git add a.txt )
status_all "staged"
( cd "$SR" && printf 'AA\n' > a.txt )
status_all "staged and edited again"
( cd "$SR" && rm sub/deep/c.txt && printf 'u\n' > u.txt && mkdir new && printf 'n\n' > new/n.txt )
status_all "deleted and untracked"
( cd "$SR" && ln -sf a.txt link && git add link && rm link && printf 'notalink\n' > link )
status_all "type change"
( cd "$SR" && chmod +x a.txt )
status_all "mode change"
( cd "$SR" && printf '*.log\n' > .gitignore && printf 'x\n' > q.log )
status_all "ignore rules"
[ $st_ok = 1 ] && { ok; report "status" "$nst combinations over 11 states"; } \
               || bad "status"

# ...and once over the reference repository itself, which the constructed
# states cannot stand in for: it has two nested repositories, a real submodule
# gitlink, and a configured upstream.  The three upstream forms are filtered
# out on git's side -- they need a remote (phase 8) and a range count
# (phase 6) -- and everything else must agree byte for byte.
ref_ok=1
# The upstream report used to be filtered out of this comparison, because
# phase 5 had neither a range count nor a remote-tracking ref and printed
# none of it.  Phase 6 has both, so it is compared like everything else.
diff <(git -C "$REFREPO" status) <("$GITTLE" -C "$REFREPO" status) >/dev/null \
  || { ref_ok=0; echo "  status --long on the reference repository differs"; }
diff <(git -C "$REFREPO" status -s) <("$GITTLE" -C "$REFREPO" status -s) >/dev/null \
  || { ref_ok=0; echo "  status -s on the reference repository differs"; }
diff <(git -C "$REFREPO" status -s -uall) <("$GITTLE" -C "$REFREPO" status -s -uall) >/dev/null \
  || { ref_ok=0; echo "  status -s -uall on the reference repository differs"; }
diff <(git -C "$REFREPO" status --porcelain=v2 -b) \
     <("$GITTLE" -C "$REFREPO" status --porcelain=v2 -b) >/dev/null \
  || { ref_ok=0; echo "  status --porcelain=v2 on the reference repository differs"; }
# A nested repository is one untracked directory, and a gitlink is not a
# change -- both are easy to get wrong and neither appears in a fresh repo.
diff <(git -C "$REFREPO" ls-files -o --exclude-standard) \
     <("$GITTLE" -C "$REFREPO" ls-files -o --exclude-standard) >/dev/null \
  || { ref_ok=0; echo "  ls-files -o on the reference repository differs"; }
diff <(git -C "$REFREPO" diff --raw) <("$GITTLE" -C "$REFREPO" diff --raw) >/dev/null \
  || { ref_ok=0; echo "  diff --raw on the reference repository differs"; }
[ $ref_ok = 1 ] && { ok; report "status, real repository" "nested repos, a gitlink, an upstream reported"; } \
                || bad "status, real repository"

# ------------------------------------------- from inside a subdirectory
# Every command that prints a path has to decide *which* path, and they do not
# all decide the same way: a patch is always root-relative because it has to
# apply from the root, `status` and `grep` are relative to where you stood,
# and porcelain v1 alone is root-relative whatever the format around it does.
# None of that is exercised from a repository root, which is where every other
# sweep in this file runs.
SUB="$WORK/subrepo"
git init -q "$SUB"
( cd "$SUB" && mkdir -p sub/deep && printf 'a\n' > top.txt \
  && printf 'b\n' > sub/s.txt && printf 'c\n' > sub/deep/d.txt \
  && git add -A && git commit -qm one \
  && printf 'A\n' > top.txt && printf 'B\n' > sub/s.txt \
  && printf 'D\n' > sub/deep/d.txt && printf 'new\n' > sub/untracked.txt )
sub_ok=1; nsub=0
for f in "" "-s" "-s -b" "--porcelain" "--porcelain=v2" "--porcelain=v2 -b" \
         "-uall" "-uno" "-z" "-b"; do
  nsub=$((nsub+1))
  ( cd "$SUB/sub" && git status $f ) > "$WORK/p5.sg" 2>&1
  ( cd "$SUB/sub" && "$GITTLE" status $f ) > "$WORK/p5.st" 2>&1
  cmp -s "$WORK/p5.sg" "$WORK/p5.st" \
    || { sub_ok=0; echo "  status $f from a subdirectory differs"; }
done
for f in "--stat" "--name-only" "--raw" "" "--stat -- deep"; do
  nsub=$((nsub+1))
  ( cd "$SUB/sub" && git diff $NOREN $f ) > "$WORK/p5.dg" 2>&1
  ( cd "$SUB/sub" && "$GITTLE" diff $f ) > "$WORK/p5.dt" 2>&1
  cmp -s "$WORK/p5.dg" "$WORK/p5.dt" \
    || { sub_ok=0; echo "  diff $f from a subdirectory differs"; }
done
for f in "-n -E b" "-n -E b HEAD" "-l -E b" "-c -E b"; do
  nsub=$((nsub+1))
  ( cd "$SUB/sub" && git grep $f ) > "$WORK/p5.gg" 2>&1
  ( cd "$SUB/sub" && "$GITTLE" grep $f ) > "$WORK/p5.gt" 2>&1
  cmp -s "$WORK/p5.gg" "$WORK/p5.gt" \
    || { sub_ok=0; echo "  grep $f from a subdirectory differs"; }
done
# status.relativePaths turns the whole thing off.
nsub=$((nsub+1))
( cd "$SUB/sub" && git -c status.relativePaths=false status -s ) > "$WORK/p5.sg" 2>&1
( cd "$SUB/sub" && "$GITTLE" -c status.relativePaths=false status -s ) > "$WORK/p5.st" 2>&1
cmp -s "$WORK/p5.sg" "$WORK/p5.st" \
  || { sub_ok=0; echo "  status.relativePaths=false differs"; }
[ $sub_ok = 1 ] && { ok; report "from a subdirectory" "$nsub status, diff and grep forms"; } \
                || bad "from a subdirectory"

# ------------------------------------------------- commit's summary output
# The diffstat and the create/delete/mode-change lines, plus the whole of
# `status` on "nothing to commit".  Compared by driving both tools through the
# same script and diffing everything they said.
commit_run() {  # commit_run <dir> <tool>
  # Everything runs in a subshell that exits if the `cd` fails.  Without that,
  # a failed `git init` leaves the body running in *this* repository, where it
  # would `add -A` and `commit` the project itself -- which is exactly what
  # happened once while this file was being written.
  rm -rf "$1"; git init -q "$1" || return 1
  (
    cd "$1" || exit 1
    printf 'a\n' > a.txt; mkdir sub; printf 'c\n' > sub/c.txt; ln -s a.txt l
    $2 add -A > /dev/null; $2 commit -m one
    printf 'A\nB\n' > a.txt; rm sub/c.txt; printf 'n\n' > n.txt; chmod +x a.txt
    $2 add -A > /dev/null; $2 commit -m two
    $2 commit -m three; echo "rc=$?"
    printf 'z\n' > z.txt; $2 add z.txt > /dev/null; $2 commit -q -m four; echo "rc=$?"
    printf 'zz\n' > z.txt; $2 add z.txt > /dev/null; $2 commit --amend -m four2
  )
}
commit_run "$WORK/cg" "git"      > "$WORK/cg.out" 2>&1
commit_run "$WORK/ct" "$GITTLE"  > "$WORK/ct.out" 2>&1
if diff <(sed "s#$WORK/cg#REPO#g" "$WORK/cg.out") \
        <(sed "s#$WORK/ct#REPO#g" "$WORK/ct.out") >/dev/null; then
  ok; report "commit summary" "diffstat, create/delete/mode lines, and status"
else
  bad "commit summary"
  diff <(sed "s#$WORK/cg#REPO#g" "$WORK/cg.out") \
       <(sed "s#$WORK/ct#REPO#g" "$WORK/ct.out") | head -12
fi

# ------------------------------------------------------------------- grep
# Over the whole reference repository, which is the only corpus large enough
# to contain the awkward cases: binary files, empty files, gitlinks, symlinks.
# `-E` throughout, because git's default is BRE and gittle's patterns are ERE
# always -- a divergence docs/07 chose and phase-5.md records.
grep_ok=1; ngrep=0
GREPPAT="static xdl_ TODO the Signed-off-by"
[ $FULL = 1 ] && GREPPAT="$GREPPAT ^int [a-z]+_oid struct"
for pat in $GREPPAT; do
  for f in "-n" "-l" "-c" "" "-i -n" "-w -n" "-C1 -n" "-L" "-A1 -n" "-B2 -n" \
           "-v -l" "-v -c" "-h -n" "--cached -n"; do
    ngrep=$((ngrep+1))
    git -C "$REFREPO" grep -E $f -e "$pat" > "$WORK/p5.gg" 2>&1; ga=$?
    "$GITTLE" -C "$REFREPO" grep -E $f -e "$pat" > "$WORK/p5.gt" 2>&1; gb=$?
    { cmp -s "$WORK/p5.gg" "$WORK/p5.gt" && [ "$ga" = "$gb" ]; } \
      || { grep_ok=0; echo "  grep $f -e '$pat' differs (rc $ga/$gb)"; }
  done
done
# A tree search prefixes every path with the name it was asked by, and -z, -q
# and --color have shapes of their own.
for f in "-n alpha HEAD" "-n -z static" "-l -z static" "--color -n static" \
         "-c -z static" "-n static HEAD" "-2 static"; do
  ngrep=$((ngrep+1))
  git -C "$REFREPO" grep -E $f > "$WORK/p5.gg" 2>&1; ga=$?
  "$GITTLE" -C "$REFREPO" grep -E $f > "$WORK/p5.gt" 2>&1; gb=$?
  { cmp -s "$WORK/p5.gg" "$WORK/p5.gt" && [ "$ga" = "$gb" ]; } \
    || { grep_ok=0; echo "  grep $f differs (rc $ga/$gb)"; }
done
git -C "$REFREPO" grep -q static; ga=$?
"$GITTLE" -C "$REFREPO" grep -q static; gb=$?
ngrep=$((ngrep+1))
[ "$ga" = "$gb" ] || { grep_ok=0; echo "  grep -q exit status $ga/$gb"; }
git -C "$REFREPO" grep -q zzzznomatch; ga=$?
"$GITTLE" -C "$REFREPO" grep -q zzzznomatch; gb=$?
ngrep=$((ngrep+1))
[ "$ga" = "$gb" ] || { grep_ok=0; echo "  grep -q no-match exit status $ga/$gb"; }
[ $grep_ok = 1 ] && { ok; report "grep" "$ngrep combinations over the reference repository"; } \
                 || bad "grep"

# ------------------------------------------- the ERE engine's own agreement
# The patterns plan.md §6.4 nominated as the places two regex flavors are
# most likely to disagree, including the malformed ones -- whose error text
# comes out identical because both tools call the same libc `regerror`.
re_ok=1; nre=0
RD="$WORK/reredir"; mkdir -p "$RD"
printf 'a+b\naab\nab\nxx\n(x)\nx\nalpha123\naaa\naa\nfoo)bar\nfoo\nbar\n\nlast\n' \
  > "$RD/subj.txt"
( cd "$RD" && git init -q . && git add subj.txt )
for pat in 'a+b' 'a?' '\(x\)' '[[:alpha:]]+' 'a{2,3}' ')' 'a|' '(|x)b' '^ab$' \
           'b$' '^' '$' 'x*' '[a-' 'a**' '(a' 'foo|bar' '\.' '[^a]' 'A+B'; do
  nre=$((nre+1))
  ( cd "$RD" && git grep -n -E -e "$pat" -- subj.txt ) > "$WORK/p5.rg" 2>&1
  ( cd "$RD" && "$GITTLE" grep -n -E -e "$pat" -- subj.txt ) > "$WORK/p5.rt" 2>&1
  # git prefixes a compile error with "fatal: -e option, '<pat>': " and gittle
  # with its own wording; the libc message after it must match exactly.
  sed -i -e "s/^fatal: -e option, '.*': //" -e "s/^gittle: invalid regular expression '.*': //" \
      "$WORK/p5.rg" "$WORK/p5.rt"
  cmp -s "$WORK/p5.rg" "$WORK/p5.rt" || { re_ok=0; echo "  pattern '$pat' differs"; }
done
[ $re_ok = 1 ] && { ok; report "ERE engine" "$nre patterns, errors included"; } \
               || bad "ERE engine"


# =========================================================================
# Phase 6 -- history
# =========================================================================
#
# Two shapes of check, and the difference matters.  Read-only commands are
# compared on stdout, stderr and exit status.  Commands that *change* a
# repository are run twice, in two identical copies, and every byte either
# tool could have written is compared afterwards: refs, HEAD, config, every
# reflog, every working-tree file and the index.  A checkout that prints the
# right thing and leaves the wrong index is the failure worth catching.

P6="$WORK/p6"; mkdir -p "$P6"

# gittle names itself where git names itself; that is a deliberate difference
# and not one to test.
p6norm(){ sed -e 's/^fatal: //' -e 's/^gittle: //' -e "s/'git /'gittle /" \
              -e 's/^  git /  gittle /' -e 's/"git /"gittle /g' \
              -e 's/known to git$/known to gittle/'; }

# p6ro <expected-name> <args...> -- a read-only command, both tools, one repo.
p6dir=""
p6ro(){
  local ao as ae bo bs be
  ao=$( cd "$p6dir" && git "$@" 2>"$WORK/p6.ea" ); as=$?
  ae=$(p6norm < "$WORK/p6.ea")
  bo=$( cd "$p6dir" && "$GITTLE" "$@" 2>"$WORK/p6.eb" ); bs=$?
  be=$(p6norm < "$WORK/p6.eb")
  p6n=$((p6n+1))
  if [ "$ao" != "$bo" ] || [ "$as" != "$bs" ] || [ "$ae" != "$be" ]; then
    p6ok=0
    printf '  %s %s  [git %d / gittle %d]\n' "${p6what:-}" "$*" "$as" "$bs"
    diff <(printf '%s\n' "$ao") <(printf '%s\n' "$bo") | head -4
    [ "$ae" = "$be" ] || printf '    err: %s | %s\n' "$ae" "$be"
  fi
}

# Everything a command could have written, as text.
p6state(){
  ( cd "$1" || return
    git for-each-ref --format='%(refname) %(objectname) %(symref)'
    git symbolic-ref -q HEAD || git rev-parse HEAD
    sed -e 's/[ \t]*$//' .git/config
    ( cd .git/logs 2>/dev/null && find . -type f | sort |
      while read -r f; do echo "== $f"; cat "$f"; done )
    # `-type f` alone would follow a symlink and hash what it points at, and
    # a checkout that wrote a regular file instead of a link would pass.
    find . -path ./.git -prune -o \( -type f -o -type l \) -print | sort |
      while read -r f; do
        if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"
        else printf '%s %s %s\n' "$f" \
             "$(sha1sum <"$f" | cut -d' ' -f1)" "$([ -x "$f" ] && echo x || echo -)"
        fi
      done
    git ls-files -s )
}

# p6mut <args...> -- a mutating command, run in two copies of $P6/fix.
# $PREP, if set, is run in each copy first to build a dirty starting state.
p6mut(){
  local ao as bo bs sa sb this
  rm -rf "$P6/a" "$P6/b"; cp -a "$P6/fix" "$P6/a"; cp -a "$P6/fix" "$P6/b"
  ( cd "$P6/a" && eval "${PREP:-true}" ) >/dev/null 2>&1
  ( cd "$P6/b" && eval "${PREP:-true}" ) >/dev/null 2>&1
  ao=$( cd "$P6/a" && git "$@" 2>&1 ); as=$?
  bo=$( cd "$P6/b" && "$GITTLE" "$@" 2>&1 ); bs=$?
  p6n=$((p6n+1)); this=1
  # The two copies live at different paths, and a message that names the
  # working tree would differ for that reason alone.
  [ "$(printf '%s\n' "$ao" | p6norm | sed "s|$P6/[ab]|REPO|g")" \
  = "$(printf '%s\n' "$bo" | p6norm | sed "s|$P6/[ab]|REPO|g")" ] || this=0
  [ "$as" = "$bs" ] || this=0
  sa=$(p6state "$P6/a"); sb=$(p6state "$P6/b")
  [ "$sa" = "$sb" ] || this=0
  if [ $this = 0 ]; then
    p6ok=0
    printf '  %s%s  [git %d / gittle %d]\n' \
      "${PREP:+($PREP) }" "$*" "$as" "$bs"
    diff <(printf '%s\n' "$ao" | p6norm) <(printf '%s\n' "$bo" | p6norm) | head -5
    diff <(printf '%s\n' "$sa") <(printf '%s\n' "$sb") | head -6
  fi
}

# ------------------------------------------------------------ the fixture
# Small, but with one of everything the phase touches: a merge, a side
# branch, an annotated tag and a lightweight one, a subdirectory, a
# remote-tracking ref and a configured upstream.
#
# And an executable and a symlink, on the side branch only, so that switching
# has to create and remove both.  A checkout that writes a symlink's target as
# a regular file looks right in every listing that prints a name.
rm -rf "$P6/fix"; mkdir -p "$P6/fix"
( cd "$P6/fix"
  git init -q -b main .
  echo a > a.txt; mkdir -p sub; echo s > sub/s.txt
  git add .; git commit -qm one
  echo b >> a.txt; git commit -qam two
  git tag -a v1 -m "tag one"
  git tag light HEAD~1
  git checkout -qb side HEAD~1
  echo c > c.txt
  printf '#!/bin/sh\necho hi\n' > run.sh; chmod +x run.sh
  ln -s a.txt link
  git add c.txt run.sh link; git commit -qm three
  git checkout -q main
  git merge -q --no-ff side -m merge
  git branch stale HEAD~1
  git update-ref refs/remotes/origin/main main
  git config remote.origin.url .
  git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git config branch.main.remote origin
  git config branch.main.merge refs/heads/main ) >/dev/null 2>&1

# ---------------------------------------------------- the revision grammar
# Every suffix operator, every range spelling, and the forms that must *not*
# resolve -- because "HEAD^3 is an error" is as much a behavior as "HEAD^2 is
# the second parent", and only one of the two is in the manual.
p6ok=1; p6n=0; p6dir="$P6/fix"; p6what="rev-parse"
for x in HEAD HEAD^ HEAD~ HEAD~1 HEAD~2 HEAD^2 HEAD^^ 'HEAD^{}' 'HEAD^{tree}' \
         'HEAD^{commit}' 'HEAD^{object}' v1 'v1^{}' 'v1^{commit}' 'v1^{tag}' \
         'v1^{tree}' @ 'HEAD@{0}' 'HEAD@{1}' '@{-1}' ':a.txt' ':0:a.txt' \
         ':1:a.txt' 'HEAD:a.txt' 'HEAD^:a.txt' 'HEAD:sub/s.txt' 'HEAD:' \
         'HEAD:nosuch' 'main..side' 'main...side' 'side..main' 'side...main' \
         '..side' 'main..' 'v1..main' 'HEAD^!' 'HEAD^@' 'HEAD^-1' 'HEAD^-9' \
         '^main' main side light nosuch a.txt 'HEAD~0' 'HEAD^0' 'HEAD^3' \
         'HEAD~9' '@{5}' '@{-5}' 'side@{0}' 'HEAD^{tree}..HEAD' 'HEAD^!x'; do
  p6ro rev-parse "$x"
done
for f in --verify --short --symbolic-full-name --abbrev-ref; do
  p6ro rev-parse $f HEAD
done
p6ro rev-parse -q --verify nosuch;      p6ro rev-parse --verify nosuch
p6ro rev-parse --verify HEAD HEAD;      p6ro rev-parse --short=12 HEAD
p6ro rev-parse --short=2 HEAD;          p6ro rev-parse --short=99 HEAD
p6ro rev-parse --symbolic-full-name HEAD main v1
p6ro rev-parse --abbrev-ref HEAD main v1
p6ro rev-parse --abbrev-ref=strict main
p6ro rev-parse --symbolic-full-name main..side
p6ro rev-parse -- a.txt;                p6ro rev-parse HEAD a.txt
p6ro rev-parse --foo;                   p6ro rev-parse --short main..side
for f in --git-dir --show-toplevel --show-cdup --show-prefix \
         --is-inside-git-dir --is-inside-work-tree --is-bare-repository; do
  p6ro rev-parse $f
done
# From a subdirectory: `:path` is root-relative and `:./path` is not, and the
# layout queries all answer differently.
p6dir="$P6/fix/sub"
for f in --git-dir --show-toplevel --show-cdup --show-prefix \
         --is-inside-work-tree; do
  p6ro rev-parse $f
done
p6ro rev-parse ':s.txt'; p6ro rev-parse ':./s.txt'; p6ro rev-parse 'HEAD:./s.txt'
p6dir="$P6/fix"
[ $p6ok = 1 ] && { ok; report "revision grammar" "$p6n expressions and rev-parse forms"; } \
              || bad "revision grammar"

# ------------------------------------------------------------- merge-base
# Over the reference repository, because a merge base is only interesting on
# history with real criss-crosses in it.
p6ok=1; p6n=0; p6dir="$REFREPO"; p6what="merge-base"
p6ro merge-base HEAD HEAD~5
p6ro merge-base --is-ancestor HEAD~5 HEAD
p6ro merge-base --is-ancestor HEAD HEAD~5
p6ro merge-base --is-ancestor HEAD HEAD
for t in v2.10.0 v2.20.0 v2.30.0 v2.40.0; do
  p6ro merge-base HEAD $t; p6ro merge-base --all $t v2.28.0
done
p6ro merge-base --all v2.20.0 v2.35.0 v2.30.0
# Random pairs, which is the only way to reach a criss-cross on purpose.
NPAIR=40; [ $FULL = 1 ] && NPAIR=400
mapfile -t P6C < <(git -C "$REFREPO" rev-list -n 4000 HEAD |
                   shuf -n $NPAIR --random-source=<(yes))
for ((i = 0; i + 1 < ${#P6C[@]}; i += 2)); do
  p6ro merge-base --all "${P6C[$i]}" "${P6C[$((i+1))]}"
done
[ $p6ok = 1 ] && { ok; report "merge-base" "$p6n forms, $((NPAIR/2)) random commit pairs"; } \
              || bad "merge-base"

# --------------------------------------------------------------- rev-list
# The whole of docs/04 against real history: the orderings especially, since
# `--topo-order` is a *choice* among valid topological orders and agreeing
# with git means reproducing the choice.
p6ok=1; p6n=0; p6dir="$REFREPO"; p6what="rev-list"
RN=200; [ $FULL = 1 ] && RN=4000
for a in "-n $RN HEAD" "-n $RN --topo-order HEAD" "-n $RN --date-order HEAD" \
         "-n $RN --first-parent HEAD" "-n $RN --merges HEAD" \
         "-n $RN --no-merges HEAD" "-n 50 --parents HEAD" \
         "-n 50 --parents --abbrev-commit HEAD" "HEAD~50..HEAD" \
         "HEAD~50...HEAD~20" "--left-right HEAD~50...HEAD~20" \
         "-n 100 --reverse HEAD" "--no-walk HEAD HEAD~5 HEAD~2" \
         "--no-walk=unsorted HEAD HEAD~5 HEAD~2" "-n 100 HEAD -- Makefile" \
         "-n 100 --parents HEAD -- Makefile" "-n 30 --topo-order HEAD -- diff.c" \
         "-n 30 --date-order HEAD -- diff.c" \
         "-n 30 --topo-order --parents HEAD -- diff.c" "-n 20 --skip=5 HEAD" \
         "HEAD~3^!" "HEAD~3^@" "-n 5 --oneline HEAD" "-n 3 --pretty=medium HEAD" \
         "-n 3 --pretty=raw HEAD" "-n 3 --pretty=fuller HEAD" \
         "-n 3 --pretty=oneline HEAD" "-n 5 --format=%h HEAD" \
         "-n 5 --format=%h --abbrev-commit HEAD" "--count v2.30.0..v2.31.0" \
         "--left-right --count v2.30.0...v2.31.0" \
         "-n 200 --since=2024-01-01 HEAD" "-n 200 --until=2020-01-01 HEAD" \
         "-n 60 --topo-order HEAD -- t/" "--count --all"; do
  p6ro rev-list $a
done
# `--objects` is the question a fetch asks, so both halves of a range matter.
p6dir="$P6/fix"
for a in "--objects HEAD" "--objects --all" "--objects main ^side" \
         "--objects side ^main" "--objects --all --not main" \
         "--objects --all --not v1" "--objects v1" "--objects --tags" \
         "--objects HEAD --not HEAD~2" "--all" "--branches" "--tags" \
         "--remotes" "--all --topo-order" "--all --date-order"; do
  p6ro rev-list $a
done
[ $p6ok = 1 ] && { ok; report "rev-list" "$p6n option forms over real history"; } \
              || bad "rev-list"

# `log` shares the same parser, so what is tested here is that it *does*.
p6ok=1; p6n=0; p6dir="$REFREPO"; p6what="log"
for a in "-n 20 --oneline --topo-order" "-n 20 --oneline --date-order" \
         "-n 20 --oneline --all" "-n 10 --oneline HEAD~30..HEAD" \
         "-n 10 --left-right HEAD~30...HEAD~10" \
         "-n 10 --oneline --left-right HEAD~30...HEAD~10" \
         "-n 10 --oneline --merges" "-n 10 --oneline --no-merges" \
         "-n 10 --oneline --since=2025-01-01" "-n 5 --parents --oneline" \
         "-n 5 --parents" "-n 20 --oneline --parents -- Makefile" \
         "--no-walk --oneline HEAD HEAD~3" "-n 8 --oneline --first-parent" \
         "-n 5 --oneline --branches" "-n 5 --oneline --tags"; do
  # git applies .mailmap by default and gittle does not; see the note at the
  # top of this file.
  ao=$(git -C "$REFREPO" log $a $NOMAILMAP 2>&1); as=$?
  bo=$("$GITTLE" -C "$REFREPO" log $a 2>&1); bs=$?
  p6n=$((p6n+1))
  { [ "$ao" = "$bo" ] && [ "$as" = "$bs" ]; } \
    || { p6ok=0; echo "  log $a differs"; diff <(echo "$ao") <(echo "$bo")|head -4; }
done
[ $p6ok = 1 ] && { ok; report "log, shared surface" "$p6n forms through the same parser"; } \
              || bad "log, shared surface"

# ---------------------------------------------------------- for-each-ref
p6ok=1; p6n=0; p6dir="$REFREPO"; p6what="for-each-ref"
for f in '%(refname)' '%(refname:short)' '%(objectname)' '%(objectname:short)' \
         '%(objectname:short=12)' '%(objecttype)' '%(subject)' '%(contents)' \
         '%(contents:subject)' '%(contents:body)' '%(contents:lines=1)' \
         '%(contents:lines=3)' '%(*objectname)' '%(HEAD)%(refname)' \
         '%(upstream) %(upstream:short)'; do
  p6ro for-each-ref --format="$f" refs/tags
done
p6ro for-each-ref refs/heads
p6ro for-each-ref 'refs/tags/v2.3*'
p6ro for-each-ref --count=5
p6ro for-each-ref --sort=objectname
p6ro for-each-ref --sort=-refname
p6ro for-each-ref --contains v2.30.0 refs/tags
p6ro for-each-ref --no-contains v2.30.0 refs/tags
p6ro for-each-ref --merged v2.31.0 refs/tags
p6ro for-each-ref --no-merged v2.31.0 refs/tags
p6ro for-each-ref --points-at HEAD
[ $p6ok = 1 ] && { ok; report "for-each-ref" "$p6n atoms and filters over 1,000 refs"; } \
              || bad "for-each-ref"

# --------------------------------------------------------------- branch
p6ok=1; p6n=0; p6dir="$P6/fix"; p6what="branch"
for a in "" "-v" "-vv" "-a" "-r" "-av" "-arv" "--show-current" "--list" \
         "--contains side" "--merged" "--no-merged" "--sort=-refname" \
         "-v --sort=objectname" "-l ma*" "-l s*"; do
  p6ro branch $a
done
p6ro branch --format='%(refname)'
p6ro branch --format='%(refname:short) %(objectname:short)'
# A detached HEAD is a row in the listing that is not a ref, and it counts
# toward the column width.
( cd "$P6/fix" && git checkout -q --detach HEAD~1 ) >/dev/null 2>&1
p6ro branch; p6ro branch -v; p6ro branch -a
( cd "$P6/fix" && git checkout -q main ) >/dev/null 2>&1
[ $p6ok = 1 ] && { ok; report "branch listing" "$p6n forms, detached HEAD included"; } \
              || bad "branch listing"

p6ok=1; p6n=0; p6what="branch"
p6mut branch newb;            p6mut branch newb HEAD~1
p6mut branch newb side;       p6mut branch newb origin/main
p6mut branch -f side HEAD~1;  p6mut branch side
p6mut branch -d stale;        p6mut branch -d side
p6mut branch -D side;         p6mut branch -d nosuch
p6mut branch -m stale renamed; p6mut branch -m main renamed
p6mut branch -M main side;    p6mut branch -m nosuch x
p6mut branch -u origin/main side
p6mut branch --set-upstream-to=origin/main
p6mut branch --unset-upstream
p6mut branch -t newb origin/main
p6mut branch --no-track newb origin/main
p6mut branch newb v1;         p6mut branch -d -r origin/main
p6mut branch -q newb;         p6mut branch -q -d stale
p6mut branch -d main;         p6mut branch -d light
[ $p6ok = 1 ] && { ok; report "branch" "$p6n creates, deletes, renames and upstreams"; } \
              || bad "branch"

# ------------------------------------------------------------------ tag
p6ok=1; p6n=0; p6dir="$P6/fix"; p6what="tag"
for a in "" "-l" "-n" "-n1" "-n2" "-n5" "--sort=-refname" "--contains HEAD~2" \
         "--merged HEAD" "--points-at HEAD~1" "-l v*" "-l l*"; do
  p6ro tag $a
done
p6ro tag --format='%(refname)'
[ $p6ok = 1 ] && { ok; report "tag listing" "$p6n forms"; } || bad "tag listing"

p6ok=1; p6n=0; p6what="tag"
p6mut tag newtag;                p6mut tag newtag HEAD~1
p6mut tag -a -m hello annot;     p6mut tag -mmsg mtag
p6mut tag -a -m one -m two two;  p6mut tag -f v1
p6mut tag -f -m new v1;          p6mut tag -d v1
p6mut tag -d light;              p6mut tag -d nosuch
p6mut tag v1;                    p6mut tag newtag v1
[ $p6ok = 1 ] && { ok; report "tag" "$p6n creates and deletes, annotated and light"; } \
              || bad "tag"

# ------------------------------------------- checkout, switch and restore
# The dangerous ones.  Every case is run against a *dirty* starting state as
# well as a clean one, because the whole safety property is what happens when
# something would be lost.
p6ok=1; p6n=0; p6what="checkout"
p6mut checkout side;             p6mut switch side
p6mut checkout main;             p6mut checkout -b topic
p6mut checkout --detach HEAD~1;  p6mut checkout v1
p6mut checkout HEAD~1;           p6mut switch -c topic2 HEAD~1
p6mut checkout -B side HEAD~1;   p6mut checkout -q side
p6mut switch -d HEAD~1;          p6mut checkout nosuch
p6mut switch v1;                 p6mut switch nosuch
PREP='echo x >> a.txt'                 p6mut checkout side
PREP='echo x >> a.txt'                 p6mut switch side
PREP='echo x >> a.txt'                 p6mut checkout -f side
PREP='echo x >> a.txt'                 p6mut restore a.txt
PREP='echo x >> a.txt'                 p6mut checkout -- a.txt
PREP='echo x >> a.txt'                 p6mut restore --source=HEAD~1 a.txt
PREP='echo x >> a.txt; git add a.txt'  p6mut restore --staged a.txt
PREP='echo x >> a.txt; git add a.txt'  p6mut checkout side
PREP='rm a.txt'                        p6mut restore a.txt
PREP='rm -r sub'                       p6mut restore sub
PREP='echo z > c.txt'                  p6mut checkout side
PREP='echo z > newfile.txt'            p6mut checkout side
unset PREP
[ $p6ok = 1 ] && { ok; report "checkout/switch/restore" "$p6n switches and restores, clean and dirty"; } \
              || bad "checkout/switch/restore"

# ---------------------------------------------------------------- reset
p6ok=1; p6n=0; p6what="reset"
p6mut reset;                p6mut reset HEAD~1
p6mut reset --soft HEAD~1;  p6mut reset --hard HEAD~1
p6mut reset --mixed HEAD~1; p6mut reset --hard
p6mut reset -q HEAD~1;      p6mut reset HEAD -- a.txt
p6mut reset -- a.txt;       p6mut reset HEAD~1 -- a.txt
p6mut reset --hard side;    p6mut reset --hard HEAD~2
p6mut reset --soft nosuch;  p6mut reset nosuch
PREP='echo x >> a.txt'                     p6mut reset --hard
PREP='echo x >> a.txt'                     p6mut reset --soft HEAD~1
PREP='echo x >> a.txt; git add a.txt'      p6mut reset
PREP='echo x >> a.txt; git add a.txt'      p6mut reset a.txt
PREP='echo n > new.txt; git add new.txt'   p6mut reset new.txt
PREP='rm a.txt'                            p6mut reset --hard
PREP='rm -r sub'                           p6mut reset --hard
unset PREP
[ $p6ok = 1 ] && { ok; report "reset" "$p6n resets across the three modes"; } \
              || bad "reset"

# --------------------------------------------------------------- reflog
p6ok=1; p6n=0; p6dir="$P6/fix"; p6what="reflog"
p6ro reflog; p6ro reflog show; p6ro reflog show HEAD; p6ro reflog HEAD
p6ro reflog main; p6ro reflog side; p6ro reflog -n 3
[ $p6ok = 1 ] && { ok; report "reflog" "$p6n listings"; } || bad "reflog"

# -------------------------------------- the upstream lines phase 5 deferred
# All four `status` formats report the relationship with the upstream, and
# each reports it differently.  Phase 5 could not: it had neither a range
# count nor a remote-tracking ref.
p6ok=1; p6n=0; p6what="status"
for f in "" "-s" "-b" "-sb" "-bs" "--porcelain" "--porcelain=v2" \
         "--porcelain=v2 -b" "--long" "-uno" "-uall" "-sz"; do
  p6mut status $f
done
for f in "" "-sb" "--porcelain=v2 -b"; do
  PREP='git commit -q --allow-empty -m ahead'              p6mut status $f
  PREP='git update-ref refs/remotes/origin/main HEAD~1'    p6mut status $f
  PREP='git update-ref -d refs/remotes/origin/main'        p6mut status $f
done
unset PREP
[ $p6ok = 1 ] && { ok; report "upstream tracking" "$p6n status forms, four ways of saying it"; } \
              || bad "upstream tracking"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
