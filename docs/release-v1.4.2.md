## 更新内容 / Changes

### 新增 / New
- **两个发布包**：
  - `7z-password-vault-26.03-win64-setup.exe` —— **安装版**：先选安装目录（默认
    `D:\7-Zip Password Vault\`），解包后创建开始菜单 / 桌面快捷方式，并把自己登记到
    「应用和功能」（当前用户，无需管理员）。卸载从那里点，或运行程序目录里的 `uninstall.cmd`。
  - `7z-password-vault-26.03-win64-portable.zip` —— **便携版**：解压即用。
- **卸载程序** `uninstall.cmd`（两版都带）：先问是否保留密码库，再确认；删除进程、注册表、
  指向该目录的关联与右键菜单扩展、快捷方式、「应用和功能」条目和整个程序目录。
  删设置键前会导出备份到 `%TEMP%\7zip-vault-settings-<日期>.reg`，结尾打印恢复命令。
  `-KeepVault` / `-DeleteVault` / `-AllUsers` / `-WhatIf` / `-NoBackup` 可选。

### 变更 / Changed
- **密码库默认存放在程序所在文件夹**（`<程序目录>\7zPasswordVault.dat`），**不再默认占用 C 盘**。
  若程序目录不可写（例如装在 `Program Files`），自动退回 `%APPDATA%\7-Zip\7zPasswordVault.dat`；
  升级后首次运行时，仍留在旧位置的密码库会被**移动**到程序目录，并弹出提示告诉新位置。
  用户手动指定过位置时永远不动。
- 安装版与便携版都**不自动关联文件格式**：装完在「工具 → 选项 → 系统」里勾选 `7z`、`zip` 等
  即可恢复关联与图标。

### 修复 / Fixed
- **密码库位置可以填文件夹**：以前填文件夹后点确定会报「无法替换密码库文件」（程序把密码库
  重命名到一个已存在的目录上）。现在文件夹被识别为「密码库放在这个文件夹里」，实际使用
  `<文件夹>\7zPasswordVault.dat`；带引号的路径同样可用，应用后输入框显示真正使用的文件路径。
- **「浏览...」选完文件夹后点确定没反应**：程序内部用 `SetText` 写路径不会产生 `EN_CHANGE`，
  而设置页靠它启用「应用」。现在「浏览」也会触发变更。
- 换位置失败的报错现在带上完整路径与 Windows 的错误原因。

### 测试 / Tests
- `tests\ui-test.ps1` 精简与加固：新增 `New-VaultEntry` / `Open-PasswordPage` /
  `Apply-PasswordPage` / `Wait-PasswordText` 等公共步骤，15 处重复的新建条目代码各压成一行。
- 新增**环境自检**：若有**另一份 7zFM/7zG 正在运行**（例如你自己那份），测试会拒绝运行并指出
  进程号 —— 两个实例共用注册表设置，会互相覆盖密码库文件，造成看似随机的失败（本次排查中
  确实发生过，32 项假失败）。要强行跑可加 `-AllowOtherInstances`。
- 新增 `tests\uninstall-test.ps1`（20 项）：在 `%TEMP%` 造假安装目录验证卸载逻辑，
  并自行备份/还原真实注册表与真实密码库。

Every release now ships two builds: an installer (`...-setup.exe` — folder chooser, Start
Menu / Desktop shortcuts, an entry in *Apps & features*, uninstaller included) and a
portable zip. The vault file is no longer kept on the system drive by default: it lives
next to the program, with `%APPDATA%\7-Zip` only as a fallback when the program folder
cannot be written, and an older vault left there is moved on the first run.

Fixed: the vault location field accepts a folder again (it used to fail with "cannot
replace the vault file", because the vault was renamed onto an existing directory), a
quoted path works, and picking a folder with **Browse** followed by OK now applies
(SetText does not raise EN_CHANGE, which is what enables Apply).

The test suite was condensed with shared helpers and gained an environment check: if
another 7zFM/7zG is running it refuses to start, because two instances share the vault
settings and overwrite each other's vault file — exactly what produced an earlier run of
32 puzzling failures (override with `-AllowOtherInstances`).

构建方式 / Build: MinGW-w64 GCC 16.2.0 (msvcrt flavour), see `BUILD.md`.
二进制哈希 / SHA-256: `7zFM.exe` `0eb4749a60d16c58d49475d7d30f798984e1ca414ca2dfd2c74d63e6ce2f0a85`,
`7zG.exe` `a22ec2f111108d908d29de5c253cfd674db047c3ef69dfe8200f3fa9a4596022`.
