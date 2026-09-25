# 1.6.0-rc1 发布候选说明

本候选增加“工具 → 选项 → 密码管理 → 恢复上一版本”。它验证当前库对应的 v4 加密备份，确认后保留恢复前密文，再原子替换当前库。取消、错误密码、占用、权限拒绝或磁盘满不会提交恢复；`.bak` 保持不变。旧备份可能包含已删除条目，并可能需要旧主密码。

启动时发现恢复临时文件会提示检查，不自动使用或删除。清理失败及恢复后的设置写入失败分别报告，避免把“文件已恢复”误报为“没有改变”。恢复前应关闭旧版程序；旧版不参与新会话协调。

验收范围仅 Windows 11 Insider x64 build 26220。普通桌面及独立标准账户完整 GUI 各 436/436，三种语言恢复专项各 45/45；覆盖 150% 缩放，简体中文标准账户另覆盖 200%。核心压缩 39/39、运行时输入 10/10、发布门禁回归 34/34，以及真实 DPAPI、跨账户拒绝、真实 ACL、隔离卷磁盘满、崩溃保护和升级回滚均有对应记录。

两个 EXE 已由干净提交 `77addbfbdd430db3ff29db76ae8f506039eb450b` 独立重建并核对哈希。公开候选重新组装文档与包清单，程序和语言资源沿用已测内容；ZIP 哈希因此与 dev4 不同，以新包 sidecar 和 `.build.json` 为准。

程序未签名；Defender 为 `not-reviewed`，未上传复核，不能称为扫描通过或不会误报。哈希用于完整性核对，不是签名验证。不保证其他 Windows 版本或未测显示缩放。本包为 portable ZIP，不带安装、卸载或自启动脚本，也不含用户密码库。

原始证据与剩余边界见 `docs/restore-final-validation.md` 和 `docs/restore-dev4-evidence/`。本地生成候选包不代表已经上传 GitHub。

## 最终交付（2026-09-25）

- 便携包：`dist/v1.6.0-rc1-final-20260925/7z-password-vault-1.6.0-rc1-win64-portable.zip`
- ZIP SHA-256：`9f028785a940ce3f86d635a3a85655b331b9331e256872dc32da947dcf62985d`
- 对应源码：同目录 `7z-password-vault-1.6.0-rc1-source.zip`，SHA-256 `2c36b470e32f7c26a9a4d89ffc341a18c703d1f355c833f9248ff9746d53cd99`。
- 打包提交：`a4800dc35829d83bf186f689dc3f13aaec8aa2a6`；`.build.json` 记录 `sourceDirty=false`、`internalTest=false`、两个 EXE `NotSigned`、扫描 `not-reviewed`。
- 新包通过 ZIP/sidecar/包内清单核验，15 项 SBOM 与 1494 个源码清单文件逐一匹配；详见 `docs/restore-rc1-package-validation.json`。代码、语言资源及测试脚本与已独立重建的 `77addbf` 相同，仅更新随包说明和归档证据，复用同哈希程序的实测结果。

较早的 `dist/v1.6.0-rc1-20260925/` 是本轮说明修订前的组装产物，保留追溯，不作为发布输入。发布请使用上述带 `final` 的目录，连同 `.sha256`、`.build.json`、`.source.sha256`、`.sbom.json` 和源码归档提供；不要混用两组哈希。

源码 ZIP 来自上述提交的 `git archive`；它不包含上游运行时二进制、编译器或用户数据。源码编译及组装所需固定输入按 `BUILD.md` 准备。源码压缩包本身没有 `.git`，如需重新执行干净提交公开打包门禁，应从 Git 仓库检出对应提交。
