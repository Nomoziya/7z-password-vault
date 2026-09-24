# 恢复功能收尾候选 dev4

2026-09-24。范围仅 Windows 11 Insider x64。dev3 原始记录保留在 `restore-validation.md`；本页记录新增收尾实现，不以旧程序的验收冒充新程序结果。

## 已实现

- 启动文件管理器或密码窗口时发现当前库对应的 `.restore-tmp-*`，只提示确切路径，不自动使用或删除。正常恢复前副本不反复提示。
- 临时密文清理失败单独报告路径和清理错误，保持原恢复提交状态及错误码。
- 原生测试增加清理拒绝、崩溃材料只读发现和实际跨账户 DPAPI 夹具入口。
- GUI 专项增加三种语言、实际窗口 DPI、按钮文字边界、真实 Escape 取消、启动提示与真实注册表 ACL 拒绝写入后的部分成功提示。
- 发布门禁拒绝以 `restore-focused` 专项结果替代完整标准账户 GUI 验收。

## 冻结产物

- ZIP：`dist/restore-release-20260924/7z-password-vault-1.6.0-restore-dev4-win64-internal-test.zip`
- ZIP SHA-256：`4b95dcb15d27a0db61f7cd3372855133f46ff43da8457180777e18ff39b0506b`
- 7zFM.exe：`2908567C6B7088450216FE708848A20E501EA87F6B7483D7E518A21BF0F05CA2`
- 7zG.exe：`839BB203FBAF37E1DB5D6A2EC4CEE8433AFA85826FAA315E82C0D5E9D5B8F62B`
- 原生测试 EXE：`44F89862AEC8299407B40C911F48C1AFCFDE2DBFEC4C157031D3DF396AB83144`
- GUI 脚本：`205D29508D6E71539C93CB1279F38E01BEFAC54BB072F9F5BBA696D786521882`

dev4 为未签名内测包，生成时源码尚未提交，保留真实 `sourceDirty=true` 记录。Defender 为 `not-reviewed`，不代表扫描通过。后续干净构建单独记录其提交及与上述 EXE 的比较结果。

## 当前证据

| 检查 | 结果 | 原始路径 |
| --- | --- | --- |
| 原生完整测试 | PASS，真实 DPAPI、恢复/清理故障、真实 ACL、崩溃及 200 次并发保存 | `tests/b/native-run-5e274fe6b25f4a79aef959ee2e69f144/result.json` |
| 简体中文恢复专项 | 45/45 | `tests/b/ui-run-7c7a13328fe844f3ac64597c16da4841/result.json` |
| 英文恢复专项 | 45/45 | `tests/b/ui-run-6c01208c469a480cacb25a20205da073/result.json` |
| 繁体中文恢复专项 | 45/45 | `tests/b/ui-run-2f183cde698e4d58babf2aeff95b2e25/result.json` |
| 核心压缩 | 39/39 | `tests/restore-final-core.log` |
| 运行时输入 | 10/10 | `tests/restore-final-runtime.log` |
| 发布门禁 | 34/34，包含专项冒充完整验收的拒绝测试 | `tests/restore-final-release-gate.log` |

三种语言均在实际窗口 DPI 144（150%）验证文字边界、键盘取消和恢复流程。未修改系统显示设置；100%/125% 未运行，不能把本结果泛化到所有缩放。

## 测试夹具修正与历史失败

- 首轮编译使用了不存在的单参数 `UString::Mid`，修正为项目支持的字符串接口后完整编译、原生测试通过；失败记录 `native-run-d6009518b7a744deaf6bf4736f1931b4` 保留。
- 新 GUI 辅助类初次编译有重复 `GetParent` 声明，已移除重复项。
- 注册表故障夹具曾无法恢复拒绝规则，导致设置仍指向本轮测试库。已移除本轮精确的拒绝规则，真实密码库文件未更改；用户无法确认原位置，依据既有备份无自定义路径的事实，清除本轮临时路径并恢复默认选择，不声称找回了未知的旧配置。
- 夹具现在预先持有权限专用句柄，通过显式安全描述符恢复 ACL。Windows 会更新 `DACL_AUTO_INHERITED` 状态位，因此比较全部 ACE 原始字节及继承保护策略，确认权限完全恢复，而不把系统维护的该状态位误判为权限变化。
- 设置恢复不再删除重建整项注册表键；测试前保存本轮配置快照。失败记录 `ui-run-4238c16a6a884c879a5e5ee0bdb93058`、`ui-run-e7573fc445ed49a8845d7edc8d5c5520` 及 `tests/restore-final-focused-zh*.log` 保留，之后三种语言专项全部通过。

## 待收齐

- dev4 完整 GUI 与升级回滚回归、干净提交重建及包验收记录。
- 独立标准账户对 dev4 的完整验收，以及真实跨账户 DPAPI 拒绝。`tests/restore-standard-user-run.ps1` 已固定 dev4 ZIP，并会调用 `restore-cross-account-test.ps1`，将原始结果复制到公共目录。
- dev4 原生测试程序的真实磁盘满记录。dev3 已通过的记录继续保留，但不标作 dev4 实测。

收齐前保持内测候选，不替代 v1.5.0 正式发布。原计划的启动残留提示、清理失败报告及注册表失败 GUI 检查现已实现；当前缺口主要是最终程序的跨会话验收证据。
