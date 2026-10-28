---
name: android-crash-diagnose
description: "收集并分析 Android App 崩溃日志、dropbox、tombstone/ANR。触发：崩溃分析 / 抓崩溃日志 / crash log / tombstone / ANR / dropbox / logcat。"
allowed-tools:
  - Bash(bash android_tools/android_crash_collect_analyze.sh *)
  - Bash(bash android_tools/app_crash_logcat.sh *)
---

# Android Crash Diagnose

默认包名：`com.example.app`。用户给了包名则使用用户包名。

下面的命令都在**本仓库根目录**执行，脚本固定在 `android_tools/` 下。

## 用法

已崩溃，收集一次性诊断包：

```bash
bash android_tools/android_crash_collect_analyze.sh -p <package>
```

用户明确要求“分析/给 Claude 看”时才发送给 Claude：

```bash
bash android_tools/android_crash_collect_analyze.sh -p <package> --analyze
```

需要实时复现时：

```bash
bash android_tools/app_crash_logcat.sh -p <package>
```

有 tag 时加：

```bash
-t <tag>
```

## 规则

- 默认只落盘到 `/tmp`，不要自动加 `--analyze`。
- `--bugreport` 只有用户明确要求完整 bugreport 时才加。
- 结果重点看：`SUMMARY.md`、`logcat_crash_filtered.log`、`dropbox/`、`tombstones/`、`anr/`、`claude_analysis.md`。
- 回复用户时说明：崩溃类型、关键证据、bundle 路径、下一步建议。
