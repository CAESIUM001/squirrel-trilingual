# 中英法离线翻译设置

`Translation Setup.app` 是独立设置助手，复用鼠须管前端中的同一份 Apple Translation 桥接和设置界面。它不注册输入法、不读取 Rime 用户数据。

正常打开后分别显示中英、中法语言包状态；点击对应的下载按钮才会请求 Apple 系统下载。每种语言都有“示例试译”和“刷新”按钮。所有翻译由系统在本机处理。

英文和法语使用独立翻译实例、内存缓存和取消状态；缺少法语模型不会影响已有的英文。候选词语和整句均可调用批量翻译接口，输入时不自动弹出下载提示。

实际翻译需要 macOS 15 或更新版本。构建保留 macOS 13 最低目标，较早系统仅显示版本提示。

## 构建

在仓库根目录运行：

```sh
python3 translation-setup-src/build.py
```

需要 Apple Silicon Mac 及含 Translation framework 的 Xcode SDK。构建脚本只编译和本机签名，不启动应用或下载模型。

## 下载后的引擎探针

```sh
"./Translation Setup.app/Contents/MacOS/TranslationSetup" --probe
"./Translation Setup.app/Contents/MacOS/TranslationSetup" --probe --language fr
"./Translation Setup.app/Contents/MacOS/TranslationSetup" --probe-batch --language fr
"./Translation Setup.app/Contents/MacOS/TranslationSetup" --probe-isolation
```

单句探针只翻译固定合成句子“明天下午我们一起去图书馆学习。”，批量探针使用“你好”“学习”“今天下午我們一起去圖書館”。隔离探针同时发起英文和法语请求，验证两者不会相互取消。向终端返回 JSON，不读取剪贴板或真实输入。成功退出码为 0；语言包未装为 3；翻译失败为 1；30 秒超时为 2。探针不请求模型下载。

源码采用 GPL-3.0-or-later，完整许可证见项目根目录 `LICENSE`。
