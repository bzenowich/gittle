# git tool calls in this project's chat logs

Every `Bash` tool call that invoked `git`, extracted from all 15 session
transcripts in `~/.claude/projects/-home-bz-code-stm32/` (2026-08-19 through
2026-09-01). **324 calls.** Only the calls are recorded here, not their output.

Heredoc bodies (commit messages, note files) are elided to their first line;
everything else is verbatim, including the non-git parts of compound commands.

## Verb frequency

Counting every `git <verb>` occurrence, including repeats inside one compound command.

| verb | uses | verb | uses |
|---|---:|---|---:|
| `show` | 146 | `merge` | 5 |
| `diff` | 99 | `submodule` | 5 |
| `log` | 87 | `grep` | 5 |
| `status` | 62 | `config` | 3 |
| `add` | 44 | `fetch` | 2 |
| `commit` | 44 | `merge-tree` | 1 |
| `branch` | 26 | `for-each-ref` | 1 |
| `worktree` | 21 | `rm` | 1 |
| `checkout` | 19 | `reset` | 1 |
| `stash` | 16 | `restore` | 1 |
| `ls-tree` | 15 | `clone` | 1 |
| `merge-base` | 8 | `check-ignore` | 1 |
| `rev-list` | 7 | `remote` | 1 |
| `rev-parse` | 7 | `push` | 1 |
| `ls-files` | 7 | `describe` | 1 |

Grouped below by the *first* git verb in each call, most-used group first.

## `git show` — 88 calls

