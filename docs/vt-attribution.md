# VirusTotal 归属实验 / attribution experiment (v1.4.3, 2026-09-14)

「降低报毒」这件事必须先测量再改。这份文件是第一批测量结果：把 setup.exe 拆成几个部分分别提交
VirusTotal，看检测到底来自哪一层。工具是 `tests\vt-attrib.ps1`（可重复运行；探针只建在 `%TEMP%`，
从不发布）。

## 结果 / Results

| 对象 | 说明 | 检出 | 命中引擎 |
|------|------|------|----------|
| 官方 `7z.sfx` | 对照：未修改的官方存根 | **0/71** | 无 |
| 官方 `7z.exe` | 对照：包内未修改的命令行程序 | **0/71** | 无 |
| 官方 `7z.dll` | 对照 | **0/70** | 无 |
| **A0** 官方存根 + 我们现在的 sfx-config 文本 + 极小载荷 | 配置文本本身有没有影响？ | **0/69** | 无 |
| **A1** 完整载荷（`payload.7z`，含全部 114 个文件） | 归档内容本身有没有影响？ | **0/63** | 无 |
| **A2** 同上去掉 install/uninstall 脚本与哈希清单 | 「改系统的脚本」有没有影响？ | **0/63** | 无 |
| **A3** 真形状：存根 + 配置 + 载荷（但把两个重建的 exe 换成未被打标的官方程序） | 两个重建的 exe 贡献了多少？ | **2/70** | Elastic (high)、Microsoft `Trojan:Win32/Wacatac.B!ml` |
| 发布 `portable.zip` | 便携版 zip | **1/67** | Elastic (moderate) |
| 发布 `setup.exe` | 自解压安装器 | **3/70** | Microsoft `Wacatac.C!ml`、Elastic (high)、CrowdStrike `win/grayware_confidence_60%` |

## 结论 / What this means

1. **配置文本不是原因**：A0 = 0/69。`RunProgram` / `InstallPath` 这些明文键既不生效（存根不解析），
   也不影响检测数。
2. **载荷归档不是原因**：A1 = A2 = 0/63。压缩包里的脚本（install/uninstall、「按哈希删文件」的卸载器）
   单独拿出来是干净的；**脚本层的 A/B 优化空间因此非常有限**，不值得为它牺牲安全（例如把卸载器的
   哈希校验降级成存在性检查）。
3. **自解压壳本身就是原因**：A3 = 2/70 —— 用的是 **未被打标的官方程序** 做载荷，仍然被 Microsoft 与
   Elastic 打标。把「自解压 exe」这个形态去掉（改为发布 zip），就能拿回这 2 个检测。
4. **两个重建的 exe 还贡献约 1 个**（主要体现为 CrowdStrike 的 grayware）：A3(2/70) → 发布 setup.exe(3/70)
   的差量。这与「未签名却声称 Igor Pavlov / 7-Zip」的形态一致，因此改动方向是 **诚实身份**
   （已做：`CompanyName=Nomoziya`、`ProductName=7-Zip Password Vault`、版权里写明基于 7-Zip 的修改版）
   + 可选的代码签名。

## 因此采取的行动 / Actions taken from this data

| 行动 | 依据 |
|------|------|
| 发布说明与 README 不再声称安装器会建快捷方式/写卸载项（它做不到） | A0 + 存根反汇编：`7z.sfx` 不解析配置 |
| 快捷方式与「应用和功能」登记改由程序首启询问后自己完成（只写 HKCU，不用脚本解释器） | 去掉「解包后执行脚本」与「自解压壳」两个形态特征 |
| 保留 `portable.zip` 为默认下载 | 1/67，只被 Elastic 命中 |
| 诚实 VERSIONINFO + `asInvoker` manifest | A3 的差量指向「未签名却声称官方身份」 |
| 保留卸载器的哈希清单校验（不降级） | A2 证明脚本层不贡献检测，降级只有安全损失 |
| 构建可复现（`-Wl,--no-insert-timestamp`，两次构建哈希一致） | 微软按文件哈希判定，二进制稳定才能让一次误报提交覆盖多次发布 |

## 复测：改造后的结果 / Measured again after the changes

按上表的行动改完（诚实身份 + asInvoker + 可复现构建 + 去掉死配置 + 快捷方式改由程序首启询问）后，
同一套文件、同一工具链复测：

| 文件 | 改造前 | 改造后 |
|------|--------|--------|
| `portable.zip` | 1/67 (Elastic) | **0/68** ✅ |
| `setup.exe` | 3/70 (Microsoft、Elastic、CrowdStrike) | **2/70**（Microsoft 消失） |
| `7zFM.exe` | 2/70 (Microsoft、Elastic) | **1/69**（Elastic 消失） |
| `7zG.exe` | 1/70 (Microsoft `C!ml`) | **1/70**（变体变成 `B!ml`） |

合计 **7 → 4**，便携包已完全干净。剩下的三类与归属实验的预测一致（详见
`docs/vt-false-positive-report.md` 末尾一节）：两个重建 exe 的微软 ML 判定需要「每次构建提交误报 + 签名」，
`setup.exe` 的 Elastic/CrowdStrike 来自自解压壳本身（去掉 SFX 即可消除）。

## 复现方法 / How to reproduce

```powershell
pwsh -NoProfile -File tests\vt-attrib.ps1          # 重新提交探针并读回报告
pwsh -NoProfile -File tests\vt-attrib.ps1 -SkipUpload   # 只读已有报告
```

结果会写到 `%TEMP%\vt-attrib.json`，探针保留在 `%TEMP%\7zpw-attrib\` 供检查（可删除）。
注意：提交到 VirusTotal 的文件会公开，所以探针**绝不能**与发布产物同名或混放。
