# review3 源码内测构建与验收（2026-09-23）

> **历史版本，不适用于当前 review4 包。** 独立标准用户 `cs` 运行 review3 时，`7zFM.exe` 因缺少 `libgcc_s_seh-1.dll`、`libstdc++-6.dll` 无法启动，完整 GUI 验收失败。此前管理员会话的 373/373 依赖其 MinGW 环境，不证明该包可在干净标准用户环境独立运行。当前修复与证据见 [review4 验证记录](review4-validation-20260923.md)。

本报告对应 `dist/review3-release-20260923/7z-password-vault-26.03-review3-20260923-win64-internal-test.zip`。它包含当前源码的设置事务提交时序修复与抗短暂文件占用的原子替换重试。review2 保持原样，review2 的 Defender 材料不适用于 review3。本轮按用户要求跳过 Defender 复核，也没有上传样本。

ZIP SHA-256：`64082e6753db9e20b95465da3191cc85b2b20f11174c304e94d3264bb3530ee2`。

| 文件 | SHA-256 | 签名 |
| --- | --- | --- |
| 7zFM.exe | `a5f9f4e404783b9b8703dd331a7acaaa06aa2bcf0f2aa5476b3f9c7e7a04b31f` | NotSigned |
| 7zG.exe | `8b052d07025f1ff2341975ba79324660a459e9968733984346c65214146f8404` | NotSigned |

## 构建与验证

- 7zFM、7zG 编译链接成功。
- 此前的原生安全测试记录仍可追溯：隔离运行退出 78，普通用户环境的完整 PASS 属于当时的测试输入哈希。本轮为加入真实 ACL 和独立磁盘故障入口修改了测试代码，因此旧 PASS 不代表当前扩展套件。
- 修复短暂替换占用后，普通用户环境的并发完整测试两次通过，两进程各完成 100 次保存；持久权限故障仍按失败处理。详见 [verification-clean-build-20260923.md](verification-clean-build-20260923.md)。
- 压缩回归 39/39；默认运行时来自 review3 包，`core-runtime-<GUID>` 已由 finally 清理。
- 运行时输入回归 10/10，测试专属目录已清理。
- 发布门禁在冻结包生成时为 20/20；系统验收范围调整后，当前脚本新增 4 项证据字段回归，最新复跑为 **24/24**。
- `install-acceptance.ps1 -Package <review3 ZIP>`：独立 ZIP 哈希、文件集合与包内 SHA256SUMS 全部通过。此脚本不安装、不卸载。
- review3 ZIP、sidecar、build.json、source.sha256 和 SBOM 记录相互一致；完整核对记录在同目录 `artifact-audit.json`。构建记录如实写明源码未提交（`sourceDirty=true`）。
- 生成 review3 后继续更新了验证文档、测试脚本和系统验收范围；当前工作区的 README/BUILD 也已收窄到 Windows 11 Insider。冻结 ZIP 内仍是生成时的 README/BUILD，不能把后来改动当作包内文件或重新计算旧包哈希。产品 C/C++ 源码和冻结 ZIP/EXE 未重建；`artifact-audit.json` 仅是生成当时的审计快照，不冒充当前源码差异计数。
- `git diff --check` 通过。

## 本轮补充：GUI、ACL 与磁盘故障

