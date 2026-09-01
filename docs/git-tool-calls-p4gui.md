# Git tool calls in p4gui chat logs

Extracted from 13 session transcripts under `~/.claude/projects/-home-bz-code-p4gui/`. 185 Bash tool calls invoking `git`, listed chronologically by session. Commands only — results omitted.

## Subcommand frequency

| Subcommand | Count |
|---|---|
| `git log` | 94 |
| `git show` | 74 |
| `git status` | 58 |
| `git diff` | 52 |
| `git commit` | 39 |
| `git add` | 35 |
| `git stash` | 18 |
| `git worktree` | 16 |
| `git branch` | 14 |
| `git merge-base` | 12 |
| `git checkout` | 6 |
| `git grep` | 6 |
| `git rev-parse` | 5 |
| `git ls-files` | 3 |
| `git rm` | 3 |
| `git for-each-ref` | 1 |
| `git rev-list` | 1 |
| `git tag` | 1 |
| `git cat-file` | 1 |
| `git ls-tree` | 1 |
| `git merge-tree` | 1 |
| `git merge` | 1 |
| `git apply` | 1 |
| `git check-ignore` | 1 |
| `git push` | 1 |
| `git cherry-pick` | 1 |
| `git reflog` | 1 |

## All calls (chronological)

### Session `31527175` (started 2026-08-06)

```bash
timeout 600 ./bin/python3 -m unittest discover -s test 2>&1 | grep -E "^(OK|FAILED|Ran )"; echo "=== BASELINE (HEAD) ==="; git stash -q && timeout 600 ./bin/python3 -m unittest discover -s test 2>&1 | grep -E "^(OK|FAILED|Ran )"; git stash pop -q && echo restored

git --no-pager diff -- p4gui_wx.py p4gui.py

git --no-pager diff -- test_tab.py

timeout 600 ./bin/python3 -m unittest discover -s test 2>&1 | grep -E "^FAIL:" | sort > /tmp/claude-1000/-home-bz-code-p4gui/31527175-9702-49e7-ab43-1fed710abb56/scratchpad/after.txt; git stash -q; timeout 600 ./bin/python3 -m unittest discover -s test 2>&1 | grep -E "^FAIL:" | sort > /tmp/claude-1000/-home-bz-code-p4gui/31527175-9702-49e7-ab43-1fed710abb56/scratchpad/before.txt; git stash pop -q; diff /tmp/claude-1000/-home-bz-code-p4gui/31527175-9702-49e7-ab43-1fed710abb56/scratchpad/{before,after}.txt && echo "IDENTICAL failure set vs HEAD"

git --no-pager diff --stat; echo; git status --short

git --no-pager log -6 --format='%n=== %s%n%b'

git --no-pager diff -U2 -- p4gui.py p4gui_wx.py test_tab.py | grep -n "^@@\|^diff --git"

git add puck4.eds && git commit -q -F - <<'EOF'
puck4.eds: add purr generator record (0x3027)

The firmware gained a purr generator -- an additive zero-mean torque
overlay produced by purr_torque.c and driven by 0x3027 -- but this EDS
still described the object dictionary without it, so none of the eight
settings could be resolved by name.

Added as a record with sub0..sub9, matching the names and types in the
firmware's co_dict.c so both files agree: Enable, Rate, Tone, Symmetry,
Variability, Filter, Volume, Noise, and the read-only PurrTorque output
at sub9. Symmetry is INTEGER16 -- it is the one signed setting, spanning
-1000..1000 -- and an unsigned type there would fail to encode a negative
or silently wrap it.

Note this file is not the same EDS as stm32's; it descends from
puck3-r0.eds and uses a different layout, and already lacks other objects
the config CSV writes (0x3024, 0x3026). Additions only, in index order,
keeping this file's formatting conventions; no existing entry is touched.

Verified by loading with canopen: PurrGenerator parses as an ODRecord
whose ten subs carry the expected names, types and access, and Symmetry
round-trips -1000 as 0xFC18.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
git --no-pager log -1 --format='%h %s'

git add p4gui.py p4gui_wx.py test_tab.py realtime_plot.py test/test_purr_panel.py test/test_test_graph_channels.py && git status --short

git commit -q -F - <<'EOF'
Test tab: add a purr panel, and collapse the three graphs into one

Purr panel
    A Purr Generator box beside Limits, editing the eight settings of
    0x3027 over SDO as they are changed. Populated by reading the record
    back -- on Test tab activation as well as at node select -- so it
    shows what the drive actually holds after a config CSV or another
    tool has written it, not an assumed default.

    Widget ranges come from the firmware, not the EDS. parsePurr() in
    parse_app.c saturates every write (Rate 20..90, Tone 500..2000,
    Symmetry +/-1000, the rest 0..1000) and reports success either way,
    so an unbounded control could be typed to 1500, have the drive
    silently store 1000, and go on displaying 1500. The spin controls
    cannot ask for a value that would be clamped.

    Spin controls rather than sliders: eight rows of sliders with
    SL_LABELS would stand roughly twice as tall as the four beside them
    and eat the graph's space for no gain in precision.

    Bound to the value-changed event and to kill-focus, since a spin
    control that is typed into rather than clicked may not report its
    final value until focus leaves. Both paths dedupe against the last
    value sent, so the second binding costs no bus traffic, and a failed
    write drops that cache entry so the next edit retries instead of
    deduping against a value the device never took.

    _populate_purr stops at the first failed read, unlike _populate_limits
    which continues. The limits are four independent objects; these are
    sub-indices of one record and share a fate -- firmware without the
    purr generator aborts on all eight, and a puck that has gone away
    times out on all eight. Tab activation is frequent enough that eight
    SDO timeouts would be a multi-second freeze on every visit.

Test tab graph
    The three stacked graphs become one, with a picker above it for
    Current / Velocity / Position, defaulting to Current. The single
    panel takes 330 px where each of the three had 150, so it inherits
    the space the other two gave up.

    New MultiChannelRealtimePlot in realtime_plot: one figure and one
    redraw timer holding N buffer pairs, not N DualRealtimePlots with all
    but one hidden. Every channel buffers whether or not it is on screen,
    so switching to Velocity mid-run shows the history that accumulated
    while Current was displayed instead of an empty axis. Feeding a
    hidden channel cannot mark the view dirty, so it costs a deque append
    and never provokes a redraw. select() relabels the y-axis, so the
    axis text and the picker cannot disagree.

    The buffering and selection rules live in a plain ChannelBuffers
    class with no wx or matplotlib in it, so they can be tested without a
    display -- including that take() copies under the lock, which is what
    stops the notifier thread's appends raising "deque mutated during
    iteration" in the timer. DualRealtimePlot is untouched and the Tune
    tab keeps its three graphs.

Tests: 50 new, covering the purr read/write path against the real EDS
record (stubbed widgets, real encoding), the channel buffers, and the
TPDO callbacks feeding each channel in display units. The suite's 34
pre-existing failures are unchanged -- they name widgets removed in
earlier commits.

Not verified: how any of this looks. There is no display server reachable
here -- PID 1 is bwrap, /run/user does not exist, and there is no
/tmp/.X11-unix -- so wx.App() cannot start and neither panel has been
seen rendered. Worth a look at the three-across top row at the 675 px
minimum width, and at the taller single graph.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
git --no-pager log -2 --format='%h %s'; echo "--- tree clean? ---"; git status --short
```

### Session `3c941777` (started 2026-08-18)

```bash
git stash && ./bin/python3 -m unittest discover -s test 2>&1 | tail -3; git stash pop

git diff

cd /home/bz/code/stm32 && git log --oneline -8 2>/dev/null; echo "=== status ==="; git status --short 2>/dev/null | head; echo "=== 30 in purr history ==="; git log -p --all -S"30, 90" -- app/parse_app.c 2>/dev/null | grep -E "^commit|^[-+].*SATURATE.*90|^Date" | head -20

cd /home/bz/code/stm32 && git log -p --all -S"PPMIN" -- app/purr_torque.c 2>/dev/null | grep -E "^commit|^[-+].*PPMIN =" | head; echo "=== diff working tree vs HEAD for purr ==="; git diff HEAD -- app/purr_torque.c app/parse_app.c app/co_dict.c 2>/dev/null | head -40; echo "(end diff)"

./bin/python3 -m unittest discover -s test 2>&1 | tail -3; echo "=== p4gui diff ==="; git diff --stat
```

### Session `b4c523f7` (started 2026-08-19)

```bash
git -C /home/bz/code/p4gui status --short && echo "--- lines ---" && wc -l sysid.py sysid_device.py identify_tab.py test/fake_puck.py test/test_sysid.py test/test_sysid_device.py test/test_identify_tab.py

git status --short && echo "--- current branch ---" && git rev-parse --abbrev-ref HEAD

git add identify_tab.py p4gui.py p4gui_wx.py puck4.eds sysid.py sysid_device.py test/fake_puck.py test/test_identify_tab.py test/test_sysid.py test/test_sysid_device.py && git status --short

git commit -F - <<'EOF'
Identify tab: implement PMSM system identification

The Identify tab's measurement code could not have run: it imported
modules that do not exist (measure_rs, measure_ls, ...), called an
undefined _sysid_setup_env(), and mapped parameters onto invented
objects (Stator/Rs, Mechanical/Inertia, Thermal/MaxTemp) that are not
in puck4.eds.  The real parameters live in Calibration (0x3011) as
rt/lt/j/i_cont/i_peak/i_peak_time.

Replaced with a three-layer implementation:

  sysid.py         numpy-only fits (scipy is not a dependency; all three
                   fits reduce to least squares or a log-linearisation)
  sysid_device.py  CANopen sequencing, raw-unit conversion, interlocks
  identify_tab.py  GUI layer: worker thread, display units, OD writes

Measures Rs, Ls, Kt, pole pairs, friction, inertia and continuous
current, plus an Auto Measure that runs them in dependency order.

Every raw scaling is derived from the firmware source rather than the
EDS/header comments, several of which are stale:

  ud/uq        Q15 of Vbus_nominal/sqrt(3), not Vbus and not Vbus/2
  id, 0x6078   per-mille of i_peak, as peak dq amplitudes (not mA)
  0x606C       cts/s motor-side (the "0.1 cts/sec" label is puck3's)
  rt/lt        line-to-line, halved by firmware to the dq values
  j            1e-9 kg.m^2
  Theta_e      0x60EA, Q15 of pi electrical

Safety: mode 12 has no protection at all — motion_eval_pva() is empty,
so MaxTorque/MaxCurrent/torque limits/i2t never run, there is no motor
over-temperature fault, and the timer break input is disabled.  Full
scale ud is ~90 A through a P4-42 winding.  The injection ramp
therefore sizes its ceiling from resistance measured as it goes, opens
with a small blind probe, refuses to keep raising voltage when current
reads nothing, and always leaves the drive safe via a finally block.

Three unit bugs fixed on the way:

  - Calibration.poles is the TOTAL pole count, but the field is Pole
    Pairs — a factor of 2 on both read and write.
  - Kt was cached into _sysid_params as mNm/A, which the Tune tab reads
    as N.m/A when computing gains — a factor of 1000.
  - Averaging forward/reverse acceleration does not cancel Coulomb
    friction (it opposes motion both ways); it cancels a
    direction-independent offset instead.  Uncorrected, J came out 67%
    high in test.  tau_c is now subtracted explicitly and the result
    flags when it was not available.

Labels corrected to the units actually used: Rs/Ls per-phase, Kt in
mNm/A rms, peak current time in ms (was "(s)" — 1000x), viscous
friction in uNm.s/rad.

puck4.eds gains the entries this addresses by name: 0x220A
MotorMaxTemperatureDegC, the rest of the Amp record through
0x3001,9 NominalBusVoltage, 0x2384 amplifier fault limits, 0x3025,2-3
and the 0x3026 thermistor divider configuration.

115 new tests, all passing, run against a simulated puck
(test/fake_puck.py) that models the winding, rotor and the firmware's
rejection of setpoints written outside their mode.

NOT VALIDATED ON HARDWARE — the sandbox has no CAN access.  One open
question needs a motor: KT_FROM_KE uses 3/sqrt(2), which firmware's
torque equation implies, but its W_MAX macro implies sqrt(3) instead —
a 22% disagreement.  On the P4-42 (nameplate 25 mNm/A) a back-EMF
measurement lands near 25 if 3/sqrt(2) is right, near 20 if it is not.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF

timeout 600 ./bin/python3 -m unittest discover -s test 2>&1 | grep -E "^(Ran|OK|FAILED)" && git add -A ':!sandbox.conf' && git commit -F - <<'EOF'
Identify: warn when Calibration.rt/lt are zero

Firmware sets the cutoff of the filters on the exported id/iq from the
winding time constant:

    tau_winding = (float)*motor.lt * 0.01f / (float)*motor.rt;

with no zero guard, and neither rt nor lt is range-checked — unlike
poles and pwm_freq, which are validated a few lines earlier in the same
function.  With both at zero that expression is 0.0f/0.0f, i.e. NaN,
which propagates through fc_dq into biquadInit and leaves the id/iq
filters with NaN coefficients.

This is not hypothetical for the motor in front of us: the P4-42 config
CSV writes kt, poles, i_cont, i_peak, i_peak_time and i_cal, but never
rt, lt or j.

Every measurement in sysid_device reads Motor.id or 0x6078, so if this
has bitten, the numbers are meaningless rather than merely noisy — and
the failure is silent.  Warn at refresh_scaling rather than refuse,
because whether it actually bites depends on the puck's NVM and cannot
be told from the bus.  Saving a measured Rs and Ls back to the device
writes rt/lt, so a measure-save-reboot cycle is itself the fix.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF

git add notes/firmware_unit_corrections.md && git commit -q -F - <<'EOF'
notes: firmware unit corrections found during Identify work

Every item verified against /home/bz/code/stm32 at the cited line.
Three change behaviour (tau_winding scale + unguarded divide by zero,
W_MAX disagreeing with the torque equation by sqrt(3/2), nominal bus
voltage having no default or validation); six are comments that
contradict their code; four are dictionary entries nothing reads,
including the motor over-temperature limit; two are outside the
firmware (a config CSV velocity label inherited from puck3, and EDS
parameter names).

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
git log --oneline -4 && echo "--- remaining untracked ---" && git status --short
```

### Session `aef730c2` (started 2026-08-19)

```bash
git log --oneline -3 -- identify_tab.py sysid.py sysid_device.py && echo "=== status ===" && git status --short && echo "=== sandbox.conf ===" && cat sandbox.conf

ls notes/ && echo "=== last commit ===" && git show ba12263 --stat && git show ba12263 | head -80

cd ~/code/stm32 && git branch -a 2>/dev/null | head -20; echo "=== current ==="; git rev-parse --abbrev-ref HEAD 2>/dev/null; echo "=== does feature/purr exist? ==="; git log --oneline -3 feature/purr 2>&1 | head

cd ~/code/stm32 && echo "=== torque->current (motion.c) ==="; git show feature/purr:app/motion.c | grep -n "1.414F\|local_q_f" | head -5
echo "=== tau_winding (pwm.c) ==="; git show feature/purr:app/pwm.c | grep -n "tau_winding\|fc_dq" | head -5
echo "=== bus compensation ==="; git show feature/purr:app/pwm.c | grep -n "scale_q14\|SCALE_CAP" | head -6
echo "=== Clarke convention ==="; git show feature/purr:app/pwm.c | grep -n "not power-invariant\|(B-C)/sqrt(3)\|Beta (B-C)" | head -3
echo "=== motor.uq export ==="; git show feature/purr:app/pwm.c | grep -n "\*motor.uq = \|\*motor.ud = " | head -5
echo "=== max_torque binding ==="; git show feature/purr:app/motion.c | grep -n "max_torque = " | head -3

cd ~/code/stm32 && git show feature/purr:app/motion.c | grep -n "motor.j\|\.j =" | head; echo "=== uses of motor.j ==="; for f in app/motion.c app/pwm.c app/parse_app.c app/gains.h; do echo "--- $f ---"; git show feature/purr:$f | grep -n "motor\.j\b\|\bj\b.*32768\|2\^15" | head -8; done

cd ~/code/stm32 && git show feature/purr:app/pwm.h | grep -n -B2 -A2 "\*j;\|j;.*inertia\|[Ii]nertia"; echo "=== notes ==="; grep -rn "gcm\|g.cm\|inertia\|0x3011.*7\|3011,7" notes/ 2>/dev/null | head -10

git status --short && echo "=== diffstat ===" && git diff --stat

git diff sysid_device.py | head -150

git add identify_tab.py sysid_device.py test/fake_puck.py test/test_identify_tab.py test/test_sysid_device.py notes/firmware_unit_corrections.md && git status --short

git commit -F - <<'MSGEOF'
Identify: correct the measurements against a real P4-42

First hardware run of the Identify tab, on a P4-42-42V-20A-BO4523-LFM
(node 1, feature/purr firmware, 24 V bench supply). Pole-pair counting
was already right; everything else had a defect. Numbers below are from
the motor, and are recorded in the constants they justify.

measure_ls returned a confidently wrong answer, which is the worst kind.
It reported 5.99 mH against a true 0.26 mH with r2 = 0.917 — passing
every existing guard, because what it captured was not the winding but
the firmware low-pass on the exported id (pwm.c:915, ~29 ms here against
a 1 ms winding), and a filter's step response is a *clean* exponential.
It now predicts that same fc_dq and refuses when the fitted tau is not
clear of it. Ls is not obtainable this way at all: correcting firmware's
10x tau_winding bug moves the filter to 54 Hz, still slower than the
winding, so the refusal is the honest outcome rather than a stopgap.

Purring is suspended for the duration of a measurement and restored
afterwards. 0x3027 sums into the torque demand at motion.c:150, and a
commissioned puck ships with it enabled at up to 15% of rated torque —
against the ~2 mNm of friction those measurements resolve. The Kt
back-EMF fit went from r2 = 0.980 to r2 = 0.99988 with it off. Mode 12
is immune (motion_eval_pva() is empty), so this only ever showed up in
the spinning measurements.

Calibration.j is g.cm^2 * 2^15, not nN.m.s^2/rad — the tab was out by
32768x, showing 21365 g.cm^2 for a rotor that measures 91.9. The config
CSVs are the only correct source in the tree; pwm.h:81 calls it mN.m.s^2
and is also wrong. Firmware reads the object nowhere, which is why this
survived.

The Rs sweep was 34% high from two independent causes, now both
addressed: it swept down into current where the dead-time drop is still
developing (incremental dV/dI runs 1.09 ohm at 0.3 A against 0.25 ohm at
3.5 A), and it injected at one electrical angle, which moves the answer
13.5% because the alpha/beta sense channels are separately calibrated.
Floored at 0.6 of test current and averaged over three angles it fits
0.302 ohm at r2 = 0.996, against 0.348 at r2 = 0.970 before. The
remaining ~10% over the configured 0.26 is a documented systematic of
the method, not noise — see RS_SWEEP_FLOOR.

The ud ramp overshot a 3.0 A request to 3.5 A, which on a supply set
just above the requested current is a trip rather than a measurement —
and a trip sags the bus, which defeats firmware's voltage compensation
once it hits its 2x cap. Two fixes: size the step from the incremental
resistance rather than the chord V/I (the chord folds in the inverter
offset), and settle each step against the feedback filter instead of a
flat 50 ms. Now lands at 3.03 A.

measure_inertia defaulted to a torque that emptied the useful range
before it could be sampled: a quarter of rated torque crossed the speed
limit in 25 samples at r2 = 0.87, giving a J 55% away from the same
motor at 0.08 (56 and 73 samples, r2 = 0.995). Default lowered, and a
ramp that cannot clear INERTIA_MIN_SAMPLES is now rejected rather than
fitted, since too few points shows up in an r2 nobody reads rather than
in the answer.

Also fixes a bug introduced by the multi-angle sweep itself: Theta_e is
INTEGER16 and two thirds of an electrical revolution is 43690, so
_begin_d_axis has to wrap like _set_theta_e does. The first hardware run
aborted on exactly that.

Tests: fake_puck gains an optional first-order lag on id, without which
the Ls guard cannot be exercised at all — the instantaneous model has no
rise to mistake for a filter. 25 new tests covering each finding, each
naming the hardware observation behind it. 160 sysid tests pass. The 34
failures elsewhere in the suite are pre-existing and unrelated (legacy
t09-t38 tests referencing widgets removed in earlier refactors).

notes/firmware_unit_corrections.md gains a Hardware confirmations
section: item 1 (tau_winding) confirmed on the bench, item 2 (W_MAX)
settled in favour of the torque equation by source but NOT by magnitude
— measured Kt is 28.7 mNm/A where the nameplate says 25 and the sqrt(3)
convention would say 23.4, so the nameplate sits between the candidates
and cannot arbitrate. Two new items: the motor.j unit contradiction, and
purring as a trap for any host tool that identifies a motor.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSGEOF
git log --oneline -3
```

### Session `e9295f79` (started 2026-08-19)

