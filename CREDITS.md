# Credits · 致谢

StageCast 是一个独立发布的项目，但它并非从零开始：界面骨架、Metal 渲染管线与 iOS/Android 采集链路最初来自 **ScreenPresenter**，之后在此基础上重做图标、界面、多设备布局与浮窗等能力。所有借鉴与依赖都在这里标注。

StageCast is an independent project, but it did not start from nothing: the AppKit shell, the Metal render pipeline and the capture paths began as **ScreenPresenter**, then were rebuilt with a new icon, new UI, multi-device layouts and floating windows. Everything borrowed or bundled is credited here.

## 衍生的原始项目 / Derived from

| 项目 | 作者 | 许可证 | 说明 |
|---|---|---|---|
| [ScreenPresenter](https://github.com/HapticTide/ScreenPresenter) | Sun / HapticTide | MIT | StageCast 的初始代码库，原始版权声明保留在 [LICENSE](LICENSE) 中。The original code base of StageCast; its copyright notice is retained in [LICENSE](LICENSE). |

## 随包分发的工具 / Bundled tools

| 组件 | 作者 | 许可证 | 说明 |
|---|---|---|---|
| [scrcpy](https://github.com/Genymobile/scrcpy) 4.0 scrcpy-server | Genymobile and contributors | Apache-2.0 | 以原样 jar 形式随包分发（StageCast/Resources/Tools/scrcpy-server）；Android 控制协议按 control_msg.c 实现。 |
| [Android platform-tools](https://developer.android.com/tools/releases/platform-tools) (adb) | Google LLC | Apache-2.0 | 随包分发（StageCast/Resources/Tools/platform-tools/adb），用于设备发现、端口转发与 shell 命令。 |

## 依赖的库 / Libraries

| 组件 | 作者 | 许可证 | 说明 |
|---|---|---|---|
| [Sparkle](https://github.com/sparkle-project/Sparkle) 2.9.1 | Sparkle Project | MIT | 应用更新框架。 |
| [swift-opus](https://github.com/alta/swift-opus) 0.0.2 | Alta Software | BSD-3-Clause | Opus 音频解码封装。 |
| [libopus / Copus](https://github.com/xiph/opus) | Xiph.Org Foundation | BSD-3-Clause | Opus 编解码实现（经 swift-opus 引入）。 |
| [FBDeviceControlKit](https://github.com/facebook/idb) / FBDeviceControl | Meta Platforms, Inc. | MIT | 本地 vendored Swift 包（FBDeviceControlKit/），用于 iOS 设备发现。 |

## 设计与素材 / Design and assets

- 界面图标使用 Apple SF Symbols，遵循 Apple 的 SF Symbols 使用条款；SF Symbols 是 Apple Inc. 的商标。
- 设备边框（刘海、灵动岛、打孔、侧键、圆角）均为本项目按公开尺寸参数用 Core Graphics 绘制的示意图形，不代表厂商官方外观。
- 设备型号名称（iPhone、OnePlus、Xiaomi 等）为其各自所有者的商标，仅用于说明兼容性。

## 反馈 / Feedback

如果上述标注有遗漏或错误，请开 issue，我们会尽快更正。

If anything above is missing or wrong, please open an issue and we will fix it.
