# 安装方式与首启询问设计 / Installer & first-run design

状态：**提议中（Proposed）** — 待实现，替代 v1.4.2 / v1.4.3 的「自解压 + 脚本安装」方案。
适用版本：26.03 / 1.4.4（下一个发布）。
本文只描述设计与契约，不含代码补丁；实现按节落地，每节末尾给出验收条件。

---

## 0. 背景与已验证事实

v1.4.2 / v1.4.3 的 `setup.exe` 是「官方 `7z.sfx` 存根 + `sfx-config.txt` + 7z 载荷」拼接而成（`installer\build.ps1:48-53`）。
`sfx-config.txt` 里的 `RunProgram="install.cmd"` 与 `InstallPath=` **不被官方存根解析**（存根里没有 `@Install@` / `RunProgram` 字符串），因此实际行为只是「自解压到用户选的文件夹」：

- 不创建开始菜单 / 桌面快捷方式；
- 不写「应用和功能」卸载项；
- `install.cmd` / `install.ps1` 只是**留在目录里没人执行的死代码**；
- `7z-password-vault-*.exe` 仍保留官方 `VERSIONINFO`（Igor Pavlov / 7-Zip）却没有签名，在 VirusTotal 上多出 3/70 的检测（`Trojan:Win32/Wacatac.C!ml` / Elastic / CrowdStrike grayware），而官方 `7z.sfx` 存根是 0/71。

由此得到两条设计约束：

1. **安装器不得包含会改系统的脚本载荷**。载荷里带 PowerShell 安装逻辑，既不会被官方存根执行，又是杀毒引擎眼里的「灰样本特征」。
2. **首启由程序自己完成**（用户已选定方向）：自解压包只解压；快捷方式与卸载登记在**程序第一次被用户主动启动**时询问后写入。写在程序里的是编译产物，不再有「包内含脚本」的形态。

### 已验证的现状（不必重查）

| 事实 | 出处 |
|---|---|
| 密码库设置写在 `HKCU\Software\7-Zip\PasswordVault`，值名 `VaultPath` / `UseMasterPassword` / `RememberMasterPassword` / `AutoLockMaster` / `CloseAfterFill` / `AutoTypeByName` / `PromptToSaveNew` / `ShowPasswordInList` / `ShowPasswordForUnnamed` | `CPP\7zip\UI\Common\ZipRegistry.cpp:601-659` |
| 主键前缀 `Software\7-Zip\`，全部经 `HKEY_CURRENT_USER` 打开 | 同上 `:23-35` |
| 卸载器一次性删除**整棵** `HKCU\Software\7-Zip`（含 7-Zip 自身的每用户设置），删前导出 `.reg` 备份 | `tools\uninstall.ps1:102-103, 162-171, 231` |
| 卸载器只在 `InstallLocation` 与自身目录一致时才删「应用和功能」条目，否则跳过并提示 | `tools\uninstall.ps1:234-239` |
| 卸载器按程序目录 + `SHA256SUMS.txt` 逐文件比对 SHA-256 决定删除，路径必须在该目录内（`Test-InsideDir`），`..` / 盘符 / 根路径的清单条目一律拒绝 | `tools\uninstall.ps1:59-67, 392-474` |
| 安装载荷 114 个文件，而载荷内 `SHA256SUMS.txt` 只列 111 个（`install.cmd` / `install.ps1` 是 `build.ps1` 在写完清单后加进去的） | `installer\build.ps1:36-42`, `tests\deploy.ps1:35-48` |
| 语言文件是**位置式**编号：数字行是块起点，之后每个非数字行按顺序取下一个 id；未用到的 id 就是块尾的空行 | `Lang\en.txt:363-372, 392-471` |
| 语言 id 已用到 **3867**；`LangUtils.cpp` 的 `LangString(id)` 在缺失时返回空串，程序回落到内置中文兜底 | `CPP\7zip\UI\FileManager\PasswordDialogRes.h:1-112`, `PasswordVault.cpp:47-57` |
| `CPasswordVaultUi::Load(parent)` 会被三个对话框调用：口令对话框、解压对话框、添加到压缩包对话框 | `PasswordDialog.cpp:101`, `CompressDialog.cpp:471`, `PasswordVaultUi.cpp:59` |
| 密码库默认位置优先程序目录，**仅当该目录可写**；不可写则回落 `%APPDATA%\7-Zip\7zPasswordVault.dat`（`CanWriteToFolder` 用写探针文件判定） | `PasswordVault.cpp:187-226, 477-502` |
| 设置页 `IDD_PASSWORD_PAGE` 尺寸 300×280，控件最低到 y=230（底部约 40 单位空白，可放一个新按钮） | `CPP\7zip\GuiCommon.rc:118-119`, `PasswordPage.rc:27-28` |

### 目标 / 非目标

**目标**
- 自解压包保持「纯解压」，不再夹带任何会改系统的脚本。
- 首次由用户主动启动时，一次性询问是否创建快捷方式并登记卸载，全部只写 `HKCU`。
- 用户可以选「否」并保持系统干净；也可以日后从设置页补做。
- 便携目录被拷贝/移动后，快捷方式与卸载项指向当前实际路径（可检测、可修正）。
- 卸载仍然只删属于本包的文件，且可解释、可审计。

**非目标**
- 不写 `HKLM`、不需要管理员、不注册机器级文件关联（那是设置页 `System` 页签做、且以管理员身份运行的既有功能）。
- 不改安装目录到 `Program Files`（v1 仍是「用户自选文件夹 + 便携目录」）。
- 不引入 Inno Setup（列为演进路线，§11）。
- 不在本设计中改变口令/密码库本身的加密行为。

---

## 1. 决策记录（ADR 摘要）

### ADR-001：安装器不再夹带安装脚本
- **状态**：已接受。
- **决策**：`setup.exe` 只解压；快捷方式与卸载登记由程序首启询问后自行写入 `HKCU`。
- **备选**：等官方 SFX 支持 `RunProgram`（不取决于我们）；用 7-Zip SFX 的替代存根（引入第三方二进制，杀软风险更高）；迁到 Inno Setup（见 ADR-005）。
- **影响**：包内少两个 `install.*` 文件 → `SHA256SUMS.txt` 与载荷重新一致（§7.3）；杀软「包内含脚本」这一特征消失；代价是「用户双击 exe 后什么都不发生」的期待落差 → 由 §2 的首启询问补齐。

### ADR-002：首启状态写在 `HKCU\Software\7-Zip\PasswordVault\FirstRun*`
- **状态**：已接受（可被 ADR-006 取代）。
- **决策**：新增 3 个值，与密码库设置同键（用户已选定方向）。
- **原因**：复用 `CreateMainKey` / `OpenMainKey` 既有的 HKCU 打开路径，与 `CInfo` 的保存风格一致；卸载器删整棵 `HKCU\Software\7-Zip` 时首启状态一并消失，重装后重新询问，语义正确。
- **代价（须记录）**：① 该键在卸载时被整棵删除，若用户机器上还有**其它** 7-Zip 衍生版共用 `HKCU\Software\7-Zip`，会连它们的设置一起清掉（现状如此，非本设计引入）；② `CInfo::Save()` 会重写全部值，新字段必须一起进 `CInfo`，否则「设置页一保存」就可能把首启状态抹掉；③ 若将来希望首启状态在卸载后保留，需迁到兄弟键（ADR-006）。

### ADR-003：快捷方式与卸载项由 **exe 内** C++ 实现（COM），不调用 `cmd` / `powershell` / WSH
- **状态**：已接受。
- **决策**：用 `IShellLinkW` + `IPersistFile` 建 `.lnk`，用 `SHGetFolderPathW(CSIDL_PROGRAMS / CSIDL_DESKTOPDIRECTORY)` 定目录，用 `CKey` 写注册表。
- **备选**：`CoCreateInstance(CLSID_WScriptShell)`（需 WSH 组件，部分环境被策略禁用）；`process.Create("powershell.exe", ...)`。
- **原因**：不要在有杀软警惕的路径上再「程序启动脚本解释器」；不依赖 PowerShell 执行策略；`.lnk` 与注册表写入能用结构化 API 精确控制，错误码可上报给用户（§2.4 的失败模式要求）。
- **影响**：需要在 FM 与 GUI 两个 exe 里各 `#include` 同一份新模块（与 `PasswordVault*.cpp` 的现有做法一致）。

### ADR-004：路径漂移用「感知 + 一键修正」，不做自愈
- **状态**：已接受。
- **决策**：只记录最后一次登记时的目录；启动时发现当前目录不同才提示一次，修正与否由用户决定（设置页也可手动重做）。**不**在每次启动静默改写注册表 / 快捷方式。
- **原因**：便携包可以被拷到任意位置（U 盘、共享、`%TEMP%`），静默改写会在「用户只是把程序拷出来看一眼」时污染别人的机器状态；静默改写也让「卸载项消失」这类问题变得不可复现。

### ADR-005：v1 不引入 Inno Setup
- **状态**：已接受，保留为演进路线。
- **原因**：Inno 需要额外工具链与签名，且在没有代码签名证书的前提下，`setup.exe` 被杀软审视的原因（未签名的修改版 7-Zip）不会因为换安装器而消失。首启方案可以用零新工具链达成同样的用户体验；等有证书后再评估（§11）。

### ADR-006（备选，未采纳）：首启状态用兄弟键 `HKCU\Software\7-Zip\PasswordVaultSetup`
- 若将来需要「卸载后仍记住用户不想建快捷方式」，把 §2.5 的 5 个值与 §3.3 的卸载项搬到该兄弟键即可；本文其余部分不受影响。代价是卸载器要多删一个键，且新键不会被 `CInfo::Save()` 误改。

