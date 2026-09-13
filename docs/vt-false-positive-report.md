# VirusTotal / Microsoft false positive report / 误报提交记录

This file records the false-positive submissions for the release binaries, so the
next maintainer knows a case exists and what to compare against. It is **not** part
of the release package (`7-Zip-密码管家版/` only ships `README.md` and `BUILD.md`),
so editing it does not change any published hash.

本文件记录发布二进制的误报提交情况（提交编号、哈希、当前判定），方便以后复查。
它**不在发布包里**（包里只有 `README.md` 和 `BUILD.md`），所以改这里不会影响已发布的哈希。

---

## What was submitted / 提交了什么

| Field | Value |
|-------|-------|
| Platform | Microsoft Windows Defender Security Intelligence — *Submit a file for malware analysis*, path **Software developer** |
| Product | `7-Zip Password Vault (7-Zip 密码管家版)`, version `26.03 (v1.4.1)` |
| Scanned-by product | `Microsoft Defender Antivirus (Windows 10/11)` |
| Detection name given | `Trojan:Win32/Wacatac.B!ml` |
| Verdict given | incorrectly detected as malware (误报) |
| Submitted | 2026-09-13 (two separate submissions, the form takes one file each) |

| File | SHA-256 | Submission ID |
|------|---------|---------------|
| `7zFM.exe` | `cc60c3193f5c9ebabb9eaf31359723abffd4bd13bb360eacb3a1b99171337f92` | `e830c703-a3fe-4652-9d4c-e2dc69e9e7ea` |
| `7zG.exe` | `79763b2ca024b7f53ea820d588662a021f6680dcf18ed1a5a1dd67633a092bb1` | `ec8a02a1-09c6-4b2c-9a18-b37ebf63d450` |

The package (`7z-password-vault-26.03-win64.zip`,
`3376b4f7112e487bbe55750b30ae5a14c9f9c9ec6c53de1a0c52a16240ef3570`) was **not**
submitted: nothing flagged it (0/67), and a clean package would not have cleared the
two detections.

## State when the report was filed / 提交时的状态

```
7zFM.exe  1/71  Microsoft -> Trojan:Win32/Wacatac.B!ml   (69 undetected, 4 type-unsupported, 1 failure)
7zG.exe   1/71  Microsoft -> Trojan:Win32/Wacatac.B!ml   (69 undetected, 4 type-unsupported, 1 failure)
zip       0/67  nothing flagged
```

Sandbox behaviour of both binaries matches a plain archiver: no registry writes, no
services, no persistence, no child process other than itself, no network traffic
(a single DNS entry appears for `7zG.exe`, which cannot come from a binary that
imports no socket or resolver symbol at all — see `BUILD.md` section 3).

## How to check the result / 复查方法

```powershell
pwsh -NoProfile -File tests\vt-report.ps1     # current verdicts of the shipped files
```

Fill in the table below when Microsoft answers (usually 1-2 days):

| Date | `7zFM.exe` | `7zG.exe` | Note |
|------|------------|-----------|------|
| 2026-09-13 | `Trojan:Win32/Wacatac.B!ml` (1/71) | `Trojan:Win32/Wacatac.B!ml` (1/71) | before the report |
|  |  |  |  |

A cleared report changes the verdict to "no threat" for **every** user of the same
salted file signature — a rebuild produces different bytes and a new file hash, so a
**new build has to be submitted again**. That, and signing, is why `BUILD.md`
section 5 recommends a code-signing certificate: a signed, reputable binary is not
scored by the machine-learning model in the first place.
