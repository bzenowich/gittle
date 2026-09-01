# 15 — Non-command documentation

> **Not a selection list.** These are specifications, not features. The v1 compatibility
> floor is: `gitrepository-layout`, `gitformat-index` (read v2/v3/v4, write v2/v3), `gitformat-pack`,
> `gitrevisions`, `gitignore`, `gitcli`, and `gitprotocol-{common,v2,pack,capabilities}`.
> v1 deliberately ignores `gitformat-commit-graph`, `gitformat-chunk`, multi-pack-index,
> bitmaps, `gitattributes`, `gitmodules`, `gitmailmap`, and reftable. A reftable repository is
> refused at discovery by the repository-extension gate. Of `githooks`,
> only `pre-commit` and `commit-msg` are honored.

> **Marks** — `[x]` in scope for gittle v1 · `[ ]` out of scope · `` `[log]` `` seen in the
> agent tool-call logs (`git-tool-calls-*.md`). A section headed **CUT from v1** has every
> option out of scope; the reason follows inline. Rationale and budget: `plan.md`.


The remaining 32 entries in `command-list.txt` are manual pages, not commands.
They are listed here because several of them — particularly the `gitformat-*`
and `gitprotocol-*` pages — are the actual specifications gittle must implement
to stay compatible with git's on-disk format and wire protocol.

---

## Developer interfaces: file formats and protocols

**These are the specifications, not features to select.** Anything gittle reads
or writes must conform to them.

- **gitformat-index** — The `.git/index` binary format: header, cache entries, and extensions (`TREE`, `REUC`, `UNTR`, `FSMN`, `EOIE`, `IEOT`, `link`, `sdir`). Versions 2, 3, and 4 differ in flags and path compression. **Required.**
- **gitformat-pack** — The packfile and `.idx` format, delta encoding (ofs-delta and ref-delta), plus `.rev`, `.mtimes`, multi-pack-index, and pack bitmap formats. **Required if gittle speaks any transport, and in practice required to read real repositories.**
- **gitformat-commit-graph** — The commit-graph acceleration file and its chained form. Optional; git works without it, but gittle must not be confused by its presence.
- **gitformat-chunk** — The shared chunk-based container used by commit-graph and multi-pack-index files.
- **gitformat-bundle** — The bundle file format (v2 and v3), a prerequisite list plus an embedded packfile.
- **gitformat-signature** — How GPG/SSH/X.509 signatures are embedded in commit, tag, push certificate, and mergetag payloads.
- **gitprotocol-common** — Shared wire conventions: pkt-line framing, ref name rules, capability advertisement syntax. **Required.**
- **gitprotocol-pack** — How fetch and push negotiate and transfer packfiles: `want`/`have` negotiation, `ACK`/`NAK`, sideband multiplexing, ref update commands. **Required.**
- **gitprotocol-capabilities** — The v0/v1 capability list (`multi_ack`, `thin-pack`, `side-band-64k`, `ofs-delta`, `shallow`, `no-done`, `agent`, `object-format`, `push-cert`, …). **Required at whatever subset gittle negotiates.**
- **gitprotocol-v2** — Protocol version 2: the command/capability request framing, `ls-refs`, `fetch`, and `object-info` commands. **The version gittle should implement if it implements one.**
- **gitprotocol-http** — The smart and dumb HTTP transports. Out of scope given the ssh-only decision.

## User interfaces: file formats gittle reads