---

## 2. 首启询问：完整流程

### 2.0 一句话流程

```
用户双击 7zFM.exe（或快捷方式）
  → 主窗口创建成功
  → 读 HKCU\Software\7-Zip\PasswordVault
  → "从未询问过 且 当前目录适合登记" ?
        否 → 什么都不做，正常启动
        是 → 弹一次模态询问（是 / 否 / 以后再说）
               → 写状态（无论选了哪一项）
               → 选「是」才创建快捷方式 + 写「应用和功能」卸载项
  → 之后每次启动只做一次静默的「路径是否漂移」检查（§3.6），不再询问首启问题
```

### 2.1 触发时机（When）

| 项目 | 规定 |
|---|---|
| 触发进程 | **仅 `7zFM.exe`**（文件管理器主窗口）。`7zG.exe`（压缩/解压辅助进程）**永不**弹首启询问。 |
| 触发点 | `FM.cpp` 主窗口创建成功之后（`g_App.Create(...)` 返回 `S_OK`、`g_WindowWasCreated = true` 之后），在第一次 `WM_ACTIVATE` 之前；即窗口已存在可作为 owner，但尚未做任何解包/压缩工作。 |
| 为什么不在 `CPasswordVaultUi::Load()` 里问 | 该方法被口令对话框、解压对话框、添加到压缩包对话框共同调用（`PasswordDialog.cpp:101`、`CompressDialog.cpp:471`）。在这里问，用户「右键解压一个压缩包」时会被打断；而且一次会话里可能被问三次。首启询问是**应用级**问题，不是密码库级问题。 |
| 只问一次的范围 | 当前用户（`HKCU`）。同一台机器上的第二个 Windows 账户首次运行会各自被问一次——这是正确行为（快捷方式与卸载项本身是每用户的）。 |
| 静默模式 | 若进程带 `/S` 之类的无人值守参数，或启动时带压缩包路径（`g_MainPath` 非空，说明是双击压缩包调起的），**跳过询问**且**不写状态**（留给下一次用户主动启动）。 |
| 只读目录 | 见 §3.5：不弹出「是否创建快捷方式」的完整询问，改为弹出一次「说明 + 建议」类提示（文案 3872），并记入状态 S2（见 §2.5），因此同一个位置只提示一次。 |

### 2.2 询问条件（Guards）

全部满足才弹询问：

1. `HKCU\Software\7-Zip\PasswordVault\FirstRunAsk` **不存在**（或类型不对、读取失败 → 视为未询问）。
2. 当前进程是 `7zFM.exe`。
3. 当前目录**可登记**（§3.5 的判据全部满足）。
4. 当前目录里 `7zFM.exe` 存在（自检，防「程序被拆散了」）。
5. 本次会话尚未问过（进程内静态标志，杜绝重入）。

任何一条不满足 → 直接正常启动，不写任何东西。

### 2.3 问什么（对话框与文案）

用 `MessageBoxW` + `MB_YESNOCANCEL | MB_ICONQUESTION`（与现有 `IDT_PASSWORD_TWO_VAULTS_Q` 的处理方式一致，`PasswordVaultUi.cpp:69-93`），caption 用 `PasswordVault_GetCaption()`（= id 3828「7-Zip 密码管家」/「7-Zip Password Vault」）。

**中文（id 3869，语言文件里的正式文案）**

```
程序目录：
{0}

要创建开始菜单 / 桌面快捷方式，并登记到「应用和功能」吗？

「是」创建（只写入当前用户，不需要管理员）
「否」不创建，以后不再询问
「取消」以后再问
```

**英文（同一 id）**

```
Program folder:
{0}

Create Start Menu / Desktop shortcuts and add an entry to Apps & features?

Yes - create them (current user only, no administrator needed)
No - do not create them and do not ask again
Cancel - ask again later
```

实现注意：
- `{0}` 用 `UString::Replace` 填入**当前**程序目录（不是注册表里记录的那个）。
- 消息框会自动换行，长路径不会截断（`tests\check-labels.ps1` 已按多行衡量，不会再误报）。
- 文案里刻意不出现「安装」二字：这不是安装，是「把这台机器上的入口做好」。这也让「用户选否」不会显得像「安装失败」。

### 2.4 三个选项的效果

| 选项 | 立即效果 | 注册表写入 | 之后的行为 |
|---|---|---|---|
| **是（IDYES）** | ① 在开始菜单创建 `7-Zip Password Vault.lnk`；② 在桌面创建同名 `.lnk`；③ 写卸载项 4 个键值组（§4.2）。两项互相独立，各自失败不影响另一项 | `FirstRunAsk=1`、`FirstRunShortcuts=1`、`FirstRunUninstall=1`、`InstallLocation=<当前目录>`、`LastRegistered=<当前目录>` | 提示成功（3870）。以后启动不再问；只做路径漂移检查（§3.6）。 |
| **否（IDNO）** | 什么都不做，系统保持 §7.4 描述的「干净」状态 | `FirstRunAsk=1`；`FirstRunShortcuts` / `FirstRunUninstall` **不写**（等价于 0）；`InstallLocation` **不写**；`LastRegistered=""`（空串 = 用户明确说过不要再问，见 §2.5 S4） | 永远不再问。日后要补做只能走设置页按钮（§2.7）。 |
| **取消（IDCANCEL）/ 关闭对话框** | 什么都不做 | **什么都不写**（这是「以后再说」的全部含义） | 下次启动**再问一次**。连续取消每次都会问——这是刻意的：文案里写着「以后再问」，用户不会误以为被永久骚扰。若担心打扰，见 §2.6 第 6 条的「最多再问 N 次」可选加强。 |

部分失败的处理（用户选了「是」但某一项没做成）：

| 情况 | 状态写入 | 提示 |
|---|---|---|
| 两项都成功 | 1 / 1 / 1 | 3870 |
| 快捷方式失败、卸载项成功 | 1 / **0** / 1 | 3871（说明失败原因与补救路径） |
| 卸载项失败、快捷方式成功 | 1 / 1 / **0** | 3871 |
| 两项都失败 | 1 / 0 / 0 | 3871 |
| 卸载项**已存在但指向别处**（另一份拷贝登记过） | 见 §3.6 的「接管」语义：先问是否接管，用户确认才改写 | 3877 + 3870 |

关键规则：**无论成败都写 `FirstRunAsk=1`**。理由：失败多半是环境性的（目录暂时只读、注册表被策略锁、组策略禁用 .lnk 创建），重复弹窗不会让环境变好，只会把「首次启动」变成「每次都弹」。补救入口固定在设置页，用户需要时自己去点。

### 2.5 状态写在哪里（值名与类型）

键：`HKEY_CURRENT_USER\Software\7-Zip\PasswordVault`（与 `VaultPath` 等同键）。
类型一律 `REG_DWORD`（与 `UseMasterPassword` 等既有布尔值一致，由 `CKey::SetValue` 用 `DWORD` 写出）。

| 值名 | 类型 | 取值 | 含义 | 缺失时的解释 |
|---|---|---|---|---|
| `FirstRunAsk` | `REG_DWORD` | `1` = 首启问题已经处理过（问过**或**判定为当前环境不适合问） | 「还要不要弹首启询问」的**唯一**开关。存在即为真（判断「存在」，不依赖具体数值）。 | 缺失 = 从未处理 → 允许询问 |
| `FirstRunSkipped` | `REG_DWORD` | `1` = 当前环境不适合登记，已只提示过 | 与 `FirstRunAsk` 一起写：表示「没有登记，而且不是因为用户拒绝」。用于：目录之后变成可登记时给出**一次**温和提示（3874）。 | 缺失 = 要么登记过、要么用户拒绝过（看 `LastRegistered`） |
| `FirstRunShortcuts` | `REG_DWORD` | `1` = 现在应当有快捷方式 | 用户选了「是」且快捷方式创建成功（或已被判定存在且正确）。用于：设置页显示当前状态、卸载器判断「有没有我们自己建的快捷方式要清」。 | 缺失 = 没有 |
| `FirstRunUninstall` | `REG_DWORD` | `1` = 已写「应用和功能」条目 | 同上，针对卸载项。 | 缺失 = 没有 |
| `InstallLocation` | `REG_SZ` | 绝对路径（无结尾反斜杠） | 上次登记时程序目录。**只用于漂移检测与提示**，不是「安装位置」的权威来源——权威来源永远是当前 exe 所在目录。 | 缺失 = 未登记过 |
| `LastRegistered` | `REG_SZ` | 绝对路径，或空串 | 「我们最后一次处理过的程序目录」。空串是有效值，表示「用户明确说过不要再问」。与 `InstallLocation` 分开，是为了让「卸载项里那个值」与「我们自己的记忆」互不干扰（用户可能手工改过卸载项）。 | 缺失 = 未处理过 |

**四个状态互斥且可判定**（这是本设计里唯一需要仔细实现的地方）：

| 状态 | `FirstRunAsk` | `FirstRunSkipped` | `LastRegistered` | 启动时的行为 |
|---|---|---|---|---|
| S1 未处理 | 缺失 | 缺失 | 缺失 | 按 §2 走首启询问（若不可登记则转 S2） |
| S2 环境不适合（已告知） | `1` | `1` | 当前目录 | 静默；若当前目录**已变成可登记**（§3.5 判据全部通过）→ 弹一次 3874，然后转 S3 或 S4 |
| S3 已登记 | `1` | 缺失 | 当前目录 | 静默；只做「路径漂移」与「卸载器是否还在」检查（§3.6） |
| S4 用户拒绝 / 明确不再问 | `1` | 缺失 | 空串 | 静默，永不询问；只有设置页按钮能改变它 |