```bash
git log -1 --stat && echo "--- DIFF ---" && git show HEAD --format="%B" | head -100

cd /home/bz/code/stm32 && git log --oneline -3 && git status --short | head -20 && echo "--- find pwm.c ---" && find . -name "pwm.c" -o -name "pwm.h" | head

cd /home/bz/code/stm32 && git branch -a | head -30 && echo "--- current ---" && git rev-parse --abbrev-ref HEAD && echo "--- purr vs head ---" && git log --oneline feature/purr -3 2>/dev/null

cd /home/bz/code/stm32 && git log --oneline feature/purr..feature/kalman-vel | cat; echo "=== diff stat ==="; git diff --stat feature/purr feature/kalman-vel | tail -20

cd /home/bz/code/stm32 && git diff --stat && echo "=== detail ===" && git diff | head -120

cd /home/bz/code/stm32 && git status && echo "=== cached ===" && git diff --cached --stat

cd /home/bz/code/stm32 && git ls-files toolchain | head -3 && echo "toolchain tracked: $(git ls-files toolchain | wc -l) files" && echo "lib tracked: $(git ls-files lib | wc -l)" && cat .gitmodules 2>/dev/null

cd /home/bz/code/stm32 && git worktree add /home/bz/code/stm32-lsfilter -b feature/ls-filter feature/purr 2>&1 | tail -5 && ls /home/bz/code/stm32-lsfilter | head

cd /home/bz/code/stm32-lsfilter && git add -A app/pwm.c app/pwm.h app/co_dict.c app/parse_app.c app/parse_app.h Makefile puck4.eds .gitignore && git status --short

cd /home/bz/code/stm32-lsfilter && git commit -q -F - <<'EOF' && git log --oneline -1
Make the exported id/iq filter cutoff settable, and stamp the commit

Two things a host tool needs from this firmware that it could not get.

The low-pass on the exported id and iq (0x3010,6 and 0x6078) was cut once
at boot from the winding time constant and never touchable again. On a
P4-42 with rt = lt = 52 that lands at 5.4 Hz, a 29 ms envelope against a
winding that settles in about 0.9 ms - so anything watching id sees the
filter, not the motor. p4gui's Ls measurement fell straight into it and
reported 5.99 mH against a true 0.26, at r2 = 0.917, because a biquad's
step response is a cleaner exponential than any winding's. There is no
way to identify an inductance through that, and no way to widen it.

0x3019,5 and 0x3019,6 now carry the cutoff in Hz for the two axes. Zero
keeps the derived value, which is what every puck boots with and what
every fielded one will keep doing; anything else is an explicit cutoff,
and a request wider than a fifth of the control rate bypasses the filter
outright, since the loop cannot realise one that wide. Both are RW but
deliberately not NV - a tool that opens the filter up to identify a motor
and then crashes must not leave a puck reporting raw current for ever,
and a power cycle is enough to undo it. The coefficients are staged and
adopted by the PWM ISR rather than written into the running filters:
biquadInit() calls tan() and pow(), which have no business in a 20 kHz
interrupt, and a half-updated coefficient set would be processed as if it
meant something.

The derived path also now checks rt and lt before dividing by them.
Neither is range-checked anywhere in the tree - unlike poles and
pwm_freq a dozen lines above - and the commissioning CSVs write neither,
so a puck programmed from one onto blank NVM arrives with both zero.
That was 0.0f/0.0f = NaN into biquadInit, i.e. an exported id and iq that
are NaN cast to int16 for the life of the boot. It now falls back to a
1 ms winding. The 10x unit disagreement in that same expression (the
comment says rt is in milliohms, pwm.h and the CSVs say 0.01 ohm) is left
exactly as it was: it changes the filtering every fielded puck gets, and
that is a decision to take on its own, not a side effect of this.

Second: 0x3003 publishes the commit the binary was built from - seven hex
digits in the low 28 bits, generated into app/githash.h by the Makefile.
0x100A gives the release version, which many builds share; this says
which tree. Bit 31 marks a build whose tree did not match the commit it
names, either a modified tracked file or an untracked .c/.h/.S sitting in
a directory the build compiles. That second case is not hypothetical:
puck4.app.stm32.release.4ee599e.bin in the main checkout is 4 KB larger
than a clean build of 4ee599e and contains velkf.c from another branch
entirely, and nothing on the device could have told you. The output
filename gains a -dirty suffix from the same test.

Tests: 182 CppUTest tests pass. Both targets build clean.
EOF

cd /home/bz/code/stm32-lsfilter && git add Makefile && git commit -q --amend --no-edit && git log --oneline -1 && rm -f *.bin && ./build.sh stm32 app release 2>&1 | tail -3 && ls *.bin && cat app/githash.h && python3 -c "
import os
f=[x for x in os.listdir('.') if x.endswith('.bin')][0]
d=open(f,'rb').read()
import re
h=int(re.search(r'release\.([0-9a-f]{7})', f).group(1),16)
print('binary contains its own hash 0x%08X:' % h, d.count(h.to_bytes(4,'little')))"

cd /home/bz/code/stm32-lsfilter && git add -A app common Makefile && git commit -q -F - <<'EOF' && git log --oneline -1
Record the dq currents at the control rate, behind 0x3004

An SDO round trip on this bus is about 0.7 ms and a P4-42 winding settles
in less than that, so a host polling id sees a transient it has already
missed - which is the whole reason Ls could not be identified over
CANopen. This records both exported currents every control cycle into a
buffer and lets the host read it back afterwards at whatever speed it
likes. 512 records is 25.6 ms at the 20 kHz control rate, and 0x3004,3
decimates for longer spans.

log.c is where this belongs and log.c could not have worked. It wrote
into (int16_t *)0x20000000 - the base of the RAM region, i.e. straight
over .data and .bss - and LOG_SIZE was 5000 records of four int16, 40 KB
against the 22 KB that region has in total. The only reason a puck ever
booted with it compiled in is that logRecord() had no callers anywhere in
the tree, so nothing ever wrote a byte.

The buffer now lives in CCMSRAM, which had 10 KB going entirely unused
while main RAM has under 2.5 KB spare once .data and .bss are placed.
Core-coupled suits it: no other bus master can reach it, and the only
writer is the ISR.

The readout is a cursor (0x3004,4) and a window onto it (0x3004,5) that
advances on read, so pulling a capture is a run of identical SDO reads
with nothing configured and torn down around it. That replaces the old
plan of reconfiguring TPDO4 and firing 512 rapid SYNCs at the device; the
readout happens after the event and has no reason to be fast.

Removing the dump path also removes every LOG_DUMP guard it needed. Those
existed because the old scheme republished logged samples through the
same OD entries the live signal path uses, so the ISR had to stop writing
isense[].raw and theta_e, and motion had to stop applying the torque
offset, while a dump was in progress. Reading the buffer through its own
object touches none of that, so four branches come out of the control
loop and the 1 kHz motion loop. EXEC_LOG_STEP_REPONSE keeps working and
now arms the new buffer; its 15 ms of baseline before the step is exactly
right, and for the same reason the Ls measurement arms before it steps -
the edge is then visible in the data rather than assumed, which is what
makes the host's own timing stop mattering.

id and iq rather than the raw phase currents: the Park transform and the
sense-channel calibration are already applied, and with 0x3019,5 set wide
the recorded id is the winding rather than a filtered copy of it.

Tests: 182 CppUTest tests pass. Both targets build clean.
EOF

git add -A sysid_device.py test/fake_puck.py test/test_sysid_device.py flashp4.py puck4.eds && git status --short

git commit -q -F - <<'EOF' && git log --oneline -1
Identify: measure Ls through a control-rate capture, not SDO polls

The old measurement could not have worked on this motor and the numbers
say so: 5.99 mH against a true 0.26, r2 = 0.917, every guard passed. Two
separate things had to be fixed in firmware before the host side could be
honest, and this is the host side of both.

The sampling. An SDO round trip on this bus is 0.69 ms median, measured
over 200 reads, and this winding settles in about half that. Polling id
therefore cannot see the rise at all -- with the filter bypassed, the
earliest sample a host can physically take already sits at 79% of final.
No amount of fitting fixes that, so measure_ls now arms firmware's
capture buffer (0x3004), steps ud, and reads 512 records back at leisure.
The time base is the control period, 50 us here, so a 0.48 ms winding is
ten samples of rise instead of none.

The filter. What the old version actually captured was the low-pass on
the exported id, which firmware derives from the *configured* winding and
which sat at 5.4 Hz on this puck -- a 41.6 ms envelope in front of a
0.9 ms winding. It is bypassed for the capture through 0x3019,5 and put
back in a finally. The write is read back, because a silent no-op there
would put the original bug straight back; and the tau-versus-filter guard
is still applied afterwards for the same reason, since a device that
accepts the cutoff and keeps filtering anyway is the one failure the
bypass cannot detect by itself.

_feedback_filter_tau_s was also wrong, independently of all this. The
filter is a second-order Butterworth (biquadInit with Q = 0.7071), so it
settles as exp(-zeta*w0*t) and its time constant is 0.2251/fc, not the
0.159/fc a single pole gives -- 42% longer. Confirmed on the P4-42 by
equivalent-time sampling of the step at the derived 5.41 Hz cutoff: fitted
40.5 ms against the 41.6 ms this now predicts, where the old form said
29.4 ms.

Two things the hardware forced:

The step runs from a DC bias at 0.6 of the test current, not from zero.
This is not a refinement -- a from-zero step is not a linear RL step at
all. The dead-time drop puts the incremental resistance at about 1.09 ohm
near 0.3 A against 0.25 ohm at 3.5 A, so a rise starting at zero sweeps a
resistance that changes fourfold on the way up and has no single time
constant. Measured: from zero, the fitted tau climbed with test current
(0.31 ms at 0.75 A, 0.44 at 1.5, 0.49 at 3.0) and only stopped climbing
once the whole step cleared the knee. A biased step, 2.0 -> 3.5 A, gave
0.45-0.51 ms straight away, and the ud pair implies 0.31 ohm across that
interval, which agrees with the fitted Rs.

t = 0 is found in the data, not assumed. The capture is armed before the
step is commanded, and the gap between the two is a round trip -- longer
than the entire rise. The edge is located by threshold; a sub-sample
error in it shifts every point of the log-linear fit equally and is
absorbed exactly by the intercept, which is why a crude threshold is
enough.

What this motor actually measures: tau_w = 0.45-0.51 ms, giving Ls near
0.145 mH against the 0.26 mH/phase its config claims (rt = lt = 52 --
note the two are *equal*, which reads like a placeholder rather than a
measurement). The result is stable across cutoffs from 150 to 400 Hz,
across test currents from 1.5 to 4.5 A, and between a from-zero and a
biased step. Not yet reconciled with the config, and the config is the
less trustworthy of the two.

Also here, because the firmware work needed it: flashp4.py's command line
called flash() with three arguments where it takes four, so it raised a
TypeError before reaching the bus -- the progress queue is a GUI thing
and is now optional. It also resolves flashloader.eds beside the module
rather than the caller's cwd, disconnects on every path instead of only
on success, prints its progress bar every 100 frames rather than 99 times
in every 100, and exits non-zero on failure.

Tests: 84 sysid tests pass, 12 of them new and covering each finding
above. fake_puck gains the capture buffer, the filter cutoff, and a way
to model firmware that lacks an object or that ignores the cutoff. The 34
failures elsewhere in the suite are the same pre-existing legacy t09-t38
widget tests as before this change.
EOF

cd /home/bz/code/stm32-lsfilter && ls -la *.bin 2>/dev/null; echo "--- rebuild 244bb94 to compare ---"; git stash list | head -2; git log --oneline -3

cd /home/bz/code/stm32-lsfilter && rm -f *.bin && ./build.sh stm32 app release 2>&1 | grep -E "SIZE|ERROR" && git add -A stm32/*.ld Makefile && git commit -q -F - <<'EOF' && git log --oneline -2
Keep .ccmsram out of the image, and refuse to emit one that cannot fit

The capture buffer's 2 KB in CCMSRAM turned a 63 KB application into a
134,189,056-byte .bin, and I flashed it. That is exactly
0x10001000 - 0x08008000: objcopy -O binary spans every loadable address
from the lowest LMA to the highest, and .ccmsram was ALLOC+LOAD at
0x10000800 rather than NOBITS.

The reason it was loadable is worth writing down, because nothing about
the declaration looks wrong. An uninitialised static normally lands in
.bss, which is NOBITS and costs no image space -- but an explicit
__attribute__((section(".ccmsram"))) overrides that and gives PROGBITS,
zero-filled. The linker script then had nothing to say otherwise: no
NOLOAD, no AT>, so LMA = VMA = CCMSRAM. objdump showed
"CONTENTS, ALLOC, LOAD, DATA" and the section headers were the only place
it was visible. All four scripts had the same shape, so all four are
fixed.

What it cost: the flashloader erased the application and its
authentication marker, started writing 134 MB through SDOs, and ran out
of room part way. The puck has been unreachable over CAN since and needs
a J-Link.

So the image is now checked after objcopy, against the flash it has to
fit in, and a build that exceeds it fails and deletes the .bin rather
than leaving something flashable-looking behind. There is no ordinary way
to trip this -- an application that genuinely outgrew 92 KB would fail at
link time instead -- which is precisely why it is worth having: the way
it gets tripped is a section landing at a RAM address, and then the file
looks perfectly reasonable and the flashloader has no idea either.

Tests: 182 CppUTest tests pass. stm32 release 63704 bytes, stm32 debug
63704, k64 release 71024.
EOF

cd /home/bz/code/stm32-lsfilter && git stash push -q -- app common stm32 k64 flashloader && git stash list | head -1 && ./build.sh stm32 flashloader release 2>&1 | tail -6; echo "=== restoring ==="; git stash pop -q && git status --short | head

cd /home/bz/code/stm32-lsfilter && git add -A app common stm32 k64 flashloader Makefile && git commit -q -F - <<'EOF' && git log --oneline -1
Arm the watchdog before the code that hangs, and stop relaunching into it

The watchdog worked. It was just started four calls after the point it
was needed, and it was 33x slower than its comment claimed.

Timeout. LSI_VALUE is 32000 Hz and the prescaler is /256, so each tick is
8 ms and the old reload of 4095 gave 4096 * 8 ms = 32.768 s, beside a
comment reading "~1s". Now 124, for 125 ticks and 1.000 s. LSI is trimmed
to a few percent so call it 0.95-1.05 s; everything that refreshes does so
with ten times the margin, which is why that spread does not matter.

Coverage. hal_wdog_init() was the last thing before the main loop, on the
reasoning that arming it earlier means instrumenting init. The cost was
that init - where a bad image actually dies - ran unprotected, and
HardFault_Handler is weak-aliased to Default_Handler's infinite loop, so
a fault there is permanent. That is not hypothetical: a P4-42 flashed
with a corrupt application got as far as parseSendHeartbeat(), emitted
its CANopen bootup, stopped, and could not be reset by anything. It took
a J-Link.

So it is armed first now, and each init step refreshes when it returns.
Between steps and never inside them: a wait loop that never finishes has
to trip the watchdog, so a refresh in there would defeat the purpose.

That still leaves the startup code that zeroes .bss and copies .data,
which runs before main() and loops between linker symbols that are part
of the same image being doubted. An application cannot arm a watchdog
early enough to cover its own C runtime startup. The flashloader does it
instead, in launch(), immediately before the jump - not at flashloader
startup, because erase and programming are tens of seconds of blocking
flash work that would then need refreshes threaded through them, and the
flashloader is the recovery path of last resort and not worth making
conditional on getting that right. The application re-arms anyway, which
is allowed on a running IWDG and covers debug builds flashed straight to
0x08000000 with nothing underneath.

Relaunch. A watchdog only converts a hang into a reset; by itself that is
a reset loop, since the flashloader starts the same image again and it
hangs again, with a few milliseconds per cycle for anyone to get a word
in. prepareToLaunch() now refuses on RCC_CSR IWDGRSTF, which is what
turns that into a puck sitting in the flashloader waiting to be
reflashed. hal_system_getresetsources() has always reported that bit and
nothing has ever acted on it. Nothing cleared it either - RMVF was never
written, so the flags accumulated until power-off and 0x3000,3 reported
every reset since rather than the last one. Cleared now, on the read.

Rearm. watchdog() re-added itself with timer_add_event() and dropped the
return, which is -1 when all MAX_TIMERS (8) slots are busy against six or
seven users. Losing that race once lost the refresh permanently and the
puck reset a timeout later with nothing to say why. It now refreshes
before rescheduling, and the main loop retries a failed reschedule; a
table full for a whole second is a real fault and firing is correct.
Refresh interval also drops from 1000 ms to 100 ms, for margin against
the shorter timeout.

Separately, and found while building this: build/ was one directory
shared by every configuration, but common/ and stm32/ compile into all of
them with different flags - the application gets -DIS_APP -DPARSE_PDO and
the flashloader does not. Link the flashloader after the application and
build/common/parse.c.o still had PARSE_PDO in it, dragging stats_write,
parseSyncCallback and pwm_execute into a link with no application in it.
It fails loudly when the symbols are missing and silently when they are
not: the k64 image is 69024 bytes built clean against 71072 built after
an stm32 pass, so this has been producing binaries nobody asked for. One
object tree per configuration now, and clean removes all of them.

K64 note, not fixed here because it is a different watchdog on a target
this branch does not run: hal_wdog_init() there configures with
enableWdog = false and hal_wdog_enable() has no callers, so that part has
no watchdog at all.

Tests: 182 CppUTest tests pass. All four configurations build clean from
scratch and in any order - stm32 app release 63768, stm32 app debug
67864, stm32 flashloader release 21640, k64 app release 69024.
EOF
```

### Session `b8574e30` (started 2026-08-19)