- 2026-08-18 — Read the adaptive-window estimator
```bash
git show feature/velest-new:app/velocity_aw.h; echo "===================== C ====================="; git show feature/velest-new:app/velocity_aw.c
```
- 2026-08-18 — Extract estimator and check integration
```bash
cd /tmp/claude-1000/-home-bz-code-stm32/6cdcc5e8-6728-4a3b-8eba-1e9e979342ac/scratchpad && git -C /home/bz/code/stm32 show feature/velest-new:app/velocity_aw.c > velocity_aw.c && git -C /home/bz/code/stm32 show feature/velest-new:app/velocity_aw.h > velocity_aw.h && git -C /home/bz/code/stm32 show feature/velest-new:app/motion.c | grep -n "vel_aw"
```
- 2026-08-18 — Find how branch wires in the estimator
```bash
git show feature/velest-new:app/motion.c | grep -n "vel_aw\|velocity_aw\|encvel_filt\|velctrl.actual =" | head -20
```
- 2026-08-18 — Check for conflicting writes to velctrl.actual
```bash
git show feature/velest-new:app/motion.c | sed -n '1095,1110p'; echo "=== pwm.c context ==="; git show feature/velest-new:app/pwm.c | sed -n '300,312p'
```
- 2026-08-19 — Check purr integration commit and J usage
```bash
git show --stat 15146ea | head -30; echo "=== J usage ==="; grep -rn "motor\.j\|->j\b\|0x3011, 7" app/ common/ | head
```
- 2026-08-19 — Check whether EDS is maintained alongside co_dict
```bash
git show --stat 15146ea | tail -15; echo "--- 3027 in tracked eds? ---"; grep -c "3027" puck4.eds; echo "--- eds generator? ---"; ls *.py tools/ scripts/ 2>/dev/null | head
```
- 2026-08-19 — Diff generated EDS against tracked one
```bash
diff <(git show HEAD:puck4.eds) /tmp/claude-1000/-home-bz-code-stm32/eaaef271-b542-40b5-89f6-8b0ad55fea6e/scratchpad/puck4.eds | head -60
```
- 2026-08-24 — Read firmware updates doc
```bash
git show origin/feature/september-release:FIRMWARE_UPDATES_SINCE_v4.3.2.md | head -120
```
- 2026-08-24 — Linker memory regions and log.h
```bash
SP=/tmp/claude-1000/-home-bz-code-stm32/9e7100b9-6a42-4eeb-967e-7dad1092b006/scratchpad; sed -n '1,60p' $SP/wt-sept/stm32/app_release.ld | grep -A20 MEMORY; echo "=== log.h ==="; git show origin/feature/september-release:app/log.h
```
- 2026-08-24 — Compare NV entry ordering
```bash
cd /tmp/claude-1000/-home-bz-code-stm32/9e7100b9-6a42-4eeb-967e-7dad1092b006/scratchpad && for b in base sept; do git -C /home/bz/code/stm32 show $( [ $b = base ] && echo e739da2 || echo origin/feature/september-release ):app/co_dict.c | grep -oE '\{0x[0-9A-Fa-f]{4}, *[0-9]+, *[A-Z0-9]+ *\| *[^,]*NV[^,]*,' | sed -E 's/\{(0x[0-9A-Fa-f]{4}), *([0-9]+),.*/\1:\2/' > nv-$b.txt; echo "$b NV count: $(wc -l < nv-$b.txt)"; done; echo "=== first divergence ==="; diff <(cat nv-base.txt) <(cat nv-sept.txt) | head -30
```
- 2026-08-24 — Read firmware-state doc
```bash
git show origin/feature/september-release:docs/firmware-state.md | head -100
```
- 2026-08-24 — Secure branch version and main.c
```bash
git show feature/secure-flashloader:app/version.h | grep kVersion; echo "=== main.c diff (secure) ==="; git diff e739da2 feature/secure-flashloader -- app/main.c | head -120
```
- 2026-08-24 — Check EDS object coverage
```bash
for b in origin/feature/september-release feature/secure-flashloader; do echo "=== $b ==="; git show $b:puck4.eds | grep -ciE '^\[3027' ; git show $b:puck4.eds | grep -oiE '^\[(3027|3028|3029|3015|3016|6072|6073|60E0|60E1|3008sub7|3008sub8)' | sort -u | head -20; git show $b:puck4.eds | grep -icE 'CRLF' ; done 2>&1 | head -40
```
- 2026-08-24 — Read safety.c
```bash
git show origin/feature/september-release:app/safety.c
```
- 2026-08-24 — Read K64 timing note
```bash
git show origin/feature/september-release:notes/k64-80khz-encoder-timing-fix.md | head -90
```
- 2026-08-24 — Compare pwm.c across devel/HEAD/worktrees
```bash
for r in devel HEAD; do echo "== $r =="; git show $r:app/pwm.c 2>/dev/null | grep -n "hal_enc_start_read\|^  case [0-9]" | head; done; echo "== worktrees =="; ls worktrees/ 2>/dev/null; git worktree list
```
- 2026-08-24 — Show devel case 2 encoder read
```bash
git show devel:app/pwm.c | sed -n '320,340p'
```
- 2026-08-24 — Line count of pwm.c per branch
```bash
cd /home/bz/code/stm32; for r in devel feature/september-release feature/purr origin/feature/september-release; do printf "%-38s " "$r"; git show $r:app/pwm.c 2>/dev/null | wc -l; done
```
- 2026-08-24 — Compare latency-compensation symbols devel vs september-release
```bash
cd /home/bz/code/stm32; for s in ENC_LATENCY_PWM_X2 HARVEST_DEFER lag_factor enc.est; do printf "%-22s devel=%s  sept=%s\n" "$s" \
 "$(git show devel:app/pwm.c | grep -c "$s")" \
 "$(git show feature/september-release:app/pwm.c | grep -c "$s")"; done
```
- 2026-08-24 — Inspect what the docs commit contains
```bash
cd /home/bz/code/stm32; git show --stat --oneline 4f577a5 | head
```
- 2026-08-24 — Show profiler commit stat
```bash
git show --stat 158792a
```
- 2026-08-24 — Read exectime module
```bash
git show 158792a:app/exectime.h; echo "=== EXECTIME.C ==="; git show 158792a:app/exectime.c
```
- 2026-08-24 — Show instrumentation diffs
```bash
git show 158792a -- app/pwm.c app/motion.c common/hal.h stm32/hal.c app/main.c
```
- 2026-08-24 — Copy exectime files from purr
```bash
git show 158792a:app/exectime.h > app/exectime.h && git show 158792a:app/exectime.c > app/exectime.c && ls -l app/exectime.*
```
- 2026-08-24 — Show remaining diffs
```bash
git show 158792a -- app/parse_app.c app/parse_app.h app/co_dict.c k64/hal.c test/mocks/mock_hal.c
```
- 2026-08-24 — Check committed line endings
```bash
echo "HEAD main.c CR count: $(git show HEAD:app/main.c | grep -c $'\r')"; echo "HEAD motion.c CR count: $(git show HEAD:app/motion.c | grep -c $'\r')"; echo "HEAD hal.h CR count: $(git show HEAD:common/hal.h | grep -c $'\r')"; echo "HEAD stm32/hal.c CR: $(git show HEAD:stm32/hal.c | grep -c $'\r')"
```
- 2026-08-24 — Enumerate used OD indices in HEAD
```bash
git show HEAD:app/co_dict.c | grep -oE "\{0x30[0-9A-Fa-f]{2}" | sort -u | tr -d '{' | tr '\n' ' '; echo; echo "--- 0x3028 in HEAD (pre-my-change) ---"; git show HEAD:app/co_dict.c | grep -c "{0x3028,"; git show HEAD:app/co_dict.c | grep "{0x3028," | head -2
```
- 2026-08-24 — Confirm 0x302A free and check lookup order
```bash
git show HEAD:app/co_dict.c | grep -oE "\{0x302[0-9A-Fa-f]" | sort -u; echo "--- 0x302A free? ---"; git show HEAD:app/co_dict.c | grep -c "0x302A\|0x302a"; echo "--- how does parse resolve duplicates? ---"; grep -n "hashmap_put\|hashmap_get\|co_dict\[" common/parse.c | head -8
```
- 2026-08-25 — Capture buffer in purr pwm.c
```bash
git show feature/purr:app/pwm.c | grep -n "cap_\|capture" | head -50
```
- 2026-08-25 — Purr capture hook in pwm.c
```bash
git show feature/purr:app/pwm.c | sed -n '440,500p;655,700p'
```
- 2026-08-25 — Purr log.h and log.c
```bash
git show feature/purr:app/log.h | sed -n '1,60p' && echo "=== log.c diff ===" && git diff devel...feature/purr -- app/log.c | head -80
```
- 2026-08-25 — Show stats for polarity and githash commits
```bash
git show --stat 39586cd | cat && echo "=====" && git show --stat ed8287c | cat
```
- 2026-08-25 — Show githash build-system diff
```bash
git show ed8287c -- .gitignore Makefile app/parse_app.h | cat
```
- 2026-08-25 — Show co_dict/parse_app diff for githash commit
```bash
git show ed8287c -- app/co_dict.c app/parse_app.c | cat
```
- 2026-08-25 — Show polarity diff for dict/parse/encoder
```bash
git show 39586cd -- app/co_dict.c app/parse_app.c app/parse_app.h common/encoder.h | tail -n +40 | cat
```
- 2026-08-25 — Show polarity diff for pwm.c
```bash
git show 39586cd -- app/pwm.c | tail -n +40 | cat
```
- 2026-08-25 — Show stats for the torque limit commits
```bash
git show --stat e39cd37 | cat && echo "=====" && git show --stat edd2a33 | cat
```
- 2026-08-25 — Show torque-limit code diff
```bash
git show e39cd37 -- app/co_dict.c app/motion.c app/pwm.h | tail -n +15 | cat
```
- 2026-08-25 — Show follow-up limiter diff
```bash
git show edd2a33 -- app/co_dict.c app/motion.c common/parse.c | tail -n +8 | cat
```
- 2026-08-25 — Inspect the RAM/size optimization commits
```bash
git show --stat 9a0058e | cat; echo "=========="; git show --stat ddc6955 | cat
```
- 2026-08-25 — Inspect the hashmap size reduction
```bash
git show ddc6955 -- common/hashmap.c common/hashmap.h | head -100
```
- 2026-08-25 — Inspect the ds301 context refactor
```bash
git show origin/feature/ds301:app/pwm.c | grep -n "app_ctx\|ctx->" | head -15; echo "=== app_ctx def ==="; git show origin/feature/ds301:app/control_context.h 2>/dev/null | head -50
```
- 2026-08-25 — Quantify the pwm.c divergence
```bash
echo "=== line counts of pwm.c ==="; git show HEAD:app/pwm.c | wc -l; git show origin/feature/ds301:app/pwm.c | wc -l; echo "=== diff size HEAD vs ds301 pwm.c ==="; git diff --stat HEAD origin/feature/ds301 -- app/pwm.c app/motion.c | cat; echo "=== merged pwm.c coherence ==="; echo -n "ctx-> refs: "; grep -c "ctx->" app/pwm.c; echo -n "bare motor. refs: "; grep -c "[^>]motor\." app/pwm.c
```
- 2026-08-25 — Inspect the breaking commit in full
```bash
git show 2b45b92 --stat | tail -12; echo "=== full diff ==="; git show 2b45b92 | grep -E "^[-+]" | grep -v "^[-+][-+]" | head -60
```
- 2026-08-25 — See the last working string representation
```bash
echo "=== 4e34dfe (last building) 0x1008/9/100A ==="; git show 4e34dfe:app/co_dict.c | grep -nE "0x1008|0x1009|0x100A"; echo; echo "=== 4e34dfe STR handling in parse.c ==="; git show 4e34dfe:common/parse.c | grep -n -B3 -A12 "STR" | head -40
```
- 2026-08-25 — Compare log.c between branches
```bash
wc -l app/log.c app/log.h && echo "=== purr version ===" && git show feature/purr:app/log.c | wc -l && git show feature/purr:app/log.h | wc -l && echo "=== diff stat ===" && git diff --stat HEAD feature/purr -- app/log.c app/log.h | cat
```
- 2026-08-25 — Read the purr log rewrite
```bash
git show feature/purr:app/log.h; echo "===================== log.c ====================="; git show feature/purr:app/log.c
```
- 2026-08-25 — Compare purr's capture-buffer OD block
```bash
git show feature/purr:app/co_dict.c | grep -n "0x3004"; echo "=== 0x3004 free here? ==="; grep -c "0x3004" app/co_dict.c; echo "=== purr parse handler ==="; git show feature/purr:app/parse_app.c | grep -n -A30 "parseCapture" | head -45
```
- 2026-08-25 — Read the rest of parseCapture
```bash
git show feature/purr:app/parse_app.c | sed -n '450,490p'
```
- 2026-08-25 — Read the findings worth preserving
```bash
git show HEAD:app/rl_measure.h | sed -n '30,45p;62,80p'
```
- 2026-08-25 — Review what the commit actually contains
```bash
git show --stat HEAD | tail -25
```
- 2026-08-25 — Compare parse.h both sides
```bash
cd /home/bz/code/stm32
echo "########## ds301 common/parse.h (key API) ##########"
git show feature/ds301:common/parse.h | sed -n '1,80p'
echo "########## sept common/parse.h ##########"
sed -n '1,80p' common/parse.h
```
- 2026-08-25 — Feature presence in parse.c
```bash
cd /home/bz/code/stm32
for b in feature/september-release feature/ds301; do
echo "########## $b ##########"
echo -n "parse.c lines: "; git show $b:common/parse.c | wc -l
for pat in "segment" "toggle" "1016\|ConsumerHeartbeat\|consumer" "inhibit" "EMCY\|Emcy\|emcy" "SYNC\|sync" "base64" "keybin"; do
  echo -n "  $pat: "; git show $b:common/parse.c | grep -ci "$pat"
done
done
```
- 2026-08-25 — Check hal_can_write return convention
```bash
cd /home/bz/code/stm32
echo "=== sept hal.h hal_can_write decl ==="; grep -n -B4 "hal_can_write" common/hal.h
echo "=== ds301 hal.h hal_can_write decl ==="; git show feature/ds301:common/hal.h | grep -n -B4 "hal_can_write"
echo "=== sept stm32 impl ==="; sed -n "/^.*hal_can_write/,/^}/p" stm32/hal.c | head -40
```
- 2026-08-25 — Compare hal_can_write bodies
```bash
cd /home/bz/code/stm32
echo "=== sept stm32 hal_can_write body ==="
awk '/^uint8_t hal_can_write/,/^}/' stm32/hal.c
echo "=== ds301 stm32 hal_can_write body ==="
git show feature/ds301:stm32/hal.c | awk '/^uint8_t hal_can_write/,/^}/'
```
- 2026-08-25 — Check STR usage in OD tables
```bash
cd /home/bz/code/stm32
echo "=== ds301 co_dict.c STR entries ==="; git show feature/ds301:app/co_dict.c | grep -n "STR\|0x1008\|0x100A" | head -20
echo "=== sept co_dict.c STR entries ==="; grep -n "STR\|0x1008\|0x100A" app/co_dict.c | head -20
echo "=== sept flashloader co_dict.c STR ==="; grep -n "STR" flashloader/co_dict.c | head
```
- 2026-08-25 — Find tick source
```bash
cd /home/bz/code/stm32
echo "=== sept tick fns ==="; grep -n "tick\|Tick" common/hal.h
echo "=== ds301 tick fns ==="; git show feature/ds301:common/hal.h | grep -n "tick\|Tick"
echo "=== impls ==="; grep -rn "hal_get_tick\|HAL_GetTick" stm32/hal.c k64/hal.c common/*.c app/*.c sim/*.c test/mocks/*.c 2>/dev/null | head
```
- 2026-08-25 — Find hal_get_tick implementations
```bash
cd /home/bz/code/stm32
echo "=== ds301 stm32 hal_get_tick ==="; git show feature/ds301:stm32/hal.c | awk '/hal_get_tick/,/^}/' | head -12
echo "=== ds301 k64 hal_get_tick ==="; git show feature/ds301:k64/hal.c | awk '/hal_get_tick/,/^}/' | head -12
echo "=== sept: what ms counter exists? ==="; grep -rn "SysTick_Handler\|uwTick\|HAL_IncTick\|systick" stm32/interrupts.c common/timer.c | head
```
- 2026-08-25 — Check k64 tick counter
```bash
cd /home/bz/code/stm32
echo "=== k64 hal_tick_ms in sept? ==="; grep -rn "hal_tick_ms" k64/ common/ | grep -v ksdk | head
echo "=== ds301 k64 hal_tick_ms def ==="; git show feature/ds301:k64/hal.c | grep -n "hal_tick_ms" | head
```
- 2026-08-25 — k64 tick increment site
```bash
cd /home/bz/code/stm32
git show feature/ds301:k64/hal.c | sed -n '75,95p'
echo "=== where is hal_tick_ms incremented on ds301 k64? ==="
git grep -n "hal_tick_ms" feature/ds301 -- k64/ common/
```
- 2026-08-25 — Check k64 PIT ISR rate
```bash
cd /home/bz/code/stm32
echo "=== ds301 k64/interrupts.c ==="; git show feature/ds301:k64/interrupts.c | sed -n '30,55p'
echo "=== sept k64/interrupts.c ==="; sed -n '25,55p' k64/interrupts.c
```
- 2026-08-25 — Read ds301 co_dict.c comms area
```bash
cd /home/bz/code/stm32
git show feature/ds301:app/co_dict.c | sed -n '1,110p'
```
- 2026-08-25 — Compare HashmapTest versions
```bash
cd /home/bz/code/stm32
git show feature/ds301:test/phase1/HashmapTest.cpp > /tmp/hm_ds301.cpp
diff <(git show HEAD:test/phase1/HashmapTest.cpp) /tmp/hm_ds301.cpp | head -80
echo "=== sizes ==="; wc -l /tmp/hm_ds301.cpp test/phase1/HashmapTest.cpp
```
- 2026-08-25 — Compare TimerTest coverage
```bash
cd /home/bz/code/stm32
diff <(git show HEAD:test/phase2/TimerTest.cpp | grep -oP 'TEST\(\K[^)]+') <(git show feature/ds301:test/phase2/TimerTest.cpp | grep -oP 'TEST\(\K[^)]+')
```
- 2026-08-25 — Take ds301 timer tests and mock
```bash
cd /home/bz/code/stm32
git show feature/ds301:test/phase2/TimerTest.cpp > test/phase2/TimerTest.cpp
git show feature/ds301:test/mocks/timer.c > test/mocks/timer.c
cd test && make test 2>&1 | grep -E "error|Error" | head -10
```
- 2026-08-25 — Read ds301 test fixture
```bash
cd /home/bz/code/stm32
git show feature/ds301:test/fixtures/test_co_dict.c | sed -n '1,80p'
```
- 2026-08-25 — Read ds301 cordic module
```bash
cd /home/bz/code/stm32
echo "===== stm32/cordic.h ====="; git show feature/ds301:stm32/cordic.h
echo "===== stm32/cordic.c ====="; git show feature/ds301:stm32/cordic.c
```
- 2026-08-25 — Read ds301 thermistor path
```bash
cd /home/bz/code/stm32
git show feature/ds301:stm32/hal.c | grep -n -B3 -A25 "case ADC_THERM" | head -45
```
- 2026-08-25 — Find the sa bug fix
```bash
cd /home/bz/code/stm32
git show --stat 2926329 | head -20
echo "=== sa-related hunks ==="
git show 2926329 -- app/profile.c app/motion.c | grep -n -B6 -A12 "sa" | head -60
```
- 2026-08-25 — Compare ProfileTest coverage
```bash
cd /home/bz/code/stm32
diff <(git show HEAD:test/phase1/ProfileTest.cpp | grep -oP 'TEST\(\K[^)]+') <(git show feature/ds301:test/phase1/ProfileTest.cpp | grep -oP 'TEST\(\K[^)]+')
```
- 2026-08-25 — Read the sa regression test
```bash
cd /home/bz/code/stm32
git show feature/ds301:test/phase1/ProfileTest.cpp | grep -n -B12 -A40 "ContinuityAtPeak"
```
- 2026-08-25 — Compare flashloader secure boot
```bash
cd /home/bz/code/stm32
echo "=== sept flashloader: secure boot pieces ==="
grep -rn "mbedtls\|gcm\|GCM\|RDP\|WRP" flashloader/*.c flashloader/*.h Makefile 2>/dev/null | head -15
echo
echo "=== ds301 flashloader: what tiny_aes_gcm replaces ==="
git show feature/ds301:flashloader/tiny_aes_gcm.h
echo "=== ds301 flashloader main: gcm usage ==="
git show feature/ds301:flashloader/main.c | grep -n "gcm\|GCM\|launch\|verify" | head -15
```
- 2026-08-25 — See ds301 AMMCLIB replacement
```bash
cd /home/bz/code/stm32
echo "=== ds301: what replaced AMMCLIB? ==="
git show feature/ds301:app/gains.h | head -40
echo "=== ds301 pwm.c math includes ==="
git show feature/ds301:app/pwm.c | grep -n "#include\|arm_\|inline_" | head -25
```
- 2026-08-25 — Check ds301 PI anti-windup
```bash
cd /home/bz/code/stm32
echo "=== ds301 pwm.c PI section ==="
git show feature/ds301:app/pwm.c | sed -n '225,265p'
echo "=== does ds301 ship its own arm_pid_f32? ==="
git ls-tree -r --name-only feature/ds301 -- lib/cmsis-dsp/Source | grep -i pid
git show feature/ds301:lib/cmsis-dsp/Include/dsp/controller_functions.h | grep -n -A25 "arm_pid_f32" | head -40
```
- 2026-08-26 — Read control_context.h
```bash
cd /home/bz/code/stm32
git show feature/ds301:app/control_context.h
```
- 2026-08-26 — Survey infrastructure files
```bash
cd /home/bz/code/stm32
for f in common/freestanding.c common/cmsis_sin_table.c app/config.h app/control_context.c; do
  echo "=== $f ($(git show feature/ds301:$f | wc -l) lines) ==="
done
echo "=== cmsis-dsp source files ==="
git ls-tree -r --name-only feature/ds301 -- lib/cmsis-dsp/Source
echo "=== Makefile diff (build wiring) ==="
git diff feature/september-release feature/ds301 -- Makefile | head -80
```
- 2026-08-26 — Read sin table and config.h
```bash
cd /home/bz/code/stm32
echo "===== common/cmsis_sin_table.c ====="; git show feature/ds301:common/cmsis_sin_table.c | head -50
echo "===== app/config.h ====="; git show feature/ds301:app/config.h
```
- 2026-08-26 — Validate CMSIS sin/cos
```bash
cd /home/bz/code/stm32
git show feature/ds301:test/mocks/cmsis_compiler.h > test/mocks/cmsis_compiler.h
SP=/tmp/claude-1000/-home-bz-code-stm32/6e4cf351-8522-4b47-86aa-85d55e2c1fcc/scratchpad
gcc -O2 -I lib/cmsis-dsp/Include -I lib/cmsis-dsp/PrivateInclude -I test/mocks \
    -o $SP/chk_sincos $SP/chk_sincos.c lib/cmsis-dsp/Source/ControllerFunctions/arm_sin_cos_f32.c common/cmsis_sin_table.c -lm 2>&1 | head -6
$SP/chk_sincos
```
- 2026-08-26 — Scope the impedance control port
```bash
cd /home/bz/code/stm32
git show --stat 0f8d008 | head -20
echo "=== impctrl_t ==="; git show feature/ds301:app/motion.h | grep -n -B3 -A20 "impctrl_t\|} impctrl"
```
- 2026-08-26 — Read the impedance control implementation
```bash
cd /home/bz/code/stm32
git show 0f8d008 -- app/motion.c | head -140
```
- 2026-08-26 — Compare mode enums
```bash
cd /home/bz/code/stm32
sed -n '10,45p' app/motion.h
echo "=== ds301 modes ==="; git show feature/ds301:app/motion.h | sed -n '20,50p'
```
- 2026-08-26 — Compare pwm.c structure
```bash
cd /home/bz/code/stm32
echo "sept  pwm.c: $(wc -l < app/pwm.c) lines"
echo "ds301 pwm.c: $(git show feature/ds301:app/pwm.c | wc -l) lines"
echo "sept  motion.c: $(wc -l < app/motion.c) lines"
echo "ds301 motion.c: $(git show feature/ds301:app/motion.c | wc -l) lines"
echo
echo "=== sept pwm.c: functions ==="
grep -n "^[a-zA-Z_].*(.*{$\|^static.*(.*{$" app/pwm.c | sed 's/{$//' | head -50
```
- 2026-08-26 — Compare feature coverage in pwm.c
```bash
cd /home/bz/code/stm32
echo "=== features present in sept pwm.c, absent from ds301's ==="
for feat in inject_ field_weakening fw_ cog_comp cog_cal enc_comp dither DITHER safety_ exectime purr az_acc i2t_ decoupl; do
  a=$(grep -c "$feat" app/pwm.c)
  b=$(git show feature/ds301:app/pwm.c | grep -c "$feat")
  printf "  %-18s sept=%-4s ds301=%s\n" "$feat" "$a" "$b"
done
```
- 2026-08-26 — Compare motion.c coverage
```bash
cd /home/bz/code/stm32
echo "=== sept motion.c features vs ds301's ==="
for feat in inject_ field_weakening cog_cal homing_ i2t_process motion_eval_ speed_dep derate quick_stop faultHandle; do
  a=$(grep -c "$feat" app/motion.c); b=$(git show feature/ds301:app/motion.c | grep -c "$feat")
  printf "  %-18s sept=%-4s ds301=%s\n" "$feat" "$a" "$b"
done
echo
echo "=== modes handled ==="
echo -n "  sept:  "; grep -c "void motion_eval_" app/motion.c
echo -n "  ds301: "; git show feature/ds301:app/motion.c | grep -c "void motion_eval_"
```
- 2026-08-26 — Compare mode handlers
```bash
cd /home/bz/code/stm32
echo "=== ds301 motion_eval_* definitions ==="; git show feature/ds301:app/motion.c | grep -oP "void motion_eval_\w+" | sort -u
echo "=== sept motion_eval_* definitions ==="; grep -oP "void motion_eval_\w+" app/motion.c | sort -u
```
- 2026-08-27 — Show commit 62cb9a2 details
```bash
git show --stat 62cb9a2 2>&1 | head -30; echo "===="; git log -1 --format=%B 62cb9a2
```
- 2026-08-27 — Show bus voltage overflow fix commit
```bash
git show 4ee599e 2>&1 | head -120
```
- 2026-08-27 — Show purr overlay commit
```bash
git show --stat c64e0df 2>&1 | head -20; git log -1 --format=%B c64e0df | head -30
```

