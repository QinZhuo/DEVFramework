# PCG 程序化生成模块

DEV Framework 的**程序化内容生成**模块。遵循框架 **Def（静态配置 .tres）→ Entity（运行时结果）→ Tool（生成入口）** 三层模式：
所有生成参数都是可配置资源，同一 `seed` 必然复现同一结果，让「配置驱动 + 可复现」贯穿整个生成流程。

---

## 架构

```
addons/DEVFramework/PCG/
├── Def/                       # 生成配置（.tres 资源）
│   ├── PCGGeneratorDef.gd     # 生成器基类（管线单元，结果写入 ctx.output[key]）
│   ├── NoiseLayerDef.gd       # 噪声层（包装 Godot 内置 FastNoiseLite）
│   ├── GridGenDef.gd          # 网格生成器（噪声地形/细胞洞穴/迷宫/随机游走/BSP/WFC）
│   ├── PlacementDef.gd        # 散布放置器（泊松圆盘/抖动网格/均匀随机，可按网格剔除）
│   ├── ContentEntryDef.gd     # 加权表项（物品/事件/怪物等条目）
│   ├── ContentGenDef.gd       # 内容生成器（加权表/名字/马尔可夫/词缀）
│   ├── TileDef / TileSetDef   # WFC 瓦片与瓦片集
│   ├── BiomeEntryDef.gd       # 生物群系条目（高度/湿度/温度区间）
│   ├── BiomeMapDef.gd         # 生物群系图生成器（多层噪声映射）
│   └── PCGDef.gd              # 生成管线（组合多个生成器 + 共享 seed）
├── Entity/                    # 生成结果（运行时数据）
│   ├── GeneratedGrid.gd       # 2D 整数栅格（邻居/连通域/BFS 查询）
│   ├── BiomeMap.gd            # 群系图结果（格子索引 + 群系表）
│   ├── ChunkedWorld.gd        # 分块世界（seed+chunk 坐标确定性懒生成）
│   ├── WFCAnimator.gd         # WFC 过程动画器（分步观测-传播 + 波函数渲染）
│   └── PCGContext.gd          # 管线上下文（rng / 结果字典）
└── Tool/
    └── PCGTool.gd             # 统一入口（随机/噪声/网格/群系/散布/内容/管线/异步）
```

## 快速上手

### 1. 噪声层

```gdscript
var layer: NoiseLayerDef = load("res://Assets/Def/PCG/Noise_Perlin.tres")
var v := layer.get_value(x, y, seed)     # 采样（0..1），自动复制底层噪声并设置种子
var img := PCGTool.noise_image(layer, 256, 256, seed)   # 渲染灰度图
```

`NoiseLayerDef` 的 `noise` 属性就是 Godot 内置 `FastNoiseLite`（Resource），在 Inspector 里直接配
噪声类型 / 频率 / 分形 / 细胞噪声。本类叠加 归一化 / 反相 / 对比度 / 偏移 / 权重。

### 2. 网格生成（6 种算法）

```gdscript
var def: GridGenDef = load("res://Assets/Def/PCG/Grid_Cave.tres")
var grid := PCGTool.generate_grid(def, PCGTool.make_rng(seed))
grid.count(1)                          # 实体格数量
grid.components(1)                     # 实体连通域（BFS）
grid.get_cell(x, y)                    # 取格值（越界返回 -1）
```

| 类型 | 说明 |
|---|---|
| `NOISE_TERRAIN` | 噪声阈值地形（配 `noise_layer` + `threshold`） |
| `CELLULAR` | 细胞自动机洞穴（`cave_ratio` + `smooth_passes`） |
| `MAZE` | Prim 迷宫（`maze_loopiness` 0=完美迷宫） |
| `RANDOM_WALK` | 随机游走洞穴 |
| `BSP_ROOMS` | BSP 分区房间 + 走廊（`bsp_depth`/房间尺寸/走廊宽） |
| `WFC` | 波函数坍缩瓦片生成（配 `tile_set`，见下） |

### 3. WFC 瓦片生成

`TileSetDef` 由若干 `TileDef` 组成，每个瓦片用四方向 socket 标签描述连接（相邻接触侧 socket 必须相等）：

