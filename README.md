# 7-Zip 密码管家版（7-Zip Password Vault）

基于官方 **7-Zip 26.03 源码**，内置「本地加密密码管理」功能的修改版。

密码管理功能直接集成进 7-Zip 自己的「输入密码」对话框，解压加密压缩包时无需再打开任何额外程序。

## 功能

1. **本地存储密码** —— 在密码对话框里点 `Save...` 保存，密码写入 `%APPDATA%\7-Zip\7zPasswordVault.dat`。
2. **加密存储** —— 使用 Windows DPAPI（`CryptProtectData`）加密后落盘，明文密码不写磁盘，密文绑定「当前 Windows 账户 + 当前电脑」。
3. **解压时一键填入** —— 密码对话框新增 `Saved passwords` 下拉框，选中即自动填入密码输入框。
4. **密码命名** —— 保存时可给密码命名，下拉框按名称快速查找。

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
