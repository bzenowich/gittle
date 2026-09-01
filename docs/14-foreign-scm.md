# 14 — Foreign SCM interfaces

> **CUT from v1 — the whole file.** Every command here is a Perl or Python script
> upstream, which a single static binary cannot host, and none of them are needed for
> on-disk or wire compatibility with git.

> **Marks** — `[x]` in scope for gittle v1 · `[ ]` out of scope · `` `[log]` `` seen in the
> agent tool-call logs (`git-tool-calls-*.md`). A section headed **CUT from v1** has every
> option out of scope; the reason follows inline. Rationale and budget: `plan.md`.


Bridges to other version control systems and to email workflows. Almost all of
these are Perl or Python scripts in upstream git rather than C, and none of
them are required for git-repository compatibility.

**Recommendation for gittle: drop this entire category.** It is listed for
completeness and because `send-email` and `request-pull` occasionally come up
in mailing-list workflows.

---

## `send-email` — mail a patch series

The largest option set of any git command outside the diff family (57 options).

### Recipients and headers

- [ ] `--to=<address>,…` — Primary recipients.
- [ ] `--cc=<address>,…` — Starting `Cc:` list.
- [ ] `--bcc=<address>,…` — `Bcc:` list.
- [ ] `--from=<address>` — Sender address.
- [ ] `--reply-to=<address>` — Address replies should go to.
- [ ] `--in-reply-to=<identifier>` — Make the series a reply to an existing message.
- [ ] `--subject=<string>` — Subject for the introductory message.
- [ ] `--no-to` / `--no-cc` / `--no-bcc` — Clear addresses previously set in configuration.
- [ ] `--to-cmd=<command>` — Generate per-patch `To:` addresses by running a command.
- [ ] `--cc-cmd=<command>` — Generate per-patch `Cc:` addresses by running a command.
- [ ] `--header-cmd=<command>` — Generate arbitrary extra headers by running a command.
- [ ] `--no-header-cmd` — Disable a configured header command.
- [ ] `--signed-off-by-cc` / `--no-signed-off-by-cc` — Auto-Cc addresses found in `Signed-off-by` trailers.
- [ ] `--cc-cover` / `--no-cc-cover` — Apply the cover letter's `Cc:` list to every patch.
- [ ] `--to-cover` / `--no-to-cover` — Apply the cover letter's `To:` list to every patch.
- [ ] `--suppress-cc=<category>` — Suppress a category of automatic Cc (`author`, `self`, `cc`, `bodycc`, `sob`, `misc-by`, `cccmd`, `body`, `all`).
- [ ] `--suppress-from` / `--no-suppress-from` — Keep the `From:` address out of the Cc list.
- [ ] `--xmailer` / `--no-xmailer` — Add or omit the `X-Mailer:` header.
- [ ] `--envelope-sender=<address>` — SMTP envelope sender.
- [ ] `--mailmap` / `--no-mailmap` — Canonicalize addresses through the mailmap.
- [ ] `--identity=<identity>` — Use a `sendemail.<identity>` configuration subsection.
- [ ] `--no-identity` — Ignore a configured identity.

### Threading

- [ ] `--thread` / `--no-thread` — Add `In-Reply-To`/`References` headers.
- [ ] `--chain-reply-to` / `--no-chain-reply-to` — Reply to the previous mail rather than to the first.
- [ ] `--outlook-id-fix` / `--no-outlook-id-fix` — Work around Outlook servers replacing the `Message-ID`.

### Transport

