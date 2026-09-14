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

---

## v1.4.3 scan (2026-09-14) / v1.4.3 实测

Scanned with `tests\vt-upload.ps1` (the two published artifacts first, then the two
executables). The verdicts after a rebuild are **not** the same as the v1.4.0/v1.4.1
numbers above: a new build has new hashes and is scored again from scratch.

| File | SHA-256 (short) | Detections | Engines |
|------|-----------------|-----------|---------|
| `7z-password-vault-26.03-win64-portable.zip` | `3973c83f…` | 1/67 | Elastic (moderate) |
| `7z-password-vault-26.03-win64-setup.exe` | `97d92a61…` | 3/70 | Microsoft `Trojan:Win32/Wacatac.C!ml`, Elastic (high), CrowdStrike `win/grayware_confidence_60%` |
| `7zFM.exe` | `b0b7bc69…` | 2/70 | Microsoft `Trojan:Win32/Wacatac.B!ml`, Elastic (moderate) |
| `7zG.exe` | `9b68b5ed…` | 1/70 | Microsoft `Trojan:Win32/Wacatac.C!ml` |

Control / 对照实验: the **unmodified official `7z.sfx` stub** that the installer is built
from (`9598f3bbca8e95391b8a356aee2e4cab93d9ac26eea47159ec725a55cf3bb32f`) is **0/71**.
So the installer's extra detections do not come from the SFX stub - they come from the
payload behind it: two executables that Microsoft already scores, plus `install.cmd` /
`install.ps1` / `uninstall.ps1`, i.e. scripts that write registry keys and delete files.
A self-extracting archive that unpacks and then runs a script is the shape of a dropper.

对照实验：安装器所用的**官方原版 `7z.sfx` 存根**是 0/71。也就是说安装器多出来的检测
不来自 SFX 存根，而来自它背后的载荷：两个已被微软打分的可执行文件，以及会改注册表、
删除文件的 `install.cmd` / `install.ps1` / `uninstall.ps1`——「解包后立刻执行脚本」正是
释放器的典型形态。

Submission IDs for this round / 本轮提交编号:

| File | Analysis ID |
|------|-------------|
| `7z-password-vault-26.03-win64-portable.zip` | `MmZmZWZjZTQzZjQyYmFmNmM5NTlkYTA4YjJlODkwYzk6MTc4OTM4NjIzMg==` |
| `7z-password-vault-26.03-win64-setup.exe` | `ZDU3MWZjZjlhZTI4ZTMzOGE2N2ExNjFkMzVmZDQ3Mjk6MTc4OTM4NjMyOA==` |
| `7zFM.exe` | `NTVjMDdkMWI2NWNiNDE0OTYxZWY1ZjIyMWYwMWE5MzU6MTc4OTM4NjQyMg==` |
| `7zG.exe` | `M2ZhZWIxYzY1NWQ4OWM1ODQ3YmFlZjI4NTBiMmJlNDI6MTc4OTM4NjU3OQ==` |

Recommended handling / 建议处置: offer the **portable zip** as the primary download
(1/67, Elastic only) and keep the self-extracting installer as the convenient option;
re-submit the two executables (and the installer) to Microsoft as false positives,
because every rebuild needs its own submission; sign the binaries if a certificate is
available. 建议以**便携版 zip** 为默认下载，安装器作为便捷选项保留，并把两个可执行文件
与安装器重新提交微软误报，每次重新构建都要重新提交；有证书时给二进制签名。

---

## After the reduction work (2026-09-14, same day) / 降检测改造后的复测

Following the attribution experiments in `docs/vt-attribution.md` - the self-extracting
wrapper and the "unsigned binary claiming the official identity" shape were the two
measurable causes - the build was changed: honest `VERSIONINFO`
(`CompanyName=Nomoziya`, `ProductName=7-Zip Password Vault`), an explicit
`asInvoker` manifest, `-Wl,--no-insert-timestamp` (reproducible: two re-links are byte
identical), the dead `RunProgram`/`InstallPath` config keys removed, and the shortcuts /
"Apps & features" entry moved into the program's first start (no script runs out of the
package any more). Same files, same toolchain, measured again:

| File | before | after | what changed |
|------|--------|-------|--------------|
| `7z-password-vault-26.03-win64-portable.zip` | 1/67 (Elastic) | **0/68** | Elastic cleared |
| `7z-password-vault-26.03-win64-setup.exe` | 3/70 (Microsoft `Wacatac.C!ml`, Elastic, CrowdStrike) | **2/70** (CrowdStrike `grayware_60%`, Elastic) | Microsoft cleared |
| `7zFM.exe` | 2/70 (Microsoft `Wacatac.B!ml`, Elastic) | **1/69** (Microsoft `Wacatac.B!ml`) | Elastic cleared |
| `7zG.exe` | 1/70 (Microsoft `Wacatac.C!ml`) | **1/70** (Microsoft `Wacatac.B!ml`) | variant changed, count equal |