不写入的值：不记时间戳（会被当成遥测）、不记版本号（升级后重问没有必要，见 §2.6）、不做「最多问 N 次」的计数（§2.6 第 6 条，可选）。

实现契约（伪代码）：

```cpp
// 每次启动读一次；结果缓存在进程内，避免多次开键
struct CFirstRunState {
  bool  asked;            // FirstRunAsk 存在
  bool  skipped;          // FirstRunSkipped 存在（环境不适合）
  bool  haveShortcuts;    // FirstRunShortcuts == 1
  bool  haveUninstall;    // FirstRunUninstall == 1
  bool  haveRegistered;   // LastRegistered 存在（可能是空串）
  UString installLocation;   // InstallLocation（可能为空）
  UString lastRegistered;    // LastRegistered（可能为空串）
  bool Load();               // 打开 HKEY_CURRENT_USER\Software\7-Zip\PasswordVault (KEY_READ)
  bool SaveNotSuitable(const UString &dir);   // FirstRunAsk=1 + FirstRunSkipped=1 + LastRegistered=dir
  bool SaveDeclined(const UString &dir);      // FirstRunAsk=1 + LastRegistered=""          (dir 仅用于日志)
  bool SaveRegistered(bool shortcutsOk, bool uninstallOk, const UString &dir);
};                                            // = FirstRunAsk=1 + FirstRun* + InstallLocation + LastRegistered
```

`Load()` 必须容错：键不存在、值缺失、类型不是 DWORD（例如被人手工写成 `REG_SZ`）都当「未处理」，不得让启动失败。**任何一次写入失败都不得阻断启动**（最坏情况：下次再问一次，可接受）。

实现注意（Windows 注册表的一个坑）：**「值存在但为空串」与「值不存在」必须区分开**。`CKey` 的 `QueryValue` 对空串会返回成功并给出空串，而 `GetValue_bool_IfOk` 之类只判存在性；S3 与 S4 的区别完全靠 `LastRegistered` 是否存在，所以读取时要用「存在性 + 内容」两个信息，不能用「内容非空」来判断。写空串用 `key.SetValue(kLastRegistered, UString())`（`REG_SZ` 长度 0，合法且与「删除值」不同）。

### 2.6 如何避免每次启动重问

1. **唯一开关**：`FirstRunAsk` 存在就不再问。判断条件是「值存在」，不是「值为某个特定数字」——避免第三方工具把值改成 `0` 后被反复询问。
2. **问过就写，包含失败与拒绝**：§2.4 已规定失败也写。这条是本设计的核心，否则「企业机禁写注册表」的用户会每次启动都被弹窗。
3. **与两个库文件的问题互不干扰**：`IDT_PASSWORD_TWO_VAULTS_Q`（`PasswordVault.cpp:521-535`）已经有自己的记忆机制（写 `VaultPath`），本设计不改动它，也不复用 `VaultPath` 作为「问过没」的标志。
4. **升级不重问**：新版本启动时若 `FirstRunAsk` 已存在，不因为是新 exe 而重问。用户想重做走设置页。
5. **进程内防重入**：`7zFM` 在会话内只判定一次；多窗口（`Ctrl+N`）共享同一进程，不会重复弹。
6. **【可选加强】取消不无限重问**：如果实践反馈「取消」打扰过多，加一个 `FirstRunDeferCount`（`REG_DWORD`）计数，达到 3 次后按「否」处理并提示「想创建时去设置页」。本设计**默认不实现**（更简单的语义、更少的注册表值），仅记录为可选。

### 2.7 用户以后如何手动补做

**主入口：设置页按钮**（`Tools → Options → Password manager`，即 `IDD_PASSWORD_PAGE`）。

- 控件：在现有页面底部新增一个按钮，`PasswordPageRes.h` 里给新 id（建议 `IDB_PASSWORD_CREATE_SHORTCUTS`，控件 id 取 2616），位置沿用现有网格（`PasswordPage.rc` 最后一行控件在 y=230，新按钮放 y=246，靠左对齐 x=12，宽 140，高 14，满足 300×280 的页面尺寸与 `check-labels` 的宽度要求）。
- 按钮文字：id **3873**「创建快捷方式并登记卸载(&S)...」/「Create shortcuts and register uninstall(&S)...」（文案不含「密码库」字样，因为按钮做的是外壳集成，不是密码库操作）。
- 行为（`PasswordPage` 内）：
  1. 无论 `FirstRunAsk` 是否存在，都允许执行（这是「重做」入口）。
  2. 先弹一次确认（用 3868 作标题、3872 作正文），说明将创建什么、写哪些位置；用户确认后执行。
  3. 执行 §4 的完整清单（幂等，见 §4.4）。
  4. 成功后写 `FirstRunAsk=1`、`FirstRunShortcuts` / `FirstRunUninstall`、`InstallLocation`、`LastRegistered`（当前目录）。
  5. 失败时按 §2.4 的表格提示，并**不改写**成功标志。
- 按钮在只读目录（§3.5）下的处理：**仍然显示**但点击后直接给出「当前目录不适合登记」的说明，而不是静默禁用——禁用而不解释会让用户以为程序坏了。

**次入口：文档化的手工等价操作**（供企业/脚本场景，写进 `README.md` 的卸载章节旁）：

```bat
:: 手工创建开始菜单快捷方式（资源管理器里也可以：右键 7zFM.exe → 发送到 → 桌面快捷方式）
:: 手工登记「应用和功能」（reg add，等价的注册表内容见 §4.2）
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\7ZipPasswordVault" ^
  /v DisplayName /t REG_SZ /d "7-Zip Password Vault 26.03" /f
```

**不做**的入口：不再通过运行包内脚本来补做（§8 把 `install.ps1` 降级为「等价物/验证工具」，它不再是首启流程的一部分）。

### 2.8 验收条件（§2）

- [ ] 全新用户首次执行 `7zFM.exe`：弹出一次询问，三个按钮文案与 3869 一致。
- [ ] 选「是」：`%APPDATA%\Microsoft\Windows\Start Menu\Programs` 与桌面各出现一个指向**当前** `7zFM.exe` 的 `.lnk`；「应用和功能」出现 `7-Zip Password Vault 26.03`；`HKCU\...\PasswordVault` 下 5 个值齐全。
- [ ] 选「否」：快捷方式与卸载项都不存在；注册表只有 `FirstRunAsk=1`；再次启动**不**询问。
- [ ] 选「取消」：注册表**没有任何**新值；再次启动**会**再问。
- [ ] 手动把 `FirstRunAsk` 删掉后重启：重新询问。
- [ ] `7zG.exe` 单独运行（右键「解压到…」）：从不弹首启询问。
- [ ] 只读目录（如 `C:\Program Files\...` 只读测试目录）：不弹完整询问，弹一次说明（3872），第二次启动不再弹。
- [ ] 双击一个 `.7z` 文件调起 `7zFM.exe`：本次不问、不写状态；下一次用户主动启动才问。

---

## 3. 只写 HKCU：清单、失败模式、便携共存

### 3.1 为什么只写 HKCU

- **不需要管理员**：`HKCU\Software\...` 当前用户可写；卸载项写在 `HKCU\...\Uninstall\` 时，Windows 的「应用和功能」会在**当前用户**的列表里显示它，并允许非管理员点击卸载。
- **无 UAC 提示**：不触发提权，也就不会出现「一个便携压缩包解压出来的程序为什么要求管理员」的疑问。
- **卸载更容易做干净**：机器级登记一旦写进 `HKLM` 而程序目录被用户直接删掉，就留下无法自愈的残留；HKCU 的残留至少只影响当前用户，且能被卸载器的「孤儿检测」（§3.6）发现。
- **与官方 7-Zip 共存**：`HKLM\SOFTWARE\7-Zip` 与 `HKLM\SOFTWARE\Classes\7-Zip.*` 属于机器上可能已存在的官方安装。本包**绝不触碰**它们（除非用户自己到设置页 `System` 页签以管理员身份做文件关联，那是既有功能，与首启无关）。

### 3.2 快捷方式清单

| 位置 | 路径（解析方式） | 文件名 | 目标 | 工作目录 | 图标 | 说明（Description） |
|---|---|---|---|---|---|---|
| 开始菜单（程序） | `SHGetFolderPathW(NULL, CSIDL_PROGRAMS, ...)` = `%APPDATA%\Microsoft\Windows\Start Menu\Programs` | `7-Zip Password Vault.lnk` | `<InstallDir>\7zFM.exe` | `<InstallDir>` | `<InstallDir>\7zFM.exe,0` | `7-Zip Password Vault - local encrypted password vault for 7-Zip` |
| 桌面 | `SHGetFolderPathW(NULL, CSIDL_DESKTOPDIRECTORY, ...)`（每用户桌面，不是 `CSIDL_COMMON_DESKTOPDIRECTORY`） | 同上 | 同上 | 同上 | 同上 | 同上 |

要点：

- **名称固定为 ASCII**：`7-Zip Password Vault.lnk`。不用「7-Zip 密码管家版.lnk」——卸载器按 `.lnk` 的 *TargetPath* 判定归属（`uninstall.ps1:293-302`），名称不影响安全，但固定 ASCII 名称让中文/英文界面下的用户体验一致，也避免语言切换后出现两个快捷方式。
- **目标固定为 `7zFM.exe`**：不用 `7zG.exe`，也不用打包的什么启动器（不存在）。
- **工作目录必须设置**：某些 shell 扩展与相对路径行为依赖它；更重要的是让「从快捷方式启动」的 `GetProgramFolderPath()`（`PasswordVault.cpp:187-199`）与双击 exe 完全一致。
- 图标用 `7zFM.exe,0`（现有 `install.ps1:44` 的做法），不额外释放 `.ico` 文件——保持包内文件数不变。

### 3.3 「应用和功能」卸载项清单

键：`HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\7ZipPasswordVault`
（键名与现有 `install.ps1:26` 一致，便于共存与迁移）。

| 值名 | 类型 | 内容 | 备注 |
|---|---|---|---|
| `DisplayName` | `REG_SZ` | `7-Zip Password Vault 26.03` | 版本号从构建参数注入（与现在 `install.ps1:26,59` 一致） |
| `DisplayVersion` | `REG_SZ` | `1.4.4` | 与发布文档一致 |
| `Publisher` | `REG_SZ` | `Nomoziya` | 保持现状 |
| `DisplayIcon` | `REG_SZ` | `<InstallDir>\7zFM.exe` | Windows 会取其中的图标 |
| `InstallLocation` | `REG_SZ` | `<InstallDir>`（无结尾反斜杠） | **卸载器用它判定「这个条目是否属于我」**（`uninstall.ps1:236`）；漂移检测也读它 |
| `UninstallString` | `REG_SZ` | `"<InstallDir>\uninstall.cmd"` | 带引号，防路径含空格 |
| `QuietUninstallString` | `REG_SZ` | `"<InstallDir>\uninstall.cmd" -KeepVault -Yes -NoBackup` | 无人值守卸载保留密码库，与现状一致 |
| `InstallDate` | `REG_SZ` | `yyyyMMdd` | 首次登记日期；重做时**不覆盖**已有值（避免「安装日期」被刷新） |
| `EstimatedSize` | `REG_DWORD` | 目录内文件字节数 / 1024 | 遍历失败时写 0，不阻断 |
| `NoModify` | `REG_DWORD` | `1` | 没有「修改」按钮 |
| `NoRepair` | `REG_DWORD` | `1` | 没有「修复」按钮 |
| `URLInfoAbout` | `REG_SZ` | `https://github.com/Nomoziya/7z-password-vault` | 保持现状 |
| `URLUpdateInfo` | `REG_SZ` | 同上 | 可选；不加也行，避免指向不存在的更新源 |