```bash
git log --oneline -15 && echo "--- author/date of HEAD ---" && git log -1 --format='%H%n%an %ae%n%ad%n%s'

git log --all --oneline --grep='watchdog' -i | head -20; echo "--- files mentioning watchdog ---"; grep -ril 'watchdog\|iwdg\|wwdg' --include='*' . 2>/dev/null | head -20

cd ~/code/stm32 && echo "=== worktrees ===" && git worktree list && echo "=== branch/status ===" && git status -sb | head -20 && echo "=== recent commits ===" && git log --oneline -15

cd ~/code/stm32 && echo "=== watchdog commits ===" && git log --all --oneline -i --grep='watchdog\|wdg\|wdt' | head -20 && echo "=== watchdog files ===" && grep -rl --include='*.c' --include='*.h' -i 'watchdog\|IWDG\|WWDG' . 2>/dev/null | grep -v '^./build' | head -20

ls -la /home/bz/code/stm32-lsfilter 2>&1 | head -5; echo "=== commit detail ==="; cd ~/code/stm32 && git log -1 --format='%H%n author: %an <%ae>%n committer: %cn <%ce>%n authored: %ad%n committed: %cd%n%n%B' bc04a63

cd ~/code/stm32 && echo "=== files changed in bc04a63 ===" && git show --stat --format='' bc04a63 && echo "=== branch position ===" && git log --oneline -3 feature/ls-filter && echo "=== merge-base w/ kalman ===" && git merge-base --is-ancestor bc04a63 feature/kalman-vel && echo "IS ancestor of feature/kalman-vel" || echo "NOT merged into feature/kalman-vel"

cd ~/code/stm32 && echo "=== is feature/ls-filter pushed? ===" && git for-each-ref --format='%(refname:short) -> %(upstream:short) %(upstream:track)' refs/heads/feature/ls-filter && git branch -r --contains bc04a63 2>/dev/null | head; echo "(no remote branch contains it if blank)"; echo "=== divergence from kalman-vel ==="; git rev-list --left-right --count feature/kalman-vel...feature/ls-filter

cd ~/code/stm32 && git worktree prune && echo "pruned" && git worktree add /home/bz/code/stm32-lsfilter feature/ls-filter 2>&1 && echo "=== result ===" && git worktree list

cd ~/code/stm32
mkdir -p worktrees
git worktree move /home/bz/code/stm32-lsfilter /home/bz/code/stm32/worktrees/ls-filter 2>&1 || {
  echo "move failed, doing remove+add"; git worktree remove --force /home/bz/code/stm32-lsfilter 2>&1
  git worktree add worktrees/ls-filter feature/ls-filter 2>&1 | tail -3; }
echo "=== result ==="; git worktree list
echo "=== backing fs of new worktree ==="; findmnt -no FSTYPE --target ~/code/stm32/worktrees/ls-filter
echo "=== gitignore the worktrees dir ==="; grep -q '^worktrees/' .gitignore || printf '\n# Local worktrees (kept inside the rw sandbox mount)\nworktrees/\n' >> .gitignore
tail -4 .gitignore; echo "=== git status clean? ==="; git status --short | head

cd ~/code/stm32/worktrees/ls-filter
echo "=== history: did flashloader EVER set RDP1? (commit 19a28a4) ==="
git log --oneline -3 19a28a4 2>/dev/null
echo "--- RDP-related changes across history in flashloader/ ---"
git log --oneline -S'RDP' -- flashloader/ stm32/hal.c 2>/dev/null | head -10
echo
echo "=== what 19a28a4 actually did with RDP ==="
git show 19a28a4 --stat --format='%s' 2>/dev/null | head -12
git show 19a28a4 -- flashloader/ 2>/dev/null | grep -E '^[-+].*[Rr][Dd][Pp]' | head -20

cd ~/code/stm32/worktrees/ls-filter
echo "=== 19ba44f: what does 'reversible RDP1 default' actually change? ==="
git show 19ba44f --stat --format='%s%n' 2>/dev/null | head -15
echo "--- RDP lines it added/removed ---"
git show 19ba44f 2>/dev/null | grep -E '^[-+].*([Rr][Dd][Pp]|0xBB|0xAA)' | head -15
echo
echo "=== and 88ea2ac removed the in-firmware programmer: ==="
git show 88ea2ac --stat --format='%s%n' 2>/dev/null | head -10

cd ~/code/stm32
echo "=== tags ==="; git tag -l 2>/dev/null | grep -i -E '3\.0|3\.1' | head -20
echo "=== commits touching flashloader/version.h ==="
git log --all --oneline -- flashloader/version.h 2>/dev/null | head -20
echo "=== version.h content across those commits ==="
for c in $(git log --all --format=%h -- flashloader/version.h 2>/dev/null | head -12); do
  v=$(git show $c:flashloader/version.h 2>/dev/null | grep -iE 'major|minor|patch|VERSION' | tr '\n' ' ')
  echo "$c  $v"
done

cd ~/code/stm32
echo "=== how far apart is 3.0.7 from the watchdog commit's parent? ==="
git log --oneline e042255..bc04a63 -- flashloader/ common/hal.h stm32/hal.c 2>/dev/null | head -20
echo
echo "=== flashloader/main.c: 3.0.7 vs watchdog-parent ==="
git diff --stat e042255 bc04a63^ -- flashloader/main.c common/hal.h stm32/hal.c 2>/dev/null
echo
echo "=== does 3.0.7's flashloader enforce encryption? ==="
git show e042255:flashloader/main.c 2>/dev/null | grep -n -i 'encrypt\|is_encrypted\|mandatory' | head
echo "(empty above = 3.0.7 accepts plaintext)"
echo
echo "=== what bc04a63 changed in flashloader/main.c ==="
git show bc04a63 -- flashloader/main.c 2>/dev/null | grep -E '^[-+]' | grep -vE '^[-+][-+]' | head -40

cd ~/code/stm32
echo "=== does 3.0.7 (e042255) contain an in-firmware option-byte / RDP programmer? ==="
git show e042255:flashloader/main.c 2>/dev/null | grep -n -iE 'rdp|OPTKEY|OPTSTRT|OBL_LAUNCH|OPTLOCK|option|0xCC|0xBB|0xAA|STANDBY|jtag.?lock' | head -25
echo
echo "=== is 88ea2ac (the removal) after 3.0.7? ==="
git merge-base --is-ancestor e042255 88ea2ac 2>/dev/null && echo "YES: 3.0.7 PREDATES the removal -> 3.0.7 STILL HAS the programmer" || echo "no"

cd ~/code/stm32
git worktree add -b feature/watchdog-307 worktrees/wd307 e042255 2>&1 | tail -3
echo "=== fs check (must be ext4) ==="; findmnt -no FSTYPE --target ~/code/stm32/worktrees/wd307
echo "=== version ==="; grep kVersion worktrees/wd307/flashloader/version.h
echo "=== check_and_set_rdp call sites ==="; grep -n 'check_and_set_rdp' worktrees/wd307/flashloader/main.c

cd ~/code/stm32
echo "########## common/hal.h ##########"; git show bc04a63 -- common/hal.h 2>/dev/null | sed -n '/@@/,$p'
echo "########## stm32/hal.c ##########"; git show bc04a63 -- stm32/hal.c 2>/dev/null | sed -n '/@@/,$p' | head -80

cd ~/code/stm32
echo "########## stm32/hal.c (remainder) ##########"; git show bc04a63 -- stm32/hal.c 2>/dev/null | sed -n '/hal_system_clear_reset_sources/,$p' | head -30
echo "########## flashloader/main.c (full hunk w/ context) ##########"; git show bc04a63 -- flashloader/main.c 2>/dev/null | sed -n '/@@/,$p' | head -70

cd ~/code/stm32/worktrees/wd307
echo "=== any remaining RDP escalation? ==="
grep -n -E 'OB_RDP_LEVEL_1|OPTIONBYTE_RDP|RDPLevel *=' flashloader/main.c || echo "(NONE — RDP is never programmed)"
echo
echo "=== what check_and_set_rdp still does ==="
grep -n -E 'OPTIONBYTE_USER|OB_USER_nBOOT0|option_bytes_need_update = true|EnterSTANDBY' flashloader/main.c
echo
echo "=== diff summary vs 3.0.7 ==="
git -C ~/code/stm32 --work-tree=/home/bz/code/stm32/worktrees/wd307 diff --stat e042255 2>/dev/null | tail -6

echo "=== p4gui ($(git branch --show-current)) ===" && git status --short && echo "--- diff ---" && git diff --stat

cd /home/bz/code/stm32/worktrees/wd307 && echo "=== wd307 ($(git branch --show-current)) ===" && git status --short && echo "--- diff ---" && git diff --stat && echo "=== main stm32 worktree ===" && git -C /home/bz/code/stm32 status --short -- .gitignore

rm -f /home/bz/code/p4gui/echo.log   # my own scratch debris from the loopback test
cd /home/bz/code/p4gui
git add configure_tab.py
cat > /tmp/claude-1000/-home-bz-code-p4gui/b8574e30-648d-4b20-aec6-abdcbe12882a/scratchpad/msg_p4gui.txt <<'EOF'
Configure: persist e_polarity, not just e_zero

calibrate_enczero wrote Calibration/e_polarity to the object dictionary and
then only ever saved e_zero, so the polarity lived in RAM and was gone at the
next boot.  The puck kept whatever polarity was in EEPROM from before the
calibration, which is the one value the calibration had just decided was wrong.

Saved from inside the guard that computes it, so a run that declines to measure
polarity - |pos1 - pos0| >= cts_per_elec_cyc/2, meaning the rotor moved further
than the sweep should have taken it - leaves the stored value alone rather than
committing one it does not trust.

Verified against a P4-42: writing +1 and -1 through Save.Single(0x3011,2) and
power-cycling between them returns the written value both times.  Deliberately
toggled to the wrong polarity first, because rewriting the value already in
EEPROM would not have shown whether the save did anything.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
git commit -F /tmp/claude-1000/-home-bz-code-p4gui/b8574e30-648d-4b20-aec6-abdcbe12882a/scratchpad/msg_p4gui.txt 2>&1 | tail -4

cd /home/bz/code/stm32/worktrees/wd307
git add common/hal.h flashloader/main.c stm32/hal.c
cat > /tmp/claude-1000/-home-bz-code-p4gui/b8574e30-648d-4b20-aec6-abdcbe12882a/scratchpad/msg_stm32.txt <<'EOF'
Flashloader 3.0.7: arm the watchdog, and stop raising RDP on every boot

The watchdog work from bc04a63 rebased onto 3.0.7 rather than the 3.1.0 line,
because 3.1.0 makes encryption mandatory - endProgramWrite() refuses an image
whose IsEncrypted flag is clear - and a bench puck has to be loadable from a
plain .bin.  3.0.7 keeps encryption conditional, so both paths still work.

RDP.  check_and_set_rdp() promoted Level 0 to Level 1 on every boot.  Level 1
blocks debug reads of flash, so once it had run the part could not be erased or
programmed over SWD without regressing RDP - and the regression did not survive,
because the next reset ran this code again and re-armed Level 1 before anything
could reach the flash.  A puck whose application would not boot was recoverable
only by racing its own flashloader for the debug port, and in practice not at
all: the observed sequence was unlock to 0xAA, reset, and 0xBB again, with the
option byte reverting only across a reset and never while the core sat halted.

Read-out protection is a shipping decision, not a boot-time one, and it is
applied over the debug port at the trusted programming stage where it can be
verified while debug still works.  The boot configuration half of the function
stays: it is idempotent, does not touch the debug port, and is what makes the
part boot from main flash.

Watchdog.  Reload was 4095 against a /256 prescaler and a 32 kHz LSI, which the
comment beside it called "~1s" and which is 32.768 s.  Now 124, for 125 ticks
and 1.000 s.  hal_wdog_init() is armed in launch(), immediately before the jump,
so the application is covered through the .bss/.data startup that runs before
main() - an application cannot arm a watchdog early enough to cover its own C
runtime.  prepareToLaunch() refuses on IWDGRSTF so that a hung image becomes a
puck waiting in the flashloader instead of a reset loop nobody can interrupt,
and the reset flags are cleared either way so the next boot reports its own
cause rather than every cause since power-on.

Verified on a P4-42 at 24 V: flashloader 22208 bytes, all sections verified over
SWD, application downloaded over CAN with a matching CRC and launched.  After
launch the IWDG reads PR=6, RLR=124 - 1.000 s - and RCC_CSR carries no reset
flags across a full configuration load and three calibration runs, so the
application refreshes it with margin.  FLASH_OPTR now stays 0xfbeff8aa across
resets where it used to return to 0xbb.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
git commit -F /tmp/claude-1000/-home-bz-code-p4gui/b8574e30-648d-4b20-aec6-abdcbe12882a/scratchpad/msg_stm32.txt 2>&1 | tail -4
echo "=== log ===" && git log --oneline -3
```

### Session `04f46f6f` (started 2026-08-19)

```bash
git log --oneline -15

cd ~/code/stm32 && git log --oneline -25 2>&1 | head -30

cat sandbox.conf 2>/dev/null; echo "---STATUS---"; git status --short

cd ~/code/stm32 && git log -5 --stat --format='=== %h %s%n%b' 2>&1 | head -80

cd ~/code/stm32 && git log --oneline -30 --all 2>&1 | head -40; echo "=== BRANCH ==="; git branch -a 2>&1 | head -20; echo "=== tau_winding grep ==="; grep -rn "tau_winding\|tau_wind" --include=*.c --include=*.h . 2>/dev/null | head -20

cd ~/code/stm32 && git log --oneline -3 244bb94 --stat 2>&1 | head -20; echo "=== eds files ==="; find . -name "*.eds" 2>/dev/null | head

cd ~/code/stm32/worktrees/ls-filter && git log --oneline -3 && echo "=== 3004 in eds ===" && grep -n "^\[3004" -A 10 puck4.eds | head -60; echo "=== 3019sub5 ==="; grep -n "^\[3019sub5" -A 6 puck4.eds

cd ~/code/stm32 && git show 244bb94 -- app/co_dict.c 2>&1 | head -40

cd ~/code/stm32 && git show 244bb94 -- app/co_dict.c 2>&1 | sed -n '/^diff/,$p'

cd ~/code/stm32 && git show 244bb94 -- app/parse_app.c 2>&1 | sed -n '/^diff/,$p' | head -100

cd ~/code/stm32/worktrees/ls-filter && grep -n "GIT_HASH\|githash" Makefile | head -20; echo "=== recent commits with dates ==="; git log --format='%h %cd %s' --date=short -6

cd ~/code/stm32 && git cat-file -t bc04be3 2>&1; git log --format='%h %d %cd %s' --date=short -1 bc04be3 2>&1

cd ~/code/stm32 && git show 244bb94 -- app/pwm.c 2>&1 | sed -n '/^diff/,$p'

cd ~/code/stm32/worktrees/ls-filter && git log -1 --format='%h %s' -L 413,413:app/pwm.c 2>&1 | head -20

cd ~/code/stm32/worktrees/ls-filter && git diff --stat && grep -n "logRecord" app/pwm.c

git status --short && git diff --stat

git add -A notes/firmware_unit_corrections.md puck4.eds sysid_device.py test/fake_puck.py test/test_sysid_device.py && git commit -q -F - <<'EOF'
Identify: measure Ls for real — the capture buffer runs at twice the control rate

The new firmware's capture buffer (0x3004) makes measure_ls runnable, and
running it found four things between the host and a P4-42.  Ls is now
0.128 mH +/- 5.8 % across six runs at r2 = 0.95-0.99, against a first
attempt that refused outright and a second that answered 0.4 mH.

**The shipped EDS never gained 0x3004.** canopen raises KeyError for an index
the EDS does not describe, _require_capture_support catches it like any other
SDO failure, and the puck gets told to update firmware it is already running.
Added, with a test that walks every object the measurement addresses.

**pwm.c calls logRecord() from two arms of its pattern switch**, case 3 with
the buffer and case 1 left over from the log.c it replaced.  Only case 3
writes *motor.id, so every second record is a copy and 512 records span
12.8 ms rather than 25.6.  A host deriving the time base from the control rate
therefore doubles every time constant it fits, and nothing says so - the
waveform is still a clean exponential and the fit quality is untouched.  On
this motor the doubled answer was 0.258 mH against a configured lt of 52,
which is 0.26 mH per phase: agreement to within 1 %, reading as confirmation.

Deriving it again from the same source would not have caught that, so
_capture_record_interval_s times the buffer on the device - 100 records
decimated by 2000, about five seconds - and quantises to whole PWM periods.
It reads 2 periods per record on this firmware and will read 4 once the stale
call is deleted, without changing.  Notes item 18 has the three independent
confirmations; the firmware fix is a separate change in stm32.

**The filter guard was asked after the filter was restored.**  measure_ls puts
the derived cutoff back in a finally block, so the check that the fitted rise
is clear of the low-pass on the exported id read the ~42 ms filter it had just
moved out of the way, and rejected everything - including a sound fit, with
the one verdict that measurement can never usefully give.  The filter is now
sampled through the bypass, where it belongs.

That alone would leave the guard unable to catch a device that takes the write
to 0x3019,5 without acting on it, which is the failure the bypass cannot see.
Two checks replace it: the fitted tau must settle well inside the record, and
it must not land on the constant the derived filter would have had.  The first
is the load-bearing one - it holds whatever the cause, and it is what makes
the fit's steady-state-from-the-tail assumption true.

**One capture cannot resolve this winding.**  The exported id is quantised to
28 mA against a 1.2 A rise, and the log-linear fit is most sensitive where
that noise is worst.  Sixteen consecutive captures fitted individually ranged
from 0.11 to 2.64 mH; r2 ran 0.99 down to 0.50 and tracked the answer, every
noisy fit reading high.  measure_ls now averages eight, each aligned on its
own step and with its own baseline removed - the step index wandered across 22
records, more than a time constant, so averaging the buffers as they lie would
smear the edge being fitted.  Spread fell from 24.5 % to 5.8 %.

Two smaller repairs fell out of the bench work.  The baseline is a median over
the pre-step samples rather than min() of the record, because the record's
minimum is a downward glitch: keying off it put t = 0 eight samples early and
took r2 from 0.99 to 0.83 with tau 55 % high.  And the ramp to the bias
current now runs *before* the filter is bypassed - it is the only current
limit mode 12 has and it servos on read_id_amps(), so unfiltered it was
reading single samples of PWM ripple.  That drove 3.79 A on a 1.8 A request.

Measured on a P4-42-42V-20A-BO4523-LFM v1.3.3, firmware bc04be3, 24 V bench
supply: Rs 0.286 ohm (r2 0.999), Ls 0.128 mH, 5 pole pairs (raw 4.998),
Kt 30.9 mNm/A (r2 0.998), Coulomb 1.36 mNm, J 8.66e-6 kg m^2 (r2 0.994).
The measured Lt disagrees with the CSVs by 2x in a way a duplicated value
explains; notes item 19.

123 sysid tests pass.  The three new failure modes each have a test that
fails against the old behaviour.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
git log --oneline -1

cd ~/code/stm32 && echo "=== which branches contain the kalman commit f7a500d ==="; git branch --contains f7a500d 2>&1; echo; echo "=== ls-filter tip ancestry ==="; git log --oneline feature/ls-filter -12; echo; echo "=== is kalman-vel an ancestor of ls-filter? ==="; git merge-base --is-ancestor f7a500d feature/ls-filter && echo "YES: f7a500d (kalman) is an ancestor of feature/ls-filter" || echo "NO"; git merge-base --is-ancestor feature/kalman-vel feature/ls-filter && echo "YES: kalman-vel tip is an ancestor of ls-filter" || echo "NO: kalman-vel tip is NOT an ancestor"

cd ~/code/stm32 && echo "=== kalman-vel tip ==="; git log --oneline feature/kalman-vel -4; echo; echo "=== objects the kalman commits add to co_dict ==="; git show f7a500d --stat 2>&1 | head -20; echo "--- 0x3028 in co_dict on ls-filter ---"; git show feature/ls-filter:app/co_dict.c 2>/dev/null | grep -n "0x3028" | head -20

cd ~/code/stm32 && echo "=== objects added on kalman-vel (not on ls-filter) ==="; git diff 4ee599e..feature/kalman-vel -- app/co_dict.c | grep "^+.*{0x" | head -30

cd ~/code/stm32 && ls app/velkf.* 2>&1; echo "=== velkf on each branch ==="; for b in feature/kalman-vel feature/ls-filter; do printf '%-22s: ' "$b"; git ls-tree $b app/velkf.c --name-only 2>/dev/null | grep -q velkf && echo "has app/velkf.c" || echo "no velkf.c"; done

cd ~/code/stm32 && echo "=== 0x3013,3 on ls-filter (pre-kalman)? ==="; git show feature/ls-filter:app/co_dict.c | grep -n "0x3013, 3" ; echo "=== on kalman-vel ==="; git show feature/kalman-vel:app/co_dict.c | grep -n "0x3013, 3"

timeout 300 ./bin/python3 -m unittest test.test_identify_tab 2>&1 | tail -4 && git add -A notes/firmware_unit_corrections.md sysid_device.py test/test_sysid_device.py && git commit -q -F - <<'EOF'
Identify: average speed over whole shaft revolutions, not eight samples in a row

_hold_speed took the mean of 8 back-to-back reads of 0x606C.  That mean was
worth exactly one sample: an SDO read takes 0.65 ms, the autocorrelation of the
signal is still +0.83 at 5.2 ms, and the measured sd of the 8-sample mean was
22.79 RPM against 23.13 RPM for a single reading.  Effective N of 1.0.

The ripple it was trying to average is large - 23 RPM sd at 200 RPM, 11 % of
reading - and it went straight into the slopes.  The friction sweep's 100 and
200 RPM points came back 20 RPM out, and friction was the weakest of the six
fits at r2 = 0.976.

It also is not noise.  Over 12,282 samples at 200 RPM, the sd of the mean was
0.49 RPM over exactly one revolution and 1.07 over one and a half - worse from
a longer window, which random noise cannot do.  Two revolutions gave 0.39,
three 0.27, 1.25 gave 1.05.  The ripple turns with the shaft (cogging, encoder
eccentricity), so a whole revolution cancels it outright rather than diluting
it, and the window has to be an integer count of them rather than a duration
or a sample count.

_averaging_window_s(rpm) returns that count.  Floored at VEL_AVG_MIN_S so a
fast point still averages whatever is *not* synchronous - one revolution at
1400 RPM is 43 ms and too few reads - and capped at VEL_AVG_MAX_S, which gives
up the cancellation below about 30 RPM rather than spend minutes on a point.
Nothing here runs that slowly; the friction sweep bottoms out at 100 RPM.

On a P4-42, friction sweep speed-sample error: mean 7.9 -> 0.2 RPM, worst
20.4 -> 0.5.  friction r2 0.976 -> 0.985, Kt r2 0.9967 -> 1.0000.  Costs Kt
0.8 s and friction 2.9 s.

measure_inertia deliberately keeps reading 0x606C raw.  It samples the
acceleration transient, where a window this long would smear the slope it
exists to fit - and its fit already averages the ripple across ~70 points, at
r2 = 0.9936.

The window is scaled by _settle_scale like every other delay, so the suite
still runs in milliseconds and falls back to VEL_AVG_MIN_SAMPLES there.

Also corrects _hold_speed's docstring, which credited the exported velocity to
a Kalman estimator.  The bench puck runs a feature/ls-filter build and has no
such thing: ls-filter is a *sibling* of feature/kalman-vel off 4ee599e, not a
descendant, it carries no app/velkf.c, and 0x3028 aborts 0x06020000 on the
device.  Notes item 20 records the pre-Kalman baseline this was measured
against, for comparison when that branch is flashed.

129 sysid tests pass.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
git log --oneline -2

git show c1b23ed --stat; echo "=== the e_polarity save in current code ==="; grep -n "e_polarity" -B 4 -A 3 configure_tab.py

git stash -q && timeout 120 ./bin/python3 -m unittest test.test_t17_t23_configure_tab 2>&1 | grep -E "^(FAIL|ERROR):|^Ran |^OK|^FAILED"; git stash pop -q && echo "--- restored ---" && git status --short

git add -A configure_tab.py sysid_device.py test/test_sysid_device.py test/test_calibration_ramp.py && git commit -q -F - <<'EOF'
Calibration: make the current ramp apply a step before it measures one

The ramp that puts calibration current through the winding could decline to run
and report success.  It read Motor.id into a local *before* the loop and then
tested that stale copy every pass, while the other half of the same condition
re-read the live value before any ud had been written.

Run back-to-back - which is what calibrate_all does - that is not hypothetical.
calibrate_igainfactor left ud at whatever its ramp reached, writing only
SetModeOfOperation = 0 on the way out, and leaving mode 12 does not clear the
phase voltage reference.  So calibrate_enczero selected mode 12, got full
calibration current the instant it did, found Motor.id already past target,
never wrote a volt, and never turned the rotor.  It then *succeeded*:
pos0 == pos1 == pos2, e_zero saved as wherever the shaft was resting, and
e_polarity from copysign(1, 0), which is +1 whatever the truth.

_ramp_to_calibration_current applies a step, then measures, then decides, and
re-reads every pass so the saturation guard means what it says.  Both routines
call it instead of carrying a copy each.  _deenergise zeroes ud *and* uq before
leaving the mode, and calibrate_all runs it between every step.

calibrate_enczero also now says so when the rotor did not move, rather than
saving numbers that cannot mean anything.  That check is cheap and it is the
thing the ramp fix exists to guarantee.

Also fixes the derived current-filter cutoff mirrored from pwm.c.  That firmware
scaled tau by 1e-2 where the dictionary's units (rt in 0.01 ohm, lt in 0.01 mH)
call for 1e-3, so every derived cutoff came out 10x low - a 41.6 ms filter on a
P4-42 carrying the shipped rt = lt = 52, which is exactly why these 50 ms ramp
steps were reading 70 % settled.  The firmware is fixed separately, but 0x3003
carries a git hash rather than a capability, so a host cannot ask a puck which
build it runs.  _derived_filter_fc_candidates_hz returns both; the Ls guard
checks against both, and the settling delays take the slower one, where being
early costs a measurement and being late costs milliseconds.

132 sysid tests and 8 new calibration-ramp tests pass.  Reinstating the old ramp
and the old exit fails 3 of the 8.  The 2 pre-existing failures in
test_t17_t23_configure_tab are unrelated and unchanged - they assert on names
removed in earlier refactors.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
git log --oneline -1

git add -A sysid.py identify_tab.py p4gui_wx.py test/test_sysid.py test/test_identify_tab.py && git commit -q -F - <<'EOF'
Identify: one ordered calibration list, and a PWM frequency chosen from the winding

Moves Calibration Current, Current Sense Bias, Current Sense Gain and Encoder
Offset off the Configure tab and onto Identify, interleaved with the
measurements into a single numbered list.  They belong together because the
order between them is a dependency order, it is not obvious, and every way of
getting it wrong fails quietly:

  1 Calibration Current      7  Pole Pairs      -> Save + REBOOT
  2 Current Sense Bias       8  Encoder Offset
  3 Current Sense Gain       9  Kt
  4 Rs                       10 Continuous Current
  5 Ls                       11 Viscous Friction
  6 PWM Frequency            12 Inertia

Traced through the firmware rather than assumed.  Bias reads Alpha/Beta
"Filtered", which is the filtered *raw* ADC and sits upstream of both
corrections, so it depends on nothing; gain subtracts those biases; and every
current ramp after them watches Motor/id, which is downstream of bias, gain and
i_peak.  The encoder step additionally needs Calibration.poles, from which it
computes cts_per_elec_cyc, and Kt is the first step needing real commutation, so
it waits for the encoder.  Inertia needs Kt *written to the device*: firmware
turns a torque demand into current through Calibration.kt (motion.c:159), so a
stale kt scales J - by 25/29.28 on the bench puck right now.

pwm_init() runs once from main.c and fixes both motor.cts_per_elec_cycle and dt,
so the pole count and the PWM frequency change nothing until the drive
restarts.  Hence the reboot notice between rows 7 and 8, and a test that keeps
it there.

PWM frequency stops being a setting read back from the device and becomes a
design output of Rs and Ls.  sysid.pwm_frequency_for_ripple picks the *lowest*
frequency meeting a ripple budget, because every other term improves as it
falls - and one of them is not in the usual list.  hal_pwm_set_rate has to
reserve a window at each PWM valley for dead time, gate propagation and shunt
settling before the ADC samples, and it buys that by shrinking the maximum
pulse: the available alpha-beta voltage is 1 - 4*delay*f_sw.  On a P4-42
(delay = 930 ns) that is 70 % at 80 kHz against 85 % at 40 kHz, and what is lost
comes straight off top speed.  So: ripple sets the floor, the control rate sets
another (f_sw/4 at least 20x the winding corner), and firmware's 1-80 kHz guard
and the voltage headroom set the ceiling.

The workflow the user asked about is the right one, and now has a reason:
identify at the top of the range, where ripple is smallest and the
valley-sampled current sits closest to the cycle average, then choose, then
write and reboot.  On the bench P4-42 that lands on 80 kHz - the measured
0.128 mH asks for 82 kHz and clamps.  Designing from the device's own lt = 52
instead would have asked for 40.4 kHz and run the motor at double the intended
ripple, which is a concrete price for the Ls being wrong.

AUTO_SEQUENCE now runs Rs and Ls before the pole count, matching the list;
neither needs commutation, and a test pins the two against each other so they
cannot drift apart.  Step numbers come from CAL_IDENT_ROWS rather than being
written into IDENTIFY_LABELS twice.

519 tests, 34 failures - the same 34 legacy failures as before this branch,
asserting on widget names removed in earlier refactors.  The GUI itself is not
launched: there is no X server in this sandbox, so the layout is covered by
module-level assertions on CAL_IDENT_ROWS and a static check that every widget
p4gui.py binds is still created.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
git log --oneline -3

cd ~/code/stm32/worktrees/ls-filter && git diff --stat && git diff app/pwm.c | grep -E "^[+-]" | grep -vE "^[+-]{3}" | grep -E "tau_winding|logRecord"

timeout 300 ./bin/python3 -m unittest discover -s test 2>&1 | grep -E "^Ran |^OK|^FAILED"; git add -A identify_tab.py test/test_identify_tab.py test/fake_puck.py && git commit -q -F - <<'EOF'
Identify: every measurement writes its own result to the device, at once

A measured value that sits in a text field is a value the drive does not have,
and several steps read the drive rather than the fields.  So each measurement
now writes and Save.Singles its own result the moment it has one, instead of
waiting for a Save To Device the operator may never press.

The case that motivated it: firmware turns a torque demand into current through
Calibration.kt (motion.c:159, i_q = demand * 1.414 * max_torque / kt / i_peak),
so measure_inertia gets the torque it asked for only if kt on the device is the
kt that was just measured.  Confirmed on the bench P4-42, which was carrying
kt = 25 against a measured 29.46:

    J with kt committed first : 102.2 g.cm^2
    J against the stale kt=25 :  88.1 g.cm^2

The 16 % is not noise, it is the ratio of the two kt values, and it had been
silently in every inertia figure this tool has ever produced.

Two smaller versions of the same thing: the exported current filter's cutoff is
derived from rt and lt, so Rs and Ls change the signal later steps measure; and
calibrate_enczero computes cts_per_elec_cyc from Calibration.poles.

DEVICE_OBJECTS is now the single conversion table, used by both the per-step
commit and the bulk Save To Device, so the two cannot disagree about units.
Viscous friction is deliberately absent - firmware has no term for it, so there
is no object to write and it stays a field-and-CSV value.

_commit reads back what the device kept and raises on a mismatch.  An
out-of-range write is accepted at the SDO layer and then clamped or dropped, and
without the read-back the host goes on believing it changed something - which is
precisely the stale value this exists to prevent.  The individual buttons carry
a failed save in their note; inside AUTO_SEQUENCE there is nobody to read a note
and the next step will read the device, so _commit_or_raise fails the step.

A pole count that is not close to an integer is shown but NOT committed.  It is
a failed measurement, and cts_per_elec_cycle is derived from it, so writing it
would put wrong geometry into the calibration that depends on it.

Verified end to end on hardware.  The full AUTO_SEQUENCE ran Rs, Ls, poles, Kt,
friction and inertia with every step committing:

    rt   57 -> 58        lt   52 -> 25        kt   29 -> 30
    j    3350136 -> 3491976                   poles 10 (unchanged)

lt moving from 52 to 25 is the 2x correction from the Ls work reaching the drive
for the first time.

Residual worth knowing: Calibration.kt is an integer in mNm/A, so a measured
29.46 is stored as 29 or 30 - about 1.7 %, and it lands on J through the same
torque conversion.  That is quantisation rather than staleness, so it is left
alone here.

529 tests, the same 34 pre-existing legacy failures.  Reinstating display-only
measurement fails 4 of the 10 new tests, including the end-to-end kt one.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
git log --oneline -1

git add -A test/ && git commit -q -F - <<'EOF'
tests: delete 34 source-grep tests, cover the three behaviours worth keeping

The suite has been red for months on 34 tests that could not have been green.
Every one of them was an assertIn over the *text* of a source file - they
executed nothing, so they could not fail when behaviour broke and could not
pass when it worked.  They only ever tracked spellings, and the spellings moved.

Two of them show what that is worth.  test_t36_imports_odometer looked for
'from odometer' or 'import odometer' in tune_tab.py, which imports
`from wxcontrols.odometer import Odometer` - the import is right there, and the
substring is not.  test_t34_reads_poles_sdo failed because reading the pole
count moved to P4Model.select_node, where it is exercised by real tests.  Both
were red about code that was fine.

A permanently red suite is worse than no suite: it trains everyone to skim past
failures, and it caught nothing while this branch rewrote Ls, the velocity
averaging, the calibration ramp and the whole Identify tab.

Deleted rather than repaired, because repairing a grep gets a grep.  Three of
the behaviours behind them are real and were genuinely uncovered, so they get
tests that run the code:

**test_wave_generator.py** (17).  _generate_sample's shape maths - sine phase
and derivative, square duty, triangle continuity across its corners, offset
shifting position without velocity - plus the guards for zero frequency and a
half-typed amplitude.  And the stop path, which is the part that matters: a
wave run leaves a thread writing RPDOs at 100 Hz, so stopping has to clear the
flag, join the thread and idle the drive, or the motor keeps being driven by a
UI showing 'Run'.  It also has to survive the bus having gone away.

**test_set_device_id.py** (9).  on_set_id is the one operation that can leave a
puck unreachable or two pucks answering to one address, and nothing covered it.
The legacy test grepped for '0x21B0' and had been red since the write moved to
sdo['NetCfg'].  Range 1-127 at both ends, 0 (the NMT broadcast address) and 128
refused, non-integers refused rather than raising, a conflicting ID refused
while rewriting a device its own ID is allowed, and a refused SDO reported
without a rescan.

Mutation-checked rather than assumed: flipping the triangle's sign fails 2 of
12, dropping the wave thread without joining fails 2 of 5, and removing the node
ID range and conflict checks fails 4 of 9.

521 tests, 0 failures - the suite is green for the first time on this branch.

Two things deliberately left alone.  The rest of the legacy t09-t41 files are
mostly greps too, but they pass, and deleting passing tests is a bigger call
than the one asked for.  And 64 assertions in test_t09_t12_layout still hold
p4gui.wxg in place - a wxGlade file last touched in March that nothing reads,
while p4gui_wx.py is maintained by hand.  Both are worth raising separately.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
git log --oneline -1

git rm -q p4gui.wxg && sed -n '1,10p' p4gui_wx.py

git add -A && git commit -q -F - <<'EOF'
Delete p4gui.wxg and the 150 tests that asserted on source text

p4gui.wxg was a wxGlade file last touched in March that nothing read.  Two
docstrings in p4gui_wx.py still claimed to be generated from it, which is worse
than saying nothing: it tells the next person to edit the wrong file and expect
their work to survive.  p4gui_wx.py has been hand-maintained for months and now
says so.

Then the rest of the grep tests, 149 of them plus one os.path.isfile assertion
that p4gui.wxg exists.  Same objection as the 34 deleted in 3f387d7: they open a
source file and assertIn a substring, so they execute nothing.  They cannot fail
when behaviour breaks and cannot pass when it works - they track spellings.
Nineteen classes and one whole file (test_t39_t41_autoconfig.py, which was 23
greps and nothing else) were left empty and went with them.

What they were "covering" is the point.  test_t22_calibrate_ibias_defined
asserted the string 'def calibrate_ibias' appears in configure_tab.py; the
routine could have been gutted and it would have stayed green - and while these
were in the suite, calibrate_igainfactor was leaving ud energised and
calibrate_enczero was silently skipping its ramp.  test_t41_step4_runs_
canopen_runner asserted _auto_configure mentions canopen_runner.start, which it
does, right next to the bug below.

371 tests, all green.  Every source module except odometer.py is still imported
and run by a test; nothing lost coverage that it had, because text assertions
were never coverage.

Found while reading _auto_configure for this, and NOT fixed here because it is
not a test change: **it skips Save.All and the reboot.**  on_config_browse runs
canopen_runner.start, then Save.All (0x65766173), then an NMT reset, because a
CSV load is RAM-only until saved and much of the config is latched at boot.
_auto_configure calls canopen_runner.start directly and does neither - then
immediately runs calibrate_all, which needs the config latched.  On a blank puck
that means ADCref = 0, BusVoltage = 0, DS402 fault 0x3220, and mode 12 rejected
with SDO abort 0x05040001, i.e. the calibration cannot run.  It also writes the
node ID as sdo[0x21B0][0] where on_set_id uses sdo['NetCfg'].

Left alone, both worth raising: four legacy files are down to file-exists /
importable / syntax-check boilerplate that every other test does implicitly, and
test_t30_t31_waves' survivors are "pure math" tests that reimplement the
waveform formulas inline rather than calling _generate_sample - superseded by
test_wave_generator.py and misleading, since they look like wave coverage.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
git log --oneline -1; git show --stat HEAD | tail -18

git rm --cached -q sandbox.conf && git commit -q --amend --no-edit && git show --stat HEAD | tail -16; echo "=== working tree ==="; git status --short
```