- [ ] `--smtp-server=<host>` — Outgoing SMTP server, or a path to a sendmail-like program.
- [ ] `--smtp-server-port=<port>` — SMTP port.
- [ ] `--smtp-server-option=<option>` — Extra option passed to the SMTP server.
- [ ] `--sendmail-cmd=<command>` — Send using a sendmail-like command instead of SMTP.
- [ ] `--smtp-encryption=<encryption>` — `ssl` or `tls`.
- [ ] `--smtp-ssl` — Legacy alias for `--smtp-encryption ssl`.
- [ ] `--smtp-domain=<FQDN>` — Domain used in the HELO/EHLO command.
- [ ] `--smtp-auth=<mechanisms>` — Allowed SMTP AUTH mechanisms.
- [ ] `--no-smtp-auth` — Disable SMTP authentication.
- [ ] `--smtp-user=<user>` — SMTP AUTH username.
- [ ] `--smtp-pass[=<password>]` — SMTP AUTH password.
- [ ] `--smtp-ssl-cert-path <path>` — CA certificate store for TLS validation.
- [ ] `--smtp-ssl-client-cert <path>` — Client certificate to present.
- [ ] `--smtp-ssl-client-key <path>` — Private key for the client certificate.
- [ ] `--smtp-debug=(0|1)` — Print the SMTP conversation.
- [ ] `--batch-size=<num>` — Reconnect after this many messages.
- [ ] `--relogin-delay=<int>` — Seconds to wait between batches.
- [ ] `--imap-sent-folder=<folder>` — Also copy sent mail into an IMAP folder.
- [ ] `--use-imap-only` / `--no-use-imap-only` — Copy to IMAP instead of sending via SMTP.

### Content and safety

- [ ] `--annotate` — Open each patch in an editor before sending.
- [ ] `--compose` — Write an introductory cover message in an editor.
- [ ] `--compose-encoding=<encoding>` — Charset of the composed message.
- [ ] `--8bit-encoding=<encoding>` — Charset assumed for undeclared non-ASCII content.
- [ ] `--transfer-encoding=(7bit|8bit|quoted-printable|base64|auto)` — MIME transfer encoding.
- [ ] `--confirm=<mode>` — When to prompt before sending (`always`, `never`, `cc`, `compose`, `auto`).
- [ ] `--dry-run` — Do everything except send.
- [ ] `--quiet` — Print one line per message instead of full detail.
- [ ] `--validate` / `--no-validate` — Run sanity checks (line length, encoding, `sendemail-validate` hook).
- [ ] `--force` — Send despite failed safety checks.
- [ ] `--format-patch` / `--no-format-patch` — Resolve ambiguous arguments as revisions or as files.
- [ ] `--dump-aliases` — Print the configured alias names and exit.
- [ ] `--translate-aliases` — Expand aliases read from standard input.

## `svn` — Subversion bridge

Subcommands: `init`, `fetch`, `clone`, `rebase`, `dcommit`, `branch`, `tag`,
`log`, `blame`, `find-rev`, `set-tree`, `create-ignore`, `show-ignore`,
`mkdirs`, `commit-diff`, `info`, `proplist`, `propget`, `propset`,
`show-externals`, `gc`, `reset`.

Principal options: `--shared[=…]`, `--template=<dir>`, `-r`/`--revision`,
`--stdin`, `--rmdir`, `-e`/`--edit`, `-l<num>`/`--find-copies-harder`,
`-A`/`--authors-file`, `--authors-prog`, `-q`/`--quiet`, `-m`/`--merge`,
`-s`/`--strategy`, `-p`/`--rebase-merges`, `-n`/`--dry-run`, `--use-log-author`,
`--add-author-from`, `-i`/`--id`, `-R`/`--svn-remote`, `--follow-parent`, plus a
set of config-file-only knobs (`svn.noMetadata`, `svn.useSvmProps`,
`svn-remote.<name>.rewriteRoot`, `svn.pathnameencoding`, …).

## `p4` — Perforce bridge

Subcommands: `clone`, `sync`, `rebase`, `submit`, `unshelve`, `branches`,
`rollback`.

Principal options: `--git-dir`, `-v`/`--verbose`, `--silent`, `--branch <ref>`,
`--detect-branches`, `--detect-labels`, `--import-labels`, `--export-labels`,
`--import-local`, `--changesfile <file>`, `--max-changes <n>`,
`--changes-block-size <n>`, `--keep-path`, `--use-client-spec`, `-/ <path>`,
`--destination <dir>`, `--bare`, `--origin <commit>`, `-M`, `--preserve-user`,
`-n`/`--dry-run`, `--prepare-p4-only`, `--shelve`, `--update-shelve <changelist>`,
`--conflict=(ask|skip|quit)`, `--commit <sha1>[..<sha1>]`, `--disable-rebase`,
`--disable-p4sync`.

## `cvsimport` — import CVS history

