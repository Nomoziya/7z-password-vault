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
3. **Saved-passwords window** — a 3 column table (`Name | Password | Delete`):
   - **single click** on the Name or Password cell types that password into the input box;
   - **double click** (or **right click**, per the setting) opens the edit dialog;
   - **click Delete** removes the row after a confirmation prompt;
   - the password column shows `********` unless you ask to see the passwords: the
     **Show passwords** checkbox in the window reveals them, and pressing a masked cell
     still fills the real password into the input box.
4. **New password window** — name + password; the name may be left empty and a unique one is generated.
5. **Auto-type by name** — typing the name of a saved entry in the password box fills its password.
6. **Offer to save** — entering a password that is not stored yet asks whether to save it.
7. **Password management settings page** — 7-Zip "Tools → Options" gains a new "Password manager" page.
8. **Localized UI** — every new dialog and option is localized (English / 简体中文 / 繁體中文 included).

> The file manager loads its language file as `Lang\<lang>.txt` and never `.ttt`, so an English
> UI needs `Lang\en.txt` (a copy of the `en.ttt` template, which this repository ships). Without
> it, English falls back to the built-in resource strings and every string that only exists in the
> language file — the vault message boxes, list hint, prompts — would show its Chinese fallback.

### Saved-passwords window

Open it with the **Saved passwords...** button in the password dialog. It stays open while you pick,
so you can compare several entries; the hint line shows which entry was filled.

| Action | Result |
|--------|--------|
| Click the **Name** or **Password** cell | That entry's password is typed into the input box (the window stays open) |
| Double click a row | Opens the **Edit password** window (default) |
| Right click a row | Opens the **Edit password** window (only when the setting is enabled) |
| Click **Delete** | Asks for confirmation, then deletes that entry |
| Click **New password...** | Opens the new-entry window (name optional, empty name = generated name) |
| Click **Close** | Closes the window; the input box keeps whatever was filled |

### Settings page (Tools → Options → Password manager)

| Option | Meaning |
|--------|---------|
| Vault path (empty = default) | Custom vault file location (default `%APPDATA%\7-Zip\7zPasswordVault.dat`) |
| Browse... | Pick the vault file location |
| Use master password (portable) | Encrypt the vault with AES-256-GCM + master password |
| Set master password... | Set / change the master password (entered twice) |
| Clear master password... | Re-encrypt with DPAPI (removes the master password requirement) |
| Remember master password this session | Ask for the master password only once per run |
| Auto-lock the master password after 5 idle minutes | Forget the cached master password after 5 minutes |
| Show password by default | Show the password in clear text by default |
| Edit saved passwords with the right mouse button | Right click edits instead of double click |
| Auto-fill the password when a saved name is typed | Turn off to be asked before filling |
| Offer to save an unsaved password | Turn off to never be asked to store a new password |
| Show the saved passwords in the list (otherwise dots) | Reveal the password column by default; the list window also has its own **Show passwords** checkbox |
| Export vault... / Import vault... | Copy the vault to/from another file |

### Build

MinGW-w64 (GCC):

```bat
cd CPP\7zip\UI\GUI
make -f ../../cmpl_gcc.mak
cd ..\FileManager
make -f ../../cmpl_gcc.mak
```