### Session `49a5616b` (started 2026-08-20)

```bash
cd ~/code/stm32 && git status --short | head; git branch -a --sort=-committerdate | head -20; echo ---; git log --oneline -8 feature/ls-filter; echo ---; git log --oneline -8 feature/kalman-vel; echo ---; git log --oneline -5 feature/watchdog-307 2>/dev/null; echo ---; git worktree list; ls; echo ---; cat build.sh 2>/dev/null | head -40

cd ~/code/stm32 && cat CLAUDE.md | head -80; echo ---; git show c64e0df --stat | head -30; echo ---; git show 39586cd --stat | head -20; echo; git show f7a500d --stat | head -30

cd ~/code/stm32 && git show bc04a63 | head -120; echo ======; git show f085d67 --stat | head -20; git log -1 --format=%B f085d67

cd ~/code/stm32 && git merge-tree --write-tree feature/ls-filter feature/kalman-vel 2>&1 | head -20; echo "---diff files kalman-vel vs base:"; git diff --stat 4ee599e feature/kalman-vel | tail -25; echo "---diff files ls-filter vs base:"; git diff --stat 4ee599e feature/ls-filter | tail -25

cd ~/code/stm32 && echo "eds ignoring EOL:"; git diff --stat --ignore-cr-at-eol 4ee599e feature/ls-filter -- puck4.eds; git diff --stat --ignore-cr-at-eol 4ee599e feature/kalman-vel -- puck4.eds; file <(git show 4ee599e:puck4.eds) <(git show feature/ls-filter:puck4.eds) <(git show feature/kalman-vel:puck4.eds); echo ---; git show feature/ls-filter:.gitattributes 2>/dev/null; echo "=== ls-filter parse_app.c"; git diff 4ee599e feature/ls-filter -- app/parse_app.c; echo "=== kalman-vel parse_app.c"; git diff 4ee599e feature/kalman-vel -- app/parse_app.c

cd ~/code/stm32 && for r in 4ee599e feature/ls-filter feature/kalman-vel; do printf "%s: " $r; git show $r:puck4.eds | head -3 | od -c | grep -c '\\r'; done; echo "=== ls-filter pwm.c"; git diff 4ee599e feature/ls-filter -- app/pwm.c; echo "=== kalman-vel pwm.c"; git diff 4ee599e feature/kalman-vel -- app/pwm.c

cd ~/code/stm32 && git -C worktrees/ls-filter status --short; git -C worktrees/ls-filter diff | head -60; echo "=== kalman-vel motion.c diff"; git diff 4ee599e feature/kalman-vel -- app/motion.c app/motion.h common/encoder.h app/homing.c

cd ~/code/stm32 && findmnt -no FSTYPE --target worktrees && git worktree add worktrees/kalman-ls -b feature/kalman-ls feature/ls-filter 2>&1 | tail -2 && cd worktrees/kalman-ls && git merge --no-commit feature/kalman-vel 2>&1 | tail -8; git status --short | head -20; grep -rn "MODE_IDLE" ../../app/*.h ../../common/*.h | head -3

cd ~/code/stm32/worktrees/kalman-ls && S=/tmp/claude-1000/-home-bz-code-p4gui/49a5616b-3816-4769-98cb-25c2c241060a/scratchpad && mkdir -p $S && python3 - <<'EOF'
import subprocess, re
def show(ref, path): return subprocess.check_output(['git','show',f'{ref}:{path}'], text=True)
# ---- parse_app.c
ls = show('feature/ls-filter','app/parse_app.c'); kv = show('feature/kalman-vel','app/parse_app.c')
def between(src, start, end):
    i = src.index(start); j = src.index(end, i); return src[i:j]
ls_funcs = between(ls, '/* 0x3019,5-6', 'int32_t parseStatsMode')
kv_func  = between(kv, '/* Velocity estimator record 0x3028', 'int32_t parseStatsMode')
m = open('app/parse_app.c').read()
i = m.index('<<<<<<< HEAD'); j = m.index('int32_t parseStatsMode')
m = m[:i] + ls_funcs + kv_func + m[j:]
assert '<<<<<<<' not in m and '>>>>>>>' not in m
open('app/parse_app.c','w').write(m)
# ---- pwm.c
p = open('app/pwm.c').read()
h1 = between(p, '<<<<<<< HEAD', '>>>>>>> feature/kalman-vel\n') + '>>>>>>> feature/kalman-vel\n'
head, kvs = h1.split('=======\n')
head = head.replace('<<<<<<< HEAD\n','')
kvs = kvs.replace('>>>>>>> feature/kalman-vel\n','')
# head: adopt + short export comment; kvs: long export comment. Keep adopt block + kalman comment.
adopt = head[:head.index('    // Export the dq-axis')]
p = p.replace(h1, adopt + kvs)
h2 = between(p, '<<<<<<< HEAD', '>>>>>>> feature/kalman-vel\n') + '>>>>>>> feature/kalman-vel\n'
keep = h2.split('=======\n')[0].replace('<<<<<<< HEAD\n','')
p = p.replace(h2, keep)
assert '<<<<<<<' not in p and '>>>>>>>' not in p, p.count('<<<<<<<')
open('app/pwm.c','w').write(p)
EOF
grep -n "log_state\|LOG_DUMP" app/pwm.c; echo "--- eds"; git show feature/ls-filter:puck4.eds > puck4.eds; git diff 4ee599e feature/kalman-vel -- puck4.eds | sed 's/\r$//' > $S/eds.patch; patch -p1 --dry-run < $S/eds.patch | tail -5

cd ~/code/stm32/worktrees/kalman-ls && S=/tmp/claude-1000/-home-bz-code-p4gui/49a5616b-3816-4769-98cb-25c2c241060a/scratchpad && python3 - <<EOF
import re
e = open('puck4.eds').read()
e = e.replace('[ManufacturerObjects]\nSupportedObjects=42\n', '[ManufacturerObjects]\nSupportedObjects=43\n')
e = e.replace('42=0x3027\n\n[1000]', '42=0x3027\n43=0x3028\n\n[1000]')
open('puck4.eds','w').write(e)
EOF
# extract only hunk 4 (0x3028 record) and apply
python3 - <<EOF
p = open('$S/eds.patch').read()
head, *hunks = p.split('\n@@ ')
h4 = [h for h in hunks if h.startswith('-2977,6')][0]
open('$S/eds_h4.patch','w').write(head + '\n@@ ' + h4)
EOF
patch -p1 < $S/eds_h4.patch && grep -n "3028" puck4.eds | head -5 && grep -c $'\r' puck4.eds; git add app/parse_app.c app/pwm.c puck4.eds && git status --short | grep -v "^[MA] " ; echo "--- check compile-relevant leftovers"; grep -n "log_state" app/*.c app/*.h | head

cd ~/code/stm32/worktrees/kalman-ls && rm -f puck4.eds.orig && git commit -q -m "Merge feature/kalman-vel into feature/ls-filter

Brings the three-state Kalman velocity estimator, the purr overlay rejection
in the position and velocity loops, and the u_polarity command-side fix
together with the watchdog, capture buffer, filter cutoff and commit stamp
work, so one image carries both for bench testing.

Conflicts: parse_app.c (both added handlers after parsePurr - kept both),
pwm.c (filter adopt + logRecord alongside the velkf update in case 3),
puck4.eds (ls-filter had converted CRLF to LF; re-applied the 0x3028 record
onto the LF file, 43 manufacturer objects)." && git -C ../ls-filter diff | git apply && git commit -q -am "pwm: read rt as 0.01 ohm in the derived filter cutoff, and record the capture buffer once per cycle

Taken from the uncommitted working tree of worktrees/ls-filter so this
image carries it. tau = lt/rt * 1e-3 s (both in 0.01 units), not 1e-2:
the derived id/iq cutoff was 10x too low. And logRecord() only from case 3,
where *motor.id/iq are final - case 1 duplicated every record." && git log --oneline -3 && grep -n "1.0e-3F / (float)\*motor.rt" app/pwm.c

cd ~/code/stm32/worktrees/kalman-ls && sed -i 's|uint32_t  \*j; //!< Motor rotor inertia (nNm\*s^2/rad)|uint32_t  *j; //!< Motor rotor inertia (g*cm^2 * 2^15, see motion_velkf_apply)|' app/pwm.h && git commit -q -am "velkf: read 0x3011,7 as g*cm^2 * 2^15, the unit the CSVs and p4gui write

motion_velkf_apply() scaled Calibration.j by 1e-9 as if it were nNm*s^2/rad.
The commissioning CSVs label it 'Motor J (gcm^2 * 2^15)' and p4gui commits
it that way, so the estimator's J was 327.68x too large: u_gain and sigma_u
327x too small, the gains solved for a motor that barely moves, and the purr
overlay accumulators 327x too small to reject anything." && ls ~/code/stm32/test/cpputest | head -3; ls ~/code/stm32/test | head; (./build.sh stm32 app release 2>&1 | tail -15)

cd ~/code/stm32/worktrees/kalman-ls/test && ./build/test_runner 2>&1 | tail -2 && cd .. && git commit -q -am "velkf: carry the purr's iq share to the overlay accumulator as a float

purr_iq_share was an int16_t, and the cast truncates toward zero. The
accumulator it feeds is a leaky integrator with DC gain 1/leak (~3200 steps at
the 1 Hz default), and the purr's waveform is asymmetric within a cycle, so
truncation left a DC of about 0.03 per-mille - 8 uA - that came out as a
190 cts/s offset in 0x3028,11. The velocity loop then servoed the rotor to
it: 3.4 RPM of steady creep at a commanded zero in profile velocity mode,
independent of purr volume, scaling as 1/corner (195, 67, 27, 6 cts/s at
1, 3, 10, 30 Hz). Measured on a P4-42, 2026-08-20." && ./build.sh stm32 app release 2>&1 | grep SIZE && cd ~/code/p4gui && timeout 300 bin/python3 -c "
import flashp4,glob; f=sorted(glob.glob('/home/bz/code/stm32/worktrees/kalman-ls/puck4.app.stm32.release.*.bin'),key=lambda p:__import__('os').path.getmtime(p))[-1]; print(f); print('result', flashp4.flash('can2',127,f))" 2>&1 | grep -v "^\[" | tail -4

cd ~/code/stm32 && git show 4ee599e --stat | head -20; git show 4ee599e -- app/pwm.c | head -80; echo ====; git show 5efdcfa --stat | head; git show 5efdcfa | grep "^[-+]" | grep -v "^+++\|^---" | head -20

cd ~/code/stm32 && git show 5efdcfa:app/pwm.c | sed -n 555,620p; echo "=== PI limits"; git show 5efdcfa:app/pwm.c | grep -n "UpperLimit\|LowerLimit\|max_effort" | head -20

cd ~/code/stm32 && git show 5efdcfa:app/pwm.c | sed -n 505,556p

cd ~/code/p4gui && S=/tmp/claude-1000/-home-bz-code-p4gui/49a5616b-3816-4769-98cb-25c2c241060a/scratchpad; timeout 20 bin/python3 -c "
import canopen; net=canopen.Network(); net.connect(bustype='socketcan', channel='can2', bitrate=1000000); n=net.add_node(127,'$S/puck4_kl.eds')
print('fw', hex(n.sdo[0x3003].raw), 'mode', n.sdo[0x6061].raw, 'status', hex(n.sdo[0x6041].raw), 'purr', [n.sdo[0x3027][s].raw for s in range(1,9)], 'velkf en/reject', n.sdo[0x3028][1].raw, n.sdo[0x3028][9].raw, '6081', n.sdo[0x6081].raw, 'j', n.sdo[0x3011][7].raw); net.disconnect()"; ls notes/bench | wc -l; git status --short | head; cd ~/code/stm32/worktrees/kalman-ls && git log --oneline -5 && git status --short | head -3

cd /home/bz/.claude/projects/-home-bz-code-p4gui/memory && python3 - <<'EOF'
p='purr-kalman-bench.md'; s=open(p).read()
old="""**Kick (>1000 cts every few seconds): not seen** in ~12 min of 100 Hz TPDO
logging on the new firmware, any mode/path. Investigation moved to reproducing
on the old release (`~/code/stm32/puck4.app.stm32.release.4ee599e.bin`).
Purr breath period on the bench is ~1.6 s (35 ppm), fundamentals ~30/38 Hz."""
new="""**Kick (>1000 cts every few seconds, user saw it at `15146ea`): NOT
reproduced** on f32eb87, 4ee599e, or 5efdcfa (=15146ea+ppm limit) — pos/vel/trq,
moves, volume 300, the user's RAM purr settings, 1.5 kHz spike polling, and the
purr generator's own output (max |107|). Read `5efdcfa` pwm.c: PI limits scale
with max_effort = live/nominal and include the decoupling, so the Q15 product
is ≤ 2^30 — **the 4ee599e overflow cannot fire in closed-loop modes**, only
where ud/uq are written directly (mode 12). So 4ee599e is a real fix but likely
not the kick's cause. Bench ratio is 420/232 = 1.81 anyway. Proposed next:
user reproduces in the GUI while `candump -l can2` runs; decode 0x1FF/0x2FF.
Purr breath period ~1.6 s (35 ppm), fundamentals ~30/38 Hz. Full write-up:
`~/code/p4gui/notes/bench/README.md`."""
assert old in s; s=s.replace(old,new); open(p,'w').write(s)
EOF
cd ~/code/p4gui && git check-ignore -v tools/bench/purr_pdo.py notes/bench/README.md; cat .gitignore 2>/dev/null | head

cd ~/code/p4gui && bin/python3 -m unittest discover -s test 2>&1 | grep -E "^(FAIL|ERROR):|Error|assert" | head -10; echo ---; git stash -q && bin/python3 -m unittest discover -s test 2>&1 | grep -E "^Ran|^OK|FAILED|^(FAIL|ERROR):" ; git stash pop -q && git status --short | head

cd /home/bz/.claude/projects/-home-bz-code-p4gui/memory && python3 - <<'EOF'
p='purr-kalman-bench.md'; s=open(p).read()
add='''
**Test-tab "click Run twice" (FIXED 2026-08-20 in `TestTab._pp_new_setpoint`):**
not the NEW-bit semantics — the firmware is edge-triggered and the host must
clear it, which the tab did. It was ordering: RPDO1 (ControlWord) and RPDO2
(TargetPosition) are independent cyclic tasks latched on SYNC, so 0x3F could
land before the new target and the drive captured the *previous* target
(3/7 scripted moves executed, each to the target before it). Fix: read 0x607A
back over SDO until it equals the new target before raising bit 4; bounded
waits; never raise the bit on a failed read-back. 7/7 in the harness, 6/6 with
the real TestTab method on the puck. Test: `test/test_pp_setpoint.py` (fake
drive with per-PDO SYNC latency, mutation-checked against the old sequence).
'''
s=s.replace("\nRelated: [[p4gui-identify-tab]]", add+"\nRelated: [[p4gui-identify-tab]]"); open(p,'w').write(s)
EOF
cd ~/code/p4gui && cat >> notes/bench/README.md <<'EOF'

## Test tab: position move needed two clicks (fixed)

Not the NEW-bit semantics — the firmware (`motion_controlword`) is
edge-triggered and the host must clear bit 4, which the tab already did. It
was ordering: RPDO1 and RPDO2 are independent cyclic tasks, both latched on
SYNC, so the 0x3F edge could land before the new TargetPosition and the drive
captured the stale one. Scripted with the tab's exact sequence: 3 of 7 moves
executed, each to the *previous* target (`oldfw_pos_moves_*.csv`). Fix in
`TestTab._pp_new_setpoint()`: read 0x607A back until it equals the new target
before raising bit 4, bounded waits, and no edge on a failed read-back.
Harness: 7/7 (`moves_fixed_*.csv`); real TestTab method on the puck: 6/6.
Covered by `test/test_pp_setpoint.py`, mutation-checked against the old
sequence (captures `[0]`, then `[0, 100]`).
EOF
git status --short

cd ~/code/p4gui && git add test_tab.py test/test_pp_setpoint.py && git commit -q -m "Test tab: read the target back before raising the new-setpoint bit

A profile-position move from the Test tab needed two clicks. Not the bit
semantics - the firmware is edge-triggered on ControlWord bit 4 and clears
the acknowledge when the host clears it, and the tab already did set, wait,
clear. It was ordering: RPDO1 (ControlWord) and RPDO2 (TargetPosition) are
independent cyclic tasks, both latched on SYNC, so the 0x3F edge could land
before the new TargetPosition did and the drive captured the stale one - a
zero-length move on the first click, and a move to the previous click's
target on the next. Scripted with the tab's exact sequence on a P4-42: 3 of
7 moves executed, each to the target before it.

_pp_new_setpoint() now writes the target, reads 0x607A back until the drive
reports it, and only then raises bit 4; waits for the acknowledge, drops the
bit, waits for it to clear. Every wait is bounded, and a failed read-back
does not raise the bit, since that would move to the stale target. The SYNC
keeps running, so the graphs are untouched. 7 of 7 scripted moves, and 6 of
6 through this method against the drive.

test_pp_setpoint.py models the drive with per-PDO SYNC latency; the old
sequence against it captures [0], then [0, 100].

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" && git log --oneline -1 && git status --short
```