## `git diff` — 64 calls

- 2026-08-06 — Review motion.c diff
```bash
git diff --stat && git diff app/motion.c
```
- 2026-08-06 — Review final diff
```bash
cd /home/bz/code/stm32 && git diff --stat && git diff app/motion.c | grep -A 14 "MODE_IDLE\|purr sample"
```
- 2026-08-06 — Show staged changes
```bash
git diff --cached --stat
```
- 2026-08-18 — Check current uncommitted changes
```bash
git diff -- app/parse_app.c app/co_dict.c app/purr_torque.h | head -60
```
- 2026-08-18 — Find velocity estimator files on branch
```bash
git diff --stat devel...feature/velest-new -- app/ common/ stm32/ | head -30; echo "=== velest files ==="; git ls-tree -r --name-only feature/velest-new -- app common | grep -i "vel"
```
- 2026-08-19 — Review the diff before committing
```bash
git diff app/pwm.c
```
- 2026-08-19 — Review the pwm.c diff
```bash
git diff -- app/pwm.c
```
- 2026-08-19 — Regenerate tracked EDS
```bash
python3 scripts/gen_eds.py -r puck4.eds -o puck4.eds 2>&1 | tail -2 && sed -i 's/^FileName=puck4.eds$/FileName=p4.eds/' puck4.eds && git diff --stat puck4.eds && git diff puck4.eds | grep -E "^[+-](FileName|SupportedObjects|4[12]=)"
```
- 2026-08-19 — Restore FileName and inspect residual diff
```bash
sed -i 's/^FileName=puck4\.eds\r$/FileName=p4.eds\r/' puck4.eds && git diff puck4.eds | grep -E "^[+-]FileName"; echo "--- remaining diff summary ---"; git diff puck4.eds | grep -E "^[+-]" | grep -vE "^[+-]{3}" | grep -E "Time=|Date="
```
- 2026-08-19 — Review final diff
```bash
git diff --stat; echo "=== pwm.c/homing.c diff ==="; git diff app/pwm.c app/homing.c
```
- 2026-08-19 — Build all targets and regenerate EDS
```bash
cd /home/bz/code/stm32 && . ./setpath && ./build.sh stm32 app release 2>&1 | grep -Ei "error|warning"; ./build.sh stm32 app debug 2>&1 | grep -Ei "error|warning"; ./build.sh k64 app release 2>&1 | grep -Ei "error:|warning:.*velkf"; echo "all builds ok"; python3 scripts/gen_eds.py -r puck4.eds -o puck4.eds 2>&1 | tail -1 && sed -i 's/^FileName=puck4\.eds\r$/FileName=p4.eds\r/' puck4.eds && git diff --stat
```
- 2026-08-19 — Diff stat
```bash
cd /home/bz/code/stm32 && git diff --stat
```
- 2026-08-24 — Diffstat of target branch side
```bash
echo "=== secure-flashloader side diffstat ==="; git diff --stat e739da2 feature/secure-flashloader
```
- 2026-08-24 — Hunk headers for pwm.c
```bash
git diff e739da2 origin/feature/september-release -- app/pwm.c | grep -E '^@@' | head -100
```
- 2026-08-24 — Diff motion.c and headers
```bash
git diff e739da2 origin/feature/september-release -- app/motion.c common/hal.h app/pwm.h app/i2t_limit.h app/log.h app/parse_app.h | head -400
```
- 2026-08-24 — Rest of motion.c diff
```bash
git diff e739da2 origin/feature/september-release -- app/motion.c | sed -n '400,700p'
```
- 2026-08-24 — Diff headers, Makefile, linker
```bash
git diff e739da2 origin/feature/september-release -- common/hal.h app/pwm.h app/faults.h app/safety.h app/parse_app.h app/version.h Makefile stm32/app_debug.ld stm32/app_release.ld
```
- 2026-08-24 — Save pwm.c diff
```bash
git diff e739da2 origin/feature/september-release -- app/pwm.c > /tmp/claude-1000/-home-bz-code-stm32/9e7100b9-6a42-4eeb-967e-7dad1092b006/scratchpad/pwm.diff; wc -l /tmp/claude-1000/-home-bz-code-stm32/9e7100b9-6a42-4eeb-967e-7dad1092b006/scratchpad/pwm.diff
```
- 2026-08-24 — OD dictionary diff
```bash
git diff e739da2 origin/feature/september-release -- app/co_dict.c | head -250
```
- 2026-08-24 — Rest of co_dict diff
```bash
git diff e739da2 origin/feature/september-release -- app/co_dict.c | sed -n '250,400p'
```
- 2026-08-24 — Diff parse_app, i2t, log, faults, main
```bash
git diff e739da2 origin/feature/september-release -- app/parse_app.c app/i2t_limit.c app/log.c app/faults.c app/main.c common/parse.c k64/peripherals.c
```
- 2026-08-24 — HAL diffs
```bash
git diff e739da2 origin/feature/september-release -- stm32/hal.c k64/hal.c | head -400
```
- 2026-08-24 — Test makefile + rl_measure header
```bash
git diff e739da2 origin/feature/september-release -- test/Makefile; echo "=== rl_measure.h head ==="; git show origin/feature/september-release:app/rl_measure.h | head -80
```
- 2026-08-24 — Target-branch app changes
```bash
git diff e739da2 feature/secure-flashloader -- app/motion.c app/co_dict.c app/parse_app.c app/pwm.h common/parse.c
```
- 2026-08-24 — Show diff stat of tracked changes
```bash
git diff --stat
```
- 2026-08-24 — Show code diff
```bash
git diff -- app/ common/ k64/ stm32/ test/ scripts/
```
- 2026-08-24 — Check eds diff, purr.c, gitignore
```bash
git diff --stat puck4.eds && head -5 purr.c && echo "---GITIGNORE---" && cat .gitignore 2>/dev/null
```
- 2026-08-24 — Inspect eds diff
```bash
git diff puck4.eds | head -60 && echo "...TAIL..." && git diff puck4.eds | grep "^-" | grep -v "^---" | head -30
```
- 2026-08-24 — Inspect eds diff removals and additions
```bash
cd /home/bz/code/stm32 && git diff -- puck4.eds | grep "^-" | grep -v "^---" | head -30; echo "===ADDED SAMPLE==="; git diff -- puck4.eds | grep "^+" | grep -v "^+++" | head -25
```
- 2026-08-24 — Show diffstat of the change
```bash
cd /home/bz/code/stm32; git diff --stat -- app/pwm.c common/hal.h k64/hal.c stm32/hal.c
```
- 2026-08-24 — Check for CRLF damage
```bash
git diff --stat app/main.c; echo "=== CR check (working tree) ==="; for f in app/main.c app/motion.c app/pwm.c app/parse_app.c app/parse_app.h app/co_dict.c common/hal.h stm32/hal.c k64/hal.c test/mocks/mock_hal.c app/exectime.c app/exectime.h; do printf "%-26s CR=%s\n" "$f" "$(grep -c $'\r' $f)"; done
```
- 2026-08-24 — Re-apply main.c edit preserving CRLF
```bash
python3 - <<'PYEOF'
p='app/main.c'
    ... [14 more lines elided]
PYEOF
git diff --stat app/main.c; echo "--- CRLF now: $(grep -c $'\r' app/main.c) ---"; git diff app/main.c | cat
```
- 2026-08-24 — Rebuild and final diffstat
```bash
./build.sh stm32 app release 2>&1 | tail -3; echo "=== final diffstat ==="; git diff --stat
```
- 2026-08-24 — Restore Makefile, map preprocessor nesting
```bash
cp /tmp/claude-1000/-home-bz-code-stm32/2cf036f0-4beb-43a4-86cd-ca7585593bd5/scratchpad/Makefile.bak Makefile && git diff --stat Makefile; echo "=== preprocessor structure, governor segment ==="
awk 'NR>=1759 && NR<=1925 && /^#(if|else|elif|endif)/{print NR": "$0}' app/pwm.c
```
- 2026-08-24 — Final tests and diffstat
```bash
./build/test_runner 2>&1 | tail -2; cd /home/bz/code/stm32
./build.sh stm32 app release 2>&1 | tail -1
echo "=== diffstat ==="; git diff --stat -- app common stm32 k64 test; echo "new: app/field_weakening.c ($(grep -c '' app/field_weakening.c) lines), app/field_weakening.h ($(grep -c '' app/field_weakening.h)), app/exectime.{c,h}"
```
- 2026-08-24 — Back up final state
```bash
B=/tmp/claude-1000/-home-bz-code-stm32/2cf036f0-4beb-43a4-86cd-ca7585593bd5/scratchpad/final
mkdir -p $B/app $B/common $B/stm32 $B/k64 $B/test/mocks $B/notes
for f in app/exectime.c app/exectime.h app/field_weakening.c app/field_weakening.h \
         app/pwm.c app/pwm.h app/main.c app/motion.c app/co_dict.c app/parse_app.c app/parse_app.h \
         common/hal.h stm32/hal.c k64/hal.c test/mocks/mock_hal.c notes/isr_timing.md; do
  cp "$f" "$B/$f"
done
echo "backed up $(find $B -type f | wc -l) files"
git diff --stat CLAUDE.md
```
- 2026-08-25 — App-level diffs in purr
```bash
git diff --stat devel...feature/purr -- app/ common/ | head -30
```
- 2026-08-25 — Check note section and final device state
```bash
SP=/tmp/claude-1000/-home-bz-code-stm32/ad3b386e-3a6b-4326-ac59-2dcd618d711b/scratchpad
sed -n '689,700p' notes/rl_identification.md; echo "=== device final state ==="
cd ~/code/p4gui/puckutility && timeout 60 ~/code/p4gui/bin/python -c "
import sys, os; sys.path.insert(0,'$SP')
import p4
net, node = p4.connect(eds='$SP/puck4-440.eds')
u=lambda i,s: int.from_bytes(node.sdo.upload(i,s),'little')
print('status=0x%04X mode=%d errreg=0x%02X pwm=%d dt=%d uvlim=%d bus=%.1fV slope=%d/%d' % (
 u(0x6041,0),u(0x6061,0),u(0x1001,0),u(0x3001,1),u(0x3001,2),u(0x2384,7),u(0x3000,1)/10.0,u(0x3008,7),u(0x3009,7)))
net.disconnect()" 2>&1 | tail -2; echo "=== diff stat ==="; git diff --stat app/ stm32/
```
- 2026-08-25 — Clean up note and show the code diff
```bash
python3 - <<'PYEOF'
p = "notes/rl_identification.md"
    ... [33 more lines elided]
PYEOF
git --no-pager diff --stat -- app/ stm32/; echo; git --no-pager diff -- app/faults.h app/motion.c | grep -E "^[-+]" | grep -v "^[-+][-+]" | head -30
```
- 2026-08-25 — Review the hal.c diff
```bash
git --no-pager diff -- stm32/hal.c
```
- 2026-08-25 — Review Makefile diff
```bash
git diff Makefile | cat
```
- 2026-08-25 — Review pwm.c diff
```bash
git diff app/pwm.c | cat
```
- 2026-08-25 — Apply the limiters in motion_trq_control
```bash
python3 - <<'PYEOF'
p='app/motion.c'; s=open(p,newline='').read()
    ... [51 more lines elided]
PYEOF
git diff app/motion.c | cat
```
- 2026-08-25 — Revert the motor_t additions
```bash
python3 - <<'PYEOF'
# Back out the motor_t members: they cannot carry a section attribute.
    ... [8 more lines elided]
PYEOF
git diff --stat app/pwm.h | cat
```
- 2026-08-25 — Count conflict hunks per file
```bash
for f in $(git diff --name-only --diff-filter=U); do n=$(grep -c '^<<<<<<<' "$f" 2>/dev/null || echo 0); l=$(wc -l < "$f"); echo "$n hunks  ($l lines)  $f"; done | sort -rn
```
- 2026-08-25 — Remove the last orphaned sine helper
```bash
cd ~/code/p4gui/pucktuner && python3 - <<'PYEOF'
p='file_menu.py'; lines=open(p).read().split('\n')
    ... [7 more lines elided]
PYEOF
~/code/p4gui/bin/python -m py_compile file_menu.py && echo COMPILE_OK && timeout 200 ~/code/p4gui/bin/python -m unittest test_rl_identify -q 2>&1 | tail -3 && git -C . diff --stat
```
- 2026-08-25 — Inspect the CLAUDE.md diff
```bash
cd ~/code/stm32 && git diff CLAUDE.md
```
- 2026-08-25 — Per-file diffstat of source dirs
```bash
cd /home/bz/code/stm32
git diff --stat feature/september-release feature/ds301 -- app common stm32 k64 flashloader test | cat
```
- 2026-08-25 — Measure conflict region sizes
```bash
SP=/tmp/claude-1000/-home-bz-code-stm32/6e4cf351-8522-4b47-86aa-85d55e2c1fcc/scratchpad
cd $SP/trial
for f in $(git diff --name-only --diff-filter=U); do
  tot=$(wc -l < $f)
  inconf=$(awk '/^<<<<<<</{c=1} c{n++} /^>>>>>>>/{c=0} END{print n+0}' $f)
  printf "%-32s total=%-6s conflicted=%s\n" "$f" "$tot" "$inconf"
done
```
- 2026-08-25 — Diff parse.h
```bash
cd /home/bz/code/stm32
git diff feature/september-release feature/ds301 -- common/parse.h | cat
```
- 2026-08-25 — co_dict.h and hashmap.h diffs
```bash
cd /home/bz/code/stm32
echo "########## co_dict.h diff ##########"
git diff feature/september-release feature/ds301 -- common/co_dict.h | cat
echo "########## hashmap.h diff ##########"
git diff feature/september-release feature/ds301 -- common/hashmap.h | cat
```
- 2026-08-25 — hashmap.c diff
```bash
cd /home/bz/code/stm32
git diff feature/september-release feature/ds301 -- common/hashmap.c | cat
```
- 2026-08-25 — Convert hashmap to uint32 keys
```bash
cd /home/bz/code/stm32
python3 - <<'EOF'
import re
    ... [89 more lines elided]
EOF
git diff --stat common/hashmap.c common/hashmap.h
```
- 2026-08-25 — Widen OD storage to uintptr_t
```bash
cd /home/bz/code/stm32
sed -i \
 -e 's/int32_t (\*doFunc)(struct co_data_struct \*data, uint32_t \*value, bool isWrite);/int32_t (*doFunc)(struct co_data_struct *data, uintptr_t *value, bool isWrite);/' \
 -e 's/^\(\s*\)uint32_t def;/\1uintptr_t def;/' \
 -e 's/^\(\s*\)uint32_t value;/\1uintptr_t value;/' \
 -e 's/^\(\s*\)uint32_t shadow;/\1uintptr_t shadow;/' \
 common/co_dict.h test/mocks/co_dict.h
git diff --stat common/co_dict.h; diff <(git show HEAD:test/mocks/co_dict.h) test/mocks/co_dict.h
```
- 2026-08-25 — Full parse.c diff
```bash
cd /home/bz/code/stm32
git diff feature/september-release feature/ds301 -- common/parse.c | cat
```
- 2026-08-25 — Timer diff
```bash
cd /home/bz/code/stm32
git diff feature/september-release feature/ds301 -- common/timer.h common/timer.c | cat
```
- 2026-08-25 — Apply timer context param
```bash
cd /home/bz/code/stm32
python3 - <<'PY'
import re
    ... [15 more lines elided]
PY
git diff --stat common/timer.c common/timer.h
```
- 2026-08-25 — Profile diff
```bash
cd /home/bz/code/stm32
git diff feature/september-release feature/ds301 -- app/profile.c app/profile.h | cat
```
- 2026-08-26 — Review CSV diff
```bash
git diff --stat && echo === && sed -n '/RPDO3 COB ID/,+5p;/Synchronised purring/,+30p' p4-42-lfm-purr.csv
```
- 2026-08-26 — Review motion.c and hal.c diff
```bash
git diff app/motion.c stm32/hal.c | head -160
```
- 2026-08-26 — Fix comment, rebuild
```bash
python3 - <<'PYEOF'
p='stm32/hal.c'
    ... [8 more lines elided]
PYEOF
./build.sh stm32 app debug 2>&1 | tail -1 && git diff --stat
```
- 2026-08-27
```bash
grep -n "bin" .gitignore; rm -f puck4.flashloader.stm32.release.*.bin; echo "--- diff ---"; git diff
```
- 2026-08-27 — Show uncommitted diff stat
```bash
git diff --stat 2>&1 | tail -20
```
- 2026-08-31 — Show final diff
```bash
cd /home/bz/code/stm32 && file app/motion.c && git diff --stat app/motion.c && git diff app/motion.c
```

