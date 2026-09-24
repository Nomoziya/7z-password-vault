# review4 标准用户依赖修复与内测验收（2026-09-23）

> 本页记录当日冻结构建及 373 项 GUI 脚本的历史验证。当前脚本增加升级回滚检查后，同一冻结 EXE 在独立 `cs` 标准账户通过 **393/393**；见[升级回滚验收](review4-upgrade-rollback-20260923.md)及[当前证据索引](review4-validation-evidence-20260924.json)。下文的 24 项门禁数字和“当前脚本”均按当日版本理解。

当前冻结内测包：`dist/review4-release-20260923/7z-password-vault-26.03-review4-20260923-win64-internal-test.zip`。ZIP SHA-256 为 `37166d2b30f4d08d96239fac0e7bef5b77d88d6efca2e5d8196ae40bd1f62c7d`。该包仍为**受控内测，公开发布 No-Go**。

独立标准用户 `cs` 的 review3 压缩测试为 39/39，但完整 GUI 测试首项失败；Windows 随后明确提示缺少 `libgcc_s_seh-1.dll` 和 `libstdc++-6.dll`。review3 两个 GUI EXE 的 PE 导入表确有 MinGW 运行库依赖，管理员账户的编译器 PATH 掩盖了打包缺陷。review4 将这两个 GUI 目标静态链接，并让 `tests/deploy.ps1` 拒绝仍导入未随包提供的 `libgcc_s_seh-1.dll`、`libstdc++-6.dll`、`libwinpthread-1.dll`。这没有更改密码库的加密或保存语义。

| 文件 | review4 SHA-256 | 签名 | MinGW 运行库 DLL 导入 |
| --- | --- | --- | --- |
| `7zFM.exe` | `d678e6b42ea574db4db26f66992e613535f76bb402a453aa02d66b0f4166ba92` | NotSigned | 无 |
| `7zG.exe` | `2b352bb0f7a94cf77ad3b53735f9803e36b3e5fc5f3fa94ef0fe8b5fa7f56aad` | NotSigned | 无 |

从新编译目录生成两程序后，以 review3 的受检运行时为种子组装 `dist/review4-candidate-20260923`，再生成 review4 ZIP。`artifact-audit.json` 位于同一发布目录；ZIP sidecar、`.build.json`、`.source.sha256`、`.sbom.json`、包内 `SHA256SUMS.txt` 与逐文件哈希已一致。`.build.json` 如实记录未提交源码状态，这些同目录完整性材料不能代替可信签名或来源真实性证明。

本机当前真实通过：压缩 39/39、运行时输入 10/10、发布门禁 24/24、`install-acceptance.ps1` 包完整性检查。删去编译器目录的 PATH 后，review4 `7zFM.exe` 仍能打开选项页并显示密码管理页 15 个控件，证据为 [设置页检查结果](../tests/b/ui-accessibility-94222c2d632f430db1a9fbe37f20b2d8/result.json)。这只是 GUI 启动和导航检查，不是完整交互验收。

管理员桌面在 review3 时完成的 GUI 373/373、真实 Windows ACL 拒绝与真实满 VHD 保存失败均为历史版本的实测证据。Codex 隔离账户的 HKCU/DPAPI 限制不能替代真实桌面验收。Windows 10、稳定版 Windows 11 已由用户排除本轮范围。真实断电/升级回滚与备份恢复按钮尚未完成。Defender 本轮按用户要求未复核、未上传，不能沿用 review2 的 `scan-unavailable` 或任何旧扫描结论。未签名程序仍可能误报。

`cs` 账户最初两次完整 GUI 运行均为 **360 通过、1 失败**。唯一失败是第 20 组导出时未生成 `exported-vault.dat`；程序实际显示“导出失败，无法写入目标文件”。加密源文件仍在，标准账户在同一目录普通复制成功。仅调整自动化文件名输入框定位仍复现同一失败；手动导出则成功。这些现象与脚本使用 `WM_SETTEXT` 修改文件名、文件对话框未稳定收到输入变更事件相符。改为向该输入框逐字发送 `WM_CHAR` 后，保留原有实际导出文件、密文哈希及导入断言，在**同一冻结 review4 EXE** 上完整复跑为 **373 通过、0 失败、退出码 0**。

用户提供的 [标准用户结果 JSON](../tests/b/standard-user-review4-20260923/result.json) 已原样复制到工作区，两份 SHA-256 均为 `c9438d884226edd0655115a3ce6bc1decb647b3762a8e987c8a69af2b9350029`；结果中脚本 SHA-256 `7f1c1d4d87f4f71536504ba0efd1fafbbfce4ddae0b6c8443de29d0e37c0f8ba` 与当前脚本一致，7zFM/7zG 哈希与上表一致。原始结果位于 `C:\Users\cs\AppData\Local\7zpw-review4-d66b6e5f436244cbab763d62d2767208\tests\b\ui-run-516686793e3146e291cd287b9a1db206\result.json`。先前两次 360/1 仍保留为历史失败记录，不计入最终 PASS。诊断构建没有替换 review4 冻结 ZIP。
