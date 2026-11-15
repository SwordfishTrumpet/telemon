# Alert Tuning

Telemon can be configured to be loud or useful. This page explains the controls
that decide which notifications an operator actually receives, when to reach for
each one, and the invariants that must hold. It exists because a real deployment
reached ~25 messages a day of which roughly one was worth reading.

## Measure before you tune

Every dispatch is recorded in the audit log when `ENABLE_AUDIT_LOGGING=true`
(`AUDIT_LOG_FILE`, default `/var/log/telemon_audit.log`). A state change and its
dispatch are two records, so pair them to get alerts per key:

```bash
python3 - <<'EOF'
import json, re, collections
events, cur = [], None
for line in open('/var/log/telemon_audit.log'):
    try:
        r = json.loads(line)
    except Exception:
        continue
    if r['event_type'] == 'state_change':
        m = re.search(r'Key: (\S+), State: (\w+), Previous: (\w+)', r['details'])
        if m:
            cur = (m.group(1), m.group(3), m.group(2), r['timestamp'])
    elif r['event_type'] in ('alert', 'escalation') and cur:
        events.append(cur)
        cur = None
counts = collections.Counter(e[0] for e in events)
for key, n in counts.most_common(20):
    print(f"{n:5d}  {key}")
print("total:", len(events))
EOF
```

The production example behind this page: 2,398 alerts over seven months, with
`cpu`, `cpu_temp` and `iowait` accounting for 1,345 of them (56%). In the last 14
days it was 346 alerts against roughly 20 genuine findings. Three of the four
defects were in alert *policy*; one was a metric that measured the wrong thing.

## The controls

All four are opt-in or neutral by default except the CPU metric, so an existing
installation changes behaviour only when it asks to.

| Setting | Default | What it does |
|---|---|---|
| `CPU_CHECK_MODE` | `busy` | CPU metric: utilisation (percent of capacity) or legacy load average |
| `ALERT_HYSTERESIS_PCT` | `0` (off) | Deadband in percentage points before an active state clears |
| `FLAP_MAX_TRANSITIONS` | `8` | Alerts allowed inside `FLAP_WINDOW_SEC` before the key is held |
| `ALERT_WARNINGS_VIA_DIGEST` | `false` | Batch WARNINGs; `CRITICAL` always sends immediately |

### CPU metric

`CPU_CHECK_MODE=busy` compares `100 - idle - iowait` (from `/proc/stat`, over the
window since the previous run) against `CPU_THRESHOLD_WARN`/`CRIT`. The LXC path
always uses cgroup CPU accounting, so containers are unaffected by this setting.

`CPU_CHECK_MODE=load` is the legacy metric: the 1-minute load average as a
percentage of the core count. Prefer `busy`. Load average counts runnable *and*
uninterruptible (D-state) tasks, so I/O backlog inflates it; a host reported
`CRITICAL` at load 15.15 on 8 cores (189% of cores) while `/proc/stat` showed
64.7% busy, 10.6% iowait and 24.4% idle. An alert that fires while a quarter of
the CPU is idle cannot be acted on.

**Thresholds are percentages of CPU capacity either way.** A value inherited from
load semantics (`100`/`130` meaning "load equal to cores" and "1.3x cores") must
be reinterpreted under `busy`, where `100` means 100% busy. The first run after
switching uses the since-boot average, so the change does not produce a spike.

### Hysteresis

`ALERT_HYSTERESIS_PCT` adds a deadband to every check that uses the shared
threshold helper (`cpu`, `mem`, `swap`, `iowait`, `zombies`, `cpu_temp`, `ups`,
`battery`). While a check is `WARNING` or `CRITICAL` the value must move that many
percentage points *clear* of the threshold before the state improves.

```text
TEMP_THRESHOLD_WARN=90, ALERT_HYSTERESIS_PCT=3
91 °C  -> WARNING
88 °C  -> WARNING   (inside the 90-3 deadband)
86 °C  -> OK        (clear of the deadband)
```