### Session `1a79583a` (started 2026-08-20)

```bash
cat notes/bench/README.md; echo ----; ls tools/bench/; echo ----; cd ~/code/stm32 && git status --short | head; git branch -a | head -30; git worktree list; echo ----; ip -s -d link show can2 2>&1 | head -8

cd ~/code/stm32/worktrees/kalman-ls && git log --oneline -8 && git status --short | head && grep -rn "velkf\|0x3028" --include=*.c --include=*.h . | grep -v test/ | head -60

cd ~/code/stm32/worktrees/kalman-ls && python3 - <<'EOF'
import re,io
p='app/log.h'; s=open(p).read()
s=s.replace("""enum { LOG_IDLE = 0, LOG_COLLECT = 1, LOG_FULL = 2 };
""","""enum { LOG_IDLE = 0, LOG_COLLECT = 1, LOG_FULL = 2 };

/*! What each record holds (0x3004,6).  LOG_SRC_DQ is the original: id in the
 *  low 16 bits, iq in the high 16, both per-mille of i_peak.  LOG_SRC_ENC_VEL
 *  records the encoder position (0x6064, low 16 bits, wraps; unwrap on the
 *  host) together with the velocity estimate of the same control cycle
 *  (0x606C in units of 4 cts/s, high 16 bits, saturated at +-131068 cts/s).
 *  Position and estimate side by side is what lets a host judge the estimator
 *  against the motion that actually happened, at the rate it runs. */
enum { LOG_SRC_DQ = 0, LOG_SRC_ENC_VEL = 1 };
""")
s=s.replace("""//! Stop a capture and return to LOG_IDLE.
void logStop(void);
""","""//! Stop a capture and return to LOG_IDLE.
void logStop(void);

//! Choose what logRecord() stores (LOG_SRC_*). Takes effect at the next arm.
void logSetSource(uint8_t source);
""")
s=s.replace("""//! Record *index*: id in the low 16 bits, iq in the high 16, both signed
//! per-mille of i_peak. Reads outside what was captured return 0.""","""//! Record *index*, packed per the source it was armed with (see LOG_SRC_*).
//! Reads outside what was captured return 0.""")
open(p,'w').write(s)

p='app/log.c'; s=open(p).read()
s=s.replace("""static uint16_t          log_skip;       // cycles since the last record
""","""static uint16_t          log_skip;       // cycles since the last record
static uint8_t           log_source = LOG_SRC_DQ;   // what a record holds (0x3004,6)
static uint8_t           log_armed_source;          // latched at arm, read by the ISR
""")
s=s.replace("""  log_skip     = log_decimate - 1;   // so the first cycle after arming records
""","""  log_skip     = log_decimate - 1;   // so the first cycle after arming records
  log_armed_source = log_source;
""")
s=s.replace("""uint8_t logState(void) {""","""void logSetSource(uint8_t source) {
  log_source = source;
}

uint8_t logState(void) {""")
s=s.replace("""  uint16_t n = log_count;
  log_buf[n] = ((uint32_t)(uint16_t)*motor.iq << 16) | (uint16_t)*motor.id;
""","""  uint16_t n = log_count;
  if (log_armed_source == LOG_SRC_ENC_VEL) {
    // Velocity in 4 cts/s so a 16-bit field reaches +-1920 RPM on a 4096-count
    // encoder; the estimate's own noise floor is tens of cts/s, so nothing
    // worth seeing is lost to the 2-bit shift.
    int32_t v4 = *motor.enc.vel >> 2;
    v4 = v4 > 32767 ? 32767 : (v4 < -32768 ? -32768 : v4);
    log_buf[n] = ((uint32_t)(uint16_t)(int16_t)v4 << 16)
               | (uint16_t)(int16_t)*motor.enc.pos;
  } else {
    log_buf[n] = ((uint32_t)(uint16_t)*motor.iq << 16) | (uint16_t)*motor.id;
  }
""")
open(p,'w').write(s)

p='app/co_dict.c'; s=open(p).read()
s=s.replace("""    {0x3004, 0, U08, parseDefault, 5},    // Capture buffer, # of entries""","""    {0x3004, 0, U08, parseDefault, 6},    // Capture buffer, # of entries""")
s=s.replace("""    {0x3004, 5, U32, parseCapture, 0},    // Record at the cursor (id low 16, iq high 16); reading advances the cursor
""","""    {0x3004, 5, U32, parseCapture, 0},    // Record at the cursor (id low 16, iq high 16); reading advances the cursor
    {0x3004, 6, U08 | RW, parseCapture, 0},    // Source: 0 = id/iq, 1 = position low 16 | velocity/4 high 16
""")
open(p,'w').write(s)

p='app/parse_app.c'; s=open(p).read()
s=s.replace("""      case 4: // Read cursor
        data->value = SATURATE((uint16_t)*value, 0, LOG_MAX_RECORDS - 1);
        break;
      default:
        return SDO_ABORT_READ_ONLY;""","""      case 4: // Read cursor
        data->value = SATURATE((uint16_t)*value, 0, LOG_MAX_RECORDS - 1);
        break;
      case 6: // Source; takes effect at the next arm
        data->value = *value ? LOG_SRC_ENC_VEL : LOG_SRC_DQ;
        logSetSource((uint8_t)data->value);
        break;
      default:
        return SDO_ABORT_READ_ONLY;""")
open(p,'w').write(s)
EOF
git diff --stat; grep -n "include" app/parse_app.c | head; grep -n "enc.pos\b" app/pwm.h app/motion.h | head -3

cd ~/code/stm32/worktrees/kalman-ls && git add app/log.c app/log.h app/co_dict.c app/parse_app.c && git commit -q -m "Capture buffer: 0x3004,6 selects encoder position + velocity estimate as the record

The buffer recorded id/iq only.  Judging a velocity estimator needs the
estimate and the encoder position of the same control cycle, at the rate
the estimator runs - an SDO poll sees one sample per ~0.7 ms round trip and
cannot say how much of what it sees is the rotor and how much the filter.

Source 1 packs 0x6064's low 16 bits (wraps; unwrap on the host) with
0x606C in 4 cts/s (high 16, +-131068 cts/s).  Latched at arm so a running
capture never changes shape under the reader.  Default is unchanged.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" && git log --oneline -1 && (./build.sh stm32 app release 2>&1 | tail -1) && ls -t *.bin | head -1

cd ~/code/p4gui && sed -i "s/1000 rpm, 5 kHz capture — 33 \/ 167 \/ 200 \/ 400 Hz = 2×,10×,12×,24× f_rot/1000 rpm, 5 kHz capture — lines at 2×, 10×, 12×, 24× f_rot/" /tmp/claude-1000/-home-bz-code-p4gui/1a79583a-25e9-45de-b58e-8221a75d5ba2/scratchpad/fig.py && bin/python3 /tmp/claude-1000/-home-bz-code-p4gui/1a79583a-25e9-45de-b58e-8221a75d5ba2/scratchpad/fig.py && cat >> notes/bench/README.md <<'EOF'

## Velocity estimator noise: Kalman vs old differencing (2026-08-20, later)

Question: how much noisier is the Kalman estimate (0x3028,1 = 1) than the old
1 kHz differencing + 50 Hz biquad (0x3028,1 = 0), at 0 / 10 / 100 / 1000 rpm?
Both fill 0x606C, so one firmware, toggled at run time. Purr off. Device ended
on `ca5f7a1` = `f32eb87` + capture source selector (0x3004,6 = 1 records the
encoder position low 16 | 0x606C/4 high 16, same control cycle).

Harnesses: `tools/bench/vel_noise.py` (SDO poll of 0x606C at ~1.35 kHz, 10 s
per condition, iq every 10th read, mean checked against Δpos/Δt) and
`tools/bench/vel_capture.py` (0x3004 captures at 20 / 5 / 1 kHz, 512 records,
`--velkf-raw "4=1000"` for extra 0x3028 subs). Logs: `velnoise_full_*.csv`,
`velcap_full_*.csv`, `velcap_sigma*_*.csv`; analysis script was ad hoc
(numpy); figure `velnoise_20260820.png`.

### 0x606C statistics, SDO poll, 10 s each (cts/s; 4096 cts/rev → 68.27 cts/s per rpm)

| condition            | estimator   |    mean |     sd |    min |    max | Δpos/Δt | iq sd (‰) |
|----------------------|-------------|--------:|-------:|-------:|-------:|--------:|----------:|
| 0 rpm, drive idle    | Kalman      |     0.7 |  208.0 |  −1360 |   1217 |     0.0 |       0.8 |
|                      | diff+biquad |    −0.0 |   34.5 |   −136 |    150 |     0.0 |       1.2 |
| 0 rpm, vel-mode hold | Kalman      |     2.1 |  378.8 |  −1430 |   1721 |     1.8 |       0.6 |
|                      | diff+biquad |    −0.1 |  186.0 |   −765 |    748 |     0.6 |       0.7 |
| 10 rpm (683)         | Kalman      |   692.1 |  582.8 |  −1451 |   2625 |   692.6 |       1.8 |
|                      | diff+biquad |   694.5 |  536.8 |   −253 |   2913 |   695.8 |       2.4 |
| 100 rpm (6827)       | Kalman      |  6827.0 |  900.0 |   4272 |   9476 |  6847.3 |       1.8 |
|                      | diff+biquad |  6832.2 | 1528.1 |   3476 |   9815 |  6844.4 |       3.0 |
| 1000 rpm (68267)     | Kalman      | 68262.0 | 1065.7 |  65059 |  71717 | 68443.7 |       1.8 |
|                      | diff+biquad | 68267.3 |  724.6 |  66593 |  70277 | 68429.3 |       2.2 |

Means are unbiased for both (agree with Δpos/Δt to <0.3 %). The old path
returns the same value for ~30 % of consecutive reads (1 kHz update); the
Kalman ~1 % (20 kHz). The 1 kHz captures reproduce these numbers.

### What the sd is made of (control-rate captures)

- **At rest** the encoder sits on an edge and toggles ~1 count per ms. On the
  *same 512 ms of counts*, Kalman sd 173–215, the old algorithm replayed
  offline 30: **6–7× in sd, 10× in extremes** (±1260 vs ±120). The 20 kHz
  record shows why: a single-count step moves the old filter ~50–100 cts/s,
  but the Kalman treats it as acceleration — the load-torque state integrates
  and the velocity ramps for ~1 ms, to 300–1300 cts/s, until the next count
  corrects it. The innovation deadband (0x3028,5 = 0.5 ct) cannot catch
  full-count steps. It is a gain question, not a bug: sigma_enc (0x3028,4)
  500/1000/2000/4000 (λ 7/4/2/1) gave rest sd 158/69/143/145 and extremes
  ±800/±420/±450/±540 — better, but still 2–5× the old path, and sd at
  100 rpm rose to 1093 at 4000. Not a 10× fix.
- **10 rpm** (0.68 ct/ms — below the old path's 1 ct/ms quantum): both loops
  hunt at ~0.8 Hz with ±500 cts/s; the sd is the loop, not the estimator.
- **100 rpm**: the sd is real rotor ripple at 5×f_rot = 8.3 Hz (pole pairs,
  10-pole motor) plus 10× at 16.7 Hz. On the Kalman's own position stream the
  old algorithm replayed gives the same sd (734 vs 786) — the Kalman adds
  nothing here. And **the ripple itself is 2× smaller with the Kalman closing
  the loop** (position-derived 8.3 Hz line 557–577 vs 1115–1214 cts/s rms,
  both reps), i.e. the fresher, lag-free feedback lets the velocity PI reject
  the torque ripple better. That is why the old path reads 1528 vs 900.
- **1000 rpm**: real lines at 2× (33 Hz, ~585 both), 10× (167 Hz, ~350), 12×
  (200 Hz, ~150) and 24× (400 Hz, ~400). The old path's 50 Hz biquad removes
  everything above ~80 Hz (×0.05 at 167 Hz): its 725 is *under*-reporting. The
  Kalman passes them and **peaks ×1.35 at 167 Hz and ×1.85 at 200 Hz**
  (5 kHz captures, both reps), rolling off to ×0.44 at 400 Hz. Old replayed on
  the Kalman's motion: 570 vs Kalman 1050; so at 1000 rpm roughly half the
  Kalman's excess sd is content the old filter hides and half is its own
  150–200 Hz peaking.

Summary: the Kalman is unbiased at every speed, ~6× noisier in sd (10× in
peaks) at stall because of the way it responds to single-count steps, equal at
10 rpm, and at 100 rpm it gives a *cleaner* loop; at 1000 rpm it is ~1.4×
the old sd, of which the peaking around 170–200 Hz is the part worth a look.
EOF
git -C ~/code/p4gui status --short | head

cd ~/code/stm32/worktrees/kalman-ls && git add app/velkf.c app/velkf.h app/pwm.c app/motion.c test/phase1/VelKfTest.cpp && git commit -q -m "Run the purr rejection over the differencing estimator too

The overlay accumulators are an open-loop model of the plant's response to
the purr current - Kt/J through a leaky double integrator - and read neither
the encoder nor the Kalman gains, yet they only ran when the Kalman filter
did.  On the bench the rejection is what the purr gains from the estimator
change (vel-loop error sd 5100 -> 1500, iq noise -25 %, purr not reinforced
by a lagging loop); the estimate itself is buried under the purr either way.

velkf_configure() now sets overlay_valid from the plant terms alone and
solves the estimator only if the noise terms are there too.  The ISR runs the
overlay whenever overlay_valid.  Over the differencing path the velocity share
is published by motion_control(), put through the same 1 kHz difference and
the same biquad as the measurement it is subtracted from, so the two carry
the same lag and cancel instead of beating.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" && git log --oneline -1 && (./build.sh stm32 app release 2>&1 | tail -1) && cd ~/code/p4gui && BIN=$(ls -t ~/code/stm32/worktrees/kalman-ls/puck4.app.stm32.release.*.bin | head -1) && echo $BIN && timeout 300 bin/python3 -c "
import flashp4; print('result', flashp4.flash('can2', 127, '$BIN'))" 2>&1 | grep -E "Flashloader|validated|result" ; sleep 4; bin/python3 - <<'EOF'
import canopen
net = canopen.Network(); net.connect(bustype='socketcan', channel='can2', bitrate=1000000)
n = net.add_node(127, '/home/bz/code/stm32/worktrees/kalman-ls/puck4.eds'); n.sdo.RESPONSE_TIMEOUT=2.0
print('fw %07x' % n.sdo[0x3003].raw, 'status %#06x' % n.sdo[0x6041].raw, '0x3028:', [n.sdo[0x3028][s].raw for s in range(1,12)], 'purr en', n.sdo[0x3027][1].raw)
net.disconnect()
EOF

cd ~/code/stm32/worktrees/kalman-ls && echo "--- 0x3028 OD comment"; sed -n 508,516p app/co_dict.c; echo "--- velkf references outside velkf.c/h"; grep -n "velkf\|overlay" app/*.c app/*.h | grep -v "^app/velkf" | grep -v "^\s*\*" | wc -l; grep -ln "velkf\|overlay" app/*.c app/*.h | grep -v "^app/velkf"; echo "--- what motion_velkf_apply reads"; sed -n 864,892p app/motion.c | grep -n "parse\|motor\.\|velkf_od\|amp\." ; echo "--- velkf.c size / DARE"; wc -l app/velkf.c app/velkf.h; grep -n "double" app/velkf.c | wc -l; echo "--- NV / field"; grep -n "NV" app/parse*.h common/parse.h 2>/dev/null | head -5; git log --oneline main..HEAD 2>/dev/null | wc -l; git log --oneline devel..HEAD 2>/dev/null | wc -l; echo "--- p4gui refs"; grep -rn "3028\|velkf\|kalman" ~/code/p4gui/*.py | head

cd ~/code/stm32 && git worktree add -b feature/purr-reject worktrees/purr-reject feature/kalman-ls 2>&1 | tail -1 && cd worktrees/purr-reject && findmnt -no FSTYPE --target . && grep -n "velkf\|overlay\|VELKF\|Velkf" app/*.c app/*.h | grep -v "^app/velkf\." ; echo "--- makefiles"; grep -n "velkf\|VelKf" Makefile test/Makefile stm32/*.mk 2>/dev/null; grep -rn "velkf\|VelKf" --include=Makefile --include=*.mk . | grep -v "^./test/cpputest" | head; echo "--- lag factor history"; git log --oneline -S"lag_factor" -- app/co_dict.c | tail -3

cd ~/code/stm32/worktrees/purr-reject && echo "--- Makefile sources"; grep -n "wildcard\|SRCS\|\.c\b" Makefile | head -15; echo "--- lag_factor"; git log --oneline -S"lag_factor" | tail -2; grep -n "lag_factor" app/*.c app/*.h | head; echo "--- pwm.c 100-130"; sed -n 100,130p app/pwm.c; echo "--- pwm.c 385-395"; sed -n 385,395p app/pwm.c; echo "--- motion.c 40-100"; sed -n 40,100p app/motion.c; echo "--- motion.c 185-200"; sed -n 185,200p app/motion.c; echo "--- motion.c 855-910"; sed -n 855,910p app/motion.c; echo "--- motion.c 945-955"; sed -n 945,955p app/motion.c; echo "--- motion.c 1296-1305"; sed -n 1296,1305p app/motion.c; echo "--- motion.h 125-160"; sed -n 125,160p app/motion.h; echo "--- parse_app.c 410-460"; sed -n 410,460p app/parse_app.c; echo "--- parse_app.h"; grep -n "parseVelKF\|parsePurr" app/parse_app.h; echo "--- co_dict 495-530"; sed -n 495,530p app/co_dict.c; echo "--- homing.c 1-40"; sed -n 1,40p app/homing.c; echo "--- pwm.h 80-90"; sed -n 80,90p app/pwm.h; echo "--- test/Makefile 45-70"; sed -n 45,70p test/Makefile

cd ~/code/stm32/worktrees/purr-reject && cat > app/purr_reject.h <<'EOF'
/* purr_reject.h
 *
 * Purr rejection: an open-loop model of how much of the rotor's motion the
 * purr overlay is responsible for.
 *
 * The purr (purr_torque.c) is a torque overlay added downstream of the
 * position and velocity loops, so both loops see the motion it causes as
 * error and fight it. Any asymmetry in that fight - a torque clamp, the PI's
 * own output limit, the lag of the velocity filter - rectifies a zero-mean
 * disturbance into a DC one the integrator then winds up on, and a lagging
 * loop partly reinforces the purr instead of ignoring it (measured on a P4-42,
 * 2026-08-20: 1.5x the purr velocity and 30 % more iq noise without this).
 *
 * This module integrates the overlay's share of the q-axis current through
 * the plant - acceleration = Kt * i / J - into a position and a velocity the
 * controllers subtract from their feedback. 0x6064/0x606C stay untouched and
 * keep reporting what the rotor actually did. Both accumulators leak toward
 * zero with a first-order corner (0x3027,10) so an error in Kt, J or the
 * current-share calculation cannot integrate without bound; the purr's band
 * (tens of Hz) sits well above the corner, so the cancellation there is
 * unaffected.
 *
 * It needs the motor commissioned: ts, encoder resolution, Kt, J and i_peak.
 * Leave J (0x3011,7) at zero and the model stays invalid and nothing is
 * subtracted.
 */

#ifndef PURR_REJECT_H_
#define PURR_REJECT_H_

#include <stdbool.h>
#include <stdint.h>

typedef struct {
  float ts; //!< Control period (s)
  float counts_per_rev; //!< Encoder resolution (cts)
  float kt; //!< Torque constant (mNm per A rms)
  float j; //!< Rotor inertia (kg*m^2)
  float i_peak; //!< Full scale of the 0x6078 current feedback (mA)
  float f_corner; //!< Leak corner (Hz); <= 0 disables the rejection
} purr_reject_params_t;

typedef struct {
  // Runtime state, touched every control cycle
  float pos; //!< Overlay's share of position (cts)
  float vel; //!< Overlay's share of velocity (cts/step)

  // Model, fixed by purr_reject_configure()
  float u_gain; //!< cts/step^2 per per-mille of i_peak
  float leak; //!< Per-step decay of both accumulators; 1.0 = rejection off
  float inv_ts; //!< 1 / ts, converts cts/step to cts/s
  bool valid; //!< False until the motor specs are all known
} purr_reject_t;

/*! Build the model from the motor specs. Cheap (a few multiplies), but
 *  configure into a scratch instance and swap under a critical section if the
 *  control loop is already running; the swap zeroes the accumulators. Leaves
 *  valid false if any spec is at or below zero. */
void purr_reject_configure(purr_reject_t *pr, const purr_reject_params_t *p);

/*! Zero the accumulators without disturbing the model. */
void purr_reject_reset(purr_reject_t *pr);

/*! Advance one control period. iq_overlay is the overlay's share of the
 *  q-axis current in per-mille of i_peak (float, unquantized: a truncated
 *  int16 left a ~0.03 per-mille DC that the leaky integrator's 1/leak gain
 *  turned into a 3.4 RPM creep). Call from the control ISR. */
void purr_reject_update(purr_reject_t *pr, float iq_overlay);

#endif /* PURR_REJECT_H_ */
EOF
cat > app/purr_reject.c <<'EOF'
/* purr_reject.c - see purr_reject.h */

#include "purr_reject.h"

#define PR_TWO_PI (6.283185307F)
#define PR_SQRT2  (1.414213562F)

void purr_reject_reset(purr_reject_t *pr) {
  pr->pos = 0.0F;
  pr->vel = 0.0F;
}

void purr_reject_configure(purr_reject_t *pr, const purr_reject_params_t *p) {
  pr->valid = false;
  pr->u_gain = 0.0F;
  pr->leak = 1.0F;
  pr->inv_ts = 0.0F;
  purr_reject_reset(pr);

  // An uncommissioned motor leaves most of these at zero
  if (!(p->ts > 0.0F) || !(p->counts_per_rev > 0.0F) || !(p->kt > 0.0F) ||
      !(p->j > 0.0F) || !(p->i_peak > 0.0F)) {
    return;
  }

  /* Torque per per-mille of the 0x6078 current feedback. 6078 reports iq as
   * 1/1000 of i_peak, which is a peak amplitude, while kt is quoted per A rms
   * - hence the sqrt(2). The 1e9 folds mNm -> Nm with mA -> A. This is the
   * same chain motion_trq_control() runs in the opposite direction. */
  const float nm_per_pm = p->kt * p->i_peak / (PR_SQRT2 * 1.0e9F);
  const float cts_per_rad = p->counts_per_rev / PR_TWO_PI;

  // Acceleration, in cts/step^2, per per-mille of iq
  pr->u_gain = nm_per_pm / p->j * cts_per_rad * p->ts * p->ts;
  pr->inv_ts = 1.0F / p->ts;

  /* A leak of 1.0 zeroes the accumulators every step, which is how
   * f_corner <= 0 disables the feature without a branch in the control loop. */
  pr->leak = (p->f_corner > 0.0F) ? PR_TWO_PI * p->f_corner * p->ts : 1.0F;
  if (pr->leak > 1.0F) pr->leak = 1.0F;

  pr->valid = true;
}

void purr_reject_update(purr_reject_t *pr, float iq_overlay) {
  const float u = pr->u_gain * iq_overlay;

  // Constant-acceleration step over the period
  pr->pos += pr->vel + 0.5F * u;
  pr->vel += u;

  pr->pos -= pr->leak * pr->pos;
  pr->vel -= pr->leak * pr->vel;
}
EOF
git rm -q app/velkf.c app/velkf.h test/phase1/VelKfTest.cpp && sed -i 's#    ../app/velkf.c \\#    ../app/purr_reject.c \\#' test/Makefile && grep -n "purr_reject" test/Makefile && echo "--- parsePurr"; grep -n "int32_t parsePurr" -A 45 app/parse_app.c | head -60; echo "--- gen_eds usage"; head -30 scripts/gen_eds.py | grep -v "^$"

cd ~/code/stm32/worktrees/purr-reject && grep -n "cpputest\|CPPUTEST" test/Makefile | head -5; ls ../kalman-ls/test/cpputest | head -3; ln -s ../../kalman-ls/test/cpputest test/cpputest && rm -rf test/build && (cd test && make -j$(nproc) 2>&1 | grep -E "error|Error" | head -5; make test 2>&1 | tail -2); git status --short | head; echo "--- 0x2280,2 origin"; git log --oneline -S"Use Kalman estimator" -- app/co_dict.c | tail -1; grep -rn "0x2280" app/*.c | grep -v co_dict | head -3; echo "--- EDS regen"; python3 scripts/gen_eds.py -r puck4.eds -o puck4.eds 2>&1 | tail -2; git diff --stat puck4.eds; git diff puck4.eds | grep "^[-+]" | grep -v "^[-+][-+]" | head -40

cd ~/code/stm32/worktrees/purr-reject && git checkout puck4.eds && git show HEAD:puck4.eds | file - ; grep -n "^\[3027\|^\[3028" puck4.eds | head -30; echo "--- 3027sub9 + 3028 section shapes"; grep -n -A 8 "^\[3027sub9\]" puck4.eds; grep -n -A 9 "^\[3028\]" puck4.eds; grep -n -A 8 "^\[3028sub9\]" puck4.eds; grep -n -A 8 "^\[3028sub10\]" puck4.eds; echo "--- tests"; ./test/build/test_runner -v 2>/dev/null | grep -c "^TEST(PurrReject" ; ./test/build/test_runner -v 2>/dev/null | grep "PurrReject" | head -8; ls test/build/ | head

cd ~/code/stm32/worktrees/purr-reject && python3 - <<'EOF'
import re
s=open('puck4.eds').read()
# 1. remove [3028] .. through the last [3028subX] section
start=s.index('[3028]\n')
m=re.search(r'\n\[(?!3028)[0-9A-Fa-f]{4}(sub[0-9a-f]+)?\]\n', s[start:])
end=start+m.start()+1
removed=s[start:end]; s=s[:start]+s[end:]
assert '[3028' not in s
# 2. 3027 SubNumber / sub0 default
sec=s.index('[3027]\n'); nxt=s.index('[3027sub0]\n')
blk=s[sec:nxt]; assert 'SubNumber=10' in blk; s=s[:sec]+blk.replace('SubNumber=10','SubNumber=13')+s[nxt:]
sec=s.index('[3027sub0]\n'); nxt=s.index('[3027sub1]\n')
blk=s[sec:nxt]; assert 'DefaultValue=9' in blk; s=s[:sec]+blk.replace('DefaultValue=9','DefaultValue=12')+s[nxt:]
# 3. add sub a/b/c after sub9
sec=s.index('[3027sub9]\n'); nxt=s.index('\n[', sec+1)+1
add='''[3027suba]
ParameterName=PurrRejectionLeakCorner
ObjectType=0x07
DataType=0x0006
AccessType=rw
DefaultValue=10

[3027subb]
ParameterName=PurrSShareOfPosition
ObjectType=0x07
DataType=0x0004
AccessType=ro
DefaultValue=0

[3027subc]
ParameterName=PurrSShareOfVelocity
ObjectType=0x07
DataType=0x0004
AccessType=ro
DefaultValue=0

'''
s=s[:nxt]+add+s[nxt:]
# 4. object lists
for sect in ('[ManufacturerObjects]','[OptionalObjects]','[MandatoryObjects]'):
    if sect in s:
        a=s.index(sect); b=s.index('\n[',a+1)
        blk=s[a:b]
        lines=blk.split('\n')
        if any('0x3028' in l for l in lines):
            kept=[l for l in lines if '0x3028' not in l]
            # renumber entries and fix SupportedObjects
            head=[l for l in kept if '=' not in l or l.startswith('SupportedObjects')]
            ents=[l.split('=')[1] for l in kept if '=' in l and not l.startswith('SupportedObjects')]
            new=[sect,'SupportedObjects=%d'%len(ents)]+['%d=%s'%(i+1,e) for i,e in enumerate(ents)]
            s=s[:a]+'\n'.join(new)+s[b:]
            print(sect,'renumbered to',len(ents))
open('puck4.eds','w').write(s)
print('removed',removed.count('['),'sections')
EOF
grep -c "3028" puck4.eds; grep -n -B2 -A3 "0x3027$" puck4.eds | head -12; git diff --stat puck4.eds

cd ~/code/stm32/worktrees/purr-reject && python3 - <<'EOF'
s=open('puck4.eds').read()
s=s.replace('42=0x3027\n[1000]','42=0x3027\n\n[1000]')
open('puck4.eds','w').write(s)
EOF
git add -A app test/phase1/PurrRejectTest.cpp test/Makefile puck4.eds && git status --short | grep -v "^[AMDR] " | head; git commit -q -m "Excise the Kalman velocity estimator; keep the purr rejection as purr_reject.c

On the bench (notes in p4gui/notes/bench/README.md, 2026-08-20) the Kalman
estimate was unbiased but 6-7x noisier in sd and 10x in peaks at stall than
the 1 kHz differencing + biquad it replaced - a single encoder count's dither
ramps its velocity for a millisecond - equal at 10 rpm, and at 1000 rpm it
peaked x1.4-1.9 around 170-200 Hz.  Its one measured win, 2x less pole-pair
ripple at 100 rpm, does not matter for hold-then-move applications.  The
thing the purr gained from the branch was the overlay rejection, which is an
open-loop model of the plant and never needed the estimator (b3be845).

So: velkf.c/h and 0x3028 go; 0x606C is the differencing path again,
unconditionally.  The rejection moves to purr_reject.c - u_gain from Kt, J,
i_peak, resolution and ts; a leaky double integrator of the purr's iq share;
valid only once J and Kt are commissioned - and its corner to 0x3027,10
(0.1 Hz, 0 = off) with the position/velocity shares at 0x3027,11/12.  NV
ordinals shift relative to the unreleased Kalman branches only.  The
velocity share is still published through the same 1 kHz difference and
biquad as the measurement.  Tests: VelKfTest.cpp -> PurrRejectTest.cpp (6).
EDS hand-edited to match; the Riccati solve's 0.29 s main-loop stall on
every 0x3028 write is gone with it.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" && git log --oneline -1 && (./build.sh stm32 app release 2>&1 | tail -1) && cd ~/code/p4gui && BIN=$(ls -t ~/code/stm32/worktrees/purr-reject/puck4.app.stm32.release.*.bin | head -1) && echo $BIN && timeout 300 bin/python3 -c "
import flashp4; print('result', flashp4.flash('can2', 127, '$BIN'))" 2>&1 | grep -E "validated|result"; sleep 4; bin/python3 - <<'EOF'
import canopen, struct
net = canopen.Network(); net.connect(bustype='socketcan', channel='can2', bitrate=1000000)
n = net.add_node(127, '/home/bz/code/stm32/worktrees/purr-reject/puck4.eds'); n.sdo.RESPONSE_TIMEOUT=2.0
print('fw %07x' % n.sdo[0x3003].raw, 'status %#06x' % n.sdo[0x6041].raw)
print('0x3027:', [n.sdo[0x3027][s].raw for s in range(0,13)])
try: print('0x3028,0 ->', n.sdo.upload(0x3028,0))
except Exception as e: print('0x3028 gone:', e)
print('J', n.sdo[0x3011][7].raw, 'Kt', n.sdo[0x3011][4].raw, 'i_peak', n.sdo[0x3011][9].raw)
net.disconnect()
EOF

cd ~/code/stm32 && git log --oneline -3 feature/purr; echo "--- merge-base purr..purr-reject"; git merge-base feature/purr feature/purr-reject; echo "--- commits on purr not in purr-reject:"; git log --oneline feature/purr-reject..feature/purr | head; echo "--- commits on purr-reject not in purr:"; git log --oneline feature/purr..feature/purr-reject | wc -l; echo "--- fixes: polarity / watchdog / githash commits"; git log --oneline feature/purr-reject -i --grep="polarity\|u_polarity" | head; echo ..; git log --oneline feature/purr-reject -i --grep="watchdog" | head; echo ..; git log --oneline feature/purr-reject -i --grep="hash\|stamp\|version" | head; echo "--- are those in purr-reject (ancestor check)"; for c in $(git log --format=%h feature/purr-reject -i --grep="polarity\|watchdog\|githash\|git hash\|stamp the commit" | head -12); do printf "%s " $c; git merge-base --is-ancestor $c feature/purr-reject && echo yes || echo NO; done; echo "--- worktree status"; git -C worktrees/purr-reject status --short | head -5

cd ~/code/stm32 && echo "=== 1. u_polarity on the torque command (39586cd) — tree content on purr-reject"; git grep -n "u_polarity" feature/purr-reject -- app/pwm.c app/motion.c | head -12; echo; echo "=== 2. watchdog (bc04a63) — its hunks still present?"; git show bc04a63 --stat | tail -6; for f in $(git show bc04a63 --name-only --format= ); do echo "-- $f"; git show bc04a63 -- $f | grep "^+" | grep -v "^+++" | grep -v "^+\s*\(/\*\|\*\|//\)" | grep -v "^+\s*$" | head -4 | while IFS= read -r l; do pat="${l#+}"; pat="$(echo "$pat" | sed 's/^[[:space:]]*//')"; if git grep -qF -- "$pat" feature/purr-reject -- "$f"; then echo "   present: ${pat:0:70}"; else echo "   MISSING: ${pat:0:70}"; fi; done; done; echo; echo "--- feature/watchdog-307 (f085d67) ancestor of purr-reject?"; git merge-base --is-ancestor f085d67 feature/purr-reject && echo yes || echo "no (separate branch)"; git log --oneline -3 feature/watchdog-307; echo; echo "=== 3. git hash stamp (ed8287c) — 0x3003 wiring + Makefile"; git grep -n "GITHASH\|githash" feature/purr-reject -- Makefile app/co_dict.c app/version.h 2>/dev/null | head -8; echo "(device read 0x3003 = a83e5a8 after flashing a83e5a8 — live confirmation)"; echo; echo "=== merge (fast-forward feature/purr to feature/purr-reject)"; git push . feature/purr-reject:feature/purr 2>&1 | tail -3; git log --oneline -1 feature/purr; git merge-base --is-ancestor feature/purr-reject feature/purr && git rev-parse --short feature/purr feature/purr-reject

cd ~/code/stm32 && echo "=== 1. u_polarity on the torque command (39586cd) — tree content on purr-reject"; git grep -n "u_polarity" feature/purr-reject -- app/pwm.c | head -8; echo; echo "=== 2. watchdog (bc04a63) — files and whether its added lines are still in the tree"; git show bc04a63 --stat --format= | tail -5; git show bc04a63 --format= -- app/main.c app/hal.c stm32/hal.c 2>/dev/null | grep "^+" | grep -v "^+++\|^+\s*$\|^+\s*[/*]" | head -8; echo "--- watchdog-related lines on purr-reject:"; git grep -n -i "watchdog\|iwdg\|wdg" feature/purr-reject -- app/*.c stm32/*.c | grep -v "^\S*:\s*[/*]" | head -12; echo; echo "--- feature/watchdog-307 (f085d67) in purr-reject?"; git merge-base --is-ancestor f085d67 feature/purr-reject && echo yes || echo "no (separate branch)"; git log --oneline -2 feature/watchdog-307; echo; echo "=== 3. git hash stamp (ed8287c)"; git grep -n "GITHASH\|githash\|0x3003" feature/purr-reject -- Makefile app/co_dict.c app/version.h | head -8

cd ~/code/stm32 && echo "--- flashloader diff watchdog-307 vs purr-reject:"; git diff --stat feature/watchdog-307 feature/purr-reject -- flashloader/ | tail -3; git diff feature/watchdog-307 feature/purr-reject -- flashloader/main.c | grep "^[-+]" | grep -v "^[-+][-+]" | grep -i "wdog\|watchdog\|RDP\|rdp" | head -10; echo "--- is bc04a63's flashloader hunk = f085d67's?"; git log --oneline -1 -S"hal_wdog" feature/purr-reject -- flashloader/main.c; git log --oneline -1 -S"hal_wdog" feature/watchdog-307 -- flashloader/main.c; echo; echo "=== fast-forward feature/purr -> feature/purr-reject"; git merge-base --is-ancestor feature/purr feature/purr-reject && git branch -f feature/purr feature/purr-reject && git log --oneline -1 feature/purr && echo "ff ok; commits on feature/purr past 4ee599e:" && git log --oneline 4ee599e..feature/purr | wc -l
```

