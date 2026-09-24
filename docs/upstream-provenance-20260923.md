# 7-Zip 26.03 上游输入核验（2026-09-23）

核验目标是 review4 冻结包中的 8 个未修改运行时文件及项目源码基线。参考来源为 [7-Zip 官方下载页](https://www.7-zip.org/download.html)指向的 [ip7z 官方 26.03 发布资产](https://github.com/ip7z/7zip/releases/expanded_assets/26.03)。以下 SHA-256 均与该发布页公布值一致：

| 官方资产 | SHA-256 | 用途 |
| --- | --- | --- |
| `7z2603-src.7z` | `41e2a7c0e9f838351c625e01f0f581a2188bb3dda10c8e0b4a852da26546ffe2` | 源码基线 |
| `7z2603-extra.7z` | `191894e6acb3647ffb69ce630479ff318523b2e2b9890aa7f05c1127c2e59b8f` | 官方 Extra 资产的辅助核验 |
| `7z2603-x64.exe` | `0859c524b8a63551848f0c246abddcb1d0b7b656b0fbfe879f8d85e61a9e6edd` | 运行时文件来源 |

从已核验的 x64 官方安装包解出 `7-zip.chm`、`7-zip.dll`、`7z.dll`、`7z.exe`、`descript.ion`、`History.txt`、`License.txt`、`readme.txt`。这 8 个文件与 `installer/release-inputs.json`、review4 候选目录和冻结 ZIP 解包内容逐文件 SHA-256 一致。官方源码归档含 1292 个文件：与工作区对应文件比对后，1270 个字节相同、22 个已修改、0 个缺失。改动路径列在 [原始核验结果](../tests/b/upstream-26.03-official/result.json) 中。`tests/verify-upstream.ps1` 可重复核验所有这些字节及 ZIP sidecar/包内清单。

`installer/release-inputs.json` 的 `upstreamVerified=true` 仅表示这些**上游输入**已核对；不表示本项目 GUI EXE 可由当前源码完全重现，也不表示下载 ZIP 可用签名认证发布者。独立的包哈希须经可信渠道公布。review4 `.build.json` 仍如实标记构建时源码树有未提交改动；升级回滚和公开发布状态另行记录。历史 review4 ZIP 不因本次核验而重写。