不写 `WindowsInstaller=1`（我们没有 MSI）、不写 `SystemComponent=1`（那会让条目在「应用和功能」里隐藏，与目的相反）。

**卸载命令指向什么**：永远是 `<InstallDir>\uninstall.cmd`，即**包内自带的**卸载器（由 `tests\deploy.ps1:24` 从 `tools\uninstall.cmd` 拷入）。设计上必须保证：`uninstall.cmd` 与 `uninstall.ps1` 在包内、且在 `SHA256SUMS.txt` 里（§7.3），否则「卸载项指向一个不存在的文件」是最容易被用户发现的缺陷。

### 3.4 失败模式与处理

| # | 场景 | 可观测现象 | 处理 |
|---|---|---|---|
| F1 | **程序目录只读**（`C:\Program Files\`、只读网络共享、U 盘写保护） | 写探针失败（复用 `CanWriteToFolder` 的判据，`PasswordVault.cpp:203-226`） | 不弹完整询问；弹一次说明（3872）：本目录不可写 → 不建议创建快捷方式（快捷方式本身能建，但**密码库会落到 `%APPDATA%\7-Zip`**，且卸载需要管理员删除目录）。写 S2（`FirstRunAsk=1` + `FirstRunSkipped=1` + `LastRegistered=<当前目录>`），不写 `InstallLocation`。 |
| F2 | **快捷方式已存在**（同名、指向别的目录） | `IShellLink`/`IPersistFile::Save` 覆盖成功但目标错误 | 保存前先读该 `.lnk` 的 target：<br>· 指向**同一个** exe → 视为已存在，不重写（幂等），计为成功；<br>· 指向**别的**目录的 7zFM.exe → 这是另一份拷贝的快捷方式，**不静默覆盖**，弹 3878 询问是否接管；用户拒绝则视为失败项（写 `FirstRunShortcuts=0`）。 |
| F3 | **同名 `.lnk` 是用户手工建的**（例如用户自己拖过 `7zFM.exe`） | 同上，target 指向本目录 | 视为已存在且正确 → 不重写、计为成功。不改动用户的手工快捷方式（除了它本来就指向我们）。 |
| F4 | **`.lnk` 创建被策略阻止**（组策略禁用开始菜单写入、受控文件夹访问、只读漫游配置） | `IPersistFile::Save` 返回 `HRESULT` 失败 | 记为失败项；弹 3871 带上 `HRESULT` 对应的系统文本（用 `NError::MyFormatMessage`，与 `PasswordVault.cpp:176` 同法）；状态写 `FirstRunShortcuts=0`；不重试、不弹第二次。 |
| F5 | **注册表被策略锁**（`HKCU\...\Uninstall` 不可写、或整个 `HKCU\Software\7-Zip` 只读） | `RegCreateKeyEx` 返回 `ERROR_ACCESS_DENIED` 等 | 记为失败项；提示 3871；**不阻断启动**；不写 `InstallLocation`（没有登记就不该记位置）。 |
| F6 | **卸载脚本已被删除**（用户清理过目录，或杀软隔离了 `uninstall.ps1`） | 卸载项存在但 `UninstallString` 指向不存在的文件 | 两处防线：<br>① **写入前自检**：登记卸载项要求 `<InstallDir>\uninstall.cmd` 与 `uninstall.ps1` 同时存在（§3.5 判据之一），缺失就不写卸载项（只建快捷方式），并在 3871 里说明；<br>② **运行时自检**：每次启动的静默检查（§3.6）发现「有卸载项但脚本不见了」时，**删除自己的卸载项**并写 `FirstRunUninstall=0`（不留死入口），静默完成，仅记日志。 |
| F7 | **整个文件夹被拷到别处**（便携包最常见的用法） | `HKCU` 里 `LastRegistered` 指向旧目录 | 走「漂移」流程（§3.6）：**不**改写；提示 3875，用户确认后按 §4.4 重做登记（旧目录的快捷方式与卸载项会被接管，见 F8）。 |
| F8 | **同一用户在两处都登记过**（旧位置 + 新位置各有一个卸载项 / 快捷方式） | 出现两个「应用和功能」条目 | 只清理「明确的自己人」：卸载项 `DisplayName` 相同且 `InstallLocation` 指向的目录里**存在** `7zFM.exe` 且存在我们的 `SHA256SUMS.txt` → 该条目是同一份拷贝的旧登记，重做时可以删除；否则保留并提示用户手动处理。**绝不**按 `DisplayName` 盲删。 |
| F9 | **多用户机器** | 另一个账户的「应用和功能」没有这个条目 | 正确行为：HKCU 是每用户的。文档需明确写出这一点，避免被当作缺陷。 |
| F10 | **目录或路径极长**（> `MAX_PATH`） | `IPersistFile::Save` 失败 | 记为失败项；提示 3876 并建议把程序放到更短的路径。这是便携包的现实场景（解压到很深的目录）。 |
| F11 | **临时目录 / 可移动盘**（`%TEMP%`、U 盘、网络盘） | 登记后卸载项会指向可能消失的路径 | 不提供登记（§3.5 G2/G3）→ 走 S2：只提示一次 3872，并记下当时的目录。用户把文件夹拷到本地后，§3.6 检测到位置变化且新位置可登记 → 弹一次 3874。 |
| F12 | **exe 被杀软拦下或被替换** | 快捷方式指向的文件哈希不匹配 | 本包中 `7zFM.exe` / `7zG.exe` 未签名（`BUILD.md` 已记录该局限）。首启流程不做自校验（会显著变慢且需要读 `SHA256SUMS.txt`，而该文件可能被用户删）；只在文档与 `BUILD.md` 中保留「从官方发布页下载并核对 `SHA256SUMS.txt`」的指引。 |

### 3.5 什么时候**不**应该提供登记

判据（在弹询问之前逐条判定）：

| 判据 | 触发条件 | 依据 |
|---|---|---|
| G1 目录不可写 | `CanWriteToFolder(programFolder) == false`（写探针失败） | 与密码库默认位置判定同源，保证「能不能把库放在程序旁边」与「要不要建入口」口径一致 |
| G2 可移动 / 网络 / 非固定盘 | 卷类型为 `DRIVE_REMOVABLE`、`DRIVE_REMOTE`、`DRIVE_CDROM`、`DRIVE_RAMDISK`（`GetDriveTypeW` 于程序目录所在盘） | 卸载项会指向一块可能不在的盘；快捷方式会变成断链 |
| G3 临时目录 | 程序目录位于 `%TEMP%` / `%TMP%` / `%LOCALAPPDATA%\Temp` 之下，或名字匹配 `7zpw-sfx-`（`build.ps1` 的临时目录前缀） | 自解压中间产物、测试残留 |
| G4 系统目录 | 程序目录位于 `%SystemRoot%`、`%ProgramFiles%`、`%ProgramFiles(x86)%` 或 `%ProgramData%` 之下**且不可写**（可写的自定义子目录如 `D:\Tools\...` 不在此列） | 目录不可写已由 G1 覆盖；G4 只补一条「别把系统目录当安装目录」的提示语 |
| G5 目录不像我们的包 | `<InstallDir>\7zFM.exe` 不存在，**或** `<InstallDir>\SHA256SUMS.txt` 不存在 | 没有清单就无法安全卸载（§7.3），也不该登记 |
| G6 卸载器缺失 | `<InstallDir>\uninstall.cmd` 或 `uninstall.ps1` 缺失 | 见 F6①：只建快捷方式，不登记卸载项（G6 只拦卸载项，不拦整个询问） |
| G7 路径过长 | 程序目录长度 ≥ 150 字符 | 给 `UninstallString` / `DisplayIcon` 留出余量，避免写入后无法执行 |

命中 G1–G5 或 G7 中任意一条 → **不弹完整询问**，改为弹一次说明（文案 3872），并写 `FirstRunAsk=1` + `FirstRunSkipped=1` + `LastRegistered=<当前目录>`（= 状态 S2，见 §2.5）。命中 G6（仅缺卸载脚本）不在此列：仍然弹完整询问，只是不写卸载项，文案尾部追加一句「卸载脚本缺失，将只创建快捷方式」。

> **为什么 S2 也要写状态**：G1–G5 情况下若不写任何东西，只读目录 / U 盘里的程序就会**每次启动**都弹一次说明——比不提示更糟。写了 `FirstRunSkipped` 之后：同一位置只提示一次；而用户把目录拷到**可登记**的位置后，`FirstRunSkipped` 存在 + 当前目录可登记 ⇒ 弹**一次** 3874「现在可以登记了」，用户选「是」转 S3、选「否」转 S4。这就是 §2.5 里 S2 存在的原因。`LastRegistered` 记的是**当时那个不适合的目录**，所以「换个位置」是可以被检测到的（§3.6 的漂移判定）。

### 3.6 便携目录被拷贝/移动后的处理

**记录什么**：`InstallLocation` / `LastRegistered`（§2.5）。两者都是「上次登记时的程序目录」。

**每次启动的静默检查**（仅 `7zFM.exe`，不弹窗除非命中下面的分支）：

```
current = GetProgramFolderPath()          // 当前 exe 所在目录，永远权威
state   = Load()                          // HKCU，见 §2.5 的 S1..S4