- [ ] `<CVS-module>` — Module to import.
- [ ] `-d <CVSROOT>` — CVS repository root.
- [ ] `-C <target-dir>` — Destination git repository.
- [ ] `-r <remote>` — Import branches under a remote namespace.
- [ ] `-o <branch-for-HEAD>` — Local branch name for the CVS HEAD.
- [ ] `-i` — Import only; do not check out afterwards.
- [ ] `-k` — Extract files with keyword expansion disabled.
- [ ] `-u` — Convert underscores to dots in tag and branch names.
- [ ] `-s <subst>` — Replacement for `/` in branch names.
- [ ] `-p <options>` — Extra options for `cvsps`.
- [ ] `-z <fuzz>` — Timestamp fuzz factor for changeset grouping.
- [ ] `-P <file>` — Use a saved `cvsps` output file.
- [ ] `-m` — Detect merges from commit messages.
- [ ] `-M <regex>` — Detect merges using a custom pattern.
- [ ] `-S <regex>` — Skip paths matching a pattern.
- [ ] `-a` — Import recent commits too, rather than waiting out the fuzz window.
- [ ] `-L <limit>` — Import at most this many commits.
- [ ] `-A <author-conv-file>` — Map CVS usernames to git identities.
- [ ] `-R` — Write a CVS-revision-to-commit mapping file.
- [ ] `-v` — Report progress.
- [ ] `-h` — Print usage.

## `cvsexportcommit` — export one commit to a CVS checkout

- [ ] `-c` — Commit automatically if the patch applied cleanly.
- [ ] `-p` — Apply patches with zero fuzz.
- [ ] `-a` — Add `Author`/`Committer` lines to the CVS message.
- [ ] `-d` — Use an alternative `CVSROOT`.
- [ ] `-f` — Force the export even if files are out of date.
- [ ] `-P` — Force the parent commit even when it is not a direct parent.
- [ ] `-m` — Prefix the CVS commit message.
- [ ] `-u` — Update the affected files from CVS first.
- [ ] `-k` — Reverse CVS keyword expansion before applying.
- [ ] `-w` — Path to the CVS checkout.
- [ ] `-W` — The current directory is both the git and CVS checkout.
- [ ] `-v` — Verbose.

## `cvsserver` — emulate a CVS server

- [ ] `<directory>…` — Directories that may be served.
- [ ] `--base-path <path>` — Prefix prepended to requested CVSROOTs.
- [ ] `--strict-paths` — Forbid recursion into subdirectories.
- [ ] `--export-all` — Serve repositories without checking `gitcvs.enabled`.
- [ ] `-V` / `--version` — Print version and exit.
- [ ] `-h` / `-H` / `--help` — Print usage and exit.

## `archimport` — import a GNU Arch repository

- [ ] `<archive>/<branch>` — Arch branch identifier to import.
- [ ] `-h` — Print usage.
- [ ] `-v` — Verbose output.
- [ ] `-T` — Create a tag for every imported commit.
- [ ] `-f` — Use the fast patchset import strategy.
- [ ] `-o` — Use old-style branch naming.
- [ ] `-D <depth>` — Follow merge ancestry to a given depth.
- [ ] `-a` — Auto-register unknown archives.
- [ ] `-t <tmpdir>` — Override the temporary directory.

## `imap-send` — upload patches into an IMAP folder

- [ ] `-f <folder>` / `--folder=<folder>` — Destination folder.
- [ ] `--curl` — Use libcurl for the IMAP conversation.
- [ ] `--no-curl` — Use git's built-in IMAP code.
- [ ] `--list` — List the folders on the server.
- [ ] `-v` / `--verbose` — Be verbose.
- [ ] `-q` / `--quiet` — Be quiet.

## `quiltimport` — import a quilt patch series

- [ ] `-n` / `--dry-run` — Check the series without importing.
- [ ] `--author '<Name> <email>'` — Fallback author for patches lacking one.
- [ ] `--patches <dir>` — Directory holding the patches.
- [ ] `--series <file>` — The quilt `series` file.
- [ ] `--keep-non-patch` — Keep bracketed subject prefixes other than `[PATCH]`.

## `request-pull` — generate a pull request summary

- [ ] `<start>` — Commit already present upstream.
- [ ] `<URL>` — Repository URL to pull from.
- [ ] `<end>` — Tip commit being offered; defaults to HEAD.
- [ ] `-p` — Include the patch text in the output.
