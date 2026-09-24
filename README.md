# 7-Zip 密码管家版

基于 7-Zip 26.03 修改的本地密码管理与压缩解压工具。本项目不是 7-Zip 官方发行版。便携包长期不签名；下载前请从独立可信渠道取得并核对该版本的 SHA-256。安全扫描状态以同版本 `.build.json` 为准，`not-reviewed` 不表示已通过扫描。

## 使用范围

- 已验收范围：Windows 11 Insider x64。独立标准用户在相同哈希的两个 GUI 程序上完成 393/393 项交互及升级回滚检查；其他 Windows 版本不在本轮验收范围内。原始结果及限制见源码仓库 `docs/review4-upgrade-rollback-20260923.md`。
- 简体中文、繁体中文、英文。
- 密码条目新增、修改、删除；从列表填入压缩/解压密码；按名称辅助填入。
- Windows 账户加密（DPAPI）和主密码加密两种模式。
- 密码管理模块不提供网络、云同步、遥测或自动上传功能。

## 开始使用

核对 ZIP 的独立 SHA-256 后解压 portable ZIP，运行 `7zFM.exe`；`7zG.exe` 使用相同的密码库代码。不提供安装器、首次启动注册、快捷方式登记、卸载脚本或 SFX。

两个 GUI 程序已静态链接 MinGW 运行库；使用便携包不需要安装编译器，也不应依赖编译器目录出现在 `PATH` 中。

默认密码库位于 `%APPDATA%\7-Zip\7zPasswordVault.dat`。程序目录可自由移动，密码库不会随之移动。删除程序目录即可移除便携程序，用户目录内的密码库仍保留。

在“工具 → 选项 → 密码”中选择位置和加密方式。未指定路径时，程序目录和 APPDATA 中只有一个库文件就直接使用它；两个库文件都存在才询问选择，取消后本次不打开密码库。均不存在时使用 APPDATA 默认路径。不会静默迁移文件。

每次覆盖已有密码库前，保留上一份原始加密文件为同目录的 `7zPasswordVault.dat.bak`（自定义文件名则追加 `.bak`）。只保留上一版本；首次保存不生成备份。备份创建或替换失败会中止保存，原库保持不变。主文件替换失败时，备份可能与未改变的原库相同。备份始终是本地密文，不导出明文。

恢复时先退出所有本程序进程，保留当前文件，再将 `.bak` 复制到新的路径并在设置中选用；不会自动用备份覆盖损坏的库。备份使用上一版本的加密方式和主密码，修改主密码后旧备份仍需要旧密码；DPAPI 备份仍受原 Windows 账户约束。备份也可能包含刚删除的条目，应按敏感数据保管。

设置页新增“恢复上一版本…”：先应用或取消未保存的设置，验证当前库对应的 `.bak` 后确认恢复。自动恢复仅接受 v4 备份；主密码备份需要备份当时的密码，DPAPI 仍受 Windows 账户约束。当前库损坏或缺失时也可恢复可验证的备份。最近的修改将撤回，已删除的条目可能重新出现。此功能的候选验收状态见 [恢复验证记录](docs/restore-validation.md)，历史发布结果不能代替新功能验收。

恢复前会保留原始文件字节到同目录唯一的 `.pre-restore-<日期>-<随机ID>` 密文副本；该副本不自动删除。恢复采用同目录临时密文和原子替换，提交前失败不改变当前库或 `.bak`。恢复本身不轮换 `.bak`，之后正常保存仍按原规则轮换。不存在原文件时不生成恢复前副本。恢复文件成功但设置刷新失败时，会明确提示部分完成，不再次覆盖文件。

新版使用同目录的空 `.session.lock` 协调密码窗口和恢复操作。正常会话可同时保存，恢复要求其他使用此库的密码窗口已关闭；崩溃后 Windows 自动释放句柄。不要手动删除正在使用的协调文件。首次打开可编辑库需要在其目录创建协调文件的权限；只读导入和备份验证不创建协调文件。旧版本不参加此协调，恢复前须关闭旧版程序。密码库文件或 `.bak` 为目录、重解析点或多硬链接文件时拒绝保存和自动恢复。

便携**程序包**不等于便携**密码库**。如需把库放到 U 盘或其他目录，须明确设置路径，建议先设置主密码。DPAPI 库只能在对应 Windows 账户/环境解密。主密码遗失无法恢复。

