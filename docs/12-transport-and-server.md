# 12 — Transport endpoints and server-side helpers

> **PARTIALLY IN SCOPE.** gittle v1 is a transport client *and* a server.
> As a client, `clone`/`fetch`/`push` speak protocol v2 over ssh, spawning
> `git-upload-pack` / `git-receive-pack` on the far side, and use a direct
> object-store copy for local paths. As a server, gittle ships `upload-pack` and
> `receive-pack` so a device running only gittle can be cloned from and pushed
> to, plus `git-shell` as the restricted login shell. Dispatch is by `argv[0]`,
> so the `git-*` names are symlinks into the one binary. The HTTP and `git://`
> transports remain cut.

> **Marks** — `[x]` in scope for gittle v1 · `[ ]` out of scope · `` `[log]` `` seen in the
> agent tool-call logs (`git-tool-calls-*.md`). A section headed **CUT from v1** has every
> option out of scope; the reason follows inline. Rationale and budget: `plan.md`.


This is the file that matters most for gittle's "ssh only, minimal protocol"
constraint. Everything here is either a client half, a server half, or a
transport gittle has already decided to drop.

**Relevant to an ssh-only gittle:** `fetch-pack` + `upload-pack` (fetch), and
`send-pack` + `receive-pack` (push). The wire format they speak is documented
in `gitprotocol-pack`, `gitprotocol-v2`, `gitprotocol-common`, and
`gitprotocol-capabilities` — see `15-non-command-docs.md`.

**Droppable outright given the ssh-only decision:** `http-backend`,
`http-fetch`, `http-push`, `update-server-info` (dumb HTTP only), `daemon`
(the anonymous `git://` protocol), and `instaweb`/`gitweb`.

---

## `fetch-pack` — client half of fetch

- [ ] `<repository>` — *(core)* URL of the remote to fetch from.
- [ ] `<refs>…` — Which remote refs to fetch; all if unspecified.
- [ ] `--all` — Fetch every ref the remote advertises.
- [ ] `--stdin` — Read the ref list from standard input.
- [ ] `--upload-pack=<git-upload-pack>` / `--exec=<git-upload-pack>` — Override the remote command path.
- [ ] `--thin` — *(core)* Accept a thin pack that references objects the client already has.
- [ ] `-k` / `--keep` — Store the received data as a packfile rather than exploding it.
- [ ] `--include-tag` — Also receive annotated tags whose targets are being fetched.
- [ ] `--depth=<n>` — Request a shallow history of at most `<n>` commits.
- [ ] `--deepen-relative` — Interpret `--depth` relative to the existing shallow boundary.
- [ ] `--shallow-since=<date>` — Reshape the shallow boundary by date.
- [ ] `--shallow-exclude=<ref>` — Reshape the shallow boundary by excluding a ref's history.
- [ ] `--refetch` — Skip negotiation and request everything.
- [ ] `--check-self-contained-and-connected` — Report whether the received pack is complete on its own.
- [ ] `-q` / `--quiet` — Quiet the unpack step.
- [ ] `--no-progress` — Suppress progress reporting.
- [ ] `-v` — Run verbosely.

## `upload-pack` — server half of fetch

- [x] `<directory>` — *(core)* Repository to serve.
- [x] `--strict` / `--no-strict` — Refuse (or allow) falling back to `<directory>/.git`.
- [x] `--timeout=<n>` — Abort after `<n>` seconds of inactivity.
- [ ] `--stateless-rpc` — Do one request/response cycle, as HTTP requires.
- [ ] `--http-backend-info-refs` — Serve the HTTP `info/refs` advertisement form.

## `send-pack` — client half of push

- [ ] `<host>` — Remote host, invoking `git-receive-pack` over ssh.
- [ ] `<directory>` — *(core)* Repository on the remote to update.
- [ ] `<ref>…` — *(core)* Which refs to update.
- [ ] `--receive-pack=<git-receive-pack>` / `--exec=<git-receive-pack>` — Override the remote command path.
- [ ] `--all` — Update every locally existing head.
- [ ] `--stdin` — Read the ref list from standard input.
- [ ] `--force` — *(core)* Allow non-fast-forward updates.
- [ ] `--dry-run` — Do everything except send the updates.
- [ ] `--thin` — *(core)* Send a thin pack.
- [ ] `--atomic` — Update all refs in one transaction or none.
- [ ] `--signed` / `--no-signed` / `--signed=(true|false|if-asked)` — Send a signed push certificate.
- [ ] `--push-option=<string>` — Pass an option through to the receiver's hooks.
- [ ] `--verbose` — Run verbosely.

