# 恢复功能候选验证

2026-09-24：开发候选，尚未公开发布。范围仅 Windows 11 Insider x64（本机 build 26220），未签名，Defender 未复核。协议见 `restore-protocol.md`，原计划见 `restore-previous-version-plan.md`。

## 当前冻结候选

- ZIP：`dist/restore-release-20260924/7z-password-vault-1.6.0-restore-dev3-win64-internal-test.zip`
- ZIP SHA-256：`5fb6910ab854989250d8b1fbd777d54e2ade3a18432bcd31f7300f4938f18319`
- 7zFM.exe：`BA5860CED63A5A769AAC54731F7B34400FA2CE49147E00887C018E4E92D51AF7`
- 7zG.exe：`399287C354CE64DAF606B0ECB794E3E7AF47BB9B07D718ABCF8F742317B81AD1`
- GUI 脚本：`E15D57AA283DF25D508D31FF0A904343C42BBD2EB8627D048685F41606647B0A`

该 ZIP 的构建记录如实标记开发时源码有未提交改动。后续干净提交构建若重现相同 EXE，只补充可重现证据，不追改此历史 `.build.json`。哈希、sidecar、包内清单为完整性校验，不等同于签名或来源真实性证明。

## 已实际执行

| 验证 | 结果 | 原始记录 |
| --- | --- | --- |
| 最终生产代码的原生完整回归 | PASS；真实 DPAPI、ACL、注入故障、恢复前后崩溃、旧主密码及 200 次并发保存 | `tests/b/native-run-83934a0c5f254bb79ecb62b3bcdc3829/result.json` |
| 完整 GUI 与 v1.5.0 升级/回滚 | 426 通过、0 失败；账户 WW\Nomozi，未提权，不能冒充独立标准账户 | `tests/b/ui-run-87fb8e6387d3477282e1a7d554dcd3d8/result.json` 及同目录 `upgrade-rollback-result.json` |
| 核心压缩 | 39/39，dev3 | `tests/restore-core.log` |
| 运行时输入 | 10/10 | `tests/restore-runtime.log` |
| 发布门禁回归 | 33/33（门禁脚本未再变化） | `tests/restore-release-gate.log` |
| portable 包验收 | dev3 PASS | `tests/install-acceptance.ps1 -Package <上述 ZIP>` |
| 三种语言资源 | 生产语言解析器通过 en、zh-cn、zh-tw 及新增消息字段检查 | 上述原生回归；不等于三种语言的所有缩放均已目视验收 |

GUI 新用例验证默认取消、未应用设置拒绝、其他会话占用拒绝、恢复密文字节、`.bak` 不变、恢复前副本、重启后的条目，以及用恢复后的密码实际解压并比较内容。

管理员已执行真实磁盘满恢复：`tests/b/real-disk-36188f2ec3fd4e90b219956f05e1c5a4/result.json`。96 MiB 隔离 VHD 剩余 0 字节，写入错误 112；恢复在 `preserve-current` 阶段拒绝，保存及恢复保护断言通过，VHD 已卸载删除。它绑定先前原生 EXE `E4C0C6C9EC2263257FD5BEADCA39572F92B2138A8FB60F4EC6079C2530D91F7E`。随后生产代码仅修正关闭句柄时保留错误码；最终原生 EXE 为 `99CC140D1F03426A3D292E729C75E8004916338D7D74A566291AB7489D54862A`，已请求最终 EXE 的同项实测，不混用两次证据。

## 历史失败与环境限制

- `native-run-3f15bec54fd24d57bc0e2f2cfaa23223`：受限账户真实 DPAPI 探针错误 2，`ENVIRONMENT_BLOCKED`，不计通过。之后普通用户会话完整重跑通过，未改用模拟 DPAPI。
- `native-run-b1c594d7d9e049f58074bae2d1edc233`：原生、ACL 与注入测试通过，VHD 因无管理员令牌受限；该轮不能算全通过。
- `native-run-21bc66365acc426caaf2d5eb050cf82b`：新增语言测试传错产品标识，修正为生产解析器要求的 `7-Zip` 后完整重跑通过。
- GUI `ui-run-ec52e8a36e0a498582fa9b8d5a5b2aa0`：语言条目顺序错误导致载入失败；已修正资源排序。
- GUI `ui-run-caae85ac5b79418aa7612a2627acb1eb`：418/7，重开设置窗口后仍停留系统页；已修正旧窗口销毁等待及属性页选择，保持原断言，最新完整重跑 426/0。两轮失败记录保留。

## 尚待完成

- 独立标准账户 `cs` 的同哈希完整 GUI/升级回滚：运行 `tests/restore-standard-user-run.ps1`；自动复制结果到公共文档目录。
- 最终原生 EXE 的真实恢复磁盘满记录；干净已提交源码构建并比较两个 EXE。
- 不同 Windows 账户对 DPAPI 备份的实际拒绝；三种语言的显示缩放/键盘专项验收；注册表写入失败的专项 GUI 验收。
- 原计划中的启动残留材料提示及临时文件清理失败单独报告尚未实现。当前只保留密文材料，绝不自动使用崩溃残留覆盖库；完整恢复前副本保留供手动找回。

当前候选不替代 v1.5.0 正式版。公开发布门禁仍为 No-Go，不能把现有通过项描述为全部计划完成或无 bug。
