# 7-Zip Password Vault / 7-Zip 密码管家版

A modified build of **7-Zip 26.03** with an integrated, encrypted, named password vault — built directly into 7-Zip's own password dialog.

基于官方 **7-Zip 26.03 源码** 的修改版，内置「本地加密密码管理」功能，直接集成进 7-Zip 的「输入密码」对话框。

---

## English

### Features

1. **Local password storage** — save a password with a name right from 7-Zip's password dialog.
2. **Hybrid encryption** (choose in Settings):
   - **DPAPI (default)** — tied to your Windows account + machine, no master password needed.
   - **AES-256-GCM + master password (optional)** — portable; move/backup the vault to another machine.
3. **One-click fill** — a "Saved passwords" dropdown in the password dialog fills the password automatically.
4. **Password naming** — name each password for quick lookup.
5. **Password management settings page** — 7-Zip "Tools → Options" gains a new "Password" page.
6. **Localized UI** — new buttons/options are localized (English / 简体中文 / 繁體中文 included).

### Settings page (Tools → Options → Password)

| Option | Meaning |
|--------|---------|
| Vault path (empty = default) | Custom vault file location (default `%APPDATA%\7-Zip\7zPasswordVault.dat`) |
| Use master password (portable) | Encrypt the vault with AES-256-GCM + master password |
| Set master password... | Set / change the master password (entered twice) |
| Remember master password this session | Ask for the master password only once per run |
| Auto-fill the only matching password | Auto-fill when exactly one password is saved |
| Show password by default | Show the password in clear text by default |

### Build

MinGW-w64 (GCC):

```bat
cd CPP\7zip\UI\GUI
make -f ../../cmpl_gcc.mak
cd ..\FileManager
make -f ../../cmpl_gcc.mak
```

