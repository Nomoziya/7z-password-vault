# Build, verify and sign / 构建、验证与签名

This document exists so that the binaries in the release package can be **verified
instead of trusted**: it records exactly how they are produced, what is inside
them, and why an antivirus may complain about a file that is not malicious.

本文档的目的：让发布包里的二进制可以被**验证**，而不是只能被信任。它记录了这些
二进制的产出方式、内部构成，以及为什么杀毒软件可能对它们误报。

---

## 1. What the package contains / 包内是什么

`7zFM.exe` and `7zG.exe` are built from the **official 7-Zip 26.03 source** plus the
patch set in this repository. Everything else in the package (`7z.exe`, `7z.dll`,
`7-zip.dll`, `Codecs/`, `Formats/`, `Lang/*.txt`, `7-zip.chm`) is copied unchanged
from an official 7-Zip installation.

`7zFM.exe` 与 `7zG.exe` 由**官方 7-Zip 26.03 源码**加本仓库的补丁构建；包内其余文件
（`7z.exe`、`7z.dll`、`7-zip.dll`、`Codecs/`、`Formats/`、`Lang/*.txt`、`7-zip.chm`）
均直接取自官方 7-Zip 安装，未做修改。

The complete change against the official source:

```bat
git diff --stat <first-commit>..HEAD
::  26 files changed, ~2961 insertions(+), ~307 deletions(-)
```

New files are `PasswordVault.*`, `PasswordListDialog.*`, `PasswordPage.*`,
`PasswordVaultUi.*` and `tests/ui-test.ps1`; the rest are edits to existing files
(see the table at the end of `README.md`).

---

## 2. Reproduce the build / 复现构建

Toolchain used: **MinGW-w64 GCC 16.2.0, msvcrt flavour**
(`x86_64-16.2.0-release-posix-seh-msvcrt-rt_v14-rev1`).

The **msvcrt** flavour matters, and not only for antivirus heuristics:

* The UCRT flavour links `api-ms-win-crt-private-l1-1-0.dll`, an undocumented
  private API set. It is a known antivirus false-positive trigger, and it does not
  exist on Windows 7/8, so UCRT builds need Windows 10 or later.
* Official 7-Zip links plain `msvcrt.dll`. Building with the msvcrt flavour makes
  this build's imports match the official ones (14 DLLs instead of 23) and keeps
  the older Windows versions supported.

Get it from <https://github.com/niXman/mingw-builds-binaries/releases> and verify
the published SHA-256 before extracting. `make` is not part of that package, so a
separate `make` (e.g. from another MinGW install) has to stay on `PATH`; put the
msvcrt `bin` **first** so `gcc`/`g++` resolve to it. The extracted toolchain is
about 750 MB (plus the ~103 MB installer archive, which can be deleted afterwards).

```bat
:: the object directories must exist first: the makefile only creates them
:: inside an MSYS shell
mkdir CPP\7zip\UI\GUI\b\g 2>nul
mkdir CPP\7zip\UI\FileManager\b\g 2>nul

cd CPP\7zip\UI\GUI
make -f ../../cmpl_gcc.mak

cd ..\FileManager
make -f ../../cmpl_gcc.mak
```

Outputs: `CPP\7zip\UI\GUI\b\g\7zG.exe` and `CPP\7zip\UI\FileManager\b\g\7zFM.exe`.

Copying the result into the package (binaries, the four language files and the
documents) is one command:

```powershell
pwsh -NoProfile -File tests\deploy.ps1      # prints the SHA-256 of both binaries
```

A hash match only means "the same source and the same toolchain". A different GCC
version produces a different hash, so **reproduce the build and compare behaviour**
rather than expecting an identical file.

哈希一致只说明「同一份源码 + 同一套工具链」。换一个 GCC 版本就会得到不同的哈希，
所以更可靠的做法是**自己构建一遍**，而不是只比对哈希。

---

## 3. What the binaries do with your data / 二进制对你的数据做了什么

* They read and write one file: the vault
  (`%APPDATA%\7-Zip\7zPasswordVault.dat`, or the path set in the options).
* DPAPI mode encrypts every name and password with `CryptProtectData` (tied to your
  Windows account) — see `PasswordVault.cpp`.
* Master-password mode uses AES-256-GCM with a key from PBKDF2-HMAC-SHA256
  (200 000 iterations, fresh random salt and fresh 12-byte nonce on **every** save).
