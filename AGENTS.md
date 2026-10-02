# 项目约定

## 图片识别
- 本会话主模型为纯文本 DeepSeek，无法直接看图。
- 当需要识别图片/截图/视觉内容时，必须通过 Task 工具委派给 `vision` 子代理（由 MiMo V2.5 多模态模型驱动），将图片路径传给子代理，再由子代理返回文字描述。
- 不要自己尝试"读懂"图片内容，一律交给 `vision` 子代理。

## PCG 3D 程序化生成（addons/DEVFramework/PCG/）
- 模块只服务 3D 模型世界生成。涉及生成类功能一律优先使用框架 `PCG` 模块（`PCGTool` + 各种 `*Def` 配置 + `PropGen`/`PropLayoutTool`），不要从零手写算法。
- **核心主张：一份生成数据，两种投影。** `SdfField` 只烘焙一次，`MeshExtractor` 出 lowpoly 网格、`VoxelExtractor` 出体素模型；要体素模型就设 `PropGenDef.voxel_res > 0`，**不要为体素另写一套生成器**。调用前检查 `PropBuild.has_voxel()`（扁长物体会退化）。
- **生成与布局分成两件事**：造型实现 `PropGen`（只写 SDF 组合、不碰世界坐标），摆放交给 `PropLayoutTool`（只认尺寸/朝向/地面高度），两者唯一交接面是 `PropBuild`。不要写"世界生成器"把两头揉在一起。
- **配置驱动**：生成参数全部做成 `.tres` 资源（Def），代码只负责调用，不硬编码生成参数。项目层的具体内容预设放 `Scripts/Gen/`（`SceneStylePresets.gd` 等），框架内不得出现 `res://Scripts|Assets|Scenes/` 路径。
- **Seed 可复现**：所有生成都从 `PCGTool.make_rng(seed)` 派生，同一 Def + 同一种子必复现；存档用 seed + 增量改动（`ChunkedWorld3D.save_data/load_data`、`WorldAssembler.save_data`）。**只设 seed，不要 `rng.state = rng.seed`**（会让 PCG32 序列退化）。
- 常用入口：
  - 3D 体素 `PCGTool.generate_grid_3d(def, rng)`（地表/洞穴/3D WFC）；大体积用 `await PCGTool.generate_grid_3d_async_progress(def, seed, cb)`
  - 3D 散布 `PCGTool.place_3d(placement_def, rng)`
  - 管线 `PCGTool.generate(pcg_def, seed)`（多生成器协同，各拿 `derive_seed` 派生的独立随机流）
  - 分块世界 `ChunkedWorld3D`（无限体素世界，跨块连续靠同种子 + offset）
  - 单体造型 `PropGenTool.bake(gen, def, seed)` / `ModelBaker.bake(graph, seed, {...})`
  - 摆放 `PropLayoutTool.solve(...)` + `PropLayoutTool.relax(...)`
- 详细用法见 `addons/DEVFramework/PCG/Readme.md`；演示场景在 `Scenes/PCG/`，测试在 `Scripts/Test/pcg/`（经 `test_pcg.gd` 接入 TestRunner）。
