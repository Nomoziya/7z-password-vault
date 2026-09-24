# 历史材料：review2 冻结版本 Defender 复核材料（未提交）

> 仅对应 review2-release-20260923 的 SHA-256，**不适用于当前 review3 包**。本轮 review3 未进行 Defender 复核。

本次没有自动上传，也没有有效的新检测名称或提交编号。扫描状态读取被拒绝，记录为 `scan-unavailable`；不能据此断言检出、误报或安全通过。若实际机器检测本版，请补充检测名称、Defender/病毒库版本、原始日志后，按 `signing-options.md` 的软件开发者复核流程提交对应文件。

发布范围：未签名、受控内测 portable ZIP；不进行付费签名，不要求关闭安全防护或设置排除项。

| 文件 | SHA-256 |
| --- | --- |
| 7zFM.exe | 2b36ce40ea366fc4178642c951b33c2fcac510d5c48dc70904c42652670826eb |
| 7zG.exe | 2bcd58505fc1f61b3a3449ae63d877ed7c1e51ed8ee214294d9eae5fb7285313 |
| 7z-password-vault-26.03-review2-20260923-win64-internal-test.zip | aac17499f98641cbf7ef1a74aebf7aca093d68c6b5c35c150362529dfa996991 |

样本来源：`dist/review2-release-20260923/` 的冻结 ZIP；精确解压文件与扫描日志在其 `defender/` 子目录。只提交本版程序文件，不提交密码库、`.bak`、用户压缩包或其他用户数据。

## 可填写的复核说明

Product: 7-Zip Password Vault edition, based on 7-Zip 26.03, internal test build 26.03-review2-20260923. This is an unofficial local archive/password-management application.

The password vault stores sensitive data locally using Windows DPAPI or a master-password mode using PBKDF2-HMAC-SHA256 and AES-256-GCM. This build adds a single previous-generation encrypted vault backup, corrects default vault selection and clears cached master passwords on failed settings/save operations. It does not use UPX, code obfuscation, process injection, remote threads or hidden startup registration. These executables are unsigned. We are requesting review of the exact hashes listed above if detected; historical verdicts concern different builds.

Detection name: [fill from actual detection]

Defender engine / signature version: [fill from actual machine]

Reproduction steps and original detection log: [attach]

Submission ID / response: [pending]

本材料只绑定 review2 冻结 ZIP，不代表之后修改的工作区源码或重新编译 EXE。本文哈希已与实际 ZIP、解压文件和同版本 Defender evidence 核对；未上传任何样本。