Outputs are in `b\g\`. The object directory (`b\g`) must exist first — the makefile's `mkdir`
rule only works inside an MSYS shell:

```bat
mkdir CPP\7zip\UI\GUI\b\g 2>nul
mkdir CPP\7zip\UI\FileManager\b\g 2>nul
```

Run the executables next to the official `7z.dll` and `Lang\` folder.

MSVC (nmake): use `GUI\makefile` and `FileManager\makefile` (already link `crypt32.lib` + `bcrypt.lib`).

### Tests

`tests\ui-test.ps1` drives the real dialogs of the built `7zFM.exe` through Win32 messages and
real mouse input (no test framework needed):

```powershell
pwsh -NoProfile -File tests\ui-test.ps1
pwsh -NoProfile -File tests\ui-test.ps1 -SevenZipDir "D:\path\to\7-Zip"
pwsh -NoProfile -File tests\ui-test.ps1 -UiLang en      # against the English UI
```

It covers the vault round-trip, the saved-passwords window (pick / edit / delete), auto-typing,
the save prompt, the generated name, the settings page and a set of corrupt-vault files. It exits
non-zero when a check fails.

* The run is **isolated from your own data**: it points `VaultPath` at a file inside its work
  directory and restores the whole `HKCU\Software\7-Zip\PasswordVault` key afterwards, also when
  it crashes. Your real vault in `%APPDATA%\7-Zip` is never read or written.
* It clicks and types with the **real mouse and keyboard**, so the cursor is taken over for the
  duration of the run.
* Dialog titles come from the language files, so the suite runs against any language this
  repository ships: `-UiLang auto` (default) follows the 7-Zip `Lang` setting and the system UI
  language; `-UiLang en` or `-UiLang zh-cn` force one. When a window is not found the run prints
  the titles it did find, to make a language mismatch obvious.
* It stops only the `7zFM.exe` it started, so a file manager you have open is not killed.

### Security

- DPAPI mode: decryptable only by the current Windows account on the current machine. Entry names
  are encrypted as well as the passwords.
- Master-password mode: AES-256-GCM with a key derived via PBKDF2-HMAC-SHA256 (Windows CNG/bcrypt),
  per-vault random salt and nonce.
- The vault is written through a temporary file and an atomic replace, so an interrupted write
  cannot destroy an existing vault.
- Master password, derived keys and plaintext buffers are wiped from memory after use.

### License

Based on 7-Zip source, under its original license (GNU LGPL, except unRar). See `DOC\License.txt` and `DOC\copying.txt`.

---

## 中文

### 功能

1. **本地存储密码** —— 在密码对话框里点「新建密码...」保存，密码写入本地加密密码库文件。
2. **加密存储（混合方案）**：
   - **DPAPI（默认）**：Windows 账户 + 电脑绑定，免主密码；**名称与密码都加密**。
   - **AES-256-GCM + 主密码（可选）**：可移植，可备份/迁移到其它电脑。
3. **已保存的密码窗口** —— 三列表格（`名称 | 密码 | 删除`）：
   - **单击**名称或密码单元格 → 直接键入到输入框；
   - **双击**（或在设置里改成**右键**）→ 打开修改窗口；
   - **单击「删除」** → 二次确认后删除该行；
   - 密码列默认显示为 `********`；窗口里的**「显示密码」**复选框可临时显示明文，
     单击被遮挡的单元格仍然会把真实密码填入输入框。
4. **新建密码窗口** —— 填写名称 + 密码；**名称可以留空**，会自动生成一个不重复的名称。
5. **按名称自动键入** —— 在密码框里输入已保存的名称，自动填入该名称下的密码。
6. **提示保存** —— 输入密码库里没有的密码时，弹窗询问是否保存到密码库。
7. **密码管理设置页** —— 7-Zip「工具 → 选项」新增「密码管理」页。
8. **多语言** —— 新增对话框与选项均已本地化（英文 / 简体中文 / 繁体中文）。

> 文件管理器只加载 `Lang\<语言>.txt`，**不会加载 `.ttt`**。因此英文界面需要 `Lang\en.txt`
> （即 `en.ttt` 模板的副本，本仓库已提供）。缺少它时英文会退回内置资源字符串，而只存在于
> 语言文件里的字符串（密码库消息框、列表提示、各种询问）会退回中文兜底文本。

### 已保存的密码窗口

在密码对话框里点「已保存的密码...」打开。窗口**不会因为填入而关闭**，方便对比多条记录；
提示行会显示刚刚填入了哪一条。

| 操作 | 结果 |
|------|------|
| 单击**名称**或**密码**单元格 | 该条密码键入到输入框（窗口保持打开） |
| 双击某一行 | 打开「修改密码」窗口（默认） |
| 右键某一行 | 打开「修改密码」窗口（需在设置中开启） |
| 单击**删除** | 二次确认后删除该条 |
| 单击**新建密码...** | 打开新建窗口（名称可留空，留空则自动命名） |
| 单击**关闭** | 关闭窗口，输入框中已填入的内容保留 |

### 密码管理设置页（工具 → 选项 → 密码管理）

| 选项 | 说明 |
|------|------|
| 密码库位置（留空使用默认） | 自定义密码库文件存放路径（默认 `%APPDATA%\7-Zip\7zPasswordVault.dat`） |
| 浏览... | 选择密码库文件位置 |
| 使用主密码加密（可移植） | 开启后用 AES-256-GCM + 主密码加密，可迁移到其它电脑 |
| 设置主密码... | 设置 / 修改主密码（输入两次） |
| 清除主密码... | 改回 DPAPI 加密（不再需要主密码） |
| 本次会话记住主密码 | 开启后本次运行只输入一次主密码 |
| 主密码闲置 5 分钟后自动锁定 | 闲置 5 分钟后清除内存中缓存的主密码 |
| 默认显示密码 | 密码框默认显示明文 |
| 使用右键编辑已存密码（否则为双击） | 用右键代替双击来修改 |
| 输入已保存的名称时自动填入密码 | 关闭后改为先询问再填入 |
| 输入未保存的密码时提示保存 | 关闭后不再询问是否保存新密码 |
| 在列表中显示已保存的密码（否则显示为圆点） | 默认在列表中显示明文；列表窗口里也有自己的「显示密码」复选框 |
| 导出密码库... / 导入密码库... | 把密码库复制到 / 从其它文件导入 |

### 构建

MinGW-w64（GCC）：

```bat
cd CPP\7zip\UI\GUI
make -f ../../cmpl_gcc.mak
cd ..\FileManager
make -f ../../cmpl_gcc.mak
```

产物在各自目录 `b\g\` 下。**首次构建需先手动创建对象目录**——makefile 里的 `mkdir` 规则
只在 MSYS 环境下可用：

```bat
mkdir CPP\7zip\UI\GUI\b\g 2>nul
mkdir CPP\7zip\UI\FileManager\b\g 2>nul
```

运行需同目录的官方 `7z.dll` 与 `Lang\`（可从官方 7-Zip 26.03 安装包获取）。

MSVC（nmake）：使用 `GUI\makefile` 与 `FileManager\makefile`（已链接 `crypt32.lib` + `bcrypt.lib`）。

### 测试

`tests\ui-test.ps1` 通过 Win32 消息与真实鼠标输入驱动构建出的 `7zFM.exe` 真实对话框，
不需要任何测试框架：

```powershell
pwsh -NoProfile -File tests\ui-test.ps1
pwsh -NoProfile -File tests\ui-test.ps1 -SevenZipDir "D:\path\to\7-Zip"
pwsh -NoProfile -File tests\ui-test.ps1 -UiLang en      # against the English UI
```

覆盖：密码库往返、已保存密码窗口（填入 / 修改 / 删除）、自动键入、保存提示、自动命名、
设置页、以及一组损坏的密码库文件（必须报错且不崩溃）。有失败项时以非零码退出。

* 测试与**你自己的数据完全隔离**：它把 `VaultPath` 指向自己工作目录下的文件，并在结束后
  （即使中途崩溃）整体恢复 `HKCU\Software\7-Zip\PasswordVault` 键。`%APPDATA%\7-Zip`
  下的真实密码库不会被读取或写入。
* 测试使用**真实鼠标与键盘**输入，运行期间会占用光标。
* 窗口标题来自语言文件，支持本仓库提供的所有语言：`-UiLang auto`（默认）跟随 7-Zip 的
  `Lang` 设置与系统界面语言，`-UiLang en` / `-UiLang zh-cn` 可强制指定；找不到窗口时会打印
  实际存在的窗口标题，便于判断是否为语言不匹配。
* 只关闭测试自己启动的 `7zFM.exe`，不会影响你已经打开的窗口。

### 改动文件

| 文件 | 说明 |
|------|------|
| `CPP/7zip/UI/FileManager/PasswordVault.h` / `.cpp` | 新增：DPAPI + AES-256-GCM 混合加密、密码库存储、主密码对话框 |
| `CPP/7zip/UI/FileManager/PasswordListDialog.h` / `.cpp` | 新增：三列「已保存的密码」窗口（填入 / 修改 / 删除） |
| `CPP/7zip/UI/FileManager/PasswordDialog.h` / `.cpp` / `.rc` / `PasswordDialogRes.h` | 修改：密码对话框改为「已保存的密码... / 新建密码...」按钮，新增新建/修改窗口、按名称自动键入、保存提示 |
| `CPP/7zip/UI/FileManager/PasswordPage.h` / `.cpp` / `.rc` / `PasswordPageRes.h` | 新增：密码管理设置页（含导出/导入、清除主密码） |
| `CPP/7zip/UI/FileManager/OptionsDialog.cpp` | 修改：注册密码管理设置页 |
| `CPP/7zip/UI/Common/ZipRegistry.h` / `.cpp` | 修改：新增密码库设置读写 |
| `CPP/7zip/UI/GUI/UpdateCallbackGUI2.cpp` | 修改：右键解压路径也遵循「默认显示密码」 |
| `CPP/7zip/UI/GUI/makefile` / `makefile.gcc` | 修改：GUI 构建文件（链接 bcrypt） |
| `CPP/7zip/UI/FileManager/FM.mak` / `makefile.gcc` | 修改：FM 构建文件（链接 bcrypt） |
| `CPP/7zip/7zip_gcc.mak` | 修改：新增编译规则、链接 bcrypt、**头文件依赖跟踪（-MMD -MP）** |
| `Lang/en.ttt` / `en.txt` / `zh-cn.txt` / `zh-tw.txt` | 修改：新增界面字符串本地化（`en.txt` 为英文界面实际加载的文件） |
| `tests/ui-test.ps1` | 新增：UI 冒烟测试 |

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
