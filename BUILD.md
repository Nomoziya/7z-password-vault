# 构建、验证与发布

项目长期采用未签名 portable ZIP。`internal-test` 与公开候选包使用相同的文件白名单，公开候选包还须通过来源、标准账户 GUI、升级回滚与干净提交门禁；具体结果以该包的 `.build.json` 和验收记录为准。

未签名发布策略见 [docs/signing-options.md](docs/signing-options.md)。不将自签名或独立哈希称为发布者身份验证；Defender 复核未做时如实标记。

## 构建

源码基线为仓库内 7-Zip 26.03。`installer/release-inputs.json` 固定源码归档与运行时输入的 SHA-256。上游 3 个官方资产摘要和 8 个运行时文件已核验，证据见 [上游来源记录](docs/upstream-provenance-20260923.md)。这只证明上游输入来源，不证明发布者身份；GUI 程序的可重编译性须另用干净检出与实际 EXE 哈希证明。

当前环境使用 MinGW-w64 GCC 16.2.0。编译日志及最终构建记录用于记录真实工具链，不能依据文件名推断工具链 ABI 或安全信誉。请在 x64 Windows 标准用户环境运行：

```powershell
# 从仓库根目录开始。每条命令成功后再继续。
New-Item -ItemType Directory -Force CPP/7zip/UI/FileManager/b/g, CPP/7zip/UI/GUI/b/g
Push-Location CPP/7zip/UI/FileManager
make -f ../../cmpl_gcc.mak -j4
Pop-Location
Push-Location CPP/7zip/UI/GUI
make -f ../../cmpl_gcc.mak -j4
Pop-Location
pwsh -NoProfile -File tests/password-vault-security-test.ps1
pwsh -NoProfile -File tests/release-gate-test.ps1
```

两个 GUI 目标使用 `-static` 链接 MinGW 运行库。组装候选包时 `tests/deploy.ps1` 会检查 PE 导入表，拒绝仍依赖未打包的 `libgcc_s_seh-1.dll`、`libstdc++-6.dll` 或 `libwinpthread-1.dll` 的 EXE；因此标准用户机器不必安装编译器或修改 `PATH`。

恢复功能的冻结候选与实际验证状态见 [恢复验证记录](docs/restore-final-validation.md)。在干净、已提交的工作区可运行 `pwsh -NoProfile -File tests/clean-build-test.ps1 -CandidateDir <候选目录>`：脚本从当前提交导出全新源码，分别构建两个 GUI 程序并核对与候选的 SHA-256，记录提交、工具链、源码归档与编译日志哈希。它不会复用已有目标文件；编译器的 `bin` 目录须已在 `PATH` 中。

原生安全测试编译并运行生产密码库代码，使用测试专属临时库和设置适配器，不读写用户真实密码库或注册表。涵盖 DPAPI、主密码、错误密码、取消、并发保存、篡改/损坏、故障注入和崩溃恢复，并独立验证真实 Windows ACL 拒绝。注入磁盘满不能替代真实满盘；`tests/real-disk-failure-test.ps1 -NativeTestExe <本轮原生测试程序>` 需要管理员令牌，在一次性 VHD 中验证真实满盘并清理该卷。两者均不代表物理断电验收。

测试包含独立真实 DPAPI 探针。若探针与生产加密同时失败，将报告准确 API/错误码及保存阶段，退出码为 78，分类 `ENVIRONMENT_BLOCKED`，绝不计为通过；DPAPI 前置条件正常但断言失败分类 `TEST_FAILURE`。符号链接夹具也必须实际创建成功，不能跳过。应在同一 Windows 普通用户环境重跑原脚本；隔离环境结果与普通用户结果分开保存。每次运行的编译日志、执行日志、输入哈希与 JSON 分类记录位于 `tests/b/native-run-<唯一ID>/`，历史日志路径不作为当前运行证据。

## 组装受控内测包

干净克隆只包含源码，不含 `dist` 内运行时或被忽略的上游压缩包。组装前需将已核验的官方 `7z2603-src.7z` 放在仓库根目录，并解压本项目已核验的 portable ZIP 作为种子目录，通过 `-SeedDir <种子目录>` 指定；也可使用完整的既有候选目录。官方资产出处和固定哈希见 `docs/upstream-provenance-20260923.md` 与 `installer/release-inputs.json`。两个 GUI EXE 由上述命令编译，另外八个运行时文件复用固定的上游输入；这不表示整个上游运行时已从本仓库重新编译。

```powershell
# 目标必须不存在；默认从 dist 递归选择最新的 internal-test ZIP。
$package = ./tests/deploy.ps1 -PackageDir "$PWD/dist/review-candidate"
./installer/build.ps1 -PackageDir $package -Version 26.03-review -InternalTest
```

部署每次使用新目录，只复制逐文件白名单，运行时输入必须匹配固定哈希。默认选择 `dist` 下修改时间最新的 `*internal-test.zip`，先验证独立哈希、压缩包路径白名单和包内清单，再解压到独立测试目录；也可用 `-SeedDir` 指定有完整清单的候选目录。找不到内测包、最新包损坏或编译输出缺失时明确失败，不生成空包，不回退到旧包。最终包只带 3 个语言文件，不含密码库及 `.bak`、转储、私钥、测试或安装/卸载脚本。

`core-test.ps1`、`ui-test.ps1` 使用相同的默认种子选择。执行 `tests/runtime-input-test.ps1` 验证缺包、最新包选择、哈希失败及路径穿越拒绝。`install-acceptance.ps1 -Package <zip>` 只检查 ZIP 独立哈希、文件集合和包内清单，不执行安装/卸载，也不代表历史的 67 项或 26 项测试。当前恢复功能的同哈希 GUI 程序已在独立标准用户 `cs` 桌面完成 436/436 验收；review4 的 393/393 是历史版本记录。

