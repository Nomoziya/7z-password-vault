## 更新内容 / Changes

### 修复 / Fixed
- **英文界面不再出现中文**：设置页里原来还有约 15 条写死的中文（导出 / 导入的文件对话框标题、
  `密码库已导出…`、`导入完成：新增 n 条…`、清除主密码的询问等），密码库核心的**全部错误提示**
  （27 处）也是写死的中文。现在这些文本全部走 `Lang\*.txt`（新增 id 3834–3860），
  代码里只保留中文作为语言文件缺失时的兜底。
- 带数字或路径的两条消息改用 `{0}` / `{1}` 占位符 —— 不同语言的语序不同，不能在代码里拼接。

### 测试 / Tests
- `tests\ui-test.ps1` 的 `-UiLang en` 原来只切换**期望的窗口标题**，并没有把程序切成英文，
  所以英文模式其实一直在跑中文界面。现在它会像 `check-labels.ps1` 一样临时设置
  `HKCU\Software\7-Zip\Lang`，结束后恢复原值。
- 新增两项检查：英文运行时，密码库的消息框里不允许出现任何中文（这正是本次修复的回归测试）。
- UI 测试 **266 项**全部通过（中文），其中 63 项在英文界面下同样通过；引擎测试 39 项；
  英文界面 0 处标签截断。

Every vault string now comes from the language files: the export and import file
dialogs, their message boxes, the "vault moved" question and all 27 error messages of
the vault core. The code keeps the Chinese text only as the built-in fallback, and the
two messages that embed a count or a path use `{0}` / `{1}` markers because the word
order differs between languages. An English UI no longer shows Chinese anywhere.

The test harness had a matching bug: `-UiLang en` only selected the expected window
titles and never switched the application, so the English run was really testing the
Chinese UI. It now sets `HKCU\Software\7-Zip\Lang` for the run and restores it
afterwards, and two new checks fail if a vault message box contains Chinese in an
English run.

构建方式 / Build: MinGW-w64 GCC 16.2.0 (msvcrt flavour), see `BUILD.md`.
二进制哈希 / SHA-256: `7zFM.exe` `cc60c3193f5c9ebabb9eaf31359723abffd4bd13bb360eacb3a1b99171337f92`,
`7zG.exe` `79763b2ca024b7f53ea820d588662a021f6680dcf18ed1a5a1dd67633a092bb1`.
导入表与 v1.4.0 完全一致（`7zFM` 14 个 DLL、`7zG` 13 个，0 个网络符号，0 个 `api-ms-win-crt-*`）。