if (!state.asked)                                   // S1
     → 首启询问流程（§2）

else if (state.skipped)                             // S2：上次判定为「不适合登记」
     if (!SamePath(current, state.lastRegistered) && 当前目录可登记(§3.5))
         → 弹 3874 一次（本会话只弹一次）
               「是」→ 登记 → 写 S3
               「否」→ 写 LastRegistered=""（S4，别再问）
     else → 静默

else if (state.lastRegistered.IsEmpty())            // S4：用户明确说过不要
     → 静默，永不询问（只能由设置页按钮改变）

else if (SamePath(current, state.lastRegistered))   // S3：路径一致
     → 静默，仅做 F6② 的「卸载器是否还在」自检

else                                                // S3 + 漂移（便携目录被移动）
     if (state.haveUninstall && 卸载项.InstallLocation != current &&
         卸载项.InstallLocation 指向的目录里已没有我们的 7zFM.exe / SHA256SUMS.txt)
         → 旧位置残留（F8）：静默删除该卸载项，写 FirstRunUninstall=0
     if (当前目录可登记(§3.5))
         → 弹 3875 一次（本会话只弹一次）
               「是」→ 按 §4.4 重做登记（接管旧快捷方式与旧卸载项）
               「否」→ 不动任何东西，写 LastRegistered=current（「已经知道，别再问」）
     else → 静默：只记日志，不改注册表
```

路径比较规则：`SamePath` 用**不区分大小写**的完整路径比较，并且比较前去掉结尾反斜杠（`GetProgramFolderPath()` 已经不带结尾分隔符）。**不要**用 8.3 短名或 `\\?\` 前缀做比较：同一个目录用不同写法会被误判成「漂移」，进而弹出不必要的提示。若短时间内无法可靠比较，宁可退化为「字符串不区分大小写相等」，并把误判的代价限制为「多弹一次 3875」——不会破坏数据。

**为什么先做 F8 的静默清理再问**：用户把文件夹从 `D:\7-Zip Password Vault` 挪到 `E:\Tools\7zpw` 之后，`HKCU` 里的卸载项会指向 `D:\...`。此时「应用和功能」里是一个**点不动的卸载按钮**（`UninstallString` 指向已不存在的路径）。这是用户能直接看到的最糟糕的失败模式，所以要在任何提示之前先把它清掉——**前提是能证明它确实是我们的旧登记**（`InstallLocation` 下的 `7zFM.exe` + `SHA256SUMS.txt` 已消失，且 `DisplayName` 匹配）。保守起见，删不掉就不删，只提示。

**「接管」语义（F2/F8 共用）**：

- 快捷方式：读 `.lnk` 的 `TargetPath`。若它指向**任何** `<某目录>\7zFM.exe`，且我们打算写的新目标不同，则视为「另一份登记的快捷方式」→ 用户确认后覆盖（这就是「接管」）。
- 卸载项：只有一个键名（`...\Uninstall\7ZipPasswordVault`），天然是「一份」。重做时若键已存在，检查其 `InstallLocation`：
  - 指向当前目录 → 幂等更新（保留 `InstallDate`）；
  - 指向不存在我们文件的目录 → 覆盖（接管）；
  - 指向**存在**我们文件的另一个目录 → 两份拷贝都在用 → **不覆盖**，提示用户「另一份拷贝在 X，仍登记着；请在那一份里先卸载」（F8）。

**只读目录对「密码库默认位置」的影响（重要）**

现在密码库默认在程序目录（`GetDefaultPath()`，`PasswordVault.cpp:477-502`），因此：

1. 解压到**可写**目录（今天的默认体验）：`7zPasswordVault.dat` 落在程序目录旁，不占系统盘。首启询问的文案不必提密码库位置。
2. 解压到**只读**目录：`CanWriteToFolder` 为假 → 默认位置自动回落到 `%APPDATA%\7-Zip\7zPasswordVault.dat`。**这与「用户以为自己的密码跟着文件夹走」的直觉相反**，而且便携包通常被期待「数据跟着走」。因此：
   - 3872 的文案必须明确写出「本目录不可写，密码库将存放在 `%APPDATA%\7-Zip\7zPasswordVault.dat`」；
   - 设置页的路径框（`IDE_PASSWORD_VAULT_PATH`）保持「留空 = 默认」的语义不变，用户填一个可写目录即可把库放回便携位置；
   - **不**在本设计里改变默认位置的优先级规则（那是加密数据存放位置，改动风险高，见 §11 的独立议题）。
3. 只读目录下的另一个后果：目录不可写 ⇒ 卸载需要管理员（删除 `Program Files` 下的文件）。3872 文案同时提示「若希望免管理员的卸载，请把程序放到你自己的目录」。
4. 首启询问与「两个库文件」询问（3865）的相互顺序：首启询问在 `g_App.Create` 之后、`CPasswordVaultUi::Load` 之前，因此**两个询问不会在同一时刻叠加**；但只读目录 + 只有一个 `%APPDATA%` 库时，`GetTwoDefaults` 返回 false（需要一个**能写**的程序目录才会构造 portable 路径对），所以也不会产生「新库建在只读目录」的失败路径。

### 3.7 验收条件（§3）

- [ ] 只读目录：不弹完整询问，弹 3872；注册表只有 `FirstRunAsk=1`；第二次启动无提示。
- [ ] U 盘（`DRIVE_REMOVABLE`）：同 §3.5 G2，不给登记。
- [ ] 目录缺 `SHA256SUMS.txt`（手工删掉）：不给登记（G5），提示 3872。
- [ ] 手工删掉 `uninstall.ps1` 后启动：仍弹询问，但只创建快捷方式；「应用和功能」没有条目。
- [ ] 已登记后把整个文件夹改名：启动时提示 3875；选「是」后快捷方式与卸载项都指向新路径；选「否」后不再提示。
- [ ] 只读目录 → 拷到可写目录：只弹一次 3874；选「否」后不再弹。
- [ ] 已登记后整目录删除（模拟用户直接删除）：下次从别处运行同名包 → 旧卸载项被静默清除（F8）。
- [ ] 从 `%TEMP%\7zpw-sfx-*` 启动：不给登记。

---

## 4. 实现规格（可直接按此实现）

### 4.1 新模块

建议新增（实现阶段，不在本设计内提交）`CPP\7zip\UI\FileManager\PasswordVaultSetup.{h,cpp}`，同时编入 `7zFM` 与 `7zG` 两个目标（与 `PasswordVault.cpp` 的现状一致；`7zG` 只是不调用首启入口，设置页相关代码不会被它用到）。

对外接口（示意）：

```cpp
namespace NVaultSetup {
  enum class EReady { Yes, No, NoNeed };   // NoNeed: 用户从未需要

