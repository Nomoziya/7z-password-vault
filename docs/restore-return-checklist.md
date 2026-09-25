# 用户返回后：dev4 剩余验收

**已完成（2026-09-25）：** 下列操作已由用户执行并核对原始结果，cs 完整 GUI 436/0、跨账户 DPAPI 和管理员磁盘满均通过。无需再运行。保留命令供追溯，最终状态见 `restore-final-validation.md`。

2026-09-25。用户离开期间不执行本页操作。当前代码、原生测试、三语言 150% 恢复专项、436/0 完整 GUI、升级回滚与干净重建结果见 `restore-final-validation.md`。本页只列必须由对应账户完成的剩余证据，不要求重跑 dev3。

## 1. cs 独立标准账户

在 cs 桌面的普通 PowerShell 执行以下命令。约 5 分钟，测试运行期间不要操作鼠标键盘。

```powershell
pwsh -NoProfile -File 'D:\DSH Work\7z-passward\tests\restore-standard-user-run.ps1'
```

脚本会验证冻结 dev4 与 v1.5.0 包，解压到 cs 独有目录，运行核心压缩、完整 GUI/升级回滚，并验证 cs 可以使用自己的真实 DPAPI，但无法认证 Nomozi 生成的测试备份。它仅使用测试密文，拒绝恢复时验证两个文件不变。

结果自动复制到 `C:\Users\Public\Documents\7zpw-restore-evidence-<唯一ID>`。回复最后的 `passed/failed`、`Standard-user acceptance exit code` 和 `Shared evidence` 路径即可。若失败，保留原始结果，不手动更改数字或重跑覆盖日志。

跨账户夹具固定在 `tests/b/cross-account-seed-c383a72dc940408095fa53d2e46a5fad/`；完成前保留该目录及下方原生 EXE。独立脚本也可通过 `-SeedManifest` 指定已记录创建账户、两份测试密文哈希和原生 EXE 哈希的种子 JSON；不能由同一账户创建并验收拒绝。

## 2. 管理员真实磁盘满

在管理员 PowerShell 执行：

```powershell
pwsh -NoProfile -File 'D:\DSH Work\7z-passward\tests\real-disk-failure-test.ps1' -NativeTestExe 'D:\DSH Work\7z-passward\tests\b\native-run-5e274fe6b25f4a79aef959ee2e69f144\vault-native-test.exe'
```

脚本使用一次性 96 MiB 隔离 VHD。验收的是新增清理诊断后的最终原生 EXE，SHA-256 为 `44F89862AEC8299407B40C911F48C1AFCFDE2DBFEC4C157031D3DF396AB83144`。回复最后的 PASS/错误和 `Disk failure evidence` 路径。

## 收到结果后

核对原始 JSON 的程序、脚本、账户和 ZIP 哈希并归档。通过后依据实际记录评估发布门禁，再准备新版本；不覆盖 v1.5.0 或现有内测包。仍采用未签名 ZIP，Defender 保持实际未复核状态。