默认 ZIP 选择按文件修改时间排序，并不代表版本可信、开发者身份或签名有效。运行时脚本同时检查 ZIP/sidecar、`.build.json`、`.source.sha256`、包内清单的相互一致性，以及当前工作区冻结输入锁；显示源码清单与当前工作区的差异数量，允许以前的构建作为运行时种子。显式目录仅检查包内文件集合和哈希。上述记录均未签名，可一起被修改，因此这是**完整性校验，不是真实性或签名验证**，也不证明现有 EXE 可由当前源码重现。

运行时输入测试默认在 `tests/b/runtime-cases-<本次唯一ID>` 下创建所有夹具和解压目录，在 `finally` 中验证路径边界、名称及重解析点后只删除该目录；`-KeepArtifacts` 才保留。清理失败会报告失败，不扫描删除其他历史目录。

打包再次从空 staging 按白名单复制，验证包内 SHA256SUMS，解包后验证相同文件集合及内容。产出独立 `.sha256`、`.build.json` 和 `.sbom.json`（CycloneDX 文件组件清单）。SBOM 是包内文件清单，不是完整源代码依赖审计。

输入和产物冻结后不要覆盖同名 ZIP；变更内容使用新版本或新输出目录。

## 未签名公开发布门禁

公开版仍是 portable ZIP，不要求购买证书或签名。必须先独立核对上游源码归档和每个冻结运行时输入，更新 `installer/release-inputs.json` 的 `upstreamVerified`；把核验出处和原始证据保存到发布记录。打包脚本要求干净、已提交的源码树。还要在目标 Windows 11 Insider 标准用户中对**相同的两个候选 EXE 哈希**完成 GUI 测试，并用隔离加密库完成升级与回滚验收。旧版程序未必能打开新格式，回滚要验证预升级加密副本可用，不得覆盖唯一可用库。

`-EvidencePath` 的 JSON 至少包含下列字段；`upgradeRollback.evidencePath` 指向已保存的原始验收记录，其 SHA-256 也须匹配。`standardUserGui` 可从实际 `ui-test.ps1` 结果 JSON 取值，脚本哈希必须等于当前测试脚本。维护者应核对原始日志；JSON 自身不是独立真实性证明。

```json
{
  "upstreamVerified": true,
  "runtimeInputsVerified": true,
  "inputLockSha256": "<SHA-256 of verified release-inputs.json>",
  "sourceArchiveSha256": "<verified upstream source archive SHA-256>",
  "windows11InsiderStandardUser": "passed",
  "windows11InsiderBuild": "<actual OS build>",
  "standardUserAccount": "<actual standard-user account>",
  "standardUserGui": {
    "classification": "PASS", "exitCode": 0, "passed": 436, "failed": 0,
    "evidencePath": "<path to original ui-test result.json>",
    "evidenceSha256": "<result file SHA-256>",
    "scriptSha256": "<current ui-test.ps1 SHA-256>",
    "fileManagerSha256": "<candidate 7zFM.exe SHA-256>",
    "guiSha256": "<candidate 7zG.exe SHA-256>"
  },
  "upgradeRollback": {
    "result": "passed", "evidencePath": "<path to original result file>",
    "evidenceSha256": "<result file SHA-256>",
    "fileManagerSha256": "<candidate 7zFM.exe SHA-256>",
    "guiSha256": "<candidate 7zG.exe SHA-256>"
  },
  "securityScanStatus": "not-reviewed"
}
```

`securityScanStatus` 可为 `not-reviewed`、`scan-unavailable`、`clean` 或 `microsoft-cleared`。前两者不阻止未签名 ZIP 打包，但必须在发布说明中显著写明，不能称为扫描通过；已知检出不能放行。若填写 `clean` 或 `microsoft-cleared`，还须在 `files` 为两个 EXE 各提供唯一的同哈希记录、扫描时间、Defender 引擎版本和安全情报版本；微软复核还须提交编号。历史哈希和历史扫描不得移用。

```powershell
./installer/build.ps1 -PackageDir <verified-candidate> -Version <unique-version> -EvidencePath <verified-evidence.json>
```

未使用 `-InternalTest` 时，脚本检查上述来源、GUI、升级回滚及扫描状态字段，记录两个 EXE 的实际签名状态；不会要求或执行签名。产物 `.build.json` 记录验收文件哈希。`-WithSetup` 始终拒绝；脚本不上传文件、不关闭 Defender、不设置排除项。

## 产品安全边界

默认库在用户 APPDATA 目录。DPAPI v4 对整个序列化结构加密认证；主密码使用 AES-256-GCM / PBKDF2-HMAC-SHA256。缓存过期不等于自动锁定。内存清理和刷盘均有系统层面的限制，详见 README。

当前恢复候选在 Windows 11 Insider x64 build 26220 上，由 `Nomozi` 普通桌面和独立 `cs` 标准账户各完成 **436/436**；真实满盘、ACL 拒绝、跨账户 DPAPI 和干净源码重建均有记录，见[最新验收](docs/restore-final-validation.md)及 `docs/restore-dev4-evidence/`。review4 的 393/393 及其来源记录仅适用于历史程序。公开候选包须检查自身 `.build.json` 的 `sourceDirty=false`、确切提交号和同哈希验收记录。当前哈希安全扫描/复核未做时须如实声明；历史记录不能为本次构建背书。
