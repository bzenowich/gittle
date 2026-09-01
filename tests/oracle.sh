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

# Options that belong to a later phase must refuse by name rather than be
# ignored -- a `log` that silently dropped `--grep` would answer a different
# question and look like it had answered.
def_ok=1
for o in -p --stat --grep=x --author=x --all --topo-order --since=2020-01-01 --graph; do
  "$GITTLE" -C "$REFREPO" log -1 "$o" >/dev/null 2>&1 && { def_ok=0; echo "  $o was accepted"; }
done
[ $def_ok = 1 ] && { ok; report "log deferrals" "7 later-phase options refuse by name"; } \
               || bad "log deferrals"

# --------------------------------------------------------------------- show
show_ok=1; nshow=0
for f in "" "--oneline" "--pretty=raw" "--pretty=fuller" "--format=%H%n%s"; do
  nshow=$((nshow+1))
  a=$(git -C "$REFREPO" show -s $NOMAILMAP $f HEAD 2>&1)
  b=$("$GITTLE" -C "$REFREPO" show $f HEAD 2>&1)
  [ "$a" = "$b" ] || { show_ok=0; echo "  show $f differs"; }
done
# Every tag in the reference repository: annotated, signed, nested, and one
# that points at a blob.
ntag=0; TAGS=$(git -C "$REFREPO" tag)
[ $FULL = 1 ] || TAGS=$(printf '%s\n' "$TAGS" | head -40)
for t in $TAGS; do
  ntag=$((ntag+1))
  a=$(git -C "$REFREPO" show -s $NOMAILMAP "$t" 2>&1)
  b=$("$GITTLE" -C "$REFREPO" show "$t" 2>&1)
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

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