Worsening is never deferred: a value at or above the real `CRIT` still escalates
immediately. Inverted metrics (available memory, battery) mirror the direction,
and the deadband is discarded if it would invert the severity order. Storage uses
its own `DISK_HYSTERESIS_PCT`; the general setting does not apply to it.

### Flap guard

A metric oscillating across its threshold is one tuning problem, not a series of
incidents. After `FLAP_MAX_TRANSITIONS` confirmed alerts for the same key inside
`FLAP_WINDOW_SEC`, telemon sends **one** message saying the key is flapping and
needing a threshold change, then stays quiet for `FLAP_SUPPRESS_SEC`.

`CRITICAL` transitions are never suppressed, so a flapping `WARNING` cannot mask
an escalation. `FLAP_MAX_TRANSITIONS=0` disables the guard.

### Warning digest

With `ALERT_WARNINGS_VIA_DIGEST=true` a `WARNING` transition is buffered instead
of sent, and the buffer is flushed as one digest at most once per
`WARN_DIGEST_INTERVAL_SEC`.

- a warning that resolves before the flush is **dropped silently** — it never
  interrupted anyone, which is the point
- `CRITICAL` is always immediate; resolving a `CRITICAL` is immediate
- a buffered warning that escalates to `CRITICAL` is removed from the buffer, so
  it is not reported twice
- buffering does **not** consume the per-key cooldown, so a `CRITICAL` five
  minutes behind a buffered `WARNING` is not rate-limited

Use this when the interrupt channel should mean "act now" and everything else can
wait for a summary.

## A worked profile

The thresholds below are for one specific host: a passive-cooled NUC whose normal
operating range is 61 °C idle and ~84 °C under sustained crawler load, running a
deliberately oversubscribed workload (~43 vCPU on 8 threads). Each choice is
recorded with its evidence, because the point of tuning is a defensible number,
not a quiet inbox.

```bash
CPU_CHECK_MODE=busy
CPU_THRESHOLD_WARN=90          # % of CPU capacity actually in use
CPU_THRESHOLD_CRIT=97

TEMP_THRESHOLD_WARN=90         # hardware crit is 100 °C; 80 warned on normal operation
TEMP_THRESHOLD_CRIT=97

ALERT_HYSTERESIS_PCT=3
FLAP_MAX_TRANSITIONS=8
FLAP_WINDOW_SEC=1800
FLAP_SUPPRESS_SEC=3600

ALERT_WARNINGS_VIA_DIGEST=true
WARN_DIGEST_INTERVAL_SEC=3600
```

Before: `cpu` CRITICAL and `cpu_temp` WARNING were the two most frequent
notifications, and both described normal operation. After: both report `OK` on
the same host, and the first three cycles sent nothing.

Do not raise a threshold to silence a metric that is measuring the wrong thing.
The 80 °C and load-based numbers above had already been raised once for that
reason and the alerts continued, because the metric was the problem.

## Invariants

- A `CRITICAL` transition is never suppressed by the flap guard, batched by the
  digest, or delayed behind one.
- Resolutions of `CRITICAL` are announced immediately.
- Buffering succeeds or fails; it never silently swallows a `WARNING` that the
  digest later fails to deliver (the entries stay buffered and retry).
- `reset-state` and `uninstall --full` remove every state sidecar, including the
  ones these controls use.

## Where state lives

Beside `STATE_FILE`:

| File | Purpose |
|---|---|
| `.cpu_busy` | previous `/proc/stat` sample, so the CPU percentage spans runs |
| `.flap` | confirmation timestamps per key, pruned to `FLAP_WINDOW_SEC` |
| `.flaphold` | per-key suppression expiry written by the flap guard |
| `.warndigest` | buffered warnings and the last flush epoch |

All are enumerated by `get_state_file_variants()` in `lib/common.sh`.