  bool IsRegisterable(const UString &dir, UString &reasonId);  // §3.5 判据
  bool ReadRegistration(const UString &dir, bool &hasShortcuts, bool &hasUninstall);
  bool CreateShortcuts(const UString &dir, bool overwriteForeign, UString &error);
  bool RemoveShortcuts(const UString &dir, UString &error);
  bool WriteUninstallEntry(const UString &dir, const UString &version, UString &error);
  bool RemoveUninstallEntry(const UString &dir, UString &error);
}
```

- `CreateShortcuts` / `WriteUninstallEntry` 都是幂等的：先检查现状，能不动就不动。
- 所有失败都通过 `error` 返回**面向用户**的文本（语言 id + 占位符替换），不返回裸 `HRESULT`。
- 与 `tools\uninstall.ps1` 的**共用契约**：键名、值名、类型、`.lnk` 名称与三个属性（Target/WorkingDirectory/IconLocation）。用 `PasswordVaultSetup.h` 顶部的常量集中定义，注释里指向本文 §3.2 / §3.3。

### 4.2 注册表写入片段（等价内容，供实现与手工核对）

```reg
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\7-Zip\PasswordVault]
"FirstRunAsk"=dword:00000001
"FirstRunShortcuts"=dword:00000001
"FirstRunUninstall"=dword:00000001
"InstallLocation"="D:\\7-Zip Password Vault"
"LastRegistered"="D:\\7-Zip Password Vault"

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\7ZipPasswordVault]
"DisplayName"="7-Zip Password Vault 26.03"
"DisplayVersion"="1.4.4"
"Publisher"="Nomoziya"
"DisplayIcon"="D:\\7-Zip Password Vault\\7zFM.exe"
"InstallLocation"="D:\\7-Zip Password Vault"
"UninstallString"="\"D:\\7-Zip Password Vault\\uninstall.cmd\""
"QuietUninstallString"="\"D:\\7-Zip Password Vault\\uninstall.cmd\" -KeepVault -Yes -NoBackup"
"InstallDate"="20260913"
"EstimatedSize"=dword:000186a0
"NoModify"=dword:00000001
"NoRepair"=dword:00000001
"URLInfoAbout"="https://github.com/Nomoziya/7z-password-vault"
```

### 4.3 与既有 `CInfo` 的关系

`NPasswordVault::CInfo::Save()`（`ZipRegistry.cpp:615-629`）会**重写全部已知值**，因此：

1. 首启相关值**要么**进 `CInfo`（作为新成员，`Save()` 时一并写），**要么**完全由 `PasswordVaultSetup.cpp` 自己开键写入、且 `CInfo::Save()` 绝不触碰它们。
2. 本设计选择**后者**（独立模块自己写），理由：`CInfo` 是「密码库选项」的载体，混入外壳集成状态会让 `Load()` 的默认值语义（`ZipRegistry.cpp:631-641`）变复杂；而且 `CInfo::Save()` 在设置页每次 `Apply` 时都会调用，把首启状态交给它反而增加了「不小心清零」的风险。
3. 硬约束：**`CInfo::Save()` 不得删除整个 `PasswordVault` 键或整棵 `HKCU\Software\7-Zip`**（现状不删，保持）。

### 4.4 重做（幂等）流程

`RepairRegistration(dir, opts)`，被首启、漂移修正、设置页按钮三处共用：

```
1. 判据 §3.5：不满足 → 返回 NoNeed/失败原因（不写任何东西）
2. 传送到位：确保目标 .lnk 的 Target / WorkingDirectory / IconLocation 与当前 exe 一致
      - 已存在且正确 → 跳过（不算失败）
      - 已存在但指向另一份 7zFM.exe → opts.overwriteForeign ? 覆盖 : 失败(3878 已问过)
3. 卸载项：
      - 键不存在 → 创建并写 §3.3 全部值（InstallDate = 今天）
      - 键存在且 InstallLocation == dir → 更新除 InstallDate 外的值
      - 键存在且指向「已消失的旧目录」→ 覆盖（接管），InstallDate 重置为今天
      - 键存在且指向「仍在用的另一份拷贝」→ 失败并提示（F8）