- GUI 脚本 [ui-accessibility-test.ps1](../tests/ui-accessibility-test.ps1) 实际启动 review3 candidate 的 `7zFM.exe`，打开「工具→选项」、切换到密码管理页、检查 15 个控件，并通过「取消」关闭；没有输入主密码、提交设置或修改密码库。最新复跑证据为 [ui-accessibility-38edf9ac](../tests/b/ui-accessibility-38edf9ac763f4031a48192dc0c38862d/result.json)，分类 PASS，系统版本字符串 `10.0.26220.0`，`7zFM.exe` SHA-256 `a5f9f4e404783b9b8703dd331a7acaaa06aa2bcf0f2aa5476b3f9c7e7a04b31f`，包内清单 SHA-256 `1dc9e63a170ac4b78169f24807d8d940f9ff8c24880b821381ce302dc693040a`。这只证明设置页可见性和导航。
- 最新原生验证来自管理员 PowerShell 下的新 GUID 构建目录 [native run e50a](../tests/b/native-run-e50a5972d52142d1af901bd13fd0f5cb/result.json)：build 退出 0，EXE SHA-256 `B9316FF66F9B42922177FAD4C7A19676F81E1B59C98186EB196A54AB40F45434`，源码输入摘要 `FEDBBBB96618A50B20EC11D775F3B1A51B8B5D85E44EA0997C4F78395557615B`。结果 JSON 为 `classification=PASS`：真实 ACL、注入式 `ERROR_DISK_FULL`、真实满卷和 DPAPI 完整套件均通过；包括两进程共 200 次保存。
- 真实满卷细节见 [real disk run a3d5](../tests/b/real-disk-a3d5a615df9a4caca4219b3d148f7c37/result.json)：96 MiB 固定 VHD 的加密种子为 524,394 字节；填充 `WriteFile` 在 512 字节块返回原生 Win32 112，剩余空间 0。随后生产保存返回失败，主库和备份保持不变、内存条目回滚、缓存清除；VHD 已卸载并删除。控制台显示的 `Win32=2` 是 `Save()` 返回后的 `GetLastError()`，不作为失败原因码；测试以保存返回值和状态不变量判定，原生完整脚本分类为 PASS。
- 此前小种子在零空间下仍保存成功；NTFS 可把小文件 `$DATA` 驻留在 MFT 记录内（[Microsoft Sysinternals 说明](https://learn.microsoft.com/en-us/sysinternals/resources/archive/v01n05)），所以夹具已扩大为强制分配数据簇。当前成功运行使用 256K 个测试字符，种子密文大小也在结果 JSON 中核验。
- Codex 受控进程身份为 `WW\CodexSandboxOffline`，管理员组检查为否。沙箱提权不更改 Windows 身份；同一会话用 `-Verb RunAs` 启动 Codex `pwsh.exe` 和 Windows PowerShell 均以 `0xc0000142` 失败，没有出现 UAC 确认窗口。Codex 受限会话的 DPAPI 探针仍在首次加密前以 Win32 2 受阻，分类为 `PARTIAL_ENVIRONMENT_BLOCKED`；它不是成功证据，也不覆盖用户管理员会话下同一源码输入摘要的 PASS。
- 完整交互脚本 [ui-test.ps1](../tests/ui-test.ps1) 本轮尝试时在第 87 行、启动应用和执行用例之前，因 `HKCU\Software\7-Zip` 拒绝访问而退出 1。留存的 [环境阻塞结果](../tests/b/ui-test-blocked-8f4093a512d04223b17fb2c1505db034/result.json) 与 [控制台日志](../tests/b/ui-test-blocked-8f4093a512d04223b17fb2c1505db034/console.log) 记录了脚本哈希、review3 运行时 EXE 哈希及失败阶段。该脚本必须先写入隔离语言与密码库设置，因此当前受控账户不能运行其 CRUD、填入、迁移或设置持久化回滚场景；该结果分类为环境阻塞，不是应用测试失败或通过。脚本未进入用例主体。
- 用户随后在自己的管理员 PowerShell 执行完整 GUI 脚本；[粘贴日志及分类](../tests/b/ui-admin-interrupted-bffb3eca0d3441ee9f1d7a2d95090c83/result.json) 显示前 15 组及第 16 组的一部分已运行，记录了 5 个失败断言，没有最终汇总。第 16 组使用不带密码参数的 `7z.exe t` 检查加密包，进程因此等待交互输入；此次运行分类为 **INCOMPLETE**，不能记作 GUI 通过。脚本已改用明确的错误密码，使该检查非交互；同时把旧 v3 断言更新为当前 v4，并让密码框检查考虑「显示密码」选项。此处仅记录当时未完成的运行，后续完整复跑结果见下方。
- 第二次管理员 GUI 回归完成了脚本，用户报告 **338 通过、11 失败**；[逐项记录](../tests/b/ui-admin-run-report-00eaf737a7314a1e92281d378b35f6a9/result.json) 明确标记为用户粘贴的控制台结果，不能记作 PASS。5 项要求迁移后删除旧密码库，与当前保留加密恢复副本的实现相反；2 项因为该用户的默认 APPDATA 密码库本来不存在而缺少双库夹具；4 项属于当前便携包不提供的首启快捷方式/卸载登记流程，且原脚本收尾会按固定名称删除已有登记。用户确认旧安装目录已删除，无需恢复旧登记。修订后的第三轮 [GUI 结果](../tests/b/ui-run-e9665d3a32054c8f94cd69b31baa970c/result.json) 为 372/373，一项失败来自测试在主窗口尚未出现时发送打开设置页指令。脚本改为先等待主窗口，独立 [设置页复核](../tests/b/ui-accessibility-acc4db3eb2ad4c5e89b49dd4a5eebdf5/result.json) 再次通过。
- 最终管理员 PowerShell 完整 GUI 复跑：[result.json](../tests/b/ui-run-efdd5c12047f4f3bb39e8f1ddbbd16d5/result.json) 记录 **373 通过、0 失败、退出码 0**，脚本 SHA-256 `305cce37fef1491043687ff3cb86bbbf76d638d5d2a1e685b3628fc7f467f35d`，运行时 7zFM/7zG 哈希与本报告顶部一致。该记录由用户交互式管理员会话的脚本直接写入，不是 Codex 受控账户独立运行。双库测试只在 APPDATA 默认库不存在时排他创建加密夹具，结束时仅按哈希删除未变化的自有夹具；测试现验证迁移后原加密文件保持不变，便携包不会注册快捷方式或卸载项。
- 最新 GUI 设置页独立可见性与导航证据见 `tests/b/ui-accessibility-acc4db3eb2ad4c5e89b49dd4a5eebdf5/result.json`，检查了 15 个控件并由「取消」退出；该冒烟结果是上方完整交互套件的补充。
- 当前环境报告 `10.0.26220.9492`，属于 Windows 11 25H2 Insider 的 26220 构建线；微软说明见 [Windows Insider 官方公告](https://blogs.windows.com/windows-insider/2025/08/29/announcing-windows-11-insider-preview-build-26220-5770-dev-channel/)。注册表名称仍写 Windows 10 Pro for Workstations，故系统名称元数据不一致。用户将本轮系统验收范围收窄为 **Windows 11 Insider**；上述管理员桌面 GUI、真实 ACL 与真实满卷证据满足这个环境范围，不代表 Windows 10、稳定版 Windows 11 或标准用户会话已验证。
- 标准用户验收的第一次尝试仍在 `Nomozi` 账户进行；本机 `net user Nomozi` 显示其属于 Administrators 组，未提权窗口不等于独立标准账户。复制到用户目录的旧 `core-test.ps1` 在加密 7z 的 `l` 列表操作漏传密码，等待终端输入，运行被 Ctrl+C 中断，不能记作标准用户通过。工作区脚本已改为显式错误密码并收紧断言；在 Codex 会话使用同一 review3 候选程序复跑 **39/39**，但仍需在真正标准账户中复制修正版重跑。
- 随后用户贴出另一次压缩测试的完整汇总 **39/39**，并贴出 GUI 脚本启动命令，但没有 GUI 最终汇总、`result.json` 路径或 `whoami`。用户表示已删除该标准用户的数据；当前工作区未发现该次 GUI 结果。因账户身份与 GUI 完成状态均无可复核证据，这次不能记作标准用户 GUI PASS。先前管理员会话的 373/373 仍有效，但不替代标准账户验收。

## 仍未完成项目

真实 ACL 与真实满卷故障现已在当前源码原生构建上通过；Windows 11 Insider 管理员会话完整 GUI 验证为 373/373，设置页独立导航检查也通过。Windows 10 与稳定版 Windows 11 不在本轮验收范围内。恢复上一版本按钮仍为后续功能；当前只有本地密文备份与手动恢复说明。目标系统的标准用户会话、断电、其他 GUI 语言与交错操作仍未验证。review3 Defender 复核按用户要求跳过，不能引用旧版本扫描。未签名程序可能误报；本包继续作为受控内测，公开发布为 **No-Go**。