Total: **7 detections → 4**. The portable package is now clean on VirusTotal.

What is left and why:

* **Microsoft `Wacatac.B!ml` on the two rebuilt executables** - a machine-learning verdict
  on the PE shape of an unsigned binary. It did not change with the honest version
  resource, which matches what the attribution data said: the `A3` probe (official stub +
  payload with non-rebuilt binaries) was already 2/70, i.e. Microsoft reacts to the
  wrapper shape. The remaining fixes are a false-positive submission per build
  (<https://www.microsoft.com/en-us/wdsi/filesubmission>, path *Software developer*) and,
  for the long term, a code-signing certificate (SignPath for open source, Azure Trusted
  Signing) - signatures are the only durable fix.
* **Elastic (high) + CrowdStrike `grayware` on `setup.exe`** - the self-extracting wrapper
  itself: `A3` showed 2/70 even with a benign payload, and the unmodified official
  `7z.sfx` stub is 0/71 only because it is a bare stub without a payload. Dropping the
  SFX entirely (portable zip only) would remove those two; the programme's first start now
  does everything the wrapper was supposed to do.

Submission IDs of this round / 本轮提交编号: `7zFM.exe`
`MjljZWZiYTc3NzdkMDY3MGQxODk2YWU4NGE1MzViZTI6MTc4OTM5MDE4MA==`, `7zG.exe`
`ZTNhZjQwZTE1MDZkMmFjZGJkOWQ0NDA4NzY4OTQ5NjU6MTc4OTM5MDQ1MA==`, `setup.exe`
`NWFkYjIyNzA3ZGQ3N2ZmMzg4MjhiZmI4ZTAxNTg1OGY6MTc4OTM5MDA5Ng==`, `portable.zip`
`OTA0MTAzNzliZTZjNDdmMjU5MTE3MmU1NmU5MjBiNTc6MTc4OTM5MDAxNA==`.

---

## Published set of v1.4.4 (2026-09-14) / v1.4.4 的发布集合

The portable zip is the only published download (`installer\build.ps1` builds the SFX only with
`-WithSetup`), so the wrapper's Elastic/CrowdStrike detections are no longer part of a release:

| File | Result |
|------|--------|
| `7z-password-vault-26.03-win64-portable.zip` | **0/67** - nothing flagged |
| `7zG.exe` | **0/65** - nothing flagged |
| `7zFM.exe` | 1/69 - `Microsoft`: `Trojan:Win32/Wacatac.B!ml` |

**One detection left in the whole release** (it was seven before the reduction work). It is a
machine-learning verdict on an unsigned binary, so the durable fixes are a code-signing
certificate and, until then, one false-positive submission per rebuild.

### The verdicts fluctuate between scans / 同一文件不同时间扫描结果会变

Measured on the same unchanged file: `7zG.exe` (`60587682…`) was reported as **0/65** earlier
the same day and as **1/69** (`Microsoft: Trojan:Win32/Wacatac.B!ml`) a few hours later, and
`7zFM.exe` switched between the `B!ml` and `C!ml` labels of the same family. The engine set and
the machine-learning scores both move, so a single scan is an observation, not a property of
the file. That is why `docs/acceptance-plan.md` sets the bar at "at most the control baseline
+ 1, and never more than 2 engines" instead of "zero detections", and why the same hash should
be looked up again before a release is judged.

### Ready to paste into the Microsoft submission form / 可直接粘贴的提交内容

The form (<https://www.microsoft.com/en-us/wdsi/filesubmission>) asks for the file, the
detection name and a description, and one file per submission:

| Field | Value |
|-------|-------|
| Submission type | Software developer |
| File | `7zFM.exe` from `7z-password-vault-26.03-win64-portable.zip` |
| SHA-256 | `a24e93c6fe72ea95dbb3797a246d41733b285a64ce23a8a807a8dcd9ac867ccb` |
| Detection name | `Trojan:Win32/Wacatac.B!ml` |
| Product | `7-Zip Password Vault 26.03` (a modified build of 7-Zip 26.03) |
| Verdict | Incorrectly detected / false positive |

Description (English):

> This is the file manager of an open-source fork of 7-Zip 26.03; the complete source, the
> build description and the reproducible build instructions are at
> https://github.com/Nomoziya/7z-password-vault. The build adds a local, AES-256-GCM
> encrypted password vault (DPAPI or master password). The binary imports no networking
> symbols at all (verified with objdump: no socket, no resolver, no wininet/winhttp) and
> writes only under HKEY_CURRENT_USER and next to itself; the VirusTotal report of this file
> shows a single machine-learning hit and no behaviour report. The verdict is a false
> positive of the `!ml` model on an unsigned, low-prevalence binary.

