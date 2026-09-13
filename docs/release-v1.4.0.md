## 更新内容 / Changes

### 新增 / New
- **未命名条目可以直接显示密码**（可选）：没起名字的条目在名称列是空的，很难辨认。
  打开「工具 → 选项 → 密码管理 → 未命名条目直接显示密码」后，**只有这些条目**在列表中
  直接显示密码，有名称的条目仍然打码（`********`）。
  设了主密码的密码库必须先解锁成功，列表里才会有内容，未解锁时不会显示任何密码。
- 设置页因此多了一个开关，四种语言（英 / 简 / 繁 / 模板）同步更新，英文界面无截断。

### 测试 / Tests
- **中文密码测试**：中文名称 + 中文密码（`密码测试-äöü-123`）走完整条链路 —— 存入密码库、
  填入输入框、列表显示、按行填入，最后用密码库里的密码**真的解开并解压**一个加密压缩包；
  同时直接检查密码库文件里**不存在**该名称与密码的 UTF-8 / UTF-16 / ANSI 明文。
- **密码库搬迁测试**：主密码模式建库 → 把 `.dat` 复制到另一个路径（模拟换电脑 / 从备份恢复）
  → 用主密码单独解锁副本 → 条目都在且能正确填入；再通过设置页的**导出 / 导入**把密码库
  导入到一个全新的路径，并校验副本与导入结果里都没有明文。
- UI 测试累计 **264 项**全部通过（`tests\ui-test.ps1`），引擎测试 39 项，英文界面 0 处标签截断。

### 修复 / Fixes
- 测试本身的三处兼容问题（本机文件对话框有三种：7-Zip 自带、系统新式、系统经典，
  文件名输入框分别是 102 / 1001 / 1148；消息框必须用真实鼠标点击关闭，
  因为它在非活动窗口时 `BM_CLICK` 会被忽略，且本机消息框按钮 id 不是 1 而是 2）。

This release adds one option: unnamed entries (saved without a name) can show their password in
the saved-passwords window, so they can be found again, while named rows stay masked. A
master-password vault shows nothing until it has been unlocked.

The test suite grew from 205 to 264 checks: Chinese names and passwords are verified end to end
(including that the vault file holds no plaintext in UTF-8, UTF-16 or ANSI), and the vault is now
tested for portability — copy the file elsewhere, unlock it with the master password alone, and
export/import it through the settings page.

构建方式 / Build: MinGW-w64 GCC 16.2.0 (msvcrt flavour), see `BUILD.md`.
二进制哈希 / SHA-256: `7zFM.exe` `ab1326c711dc6ecc23daebc004cd88954639e3feec3c77ef678d3e6b018697fe`,
`7zG.exe` `0a09c42224ff25db96a6b962c765d98e1c526a8b39d0496c2de71df362509d18`.
