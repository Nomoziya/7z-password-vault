## 修复 / Fixed

- **卸载不再连带清掉官方 7-Zip 的设置**：`HKCU\Software\7-Zip` 是与 7-Zip 自身共用的键（语言、面板布局、
  路径、解压设置）。以前的卸载程序把整棵键删掉，因此旁边装了官方 7-Zip 的用户在卸载本包后，**官方 7-Zip 的
  每用户设置会被一起重置**。现在只删 `HKCU\Software\7-Zip\PasswordVault`——本包写入的一切都在这个子键里
  （密码库位置、开关、首次启动「已经问过」的标记），其余部分原样保留。密码库设置键仍会在删除前导出备份，
  并在结尾打印 `reg import` 恢复命令。
- 回归覆盖：`tests\uninstall-test.ps1` **28/28**（新增「属于上游 7-Zip 的值必须存活」这条），
  `tests\install-acceptance.ps1` **68/0**（同样的断言，跑在重新打包后的产物上）。

## 内容 / Contents

- 唯一发布的下载仍是便携版 zip：`7z-password-vault-26.03-win64-portable.zip`
  （本次 `2b8ac1cade4f57a076ae7e955fcd89cb058fc7fd1667a8c3f44d595964335ac4`，3,005,677 字节）。
- 两个可执行文件与 v1.4.4 相同（`7zFM.exe` `a24e93c6…`、`7zG.exe` `60587682…`），**因此不需要重新提交微软误报**——
  这正是可复现构建 + 冻结二进制的意义：只改脚本时哈希不变。

## 为什么单独发一版 / Why a new release

v1.4.4 的产物里带的是旧卸载程序。已发布的资产不替换（哈希已经公开），需要这个修复的用户请用本版。

VirusTotal（2026-09-14）：`portable.zip` **0/67**，`7zG.exe` **0/65**，`7zFM.exe` 1/69（微软 `Wacatac.B!ml`
的 ML 误报，持久解法是代码签名；提交内容已备好在 `docs/vt-false-positive-report.md`）。
