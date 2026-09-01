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
# whichever one the developer happens to have configured.
GIT_AUTHOR_NAME="Oracle Test"; GIT_AUTHOR_EMAIL="oracle@example.com"
GIT_COMMITTER_NAME="Oracle Test"; GIT_COMMITTER_EMAIL="oracle@example.com"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

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

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