## `git add` — 39 calls

- 2026-08-06 — Stage purr integration files
```bash
git add app/co_dict.c app/motion.c app/motion.h app/parse_app.c app/parse_app.h app/purr_torque.c app/purr_torque.h puck4.eds p4-42-lfm-purr.csv && git status --short --cached
```
- 2026-08-19 — Stage pwm.c
```bash
git -C /home/bz/code/stm32 add app/pwm.c && git -C /home/bz/code/stm32 diff --staged --stat
```
- 2026-08-19 — Stage the estimator work
```bash
cd /home/bz/code/stm32 && git add app/velkf.c app/velkf.h app/co_dict.c app/homing.c app/motion.c app/motion.h app/parse_app.c app/parse_app.h app/pwm.c app/pwm.h puck4.eds test/Makefile test/phase1/VelKfTest.cpp && git status --short
```
- 2026-08-19 — Commit the NIS fix
```bash
cd /home/bz/code/stm32 && git add -u app test && git status --short | grep -v "^??" && git commit -q -F - <<'EOF'
Score the estimator's NIS before the innovation deadband
    ... [23 more lines elided]
EOF
git log --oneline -2
```
- 2026-08-19 — Commit the overlay rejection
```bash
git add app puck4.eds test/phase1/VelKfTest.cpp && git commit -q -F - <<'EOF'
Stop the servo fighting the purr overlay it injected
    ... [49 more lines elided]
EOF
git log --oneline -3
```
- 2026-08-19 — Stage changed files
```bash
git add app/co_dict.c app/parse_app.c app/parse_app.h app/pwm.c common/encoder.h && git status --short
```
- 2026-08-24 — Stage feature files
```bash
git add app/exectime.c app/exectime.h app/co_dict.c app/main.c app/motion.c app/parse_app.c app/parse_app.h app/pwm.c common/hal.h k64/hal.c stm32/hal.c test/mocks/mock_hal.c scripts/gen_eds.py puck4.eds && git status --short --untracked-files=no
```
- 2026-08-24 — Stage the change
```bash
cd /home/bz/code/stm32; git add app/pwm.c common/hal.h k64/hal.c stm32/hal.c docs/validation-since-v4.3.2.md && git status --short --untracked-files=no
```
- 2026-08-24 — Commit doc reconciliation
```bash
cd /home/bz/code/stm32; git add FIRMWARE_UPDATES_SINCE_v4.3.2.md notes/review-sept-into-secure.md && git commit -F - <<'EOF'
docs: reconcile the encoder-latency notes with 8917062
    ... [26 more lines elided]
EOF
```
- 2026-08-24 — Verify tests and stage commit 1
```bash
cd /home/bz/code/stm32/test && ./build/test_runner 2>&1 | tail -1; cd /home/bz/code/stm32
git add app/exectime.c app/exectime.h app/co_dict.c app/main.c app/motion.c \
        app/parse_app.c app/parse_app.h app/pwm.c common/hal.h k64/hal.c stm32/hal.c \
        test/mocks/mock_hal.c notes/isr_timing.md
git status --short | grep -v "^??\|^ M CLAUDE"
```
- 2026-08-24 — Stage commit 2
```bash
git add app/field_weakening.c app/field_weakening.h app/pwm.c app/pwm.h app/motion.c app/main.c app/co_dict.c app/exectime.h notes/isr_timing.md
git status --short | grep -v "^??\|CLAUDE"; echo "=== diffstat for commit 2 ==="; git diff --cached --stat
```
- 2026-08-25 — Stage the source fixes and the design note
```bash
git add app/faults.h app/motion.c stm32/hal.c notes/rl_identification.md && git status --short -- app/faults.h app/motion.c stm32/hal.c notes/rl_identification.md CLAUDE.md
```
- 2026-08-25 — Commit the git hash feature
```bash
git add .gitignore Makefile app/co_dict.c && git commit -q -F - <<'EOF'
Stamp the commit the binary was built from at 0x3003
    ... [17 more lines elided]
EOF
git log --oneline -1 | cat
```
- 2026-08-25 — Commit the u_polarity fixes
```bash
git add app/co_dict.c app/parse_app.c app/parse_app.h app/pwm.c common/encoder.h && git commit -q -F - <<'EOF'
Apply user polarity to the torque command, not just the feedback
    ... [48 more lines elided]
EOF
git log --oneline -2 | cat; git status --short | head -3
```
- 2026-08-25 — Commit the torque-limiter work
```bash
git add app/co_dict.c app/motion.c app/pwm.h && git commit -q -F - <<'EOF'
DS402 torque and current limits: 0x6072, 0x6073, 0x60E0, 0x60E1
    ... [31 more lines elided]
EOF
git log --oneline -3 | cat
```
- 2026-08-25 — Commit the RAM fix and clean up the worktree
```bash
cd /home/bz/code/stm32 && git add app/co_dict.c && git commit -q -F - <<'EOF'
hashmap: stop reserving 8 bytes per bucket on a 32-bit target
    ... [26 more lines elided]
EOF
git log --oneline -1 | cat; git worktree remove --force /tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/ds301 2>&1 | tail -1
```
- 2026-08-25 — Commit the ds301 build fix
```bash
cd /tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/ds301 && git add app/co_dict.c app/parse_app.c common/hal.h k64/hal.c k64/interrupts.c stm32/hal.c && git commit -q -F - <<'EOF'
Fix the build: string storage, stale externs, and hal_get_tick
    ... [39 more lines elided]
EOF
git log --oneline -1 | cat
```
- 2026-08-25 — Commit the logger rewrite
```bash
git add app/log.c app/log.h app/pwm.c app/motion.c app/co_dict.c app/parse_app.c app/parse_app.h common/parse.c && git commit -q -F - <<'EOF'
log: bounded capture buffer in CCMSRAM, and an alpha/beta source
    ... [76 more lines elided]
EOF
git log --oneline -1 | cat
```
- 2026-08-25 — Verify and commit the integrator fix
```bash
cd /home/bz/code/stm32/test && make -s >/dev/null 2>&1 && ./build/test_runner 2>&1 | tail -2; git add app/pwm.c && git commit -q -F - <<'EOF'
rl: truncate the R integrator toward zero on both signs
    ... [21 more lines elided]
EOF
git log --oneline -1 | cat
```
- 2026-08-25 — Commit the integrator fix from the repo root
```bash
cd /home/bz/code/stm32 && git add app/pwm.c && git commit -q -F - <<'EOF'
rl: truncate the R integrator toward zero on both signs
    ... [21 more lines elided]
EOF
git log --oneline -6 | cat
```
- 2026-08-25 — Commit the fix and the design sketch
```bash
git add app/parse_app.c && git commit -q -F - <<'EOF'
log: step response reads the function parameter, not the entry count
    ... [12 more lines elided]
EOF
git add notes/rl_identification.md && git commit -q -F - <<'EOF'
notes: sketch the 0x3015 injection primitive interface
    ... [18 more lines elided]
EOF
git log --oneline -3 | cat
```
- 2026-08-25 — Commit the FW relocation
```bash
./build/test_runner 2>&1 | tail -1; cd /home/bz/code/stm32 && git add app/co_dict.c app/field_weakening.c && git commit -q -F - <<'EOF'
fw: give characterisation its own index at 0x3017
    ... [30 more lines elided]
EOF
git log --oneline -1 | cat
```
- 2026-08-25 — Commit the excision
```bash
git add -A app/ notes/ && git status --short | head -12 && git commit -q -F - <<'EOF'
rl: replace the firmware R/L measurement with an injection primitive
    ... [75 more lines elided]
EOF
git log --oneline -1 | cat
```
- 2026-08-25 — Commit the handoff note
```bash
python3 - <<'PYEOF'
p='notes/rl_identification.md'; s=open(p,newline='').read()
    ... [15 more lines elided]
PYEOF
git add notes/rl_identification.md notes/sysid_handoff.md notes/p4gui/sysid_additions.py && git commit -q -F - <<'EOF'
notes: session handoff for the section 7 host work
    ... [23 more lines elided]
EOF
git log --oneline -1 | cat
```
- 2026-08-25 — Commit CLAUDE.md
```bash
cd ~/code/stm32 && git add CLAUDE.md && git commit -q -F - <<'EOF'
docs: record how to run the unit tests, and what test/cpputest is
    ... [14 more lines elided]
EOF
git log --oneline -1
```
- 2026-08-25 — Commit firmware and notes in stm32
```bash
cd ~/code/stm32 && git add app/inject.h app/inject.c app/co_dict.c app/parse_app.c && git commit -q -F - <<'EOF'
fw: publish the injection's commanded axis voltage at 0x3015,10
    ... [15 more lines elided]
EOF
git add notes/rl_identification.md notes/sysid_handoff.md notes/p4gui && git commit -q -F - <<'EOF'
notes: section 7 is done; record where each item landed
    ... [22 more lines elided]
EOF
git log --oneline -3 && git status --short app/ notes/rl_identification.md notes/sysid_handoff.md
```
- 2026-08-25 — Commit the p4gui numerical core
```bash
cd ~/code/p4gui && git add sysid.py test/test_sysid.py && git commit -q -F - <<'EOF'
sysid: add the numerical core for the excised R/L measurement
    ... [32 more lines elided]
EOF
git log --oneline -1
```
- 2026-08-25 — Commit the p4gui device layer and GUI
```bash
cd ~/code/p4gui && git add sysid_device.py test/fake_puck.py test/test_sysid_device.py puck4.eds && git commit -q -F - <<'EOF'
sysid_device: drive R and L through the 0x3015 injection primitive
    ... [46 more lines elided]
EOF
git add identify_tab.py test/test_identify_tab.py && git commit -q -F - <<'EOF'
identify: report the R diagnostics, and add a saliency measurement
    ... [16 more lines elided]
EOF
git log --oneline -3 && git status --short | grep -v pucktuner
```
- 2026-08-25 — Commit the pucktuner autotune migration
```bash
cd ~/code/p4gui/pucktuner && git add file_menu.py && git commit -q -F - <<'EOF'
autotune: measure R and L through the injection primitive
    ... [43 more lines elided]
EOF
git log --oneline -2 && git status --short
```
- 2026-08-25 — Commit the CANopen layer port
```bash
cd /home/bz/code/stm32
cat > notes/ds301_port_progress.md <<'EOF'
# Porting feature/ds301 into feature/september-release
    ... [92 more lines elided]
EOF
git add -A app common stm32 k64 flashloader test sim notes/ds301_port_progress.md
git commit -q -m "$(cat <<'MSG'
ds301: port the CANopen/DS301 layer onto september-release
    ... [25 more lines elided]
MSG
)"
git log --oneline -1
```
- 2026-08-25 — Commit SDO tests and mock fix
```bash
cd /home/bz/code/stm32
python3 - <<'PY'
p='notes/ds301_port_progress.md'; s=open(p).read()
    ... [27 more lines elided]
PY
git add -A test notes && git commit -q -m "$(cat <<'MSG'
ds301: cover the segmented SDO server, and fix the CAN mock's return sense
    ... [18 more lines elided]
MSG
)"
git log --oneline -2
```
- 2026-08-25 — Commit CORDIC thermistor
```bash
cd /home/bz/code/stm32
python3 - <<'PY'
p='notes/ds301_port_progress.md'; s=open(p).read()
    ... [31 more lines elided]
PY
git add -A stm32 notes && git commit -q -m "$(cat <<'MSG'
ds301: compute the thermistor's logarithm on the CORDIC
    ... [27 more lines elided]
MSG
)"
git log --oneline -3
```
- 2026-08-25 — Commit profile test
```bash
cd /home/bz/code/stm32
git add -A test notes && git commit -q -m "$(cat <<'MSG'
ds301: port the triangular-profile continuity test
    ... [9 more lines elided]
MSG
)"
git log --oneline -4
```
- 2026-08-26 — Commit the 0x100A change
```bash
cd /home/bz/code/stm32
python3 - <<'PY'
p='notes/ds301_port_progress.md'; s=open(p).read()
    ... [45 more lines elided]
PY
git add -A app common test notes && git commit -q -m "$(cat <<'MSG'
ds301: publish 0x100A as a VISIBLE_STRING
    ... [18 more lines elided]
MSG
)"
git log --oneline -5
```
- 2026-08-26 — Commit CMSIS-DSP infrastructure
```bash
cd /home/bz/code/stm32
python3 - <<'PY'
p='notes/ds301_port_progress.md'; s=open(p).read()
    ... [38 more lines elided]
PY
git add -A lib common app stm32 k64 sim test Makefile notes
git commit -q -m "$(cat <<'MSG'
ds301: land the CMSIS-DSP subset and route sin/cos through the HAL
    ... [27 more lines elided]
MSG
)"
git log --oneline -6 && git status --short | grep -v '^??' | head
```
- 2026-08-26 — Commit impedance control
```bash
cd /home/bz/code/stm32
python3 - <<'PY'
p='notes/ds301_port_progress.md'; s=open(p).read()
    ... [44 more lines elided]
PY
git add -A app notes && git commit -q -m "$(cat <<'MSG'
ds301: port impedance control mode
    ... [26 more lines elided]
MSG
)"
git log --oneline -8
```
- 2026-08-26 — Record the finding
```bash
cd /home/bz/code/stm32
python3 - <<'PY'
p='notes/ds301_port_progress.md'; s=open(p).read()
    ... [63 more lines elided]
PY
git add -A notes && git commit -q -m "$(cat <<'MSG'
notes: record why the pwm.c/motion.c conversion is not a port
    ... [15 more lines elided]
MSG
)"
git log --oneline feature/september-release..HEAD | cat
```
- 2026-08-26 — Stage the change
```bash
git add app/clockcal.c app/clockcal.h test/phase1/ClockcalTest.cpp DEBUGGING.md app/co_dict.c app/main.c app/motion.c app/motion.h app/parse_app.c app/parse_app.h common/hal.h common/parse.c k64/hal.c k64/interrupts.c notes/FDCAN_CLOCK_CALIBRATION.md notes/purr.md p4-42-lfm-purr.csv stm32/hal.c test/Makefile test/mocks/mock_hal.c test/mocks/mock_hal.h && git status --short | grep -v "^??"
```
- 2026-08-27
```bash
git add .gitlab-ci.yml Makefile && git commit -q -F - <<'EOF' && git log --oneline -1 && git status -sb | head -2
Point CI at the per-configuration object tree, and let make name the binary
    ... [12 more lines elided]
EOF
```

