## Hooks, and the editor.
##
## Decision 1: exactly two hooks fire, `pre-commit` and `commit-msg`, and
## `commit --no-verify` bypasses both.  Nothing else in git's twenty-odd hooks
## is run -- not `pre-push`, not `post-commit`, not `update`.  A hook that
## never fires is safer than one that fires at the wrong moment, and a
## repository whose workflow depends on `prepare-commit-msg` should be using
## git.
##
## A hook is an executable file in `$GIT_DIR/hooks/`.  Non-zero exit aborts
## whatever was about to happen; stdout and stderr are the user's, inherited
## rather than captured, because a hook that prints why it refused is the whole
## point of a hook.
##
## `core.hooksPath` is honored: it costs one config lookup, and a repository
## that sets it has hooks somewhere gittle would otherwise silently skip --
## which would look like the hook passing.
##
## ## Why fork/exec rather than a shell
##
## `system("hooks/pre-commit")` would put a shell between us and the hook, and
## then a repository path containing a space becomes a quoting bug that only
## some users ever see.  `execv` takes an argument vector and has no such
## problem.  The editor is the one place a shell is *correct*, because
## `core.editor` is documented to be a shell command line ("emacs -nw", "code
## --wait"), and git runs it the same way.

import std/[os, posix]
import config, util

proc hookPath(cfg: Config, gitDir, name: string): string =
  ## The hook's file, or "" if there is nothing executable there.
  let dir = if cfg.has("core.hooksPath"): cfg.get("core.hooksPath")
            else: gitDir / "hooks"
  let path = (if isAbsolute(dir): dir else: gitDir / dir) / name
  if fileExists(path) and access(path.cstring, X_OK) == 0: path else: ""

proc runCommand(argv: openArray[string], env: openArray[(string, string)]): int =
  ## Fork, exec, wait.  The child inherits stdin, stdout and stderr untouched.
  var cargs: seq[cstring]
  for a in argv: cargs.add a.cstring
  cargs.add nil
  let pid = fork()
  failIf(pid < 0, "cannot fork: " & $strerror(errno))
  if pid == 0:
    for (k, v) in env: putEnv(k, v)
    discard execv(cargs[0], cast[cstringArray](addr cargs[0]))
    # Only reached if exec failed.  `_exit(127)` is the shell's convention for
    # "command not found", and it must not run Nim's exit handlers in a forked
    # child that shares the parent's buffers.
    quit(127)
  var status: cint
  while waitpid(pid, status, 0) < 0:
    failIf(errno != EINTR, "waiting for a hook failed: " & $strerror(errno))
  if WIFEXITED(status): int(WEXITSTATUS(status))
  else: 128 + int(WTERMSIG(status))

proc runHook*(cfg: Config, gitDir, indexFile, name: string,
              args: varargs[string]): int =
  ## Run a hook if it exists; a missing hook is a pass.
  ##
  ## `GIT_INDEX_FILE` is not a detail: a `pre-commit` hook's whole job is to
  ## inspect *what is about to be committed*, and under `commit -a` or
  ## `commit <path>` that is not the index on disk.  git points the hook at the
  ## temporary index it built, and so does this -- otherwise a linter hook
  ## silently checks the previous staged state and passes.
  let path = hookPath(cfg, gitDir, name)
  if path.len == 0: return 0
  var argv = @[path]
  for a in args: argv.add a
  runCommand(argv, {"GIT_DIR": gitDir, "GIT_INDEX_FILE": indexFile})

proc editorCommand(cfg: Config): string =
  ## git's search order (`editor.c:git_editor`): `GIT_EDITOR`, `core.editor`,
  ## `VISUAL`, `EDITOR`, then `vi`.
  for candidate in [getEnv("GIT_EDITOR"), cfg.get("core.editor"),
                    getEnv("VISUAL"), getEnv("EDITOR")]:
    if candidate.len > 0: return candidate
  "vi"

proc launchEditor*(cfg: Config, file: string) =
  ## Open `file` for editing and wait.
  ##
  ## Through `sh -c` because `core.editor` is a *command line*, not a program
  ## name: `code --wait` and `emacs -nw` both have to work.  The file is passed
  ## as a positional argument rather than interpolated, so a path with a space
  ## or a quote in it is still one argument -- which is exactly the bug
  ## interpolating it would introduce.
  let editor = editorCommand(cfg)
  failIf(editor == ":" or editor.len == 0, "no editor is configured")
  let code = runCommand(["/bin/sh", "-c", editor & " \"$@\"", editor, file], [])
  failIf(code != 0, "there was a problem with the editor '" & editor & "'")