4. 统计结果 → 写 FirstRunAsk=1 / FirstRunShortcuts / FirstRunUninstall / InstallLocation / LastRegistered
5. 返回结果给调用方决定弹什么文案
```

### 4.5 不做的事（明确边界）

- 不写 `HKLM`、不写 `HKCU\Software\Classes`（不抢文件关联）。
- 不创建 `C:\ProgramData` 下的共享快捷方式。
- 不添加开机自启、不写 `Run` 键。
- 不发送任何网络请求（首启流程必须完全离线）。
- 不在卸载项里放「检查更新」之类会触网的入口。

---

## 5. 与便携版的共存

### 5.1 一份包，两种用法

| 用法 | 期望行为 |
|---|---|
| 便携（解压即用，随便放） | 不创建任何入口；密码库跟着目录走（可写时）；不写注册表以外的任何东西 |
| 「当安装版用」（用户希望有开始菜单入口） | 首启询问选「是」→ 建入口；这就是今天 `setup.exe` 承诺但没有做到的事 |
| 同一份包在两处都用 | 两份拷贝各自可以登记；但**卸载项只能有一个**（同一键名）→ §3.6 的「接管/冲突」规则。文档必须写明：想同时用两份，就在第二份里对「接管」提示选「否」，用 `7zFM.exe` 直接启动。 |

### 5.2 数据跟着目录走的前提

- 密码库默认在程序目录**且该目录可写**（`PasswordVault.cpp:498-500`）。
- 因此「便携目录被拷贝」时，`7zPasswordVault.dat` 会一起被拷走——**这是数据跟着走的实现方式，同时也是风险**：把目录拷到 U 盘、发到网盘，就等于把密码库文件（DPAPI 加密或主密码加密）一起带走了。文档（`README.md`）里必须再强调一次；本设计不改这个既定行为，但要求 3872 / 设置页文案不提「密码库会自动跟走」这种会误导的说法。
- 目录被拷到**只读**位置后，程序不会移动已有 `.dat`（`AdoptPortableDefault` 只在「程序目录可写且程序目录没有库、`%APPDATA%` 有库」时才搬，`PasswordVault.cpp:544-606`），库继续在 `%APPDATA%` —— 与 §3.6 第 2 条一致。

### 5.3 「移动后」的三条路径必须是同一条逻辑

| 触发 | 入口 | 结果 |
|---|---|---|
| 启动时发现 `LastRegistered != current` | §3.6 静默检查 + 3875 | 用户确认后重做登记 |
| 用户在设置页点按钮 | §2.7 | 无条件重做登记（幂等） |
| 用户在开始菜单点了一个**旧**快捷方式 | 旧 `.lnk` 指向不存在的 exe → Windows 报「找不到」 | 无自动修复（我们不在那条路径上）。文档提示用户从新目录启动一次，由 §3.6 修正；或点设置页按钮。 |

---

## 6. `install.cmd` / `install.ps1` 的新职责

### 6.1 从载荷里移除

| 文件 | v1.4.4 起 |
|---|---|
| `installer\install.cmd` | **不再放进 SFX 载荷**（`build.ps1:37-38` 的两行拷贝删除）。保留在仓库里，用途见 §6.2。 |
| `installer\install.ps1` | 同上。 |
| `installer\sfx-config.txt` | 删除 `RunProgram="install.cmd"` 一行；把注释改成「官方存根不解析 RunProgram，安装后的入口由程序首启询问创建」。`Title` / `BeginPrompt` / `Progress` / `InstallPath` 保留（前三者生效，`InstallPath` 只作为默认路径提示）。 |

**理由**：① 官方存根不执行它，留着只会误导使用者与未来的维护者；② 「包内带一个会改注册表的脚本」正是杀软给出 grayware 判断的特征之一；③ 移除后载荷里不再有「清单外的文件」，`SHA256SUMS.txt` 与载荷重新一致（§7.3）。

### 6.2 新职责：手动入口 + 等价物 + 验证工具

保留 `installer\install.ps1`，但把它**重新定位**为：

1. **手动入口**：用户从解压出来的目录里手工运行它（或在命令行/脚本部署中使用），得到与首启询问「选是」**完全相同**的结果。参数保持现有签名，语义收紧：

   ```powershell
   pwsh -File installer\install.ps1 -InstallDir "D:\7-Zip Password Vault"
   pwsh -File installer\install.ps1 -Quiet          # 不打印摘要
   pwsh -File installer\install.ps1 -NoShortcuts    # 只登记卸载项
   # 新增（可选）：-NoUninstall （只创建快捷方式）
   # 新增（可选）：-WhatIf      （只打印将写入什么，不动手）
   ```

2. **首启逻辑的等价物（single source of truth 的**文档**版本，不是代码版本）**：两条路径的契约由本文 §3.2 / §3.3 唯一定义；`PasswordVaultSetup.h` 与 `install.ps1` 顶部的常量表都要注释指向本文件。实现时下列**必须一致**：
   - 键名 `...\Uninstall\7ZipPasswordVault` 与全部值名/类型；
   - `.lnk` 名称 `7-Zip Password Vault.lnk`、Target / WorkingDirectory / IconLocation；
   - 「已存在即跳过」的幂等语义；
   - 失败时**不**写成功标志（`FirstRunShortcuts` / `FirstRunUninstall`）。
3. **验证工具**：发布前用它在干净账户（或 `-WhatIf`）里跑一次，然后与程序首启「选是」之后的状态做**逐值比对**（§10 的 V3）。这是防止两处逻辑漂移的最便宜手段。

### 6.3 分工边界（避免两处逻辑不一致）

| 关注点 | 唯一归属 |
|---|---|
| 契约（键名、值名、类型、.lnk 属性） | 本文档 §3.2 / §3.3（唯一来源） |
| 运行时机 | 程序（首启 / 漂移 / 设置页按钮）；脚本只在**手动**执行时运行 |
| 幂等与冲突判定（F2/F8） | 程序实现；脚本**简化**为「已存在就跳过并提示」，不做接管（手工入口的复杂度不值得） |
| 「当前目录」的来源 | 永远是 exe 所在目录 / `$PSScriptRoot`；**不**从注册表推断 |
| 卸载 | `tools\uninstall.ps1` 独有，程序不实现卸载 |
| 语言文案 | Lang 文件（程序）与脚本内英文提示（脚本）分开：脚本是给动手能力强的用户/运维看的，不要求本地化 |

**明确的禁止项**：
- 程序**不得**在首启流程里调用 `install.cmd` / `install.ps1`（ADR-003）。
- `install.ps1` **不得**被 SFX 自动执行（§6.1）。
- 两者**不得**各自发明新的注册表值（新增值必须先改本文档）。

### 6.4 验收条件（§6）

- [ ] `setup.exe` 解压后的目录里**没有** `install.cmd` / `install.ps1`。
- [ ] `SHA256SUMS.txt` 的条目数 == 目录内文件数 − 1。
- [ ] 手工运行 `pwsh -File installer\install.ps1` 后，`HKCU` 状态与程序首启「选是」逐值一致（除脚本不写 `FirstRunAsk`，见下）。
- [ ] `sfx-config.txt` 里不再出现 `RunProgram`。

> 关于 `FirstRunAsk`：脚本是手工入口，不应当（也不需要）代表用户回答首启问题。约定：脚本写 `FirstRunShortcuts` / `FirstRunUninstall` / `InstallLocation` / `LastRegistered`，**不写** `FirstRunAsk`。这样「手工跑过脚本」的用户下次主动启动程序时仍会被问一次——但此时程序会发现快捷方式已存在且正确，于是幂等地跳过并只补写 `FirstRunAsk=1`。这个顺序是有意的：手工入口不替用户做决定，但也不重复劳动。

---

## 7. 鉴权与安全边界

### 7.1 为什么不写 HKLM、为什么不需要管理员

- **最低权限原则**：快捷方式与「应用和功能」条目都是**当前用户**的资源，写在 `HKCU` 即可生效；`HKLM` 版本只会带来提权需求和跨用户副作用。
- **便携包的现实**：用户可能把目录放在 U 盘、`D:\Tools`、网盘同步目录。要求管理员才能登记，会让大多数便携用法直接放弃这个功能。
- **避免「伪装成安装程序」**：一个未签名、改自 7-Zip 的 exe 弹 UAC，是最容易被误判为恶意行为的组合（`BUILD.md` / `docs\vt-false-positive-report.md` 已记录当前的 `Wacatac.C!ml` 误报）。首启流程全程零提权、零 `cmd.exe`、零 `powershell.exe` 子进程。
- **不抢官方 7-Zip 的机器级位置**：`HKLM\SOFTWARE\7-Zip`、`HKLM\SOFTWARE\Classes\7-Zip.*` 可能属于用户已装的官方 7-Zip。本设计明确不碰。
- **例外（既有，不属于首启）**：设置页 `System` 页签的文件关联 / 右键菜单登记仍可能写 `HKLM` 并需要管理员（`RegistryAssociations.cpp`、`uninstall.ps1 -AllUsers`）。首启询问**不**触发任何这些操作——这是刻意的：首启只做两件小事，文件关联留给用户在设置页主动决定。

### 7.2 卸载器如何仍然只删属于本包的文件

沿用并强化现有机制，不新增「靠名字删」的路径：

1. **哈希清单是唯一判据**：`<InstallDir>\SHA256SUMS.txt` 逐文件 SHA-256 比对，只有哈希匹配的文件才删除（`uninstall.ps1:392-431`）。
2. **路径必须落在程序目录内**：`Test-InsideDir`（`uninstall.ps1:59-67`，要求目录边界，`C:\7-Zip-old` 不算 `C:\7-Zip`）；清单里含 `..` / 盘符 / 根路径的条目直接拒绝（`:408-410`）。
3. **同名不同哈希 = 别人的**：共享目录里官方 7-Zip 的同名文件、用户自己放的文件一律保留并列出（`:447-451`，v1.4.3 已有测试覆盖）。
4. **注册表按归属判定**：`7-Zip.*` 文件类型键与 CLSID 的 `InprocServer32` 必须指向本目录才删（`:248-279`）；卸载项只在 `InstallLocation` 指向本目录时才删（`:236`）。
5. **不删数据**：密码库默认保留（`-KeepVault` 语义，`:341-351`），程序目录里还有非本包文件时整个目录保留（`:496-505`）。
6. **新增（本设计要求）**：
   - 卸载时若发现 **`FirstRunShortcuts=1` 但快捷方式已不在**（用户手工删过），不报错，只记 `[skip]`；
   - 卸载时若 `HKCU\...\Uninstall\7ZipPasswordVault` 的 `InstallLocation` 指向别的目录，保持现状「跳过并提示」（`:238`），**不**按 `DisplayName` 猜测。

### 7.3 载荷与清单必须重新一致

现状：`tests\deploy.ps1` 在写完 `SHA256SUMS.txt` **之后**，`installer\build.ps1:37-38` 才把 `install.cmd` / `install.ps1` 加进载荷 → 载荷 114 个文件、清单 111 条，且 `uninstall.ps1` 里有一段**专门补删**这两个文件的特判（`:432-439`）。

v1.4.4 的修法（二选一，推荐 A）：

- **A（推荐）**：从载荷移除这两个脚本（§6.1）→ 114 − 2 = 112 个文件，其中 `SHA256SUMS.txt` 不含自身 ⇒ 清单 111 条（与今天相同的条数，但**不再有清单外的文件**）；`uninstall.ps1` 里针对 `install.ps1` / `install.cmd` 的补删段可以保留（兼容老版本包），但不再是必需品。
- **B**：仍要放进载荷时，`build.ps1` 必须在加入之后**重新生成** `SHA256SUMS.txt`（或把这两个文件也写进清单再打包）。

无论哪种，验收标准是：**解压后 `SHA256SUMS.txt` 的条目集合 == 目录内文件集合 − {`SHA256SUMS.txt`}**。这是「卸载只删属于本包的文件」这一承诺的前提；清单不全意味着那些文件永不被卸载器删除（v1.4.3 已经踩过一次这个坑：`SHA256SUMS.txt` 与 `uninstall.cmd` 残留导致目录删不掉，见 `docs\release-v1.4.3.md:7-10`）。

### 7.4 用户选「否」时系统里应保持的状态

| 位置 | 状态 |
|---|---|
| 开始菜单 `%APPDATA%\...\Programs` | 无本程序的 `.lnk` |
| 桌面（每用户） | 无本程序的 `.lnk` |
| `HKCU\...\Uninstall\7ZipPasswordVault` | **不存在** |
| `HKLM` | 未被触碰（本设计从不写） |
| `HKCU\Software\7-Zip\PasswordVault` | 只有 `FirstRunAsk=1`（表示「问过了，用户说不要」） |
| `HKCU\Software\Classes` | 未被触碰（不做关联） |
| 程序目录 | 完整，包含 `uninstall.cmd` / `uninstall.ps1` / `SHA256SUMS.txt`（用户随时可以手工卸载） |
| 密码库 | 按既定规则（可写则程序目录，否则 `%APPDATA%\7-Zip`） |
| 网络 / 自启动 | 无任何添加 |

也就是说：**选「否」等价于「今天的便携版」**——除了 `HKCU` 里多了一个「别再问」的标志。用户可以自己双击 `7zFM.exe`、可以右键 `7zFM.exe`「发送到 → 桌面快捷方式」、可以随时运行 `uninstall.cmd`。文档应把这三条写清楚，让「选否」不是一个死胡同。

### 7.5 验收条件（§7）

- [ ] 首启「选是」全过程无 UAC 提示、无 `cmd.exe` / `powershell.exe` / `wscript.exe` 子进程（可用进程监视核对）。
- [ ] 首启流程不产生任何网络连接。
- [ ] 解压后的目录里 `SHA256SUMS.txt` 覆盖除自身外的所有文件。
- [ ] 选「否」后 `HKLM` 与 `HKCU\Software\Classes` 无变化（用 `reg export` 前后比对）。
- [ ] 在共享目录（内含官方 7-Zip 的同名文件）里运行卸载器：官方文件全部保留。

---

## 8. 语言字符串清单（从 3868 起）

**本设计只列清单，不修改 `Lang\*.txt`。** 实施时按下面的 id 追加到 `Lang\en.txt`、`Lang\zh-cn.txt`、`Lang\zh-tw.txt` 的 **3828 块尾部**（即 id 3868 起），并在 `CPP\7zip\UI\FileManager\PasswordDialogRes.h` 里加同名 `#define`。

格式说明（现状约束，别踩坑）：

- 语言文件是**位置式**：数字行是块起点，块内每个非数字行顺序取一个 id；块尾的**空行**就是「未使用的 id」。
- 3828 块目前只用到 3867，其后到 3900 之间都是空行 → **3868–3899 可以安全使用**，只是要保证在 3900 之前正好补齐（不足的部分**继续留空行**，多余的空行不能留）。
- `\n` 是换行转义（见 3865 / 3837 的既有写法）。
- `{0}` / `{1}` 由程序做 `Replace` 填充（`PasswordVault.cpp:172-183`、`PasswordVaultUi.cpp:76-91`）。
- 缺失字符串时 `LangString()` 返回空串 → 程序回落到内置**中文**兜底（`PasswordVault.cpp:47-57`），所以每个 id 的三份语言文件必须一起加，否则英文界面会显示中文。

