# 当前验收范围与历史记录

> **当前冻结内测包为 review4-release-20260923**（`7z-password-vault-26.03-review4-20260923-win64-internal-test.zip`，SHA-256 `37166d2b30f4d08d96239fac0e7bef5b77d88d6efca2e5d8196ae40bd1f62c7d`）。review3 在独立标准账户 `cs` 中启动 GUI 时暴露未打包的 MinGW DLL 依赖，现已由 review4 的静态链接修复。review4 压缩回归 39/39、运行时输入 10/10、包完整性验收通过；`cs` 的当前完整 GUI 与升级回滚验收为 **393/393**，先前单独 GUI 验收为 373/373。门禁脚本回归数量以本次输出为准，仅验证门禁逻辑，不改变冻结 review4 包。下方旧版 67/392 项、SFX、卸载器及其“通过”结论均为历史结果。Defender 本轮按用户要求不复核、不上传；两个 EXE 未签名。详见 [review4 验证记录](review4-validation-20260923.md)。

> 当前政策为长期发布未签名 ZIP。review4 的上游输入来源已核验，`Nomozi` 普通桌面和独立 `cs` 标准账户均完成 review3→review4 升级回滚 GUI 验收，各为 **393/393**；[标准账户原始结果](review4-upgrade-rollback-cs-20260924.json)已纳入[证据索引](review4-validation-evidence-20260924.json)。构建时源码仍未提交，故**公开发布仍为 No-Go**。`not-reviewed` 或 `scan-unavailable` 只能如实记录，不能称为扫描通过。门禁细节见 [BUILD.md](../BUILD.md)。

本轮追加验证见 [review3-validation-20260923.md](review3-validation-20260923.md)：设置页导航冒烟、真实 ACL、注入式磁盘故障和真实满卷保存回滚均有当前源码证据。管理员会话下最新原生构建、真实满卷子测试及完整套件均为 PASS，EXE 哈希与源码输入摘要记录在验证报告中。较早的小种子测试曾在零空闲空间下保存成功，已通过扩大种子夹具修正；不得沿用旧结果。Codex 沙箱账户不是管理员，DPAPI 无法初始化且 UAC RunAs 启动失败；这边的 `PARTIAL_ENVIRONMENT_BLOCKED` 与 `ENVIRONMENT_BLOCKED` 记录仅代表隔离会话，不覆盖管理员终端的当前 PASS。

## review3 历史验收记录（2026-09-23；不适用于当前 review4 包）

发布方式为解压 `internal-test.zip` 后运行 `7zFM.exe`，没有 SFX、安装器、卸载脚本、首启登记或快捷方式注册。继续受控内测，公开发布仍为 No-Go。不进行付费签名；未签名程序仍可能被误报，历史扫描不能代表新构建。

当前 `tests/install-acceptance.ps1 -Package <zip>` 验证独立 ZIP 哈希、解压文件白名单和完整包内哈希清单，输出一条组合 PASS；**不运行历史的 67 项安装或 26 项便携测试**。`core-test.ps1` 的数量以实际输出为准；原生安全测试覆盖真实 DPAPI/AES、双库路径选择、缓存失败清除、加密上一版本备份、故障回滚及 200 次双进程保存。`runtime-input-test.ps1` 验证默认 ZIP 来源与拒绝路径。

`tests/ui-accessibility-test.ps1` 在当前桌面实际打开 review3 的 7zFM「选项→密码管理」页，检查 15 个控件并按「取消」退出；最新证据为 `tests/b/ui-accessibility-acc4db3eb2ad4c5e89b49dd4a5eebdf5/result.json`。完整 `tests/ui-test.ps1` 在 Codex 账户下因 `HKCU\Software\7-Zip` 拒绝写入而无法启动；[环境阻塞结果](../tests/b/ui-test-blocked-8f4093a512d04223b17fb2c1505db034/result.json) 留存了原因。用户管理员会话先在第 16 组被交互式 7z 检查卡住，修复后完成一次 **338/349** 的 GUI 运行，[11 项失败记录](../tests/b/ui-admin-run-report-00eaf737a7314a1e92281d378b35f6a9/result.json) 已保留。失败集中在旧版迁移删除预期、缺少双库夹具和已移除的首启登记场景；测试脚本已按 review3 语义修正，旧 GUI 数量不能作为当前版本证据。`uninstall-test.ps1` 和 SFX 归属脚本已明确拒绝用于当前便携版。

