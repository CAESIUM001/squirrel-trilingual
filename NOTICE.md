# 来源、许可与致谢

鼠须管伴词（Squirrel Trilingual）是社区定制项目。它不属于 Rime、雾凇、青简或 Apple 官方产品，也不表示这些项目或公司对本项目提供背书。各名称与商标归相应权利人所有。

## 项目新增内容

Lua 扩展、翻译衔接、选词逻辑、安装与生成工具，以及本项目新增的前端改动：Copyright (c) 2026 rime-english-gloss contributors，按 **GPL-3.0-or-later** 提供。许可证全文见 [LICENSE](LICENSE)。再分发修改后的程序时，请保留来源、许可证及相应源码。

## 鼠须管与运行库

- **Squirrel / 鼠须管**：https://github.com/rime/squirrel 。前端基线为 1.1.2，提交 `876adebaf2f612951dcdca8a591de65401222b9a`。上游 GPL 许可证保留在 [`frontend/source/LICENSE.txt`](frontend/source/LICENSE.txt)。
- **librime**：https://github.com/rime/librime ，固定源码提交 `a251145d3aafa33871824a40bbec04c966bd8b56`，采用 BSD 3-Clause；原文见 [`frontend/source/librime/LICENSE`](frontend/source/librime/LICENSE)。
- **Sparkle**：https://github.com/sparkle-project/Sparkle ，固定提交 `41847a58cdef7506b257591fcca6f9495df591d4`。主许可证为 MIT，并包含外部组件的单独声明；全文见 [`frontend/source/Sparkle/LICENSE`](frontend/source/Sparkle/LICENSE)。

公开源码保留构建所需的上游代码、固定提交、公钥测试夹具和第三方许可证全文。为避免分发与本项目构建无关的历史二进制，未包含 Sparkle 上游 `Tests/Resources` 中的 13 个已编译测试归档；这些文件可从上述固定上游提交获取。

当前前端构建复用对应官方 Squirrel 1.1.2 运行库及插件。固定版本和二进制校验值记录在 [`LOCAL-DEPENDENCIES.json`](frontend/source/LOCAL-DEPENDENCIES.json)。各依赖的独立许可证继续适用，不因本项目采用 GPL 而被替换。

## 其他运行库与插件声明

官方运行库及插件涉及 glog、LevelDB、marisa-trie、OpenCC、yaml-cpp、Boost、Lua，以及 librime-lua、librime-octagram、librime-predict。补充的上游许可证全文位于 [`third_party/licenses/`](third_party/licenses/)，原始 URL、固定提交／版本和文件 SHA-256 记录在 [`third_party/sources.json`](third_party/sources.json)。这些声明也随二进制安装包提供。

来源范围需要区分：部分依赖的提交来自所保留 librime 源码的 gitlink，部分插件许可证是固定到不可变提交的上游快照。它们用于保留许可和来源，不证明复用的官方预编译二进制中的每个静态库或插件都来自完全相同的提交。二进制中的 Lua 版本串可确认为 5.4.6；其他未独立确认的对应关系已在来源清单中标注。该清单不应被解释为所有运行库均已从这些版本重新构建。

## 雾凇拼音与中文词源

**Rime Ice / 雾凇拼音**：https://github.com/iDvel/rime-ice ，上游使用 GPLv3。公开安装包采用静态雾凇全拼配置，并保留所携带文件的原始头部、版权与数据来源说明。

预生成法语词表的中文键来自静态 `cn_dicts/base.dict.yaml` 和 `cn_dicts/8105.dict.yaml`，并对补充日常词进行已有英文词表的中文键匹配。其上游基础词库注明华宇野风系统词库、[THUOCL](https://github.com/thunlp/THUOCL)、[现代汉语常用词表](https://gist.github.com/indiejoseph/eae09c673460aa0b56db)、[腾讯词向量](https://ai.tencent.com/ailab/nlp/zh/download.html)等来源，以及大量雾凇维护者的整理工作。单字表注明维基词典的通用规范汉字拼音索引与北京语言大学 25 亿字语料字频表。

完整选词规则、原始文件哈希和生成信息见 [`glossary-fr.provenance.json`](frontend/source/resources/glossary-fr.provenance.json) 与 [词表说明](frontend/source/resources/glossary-fr.README.md)。

## 青简英文词表

**Qingjian / 青简**：https://github.com/qingjian-team/qingjian 。英文词表固定在提交 `10e86493d8f1e59a7483c8afdf910d84bd0908a0`，包含 232,213 个词条，其中 9,872 个有第二义，按 GPL-3.0-or-later 使用。

上游说明该词表由模型离线生成；本项目保留其[原始说明](en_gloss/UPSTREAM-README.md)与[来源及校验值](en_gloss/provenance.json)。本项目重新实现了 Lua 查询和输入法衔接，没有使用青简输入引擎。词表可能存在错译或上下文不适配，可通过英文个人词表覆盖。

## 法语与 Apple Translation

5,000 条随包法语译文由已安装的 Apple 中法模型对公开静态词库预先生成，项目新增数据与生成工具随 GPL-3.0-or-later 源码提供。未使用个人输入历史、用户词频或私人数据库。它们是机器翻译结果，已做结构检查与有限的常用词抽查，未逐条人工审校。

实时英文和法语翻译使用 macOS 的公开 Translation 框架。Apple 模型、系统框架及其权利归 Apple 或相应权利人所有，不随本项目再分发；新设备上的模型下载由 Apple 的系统流程完成。
