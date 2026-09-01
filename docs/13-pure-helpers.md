# 13 — Pure helpers

> **Marks** — `[x]` in scope for gittle v1 · `[ ]` out of scope · `` `[log]` `` seen in the
> agent tool-call logs (`git-tool-calls-*.md`). A section headed **CUT from v1** has every
> option out of scope; the reason follows inline. Rationale and budget: `plan.md`.


Small single-purpose programs. Several exist only to support git's shell
scripts (`sh-setup`, `sh-i18n`, `merge-one-file`) and disappear entirely in a
single-binary implementation. Others (`check-ignore`, `check-attr`,
`stripspace`, `interpret-trailers`) are library functions gittle needs
internally whether or not it exposes them as commands.

---

## `check-attr` — report gitattributes for paths

> **CUT from v1** — v1 does not implement gitattributes.

- [ ] `<attr>… <pathname>…` — Attributes to query and paths to query them for.
- [ ] `-a` / `--all` — List every attribute set on the paths.
- [ ] `--cached` — Read `.gitattributes` from the index rather than the working tree.
- [ ] `--source=<tree-ish>` — Read `.gitattributes` from a tree.
- [ ] `--stdin` — Read path names from standard input.
- [ ] `-z` — NUL-separate both input and output.
- [ ] `--` — Separate the attribute list from the path list.

## `check-ignore` — explain ignore decisions

- [x] `<pathname>…` — Paths to test.  `[log]`
- [x] `-q` / `--quiet` — Report the result only through the exit status.
- [x] `-v` / `--verbose` — Print the source, line number, and pattern that matched.  `[log]`
- [ ] `-n` / `--non-matching` — With `--verbose`, also list paths that matched nothing.
- [ ] `--no-index` — Ignore the index when deciding, to explain why a path is tracked.
- [ ] `--stdin` — Read path names from standard input.
- [ ] `-z` — NUL-separate both input and output.

## `check-mailmap` — resolve identities through the mailmap

> **CUT from v1** — v1 does not implement mailmap.

- [ ] `<contact>…` — Identities to canonicalize.
- [ ] `--stdin` — Read further contacts from standard input.
- [ ] `--mailmap-file=<file>` — Consult an extra mailmap file.
- [ ] `--mailmap-blob=<blob>` — Consult a mailmap stored as a blob.

## `check-ref-format` — validate ref names

> **CUT from v1** — validation stays internal.

- [ ] `<refname>` — *(core)* The name to validate.
- [ ] `--allow-onelevel` / `--no-allow-onelevel` — Accept or reject names with no `/`.
- [ ] `--refspec-pattern` — Allow a single `*` as a refspec wildcard.
- [ ] `--normalize` — Print the name with leading and duplicated slashes removed.
- [ ] `--branch <name>` — Expand and validate a branch name, resolving `@{-n}`.

## `column` — lay text out in columns

> **CUT from v1** — output cosmetics.

- [ ] `--command=<name>` — Take the layout mode from `column.<name>` configuration.
- [ ] `--mode=<mode>` — Set the layout mode explicitly.
- [ ] `--raw-mode=<n>` — Set the layout mode as a numeric bitfield.
- [ ] `--width=<width>` — Assume a terminal of the given width.
- [ ] `--indent=<string>` — String printed at the start of each line.
- [ ] `--nl=<string>` — String printed at the end of each line.
- [ ] `--padding=<N>` — Spaces between columns.

## `credential` — query and store credentials

> **CUT from v1** — ssh-only access needs no credential helpers.

Subcommands: `fill`, `approve`, `reject`.

- [ ] `fill` — Read a credential description on stdin and print it with username and password filled in.
- [ ] `approve` — Record a credential that worked.
- [ ] `reject` — Erase a credential that failed.

Relevant to gittle only if ssh key handling ever needs a credential path;
ssh-only access normally bypasses this machinery entirely.

## `credential-cache` — in-memory credential helper

> **CUT from v1** — ssh-only access needs no credential helpers.

- [ ] `--timeout <seconds>` — How long credentials stay cached (default 900).
- [ ] `--socket <path>` — Unix socket used to reach the cache daemon.

## `credential-store` — plaintext-file credential helper

> **CUT from v1** — ssh-only access needs no credential helpers.

- [ ] `--file=<path>` — File used to store and look up credentials.

## `fmt-merge-msg` — compose a merge commit message

> **CUT from v1** — message generation stays internal to `merge`.

- [ ] `-F <file>` / `--file <file>` — Read the merged-ref list from a file instead of stdin.
- [ ] `--log[=<n>]` — Include up to `<n>` one-line commit summaries.
- [ ] `--no-log` — Omit the commit summaries.
- [ ] `--summary` / `--no-summary` — Deprecated synonyms for `--log` / `--no-log`.
- [ ] `-m <message>` / `--message <message>` — Use a custom first line.
- [ ] `--into-name <branch>` — Compose the message as if merging into a different branch.

## `hook` — run configured hooks

> **CUT from v1** — v1 runs no hooks.

Subcommands: `run`, `list`.