```gdscript
# 用 .tres 配置（参考 Assets/Def/PCG/TileSet_Nature.tres）
var wfc: GridGenDef = load("res://Assets/Def/PCG/Grid_WFC.tres")
wfc.type = GridGenDef.Type.WFC
var grid := PCGTool.generate_grid(wfc, PCGTool.make_rng(seed))
# 格值 = TileSetDef.tiles 的索引（可用 tiles[i].color 着色）
```

**高级功能**（GridGenDef 上可配）：

| 功能 | 参数 | 说明 |
|---|---|---|
| 固定格 | `PCGTool.generate_grid(def, rng, fixed)` / `wfc_fixed_cells` | 预置部分格子的瓦片索引，WFC 遵守并自动补全其余（支持玩家手绘一部分自动完成）。`fixed` key 支持 `Vector2i` / int(线性索引) / `"x,y"` |
| 回溯 | `wfc_max_backtracks` | 冲突时回退到上一次观测重新选择（默认 8），而非直接放弃 |
| 整体重试 | `wfc_retries` | 回溯仍冲突时用新随机流整体重新生成（默认 3） |

```gdscript
# 玩家手绘：固定几个水格，其余自动补全
var fixed := {Vector2i(10, 10): 2, Vector2i(20, 20): 2}
var grid := PCGTool.generate_grid(wfc, PCGTool.make_rng(seed), fixed)
```

**过程动画**（观测-传播可视化）：`WFCAnimator` 分步推进 WFC，随时渲染当前波函数
（未坍缩格 = 候选瓦片平均色，已确定格 = 瓦片色，矛盾格 = 红色）：

```gdscript
var anim := WFCAnimator.new()
anim.setup(wfc, PCGTool.make_rng(seed), fixed)
while not anim.step():                 # 每帧推进若干步
    my_texture_rect.texture = ImageTexture.create_from_image(anim.render_image())
print("完成，共 %d 步" % anim.step_count)
```

> WFC 在 GDScript 下选格是 O(n²)，建议尺寸 ≤ 64×64；>20000 格自动降级为加权随机填充。
> 大图请用 `generate_grid_async` 后台生成或给瓦片集设计强约束（道路/房屋）加速收敛。

### 4. 散布放置

```gdscript
var def: PlacementDef = load("res://Assets/Def/PCG/Placement_Poisson.tres")
var pts: PackedVector2Array = PCGTool.place(def, PCGTool.make_rng(seed))
```

三种模式：`POISSON_DISK` 泊松圆盘（点间距 >= min_distance 无重叠）/
`JITTER_GRID` 抖动网格 / `RANDOM_UNIFORM` 均匀随机。设置 `exclude_grid_key` 可剔除落在指定网格实体格上的点（管线内配合 `GridGenDef` 用）。

### 5. 内容生成（4 种模式）

```gdscript
var def: ContentGenDef = load("res://Assets/Def/PCG/Content_Names.tres")
var items: Array = PCGTool.generate_content(def, PCGTool.make_rng(seed))
```

| 模式 | 说明 |
|---|---|
| `WEIGHTED` | 加权表抽取（`entries: Array[ContentEntryDef]` 按 weight 有放回） |
| `NAME` | 名字合成（`prefixes` + `suffixes`） |
| `MARKOV` | 词级马尔可夫文本（`corpus` 句子语料，`markov_order`） |
| `AFFIX` | 词缀组合（`affix_bases` + 随机 `affix_prefixes/suffixes`，概率控制） |

### 6. 生物群系图

```gdscript
var def: BiomeMapDef = load("res://Assets/Def/PCG/Biome_World.tres")
var bm := PCGTool.generate_biome(def, PCGTool.make_rng(seed))
var b := bm.biome_at(x, y)      # 该格群系（BiomeEntryDef）
var img := PCGTool.biome_to_image(bm)   # 按群系颜色渲染
```

`BiomeMapDef` 用 高度/湿度/温度 三层噪声采样，映射到 `biomes`（`BiomeEntryDef` 定义各群系的数值区间，顺序即优先级）。

### 7. 分块世界（确定性无限世界）

```gdscript
var world := ChunkedWorld.new()
world.seed_base = 20260811
world.grid_def = grid_gen_def          # 任意 GridGenDef
world.chunk_size = 16
var g := world.get_chunk(3, -2)        # 懒生成并缓存（同 seed 必复现）
var v := world.get_cell(50, 30)        # 直接按世界坐标取值
world.clear_chunks()                   # 释放内存，重新取按同一种子重建
```

