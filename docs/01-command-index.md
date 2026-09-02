# 01 — Command index

> **Marks** — `[x]` in scope for gittle v1 · `[ ]` out of scope · `` `[log]` `` seen in the
> agent tool-call logs (`git-tool-calls-*.md`). A section headed **CUT from v1** has every
> option out of scope; the reason follows inline. Rationale and budget: `plan.md`.


Every command git ships, grouped by git's own classification from
`command-list.txt`. Tick the boxes for what gittle should implement.

Counts: 161 commands + 32 non-command manual pages (see `15-non-command-docs.md`).

---

## Main porcelain — repository creation

- [x] **clone** — Copy an existing repository into a new directory, creating remote-tracking branches and checking out a starting branch.  `[log]`
- [x] **init** — Create an empty repository or reinitialize an existing one.

## Main porcelain — working on the tree

- [x] **add** — Stage the current content of files into the index for the next commit.  `[log]`
- [x] **mv** — Move or rename a file, directory, or symlink and record the change in the index.
- [x] **restore** — Restore working-tree and/or index files from another source (HEAD, a commit, or the index).  `[log]`
- [x] **rm** — Remove files from the working tree and from the index.  `[log]`
- [ ] **sparse-checkout** — Restrict the working tree to a chosen subset of tracked paths.

## Main porcelain — examining history and state

- [ ] **bisect** — Binary-search the commit history to find the commit that introduced a change in behavior.
- [x] **diff** — Show changes between commits, the index, and the working tree.  `[log]`
- [x] **grep** — Search tracked content (working tree, index, or arbitrary trees) for lines matching a pattern.  `[log]`
- [x] **log** — Show commit history with optional diffs, filters, and formatting.  `[log]`
- [x] **show** — Display one or more objects (commits, tags, trees, blobs) in human-readable form.  `[log]`
- [x] **status** — Show which paths differ between working tree, index, and HEAD, plus untracked files.  `[log]`

## Main porcelain — growing, marking, and tweaking history

- [x] **branch** — List, create, rename, delete, and configure branches.  `[log]`
- [x] **commit** — Record the staged content as a new commit on the current branch.  `[log]`
- [ ] **history** — Rewrite history using a declarative description of the desired result. `[experimental]`
- [x] **merge** — Join two or more development histories together, creating a merge commit when needed.  `[log]`
- [x] **rebase** — Reapply a series of commits on top of a different base commit, optionally interactively.
- [x] **reset** — Move HEAD and optionally the index and working tree to a given state.  `[log]`
- [x] **switch** — Change the current branch (the checkout half of `checkout`).
- [x] **tag** — Create, list, delete, or verify lightweight and annotated tags.  `[log]`

## Main porcelain — collaborating

- [x] **fetch** — Download objects and refs from a remote repository into remote-tracking refs.  `[log]`
- [x] **pull** — Fetch from a remote and then merge or rebase the result into the current branch.
- [x] **push** — Upload local refs and the objects they need to a remote repository.  `[log]`

## Main porcelain — other