- [ ] `run <hook-name>` — *(core)* Run the hooks configured for an event.
- [ ] `list <hook-name>` — List the hooks that would run for an event.
- [ ] `--allow-unknown-hook-name` — Do not reject hook names git does not recognize.
- [ ] `--to-stdin <file>` — Stream a file into the hook's standard input.
- [ ] `--ignore-missing` — Exit zero when no hook exists.
- [ ] `-j` / `--jobs` — Run hooks in parallel.
- [ ] `-z` — NUL-terminate `list` output.
- [ ] `--show-scope` — Prefix each listed hook with the config scope that declared it.

## `interpret-trailers` — parse and edit commit-message trailers

> **CUT from v1** — trailer parsing beyond `-s` is out of scope.

- [ ] `<file>…` — Messages to process; stdin if none.
- [ ] `--in-place` / `--no-in-place` — Edit the files in place rather than writing to stdout.
- [ ] `--trailer=<key>[(=|:)<value>]` / `--no-trailer` — Trailer to add; repeatable.
- [ ] `--where=<placement>` — Where new trailers go (`after`, `before`, `end`, `start`).
- [ ] `--if-exists=<action>` — What to do when the trailer already exists (`addIfDifferent`, `addIfDifferentNeighbor`, `add`, `replace`, `doNothing`).
- [ ] `--if-missing=<action>` — What to do when it does not exist (`add`, `doNothing`).
- [ ] `--trim-empty` / `--no-trim-empty` — Drop trailers whose value is only whitespace.
- [ ] `--only-trailers` / `--no-only-trailers` — Print just the trailer block.
- [ ] `--only-input` / `--no-only-input` — Print only trailers found in the input.
- [ ] `--unfold` / `--no-unfold` — Join multi-line trailer values into one line.
- [ ] `--parse` — Alias for `--only-trailers --only-input --unfold`.
- [ ] `--divider` / `--no-divider` — Treat `---` as the end of the message.

## `mailinfo` — split one email into message, identity, and patch

> **CUT from v1** — email workflow.

- [ ] `<msg> <patch>` — Output files for the commit message and the patch.
- [ ] `-k` — Keep the subject line verbatim.
- [ ] `-b` — Strip only `[PATCH]`-like prefixes, keeping other bracketed text.
- [ ] `-u` — Re-encode the message and identity to UTF-8.
- [ ] `--encoding=<encoding>` — Re-encode to a specific charset instead.
- [ ] `-n` — Do not re-encode at all.
- [ ] `-m` / `--message-id` — Append the `Message-ID` to the commit message.
- [ ] `--scissors` — Discard everything before a scissors line.
- [ ] `--no-scissors` — Ignore scissors lines.
- [ ] `--quoted-cr=<action>` — How to handle CRLF surviving transfer decoding (`nowarn`, `warn`, `strip`).

## `mailsplit` — split an mbox or Maildir into messages

> **CUT from v1** — email workflow.

- [ ] `<mbox>` / `<Maildir>` — Input mailbox; stdin if omitted.
- [ ] `-o<directory>` — Directory to write individual messages into.
- [ ] `-b` — Accept input whose first line is not a `From ` line.
- [ ] `-d<prec>` — Number of digits in generated filenames.
- [ ] `-f<nn>` — Start numbering after `<nn>`.
- [ ] `--keep-cr` — Do not strip CR from CRLF line endings.
- [ ] `--mboxrd` — Input is mboxrd; reverse the `>From ` escaping.

## `merge-one-file` — default `merge-index` helper

> **CUT from v1** — `merge-index` is cut.

No options; invoked by `merge-index` with a fixed positional argument list
(mode/oid/stage triples plus the path).

## `patch-id` — compute a whitespace-independent patch ID

> **CUT from v1** — needed only by `cherry` and `--cherry-pick`, both cut.

- [ ] `--stable` — Use the order-independent hash (the default in modern git).
- [ ] `--unstable` — Use the historical hash that depends on hunk order.
- [ ] `--verbatim` — Hash the input as-is, without stripping whitespace.

## `sh-i18n` / `sh-setup` — shell script libraries

> **CUT from v1** — shell libraries with no analogue in a single binary.

Sourced by git's shell-script commands; not user-facing and irrelevant to a
Nim implementation.

## `stage` — alias for `add`

Same options as `add`; see `06`.

## `stripspace` — normalize message whitespace

> **CUT from v1** — message cleanup stays internal.

- [ ] `-s` / `--strip-comments` — Remove comment lines.
- [ ] `-c` / `--comment-lines` — Prefix each line with the comment character.

## `url-parse` — decompose a git URL

> **CUT from v1** — URL parsing stays internal.

- [ ] `<url>…` — URLs to parse.
- [ ] `-c <component>` / `--component <component>` — Which component to print (`protocol`, `host`, `port`, `path`, `user`, …).

Useful reference for gittle's ssh URL handling: git accepts `ssh://[user@]host[:port]/path`,
the scp-like `[user@]host:path`, plain filesystem paths, and `file://` URLs.
