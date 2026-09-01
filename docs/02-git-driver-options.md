# 02 — `git` driver options

> **Marks** — `[x]` in scope for gittle v1 · `[ ]` out of scope · `` `[log]` `` seen in the
> agent tool-call logs (`git-tool-calls-*.md`). A section headed **CUT from v1** has every
> option out of scope; the reason follows inline. Rationale and budget: `plan.md`.


Options accepted by the `git` wrapper itself, before the subcommand name.
These set up the process environment (repository location, config overrides,
pathspec semantics) and are then visible to every subcommand.

```
git [<driver-options>] <command> [<command-options>] [<args>]
```

## Version and help

- [x] `-v` / `--version` — Print the git version and exit.
- [x] `-h` / `--help` — Print the synopsis and the list of common commands; `git help -a` lists everything.
- [ ] `--help` *(after a command)* — Show that command's manual page instead of running it.

## Repository location

- [x] `-C <path>` — Behave as if git had been started in `<path>`; repeatable and cumulative.  `[log]`
- [x] `--git-dir=<path>` — Use `<path>` as the repository directory instead of discovering `.git` (also `GIT_DIR`).
- [x] `--work-tree=<path>` — Use `<path>` as the working tree root (also `GIT_WORK_TREE`).  `[log]`
- [x] `--bare` — Treat the repository as bare, so there is no working tree.
- [ ] `--namespace=<path>` — Operate inside a ref namespace, hiding refs outside it (also `GIT_NAMESPACE`).

## Configuration

- [x] `-c <name>=<value>` — Override a single configuration variable for this invocation.
- [ ] `--config-env=<name>=<envvar>` — Set a configuration variable from an environment variable, keeping secrets off the command line.
- [ ] `--attr-source=<tree-ish>` — Read `.gitattributes` from the given tree instead of the working tree.

## Output and paging

- [ ] `-p` / `--paginate` — Pipe output through the pager even when the command would not normally page.
- [x] `-P` / `--no-pager` — Never pipe output through a pager.  `[log]`
- [ ] `--no-advice` — Suppress all advice/hint messages.

## Object database behavior

- [ ] `--no-replace-objects` — Ignore `refs/replace/*` substitutions.
- [ ] `--no-lazy-fetch` — Do not fetch missing objects on demand from a promisor remote.
- [ ] `--no-optional-locks` — Skip operations that would take a lock purely to refresh caches (e.g. index refresh in `status`).

## Pathspec interpretation

- [ ] `--literal-pathspecs` — Disable all globbing and pathspec magic; treat arguments literally.
- [ ] `--glob-pathspecs` — Apply `glob` magic to every pathspec.
- [ ] `--noglob-pathspecs` — Apply `literal` magic to every pathspec.
- [ ] `--icase-pathspecs` — Apply `icase` magic to every pathspec, making matching case-insensitive.

## Installation introspection

- [ ] `--exec-path[=<path>]` — Print, or override, the directory holding git's helper executables.
- [ ] `--html-path` — Print the install path of git's HTML documentation and exit.
- [ ] `--man-path` — Print the manpath for git's manual pages and exit.
- [ ] `--info-path` — Print the install path of git's Info documentation and exit.
- [ ] `--list-cmds=<group>[,<group>…]` — Internal/experimental: list command names belonging to the given groups.

## Notes for gittle

- The driver's argument parsing, config override handling, and repository
  discovery are the natural first module: every command depends on them.
- `--exec-path`, `--html-path`, `--man-path`, `--info-path` and `--list-cmds`
  exist only because git dispatches to external binaries and ships manpages;
  a single-binary gittle can drop them outright.
- Corresponding environment variables (`GIT_DIR`, `GIT_WORK_TREE`,
  `GIT_CONFIG_*`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`,
  `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_CEILING_DIRECTORIES`,
  `GIT_SSH_COMMAND`, `GIT_AUTHOR_*`, `GIT_COMMITTER_*`) are documented in
  `Documentation/git.adoc` and are a separate selection decision.
