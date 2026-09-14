## 更新内容 / Changes

### 修复 / Fixed
- **密码库读不出来时不再让你白填一遍**：「新建密码...」以前会先弹出命名窗口，等你把名称和密码都填好、按下确定，
  才告诉你「无法打开密码库文件」。现在一点「新建密码...」就直接报错，命名窗口根本不会出现。
  同理，库读不出来时「是否保存这个密码？」的询问也不再出现（内存里的条目是空的，问了也存不进去）。
- **卸载后程序目录残留两个文件**：以前的安装包目录里有 `SHA256SUMS.txt`（哈希清单）时，卸载会按清单删除属于本包的
  文件，却漏掉了清单自己和 `uninstall.cmd`，于是程序目录永远删不掉，看起来像卸载失败。现在清单文件会被删除，
  `uninstall.cmd` 交给延迟助手删除（cmd.exe 正在读它），程序目录才能真正清空。
  与他人共用的目录仍然只删属于本包的文件：同名但哈希不同的文件、清单里没有列出的文件都会保留并提示。

### 变更 / Changed
- `install.ps1` 的「应用和功能」条目版本号更新为 `1.4.3`。

### 测试 / Tests
- `tests\ui-test.ps1`（339 项，全部通过）：
  - Windows 不允许跨进程读取 `ES_PASSWORD` 控件，相关断言改为「这个控件仍然是密码框」，**真正填进去的密码**
    由第 24 组用两个可读通道验证：已保存密码列表（普通列表控件）和一个只有正确密码才能打开的压缩包。
  - 失败时只转储 4 个对话框、每个最多 24 个子控件，日志不再是几千行。
  - 运行前后会清理**自己**遗留的 7zFM/7zG 进程（只按可执行文件路径匹配，绝不碰用户自己的 7-Zip）：残留进程会锁住
    `7zFM.exe`，导致下一次构建无法覆盖它。
- `tests\uninstall-test.ps1`（27 项，全部通过）：假安装目录现在也生成 `SHA256SUMS.txt`，因此首次真正覆盖到
  「按哈希清单删除」这条分支；新增第 4 组验证共用目录：同名但哈希不同的文件必须保留、清单里没有的文件必须保留、
  目录因仍有他人文件而保留，并且输出里明确说明保留了哪些。
- `tests\check-labels.ps1`：改为按换行和多行宽度衡量标签，消息框里的长路径（系统会自动换行）不再被误报为「截断」。
  改为多行衡量后，`en` 语言 0 处截断；`zh-cn` 只剩 1 处真实截断 —— 官方「添加到压缩包」对话框里的
  `Archive:` 标签（压缩包(&A)：）超出 19 像素。该标签的宽度来自官方布局（`xArcFolderOffs = 40`），本次改动
  （只在密码行新增两个按钮并把密码框收窄到 96）没有碰它，属于既有的中英文字长度差异。
- `tests\deploy.ps1`：如果输出目录里出现 `*.dat`（密码库）就报错停止，避免把测试残留的库文件打进发布包 ——
  万一里面有真实条目，那就是直接泄漏。
- `tests\core-test.ps1`（39 项，全部通过）：压缩 / 解压 / 加密 7z、AES-256 与 ZipCrypto 的 zip、损坏包处理、
  60+ 文件与怪名字。

发布前实测 / Verified before release: `ui-test` 339/339, `uninstall-test` 27/27, `core-test` 39/39,
`check-labels -UiLang en` 0 clipped, `-UiLang zh-cn` 1 clipped (official label, see above).

### 已知限制 / Known limitations
- 两个进程（`7zFM.exe` 与 `7zG.exe`）同时写同一个密码库时，后保存的一方会在文件被改动过
  （大小或时间戳变化）时报错并要求重试，而不是静默覆盖 —— 不会丢数据，但需要用户再点一次。
- 卸载入口 `uninstall.cmd` 位于程序目录内（用户可写）。多人共用的机器上，能改写该目录的人可以替换卸载脚本；
  单用户机器不受影响。安装到 `Program Files` 等受保护目录可缓解。
- 程序目录与 `%APPDATA%\7-Zip` 各存在一个密码库时，目前一律优先使用程序目录里的那个（首次运行会把
  `%APPDATA%` 里的旧库移动过来），没有提供「两个都保留、由用户选择」的界面。

### 哈希 / Hashes
二进制与整包哈希见包内 `SHA256SUMS.txt`（111 个文件）。本次两个可执行文件：
`7zFM.exe` `d0562b8da64bc99ccf098c245481a6818f9b40202803cb9e7514a64322644bd5`,
`7zG.exe` `befb7ac07bca471cf93b8fa678acd3b841db63b69f53cc155e6101ed01816827`。
构建方式 / Build: MinGW-w64 GCC 16.2.0 (msvcrt flavour), see `BUILD.md`.

---

Fixed: pressing **New password...** on a vault that cannot be read used to open the name
window first and only report the failure after you had typed a name and a password; the
refusal is reported immediately now, and the "save this password?" question is skipped
altogether while the vault is unreadable.

Fixed: uninstalling left `SHA256SUMS.txt` and `uninstall.cmd` behind, so the program folder
could never be removed. The hash list is deleted with the other package files and the batch
launcher is removed by the delayed helper (cmd.exe is still reading it). A folder shared
with another 7-Zip still keeps every file of theirs: same name with a different hash, or
not listed in the manifest at all.

The test suite now reads the password box through the dialog helper (Windows refuses to
read an `ES_PASSWORD` edit from another process), so the value a fill really delivers is
proven by the saved-passwords list and by an archive that only opens with the right
password; the failure dump is capped; leftover test instances are cleaned up so they cannot
lock the freshly built `7zFM.exe`; the uninstall test exercises the hash-list branch and a
shared folder; the label checker measures wrapped text instead of reporting auto-wrapped
message boxes; and the deploy script refuses to build a package while a vault file sits in
the output folder.
