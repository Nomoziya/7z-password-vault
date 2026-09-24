# review2 冻结版本源码验证记录（2026-09-23）

> 本文记录工作区源码验证，不代表旧 review2 ZIP 内的可执行文件。最新源码已另行打包为 review3，当前产物验收见 [review3-validation-20260923.md](review3-validation-20260923.md)。

本文两次干净构建记录验证后续工作区源码，并非 review2 ZIP 内的可执行文件。源码之后已打包为 review3；review3 产物验证见 [review3-validation-20260923.md](review3-validation-20260923.md)。

## 原生测试的两份干净构建记录

`tests/password-vault-security-test.ps1` 每次创建新的 `tests/b/native-run-<GUID>` 目录，在其中直接编译当前源码，先刷新 `tests/native-build.log`，再运行刚编出的 EXE。每次保存 `inputs.json`、`build.log`、`result.log` 和 `result.json`，记录脚本、源码清单、编译器、EXE 和运行日志哈希。成功编译退出码均为 0；没有运行旧 EXE。最终两次构建使用同一个脚本哈希、同一个源码清单哈希，生成相同的测试 EXE 哈希。

| 执行环境 | 完整构建目录 | 原生结果 |
| --- | --- | --- |
| 文件隔离环境 | `tests/b/native-run-c1d1a5d6353f449ab404c03a77f407a8` | `ENVIRONMENT_BLOCKED`，退出 78。独立 DPAPI 探针和生产 `CryptProtectData` 均返回错误 2；刷盘、备份和替换均未开始。不是 PASS。 |
| 本机普通用户环境 | `tests/b/native-run-0bdccd2ea29242f3b97668474ee0fc19` | 完整 PASS，退出 0。真实 DPAPI/AES、文件路径拒绝、保存失败回滚及缓存清除、加密备份、故障注入、崩溃和两进程各 100 次保存均通过。 |

原生测试在此前一次普通用户运行中发现并发保存偶发失败。子进程诊断记录显示，原子替换 `.bak` 或主库时受到短暂访问拒绝。生产代码现在只对 `ERROR_ACCESS_DENIED` / `ERROR_SHARING_VIOLATION` 做最多约一秒的有限重试，每次重试仍检查目标叶节点；持久故障仍失败，并由既有故障注入断言验证原库、备份、内存和缓存状态。修复后两次普通用户完整并发测试通过；其中上述最终 PASS 与隔离环境记录使用完全相同输入。

## 其他本轮核对

- `CPasswordPage::OnApply()` 在迁移或重加密成功后才一次提交密码设置和默认显示选项。保存失败时无设置提交；当前源码的 7zFM.exe 和 7zG.exe 均重新编译链接成功。实际 GUI 点击与注册表回归尚未运行。
- `core-test.ps1`：39/39。默认解压目录改为本次唯一 `core-runtime-<GUID>`，无论测试成功或异常都由 `finally` 安全清理；`-KeepArtifacts` 可保留。八个此前遗留、只含发布白名单文件的 `runtime-<GUID>` 临时目录已逐一核对路径并清理。
- `runtime-input-test.ps1`：10/10；`release-gate-test.ps1`：20/20。`git diff --check` 通过。
- `docs/defender-submission-20260923.md` 已与 review2 ZIP、7zFM.exe、7zG.exe 及该包 Defender evidence 的哈希逐一核对。review2 的两个 EXE 未签名，Defender 仍为 `scan-unavailable`；未上传样本，不能宣称 clean。
- `docs/acceptance-plan.md` 和 `docs/backup-validation-20260923.md` 顶部显著标注历史结果适用范围。旧 67/392 项、SFX、卸载器和旧原生结论不适用于 review2；review2 已有的压缩 39/39、运行时 10/10、发布门禁 20/20 才是该冻结包相关数字。

后续仍需新源码正式内测打包、设置页 GUI/注册表回归、Win10/Win11 标准用户验收、真实磁盘/ACL 故障和可用 Defender 环境复核。公开发布仍为 No-Go。