### Session `03f3d294` (started 2026-08-20)

```bash
cd ~/code/stm32 && git branch --show-current && git status --short | head && ls && grep -rn "pwm_execute\|motion_control" --include=*.c --include=*.h -l | head -30

cd ~/code/p4gui && for m in trq vel pos; do echo "=== mode $m, purr off"; timeout 90 bin/python3 tools/bench/exectime.py --mode $m --purr 0 --duration 10 --csv notes/bench/exectime.csv --label "purr-off-$m" 2>&1 | tail -7; done; echo ==== EDS; cd ~/code/stm32 && cp puck4.eds /tmp/claude-1000/-home-bz-code-p4gui/03f3d294-4439-43ad-92ef-77f4f46bbc19/scratchpad/puck4.eds.ref && python3 scripts/gen_eds.py -r /tmp/claude-1000/-home-bz-code-p4gui/03f3d294-4439-43ad-92ef-77f4f46bbc19/scratchpad/puck4.eds.ref -o puck4.eds 2>&1 | tail -3; git diff --stat puck4.eds; grep -n "^\[3028sub1\]" -A5 puck4.eds

cd ~/code/stm32 && file puck4.eds; git show HEAD:puck4.eds | file -; git diff --ignore-all-space --stat puck4.eds; git diff --ignore-all-space puck4.eds | grep "^[-+]" | grep -v "^+++\|^---" | head -20

cd ~/code/stm32 && grep -c $'\r' puck4.eds; sed -i 's/\r$//' puck4.eds; git diff --stat puck4.eds; git diff puck4.eds | grep "^[-+]" | grep -v "^+++\|^---\|3028\|Time=\|Date=" | head -40

cd ~/code/stm32 && git show HEAD:puck4.eds | sed -n '/^\[3003\]/,/^$/p'; sed -n '/^\[3003\]/,/^$/p' puck4.eds; ~/code/p4gui/bin/python3 -c "
import canopen; od=canopen.import_od('puck4.eds'); o=od[0x3028]; print(o.name, len(o.subindices), o[1].name, o[26].name, od[0x3003].default if hasattr(od[0x3003],'default') else None)"

cd ~/code/stm32 && python3 - <<'EOF'
import re
p='app/co_dict.c'; s=open(p).read()
# "pwm_execute case N, last (ns)" -> "pwm_execute case N last (ns)" so gen_eds.py derives PwmExecuteCase1Last etc.
s2 = re.sub(r'(// (?:pwm_execute case \d|motion_control (?:wall|self))), (last|min|max|mean) \(ns\)', r'\1 \2 (ns)', s)
assert s2.count(' last (ns)')==6 and s2 != s
open(p,'w').write(s2)

p='scripts/gen_eds.py'; s=open(p).read()
old='''    if datatype != DTYPE_VISIBLE_STRING:
        return raw
    try:
        value = int(raw, 0)
    except (TypeError, ValueError):
        return raw
'''
new='''    try:
        value = int(raw, 0)
    except (TypeError, ValueError):
        # A macro (GIT_HASH, filled in by the build), not a literal: the EDS
        # has no way to carry it, and a bare identifier is not a valid token.
        return "0"
    if datatype != DTYPE_VISIBLE_STRING:
        return raw
'''
assert s.count(old)==1; s=s.replace(old,new,1); open(p,'w').write(s)
EOF
python3 scripts/gen_eds.py -r /tmp/claude-1000/-home-bz-code-p4gui/03f3d294-4439-43ad-92ef-77f4f46bbc19/scratchpad/puck4.eds.ref -o puck4.eds | tail -1; sed -i 's/\r$//' puck4.eds; grep -c $'\r' puck4.eds; awk '/^\[/{sec=$0} /^ParameterName=/{if(sec ~ /^\[3028/) printf "%s %s | ", sec, $0}' puck4.eds; echo; sed -n '/^\[3003\]/,/^$/p' puck4.eds | grep Default; git diff --stat; ~/code/p4gui/bin/python3 -c "
import canopen; od=canopen.import_od('puck4.eds'); print(od[0x3028][26].name, od[0x3028][6].name)"

cd ~/code/stm32 && grep -n "_WORD_RE" scripts/gen_eds.py | head -2; sed -i 's/^_WORD_RE = re.compile(r"\[A-Za-z\]+")/_WORD_RE = re.compile(r"[A-Za-z0-9]+")/' scripts/gen_eds.py; grep -n "^_WORD_RE" scripts/gen_eds.py; python3 scripts/gen_eds.py -r /tmp/claude-1000/-home-bz-code-p4gui/03f3d294-4439-43ad-92ef-77f4f46bbc19/scratchpad/puck4.eds.ref -o puck4.eds | tail -1; sed -i 's/\r$//' puck4.eds; awk '/^\[/{sec=$0} /^ParameterName=/{if(sec ~ /^\[30(28|04)sub/) printf "%s=%s ", substr(sec,2,length(sec)-2), substr($0,15)}' puck4.eds; echo; git diff puck4.eds | grep "^-ParameterName" | head

cd ~/code/stm32 && sed -i -E 's#// pwm_execute case ([1-4]) (last|min|max|mean) \(ns\)#// pwm_execute case\1 \2 (ns)#' app/co_dict.c && grep -c "pwm_execute case[1-4] " app/co_dict.c && python3 scripts/gen_eds.py -r /tmp/claude-1000/-home-bz-code-p4gui/03f3d294-4439-43ad-92ef-77f4f46bbc19/scratchpad/puck4.eds.ref -o puck4.eds | tail -1 && sed -i 's/\r$//' puck4.eds && awk '/^\[/{sec=$0} /^ParameterName=/{if(sec ~ /^\[3028sub/) printf "%s ", substr($0,15)}' puck4.eds; echo; ./build.sh stm32 app release 2>&1 | grep -E "error|warning|SIZE"; git status --short | grep -v "^??"
```

