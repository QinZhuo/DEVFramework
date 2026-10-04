# 项目约定

## 图片识别
- 本会话主模型为纯文本 DeepSeek，无法直接看图。
- 当需要识别图片/截图/视觉内容时，必须通过 Task 工具委派给 `vision` 子代理（由 MMo V2.5 多模态模型驱动），将图片路径传给子代理，再由子代理返回文字描述。
- 不要自己尝试"读懂"图片内容，一律交给 `vision` 子代理。

## PCG 已拆出
- 3D 程序化生成（`PCG/` 模块、`Scripts/Gen/` 道具库、`Assets/Def/PCG/`、`Scenes/PCG/`、`Scripts/Test/pcg/`、
  `gdextension/src/pcg_*` 原生类）已于 2026-10 从本仓库移除，改为独立插件项目：
  `d:\Work\GodotProject\PCG`（插件名 `pcg`，装入任何 Godot 项目即可用，零 autoload、零 `.tres` 依赖）。
- 已编译产物 `Native/dev.gdextension` 内**仍注册着 6 个 PCG 原生类**，但无任何 GDScript 调用方，不阻塞运行；
  重编译该扩展后自动消失。

## 程序化音频合成已移除
- 程序化音乐/音效合成已于 2026-10 从本仓库移除：`addons/DEVFramework/Audio/`（12 个合成 Def、`AudioSequence`、
  `AudioSynthTool`）、`Tool/DevAudioExamples.gd`（编曲配方）、`Tool/DevAudioTools.gd`（编辑器菜单）、
  `gdextension/src/audio_synth.*`（C++ 逐采样合成内核）、`Assets/Def/Audio/`（示例定义 + 已渲染 wav）、`Scenes/AudioDemo/`。
- 保留 `Tool/AudioTool.gd`，回归**通用音频管理**定位：播放任意 `AudioStream`、总线与效果链、WAV 保存、流查询、效果录音。
  框架不再做任何逐采样合成，音频处理一律用 Godot 内置 `AudioStreamPlayer` / `AudioEffect` / `AudioServer`。
- 已编译产物 `Native/dev.gdextension` 内**仍注册着 `AudioSynthEngine`**，但已无 GDScript 调用方，不阻塞运行；
  重编译该扩展后自动消失。
- 已渲染的示例成品 **未保留**：`Assets/Audio/Baked/` 及其中的 `.wav` 随模块一并移除。
  `Assets/Audio/AudioBusLayout.tres` 保留（项目总线布局，`project.godot` 仍引用）。
  ⚠ 合成代码已删除，wav 无法重建 —— 今后需要音频素材时用外部导入或引擎内置音源，不要指望本仓再生成。