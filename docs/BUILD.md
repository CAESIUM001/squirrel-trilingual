# 从源码构建

## 组成

- `lua/en_gloss.lua`：英文词表查询、义项选取，以及法语选取与 Rime 当前输入的衔接。
- `frontend/source/`：基于官方 Squirrel 1.1.2 的完整前端源码导出，含三行面板与本机翻译集成。
- `en_gloss/`：固定版本英文词表、索引及来源记录。
- `frontend/source/resources/glossary-fr.tsv`：5,000 条预生成法语词表。
- `translation-setup-src/`：独立语言包设置窗口。
- `installer/`：面向普通用户的原生安装辅助工具与 PKG 构建文件。
- `tests/`：Lua、安装工具、状态、真实 Rime 引擎、Apple 翻译和面板检查。

## 构建环境

前端发行版本面向 Apple Silicon。已验证的构建环境为 Xcode 26.2、Python 3 与 macOS 的签名／安装包工具。完整翻译运行环境需要 macOS 15 或更新版本。

前端构建脚本重编译本项目的 Squirrel 源码，并复用匹配的**官方 Squirrel 1.1.2** 运行库、插件和随包字典；该流程不会重新编译 librime 或 Sparkle。依赖源码及许可证保留在各自目录，提交与运行库校验值见 [`LOCAL-DEPENDENCIES.json`](../frontend/source/LOCAL-DEPENDENCIES.json)。

附带静态库和插件的完整许可证快照及来源范围见 [`third_party/sources.json`](../third_party/sources.json)。来源快照不表示已验证每个官方预编译组件与某个提交完全同源；该构建路径只重编译前端。

请先从 [Squirrel 官方 1.1.2 发布页](https://github.com/rime/squirrel/releases/tag/1.1.2)取得对应应用，解包到独立目录。以下命令中的路径应指向该官方 `Squirrel.app`，不是安装器或 DMG 文件。

## 前端

在本仓库根目录运行：

```sh
python3 frontend/source/scripts/build-local.py \
  --official-app "/path/to/official/Squirrel.app" \
  --configuration Release
```

产物：

```text
frontend/source/build/Build/Products/Release/Squirrel.app
```

脚本会校验官方版本、准备对应依赖、构建 arm64 前端、进行本地临时签名，并运行严格签名检查与 `--help` 动态链接检查。日志保存在 `frontend/source/build-local-release.log`。这不等同于 Developer ID 签名、公证或实际输入法安装。

构建脚本不复制到输入法目录，也不显式启用输入源；Xcode 本身可能刷新构建产物的 LaunchServices 记录。**不要对同一 bundle ID 的构建副本执行 `lsregister -u`**，它可能影响已安装输入法的注册。正式安装后，由安装器从实际安装路径调用 `--register-input-source` 并验证系统状态。

更详细的运行库准备和登记行为见 [`frontend/BUILD-LOCAL.md`](../frontend/BUILD-LOCAL.md)。

## 语言包设置工具

```sh
python3 translation-setup-src/build.py
```

生成仓库根目录下的 `Translation Setup.app`。构建只生成工具；下载模型必须由用户打开设置后主动发起并完成 Apple 的提示。该工具使用与前端相同的公开 Translation API。

## PKG 安装包

原生辅助工具、资源打包与安装失败恢复逻辑位于 `installer/`。完成前两步构建后，在仓库根目录明确传入应用路径：

```sh
python3 installer/build.py \
  --version 0.4.0 \
  --squirrel-app "frontend/source/build/Build/Products/Release/Squirrel.app" \
  --setup-app "Translation Setup.app" \
  --output "installer/dist"
```

输出 `installer/dist/Squirrel-Trilingual-0.4.0-macOS-arm64.pkg` 及对应校验文件。`--stage-only` 仅生成包载荷，便于检查后再打包。发布时还应汇总提供 `SHA256SUMS`。

安装包包含已构建前端、静态雾凇配置、扩展资源和设置工具，目标机器不依赖 Python。构建后应检查包内文件、脚本、签名状态及资源哈希，并先运行隔离安装、配置保留和失败恢复测试。

未提供 Apple Developer ID 证书时，输出为未签名 PKG，内含本地临时签名应用。不要将其描述为“已通过 Apple 公证”。

构建或 `--stage-only` 完成后，可验证全拼安装载荷：

```sh
python3 tests/native/full_pinyin.py \
  --payload "installer/build/root/Library/Application Support/Squirrel Trilingual/Current" \
  --results tests/native/full-pinyin-results.json
```

它在临时 home 中运行原生安装辅助工具，再用实际 `rime_deployer` 与 Rime 引擎检查全拼、九候选、英文选词、双 Shift 和随包法语资源。测试不注册输入源、不激活输入法，也不修改当前用户的配置。

安装器配置保留与失败恢复检查使用相同载荷：

```sh
python3 installer/tests/test_installer.py \
  --payload "installer/build/root/Library/Application Support/Squirrel Trilingual/Current"
```

该组 45 项检查仅操作临时 home，覆盖新装、个人数据保留、备份、重复安装、配置拒绝条件和故障恢复；不运行特权 PKG 安装或 GUI 激活。结果记录在 `installer/tests/results.json`。

对最终 PKG 执行解包检查：

```sh
python3 installer/tests/verify_package.py \
  "installer/dist/Squirrel-Trilingual-0.4.0-macOS-arm64.pkg" \
  "installer/build/verified-pkg-0.4.0"
```

第二个位置参数是新解包目录，运行前必须不存在。当前版本记录了 327 项检查：包结构与固定载荷路径、禁止应用搬移、全部清单资源哈希、解包应用／辅助工具严格签名、13 份第三方版权／许可文件，以及无需用户 Python 的安装脚本。结果写入 `installer/tests/package-results.json`，并记录最终包及辅助工具 SHA-256。它不会安装 PKG，也不表示包已签名或公证。




## 验证

基础检查：

```sh
lua tests/test_en_gloss.lua
python3 -m unittest discover -s tests -p 'test_*.py'
```

原生面板及真实模型检查，在仓库根目录运行：

```sh
python3 tests/native/ui/run.py --sources frontend/source/sources
python3 tests/native/translation-backend/run.py \
  --source frontend/source/sources/SquirrelSentenceTranslator.swift
python3 tests/native/translation-latency/run.py
```

真实模型检查需要已登录的桌面会话、已安装的中英／中法语言包，以及正常访问本机 Translation 服务的权限；它们不会请求模型下载。离屏面板检查不会启用输入法。

真实 Controller / Rime 集成检查需要一个含完整静态配置和编译结果的测试 Rime 目录及匹配前端运行库，请按 [`tests/native/sentence-selection/README.md`](../tests/native/sentence-selection/README.md)准备。运行时显式传入 `--frontend frontend/source`、`--work-root work`、`--source-user <测试配置目录>` 和 `--bundle <匹配 Squirrel.app>`。测试目录与个人用户词频库应保持分离。

检查范围和已记录结果见[验证说明](VALIDATION.md)。