### Session `864112d3` (started 2026-08-26)

```bash
git show fcce6fc --stat 2>&1 | head -30

git branch --contains fcce6fc; git merge-base --is-ancestor fcce6fc HEAD && echo "already in HEAD" || echo "not in HEAD"

git show fcce6fc -- test_tab.py | head -150

git status --porcelain -- test_tab.py test/test_pp_setpoint.py && git cherry-pick -x fcce6fc 2>&1

git stash -u 2>/dev/null; git checkout -q HEAD~1 -- . 2>/dev/null; echo "skip"; git checkout -q feature/purr -- . 2>/dev/null

git stash pop && git status --porcelain

git worktree add -q /tmp/claude-1000/-home-bz-code-p4gui/864112d3-e742-4beb-988f-3e5f67ffed11/scratchpad/pre-pick HEAD~1 && cd /tmp/claude-1000/-home-bz-code-p4gui/864112d3-e742-4beb-988f-3e5f67ffed11/scratchpad/pre-pick && /home/bz/code/p4gui/bin/python3 -m unittest discover -s test 2>&1 | tail -3

git worktree remove --force /tmp/claude-1000/-home-bz-code-p4gui/864112d3-e742-4beb-988f-3e5f67ffed11/scratchpad/pre-pick

git log --oneline -3 -- p4gui.wxg; echo ---; grep -n "purr\|multi" p4gui.wxg | head

git status --porcelain && git diff --stat

git add model.py p4gui.py p4gui_wx.py test_tab.py test/test_multi_puck.py test/test_purr_panel.py test/test_t28_t29_automated.py && git commit -m "$(cat <<'EOF'
Test tab: Multi-Puck switch — group control of every puck found

A Multi-Puck OnOffButton (same size/shape/colour as the CAN FD toggle,
default Off) sits above the Interactive box. Off, the tab behaves exactly
as before. On, every Test-tab action targets all pucks the last scan
found, via _test_nodes():

- Turning the switch on configures each found puck off the GUI thread
  (EDS, PDO read-back, heartbeat off, OPERATIONAL — model.prepare_multi),
  and a rescan while on picks up new pucks. Either toggle direction
  commands Idle first so no puck is left running under the old regime,
  and the switch is locked while an automated test runs.
- Interactive: cyclic RPDO1/RPDO2 start per puck, and the enable walk,
  mode request, targets, homing and the profile-position handshake are
  phased — every node written before any node is waited on — so the
  group steps together. Position moves apply the same delta relative to
  each puck's own position, and _pp_new_setpoint_group aborts the whole
  group if any drive fails a read-back: no puck moves to a stale target.
- Automated tests fan each step across the group and wait on every node.
- Limits and Purr settings: for node in found — one SDO write each.
- Purr Enable (0x3027,1) goes out as ONE RPDO frame on the shared group
  COB-ID (p4-42-lfm-purr.csv RPDO3, 0x400, receive type 0), found by
  searching the node's RPDO maps, so every axis latches it on the same
  SYNC and the overlays start in phase. Single-puck keeps the SDO path.
- Purr settings are locked while purring is enabled (and re-synced from
  device read-back), so they can only change while the generator is off.

Command scaling still comes from the selected node — a multi-puck group
is assumed homogeneous — and the graphs still show the selected puck.

30 new tests in test_multi_puck.py, 5 purr-lock tests in
test_purr_panel.py. The t28 no-globals check now looks for actual
module-level node/network definitions instead of a regex that could not
tell a loop variable from a global.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)" && git log --oneline -2 && git status --porcelain

git add p4gui_wx.py test/test_multi_puck.py && git commit -m "$(cat <<'EOF'
Test tab: paint the Multi-Puck button on the frame's background

OnOffButton snapshots its parent's background at construction and paints
its bitmaps on it. The CAN FD button's parent is the frame, whose colour
attribute is the themed one, so it blends; the Multi-Puck button's parent
is the notebook-page controls panel, which reports black — and on wxGTK
GetBackgroundColour() returns the wx-side attribute, not the pixel GTK
renders, so it stays black even after realization (a deferred re-read
gets the same black; an earlier attempt at exactly that re-fix unfixed
itself one event-loop tick after startup).

So repaint the button once, with the frame's colour — the very colour
the CAN FD button blends with — and never consult the panel's. The
regression test asserts the repaint is present and that the panel's
colour is not used for this button.

Verified on screen: the button now blends with the system colour scheme
like the CAN FD one.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)" && git log --oneline -3 && git status --porcelain
```

### Session `1aff50ca` (started 2026-08-27)

```bash
cd ~/code/stm32 && git log --oneline -20 && git status -sb

cd ~/code/stm32 && git log --oneline -30 --all --grep -i -E "sync|clock|drift" 2>/dev/null | head -40

cd ~/code/stm32 && git log --oneline -15 feature/secure-purr && echo ---- && git show --stat 62cb9a2 | head -30 && echo ---- && git show --stat c61267e | head -30

cd ~/code/stm32 && git show 62cb9a2 --stat | sed -n '25,80p' && echo ==== && git log -1 --format=%B 62cb9a2 | tail -30

cd ~/code/stm32 && git log --oneline --all --grep -i -E "0x3026|debug.*(entr|OD)|dictionary" | head; grep -rn "3026\|clockcal\|clkcal" app/parse_app.c | head -30

cd ~/code/stm32 && git reflog --date=short | head -30 && echo ==== && git log --all --oneline -- app/clockcal.c | head && echo ==== && git stash list

cd ~/code/stm32 && git show 62cb9a2 -- app/co_dict.c | head -80

cd ~/code/stm32 && python3 - <<'EOF'
import io

# --- parse_app.h: declare the handler ---
p = 'app/parse_app.h'
s = open(p).read()
anchor = "int32_t parseExectime(co_data_t *data, uint32_t *value, bool isWrite);"
assert anchor in s, "anchor missing in parse_app.h"
s = s.replace(anchor, anchor + "\nint32_t parseClockcal(co_data_t *data, uint32_t *value, bool isWrite);")
open(p, 'w').write(s)

# --- parse_app.c: the handler, next to parseExectime ---
p = 'app/parse_app.c'
s = open(p).read()
# insert after the end of parseExectime; anchor on the comment that follows it
anchor = "/* 0x3019,5-6 - cutoff of the low-pass on the exported id and iq, in Hz."
assert anchor in s, "anchor missing in parse_app.c"
handler = '''/* 0x3029 - read-only window into the clock calibration (app/clockcal.c).
 *
 * TEMPORARY - bench-testing the SYNC clock lock only.  The module is
 * deliberately interface-free and this record must be removed before release
 * so it cannot land in the customer EDS (gen_eds.py builds puck4.eds from
 * co_dict.c).  Grep for parseClockcal to find every piece.
 *
 * No critical section: clockcal is only ever written by clockcal_sync(),
 * called from parseSyncCallback(), and this runs from parseCO() - both are
 * main-loop context, so a read here can never catch a write mid-flight. */
int32_t parseClockcal(co_data_t *data, uint32_t *value, bool isWrite){
  if (isWrite) return SDO_ABORT_READ_ONLY;

  switch (data->dict->subIdx) {
    case 1:  *value = clockcal.state;                   return 0;
    case 2:  *value = clockcal.sync_period_us;          return 0;
    case 3:  *value = (uint32_t)clockcal.error_ppm;     return 0;
    case 4:  *value = (uint32_t)clockcal.window_ppm;    return 0;
    case 5:  *value = (uint32_t)clockcal.phase_us;      return 0;
    case 6:  *value = (uint32_t)clockcal.phase_peak_us; return 0;
    case 7:  *value = clockcal.trim;                    return 0;
    case 8:  *value = clockcal.trim_lo;                 return 0;
    case 9:  *value = clockcal.trim_hi;                 return 0;
    case 10: *value = (uint32_t)clockcal.err_lo_ppm;    return 0;
    case 11: *value = (uint32_t)clockcal.err_hi_ppm;    return 0;
    case 12: *value = clockcal.trim_boot;               return 0;
    case 13: *value = clockcal.windows;                 return 0;
    case 14: *value = clockcal.discarded;               return 0;
    case 15: *value = clockcal.steps;                   return 0;
    case 16: *value = clockcal.relocks;                 return 0;
    case 17: *value = clockcal.cliffs;                  return 0;
    default: return SDO_ABORT_INVALID_SUBIDX;
  }
}

'''
s = s.replace(anchor, handler + anchor)
open(p, 'w').write(s)

# --- co_dict.c: the record, appended before the terminator ---
p = 'app/co_dict.c'
s = open(p).read()
anchor = "    {0x0000, 0, U08, parseDefault, 0},  // Array terminator - DO NOT MOVE OR CHANGE"
assert anchor in s, "anchor missing in co_dict.c"
record = '''
    /* 0x3029 - clock calibration (app/clockcal.c) debug window.
     * TEMPORARY - for bench-testing the SYNC clock lock; remove before
     * release so the clock-sync API stays out of the customer EDS
     * (gen_eds.py builds puck4.eds from this table).  Everything is
     * read-only and nothing is NV, so appending here cannot shift the
     * EEPROM offsets of fielded devices. */
    {0x3029, 0, U08, parseDefault, 17},   // Clock calibration (debug), # of entries
    {0x3029, 1, U08, parseClockcal, 0},   // State (0 unsupported, 1 idle, 2 learning, 3 acquiring, 4 locked, 5 holding)
    {0x3029, 2, U32, parseClockcal, 0},   // Measured SYNC period (us)
    {0x3029, 3, I32, parseClockcal, 0},   // Smoothed frequency error (ppm, + = this node fast)
    {0x3029, 4, I32, parseClockcal, 0},   // Last window's error (ppm)
    {0x3029, 5, I32, parseClockcal, 0},   // Phase vs producer (us, + = ahead)
    {0x3029, 6, I32, parseClockcal, 0},   // Peak |phase| since current lock (us)
    {0x3029, 7, U08, parseClockcal, 0},   // HSITRIM in force
    {0x3029, 8, U08, parseClockcal, 0},   // Bracket low trim (slow code)
    {0x3029, 9, U08, parseClockcal, 0},   // Bracket high trim (fast code)
    {0x3029, 10, I32, parseClockcal, 0},  // Measured error at trim_lo (ppm)
    {0x3029, 11, I32, parseClockcal, 0},  // Measured error at trim_hi (ppm)
    {0x3029, 12, U08, parseClockcal, 0},  // Boot (factory) trim
    {0x3029, 13, U32, parseClockcal, 0},  // Windows completed
    {0x3029, 14, U32, parseClockcal, 0},  // Windows discarded (SYNC missing/late)
    {0x3029, 15, U32, parseClockcal, 0},  // Trim register writes (dither switches included)
    {0x3029, 16, U16, parseClockcal, 0},  // Relocks (phase runaway, pair re-hunted)
    {0x3029, 17, U16, parseClockcal, 0},  // Cliff refusals (trim discontinuity hits)

'''
s = s.replace(anchor, record + anchor)
open(p, 'w').write(s)
print("edits applied")
EOF
git -C ~/code/stm32 diff --stat

cd ~/code/stm32 && python3 - <<'PYEOF'
p = 'app/clockcal.c'
s = open(p).read()

# --- new tunables after PHASE_RUNAWAY_US ---
a = """#define PHASE_RUNAWAY_US (5000)
"""
assert a in s
s = s.replace(a, a + """
/* --- Getting out of a hold again ---------------------------------------- */

/*! While holding, phase drifts at the held code's residual.  Once it has
 *  drifted this far, re-arm the hunt: whatever refused a bracket may have
 *  been a transient.  Larger than PHASE_RUNAWAY_US because a re-hunt from a
 *  hold is speculative - this leash sets how often one is paid for. */
#define HOLD_RUNAWAY_US (4 * PHASE_RUNAWAY_US)

/*! The hold remembers what its code measured when it began.  Smoothed error
 *  moving this far from that means conditions have changed, and the no-go
 *  code recorded on the way in is no longer evidence of anything. */
#define HOLD_STALE_PPM (1500)

/*! Re-hunts turned back for wanting the no-go code, before one is allowed to
 *  probe it after all.  See step_or_settle(). */
#define NO_GO_PROBES_HELD_OFF (8)
""", 1)

# --- cal_t fields ---
a = """  int8_t   acq_dir;
} cal_t;"""
assert a in s
s = s.replace(a, """  int8_t   acq_dir;

  // Holding
  int32_t  hold_err;       //!< Error the held code measured when the hold began
  uint8_t  no_go;          //!< Code refused for landing on the discontinuity
  bool     no_go_valid;
  uint8_t  no_go_refused;  //!< Re-hunts turned back for wanting the no-go code
} cal_t;""", 1)

# --- relearn clears the no-go ---
a = """  cal.ewma_valid = false;
  clockcal.sync_period_us = 0;"""
assert a in s
s = s.replace(a, """  cal.ewma_valid = false;
  cal.no_go_valid = false;
  cal.no_go_refused = 0;
  clockcal.sync_period_us = 0;""", 1)

# --- hold_at: new signature and duties ---
a = """/* Give up on finding a pair and sit on `code`.  Phase drifts from here - this
 * is the outcome the dither exists to avoid, taken when the oscillator will
 * not offer a bracket within reach. */
static void hold_at(uint8_t code) {
  set_trim(code);
  clockcal.trim_lo = clockcal.trim_hi = clockcal.trim;
  clockcal.state = CLOCKCAL_HOLDING;
  acquire_reset();
}"""
assert a in s
s = s.replace(a, """/* Give up on finding a pair and sit on `code`, whose measured error is `err`.
 * Phase drifts from here - the outcome the dither exists to avoid - but no
 * longer forever: the drift itself re-arms the hunt (hold_update), so a hold
 * outlasts only conditions that keep refusing a bracket.  Phase and the error
 * EWMA restart so that both describe the held code alone - the EWMA in
 * particular may be carrying a probe of the discontinuity, which would leave
 * hold_update's staleness test comparing against garbage. */
static void hold_at(uint8_t code, int32_t err) {
  set_trim(code);
  clockcal.trim_lo = clockcal.trim_hi = clockcal.trim;
  clockcal.state = CLOCKCAL_HOLDING;
  cal.hold_err = err;
  cal.ewma_valid = false;
  clockcal.phase_us = 0;   // The drift budget until the next re-hunt
  acquire_reset();
}

/* Step the hunt to the next code, unless that code is the remembered no-go:
 * then settle where we are, with the error just measured.  Every
 * NO_GO_PROBES_HELD_OFF refusals one probe is allowed through after all - a
 * no-go recorded off a single garbage measurement in otherwise steady
 * conditions looks exactly like a real discontinuity, and only a probe can
 * tell them apart.  A real one costs a couple of spoiled seconds per probe;
 * this holds that cost to once per several re-hunt periods. */
static void step_or_settle(uint8_t trim, int32_t err) {
  int32_t next = (int32_t)trim + cal.acq_dir;
  if (cal.no_go_valid && next == (int32_t)cal.no_go &&
      ++cal.no_go_refused < NO_GO_PROBES_HELD_OFF) {
    hold_at(trim, err);
    return;
  }
  if (cal.no_go_valid && next == (int32_t)cal.no_go) cal.no_go_refused = 0;
  if (!set_trim(next)) hold_at(trim, err);
}""", 1)

# --- lock() forgets the no-go ---
a = """  clockcal.state = CLOCKCAL_LOCKED;
  acquire_reset();
}"""
assert a in s
s = s.replace(a, """  clockcal.state = CLOCKCAL_LOCKED;
  cal.no_go_valid = false;
  cal.no_go_refused = 0;
  acquire_reset();
}""", 1)

# --- acquire_update call sites ---
a = """    cal.acq_dir = (err >= 0) ? -1 : 1;
    if (!set_trim((int32_t)trim + cal.acq_dir)) hold_at(trim);
    return;"""
assert a in s
s = s.replace(a, """    cal.acq_dir = (err >= 0) ? -1 : 1;
    step_or_settle(trim, err);
    return;""", 1)

a = """    clockcal.cliffs++;
    hold_at(prev_trim);
    return;"""
assert a in s
s = s.replace(a, """    clockcal.cliffs++;
    cal.no_go = trim;        // Remember it; re-hunts steer around it
    cal.no_go_valid = true;
    cal.no_go_refused = 0;
    hold_at(prev_trim, prev_err);
    return;""", 1)

a = """    // Same side, and no closer - noise, or as close as this oscillator gets
    // from this direction. Settle for the better of the two.
    hold_at(prev_trim);
    return;"""
assert a in s
s = s.replace(a, """    // Same side, and no closer - noise, or as close as this oscillator gets
    // from this direction. Settle for the better of the two.
    hold_at(prev_trim, prev_err);
    return;""", 1)

a = """  cal.acq_prev_trim = trim;
  cal.acq_prev_err = err;
  if (!set_trim((int32_t)trim + cal.acq_dir)) hold_at(trim);
}"""
assert a in s
s = s.replace(a, """  cal.acq_prev_trim = trim;
  cal.acq_prev_err = err;
  step_or_settle(trim, err);
}""", 1)

# --- hold_update, after lock_update ---
a = """  if (clockcal.phase_us > PHASE_DEADZONE_US) {
    set_trim(clockcal.trim_lo);        // Running ahead: slow down
  } else if (clockcal.phase_us < -PHASE_DEADZONE_US) {
    set_trim(clockcal.trim_hi);        // Running behind: speed up
  }
}"""
assert a in s
s = s.replace(a, a[:-1] + """}

/* Holding, but no longer parked.  Windows keep landing, so keep judging.
 *
 * If the smoothed error stops matching what the held code measured when the
 * hold began, the conditions that refused a bracket - a transient producer
 * stall, temperature - have moved on, and the no-go code recorded on the way
 * in stops being evidence.
 *
 * And the phase keeps integrating the held code's residual; once it has
 * drifted a re-hunt's worth, go and look for the pair again.  This is the fix
 * for the trap where one garbage measurement parked the module for good. */
static void hold_update(void) {
  if (cal.no_go_valid &&
      iabs32(clockcal.error_ppm - cal.hold_err) > HOLD_STALE_PPM) {
    cal.no_go_valid = false;
  }
  if (iabs32(clockcal.phase_us) > HOLD_RUNAWAY_US) {
    clockcal.relocks++;
    acquire_reset();
    clockcal.state = CLOCKCAL_ACQUIRING;
  }
}""", 1)

# --- the switch gains a HOLDING case ---
a = """    case CLOCKCAL_LOCKED:
      lock_update();
      break;
    default:
      break;   // Holding: measuring only, nothing to steer with"""
assert a in s
s = s.replace(a, """    case CLOCKCAL_LOCKED:
      lock_update();
      break;
    case CLOCKCAL_HOLDING:
      hold_update();
      break;
    default:
      break;""", 1)

open(p, 'w').write(s)

# ---------------- clockcal.h doc ----------------
p = 'app/clockcal.h'
s = open(p).read()
a = """ *     way - it falls back to the best single code and says so (CLOCKCAL_HOLDING).
 *     Phase then drifts as it would have anyway."""
assert a in s
s = s.replace(a, """ *     way - it falls back to the best single code and says so (CLOCKCAL_HOLDING).
 *     Phase then drifts as it would have anyway - though the drift is watched:
 *     once enough accumulates the pair is hunted again, so a hold outlasts
 *     only conditions that keep refusing a bracket.  A transient (a stalled
 *     producer faking the discontinuity, say) costs a few re-hunt periods,
 *     not the rest of the boot.""", 1)
open(p, 'w').write(s)

# ---------------- DEBUGGING.md ----------------
p = 'DEBUGGING.md'
s = open(p).read()
a = """- `state` 5 with `cliffs` non-zero means the multiple-of-64 discontinuity is
  sitting where the bracket needed to be, so there is no pair to dither on and
  phase will drift. Expected on some parts; nothing to do about it."""
assert a in s
s = s.replace(a, """- `state` 5 with `cliffs` non-zero means the multiple-of-64 discontinuity is
  sitting where the bracket needed to be, so there is no pair to dither on and
  phase drifts. The module re-hunts as that drift accumulates (`relocks`
  climbing slowly while holding is expected), steering around the refused code
  and re-probing it only rarely. Persistent state 5 with `cliffs` ticking up
  every few minutes means the discontinuity really is in the way; a hold born
  of one garbage measurement clears itself within a few re-hunt periods.""", 1)
open(p, 'w').write(s)

# ---------------- tests ----------------
p = 'test/phase1/ClockcalTest.cpp'
s = open(p).read()
a = """TEST(Clockcal, SearchStaysWithinItsSpan) {
  Osc o; o.base_ppm = 30000;   // 3 %: ten steps out, and the span is eight
  Bus bus(o);
  bus.runSeconds(90.0);

  CHECK_EQUAL(64 - TRIM_SPAN, clockcal.trim);
  CHECK_EQUAL(CLOCKCAL_HOLDING, clockcal.state);
}"""
assert a in s
s = s.replace(a, """TEST(Clockcal, SearchStaysWithinItsSpan) {
  Osc o; o.base_ppm = 30000;   // 3 %: ten steps out, and the span is eight
  Bus bus(o);
  bus.runSeconds(90.0);

  /* The drifting phase keeps re-arming the hunt (that is the fix for the
   * holding trap), but every hunt runs straight back into the span bound:
   * the trim must never leave the edge, and never lock. */
  CHECK_EQUAL(64 - TRIM_SPAN, clockcal.trim);
  CHECK(clockcal.state == CLOCKCAL_HOLDING ||
        clockcal.state == CLOCKCAL_ACQUIRING);
  CHECK(clockcal.relocks > 0);
  bus.runSeconds(2.0);
  CHECK_EQUAL(64 - TRIM_SPAN, clockcal.trim);
}

/* --- Getting out of a hold again ----------------------------------------- */

/* The trap this guards against was seen on real hardware: a stalled SYNC
 * producer made a re-hunt's measurements look like the discontinuity, the
 * cliff guard (correctly) refused them, and the module then sat in HOLDING
 * with the phase drifting for the rest of the boot.  A hold has to notice
 * that the conditions which refused a bracket are gone, and try again. */
TEST(Clockcal, RecoversFromHoldingAfterATransient) {
  Osc o;
  o.base_ppm = 1000;
  o.cliff_code = 63;          // Blocks the bracket: the module holds at 64
  Bus bus(o);
  bus.runSeconds(ACQUIRE_SECONDS);
  CHECK_EQUAL(CLOCKCAL_HOLDING, clockcal.state);

  // The "discontinuity" was transient, and conditions have moved on: the
  // held code no longer measures what the hold recorded on the way in.
  bus.osc.cliff_code = -1;
  bus.osc.base_ppm = 3500;
  bus.runSeconds(40.0);

  checkBracketed("after the transient cleared");
  CHECK(clockcal.relocks > 0);
}

TEST(Clockcal, AHoldProbesARealCliffOnlyRarely) {
  Osc o;
  o.base_ppm = 1000;
  o.cliff_code = 63;
  Bus bus(o);
  bus.runSeconds(ACQUIRE_SECONDS);
  CHECK_EQUAL(CLOCKCAL_HOLDING, clockcal.state);
  CHECK_EQUAL(1, (int)clockcal.cliffs);

  /* Re-hunts fire as the phase drifts, but they remember the no-go code and
   * turn back without touching it: the clock must not be walked onto a 6 %
   * error every few seconds just to keep checking it is still there. */
  bus.runSeconds(60.0);
  CHECK_EQUAL(1, (int)clockcal.cliffs);
  CHECK_EQUAL(64, clockcal.trim);
  CHECK(clockcal.relocks > 0);

  /* Eventually one probe is allowed through - a no-go recorded off a garbage
   * measurement in steady conditions could be disproved no other way - and
   * the real cliff turns it straight back. */
  bus.runSeconds(180.0);
  CHECK_EQUAL(2, (int)clockcal.cliffs);
  CHECK_EQUAL(64, clockcal.trim);
}""", 1)
open(p, 'w').write(s)
print("all edits applied")
PYEOF
git diff --stat

cd ~/code/stm32 && git status --porcelain | grep -v "^??" && git add app/clockcal.c app/clockcal.h app/main.c test/phase1/ClockcalTest.cpp DEBUGGING.md && git commit -q -m "$(cat <<'EOF'
clockcal: re-arm the hunt from a hold, and walk home when the producer dies

Two escape hatches for states that used to be terminal, both found the
hard way on the bench.

Holding is no longer a parking brake. A SYNC producer that stalled ~1 %
for a few seconds made a mid-stall re-hunt measure garbage, the cliff
guard (correctly) refused it, and the module then sat in CLOCKCAL_HOLDING
with phase drifting for the rest of the boot. Now a hold keeps judging:
the phase integral re-arms the hunt once it drifts HOLD_RUNAWAY_US (4x
the lock's leash, so re-hunts are rate-limited), the code refused for
looking like the discontinuity is remembered and steered around - a real
cliff must not be probed onto every few seconds - and that no-go is
forgotten when the held code's error stops matching what the hold
recorded, or disproved by one allowed probe every eighth re-hunt.
Hardware: 4/4 induced producer stalls parked the module in HOLDING and
every one recovered to a correct lock within ~8 s.

And a producer that disappears while the trim sits far from boot has, as
far as anyone can tell, dragged the clock somewhere the bus cannot reach
- clockcal trusts the SYNC period as ground truth, so a period ~2 % wrong
walks the slave's bit timing out of CAN tolerance, at which point the
node is deaf and nothing over the bus can ever tell it to come back
(demonstrated: wedged the controller ERROR-PASSIVE; recovery took ip link
surgery and a power cycle). clockcal_watch() runs every 100 ms off the
software timer, the one clock the missing bus cannot stop, and after 30 s
of silence with the trim more than 4 steps out it returns the trim to the
factory code and goes back to idle. Near-boot locks are left alone, so an
ordinary master outage costs nothing.

Both run in main-loop context like everything else here; the exectime
profiler shows pwm_execute and motion_control unchanged against the
2026-08-20 baseline with SYNC at 1 and 2 kHz.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)" && git add app/co_dict.c app/parse_app.c app/parse_app.h && git commit -q -m "$(cat <<'EOF'
clockcal: expose the state at 0x3029 for bench testing. TEMPORARY

Read-only OD record mirroring the clockcal global (18 subs: state,
learned period, ppm errors, phase, trim bracket, counters) so the bench
can watch a lock over CANopen instead of GDB. p4gui's
tools/bench/clockcal.py reads it while producing SYNC from the PC.

Remove before release: gen_eds.py builds puck4.eds from co_dict.c, and
the clock-sync machinery must not become a customer-facing API. Grep
parseClockcal to find every piece; reverting this commit is the same
thing.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)" && git log --oneline -4 && git status --porcelain | grep -v "^??" ; echo "tracked tree clean: $?"

cd ~/code/stm32 && git show --stat --oneline 5c97708 | tail -7 && git show --stat --oneline 2961003 | tail -5 && git checkout -q 5c97708 && ./build.sh stm32 app release 2>&1 | tail -2 && make -C test 2>&1 | tail -1 && ./test/build/test_runner 2>&1 | tail -2; git checkout -q feature/secure-purr && echo "back on branch: $(git rev-parse --abbrev-ref HEAD)"

cd ~/code/stm32 && git status --porcelain | grep -v "^??" && git add app/co_dict.c && git commit -q -m "$(cat <<'EOF'
Purr settings are volatile: sane defaults, configured online

Persisting them bought nothing. The defaults are sane, the host
configures the group online each session anyway (seed + RPDO restart is
the synchronised-purr workflow), and an actuator that starts purring at
boot because someone once saved it enabled is a surprise nobody wants.

Dropping the NV flag is safe for fielded devices: NV entries live in
EEPROM by ordinal position, and the purr entries were the last NV
ordinals in the table, so nothing else's saved offset moves. Their old
slots are simply never read again. Verified on hardware: serial,
product code and thermistor calibration survive the upgrade and a
reboot; a purr rate written online and Save.All'd reverts to its
default on the next boot.

The one setting this demotes is the rejection leak corner (0x3027,10):
a product wanting a non-default value now writes it after each boot,
along with the rest of the purr setup.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)" && git log --oneline -4 && git status --porcelain | grep -v "^??"; echo "clean: $?"
```