## `git log` — 27 calls

- 2026-08-06 — Check git state
```bash
git log --oneline -3 && git status --short | head -30
```
- 2026-08-06 — Verify commit
```bash
git log --oneline -3; echo "=== left untracked ==="; git status --short -- purr.c
```
- 2026-08-18 — Inspect velest-new branch
```bash
git log --oneline devel..feature/velest-new 2>/dev/null | head -20; echo "=== diff stat vs devel ==="; git diff --stat devel...feature/velest-new 2>/dev/null | tail -20
```
- 2026-08-19 — Verify commit
```bash
git log --oneline -3 && git status --short -- app/
```
- 2026-08-19 — Explore p4gui directory
```bash
cd ~/code/p4gui && ls -la && echo "=== git ===" && git log --oneline -5 2>/dev/null | head
```
- 2026-08-24 — List incoming commits and diffstat
```bash
echo "=== 41 commits incoming ==="; git log --oneline --no-decorate origin/feature/september-release ^feature/secure-flashloader; echo; echo "=== diffstat merge-base..september ==="; git diff --stat e739da2 origin/feature/september-release
```
- 2026-08-24 — Check kick presence per worktree and origin commit
```bash
for w in kalman-ls ls-filter purr-reject wd307; do printf "%-12s " $w; grep -c "hal_enc_start_read" worktrees/$w/app/pwm.c 2>/dev/null || echo "n/a"; done; echo "--- introduced by ---"; git log --oneline -1 -S"hal_enc_start_read" -- app/pwm.c
```
- 2026-08-24 — Recent commit history
```bash
git log --oneline -20 --format='%h %ad %s' --date=short
```
- 2026-08-24 — Read key commit messages
```bash
git log --format='%h%n%B%n-----' -1 7999a6f 4441c0e f7b5290 3fca49b 0557460 8917062 2>/dev/null | head -200
```
- 2026-08-24 — Read key commit messages
```bash
for h in 7999a6f 4441c0e f7b5290 3fca49b 0557460 d4b7281; do git log --format='=== %h %s%n%b' -1 $h; done | head -220
```
- 2026-08-24 — Search all branches for flashp4.py
```bash
git log --all --oneline --name-only --diff-filter=A 2>/dev/null | grep -i "flashp4" | head; echo "--- any branch tree ---"; for b in $(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes); do git ls-tree -r --name-only $b 2>/dev/null | grep -i flashp4 | sed "s|^|$b: |"; done | head
```
- 2026-08-24 — Identify which ISR blocks are new since devel
```bash
git log --oneline devel..HEAD -- app/pwm.c | wc -l; echo "=== case-2/3 blocks: new since devel? ==="
for pat in "correct_pos" "cog_comp" "cog_cal" "DEADTIME_COMP" "hal_enc_harvest_read" "ENC_LATENCY_PWM_X2" "AUTOZERO_AT_ENABLE" "AW_SAT_FREEZE" "rl_phase"; do
  n=$(git show devel:app/pwm.c 2>/dev/null | grep -c "$pat")
  m=$(grep -c "$pat" app/pwm.c)
  printf "%-24s devel=%-4s sept=%-4s %s\n" "$pat" "$n" "$m" "$([ "$n" = "0" ] && echo '<-- NEW in september-release')"
done
```
- 2026-08-25 — Diff stat purr vs devel
```bash
git log --oneline devel..feature/purr | wc -l && git diff --stat devel...feature/purr | tail -30
```
- 2026-08-25 — List commits on feature/purr not in devel
```bash
git log --oneline devel..feature/purr | cat
```
- 2026-08-25 — List commits on current branch and merge base
```bash
git log --oneline devel..HEAD | cat && echo "--- merge-base ---" && git merge-base --all HEAD feature/purr
```
- 2026-08-25 — Search purr commits for polarity and githash
```bash
git log --oneline devel..feature/purr --all --grep='polarity' -i | cat && echo "=== githash grep ===" && git log --oneline devel..feature/purr -i --grep='hash\|commit\|stamp' | cat
```
- 2026-08-25 — Quantify the divergence
```bash
echo "=== merge-base info ==="; git log --oneline -1 f7bd91cd4d54561ad39b458d2910e97e29eacc16 | cat; echo; echo "=== commits on HEAD since merge-base: ==="; git rev-list --count f7bd91c..HEAD; echo "=== commits on ds301 since merge-base: ==="; git rev-list --count f7bd91c..origin/feature/ds301; echo; echo "=== files changed on ds301 ==="; git diff --stat f7bd91c origin/feature/ds301 | tail -30
```
- 2026-08-25 — Read ds301 commit messages
```bash
git log --reverse --format='=== %h %s%n%b' f7bd91c..origin/feature/ds301 | head -120
```
- 2026-08-25 — Trace the string storage across ds301 commits
```bash
for c in 4e34dfe 4b51823 15a7f68 69f30ba 2b45b92; do echo "=== $c $(git log --format=%s -1 $c | cut -c1-45) ==="; git show $c:app/co_dict.c | sed -n '10,20p'; done
```
- 2026-08-25 — Locate rl_identification notes
```bash
ls notes/ | head -30; echo "=== rl_identification ==="; ls -la notes/rl_identification.md 2>&1; git log --all --oneline -- notes/rl_identification.md 2>/dev/null | head
```
- 2026-08-25 — Unstage the unrelated notes files
```bash
git log -1 --format=%B > /tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/msg.txt && git reset -q --soft HEAD~1 && git restore --staged notes/150ma-ramp.png notes/FW-v34-42V.png notes/GL40_sweep_discretized_feedback.png notes/PDO_DataLogging.py notes/deadzone.png notes/gl40.csv notes/k64_improvements.md notes/motion_control_timing.md notes/oscillator2.png notes/solved_problems.md notes/stair.png notes/star_topology.md notes/validate.md && git status --short | grep -v "^??"
```
- 2026-08-25 — Final build verification
```bash
for t in "stm32 app debug" "stm32 app release" "k64 app debug" "k64 app release"; do rm -f build/puck4.axf; ./build.sh $t >/dev/null 2>&1; [ -f build/puck4.axf ] && echo "OK   $t" || echo "FAIL $t"; done; echo; git log --oneline -5 | cat
```
- 2026-08-25 — List ds301 commits
```bash
cd /home/bz/code/stm32
echo "=== 25 commits on ds301 (oldest first) ==="
git log --oneline --reverse feature/september-release..feature/ds301
echo
echo "=== is 6c046bf an ancestor of merge-base? ==="
git merge-base --is-ancestor 6c046bf f7bd91c && echo YES || echo NO
echo "=== 6c046bf date/branch position ==="
git log --oneline -1 --date=short --format='%h %ad %s' 6c046bf
```
- 2026-08-25 — Baseline size in trial worktree
```bash
SP=/tmp/claude-1000/-home-bz-code-stm32/6e4cf351-8522-4b47-86aa-85d55e2c1fcc/scratchpad
cd $SP/trial && git log --oneline -1 && rm -rf build && ./build.sh stm32 app release >/dev/null 2>&1
OD=/home/bz/code/stm32/toolchain/arm-none-eabi/arm-none-eabi-objdump
echo "=== september-release baseline ==="; $OD -h build/puck4.axf | awk '$2==".text"||$2==".data"||$2==".bss"{print $2, $3}'
```
- 2026-08-26 — Survey repo for purr/0x3027 references
```bash
ls && git log --oneline -5 && grep -rn "3027" --include=*.c --include=*.h --include=*.csv --include=*.md -l | head -50
```
- 2026-08-27
```bash
git log --oneline -1 -S 'BUILD_DIR := build/$(BUILD_TARGET)-$(BUILD_APP)-$(BUILD_TYPE)' -- Makefile; echo "--- devel Makefile BUILD_DIR:"; git show devel:Makefile | grep -n "BUILD_DIR :=" ; echo "--- devel ci axf refs:"; git show devel:.gitlab-ci.yml | grep -n "axf\|update-section"; echo "--- merge-base:"; git merge-base --is-ancestor devel HEAD && echo "devel is ancestor of HEAD"
```
- 2026-08-27 — Show commits since bbbae
```bash
git log --oneline bbbae..HEAD 2>&1 | head -50; echo "---"; git log --oneline -1 bbbae 2>&1
```

