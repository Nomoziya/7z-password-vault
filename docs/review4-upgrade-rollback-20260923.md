# review3 → review4 升级与回滚验收

目标是冻结 review4 ZIP 中 SHA-256 为 `d678e6b42ea574db4db26f66992e613535f76bb402a453aa02d66b0f4166ba92` 的 `7zFM.exe` 和 `2b352bb0f7a94cf77ad3b53735f9803e36b3e5fc5f3fa94ef0fe8b5fa7f56aad` 的 `7zG.exe`。旧版来自已验证 sidecar 与包内清单的 review3 ZIP。review3 曾缺少随包提供的 MinGW DLL；本测试只在隔离旧版目录放入 3 个测试专用 DLL，哈希见 [旧版测试基线](review3-upgrade-baseline-20260923.json)。此目录不作为发布包。

在 Windows 11 Insider 26220.9492 的 `Nomozi` 普通桌面会话中，完整 GUI 回归为 **393/393、退出码 0**，其中新增的 20 项检查覆盖：review3 建立主密码加密库；review4 打开旧库、保存新条目、重新启动后读取两个条目；`.bak` 与升级前密文逐字节一致；把升级前密文复制到**另一条测试路径**后，review3 能读回旧条目及密码，且不包含后来新增的条目；升级后的库未被回滚操作覆盖。结果见 [完整 GUI 记录](review4-gui-nomozi-20260923.json)和 [升级回滚记录](review4-upgrade-rollback-nomozi-20260923.json)。全过程只使用测试库，未生成明文库文件。

独立 `WW\\cs` 标准账户随后使用同一测试脚本和相同 review4 EXE 完整复跑，结果为 **393/393、退出码 0**。原始结果已从该账户的隔离测试目录复制并核对，见 [标准用户 GUI 结果](review4-gui-cs-20260924.json)及[升级回滚结果](review4-upgrade-rollback-cs-20260924.json)。备份和回滚副本的 SHA-256 均为 `780642eb3fe5bc53d544ecbd728d47298e05660839fb541cde0477d258d9c119`，与升级前密文一致；升级后库的 SHA-256 不同，且未被覆盖。[当前证据索引](review4-validation-evidence-20260924.json)绑定测试脚本、两个 EXE、输入锁和两份原始结果的哈希。

这是 review3→review4 的程序替换与数据回滚验收；两版都使用 v4 密码库格式。它不能代表 v2/v3 旧格式的实际跨版本 GUI 迁移、断电恢复或生产密码库恢复。测试证据和同目录哈希不构成签名认证；review4 构建时源码未提交，公开发布仍为 No-Go。