“设置主密码”需输入并确认新密码；已有主密码库需先用旧密码解锁。错误密码或取消操作不会覆盖原库。可以切换回 DPAPI。选择新库位置时只复制到尚不存在的目标，保留原文件作为恢复副本；合并现有库请使用“导入”。

## 安全行为与边界

- 保存时以规范化路径建立跨进程互斥锁；在锁内读取当前文件、合并本次变更、写临时文件、刷盘和替换。不同记录的新增可合并；同名新增或同一记录的冲突会报错。
- 比较文件的完整内容，不依赖大小和修改时间。保存失败回滚内存；无法读取、被锁定或损坏的密码库不会作为空库覆盖。
- 新写入格式为 v4：DPAPI 一次保护完整序列化密码库，绑定条目数量、顺序和名称/密码配对。v2/v3 仍可读取，成功保存后写入 v4。**升级前请保留旧文件备份；旧程序不能读取 v4。**
- 主密码使用 PBKDF2-HMAC-SHA256（200,000 次）和 AES-256-GCM，每次保存使用新的盐和 nonce。
- **“主密码缓存 5 分钟后过期”仅在下次请求缓存密码时检查有效期，不是自动锁定。** 已打开的库、列表和填入字段不会因此锁定。结束使用后关闭相关窗口和进程。
- 为条目和主要敏感字符串增加退出/替换清理，明文缓冲采用不可优化掉的擦除。Windows 控件、系统分页、压缩模块和普通字符串接口仍可能持有副本，不承诺清除系统中所有明文。
- 临时文件刷盘与原子替换降低中断风险，不保证任意存储设备断电后绝对不损坏，也不防御整份有效旧文件的回滚攻击。请保留加密备份。

## 验证与发布

构建和验证步骤见 [BUILD.md](BUILD.md)。安全边界、历史验证与后续功能见源代码仓库内的 `docs/security-remediation.md`。

项目长期发布未签名 portable ZIP。公开打包门禁要求独立核验上游源码及运行时输入、Windows 11 Insider 标准用户 GUI 验收，以及绑定当前两个 EXE 哈希的升级回滚验收；源码须已提交且工作区干净。扫描状态如实记录为 `not-reviewed`、`scan-unavailable` 或有同哈希证据的结果。独立哈希和随包构建记录只能证明相互一致，不能证明发布者身份；未签名程序仍可能触发警告或误报。

遇到安全软件拦截，请核对可信发布渠道及独立公布的 SHA-256，并报告当前哈希供开发者复核；不要关闭防护或添加排除项。项目不采用混淆、加壳或规避扫描手段。

## English

This is an unofficial 7-Zip 26.03 fork. The verified scope is Windows 11 Insider x64. An independent standard-user session passed 393 GUI and upgrade/rollback checks with executables byte-identical to this portable build. English, Simplified Chinese, and Traditional Chinese interfaces are available.

Extract the ZIP and run `7zFM.exe`. The vault defaults to `%APPDATA%\7-Zip\7zPasswordVault.dat`; a portable vault requires an explicit location and a master password for cross-device use. Existing program-folder vaults require an explicit choice. Migration preserves the original and refuses an existing destination.

Concurrent saves merge independent changes under a cross-process mutex. Conflicting changes fail visibly. DPAPI v4 authenticates the entire record sequence; v2/v3 are read for migration only. Back up before upgrading: some older builds cannot read v4.

The five-minute setting expires the cached master password when it is next requested. It does **not** lock an open vault or clear a visible password field. Sensitive owners and buffers are wiped on scope exit, but complete removal of all system/UI copies is not guaranteed.

This portable build is unsigned by design. The current security-scan status is `not-reviewed`, which does not mean that a scan passed. Verify the ZIP SHA-256 from an independently trusted project channel before use. Unsigned files may trigger warnings or false positives. Do not disable antivirus protection or add exclusions. See BUILD.md for build and verification commands.

## 许可证

继承上游 7-Zip 的许可条款；请参阅 `DOC/License.txt`、`DOC/copying.txt` 和 `DOC/unRarLicense.txt`。发布包包含上游 `License.txt`，本项目不冒充 Igor Pavlov 或其他官方签名发布者。