### Session `b68b0f9c` (started 2026-08-27)

```bash
grep -rn "purr_init" /home/bz/code/stm32 --include="*.c" --include="*.h" --include="*.cpp" | grep -v worktrees; echo ====; cd /home/bz/code/stm32 && git status --short --branch | head; git log --oneline -5

cd /home/bz/code/stm32 && git diff --stat | tail -25

grep -n "0x2384\|0x2406\|0x1018\|2384\|2406" /home/bz/code/stm32/p4-42-lfm-purr.csv | head; echo ====; git log --oneline -3 && git branch --show-current

git log --all --oneline 2>/dev/null | grep -i "8bf7b19\|c1b23ed" ; git show 8bf7b19 --stat 2>&1 | head -8

git branch --contains 8bf7b19 2>/dev/null; git merge-base --is-ancestor 8bf7b19 HEAD && echo "fix IS in HEAD" || echo "fix NOT in HEAD"

cd /home/bz/code/stm32 && git status --short | head -30; echo ====; git log --oneline -3; echo ====; git stash list | head -3

set -e
cd /home/bz/code/stm32
SP=/tmp/claude-1000/-home-bz-code-p4gui/b68b0f9c-9491-4bee-98e3-5760f60c97e7/scratchpad/commit-split
mkdir -p $SP
# Backup every modified tracked file (full current state = seed + timer + csv)
git diff --name-only > $SP/modified.txt
while read f; do mkdir -p $SP/full/$(dirname $f); cp $f $SP/full/$f; done < $SP/modified.txt
echo "backed up: $(wc -l < $SP/modified.txt) files"

# Reset the five seed-touched files to HEAD, re-apply ONLY the seed edits
git checkout -- app/motion.c app/motion.h app/co_dict.c app/parse_app.c notes/purr.md
python3 - <<'PYEOF'
import pathlib
def sub(path, old, new):
    p = pathlib.Path(path); t = p.read_text()
    assert t.count(old) == 1, f"{path}: {t.count(old)} matches"
    p.write_text(t.replace(old, new))

R = "/home/bz/code/stm32"
sub(f"{R}/app/motion.c",
"""COB-ID shared by the group).  Seed 0 keeps the old behaviour of deriving one
 * from the serial number, so unconfigured pucks stay out of step.""",
"""COB-ID shared by the group).  Seed 0 uses the generator's built-in default,
 * identical on every device, so even unconfigured pucks purr in lockstep.""")
sub(f"{R}/app/motion.c",
"""  uint32_t *serial = parseGetValuePtr(0x1018, 4);
  uint32_t seed = (purr.seed && *purr.seed) ? *purr.seed
                                            : (serial ? *serial : 0);

  purr_init(seed);""",
"""  purr_init(purr.seed ? *purr.seed : 0);""")
sub(f"{R}/app/co_dict.c",
"""     * Zero means "use the serial number", which is the historical behaviour
     * and keeps two pucks on one bus from purring in lockstep.  A non-zero
     * value is used as-is, so writing the same seed to several axes and
     * starting them on the same SYNC gives them bit-identical overlays - the
     * synchronised-purr case.  Only the seed is shared; the generator still
     * has to be restarted (write 0x3027,1) for it to take. */
    {0x3027, 13, U32 | RW, parsePurr, 0},   // RNG seed (0 = derive from serial)""",
"""     * Zero means "use the generator's built-in default", which is identical
     * on every device, so all axes purr in lockstep out of the box.  A
     * non-zero value is used as-is, so writing the same seed to several axes
     * and starting them on the same SYNC gives them bit-identical overlays -
     * the synchronised-purr case.  Only the seed is shared; the generator
     * still has to be restarted (write 0x3027,1) for it to take. */
    {0x3027, 13, U32 | RW, parsePurr, 0},   // RNG seed (0 = built-in default)""")
sub(f"{R}/app/motion.h",
"""  /* 0x3027,13 seed for the generator's RNG. 0 = derive one from the serial
   * number, which is what keeps unsynchronised pucks from purring in unison;
   * a shared non-zero value is what makes them purr in unison on purpose. */""",
"""  /* 0x3027,13 seed for the generator's RNG. 0 = the generator's built-in
   * default, identical on every device; any value shared by a group (default
   * or not) is what makes it purr in unison. */""")
sub(f"{R}/app/parse_app.c",
"    case 13: // RNG seed, 0 = derive one from the serial number",
"    case 13: // RNG seed, 0 = generator's built-in default")
sub(f"{R}/notes/purr.md",
"""1. **The seed has to be shared.** `motion_purr_restart()` used to seed from the
   serial number (0x1018,4), deliberately, so pucks on one bus would *not* purr
   in lockstep. 0x3027,13 overrides it: any non-zero value is used as-is, 0
   keeps the per-device behaviour.""",
"""1. **The seed has to be shared.** It is by default: seed 0 (the 0x3027,13
   default) uses the LCG's built-in state, identical on every device.  (Until
   2026-08-27 `motion_purr_restart()` derived the seed from the serial number
   (0x1018,4), deliberately, so pucks on one bus would *not* purr in lockstep;
   that is gone — lockstep is the goal.)  A non-zero 0x3027,13 is used as-is.""")
print("seed edits re-applied")
PYEOF
git add app/motion.c app/motion.h app/co_dict.c app/parse_app.c notes/purr.md
git commit -q -m "$(cat <<'MSG'
Purr: seed 0 means the built-in default, not the serial number

The goal is lockstep: every device should purr in phase out of the box.
Deriving the RNG seed from 0x1018,4 did the opposite by design, so drop
it. Seed 0 now leaves the LCG's built-in state alone, which is identical
on every device; a non-zero 0x3027,13 is still used as-is for explicit
group seeding.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
MSG
)"
echo "=== commit 1 done ==="

# Restore the full state (seed + timer + csv) and commit the timer redesign
while read f; do cp $SP/full/$f $f; done < $SP/modified.txt
git add app/clockcal.c app/co_dict.c app/main.c app/motion.c app/motion.h \
        app/parse_app.c app/profile.c common/parse.c common/timer.c common/timer.h \
        flashloader/main.c k64/hal.c k64/interrupts.c k64/peripherals.c k64/peripherals.h \
        notes/purr.md stm32/STM32G4xx_HAL_Driver/Src/stm32g4xx_hal.c stm32/interrupts.c \
        test/mocks/mock_timer.h test/mocks/timer.c test/phase1/ProfileTest.cpp \
        test/phase2/TimerTest.cpp
git commit -q -m "$(cat <<'MSG'
Timer: run events in the tick interrupt, at exactly their period

The tick drops from 10 kHz to 1 kHz (STM32 SysTick restored to the stock
1 ms HAL formula; K64 PIT 100 us -> 1 ms) and timer_int() now executes a
due event in place, re-arming it (count = 0) in the same tick, so periodic
work like motion_control() runs every millisecond of the local clock with
no main-loop dispatch latency and no drift. The tick interrupt sits at the
lowest NVIC priority (K64 PIT 7 -> 15; STM32 SysTick already 0x0F) so it
never delays another interrupt source.

timer_handle() and TIMER_READY are gone. One-shots keep their slot id and
remove it from inside the callback: parseSetCurrent, the deferred CAN-ID
reload (new trampoline in parse.c), and the flashloader's launch event.
Two things deliberately stay in the main loop, flagged from the interrupt:
the watchdog refresh (refreshed from the ISR it could never bite on a
wedged loop) and the flashloader's launch() (jumping from handler mode
would enter the app with an exception frame active). The heartbeat is now
a true periodic event, re-armed only when 0x1017 changes; the profile
stopwatch reads 1 ms ticks; K64 hal_can_write wraps its mailbox write in
a critical section since EMCY/heartbeat frames now originate in the ISR.

Known follow-up: SDO/PDO handlers in the main loop now race the 1 kHz
motion interrupt (mode switches, purr_set_filter/symmetry, the 0x3028
rebuild); existing critical sections cover the PWM ISR only.

Hardware-validated on a P4-42: heartbeat periods 99.862/9.987 ms at
100/10 ms settings (same -1.3 permille HSI offset at both rates, sd
60/45 us, zero scheduling drift); exectime (0x3028) matches the
2026-08-20 baselines in idle/vel/pos/trq/pos+purr. 212 unit tests pass.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
MSG
)"
echo "=== commit 2 done ==="

git add p4-42-lfm-purr.csv
git commit -q -m "$(cat <<'MSG'
p4-42-lfm-purr.csv: no commas inside an unquoted name field

canopen_runner's validator splits on every comma, so the RPDO3 row's
"(group, no node ID)" made 7 tokens and the loader rejected the whole
file. Semicolon instead.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
MSG
)"
echo "=== commit 3 done ==="
git status --short | grep -v "^??" | grep -v "^ ?" || echo "(no tracked changes left)"
git log --oneline -5

cd /home/bz/code/stm32 && git show --stat d394b99 | tail -8; echo ====; git show --stat 0a5547e | tail -4

cd /home/bz/code/stm32 && git status --short | grep -v "^??" | grep -v "^ ?"

cd /home/bz/code/stm32 && git add app/motion.c app/parse_app.c common/critical.h test/mocks/critical.h && git commit -q -m "$(cat <<'MSG'
Guard CAN frame handlers against the 1 kHz motion interrupt

Since timer events moved into the tick interrupt, the main-loop SDO/PDO
handlers race motion_control(): both sides read-modify-write status_word
(goState vs faultState) and mfgStatus (faultClear vs faultSet), a mode
change can interleave with a fault reaction, and the multi-word
purr_set_*()/purr_init() writes can be ticked half-applied by purr_tick().

Add EnterTimerCritical()/ExitTimerCritical() to critical.h: BASEPRI = 0xF0
masks only the priority-15 tick exception (SysTick on STM32, PIT0 on K64),
so a tick due inside a guard is deferred - pending, never lost, for any
window under 1 ms - and PWM, ADC and CAN are never delayed. A plain
EnterCritical() would stall the motor-control interrupts through the
trig-heavy purr setters, which is why the handlers do not use it.

Guarded: parseControl (fault flag + FSA + homing/motion controlword,
restructured to single-exit), parseMode (the OE check and motion_set_mode
land in one tickless window), and motion_purr_apply/motion_purr_restart
(self-guarded, covering all callers). motion_reject_apply already staged
its swap under the full critical section and is unchanged. Single-word
setpoint and gain writes stay unguarded (atomic on ARM), as do long
handlers like parseSave that touch no motion state.

Bench-validated on a P4-42: 22k handler writes in 20 s (purr params,
controlword, mode) under velocity mode with the purr running, plus purr
restart pulses and vel/trq/pos mode thrash - zero faults, generator
uninterrupted, exectime unchanged. 212 unit tests pass.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
MSG
)" && git status --short | grep -v "^??" | grep -v "^ ?" || echo "(no tracked changes left)"; git log --oneline -3
```