| id | 用途 | 中文（zh-cn / zh-tw 同义，繁简按各自用字） | English (en) | 为什么需要 |
|---|---|---|---|---|
| 3868 | 首启询问 / 设置页操作的消息框标题 | `首次启动设置` | `First start setup` | 3868 起的第一条；现有 caption 是产品名（3828），首启询问属于「设置」语境，给一个更准确的标题，避免用户以为这是密码库出错的提示 |
| 3869 | 首启询问正文（`{0}` = 程序目录） | `程序目录：\n{0}\n\n要创建开始菜单 / 桌面快捷方式，并登记到「应用和功能」吗？\n\n「是」创建（只写入当前用户，不需要管理员）\n「否」不创建，以后不再询问\n「取消」以后再问` | `Program folder:\n{0}\n\nCreate Start Menu / Desktop shortcuts and add an entry to Apps & features?\n\nYes - create them (current user only, no administrator needed)\nNo - do not create them and do not ask again\nCancel - ask again later` | 核心文案：把三个按钮的效果写在问题里，用户不必猜「以后再说」是什么意思 |
| 3870 | 成功提示：已创建的内容与后续操作 | `已创建开始菜单和桌面快捷方式，并在「应用和功能」里登记了本程序。\n\n卸载时可以像普通程序一样从「应用和功能」卸载。` | `Start Menu and Desktop shortcuts were created and the program was registered in Apps & features.\n\nYou can remove it later from Apps & features like any other program.` | 用户需要知道「刚才做了什么、以后怎么撤销」；也顺带说明这不是「安装」 |
| 3871 | 部分失败提示（`{0}` = 错误详情） | `一部分入口没有创建成功：\n\n{0}\n\n你可以随时在「工具 → 选项 → 密码管理器」里重试。` | `Some of the entries could not be created:\n\n{0}\n\nYou can try again in Tools -> Options -> Password manager.` | §2.4 规定失败也要写状态；必须给出**补救路径**，否则用户只能重装 |
| 3872 | 只读 / 不适合登记时的说明（`{0}` = 程序目录，`{1}` = 密码库将使用的位置） | `当前目录不适合登记快捷方式与卸载项：\n{0}\n\n原因：该目录不可写（或位于可移动磁盘 / 网络位置）。\n\n密码库将存放在：\n{1}\n\n若希望把程序当安装版使用，请先把它移动到你自己的可写目录，再运行一次本程序。` | `This folder is not suitable for shortcuts and an uninstall entry:\n{0}\n\nIt is not writable (or it is on a removable disk / network location).\n\nThe password vault will be stored in:\n{1}\n\nTo use the program like an installed one, move it to a writable folder of your own and start it again.` | §3.5 的 G1–G5/G7 要「告知而不是静默跳过」；同时必须说清密码库落到哪里（§3.6 第 2 条），这是只读目录下最反直觉的一点 |
| 3873 | 设置页按钮：创建入口 | `创建快捷方式并登记卸载(&S)...` | `Create shortcuts and register uninstall(&S)...` | §2.7 的手动补做入口；按钮文字必须能自解释（用户不会去读文档） |
| 3874 | 【可选】目录由「不适合登记」变为「可登记」后的温和提示 | `这个目录现在可以登记了。要创建快捷方式并在「应用和功能」里登记卸载吗？` | `This folder can be registered now. Create the shortcuts and the uninstall entry?` | §3.5 / §2.5 S2 状态：先解压到只读目录、之后拷到可写目录的用户，否则永远不会被再问。只在 `FirstRunSkipped` 存在且当前目录可登记时弹一次 |
| 3875 | 目录已被移动的提示（`{0}` = 记录的旧目录，`{1}` = 当前目录） | `程序目录已经改变：\n\n上次登记：{0}\n当前目录：{1}\n\n要更新快捷方式和「应用和功能」里的卸载项，让它们指向当前目录吗？` | `The program folder has changed:\n\nLast registered: {0}\nCurrent folder: {1}\n\nUpdate the shortcuts and the Apps & features entry so they point to the current folder?` | §3.4 F7 / §3.6 的漂移提示；这是便携包最常见的操作（拷贝/移动目录） |
| 3876 | 路径过长 / 写入失败的补充说明（`{0}` = 具体错误） | `无法在这里创建快捷方式或卸载项：\n\n{0}\n\n可以尝试把程序放到更短的路径（例如 D:\\7-Zip Password Vault）后重试。` | `Shortcuts or the uninstall entry cannot be created here:\n\n{0}\n\nTry a shorter path (for example D:\\7-Zip Password Vault) and try again.` | §3.4 F10 / F4 的用户可见解释；`{0}` 用 `NError::MyFormatMessage` 填系统文本，与既有错误提示风格一致 |
| 3877 | 接管询问（`{0}` = 另一份拷贝的目录） | `快捷方式或「应用和功能」里的条目已经指向另一份拷贝：\n\n{0}\n\n要让它们指向当前的目录吗？（另一份拷贝的程序文件不会被删除）` | `A shortcut or the Apps & features entry already points to another copy:\n\n{0}\n\nPoint them to the current folder instead? (The other copy's program files are not deleted.)` | §3.4 F2 / F8 的「接管」分支必须得到用户同意；明确写出「不删另一份的文件」，否则用户会以为要丢掉那份拷贝 |

共 10 条（3868–3877）。**条数与 id 必须一一对应**：语言文件是位置式的，少写一条就会让后面的字符串全部错位，表现为「按钮上出现上一个对话框的文字」。

已占用与边界：3867 是当前最后一个已用 id（`IDT_PASSWORD_USING_ROAMING`）；**不要**复用 3828–3867，也不要在 3900 之后插值（那是「已用时间 / 剩余时间」等解压进度的块）。若要再加字符串，从 3878 继续，最多到 3899。

`zh-tw` 的用字与 `zh-cn` 不同（例如「档案」「捷径」「注册」），实施时需按繁体习惯单独写一遍，不是简单转换。

---

## 9. 验证清单（发布前）

**不允许**在自动测试里写 `HKCU` 或启动 GUI 的约束下，本设计推荐的做法是：

| # | 方式 | 覆盖 |
|---|---|---|
| V1 | 手工验证清单（§2.8 / §3.7 / §6.4 / §7.5），在**专用测试账户**里跑（该账户的 `HKCU` 是可丢弃的） | 全部流程与失败模式 |
| V2 | `tests\uninstall-test.ps1` 扩展 | 卸载器新增分支：`FirstRunShortcuts=1` 但快捷方式已删（幂等跳过）、`InstallLocation` 指向别处（跳过并提示）、`SHA256SUMS.txt` 覆盖完整性（条目数 == 文件数 − 1） |
| V3 | `installer\install.ps1` 与程序首启的**逐值比对**：在测试账户里先跑脚本、导出注册表；还原后走程序首启「选是」、再导出；用 `Compare-Object` 比较（允许 `FirstRunAsk` 与 `InstallDate` 差异） | §6.3 的「两处逻辑不一致」 |
| V4 | `tests\check-labels.ps1`（en / zh-cn / zh-tw） | 新增的 10 条字符串与设置页新按钮是否被截断（3868 / 3869 / 3872 这种长文案放在消息框里没问题，但**设置页按钮 3873 必须过这一关**） |
| V5 | 静态检查：解压 `setup.exe` 后核对「`install.cmd` / `install.ps1` 不存在、清单覆盖完整」 | §6.4 / §7.3 |
| V6 | 发布包重扫 VirusTotal，与上一版对比；把结果写进发布说明 | 移除脚本载荷后是否降低了检测数（预计改善，但**不承诺**：`7zFM.exe` / `7zG.exe` 的签名缺失是主因） |

---

## 10. 已知限制

1. **未签名**：`7zFM.exe` / `7zG.exe` 仍会保留官方 `VERSIONINFO` 却没有签名。首启流程不改变这一点；要真正降低误报，需要代码签名证书（`BUILD.md` §5 已记录）。本设计能做的只是**不再给杀软额外的脚本特征**。
2. **卸载入口可被改写**：`UninstallString` 指向 `%InstallDir%\uninstall.cmd`，而该目录用户可写（`docs\release-v1.4.3.md:49-50` 已列为已知限制）。本设计不改变它；缓解手段仍是「装到受保护目录」或将来改为签名安装器（§11）。
3. **多用户机器**：首启状态与卸载项是每用户的（`HKCU`）；另一个账户看不到条目，也不会共享快捷方式（`CSIDL_COMMON_*` 未使用）。
4. **两份拷贝**：同一键名只能登记一份；第二份会看到「接管/冲突」提示，需用户选择。
5. **「选否」不是死胡同但需要用户主动**：补救入口在设置页；`README.md` 必须写明。
6. **只读目录的密码库位置**：回落到 `%APPDATA%\7-Zip`，与「便携」的直觉相反；本设计只做提示，不改变默认位置优先级（ADR 未覆盖此议题，见 §11）。
7. **`EstimatedSize` 的精度**：按目录遍历估算，遍历失败时写 0；不影响功能。

---

## 11. 演进路线

| 阶段 | 内容 | 前置条件 |
|---|---|---|
| v1.4.4（本设计） | 纯解压 SFX + 程序首启询问（HKCU）+ 设置页补做按钮 + 卸载器适配 + 清单一致 | 无 |
| 下一版 | 代码签名（EV 或 OV 证书）→ 重扫 VT、更新 `BUILD.md` 与误报说明 | 需要证书预算 |
| 再往后 | 评估 Inno Setup：真正的安装器可以做到「目录选择 + 卸载项 + 关联 + 无需脚本 + 静默安装参数」，且能与签名配合；届时首启询问可退化为「便携模式的兜底」 | 证书 + 工具链评估 |
| 独立议题（不在本设计内） | 密码库默认位置是否改为「始终 `%APPDATA%`」或「首次询问放哪里」：涉及加密数据位置与便携语义，需要单独 ADR | 用户反馈 |

---

## 附：术语与路径速查

| 名词 | 值 |
|---|---|
| 设置 / 首启状态键 | `HKCU\Software\7-Zip\PasswordVault` |
| 卸载项键 | `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\7ZipPasswordVault` |
| 开始菜单快捷方式 | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\7-Zip Password Vault.lnk` |
| 桌面快捷方式 | `%USERPROFILE%\Desktop\7-Zip Password Vault.lnk`（= `CSIDL_DESKTOPDIRECTORY`） |
| 默认密码库 | `<InstallDir>\7zPasswordVault.dat`，不可写时 `%APPDATA%\7-Zip\7zPasswordVault.dat` |
| 卸载入口 | `<InstallDir>\uninstall.cmd`（→ `tools\uninstall.ps1` 的副本） |
| 归属判据 | `<InstallDir>\SHA256SUMS.txt` 的 SHA-256 逐文件比对 |