每个 chunk 用 `(seed_base, chunk坐标)` 派生独立种子，天然支持无限世界、存档只存 seed、联机同步。

### 8. 异步生成（后台线程）

```gdscript
var grid: GeneratedGrid = await PCGTool.generate_grid_async(wfc_def, seed)
```

基于 `AsyncTool.thread_call`，`GeneratedGrid` 是纯数据，线程安全；大图生成不卡主线程（demo 见 ChunkDemo 的「异步生成」开关）。

### 9. 生成管线（组合多步）

```gdscript
# 先地形，再在空地上放资源点（PlacementDef 按 exclude_grid_key 剔除墙上点）
var out: Dictionary = PCGTool.generate(pcg_def)         # 用 def.seed
var out2: Dictionary = PCGTool.generate(pcg_def, 42)    # 覆盖种子
var terrain: GeneratedGrid = out["terrain"]
var resources: PackedVector2Array = out["resources"]
```

- 每个生成器用 `PCGTool.derive_seed(base, slot)` 独立派生 RNG，**互不干扰、顺序稳定、必可复现**。
- `output_key` 为空时用 Def 名作为结果键；`enabled=false` 可临时停用某一步。
- 生物群系（`BiomeMapDef`）、网格（`GridGenDef`）、散布（`PlacementDef`）、内容（`ContentGenDef`）都是 `PCGGeneratorDef`，可任意组合进同一管线。

**完整管线示例**：`Assets/Def/PCG/Pipeline_World.tres` 一条管线生成一个小世界 ——
地形(岛屿) → 群系(海洋/沙漠/草原/森林/山地) → 资源点(自动避开地形实体格) → 战利品(词缀命名)。
在 PCGDemo 的「综合」类别可查看总览合成图（群系色底 + 地形加深 + 资源点高亮）。

### 10. 存档

seed 即世界的"钥匙"，配合 `SaveTool` 一行存读（demo 见 ChunkDemo 的「存种子/读种子」）：

```gdscript
SaveTool.save_data("user://world.json", {"seed": seed, "radius": 2}, SaveTool.Mode.JSON)
var data = SaveTool.load_data("user://world.json", SaveTool.Mode.JSON)
```

## 设计要点

| 原则 | 说明 |
|---|---|
| **Seed 驱动可复现** | 所有生成只依赖 `PCGTool.make_rng(seed)`，同 seed 必复现，利于存档/分享/联调 |
| **配置驱动** | 一切参数都是 `.tres` 资源，策划可调不动代码 |
| **管线组合** | 小算法组合成多通道管线（地形→群系→结构→散布），是业界主流做法 |
| **结果与渲染解耦** | 生成结果（栅格/点集/内容/群系图）是纯数据，交给游戏侧自由渲染 |
| **只包装内置能力** | 噪声用 Godot 内置 `FastNoiseLite`；重算法可走 gdextension 路线加速（参考框架 ECS） |

## 演示

- `res://Scenes/PCG/PCGDemo.tscn` — 基础生成展示：噪声层 / 网格（含 WFC 固定格涂色补全 + 过程动画）/ 散布 / 内容（含词缀）/ 生物群系 / 综合管线（地形→群系→资源点→战利品）
- `res://Scenes/PCG/ChunkDemo.tscn` — 分块世界：确定性无限世界、同步/异步生成、seed 存读取档

WFC 演示小贴士：切到「网格」选 WFC 配置，左侧选「刷子」瓦片，在图上**左键点击涂格**（固定该格）、**右键擦除**已固定的格，点「重新生成」即可看到 WFC 在保持你手绘格子的前提下自动补全整张地图（固定格带亮色边框）。勾选「生成过程」可逐帧观看观测-传播动画，点「重置」回到未生成状态重放。

预置配置资源位于 `res://Assets/Def/PCG/`。

## 扩展

新增一种生成器：继承 `PCGGeneratorDef`，实现 `generate(ctx)`，把结果写入 `ctx.output[键]`，
即自动接入管线（参考 `GridGenDef` / `BiomeMapDef`）。
