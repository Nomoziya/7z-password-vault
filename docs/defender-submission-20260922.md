# Microsoft Defender 误报提交材料

本材料对应唯一冻结内测包：

- ZIP：`7z-password-vault-26.03-free-20260922-win64-internal-test.zip`
- ZIP SHA-256：`e61b264bcc2ac1d65b97233268adc95aea30b3d3eb7853e5cdbe8e26aa3871d2`
- 构建记录：[`.build.json`](../dist/free-release-20260922/7z-password-vault-26.03-free-20260922-win64-internal-test.zip.build.json)
- 包内清单：[`.sha256`](../dist/free-release-20260922/7z-password-vault-26.03-free-20260922-win64-internal-test.zip.sha256)
- SBOM：[`.sbom.json`](../dist/free-release-20260922/7z-password-vault-26.03-free-20260922-win64-internal-test.zip.sbom.json)

## 需要分别提交的文件

| 文件 | SHA-256 | 签名 | 当前扫描状态 |
|---|---|---|---|
| `7zFM.exe` | `69f2d02a6189204ef6a6501719afcfa608fbfe862263fe315aff8df5924e221a` | NotSigned | scan-unavailable |
| `7zG.exe` | `fef5d1be878ed4959370dcebada9119a6d2093af018d3be462c88bad9135a458` | NotSigned | scan-unavailable |

文件来自 ZIP 解包后的 `extracted-candidate` 目录。提交前必须重新核对哈希；不要提交源码目录中的其他构建产物，也不要提交旧版本文件。

## 门户填写值

- 入口：<https://www.microsoft.com/en-us/wdsi/filesubmission>
- Submission type：`Software developer`
- 如果出现检测分类：`Incorrectly detected as malware/malicious`；若实际分类为 PUA，则选择对应的 `Incorrectly detected as PUA`。
- Detection name：从本机 Windows Security 的实际告警中逐字填写；当前没有可验证的检测名称，不能臆填。
- Product name：`7-Zip Password Vault (unofficial 7-Zip 26.03 fork)`
- Version：`26.03-free-20260922`，受控内测版
- Publisher：填写实际个人/组织名称；不要填写 Igor Pavlov 或官方 7-Zip 发布者。
- Source repository：<https://github.com/Nomoziya/7z-password-vault>
- Network behavior：密码管家代码不提供网络、云同步、遥测或自动上传。
- Privilege behavior：面向 Windows 10/11 x64 标准用户；不要求管理员权限。
- Distribution：纯 portable ZIP；不包含 SFX、安装器、卸载脚本、测试脚本、密码库、私钥或转储文件。

## 给微软的说明正文

> We are the developer of an unofficial, open-source 7-Zip 26.03 fork for local password management. The submitted executable is distributed only inside a portable ZIP for controlled testing. It stores the local vault under the current user's application-data directory, uses Windows DPAPI or a user-entered master password, and has no network, telemetry, cloud sync, privilege elevation, obfuscation, packing, or Defender-exclusion behavior. The package is not signed because this is a no-cost internal-test release; its exact hashes, build metadata, source commit, input lock, package manifest, and SBOM are provided alongside the sample. Please review the exact submitted SHA-256 and confirm whether the detection is an incorrect malware/PUA classification.

## 本次扫描记录

扫描记录：[defender-evidence.json](../dist/free-release-20260922/defender-evidence-20260922/defender-evidence.json)。脚本使用 `MpCmdRun.exe -Scan -ScanType 3 -File <exact-extracted-file> -DisableRemediation`，不修改设置、不执行修复、不上传样本。

本机扫描结果必须标记为 `scan-unavailable`：Defender 服务未运行，读取状态返回“拒绝访问”，引擎/病毒库版本为空。命令退出码为 0 不能在这种环境下解释为 clean。提交门户的 Detection name、扫描时间和 Defender 版本应在 Defender 正常运行的 Windows 环境中补齐。

提交后把门户生成的 Submission ID、实际检测名称、Defender 引擎/安全情报版本和提交时间写回本材料及 `defender-evidence.json`。未取得同一 SHA-256 的微软结论前，不得把文件描述为“已获微软确认无害”。