* There is **no network code**: the binaries do not import `ws2_32`, `wininet`,
  `winhttp` or `urlmon`, and import no socket / DNS / HTTP symbol at all
  (`WSAStartup`, `socket`, `getaddrinfo`, `InternetOpen*`, `WinHttp*`,
  `URLDownloadToFile*` — all zero).
* `7zFM.exe` imports `ShellExecuteW` / `ShellExecuteExW` from `SHELL32`, exactly like
  the official file manager: that is how **Open** (and the help window) starts the
  associated program. It is not used to run anything by itself, and `7zG.exe` does
  not import it. Worth knowing: a VirusTotal sandbox can report a DNS query for a
  binary that has no networking imports — it cannot have come from the process.

You can check that yourself:

```bat
objdump -p 7zG.exe | findstr "DLL Name"
```

Expected imports: `ADVAPI32 bcrypt COMCTL32 comdlg32 CRYPT32 GDI32 hhctrl.ocx
KERNEL32 msvcrt ole32 OLEAUT32 SHELL32 USER32` (and `MPR` in 7zFM).

Hardening is enabled: `DYNAMIC_BASE` (ASLR), `NX_COMPAT` (DEP) and
`HIGH_ENTROPY_VA`, i.e. `DllCharacteristics = 0x160`.

---

## 4. Antivirus false positives / 杀毒软件误报

**A modified, locally built `7zG.exe` will be flagged by some engines.** This is
expected and is not a sign of a real infection. The reasons are specific, and one
of them is a property of the toolchain rather than of this code:

1. **The file name.** `7zG.exe` is on watchlists because malware often ships it to
   unpack its payload. A modified `7zG.exe` no longer matches the officially signed
   file, so it loses that file's reputation.
2. **Unsigned and brand new.** No Authenticode signature and no prevalence data
   means a first-seen binary is scored harshly by cloud heuristics.
3. **The behaviour shape.** It writes an encrypted file under `%APPDATA%`, uses AES
   and PBKDF2, and starts child processes to compress and extract — a combination
   that also describes a dropper.
4. **The import set (fixed).** A UCRT-flavoured MinGW-w64 makes even
   `int main(){ printf("x"); }` import `api-ms-win-crt-private-l1-1-0.dll`, an
   undocumented private API set that some engines associate with packed malware.
   This build is compiled with the **msvcrt** flavour instead, so it imports
   `msvcrt.dll` exactly like the official binaries:

```bat
objdump -p 7zG.exe | findstr "DLL Name"
::   this build : msvcrt.dll + 12 Win32 DLLs, no api-ms-win-crt-* at all
::   official   : msvcrt.dll + the Win32 DLLs
```

   (Linking `-lucrtbase` on top of a UCRT toolchain was tried first and does not
   remove the private import, so the toolchain had to be replaced, not patched.)

   Reasons 1-3 above remain: the binaries are still unsigned, still called
   `7zG.exe`, and still behave like something that writes an encrypted file and
   spawns processes. Signing is the fix for those.

What to do:

* Add the build output and the unpacked package to the antivirus **exclusion list**.
* If you want the detection reviewed, submit the file to your vendor as a false
  positive (Kaspersky: <https://opentip.kaspersky.com/> → *Submit to reanalyze*;
  Microsoft: <https://www.microsoft.com/en-us/wdsi/filesubmission>).
  Include the SHA-256 and the link to this repository.
* Do **not** disable your antivirus globally, and do not run a build you did not
  compile yourself from a source tree you have reviewed.

### Measured result of v1.4.0 / v1.4.0 实测结果

Both binaries were submitted to VirusTotal (74 engines):

| File | Result |
|------|--------|
| File | v1.4.0 | v1.4.1 |
|------|--------|--------|
| `7zFM.exe` | 1/74 — `Microsoft`: `Trojan:Win32/Wacatac.B!ml` | 1/71 — same |
| `7zG.exe` | 1/74 — `Microsoft`: `Trojan:Win32/Wacatac.B!ml` | 1/71 — same |
| `7z-password-vault-26.03-win64.zip` | **0/73** | **0/67** |

(The engine count differs slightly between runs because VirusTotal adds and removes
engines; the verdicts are identical.)

`!ml` marks a machine-learning verdict, `Wacatac` is its generic name: this is the
best known false-positive family for unsigned, low-prevalence binaries (a single
engine, the only one using this model, and no named family from any other vendor).
The sandbox reports match a plain archiver: no registry writes, no services, no
persistence, no child process other than itself, and no network traffic — the single
DNS entry shown for `7zG.exe` cannot come from a binary that imports no socket or
resolver symbol at all (see section 3).

Submit it to Microsoft as a false positive and the detection normally disappears
within a day or two for everyone.

Two scripts read and refresh these reports. Both need a free VirusTotal API key in
`%USERPROFILE%\.vt-key` — a read-only file outside the checkout, so the key can never
be committed by accident (a stray `.vt-key.txt` in the checkout is gitignored as a
second safety net):

```powershell
pwsh -NoProfile -File tests\vt-report.ps1   # read the reports of the current files
pwsh -NoProfile -File tests\vt-upload.ps1   # submit them again and read the verdicts
```

---

## 5. Code signing / 代码签名

Signing is the only durable fix: a signed binary with a known publisher stops being
judged on heuristics alone. A **self-signed certificate does not help** — it is not
trusted by anything, so it changes nothing for SmartScreen or for antivirus
reputation.

### Free option for open source: SignPath Foundation

<https://signpath.org> signs open source projects **free of charge**. The project
does not receive a certificate of its own: the certificate is issued to *SignPath
Foundation* (they are the publisher), the private key lives in their HSM, and each
release is signed through SignPath.io after a manual approval by a project member.

Conditions that apply to this project (from <https://signpath.org/terms>):

| Condition | Status here |
|-----------|-------------|
| No malware, OSI-approved licence, no proprietary parts | OK — LGPL, all sources public |
| Maintained, released, documented | OK — repository, releases, README |
| No data collection / announce system changes | OK — no network code at all |
| Sign only your own builds, from your own repository | OK |
| **Modified upstream software**: upstream must publish signed builds, and the fork must be a *visible* fork (e.g. GitHub's fork feature) | **Needs work** — 7-Zip publishes signed builds, but this repository is not a GitHub fork of 7-Zip |
| **Reputation**: the project must have verifiable reputation for downloadable executables | **Needs work** — a young repository may be rejected |
| MFA on GitHub and SignPath; Authors / Reviewers / Approvers roles documented | Needs setup |
| A **"Code signing policy"** section on the project home page with the required wording, roles and privacy statement | Needs to be added to `README.md` |
| File metadata restrictions (product name / version set consistently) | Note: the binaries currently carry upstream 7-Zip's version resource |

The two "needs work" rows are the real obstacles and are about the project's public
presentation and reputation, not about the code. A practical sequence is: publish
the project properly (visible fork of 7-Zip, clear README, a few releases), add the
code-signing policy section, then apply.

### Paid alternatives

* **Azure Trusted Signing** — around $10/month, own certificate, supports
  individual and organisation validation, integrates with CI.
* **Certum** — advertises open-source friendly code signing; their store did not
  expose the open-source terms when checked, so verify the conditions directly
  before relying on it.
* Any commercial OV/EV code-signing certificate from a CA.

Before signing anything, note that the current version resource still says
`7-Zip`; a signing service that enforces metadata restrictions will want the
product name to identify this project.

### How to sign once you have a certificate

```bat
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 ^
  /f mycert.pfx /p <password> ^
  CPP\7zip\UI\GUI\b\g\7zG.exe

signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 ^
  /f mycert.pfx /p <password> ^
  CPP\7zip\UI\FileManager\b\g\7zFM.exe
```

Verify with `signtool verify /pa /v <file>`. Always timestamp (`/tr /td`): without
it the signature becomes invalid when the certificate expires. Sign **after** the
build and **before** `Compress-Archive`, otherwise the package ships unsigned
binaries.

---

## 6. Current hashes / 当前哈希

The package carries its own list: `SHA256SUMS.txt` (written by `tests\deploy.ps1`) holds
the SHA-256 of **every** file next to its name. Verify a download with that file instead
of copying hashes from a document - a hard coded hash goes stale as soon as anything is
rebuilt, and then a correct download looks tampered with (the last releases carried
hashes that no longer matched).

哈希清单随包发布：`SHA256SUMS.txt`（由 `tests\deploy.ps1` 生成）列出包内**每一个**文件的
SHA-256 与名字。请用它校验下载，不要在文档里抄哈希 —— 文档里的哈希只要重新编译一次就会过期，
那时正确的下载反而看起来像被人改过。

```powershell
Get-Content .\SHA256SUMS.txt | ForEach-Object {
  if ($_ -match '^([0-9a-f]{64})\s+(.+)$') {
    $want = $Matches[1]; $file = $Matches[2]
    $got = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $want) { Write-Host "MISMATCH $file" }
  }
}
Write-Host "checked"
```