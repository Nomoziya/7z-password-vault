## 重点：安装版不再是「假安装」，报毒也更少 / Installer fixed, detections down

### 修复 / Fixed
- **安装版以前根本不会安装**：官方 `7z.sfx` 存根**不解析** SFX 配置（实测：`RunProgram` 不执行、
  `InstallPath` 被忽略，存根里也没有 `@Install@`/`RunProgram` 字符串），所以 v1.4.2/v1.4.3 的
  `setup.exe` 只是「解压到你选的文件夹」，快捷方式与「应用和功能」条目都**没有**创建——发布说明写了
  但做不到。现在：
  - `setup.exe` 如实描述为**自解压包**（解包 + 可选的手动 `install.cmd`）；
  - 快捷方式与「应用和功能」登记改由**程序自己**在**首次启动**时询问后完成（`SetupShortcuts.cpp`）：
    `IShellLink` 建 `.lnk`、只写 `HKCU`，不调用 `cmd`/`powershell`/WSH，不需要管理员权限，
    选「否」也照常使用且不再询问（`HKCU\Software\7-Zip\PasswordVault\SetupAsked`）；
  - 从临时目录运行的副本不会提议登记（避免指向会被系统删掉的路径）；
  - 手动运行 `install.cmd` 时也会写好 `SetupAsked`，不会再被问一次。
- **载荷哈希清单不完整**：安装器载荷 114 个文件、清单只列 111 个（`install.cmd`/`install.ps1` 未列入）。
  `installer\build.ps1` 现在在打包前重建清单（本次 113 条），卸载器按清单判定归属的前提才成立。
- **卸载器不再信任任何同名清单**：只有当文件夹里的 `SHA256SUMS.txt` 首行是本包的包头时才用它驱动删除；
  否则（例如下载页的清单）**什么都不删**并给出说明，避免按别人的哈希删掉不属于本包的文件。
- **两个默认密码库的问答只写一个注册表值**（`CInfo::SaveVaultPath`）：以前用 `Save()` 会整体回写 9 个值，
  7zFM 与 7zG 同时运行时可能把另一个进程刚改的设置回滚。
- 「只问一次」的测试不再可能假通过（读不到消息框文本即判失败），并且库副本的清理放进 `finally`；
  `check-labels.ps1` 用 `$null` 判断还原，且运行期间的临时密码库位置/首启标记都会被还原。

### 变更 / Changed
- **只发布便携版 zip**：不再发布自解压 `setup.exe`。原因不是省事，而是归属实验（`docs/vt-attribution.md`）
  显示自解压外壳本身就是检测来源：把 `setup.exe` 拆开单独提交时，配置文本 0/69、载荷归档 0/63、
  官方存根 0/71，而「外壳 + 载荷」即使换成未被打标的官方程序仍是 2/70。去掉外壳后，
  **Elastic 与 CrowdStrike 的那两个检测直接消失**，功能没有损失：快捷方式与「应用和功能」登记
  由程序首次启动时询问后完成，`install.cmd` 仍在压缩包里作为手动入口。
  `installer\build.ps1` 只有在显式加 `-WithSetup` 时才构建自解压包。
- `install.cmd` / `install.ps1` 现在**随便携包一起发布**（以前只在自解压载荷里），
  包内哈希清单覆盖全部 113 个文件（此前 114 个文件只列 111 条）。
- 「应用和功能」里的版本号统一为 `26.03`（与程序内显示一致），不再与发布号分叉。
- **二进制身份改为诚实身份**：`CompanyName=Nomoziya`、`ProductName=7-Zip Password Vault`、
  版权写明「基于 7-Zip 26.03（Igor Pavlov，LGPL）的修改版」。未签名却声称官方公司/产品正是冒充类特征。
- **构建可复现**：GNU ld 会把链接时间写进 PE 头（实测这是唯一的不确定来源），现在链接时加
  `-Wl,--no-insert-timestamp`，**连续两次重新链接产出完全相同的哈希**（已验证）。
- manifest 增加 `<requestedExecutionLevel level="asInvoker"/>`：程序从不需要管理员权限。

### VirusTotal 实测 / Measured on VirusTotal (2026-09-14)

| 文件 | 改造前 | 改造后 |
|------|--------|--------|
| `portable.zip`（唯一发布的下载） | 1/67（Elastic） | **0/67** ✅ 全清 |
| `setup.exe`（不再发布） | 3/70（Microsoft `Wacatac.C!ml`、Elastic、CrowdStrike） | — 已停发，那两个检测随外壳一起消失 |
| `7zFM.exe` | 2/70（Microsoft、Elastic） | **1/69**（只剩微软 ML） |
| `7zG.exe` | 1/70（Microsoft `C!ml`） | **0/65** ✅ 全清 |

**发布集合只有 3 个文件，合计 1 个检出**（`7zFM.exe` 的微软 ML 判定），从改造前的 7 个降到 1 个。
归属实验（哪一层造成检测）见 `docs/vt-attribution.md`：把 `setup.exe` 拆开单独提交后，配置文本 0/69、
载荷归档 0/63、官方存根 0/71，而「自解压壳 + 载荷」即使换成未被打标的官方程序仍是 2/70 —— 也就是说自解压壳
形态本身就是原因，两个重建的 exe 再贡献约 1 个。剩下那 1 个的持久解法是代码签名（每次重建后也可先提交微软误报）。

剩下的检测与处置：两个重建 exe 的微软 ML 判定需要**每次构建重新提交误报**（
<https://www.microsoft.com/en-us/wdsi/filesubmission>，Software developer 路径）+ 长期靠**代码签名**
（SignPath / Azure Trusted Signing）；`setup.exe` 的 Elastic/CrowdStrike 来自自解压壳，**只发便携版 zip
即可完全消除**。

### 测试 / Tests
- `ui-test` **352/352**（新增第 26 组：首次启动只问一次、选「否」不建快捷方式/不写卸载项、下次不再问）。
- `uninstall-test` **27/27**（新增：清单首行不是本包时不删任何文件）。
- `core-test` 39/39；`check-labels -UiLang en` 无截断，`zh-cn` 1 处官方标签既有差异。
- `tests\vt-attrib.ps1` 新增：归属实验可重复运行；`vt-upload.ps1` 增加 502 重试与更稳的扫描列表。

构建方式 / Build: MinGW-w64 GCC 16.2.0 (msvcrt flavour)，可复现构建见 `BUILD.md`。