## `git status` — 20 calls

- 2026-08-06 — Check status of relevant paths
```bash
git status --short -- app/ puck4.eds p4-42-lfm-purr.csv purr.c notes/purr.md; echo "=== branch ==="; git branch --show-current
```
- 2026-08-18 — Check working tree state
```bash
git status --short | head; echo "=== log ==="; git log --oneline -2
```
- 2026-08-19 — Diagnose git state
```bash
git status; echo "=== plain diff stat ==="; git diff --stat; echo "=== staged ==="; git diff --staged --stat
```
- 2026-08-24 — Check git status and branch
```bash
git status --short && echo "---BRANCH---" && git branch --show-current && echo "---LOG---" && git log --oneline -5
```
- 2026-08-24 — List newest bin and status
```bash
ls -t *.bin | head -3; git status --short app/ common/ stm32/ k64/ test/mocks/
```
- 2026-08-24 — Final diffstat
```bash
git status --short | grep -v "^??" ; echo "=== diffstat ==="; git diff --stat; echo "=== new files ==="; ls -l app/exectime.c app/exectime.h
```
- 2026-08-24 — Write notes and finalize tree
```bash
cat > notes/isr_timing.md <<'EOF'
# PWM ISR / motion_control execution time — measured 2026-08-24
    ... [67 more lines elided]
EOF
sed -i 's/#define EXECTIME_CASE4_DETAIL 0/#define EXECTIME_CASE4_DETAIL 0   \/\/ 1 = add the 6 case-4 sub-stamps (+0.49 us each)/' app/exectime.h
./build.sh stm32 app release 2>&1 | tail -1; git status --short | grep -v "^??"
```
- 2026-08-24 — Record results and final verification
```bash
cat >> notes/isr_timing.md <<'EOF'

    ... [64 more lines elided]
EOF
git status --short | grep -v "^??"; echo "=== final verification ==="
./build.sh stm32 app release 2>&1 | grep -cE "error"; ./build.sh k64 app release 2>&1 | grep -cE "error"
cd test && make >/dev/null 2>&1 && ./build/test_runner 2>&1 | tail -1
```
- 2026-08-24 — Trim notes and check status
```bash
cd test && make >/dev/null 2>&1 && ./build/test_runner 2>&1 | tail -1; cd /home/bz/code/stm32
python3 - <<'PYEOF'
# notes/isr_timing.md: first half only for commit 1
    ... [4 more lines elided]
PYEOF
git status --short | grep -v "^??"; echo "--- untracked of mine ---"; git status --short | grep "^??" | grep -E "exectime|field_weakening|isr_timing"
```
- 2026-08-25 — Locate the freshly built binary
```bash
ls -la puck4.app.stm32.release.bf2e9b5*.bin 2>/dev/null; git status --short app/ stm32/ | head; echo "=== newest bin ==="; ls -t puck4.app.stm32.release.*.bin | head -3
```
- 2026-08-25 — Check working tree state before committing
```bash
git status --short | head -20; echo "=== branch ==="; git branch --show-current; echo "=== is puck4.eds / bins tracked? ==="; git ls-files --error-unmatch puck4.app.stm32.release.bf2e9b5.bin 2>&1 | head -2
```
- 2026-08-25 — Verify line endings and changed files
```bash
file app/pwm.c app/parse_app.c app/co_dict.c common/encoder.h Makefile .gitignore | grep -i crlf; echo "no CRLF above = ok"; git status --short -- Makefile .gitignore app/ common/
```
- 2026-08-25 — Verify everything is committed
```bash
git status --short | grep -v "^??" ; echo "--- branch/commits ---"; git log --oneline -9 | cat; echo "--- ds301 ---"; git log --oneline -1 feature/ds301 | cat
```
- 2026-08-25 — Check whether cpputest is a real submodule
```bash
cat .gitmodules 2>/dev/null; echo "--- status ---"; git status --short test/cpputest; echo "--- ls ---"; ls test/cpputest | head; echo "--- config ---"; git config -f .gitmodules --list 2>/dev/null; git submodule status
```
- 2026-08-25 — Add Building & Testing section to CLAUDE.md
```bash
python3 - <<'EOF'
p='CLAUDE.md'; t=open(p).read()
    ... [17 more lines elided]
EOF
sed -n '43,60p' CLAUDE.md
```
- 2026-08-25 — Check pucktuner EDS for the old RL block
```bash
cd ~/code/p4gui && grep -n "^\[3015" pucktuner/puck4.eds | head -20; echo "--- 3004 ---"; grep -n "^\[3004" pucktuner/puck4.eds; echo "--- pucktuner git status ---"; git -C pucktuner status --short | head
```
- 2026-08-25 — Final status across the three repos
```bash
cd ~/code/stm32 && git status --short app/ notes/ CLAUDE.md && echo "=== p4gui ===" && git -C ~/code/p4gui status --short | grep -v pucktuner | head && echo "=== pucktuner ===" && git -C ~/code/p4gui/pucktuner status --short
```
- 2026-08-25 — Inspect merge result details
```bash
SP=/tmp/claude-1000/-home-bz-code-stm32/6e4cf351-8522-4b47-86aa-85d55e2c1fcc/scratchpad
cd $SP/trial
echo "=== deleted by merge ==="; git status --short | grep '^D' 
echo "=== renamed ==="; git status --short | grep '^R'
echo "=== added (non-lib/docs) ==="; git status --short | grep '^A' | grep -v 'lib/\|docs/\|notes/\|figures/'
echo "=== conflict hunk counts ==="
for f in $(git diff --name-only --diff-filter=U); do printf "%-30s %s\n" "$f" "$(grep -c '^<<<<<<<' $f)"; done
```
- 2026-08-26 — Clean stray build dir, check status
```bash
cd /home/bz/code/stm32 && ls build/ && rm -rf build/-- && git status --short | head -30
```
- 2026-08-26 — Final test run and status
```bash
cd test && ./build/test_runner 2>&1 | tail -3; cd .. && rm -f /tmp/claude-1000/-home-bz-code-stm32/*/scratchpad/sim /tmp/claude-1000/-home-bz-code-stm32/*/scratchpad/sim.c 2>/dev/null; git status --short | grep -v "^??"
```

## `git branch` — 18 calls

- 2026-08-19 — Check what's modified before committing
```bash
git branch --show-current; git status --short -- app/ common/ stm32/ k64/ *.csv *.eds; echo "=== diff ==="; git diff --stat
```
- 2026-08-24 — List relevant branches
```bash
git branch -a --list '*september*' '*secure*' '*purr*' && echo "---" && git log --oneline -1 feature/september-release 2>/dev/null && git log --oneline -1 feature/secure-flashloader 2>/dev/null
```
- 2026-08-24 — List all branches
```bash
git branch -a | head -50
```
- 2026-08-24 — Which branches contain the deferred-harvest commit
```bash
git branch --contains be06293 2>/dev/null; echo "--- devel has? ---"; git merge-base --is-ancestor be06293 devel && echo YES || echo NO
```
- 2026-08-24 — Recheck current branch and containment
```bash
git branch --show-current; git rev-parse --short HEAD; echo "--- contains ---"; git branch -a --contains be06293 | head -20; echo "--- kick in HEAD pwm.c ---"; git show HEAD:app/pwm.c | grep -c hal_enc_start_read
```
- 2026-08-24 — Find purr branch
```bash
git branch -a | head -40; echo "=== worktrees ==="; git worktree list; echo "=== purr log ==="; git log --oneline -5 feature/purr 2>&1 | head
```
- 2026-08-25 — List branches and purr history
```bash
git branch -a | head -30 && echo "---" && git log --oneline feature/purr -15 2>/dev/null
```
- 2026-08-25 — List all branches
```bash
git branch -a | cat
```
- 2026-08-25 — Create local ds301 branch and worktree
```bash
git branch -f feature/ds301 origin/feature/ds301 && git worktree add /tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/ds301 feature/ds301 2>&1 | tail -2
```
- 2026-08-25 — Check branches and pucktuner nesting
```bash
cd ~/code/stm32 && git branch --show-current && echo "=== p4gui ===" && git -C ~/code/p4gui branch --show-current && git -C ~/code/p4gui status --short | grep -i pucktuner | head -3; echo "(no pucktuner lines above = p4gui ignores it)"; grep -n "pucktuner\|puckutility" ~/code/p4gui/.gitignore 2>/dev/null; echo "=== pucktuner ===" && git -C ~/code/p4gui/pucktuner branch --show-current
```
- 2026-08-25 — List branches
```bash
git branch -a && echo "=== current ===" && git log --oneline -5 && echo "=== ds301 exists? ===" && git log --oneline -3 feature/ds301 2>&1 | head
```
- 2026-08-25 — Verify branch state intact
```bash
cd /home/bz/code/stm32
git branch --show-current; git status --short | grep -v '^??' | head; echo "---"; git stash list
```
- 2026-08-25 — Verify working tree intact
```bash
cd /home/bz/code/stm32
git branch --show-current; echo "--- modified ---"; git status --short | grep -v '^??' ; echo "--- stashes ---"; git stash list | head -3
echo "--- cordic present? ---"; ls -la stm32/cordic.c stm32/cordic.h 2>&1 | head
```
- 2026-08-27
```bash
git branch -vv | head -20 && echo "=== remotes ===" && git remote -v && echo "=== upstream ===" && git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>&1 && echo "=== ahead/behind ===" && git status -sb | head -3
```
- 2026-08-27
```bash
git branch -m feature/purr feature/secure-purr && git push -u origin feature/secure-purr 2>&1 | tail -20
```
- 2026-08-27
```bash
git branch -m feature/purr feature/secure-purr && git branch -vv | grep secure-purr
```
- 2026-08-27 — Show branches containing the commit
```bash
git branch -a --contains 4ee599e 2>&1 | head -30
```
- 2026-08-27 — Fetch and recheck remote containment
```bash
timeout 30 git fetch origin --quiet 2>&1 | head; echo "fetch rc=$?"; git branch -r --contains 4ee599e 2>&1; echo "--- local vs origin for current branch:"; git rev-list --left-right --count origin/feature/secure-purr...HEAD 2>&1
```

## `git commit` — 11 calls

