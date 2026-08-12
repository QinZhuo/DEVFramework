# 项目约定

## 图片识别
- 本会话主模型为纯文本 DeepSeek，无法直接看图。
- 当需要识别图片/截图/视觉内容时，必须通过 Task 工具委派给 `vision` 子代理（由 MiMo V2.5 多模态模型驱动），将图片路径传给子代理，再由子代理返回文字描述。
- 不要自己尝试"读懂"图片内容，一律交给 `vision` 子代理。

## PCG 程序化生成（addons/DEVFramework/PCG/）
- 涉及生成类功能一律优先使用框架 `PCG` 模块（`PCGTool` + 各种 `*Def` 配置），不要从零手写算法。
- **配置驱动**：生成参数全部做成 `.tres` 资源（Def），代码只负责调用 `PCGTool`，不硬编码生成参数。
- **Seed 可复现**：所有生成都从 `PCGTool.make_rng(seed)` 派生，同一 Def + 同一种子必复现；存档用 seed + 增量改动（`ChunkedWorld.save_data/load_data`）。
- 常用入口：
  - 2D 网格 `PCGTool.generate_grid(def, rng)`（8 种算法，含 WFC 固定格）
  - 3D 体素 `PCGTool.generate_grid_3d(def, rng)`（地表/洞穴/3D WFC）
  - 管线 `PCGTool.generate(pcg_def, seed)`（地形→群系→河流→道路→资源点→战利品）
  - 分块世界 `ChunkedWorld` / `ChunkedWorld3D`（无限世界）
- 详细用法见 `addons/DEVFramework/PCG/Readme.md`；演示场景在 `Scenes/PCG/`。