Outputs are in `b\g\`. Run them next to the official `7z.dll` and `Lang\` folder.

MSVC (nmake): use `GUI\makefile` and `FileManager\makefile` (already link `crypt32.lib` + `bcrypt.lib`).

### Security

- DPAPI mode: decryptable only by the current Windows account on the current machine.
- Master-password mode: AES-256-GCM with a key derived via PBKDF2-HMAC-SHA256 (Windows CNG/bcrypt).
- Vault file: `%APPDATA%\7-Zip\7zPasswordVault.dat` (configurable).

### License

Based on 7-Zip source, under its original license (GNU LGPL, except unRar). See `DOC\License.txt` and `DOC\copying.txt`.

---

## 中文

### 功能

1. **本地存储密码** —— 在密码对话框里点 `保存...` 保存，密码写入本地密码库文件。
2. **加密存储（混合方案）**：
   - **DPAPI（默认）**：Windows 账户 + 电脑绑定，免主密码。
   - **AES-256-GCM + 主密码（可选）**：可移植，可备份/迁移。
3. **解压时一键填入** —— 密码对话框新增「已保存的密码」下拉框，选中即自动填入。
4. **密码命名** —— 保存时给密码命名，下拉框按名称快速查找。
5. **密码管理设置页** —— 7-Zip「工具 → 选项」新增「密码管理」页。
6. **多语言** —— 新增界面已本地化（英文 / 简体中文 / 繁体中文）。

### 密码管理设置页（工具 → 选项 → 密码管理）

| 选项 | 说明 |
|------|------|
| 密码库位置（留空使用默认） | 自定义密码库文件存放路径（默认 `%APPDATA%\7-Zip\7zPasswordVault.dat`） |
| 使用主密码加密（可移植） | 开启后用 AES-256-GCM + 主密码加密，可迁移到其它电脑 |
| 设置主密码... | 设置 / 修改主密码（输入两次） |
| 本次会话记住主密码 | 开启后本次运行只输入一次主密码 |
| 自动填入唯一匹配的密码 | 只有一条已存密码时，打开密码框自动填入 |
| 默认显示密码 | 密码框默认显示明文 |

### 构建

MinGW-w64（GCC）：

```bat
cd CPP\7zip\UI\GUI
make -f ../../cmpl_gcc.mak
cd ..\FileManager
make -f ../../cmpl_gcc.mak
```

产物在各自目录 `b\g\` 下。运行需同目录的官方 `7z.dll` 与 `Lang\`（可从官方 7-Zip 26.03 安装包获取，或本仓库外 `7-Zip-密码管家版\` 目录）。

MSVC（nmake）：使用 `GUI\makefile` 与 `FileManager\makefile`（已链接 `crypt32.lib` + `bcrypt.lib`）。

### 改动文件

| 文件 | 说明 |
|------|------|
| `CPP/7zip/UI/FileManager/PasswordVault.h` / `.cpp` | 新增：DPAPI + AES-256-GCM 混合加密、密码库存储 |
| `CPP/7zip/UI/FileManager/PasswordDialog.h` / `.cpp` / `.rc` / `PasswordDialogRes.h` | 修改：密码对话框加下拉选择、保存、删除、命名、主密码对话框 |
| `CPP/7zip/UI/FileManager/PasswordPage.h` / `.cpp` / `.rc` / `PasswordPageRes.h` | 新增：密码管理设置页 |
| `CPP/7zip/UI/FileManager/OptionsDialog.cpp` | 修改：注册密码管理设置页 |
| `CPP/7zip/UI/Common/ZipRegistry.h` / `.cpp` | 修改：新增密码库设置读写 |
| `CPP/7zip/UI/GUI/UpdateCallbackGUI2.cpp` | 修改：右键解压路径也遵循「默认显示密码」 |
| `CPP/7zip/UI/GUI/makefile` / `makefile.gcc` | 修改：GUI 构建文件（链接 bcrypt） |
| `CPP/7zip/UI/FileManager/FM.mak` / `makefile.gcc` | 修改：FM 构建文件（链接 bcrypt） |
| `CPP/7zip/7zip_gcc.mak` | 修改：新增编译规则、链接 bcrypt、**头文件依赖跟踪（-MMD -MP）** |
| `Lang/en.ttt` / `zh-cn.txt` / `zh-tw.txt` | 修改：新增界面字符串本地化 |

### 开发注意（重要）

7-Zip 自带的 GCC makefile **不跟踪头文件依赖**。修改任何 `.h` 后如果只做增量编译，
包含该头文件的其他 `.cpp` 不会重新编译，会造成**类布局不一致**（不同目标文件对同一成员的
偏移量理解不同），从而出现内存踩踏 / 崩溃。

本仓库已在 `7zip_gcc.mak` 中加入 `-MMD -MP` 与 `-include $(OBJS:.o=.d)` 自动跟踪头文件依赖。
若在旧版构建脚本上开发，**改过头文件后请务必全量重编**：

```bat
del /q CPP\7zip\UI\GUI\b\g\*.o CPP\7zip\UI\FileManager\b\g\*.o
make -f ../../cmpl_gcc.mak
```

### 健壮性设计

- 密码库采用**临时文件 + 原子替换**写入，写入过程中崩溃/断电不会损坏已有密码库。
- 读取时会校验条数、名称长度、密文长度与 PBKDF2 迭代次数，避免损坏文件导致巨额内存分配或长时间卡死。
- 主密码、派生密钥、明文缓冲在使用后会被**主动清零**。

### 安全说明

- DPAPI 模式：仅当前 Windows 账户在当前电脑上可解密。
- 主密码模式：AES-256-GCM，密钥由 PBKDF2-HMAC-SHA256 派生（Windows CNG/bcrypt）。
- 密码库文件：`%APPDATA%\7-Zip\7zPasswordVault.dat`（可自定义）。

### 许可

本修改基于 7-Zip 源码，遵循其原有许可（GNU LGPL，unRar 部分除外）。详见 `DOC\License.txt` 与 `DOC\copying.txt`。