- 2026-08-06 — Commit purr integration
```bash
git commit -F - <<'EOF'
Integrate purr torque generator with CANopen record 0x3027
    ... [39 more lines elided]
EOF
```
- 2026-08-19 — Commit the overflow fix
```bash
cd /home/bz/code/stm32 && git commit -F - <<'EOF'
Fix int32 overflow in bus voltage compensation
    ... [47 more lines elided]
EOF
```
- 2026-08-19 — Commit the estimator
```bash
git commit -q -F - <<'EOF'
Estimate velocity with a spec-derived three-state Kalman filter
    ... [78 more lines elided]
EOF
git log --oneline -1 && git show --stat HEAD | tail -15
```
- 2026-08-19 — Commit polarity fix
```bash
git commit -F - <<'EOF'
Apply user polarity to the torque command, not just the feedback
    ... [37 more lines elided]
EOF
```
- 2026-08-24 — Commit exectime feature
```bash
git commit -F - <<'EOF'
Execution-time profiler behind 0x3028
    ... [21 more lines elided]
EOF
```
- 2026-08-24 — Commit the deferred-harvest change
```bash
git commit -F - <<'EOF'
enc: unconditional deferred harvest on both platforms
    ... [35 more lines elided]
EOF
```
- 2026-08-24 — Commit 1: profiler
```bash
cd /home/bz/code/stm32/test && ./build/test_runner 2>&1 | grep -E "^OK|Errors"; cd /home/bz/code/stm32
git commit -q -F - <<'EOF'
Execution-time profiler behind 0x302A
    ... [39 more lines elided]
EOF
git log --oneline -1
```
- 2026-08-24 — Commit 2: refactor
```bash
git commit -q -F - <<'EOF'
fw: split field weakening out of the PWM ISR onto the 1 kHz tick
    ... [65 more lines elided]
EOF
git log --oneline -3; echo "=== working tree ==="; git status --short | grep -v "^??"
```
- 2026-08-25 — Commit the fixes and design note
```bash
git commit -F - <<'EOF'
hal: fix the DTG encoding, and take the UV backstop from 0x2384:7
    ... [42 more lines elided]
EOF
echo "---"; git --no-pager log --oneline -3; echo "---"; git --no-pager show --stat --oneline HEAD | head -8
```
- 2026-08-25 — Recommit with only the relevant files
```bash
git commit -q -F /tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/msg.txt && git show --stat HEAD | tail -14 && echo "=== untracked notes restored ===" && git status --short notes/ | head -5
```
- 2026-08-26 — Commit
```bash
git commit -q -F - <<'EOF'
Synchronised purring, and a clock that stays put
    ... [44 more lines elided]
EOF
git log --oneline -1 && git show --stat HEAD | tail -25
```

## `git checkout` — 10 calls

- 2026-08-24 — Resolve conflicts taking september side
```bash
SP=/tmp/claude-1000/-home-bz-code-stm32/9e7100b9-6a42-4eeb-967e-7dad1092b006/scratchpad; cd $SP/wt-merge && git checkout --theirs app/main.c app/version.h puck4.eds && git add app/main.c app/version.h puck4.eds && git status --short | head -5 && grep -n 'hal_nvm_commit\|GOLDEN_VECTORS' app/main.c
```
- 2026-08-24 — Inspect main.c byte structure
```bash
git checkout HEAD -- app/main.c
python3 - <<'PYEOF'
p='app/main.c'
    ... [10 more lines elided]
PYEOF
```
- 2026-08-24 — Reconstruct profiler-only shared files
```bash
B=/tmp/claude-1000/-home-bz-code-stm32/2cf036f0-4beb-43a4-86cd-ca7585593bd5/scratchpad/final
git checkout HEAD -- app/pwm.c app/pwm.h app/main.c app/motion.c app/co_dict.c
# profiler-only files are identical in the final state
cp $B/app/parse_app.c $B/app/parse_app.h app/
cp $B/common/hal.h common/ ; cp $B/stm32/hal.c stm32/ ; cp $B/k64/hal.c k64/
cp $B/test/mocks/mock_hal.c test/mocks/ ; cp $B/app/exectime.c app/
python3 - <<'PYEOF'
B='/tmp/claude-1000/-home-bz-code-stm32/2cf036f0-4beb-43a4-86cd-ca7585593bd5/scratchpad/final'
    ... [12 more lines elided]
PYEOF
grep -c "0x3028" app/co_dict.c; grep -c "EXECTIME_FW_1KHZ" app/exectime.h
```
- 2026-08-25 — Bisect ds301 for the last building commit
```bash
cd /tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/ds301 && for c in 69f30ba 15a7f68 4b51823 4e34dfe a1fd25e; do git checkout -q $c 2>/dev/null; r=$(./build.sh stm32 app release 2>&1 | grep -c "error"); echo "$c: errors=$r"; done
```
- 2026-08-25 — Check the remaining ds301 commits
```bash
cd /tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/ds301 && for c in 6a508a6 52673fd 5d581c6; do git checkout -q $c; r=$(./build.sh stm32 app release 2>&1 | grep -c "error"); echo "$c: errors=$r"; done
```
- 2026-08-25 — Measure ds301 RAM at last building commit
```bash
cd /tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/ds301 && git checkout -q 5d581c6 && ./build.sh stm32 app release >/dev/null 2>&1 && . ./setpath && arm-none-eabi-objdump -h build/puck4.axf | grep -E "\.(data|bss|ccmsram) " && echo "--- top bss ---" && arm-none-eabi-nm --size-sort -S build/puck4.axf | grep -iE " [bB] " | tail -12
```
- 2026-08-25 — Test every ds301 commit for a successful STM32 link
```bash
cd /tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/ds301 && for c in 2926329 9a0058e 0f8d008 ec4bbf2 aa0d301 4f2f381 ef9e05e ddc6955 f99893f 3a383a4 a1fd25e 4e34dfe 6a508a6 52673fd 5d581c6 4b51823 15a7f68 69f30ba 2b45b92; do git checkout -q $c; rm -f build/puck4.axf; ./build.sh stm32 app release >/dev/null 2>&1; if [ -f build/puck4.axf ]; then echo "$c OK   $(git log --format=%s -1 $c | cut -c1-52)"; else echo "$c FAIL $(git log --format=%s -1 $c | cut -c1-52)"; fi; done
```
- 2026-08-25 — Identify the DS301 link failure
```bash
cd /tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/ds301 && git checkout -q 4e34dfe && ./build.sh stm32 app release 2>&1 | grep -oE "undefined reference to \`[a-z_]+'" | sort -u
```
- 2026-08-25 — Measure RAM at the last linking ds301 commit
```bash
cd /tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/ds301 && git checkout -q a1fd25e && ./build.sh stm32 app release >/dev/null 2>&1; . ./setpath; echo "=== a1fd25e (last linking ds301 commit) ==="; arm-none-eabi-objdump -h build/puck4.axf | grep -E "\.(data|bss|ccmsram) "; arm-none-eabi-nm --size-sort -S build/puck4.axf | grep -iE " [bB] " | tail -8; grep -cE "^\s*\{0x[0-9A-Fa-f]{4}," app/co_dict.c
```
- 2026-08-25 — Create port branch
```bash
cd /home/bz/code/stm32
git checkout -b feature/ds301-port 2>&1 | tail -2
git status --short | head -3
```

## `git worktree` — 10 calls

- 2026-08-24 — Create worktrees for size comparison
```bash
git worktree add /tmp/claude-1000/-home-bz-code-stm32/9e7100b9-6a42-4eeb-967e-7dad1092b006/scratchpad/wt-sept origin/feature/september-release --detach 2>&1 | tail -2 && git worktree add /tmp/claude-1000/-home-bz-code-stm32/9e7100b9-6a42-4eeb-967e-7dad1092b006/scratchpad/wt-base e739da2 --detach 2>&1 | tail -2 && git worktree add /tmp/claude-1000/-home-bz-code-stm32/9e7100b9-6a42-4eeb-967e-7dad1092b006/scratchpad/wt-sf feature/secure-flashloader --detach 2>&1 | tail -2
```
- 2026-08-24 — Trial merge in a worktree
```bash
SP=/tmp/claude-1000/-home-bz-code-stm32/9e7100b9-6a42-4eeb-967e-7dad1092b006/scratchpad; git worktree add $SP/wt-merge feature/secure-flashloader --detach 2>&1 | tail -1; cd $SP/wt-merge && git merge origin/feature/september-release 2>&1 | tail -6
```
- 2026-08-24 — Clean up unneeded worktrees
```bash
git worktree remove --force /tmp/claude-1000/-home-bz-code-stm32/9e7100b9-6a42-4eeb-967e-7dad1092b006/scratchpad/wt-base && git worktree remove --force /tmp/claude-1000/-home-bz-code-stm32/9e7100b9-6a42-4eeb-967e-7dad1092b006/scratchpad/wt-sf && git worktree list
```
- 2026-08-24 — Build K64 baseline for size comparison
```bash
SP=/tmp/claude-1000/-home-bz-code-stm32/9e7100b9-6a42-4eeb-967e-7dad1092b006/scratchpad; git worktree add $SP/wt-base e739da2 --detach 2>&1 | tail -1; cd $SP/wt-base && ./build.sh k64 app release > $SP/build-base-k64.log 2>&1; echo "exit=$?"; /home/bz/code/stm32/toolchain/arm-none-eabi/arm-none-eabi-objdump -h build/puck4.axf | grep -E '^\s+[0-9]+ \.' | awk '{print $2,$3,$4}'
```
- 2026-08-24 — Clean up build worktrees
```bash
git worktree remove --force /tmp/claude-1000/-home-bz-code-stm32/9e7100b9-6a42-4eeb-967e-7dad1092b006/scratchpad/wt-base && git worktree remove --force /tmp/claude-1000/-home-bz-code-stm32/9e7100b9-6a42-4eeb-967e-7dad1092b006/scratchpad/wt-sept && git worktree list | tail -3
```
- 2026-08-25 — Create a worktree for ds301
```bash
git worktree add /tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/ds301 origin/feature/ds301 2>&1 | tail -3
```
- 2026-08-25 — Build the pre-cut baseline
```bash
SP=/tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad; git worktree add -q $SP/base 72f8bce 2>&1 | tail -1; cd $SP/base && ./build.sh stm32 app release >/dev/null 2>&1; . ./setpath; echo "=== 72f8bce (before the cut) ==="; arm-none-eabi-objdump -h build/puck4.axf | grep -E "\.(text|data|bss) "; grep -cE "^\s*\{0x[0-9A-Fa-f]{4}," app/co_dict.c
```
- 2026-08-25 — Extract hardware findings from the deleted header
```bash
git worktree remove --force /tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/base; git show HEAD:app/rl_measure.h | grep -n -iE "measured|hardware|ruled out|bench|found|observed|2026|confirm" | head -25
```
- 2026-08-25 — Check for prior merge work
```bash
cd /home/bz/code/stm32
echo "=== worktrees ==="
ls worktrees/ 2>/dev/null; git worktree list
echo "=== tmp/merge-test ==="
git log --oneline -3 tmp/merge-test
echo "=== notes dir ==="
ls notes/
echo "=== tasks dir on ds301 ==="
git ls-tree --name-only feature/ds301 -- tasks/
```
- 2026-08-25 — Trial merge to gauge conflicts
```bash
cd /home/bz/code/stm32
SP=/tmp/claude-1000/-home-bz-code-stm32/6e4cf351-8522-4b47-86aa-85d55e2c1fcc/scratchpad
git worktree prune
git worktree add -f --detach $SP/trial feature/september-release >/dev/null 2>&1
cd $SP/trial && git merge --no-commit --no-ff feature/ds301 >/dev/null 2>&1
echo "=== conflict summary ==="
git diff --name-only --diff-filter=U | sed 's/^/CONFLICT /'
echo
git status --short | awk '{print $1}' | sort | uniq -c
```

## `git stash` — 7 calls

- 2026-08-24 — Check whether RWX warning pre-exists my change
```bash
cd /home/bz/code/stm32; git stash list >/dev/null; git stash; ./build.sh k64 app debug 2>&1 | grep -c "RWX"; git stash pop
```
- 2026-08-24 — Verify commit 1 builds standalone
```bash
git stash list | head -1; git checkout -q 21866df 2>&1 | head -2
./build.sh stm32 app release 2>&1 | grep -cE "error"; ./build.sh k64 app release 2>&1 | grep -cE "error"
cd test && make >/dev/null 2>&1; ./build/test_runner 2>&1 | grep -E "^OK|Errors"; cd /home/bz/code/stm32
git checkout -q feature/september-release && git log --oneline -1
```
- 2026-08-25 — Check stash state
```bash
git stash -q --keep-index 2>/dev/null; git stash list | head -2
```
- 2026-08-25 — Restore the stashed changes
```bash
git stash pop 2>&1 | tail -5; git status --short -- app/ | cat
```
- 2026-08-25 — Confirm the 5 failures pre-date my fixes
```bash
cd /tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/ds301 && git stash -q && cd test && make -s >/dev/null 2>&1; ./build/test_runner 2>&1 | tail -2; cd .. && git stash pop -q && echo "restored" && git status --short | head
```
- 2026-08-25 — Compare binary sizes
```bash
cd /home/bz/code/stm32
SZ=$(find toolchain -name "arm-none-eabi-size" | head -1)
echo "=== new ==="; $SZ build/puck4.axf
git stash list >/dev/null
echo "=== baseline (feature/september-release) ==="
git stash push -u -q -m tmp-size 2>/dev/null; git checkout -q feature/september-release 2>/dev/null && ./build.sh stm32 app release >/dev/null 2>&1 && $SZ build/puck4.axf; git checkout -q feature/ds301-port; git stash pop -q 2>/dev/null
echo done
```
- 2026-08-25 — Compare section sizes vs baseline
```bash
cd /home/bz/code/stm32
rm -rf build && ./build.sh stm32 app release >/dev/null 2>&1
OD=toolchain/arm-none-eabi/arm-none-eabi-objdump
echo "=== ds301-port ==="; $OD -h build/puck4.axf | awk '$2==".text"||$2==".data"||$2==".bss"{print $2, $3}'
git stash -q -u 2>/dev/null
git checkout -q feature/september-release && rm -rf build && ./build.sh stm32 app release >/dev/null 2>&1
echo "=== september-release baseline ==="; $OD -h build/puck4.axf | awk '$2==".text"||$2==".data"||$2==".bss"{print $2, $3}'
git checkout -q feature/ds301-port && git stash pop -q
git branch --show-current
```

