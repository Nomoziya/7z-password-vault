# 7-Zip 密码管家版（7-Zip Password Vault）

基于官方 **7-Zip 26.03 源码**，内置「本地加密密码管理」功能的修改版。

密码管理功能直接集成进 7-Zip 自己的「输入密码」对话框，解压加密压缩包时无需再打开任何额外程序。

## 功能

1. **本地存储密码** —— 在密码对话框里点 `保存...` 保存，密码写入本地密码库文件。
2. **加密存储（混合方案）** —— 两种加密方式可选（见下）：
   - **DPAPI（默认）**：Windows 账户 + 电脑绑定，免主密码。
   - **AES-256-GCM + 主密码（可选）**：可移植，可备份/迁移。
3. **解压时一键填入** —— 密码对话框新增「已保存的密码」下拉框，选中即自动填入。
4. **密码命名** —— 保存时给密码命名，下拉框按名称快速查找。
5. **密码管理设置页** —— 7-Zip「工具 → 选项」新增「密码管理」页（见下）。
6. **全中文界面** —— 新增的按钮、选项、弹窗均已翻译为中文。

### 密码管理设置页（工具 → 选项 → 密码管理）

| 选项 | 说明 |
|------|------|
| 密码库位置 | 自定义密码库文件存放路径（留空 = 默认 `%APPDATA%\7-Zip\7zPasswordVault.dat`） |
| 使用主密码加密（可移植） | 开启后用 AES-256-GCM + 主密码加密，可迁移到其它电脑 |
| 设置主密码... | 设置 / 修改主密码（输入两次） |
| 本次会话记住主密码 | 开启后本次运行只输入一次主密码 |
| 自动填入唯一匹配的密码 | 只有一条已存密码时，打开密码框自动填入 |
| 默认显示密码 | 密码框默认显示明文 |

密码对话框新增控件：

```
输入密码：
  [密码输入框]
  Saved passwords: [下拉框]   ← 已存密码选择
  [Save...]  [Delete]          ← 保存(命名)/删除
  显示密码  确定  取消
```

## 构建

### MinGW-w64（GCC）

1. 安装 MinGW-w64（含 `gcc`/`g++`/`windres`/`make`）。
2. 编译 `7zG.exe`（右键解压模块）：

   ```bat
   cd CPP\7zip\UI\GUI
   make -f ../../cmpl_gcc.mak
   ```

3. 编译 `7zFM.exe`（文件管理器）：

   ```bat
   cd CPP\7zip\UI\FileManager
   make -f ../../cmpl_gcc.mak
   ```

   产物在各自目录的 `b\g\` 下。运行需要同目录的官方 `7z.dll` 与 `Lang\`（可从官方 7-Zip 26.03 安装包获取，或本仓库外的 `7-Zip-密码管家版\` 目录）。

### MSVC（Visual Studio）

在对应目录用 `nmake`：

```bat
cd CPP\7zip\UI\GUI
nmake -f makefile
cd ..\FileManager
nmake -f makefile
```

`GUI\makefile` 与 `FileManager\makefile` 已加入 `PasswordVault.obj` 并链接 `crypt32.lib`。

## 改动文件

| 文件 | 说明 |
|------|------|
| `CPP/7zip/UI/FileManager/PasswordVault.h` / `.cpp` | 新增：DPAPI 加密 + 二进制密码库存储 |
| `CPP/7zip/UI/FileManager/PasswordDialog.h` / `.cpp` / `.rc` / `PasswordDialogRes.h` | 修改：密码对话框加下拉选择、保存、删除、命名对话框 |
| `CPP/7zip/UI/GUI/makefile` / `makefile.gcc` | 修改/新增：GUI 构建文件 |
| `CPP/7zip/UI/FileManager/FM.mak` / `makefile.gcc` | 修改/新增：FM 构建文件 |
| `CPP/7zip/7zip_gcc.mak` | 修改：新增 PasswordVault 编译规则 |

## 安全说明

- 密码用 DPAPI 加密，仅当前 Windows 账户在当前电脑上可解密。
- 密码库文件：`%APPDATA%\7-Zip\7zPasswordVault.dat`。
- 换用户 / 换电脑后无法解密（安全特性，非 bug）。

## 许可

本修改基于 7-Zip 源码，遵循其原有许可（GNU LGPL，unRar 部分除外）。详见 `DOC\License.txt` 与 `DOC\copying.txt`。