- [ ] **am** — Apply a series of patches taken from a mailbox, creating one commit per patch.
- [ ] **archive** — Produce a tar or zip archive of the contents of a tree.
- [ ] **backfill** — Download objects a partial clone previously skipped.
- [ ] **bundle** — Package objects and refs into a single file that can be moved offline and fetched from.
- [x] **checkout** — Switch branches and/or restore working-tree files (the older, overloaded form of `switch` + `restore`).  `[log]`
- [x] **cherry-pick** — Apply the changes introduced by existing commits onto the current branch as new commits.  `[log]`
- [ ] **citool** — Tcl/Tk graphical commit tool.
- [x] **clean** — Delete untracked files (and optionally ignored files and directories) from the working tree.
- [ ] **describe** — Name a commit from the most recent reachable tag plus a distance and abbreviated hash.
- [ ] **format-patch** — Render commits as one mail-formatted patch file per commit, ready for email submission.
- [x] **gc** — Run housekeeping: repack objects, prune unreachable ones, expire reflogs, and update auxiliary indexes.
- [ ] **gitk** — Tcl/Tk history browser (shipped separately from the core binary).
- [ ] **gui** — Tcl/Tk graphical porcelain for staging and committing.
- [ ] **maintenance** — Run or schedule background repository optimization tasks.
- [ ] **notes** — Attach, inspect, copy, and merge notes attached to objects without rewriting them.
- [ ] **range-diff** — Compare two ranges of commits (e.g. two versions of a patch series) pairwise.
- [x] **revert** — Create new commits that undo the changes made by existing commits.
- [ ] **scalar** — Opinionated setup/maintenance wrapper for very large repositories.
- [ ] **shortlog** — Summarize `git log` output grouped by author with commit subjects.
- [x] **stash** — Save dirty working-tree and index state onto a stack and restore it later.  `[log]`
- [ ] **submodule** — Initialize, update, and inspect repositories nested inside this one.  `[log]`
- [x] **worktree** — Manage additional working trees attached to the same repository.  `[log]`

---

## Ancillary manipulators

- [x] **config** — Read and write configuration values in the repository, user, system, or worktree config files.  `[log]`
- [ ] **fast-export** — Dump repository history as a `fast-import` stream.
- [ ] **fast-import** — Build repository history by consuming a stream of high-level commands.
- [ ] **filter-branch** — Rewrite branches by running filters over each commit (deprecated in favor of `filter-repo`).
- [ ] **mergetool** — Launch external merge tools to resolve conflicted paths.
- [ ] **pack-refs** — Move loose refs into the packed-refs file for faster access.
- [ ] **prune** — Delete unreachable objects from the object database.
- [x] **reflog** — Inspect, expire, and delete entries in the per-ref logs of where refs have pointed.  `[log]`
- [ ] **refs** — Low-level ref-store access, including migration between the files and reftable backends.
- [x] **remote** — Manage the set of named remote repositories and their refspecs.  `[log]`
- [ ] **repack** — Combine loose objects and existing packs into new packfiles.
- [ ] **replace** — Create, list, and delete refs that transparently substitute one object for another.

## Ancillary interrogators

- [ ] **annotate** — Show, for each line of a file, the commit that last touched it (`blame` with a different default output).
- [ ] **blame** — Annotate each line of a file with the commit, author, and time that last modified it.
- [ ] **bugreport** — Collect system and repository information into a file for filing a bug report.
- [ ] **count-objects** — Report how many loose objects exist and how much disk they consume.
- [ ] **diagnose** — Produce a zip archive of diagnostic information about the repository and environment.
- [ ] **difftool** — Show diffs using an external graphical or terminal diff tool.
- [ ] **fsck** — Verify object connectivity and validity throughout the object database.
- [ ] **gitweb** — CGI web front end for browsing repositories.
- [x] **help** — Display documentation for git itself, a command, a guide, or a configuration variable.
- [ ] **instaweb** — Start a local web server running gitweb against the current repository.
- [ ] **merge-tree** — Compute a merge between two commits and report the result without touching the index or working tree.  `[log]`
- [ ] **rerere** — Record and replay how conflicts were resolved so identical conflicts resolve automatically.
- [ ] **show-branch** — Display an ASCII graph of what commits are on which branches relative to a merge base.
- [ ] **verify-commit** — Check the GPG/SSH signature of signed commits.
- [ ] **verify-tag** — Check the GPG/SSH signature of signed tags.
- [x] **version** — Print the git version, optionally with build details.
- [ ] **whatchanged** — Deprecated alias for `log --raw`, showing which files each commit touched.

---

## Interacting with other systems (foreign SCM interface)

