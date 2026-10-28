# Android Crash Diagnose

A Claude Code / agent skill that collects and analyzes Android app crashes: logcat, dropbox
records, tombstones, and ANR traces. Two bash scripts do the work. One collects a complete
diagnostic bundle; the other captures a live logcat stream while you reproduce a crash.

Apache-2.0 licensed. The skill definition sits at the repository root and the scripts it calls
live in `android_tools/`.

## What's inside

| Path | Purpose |
|---|---|
| `SKILL.md` | Skill definition (trigger rules, usage, output expectations) |
| `android_tools/android_crash_collect_analyze.sh` | One-shot crash bundle: logcat, dropbox, tombstones, ANR; optional Claude CLI analysis |
| `android_tools/app_crash_logcat.sh` | Live capture: full raw logcat plus a filtered crash/signal view |

## Install

### As a skill (recommended)

```bash
npx skills add xiebaiyuan/android-crash-diagnose
```

Or clone it manually and run the scripts from the repository root:

```bash
git clone https://github.com/xiebaiyuan/android-crash-diagnose.git
cd android-crash-diagnose
```

## Requirements

| Dependency | Needed for | Notes |
|---|---|---|
| `adb` | both scripts | Must be in `PATH`; a device or emulator must be connected |
| `bash` | both scripts | Any POSIX-ish bash; tested with the system bash on macOS |
| `claude` CLI | `--analyze` only | Optional. Point elsewhere with `--claude-cmd <cmd>` |
| `python3` | not required | These two scripts are pure bash; no Python is invoked |

This skill collects log data. It never uploads anything by itself — data stays under the output
directory until you move it.

## Usage

Run everything from the repository root.

Collect a one-shot diagnostic bundle (writes to `/tmp`, does not call any LLM):

```bash
bash android_tools/android_crash_collect_analyze.sh -p <package>
```

Add `--analyze` only when analysis is explicitly wanted — this pipes the collected excerpts into
the Claude CLI and writes `claude_analysis.md`:

```bash
bash android_tools/android_crash_collect_analyze.sh -p <package> --analyze
```

Reproduce a crash live while capturing logs:

```bash
bash android_tools/app_crash_logcat.sh -p <package>
```

Narrow the capture to a specific tag:

```bash
bash android_tools/app_crash_logcat.sh -p <package> -t <tag>
```

Pick a device when several are connected, or change the output directory:

```bash
bash android_tools/android_crash_collect_analyze.sh -p <package> -s emulator-5554 -o /tmp
bash android_tools/app_crash_logcat.sh -p <package> -s emulator-5554 --no-clear
```

Both scripts accept `-h` / `--help` for the full option list.

## Output

`android_crash_collect_analyze.sh` produces `/tmp/<package>_crash_bundle_<timestamp>/` and a
matching `.tar.gz`. Read these first:

- `SUMMARY.md` — package, device, counts, key-file index
- `logcat_crash_filtered.log` — crash and signal lines only
- `dropbox/` — Android dropbox records (app/system crash, native crash, ANR, tombstone)
- `tombstones/`, `anr/` — pulled from the device when permissions allow
- `claude_analysis.md` — only present with `--analyze`

`app_crash_logcat.sh` writes `<package>_logcat_<timestamp>.raw.log` and
`<package>_logcat_<timestamp>.filtered.log` into the output directory (default `/tmp`).

## Privacy

Crash logs can contain account identifiers, URLs, tokens, device data, and business data.
Collecting into `/tmp` is local-only. The `--analyze` flag is opt-in and is the only path that
hands excerpts to an external CLI.

## 中文说明

Android 崩溃诊断 skill，独立成库。用法：在本仓库根目录执行
`bash android_tools/android_crash_collect_analyze.sh -p <包名>` 收集一次性诊断包，
或 `bash android_tools/app_crash_logcat.sh -p <包名>` 实时抓取。默认只落盘到 `/tmp`，
不加 `--analyze` 不会调用 Claude。依赖只有 `adb` 和 `bash`；`--analyze` 需要额外的 `claude`
CLI，这两个脚本本身不用 Python。

## License

Apache License 2.0. See [LICENSE](LICENSE).