## `git ls-files` — 5 calls

- 2026-08-25 — Inspect githash.h and eds files
```bash
cat app/githash.h 2>/dev/null; echo "=== eds tracked? ==="; git ls-files | grep -i eds; echo "=== eds 3003 on purr ==="; git show feature/purr:puck4.eds | grep -n "3003" | head
```
- 2026-08-25 — Apply Makefile githash changes
```bash
python3 - <<'PYEOF'
import io
    ... [82 more lines elided]
PYEOF
```
- 2026-08-25 — Check if cpputest is tracked on ds301
```bash
cd /tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/ds301 && git ls-files test/cpputest | head -3; echo "--- is it tracked? ---"; git ls-files test/cpputest | wc -l
```
- 2026-08-25 — Restore the tracked cpputest entry
```bash
cd /tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/ds301 && git ls-files -s test/cpputest; echo "--- restore it ---"; rm -f test/cpputest && git checkout -- test/cpputest && git status --short | head
```
- 2026-08-25 — Check index entry and BUILDING.md
```bash
git ls-files -s test/cpputest; echo "--- BUILDING.md test refs ---"; grep -n -i "test\|cpputest\|submodule" docs/BUILDING.md | head -30
```

## `git ls-tree` — 5 calls

- 2026-08-18 — Find all uses of vel_aw on the branch
```bash
for f in $(git ls-tree -r --name-only feature/velest-new -- app common stm32 test); do if git show feature/velest-new:$f 2>/dev/null | grep -q "vel_aw"; then echo "== $f"; git show feature/velest-new:$f | grep -n "vel_aw" | head -5; fi; done
```
- 2026-08-24 — Find flashp4.py in purr branch
```bash
git ls-tree -r --name-only feature/purr | grep -i "flashp4\|\.py$" | head -20
```
- 2026-08-25 — Inspect ds301 tree
```bash
cd /home/bz/code/stm32
echo "=== ds301 lib/ ==="
git ls-tree feature/ds301 lib/ 
echo "=== ds301 AMMCLIB refs in app ==="
git grep -l "GFLIB_\|GMCLIB_\|MLIB_" feature/ds301 -- app common stm32 | head
echo "=== ds301 base64 ==="
git grep -n "base64" feature/ds301 -- common/parse.c | head
echo "=== ds301 impedance ==="
git ls-tree -r --name-only feature/ds301 -- app | head -50
echo "=== ds301 test dir ==="
git ls-tree -r --name-only feature/ds301 -- test | head -40
```
- 2026-08-25 — File-level divergence
```bash
cd /home/bz/code/stm32
echo "=== files only in ds301 ==="
comm -13 <(git ls-tree -r --name-only feature/september-release | sort) <(git ls-tree -r --name-only feature/ds301 | sort) | grep -v '^docs/\|^notes/\|^figures/' 
echo
echo "=== files only in september-release ==="
comm -23 <(git ls-tree -r --name-only feature/september-release | sort) <(git ls-tree -r --name-only feature/ds301 | sort) | grep -v '^docs/\|^notes/\|^figures/\|^lib/AMMCLIB\|^lib/mbedtls'
```
- 2026-08-26 — Copy CMSIS-DSP subset into tree
```bash
cd /home/bz/code/stm32
# Bring the CMSIS-DSP subset and the sine table across from ds301
for f in $(git ls-tree -r --name-only feature/ds301 -- lib/cmsis-dsp); do
  mkdir -p "$(dirname "$f")"; git show "feature/ds301:$f" > "$f"
done
git show feature/ds301:common/cmsis_sin_table.c > common/cmsis_sin_table.c
git show feature/ds301:app/config.h > app/config.h
echo "=== files landed ==="
find lib/cmsis-dsp -type f | wc -l; ls common/cmsis_sin_table.c app/config.h
```

## `git rev-parse` — 4 calls

- 2026-08-24 — Tie branch, HEAD, and on-disk pwm.c together
```bash
cd /home/bz/code/stm32; git rev-parse --abbrev-ref HEAD; git rev-parse --short HEAD; wc -l app/pwm.c; md5sum app/pwm.c; git status --short -- app/pwm.c; echo "--- HEAD blob ---"; git show HEAD:app/pwm.c | wc -l
```
- 2026-08-25 — Add 0x3003 entry to co_dict.c
```bash
python3 - <<'PYEOF'
p='app/co_dict.c'
    ... [27 more lines elided]
PYEOF
git diff --stat app/co_dict.c | cat
```
- 2026-08-25 — Check p4gui repo state
```bash
cd ~/code/p4gui && git rev-parse --is-inside-work-tree 2>/dev/null && git status --short | head -10 && git log --oneline -3 | cat
```
- 2026-08-25 — Check vendoring convention and pucktuner repo
```bash
cd ~/code/p4gui && for f in canopen_runner.py flashp4.py puck4.eds flashloader.eds; do if [ -f "pucktuner/$f" ] && [ -f "$f" ]; then if diff -q "$f" "pucktuner/$f" >/dev/null; then echo "IDENTICAL  $f"; else echo "DIVERGED   $f  ($(diff "$f" "pucktuner/$f" | grep -c '^[<>]') differing lines)"; fi; fi; done; echo "--- pucktuner repo ---"; git -C pucktuner rev-parse --show-toplevel 2>/dev/null; git -C pucktuner log --oneline -3 2>/dev/null
```

## `git merge` — 3 calls

- 2026-08-25 — Dry-run the merge to measure conflicts
```bash
git merge --no-commit --no-ff origin/feature/ds301 >/tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad/merge.log 2>&1; echo "exit=$?"; echo "=== conflict counts ==="; git diff --name-only --diff-filter=U | wc -l; git diff --name-only --diff-filter=U | head -40
```
- 2026-08-25 — Abort the merge and inspect hashmap_create
```bash
git merge --abort && git status --short -- app/ common/ Makefile | cat; echo "merge aborted"; sed -n 40,60p common/hashmap.c
```
- 2026-08-25 — Check flashloader on baseline
```bash
SP=/tmp/claude-1000/-home-bz-code-stm32/6e4cf351-8522-4b47-86aa-85d55e2c1fcc/scratchpad
cd $SP/trial && git merge --abort 2>/dev/null; git checkout -q -f feature/september-release 2>/dev/null || git checkout -q -f -B trialbase feature/september-release
git log --oneline -1
./build.sh stm32 flashloader release 2>&1 | tail -8
```

## `git fetch` — 2 calls

- 2026-08-24 — Find merge base and divergence
```bash
git fetch origin 2>&1 | tail -3; echo "=== merge-base ==="; git merge-base origin/feature/september-release feature/secure-flashloader; echo "=== log target ahead ==="; git log --oneline feature/secure-flashloader ^origin/feature/september-release | head -40; echo "=== count ==="; git rev-list --count feature/secure-flashloader ^origin/feature/september-release; git rev-list --count origin/feature/september-release ^feature/secure-flashloader
```
- 2026-08-25 — Fetch and survey ds301
```bash
git fetch origin 2>&1 | tail -3; echo "=== ds301 vs merge-base with HEAD ==="; git merge-base HEAD origin/feature/ds301; echo "--- commits on ds301 not in HEAD ---"; git log --oneline HEAD..origin/feature/ds301 | cat
```

## `git grep` — 2 calls

- 2026-08-25 — Find base64 and API call sites
```bash
cd /home/bz/code/stm32
echo "=== base64 users (sept) ==="; grep -rln "base64" --include=*.c --include=*.h --include=*.cpp --include=Makefile . 2>/dev/null | grep -v '^./lib\|^./.venv\|cpputest' 
echo "=== ds301 base64 users ==="; git grep -ln "base64" feature/ds301 -- '*.c' '*.h' '*.cpp' 'Makefile' 'test/Makefile' | grep -v lib/
echo "=== parseGetValuePtr call sites (sept) ==="; grep -rn "parseGetValuePtr" --include=*.c --include=*.h --include=*.cpp . 2>/dev/null | grep -v '^./lib\|cpputest' | wc -l
echo "=== hashmap_insert/lookup call sites (sept) ==="; grep -rn "hashmap_insert\|hashmap_lookup" --include=*.c --include=*.cpp . 2>/dev/null | grep -v cpputest
```
- 2026-08-25 — Trace PARSE_PDO
```bash
cd /home/bz/code/stm32
echo "=== PARSE_PDO refs (sept) ==="; grep -rn "PARSE_PDO" --include=*.h --include=*.c --include=Makefile --include=*.mk . 2>/dev/null | grep -v worktrees
echo "=== PARSE_PDO refs (ds301) ==="; git grep -n "PARSE_PDO" feature/ds301 -- '*.h' '*.c' 'Makefile' | head -20
```

## `git merge-base` — 2 calls

- 2026-08-25 — Compare branches
```bash
cd /home/bz/code/stm32
echo "=== merge-base september-release <-> ds301 ==="
git merge-base feature/september-release feature/ds301 | xargs git log --oneline -1
echo "=== commits on ds301 not in september-release ==="
git rev-list --count feature/september-release..feature/ds301
echo "=== commits on september-release not in ds301 ==="
git rev-list --count feature/ds301..feature/september-release
echo "=== 6c046b? ==="
git log --oneline -1 6c046b 2>&1 | head -2
echo "=== diffstat summary ds301 vs sept ==="
git diff --stat feature/september-release feature/ds301 | tail -5
```
- 2026-08-25 — What sept changed in parse layer
```bash
cd /home/bz/code/stm32
MB=$(git merge-base feature/september-release feature/ds301)
echo "=== sept changes to common/parse.c since merge-base ==="
git diff --stat $MB feature/september-release -- common/parse.c common/parse.h common/hashmap.c common/hashmap.h app/co_dict.c common/co_dict.h | cat
echo
git diff $MB feature/september-release -- common/parse.c | cat
```

## `git check-ignore` — 1 call

- 2026-08-25 — Check pucktuner gitignore for __pycache__
```bash
cd ~/code/p4gui/pucktuner && cat .gitignore 2>/dev/null | head; git check-ignore -v __pycache__ 2>&1 | head -2
```

## `git clone` — 1 call

- 2026-08-25 — Clone p4gui to a writable location
```bash
SP=/tmp/claude-1000/-home-bz-code-stm32/3c4b1a83-bb21-4801-9670-3d2b431e47a4/scratchpad; rm -rf $SP/p4gui && git clone -q ~/code/p4gui $SP/p4gui 2>&1 | tail -2; cd $SP/p4gui && git log --oneline -1 | cat && ls sysid.py sysid_device.py && cp -r ~/code/p4gui/bin ~/code/p4gui/lib $SP/p4gui/ 2>/dev/null; ls -d bin lib 2>/dev/null
```

## `git config` — 1 call

- 2026-08-25 — Commit rl_identify in pucktuner
```bash
cd ~/code/p4gui/pucktuner && git config user.name && git config user.email && git add rl_identify.py test_rl_identify.py && git commit -q -F - <<'EOF'
rl: add rl_identify, a self-contained R and L measurement over 0x3015
    ... [33 more lines elided]
EOF
git log --oneline -1
```

## `git describe` — 1 call

- 2026-08-27
```bash
python3 - <<'EOF'
import re
    ... [30 more lines elided]
EOF
git diff --stat .gitlab-ci.yml
```

## `git merge-tree` — 1 call

- 2026-08-24 — Trial merge to detect conflicts
```bash
git merge-tree --write-tree feature/secure-flashloader origin/feature/september-release 2>&1 | head -60
```

## `git rm` — 1 call

- 2026-08-25 — Delete rl_measure and rebuild
```bash
python3 - <<'PYEOF'
# dbg_qmode drove the deleted manual-sine q-axis diagnostic; nothing reads it now.
    ... [13 more lines elided]
PYEOF
git rm -q app/rl_measure.c app/rl_measure.h && ./build.sh stm32 app debug 2>&1 | grep -E "error|undefined" | head -10
```

## `git submodule` — 1 call

- 2026-08-25 — Baseline unit tests
```bash
git submodule status test/cpputest && cd test && make test 2>&1 | tail -25
```