- [ ] **archimport** — Import a GNU Arch repository into git.
- [ ] **cvsexportcommit** — Export a single git commit into a CVS checkout.
- [ ] **cvsimport** — Import history from a CVS repository into git.
- [ ] **cvsserver** — Emulate a CVS server so CVS clients can work against a git repository.
- [ ] **imap-send** — Upload a stream of patches from stdin into an IMAP folder as drafts.
- [ ] **p4** — Import from and submit to Perforce depots.
- [ ] **quiltimport** — Apply a quilt patch series onto the current branch as commits.
- [ ] **request-pull** — Generate a summary message asking an upstream maintainer to pull from a published branch.
- [ ] **send-email** — Send commits, typically produced by `format-patch`, as email via SMTP or sendmail.
- [ ] **svn** — Bidirectional bridge between a Subversion repository and git.

---

## Low-level plumbing — manipulators

- [ ] **apply** — Apply a unified diff to the working tree and/or index without creating a commit.  `[log]`
- [ ] **checkout-index** — Copy file contents from the index into the working tree.
- [ ] **commit-graph** — Write and verify commit-graph files that accelerate history traversal.
- [x] **commit-tree** — Create a commit object from a tree, parents, and a message read from stdin.
- [x] **hash-object** — Compute an object ID for a file's content and optionally write the object into the database.
- [x] **index-pack** — Read a packfile and build (or verify) its `.idx` index.
- [x] **merge-file** — Perform a three-way merge of three files and emit the result with conflict markers.
- [ ] **merge-index** — Run a per-path merge helper over every unmerged entry in the index.
- [ ] **mktag** — Create a tag object from a description on stdin, with extra syntactic validation.
- [ ] **mktree** — Build a tree object from `ls-tree`-formatted lines on stdin.
- [ ] **multi-pack-index** — Write, verify, expire, and repack multi-pack index files.
- [x] **pack-objects** — Create a packfile from a list of object names on stdin.
- [ ] **prune-packed** — Delete loose objects that are already present in a packfile.
- [x] **read-tree** — Load one, two, or three trees into the index, optionally performing a merge.
- [ ] **replay** — Replay commits onto a new base entirely in the object database, without a working tree. `[experimental]`
- [x] **symbolic-ref** — Read, write, and delete symbolic refs such as HEAD.
- [ ] **unpack-objects** — Explode a packfile from stdin into loose objects.
- [x] **update-index** — Register working-tree content, flags, and cache metadata into the index.
- [x] **update-ref** — Update, create, or delete refs safely, with old-value checks and reflog entries.
- [x] **write-tree** — Write the current index out as a tree object and print its ID.

## Low-level plumbing — interrogators

- [x] **cat-file** — Print the type, size, or content of objects, individually or in batch mode.  `[log]`
- [ ] **cherry** — List which commits in a branch have not yet been applied upstream, by patch ID.
- [ ] **diff-files** — Compare the working tree against the index in machine-readable form.
- [ ] **diff-index** — Compare a tree against the index or working tree in machine-readable form.
- [ ] **diff-pairs** — Diff explicitly supplied blob pairs read from stdin.
- [ ] **diff-tree** — Compare the content and mode of blobs found via two tree objects.
- [x] **for-each-ref** — Iterate over refs matching patterns and print selected fields in a chosen format.  `[log]`
- [ ] **for-each-repo** — Run a git command in each repository listed in a configuration variable.
- [ ] **format-rev** — Pretty-print individual revisions on demand from a stream of requests. `[experimental]`
- [ ] **get-tar-commit-id** — Extract the commit ID embedded in a tar archive produced by `git archive`.
- [ ] **last-modified** — Report, for each path, the commit that last modified it. `[experimental]`
- [x] **ls-files** — List files known to the index, the working tree, or both, with optional status flags.  `[log]`
- [x] **ls-remote** — List the refs a remote repository advertises, without fetching objects.
- [x] **ls-tree** — List the entries of a tree object.  `[log]`
- [x] **merge-base** — Find the best common ancestor(s) of two or more commits.  `[log]`
- [ ] **name-rev** — Find a symbolic name for a commit based on the refs that can reach it.
- [ ] **pack-redundant** — Identify packfiles whose objects are fully covered by other packs. (deprecated)
- [ ] **repo** — Report structural facts about the repository, such as layout and format versions.
- [x] **rev-list** — Walk history and list the commit (or object) names that satisfy a set of filters.  `[log]`
- [x] **rev-parse** — Parse and normalize revision and path arguments, and report repository layout variables.  `[log]`
- [ ] **show-index** — Dump the contents of a packfile index.
- [ ] **show-ref** — List local refs and the object IDs they point at.
- [ ] **unpack-file** — Write a blob's contents into a temporary file and print its name.
- [ ] **var** — Print the value of a logical git variable such as the committer identity or editor.
- [ ] **verify-pack** — Validate a packfile and its index, optionally printing per-object statistics.