- **gitrepository-layout** — What lives in `.git`: `objects/`, `refs/`, `HEAD`, `config`, `index`, `info/`, `hooks/`, `logs/`, `worktrees/`, `packed-refs`, `shallow`, and so on. **Read this first.**
- **gitignore** — Ignore pattern syntax and the precedence of `.gitignore`, `.git/info/exclude`, and `core.excludesFile`.
- **gitattributes** — Path attribute syntax and the built-in attributes (`text`, `eol`, `diff`, `merge`, `filter`, `export-ignore`, `delta`, …).
- **gitmodules** — The `.gitmodules` file that records submodule paths, URLs, branches, and update policies.
- **gitmailmap** — The `.mailmap` file that rewrites author and committer identities.
- **githooks** — Every hook git will run, its arguments, and its stdin/exit-status contract (`pre-commit`, `commit-msg`, `pre-push`, `pre-receive`, `update`, `post-receive`, `post-checkout`, `post-merge`, `reference-transaction`, …).
- **gitrevisions** — The revision and range grammar: `<sha1>`, `<refname>`, `@{<n>}`, `@{<date>}`, `<rev>^`, `<rev>~<n>`, `<rev>^{<type>}`, `:/<text>`, `<rev>:<path>`, `:<n>:<path>`, `<a>..<b>`, `<a>...<b>`, `<rev>^@`, `<rev>^!`. **Required — every command that takes a revision depends on this.**
- **gitcli** — The command-line conventions all git commands follow: `--` separating revisions from paths, `-h` behavior, `--help-all`, negated `--no-` options, and the pathspec magic syntax (`:(exclude)`, `:(glob)`, `:(icase)`, `:(attr:…)`, `:/`, `:!`).
  - [ ] `-h` — Print a short usage summary for a command.
  - [ ] `--help-all` — Include plumbing and deprecated options in that summary.

## Guides

Prose documentation with no direct implementation consequences, except where
noted.

- **gitcore-tutorial** — Walks through the plumbing commands in the order a reimplementation would naturally build them; a useful reading order for gittle.
- **gitglossary** — Definitions of ~92 terms used throughout the documentation.
- **gitrevisions** *(also listed above)*, **gitnamespaces** — Ref namespacing via `GIT_NAMESPACE`, used by hosting servers to serve many forks from one object store.
- **gitremote-helpers** — The `git-remote-<transport>` helper protocol: a helper announces `capabilities` and then handles `list`, `fetch`, `push`, `import`, `export`, `connect`, `stateless-connect`, and `get` commands, tuned by `option <name> <value>` lines (`verbosity`, `progress`, `depth`, `deepen-since`, `deepen-not`, `deepen-relative`, `followtags`, `dry-run`, `servpath`, `check-connectivity`, `force`, `cloning`, `update-shallow`, `pushcert`, `push-option`, `from-promisor`, `no-dependents`, `atomic`, `object-format`).
  *Decision point for gittle:* implementing ssh natively means no remote helpers are needed; supporting them later would be the extension path to other transports.
- **gitcredentials** — How credentials are requested and cached; configuration keys `helper`, `username`, `useHttpPath`. Largely moot for ssh-only access.
- **gitsubmodules** — Conceptual overview of submodules.
- **gitworkflows** — Recommended branching workflows.
- **giteveryday** — The minimum useful command set for several user roles; a good sanity check against gittle's chosen feature set.
- **gitfaq** — Frequently asked questions.
- **gitdiffcore** — How the diff pipeline transforms its output (rename detection, pickaxe, path ordering); relevant if gittle implements `-M`/`-C`/`-S`.
- **gittutorial** / **gittutorial-2** — Introductory tutorials.
- **gitcvs-migration** — Guidance for CVS users.
- **gitk** *(also a command)*, **gitweb** *(also a command)* — GUI and web frontends.

---

## Suggested reading order for implementation

1. `gitrepository-layout` — what is on disk.
2. `gitformat-index` — the index.
3. `gitformat-pack` — packs and deltas.
4. `gitrevisions` — how users name objects.
5. `gitcli` — how arguments are parsed and what pathspec magic means.
6. `gitprotocol-common` + `gitprotocol-v2` + `gitprotocol-pack` — the wire.
7. `gitignore`, `gitattributes` — working-tree behavior.
8. `githooks` — only the hooks gittle chooses to fire.