最终用户管理员会话的完整 GUI 复跑结果为 373/373、退出码 0，证据见 tests/b/ui-run-efdd5c12047f4f3bb39e8f1ddbbd16d5/result.json。前一次修订版 372/373 的唯一失败是测试在主窗口出现前发送打开设置页指令；等待主窗口后完整复跑通过。最新独立设置页检查见 tests/b/ui-accessibility-acc4db3eb2ad4c5e89b49dd4a5eebdf5/result.json。此结果属于用户管理员桌面，不能当作 Codex 受控账户的通过记录。

当前桌面报告版本号 `10.0.26220.9492`，属于 Windows 11 25H2 Insider 26220 构建家族；注册表 `ProductName` 却显示 Windows 10 Pro for Workstations，元数据彼此不一致。微软将 `26220.xxxx` 标为 Windows 11 Insider 25H2 构建（[微软说明](https://blogs.windows.com/windows-insider/2025/08/29/announcing-windows-11-insider-preview-build-26220-5770-dev-channel/)）。用户将系统验收范围限定为 Windows 11 Insider；管理员桌面的完整 GUI、真实 ACL 和真实满卷证据满足该环境范围，独立 `cs` 标准用户的当前完整 GUI 验收亦通过。Windows 10 与稳定版 Windows 11 不列为本轮必验项。

真实 ACL 故障已在一次性测试文件和父目录上验证并精确恢复 DACL；真实 VHD 满卷保存失败及主库、备份、内存和缓存不变量均已通过最新管理员运行验证。Codex 受控身份不能通过 UAC 启动管理员进程；其受限运行返回 `ENVIRONMENT_BLOCKED`，未触碰磁盘卷。公开发布仍为 **No-Go**：目标系统 Windows 11 Insider 的管理员及标准用户验收均已有记录，但当前冻结包构建时源码未提交，且本轮 Defender 复核按要求未做。未签名是已接受的长期发布政策，不把签名列为本轮硬门槛。

## 以下为 v1.4.4 历史记录，全部结果仅适用于当时产物

以下旧用例、数量和“通过”结论不适用于当前脚本或当前构建；保留仅供追溯。当前验收以本页上方范围及本次实际日志为准。

这份文件回答两件事：**「报毒减少」怎么算通过**、**安装/卸载凭什么算验收通过**，并记录当前证据与缺口。
配套脚本：`tests\install-acceptance.ps1`（安装/卸载端到端）、`tests\vt-attribution.ps1`（归属实验）、
`tests\vt-upload.ps1`（提交并读回 VirusTotal 报告）。

## 1. 报毒验收标准 / Detection acceptance criteria

**扫什么**：两个发布产物（`portable.zip`、`setup.exe`）+ 包内全部 exe/dll；**对照必须同时看**包内未修改的官方
文件（`7z.sfx`、`7z.exe`、`7z.dll`）。

| 项 | 标准 |
|----|------|
| Defender 预扫 | 本机 `MpCmdRun -Scan` 对解压目录 0 告警 |
| VirusTotal | 每个文件 ≤ 对照基线 + 1，且**绝对检出 ≤ 2 个引擎** |
| 引擎归属 | 命中引擎名若同时出现在官方对照的命中名单里，视为引擎噪声，不计入 |
| 稳定性 | 同一 hash 连查两次结果一致 |
| 透明 | 发布说明必须列出命中的引擎名与原因（见 `docs/vt-false-positive-report.md`） |
| 复扫触发 | 任一 exe/dll 重建、打包方式变化、签名变化、发布前、距上次扫描 > 90 天 |

**防自身上传造成的假象**：先按 hash 查询（命中即复用已有报告，省配额；免费额度 4 请求/分钟），只有缺失时才上传；
上传后立即记录 `sha256` 与首轮结果；探针文件（`vt-attrib`）绝不与发布产物同名或混放。

**当前结果**（2026-09-14，详见 `docs/vt-attribution.md` 与 `docs/vt-false-positive-report.md`）：
公开发布只有便携版 zip，**发布集合 3 个文件合计 1 个检出**——`portable.zip` 0/67、`7zG.exe` 0/65、
`7zFM.exe` 1/69（微软 `Wacatac.B!ml`，ML 判定）。改造前是 7 个检出；自解压 `setup.exe` 已停发，
它带来的 Elastic 与 CrowdStrike 两个检测随外壳一起消失。

## 2. 安装 / 卸载端到端验收 / INS cases

全部自动化在 `tests\install-acceptance.ps1`（**67 项检查，当前 67/0，verdict: accepted for this scope**）：

| 用例 | 内容 | 现状 |
|------|------|------|
| INS-01 | 用包内 7z.exe 解出 setup.exe 载荷（不启动 SFX 的 GUI），校验文件集合与载荷内 `SHA256SUMS.txt` 一致 | ✅ |
| INS-02 | `install.cmd` 在隔离目录运行并创建「应用和功能」条目（字段、版本号） | ✅ |
| INS-03 | `uninstall.cmd` 卸载后：目录整体消失、`install.*`/`uninstall.*`/`SHA256SUMS.txt` 均无残留 | ✅ |
| INS-04 | 无哈希清单时走「按名删除」回退，并且**明确播报**自己会按名删 | ✅ |
| INS-05 | 与他人共用的目录：同名不同哈希、清单未列出的文件必须保留，并说明保留了哪些 | ✅ |
| INS-06 | 隔离要求：测试把卸载器指向自己拥有的密码库文件，并在 `finally` 里用备份恢复用户真实密码库 | ✅ |

已知不完全覆盖的部分：真实 SFX 双击流程（会弹文件夹选择对话框，无法无人值守）、快捷方式是否出现在真实
开始菜单（`-IncludeShortcuts` 才做，默认跳过以免污染用户环境）。

## 3. 回归用例 / REG cases

| 用例 | 内容 | 现状 |
|------|------|------|
| REG-01 | 库损坏时输入未保存的密码：不弹「保存这个密码？」、库文件哈希不变 | ✅ `ui-test` 23 + `OfferToSave` 的 `!_loaded` 判断 |
| REG-02 | 库可读时输入**已存**密码：不弹询问 | ✅ `ui-test` 24b（新增：输入已保存的密码后 4 秒内不出现询问框） |
| REG-03 | 卸载后逐文件断言无残留（含 `install.*`） | ✅ `install-acceptance` 阶段 3 |
| REG-04 | 清单缺失时回退按名删除并播报 | ✅ `install-acceptance` 阶段 4a |
| REG-05 | 「两个默认库只问一次」选「是」（用程序目录）分支 | ✅ `ui-test` 24b（记录程序目录位置，且 `%APPDATA%` 的库内容不变） |
| REG-06 | 「取消」分支：程序可用、不写位置、下次仍询问 | ✅ `ui-test` 24b |
| REG-07 | 未被选中库文件在问答前后哈希不变 | ✅ `ui-test` 24b（两个库文件在整组测试后逐字节比对） |
| REG-08 | 首次启动只问一次、选「否」不建快捷方式/不写卸载项、下次不再问 | ✅ `ui-test` 26 |
| REG-09 | 从程序目录内部启动卸载器时目录能被真正删除 | ✅ `install-acceptance`（此用例发现并修掉了真实缺陷） |
| REG-10 | 设置页 2616 按钮一点即登记：卸载项指向本目录、两个快捷方式建立、`LastRegistered` 记录本目录 | ✅ `ui-test` 27 |
| REG-11 | 登记目录消失后：询问一次；选「否」记住这对目录不再问；选「是」则卸载项与快捷方式改指本目录 | ✅ `ui-test` 27（两条分支各测一次） |
| REG-12 | `LastRegistered` 指向仍然存在的另一份副本时：不提问、不抢占它的登记 | ✅ `ui-test` 27 |

## 4. 二进制冻结策略 / Binary freeze policy

* 当源码**没有**变化时，不因文档、脚本、README 变更而重新编译 exe：重新编译会产生新哈希，使已经
  提交给微软的误报失效（微软按文件哈希判定）。
* 冻结的**破例条件**：上游 7-Zip 安全修复、换编译器/工具链、加签名、被 AV 拉黑需要送新样本。
* 前提是构建可复现：`-Wl,--no-insert-timestamp` 已使连续两次重新链接产出完全相同的哈希（见 `BUILD.md`）。
* 本次实践已验证该策略有效：改造后只重打包（脚本与外壳变化）时，两个 exe 的哈希不变，因此**不需要**重新提交。

## 5. 结论 / Verdict

对被测范围（便携包 + 自解压包 + 卸载器 + 首启登记）：**通过**（`ui-test` 392/392、`uninstall-test` 27/27、
`core-test` 39/39、`install-acceptance` 67/0（SFX 版）/ 26/0（便携 zip 版）、标签检查 en 无截断、zh-cn 1 处官方既有差异）。

已无遗留回归缺口（上表 9 组全部有自动化证据）。仍未做、不影响验收的项：真实 SFX 双击流程的无人值守验证
（会弹出文件夹选择框），以及代码签名。更正：代码签名也不能保证消除误报，不能作为当前安全性或发布验收的替代证据。