---

## Synching repositories (transport endpoints)

- [ ] **daemon** — Minimal TCP server exporting repositories over the anonymous `git://` protocol.
- [ ] **fetch-pack** — Client half of the fetch transport: negotiate wants/haves and receive a packfile.
- [ ] **http-backend** — CGI program implementing the server side of git-over-HTTP.
- [ ] **send-pack** — Client half of the push transport: send refs updates and a packfile to a receiver.
- [ ] **update-server-info** — Refresh the auxiliary files that let dumb HTTP servers serve a repository.

## Synching helpers (server side)

- [ ] **http-fetch** — Fetch objects over dumb HTTP.
- [ ] **http-push** — Push objects over HTTP/DAV.
- [ ] **receive-pack** — Server half of push: accept ref updates and a packfile from `send-pack`.  *(was in scope; cut with the server, plan.md §6 decision 2)*
- [ ] **shell** — Restricted login shell that only permits git transport commands over ssh.  *(was in scope; cut with the server)*
- [ ] **upload-archive** — Server half of `git archive --remote`, streaming an archive back to the client.
- [ ] **upload-pack** — Server half of fetch: advertise refs and send the requested packfile.  *(was in scope; cut with the server)*

---

## Pure helpers

- [ ] **check-attr** — Report the gitattributes that apply to given paths.
- [x] **check-ignore** — Report which ignore rule, if any, excludes given paths.  `[log]`
- [ ] **check-mailmap** — Resolve author/committer identities through the mailmap.
- [ ] **check-ref-format** — Validate that a string is a well-formed ref name, optionally normalizing it.
- [ ] **column** — Format a list of lines into columns for terminal display.
- [ ] **credential** — Query, store, or erase credentials via configured credential helpers.
- [ ] **credential-cache** — Credential helper that keeps credentials in memory for a limited time.
- [ ] **credential-store** — Credential helper that keeps credentials in a plaintext file.
- [ ] **fmt-merge-msg** — Generate a merge commit message from `FETCH_HEAD`-style input.
- [ ] **hook** — Run a configured hook by name, honoring both hook files and config-declared hooks.
- [ ] **interpret-trailers** — Parse, add, and modify structured trailers in a commit message.
- [ ] **mailinfo** — Split one email message into a commit message, authorship information, and a patch.
- [ ] **mailsplit** — Split an mbox or Maildir into one file per message.
- [ ] **merge-one-file** — Default per-path merge helper invoked by `merge-index`.
- [ ] **patch-id** — Compute a whitespace- and line-number-independent ID for a patch.
- [ ] **sh-i18n** — Shell library providing gettext wrappers for git's shell scripts.
- [ ] **sh-setup** — Shell library providing common setup for git's shell scripts.
- [x] **stage** — Alias for `git add`.
- [ ] **stripspace** — Normalize whitespace and comment lines in text read from stdin.
- [ ] **url-parse** — Parse a git URL and print selected components.