## `receive-pack` — server half of push

- [x] `<git-dir>` — *(core)* Repository to receive into.
- [ ] `--http-backend-info-refs` — Serve the HTTP `info/refs` advertisement form.
- [ ] `--skip-connectivity-check` — Skip verifying that the pushed objects' closure is present.

Its real interface is the hook set it runs: `pre-receive`, `update`,
`post-receive`, `post-update`, `proc-receive`, `push-to-checkout`.

## `shell` — restricted ssh login shell

- [x] `git receive-pack <argument>` / `git upload-pack <argument>` — The only commands permitted. gittle drops `git upload-archive` from the whitelist because `archive` is cut.
- [ ] `cvs server` — Additionally permitted when CVS emulation is enabled.
- [x] `-c <command> <argument>` — The form ssh uses to pass the requested command.

In scope for v1. An ssh-only server side is exactly `git-shell` plus
`upload-pack`/`receive-pack`, and nothing else. Set it as the login shell of the
git user; it permits only the two transport commands and rejects everything
else, including an interactive login.

## `upload-archive` — server half of `archive --remote`

- [ ] `<repository>` — The repository to produce an archive from.

## `daemon` — anonymous `git://` server

- [ ] `<directory>…` — Whitelist of directories the daemon will serve.
- [ ] `--base-path=<path>` — Treat requested paths as relative to a root directory.
- [ ] `--base-path-relaxed` — Retry a failed lookup without the base path.
- [ ] `--strict-paths` — Require exact path matches, without `.git` fallbacks.
- [ ] `--interpolated-path=<pathtemplate>` — Build the served path from request variables, for virtual hosting.
- [ ] `--export-all` — Serve every repository found, ignoring `git-daemon-export-ok`.
- [ ] `--user-path[=<path>]` — Permit `~user` notation in requests.
- [ ] `--inetd` — Run as an inetd service rather than a standalone listener.
- [ ] `--listen=<host-or-ipaddr>` — Bind to a specific address.
- [ ] `--port=<n>` — Listen on a non-default port.
- [ ] `--init-timeout=<n>` — Time allowed between connection and first request.
- [ ] `--timeout=<n>` — Time allowed for each sub-request.
- [ ] `--max-connections=<n>` — Concurrency limit (0 for unlimited).
- [ ] `--detach` — Daemonize.
- [ ] `--pid-file=<file>` — Write the process ID to a file.
- [ ] `--user=<user>` / `--group=<group>` — Drop privileges before serving.
- [ ] `--syslog` — Shorthand for `--log-destination=syslog`.
- [ ] `--log-destination=<destination>` — Log to `stderr`, `syslog`, or `none`.
- [ ] `--verbose` — Log connections and requested paths.
- [ ] `--reuseaddr` — Set `SO_REUSEADDR` on the listening socket.
- [ ] `--enable=<service>` / `--disable=<service>` — Turn services on or off site-wide.
- [ ] `--allow-override=<service>` / `--forbid-override=<service>` — Control per-repository service overrides.
- [ ] `--informative-errors` / `--no-informative-errors` — Trade error detail against information disclosure.
- [ ] `--access-hook=<path>` — Run an external command to authorize each request.

## `http-backend` — server side of smart HTTP

No command-line options; configured entirely through CGI environment variables
and `http.*` configuration.

## `http-fetch` — dumb HTTP client

- [ ] `<commit-id>` — Object or ref file to fetch.
- [ ] `-a` / `-c` / `-t` — Historical no-ops.
- [ ] `-v` — Report what is downloaded.
- [ ] `-w <filename>` — Write the fetched commit ID into a local ref.
- [ ] `--stdin` — Read the request list from standard input.
- [ ] `--packfile=<hash>` — Internal: fetch one packfile by hash.
- [ ] `--index-pack-arg=<arg>` — Internal: extra arguments for the `index-pack` step.
- [ ] `--recover` — Re-verify reachability after an interrupted fetch.

## `http-push` — HTTP/DAV push client

- [ ] `<ref>…` — Remote refs to update.
- [ ] `--all` — Verify the whole local object store rather than assuming the remote is complete.
- [ ] `--force` — Allow non-fast-forward updates.
- [ ] `--dry-run` — Do everything except send.
- [ ] `--verbose` — List objects walked and sent.
- [ ] `-d` / `-D` — Delete a remote ref (`-D` skips the safety checks).

## `update-server-info` — refresh dumb-HTTP metadata

- [ ] `-f` / `--force` — Rebuild the info files from scratch.
