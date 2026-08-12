# PCG 程序化生成模块

DEV Framework 的**程序化内容生成**模块。遵循框架 **Def（静态配置 .tres）→ Entity（运行时结果）→ Tool（生成入口）** 三层模式：
所有生成参数都是可配置资源，同一 `seed` 必然复现同一结果，让「配置驱动 + 可复现」贯穿整个生成流程。

---

## 架构

```
addons/DEVFramework/PCG/
├── Def/                       # 生成配置（.tres 资源）
│   ├── PCGGeneratorDef.gd     # 生成器基类（管线单元，结果写入 ctx.output[key]）
│   ├── NoiseLayerDef.gd       # 噪声层（包装 Godot 内置 FastNoiseLite，含 2D/3D 采样）
│   ├── GridGenDef.gd          # 2D 网格生成器（噪声地形/细胞洞穴/迷宫/随机游走/BSP/WFC/Voronoi）
│   ├── Grid3DGenDef.gd        # 3D 体素生成器（地表高度图 / 3D 细胞洞穴 / 3D WFC / 3D 噪声洞穴）
│   ├── TileDef3D / TileSetDef3D  # 3D WFC 六面 socket 瓦片与瓦片集
│   ├── CityDef.gd             # 城市街区生成（道路网格 + 建筑/公园）
│   ├── PlacementDef.gd        # 散布放置器（泊松圆盘/抖动网格/均匀随机，可按网格剔除）
│   ├── PlacementDef3D.gd      # 3D 散布放置器（3D 泊松/网格/随机，可按 3D 网格剔除）
│   ├── ContentEntryDef.gd     # 加权表项（物品/事件/怪物等条目）
│   ├── ContentGenDef.gd       # 内容生成器（加权表/名字/马尔可夫/词缀）
│   ├── ContentEvolveDef.gd    # 内容进化生成器（遗传算法进化出高适应度组合）
│   ├── TileDef / TileSetDef   # WFC 瓦片与瓦片集
│   ├── BiomeEntryDef.gd       # 生物群系条目（高度/湿度/温度区间）
│   ├── BiomeMapDef.gd         # 生物群系图生成器（多层噪声映射）
│   ├── TemplateDef / TemplateStitchDef  # 手作模板 + 拼接
│   ├── RiverDef / RoadDef     # 河流（梯度下降）/ 道路（MST 走廊）
│   └── PCGDef.gd              # 生成管线（组合多个生成器 + 共享 seed）
├── Entity/                    # 生成结果（运行时数据）
│   ├── GeneratedGrid.gd       # 2D 整数栅格（邻居/连通域/BFS 查询，可序列化）
│   ├── GeneratedGrid3D.gd     # 3D 整数栅格（体素，邻居/连通域，可序列化）
│   ├── BiomeMap.gd            # 群系图结果（格子索引 + 群系表）
│   ├── ChunkedWorld.gd        # 2D 分块世界（seed+chunk 坐标确定性懒生成，seed+增量存档）
│   ├── ChunkedWorld3D.gd      # 3D 分块世界（统一噪声种子 + 世界坐标偏移，地表跨块连续，seed+增量存档）
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
| `VORONOI` | Voronoi 地块地形（随机种子点划分区域，每区域采样一次噪声，可选区域边界画墙） |

**连通性后处理**（`GridGenDef.connectivity`）：生成后保证"空地"全部连通（洞穴/地牢可玩性关键）：
- `KEEP_LARGEST`：保留最大空连通域，孤立小区域填成实体
- `CONNECT_ALL`：Dijkstra 随机扰动代价寻路，从每个孤立区挖出**有机蜿蜒隧道**连到主区域（走空便宜、穿墙贵，隧道自然弯曲像洞穴通道；保留全部空间且全连通）
- 默认 `NONE` 不处理（保持算法原始输出）；WFC 瓦片语义除外

### 2.5 模板拼接（手作模板组合）

`TemplateStitchDef` 随机放置多个 `TemplateDef`（字符串行模板，`#`→墙、`.`→空地、`G`→出入口等），模板间用走廊连通：

```gdscript
var tmpl := TemplateDef.new()
tmpl.lines = PackedStringArray(["#####", "#.G.#", "#...#", "#####"])
var stitch := TemplateStitchDef.new()
stitch.width = 96
stitch.height = 96
stitch.templates = [tmpl]
stitch.count = 8
var grid := PCGTool.generate_template_stitch(stitch, PCGTool.make_rng(seed))
```

适合做地牢房间组合 / 建筑群 / 基地布局。

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
# 区域约束：整块矩形区域强制为某瓦片（key 用 Rect2i）
var fixed2 := {Rect2i(0, 0, 16, 16): 0, Vector2i(30, 30): 2}
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

### 5.5 河流与道路（路径生成）

```gdscript
var river_def: RiverDef = load("res://Assets/Def/PCG/River_Terrain.tres")
var rivers: PackedVector2Array = PCGTool.generate_river(river_def, PCGTool.make_rng(seed))
var road_def: RoadDef = load("res://Assets/Def/PCG/Road_Network.tres")
var roads: PackedVector2Array = PCGTool.generate_road(road_def, PCGTool.make_rng(seed))
```

- **RiverDef**：从高地沿高度场梯度（8 邻域最低）一路下降直到入海，`wander` 加随机扰动更自然
- **RoadDef**：生成枢纽点（可自随机或从管线 `hubs_key` 取），用 L 型走廊连接；`mst_only` 用最小生成树避免道路冗余
- 两者都可设 `terrain_key` 把路径印进地形栅格（`PCGTool.stamp_path`），适合叠加进世界管线

### 5.6 3D 体素生成（3D 基石）

`GeneratedGrid3D` 是 3D 整数栅格（体素），配合 `Grid3DGenDef` 生成：
- `NOISE_SURFACE`：每 (x,z) 列按 2D 噪声高度填充实体（Minecraft 式地表）
- `CAVE_3D`：3D 细胞自动机洞穴（26 邻域平滑，空连通域=1 全连通）
- `WFC_3D`：3D 波函数坍缩（六面 socket 瓦片，`TileDef3D` / `TileSetDef3D`）
- `CAVE_NOISE_3D`：3D 噪声洞穴（3D 噪声阈值，`offset` 世界坐标 → 分块世界跨块**完全连续**）

```gdscript
var def: Grid3DGenDef = load("res://Assets/Def/PCG/Grid3D_Surface.tres")
var voxels: GeneratedGrid3D = PCGTool.generate_grid_3d(def, PCGTool.make_rng(seed))
voxels.get_cell(x, y, z)         # 体素取值
voxels.components(0)             # 3D 空腔连通域（洞穴可通行性）
voxels.neighbors(x, y, z, 1)     # 26 邻域统计
```

**3D WFC**：`TileDef3D` 用六面 socket（0=+x,1=-x,2=+y,3=-y,4=+z,5=-z）描述体素连接，
与 2D WFC 同样支持回溯（`wfc_max_backtracks`）、整体重试（`wfc_retries`）与**固定格**：
`fixed` 键支持 `Vector3i`(单格) / int(线性索引) / `"x,y,z"` / `AABB`(区域)，value 为瓦片索引。
参考瓦片集 `Assets/Def/PCG/TileSet3D_Checker.tres`（A/B 垂直交替棋盘）。

```gdscript
# 手绘部分：固定几个体素，3D WFC 自动补全其余
var fixed := {Vector3i(2, 2, 2): 0, Vector3i(3, 3, 3): 1, AABB(Vector3(10, 10, 10), Vector3(3, 3, 3)): 0}
var voxels := PCGTool.generate_grid_3d(wfc3d_def, PCGTool.make_rng(seed), fixed)
```

### 5.8 城市与内容进化

**CityDef**（城市街区）：道路网格划分街区，街区填充建筑/公园：

```gdscript
var city: CityDef = load("res://Assets/Def/PCG/City_Grid.tres")
var city_grid := PCGTool.generate_city(city, PCGTool.make_rng(seed))
# 值语义：road_value=道路 / building_value=建筑 / park_value=公园 / empty=街道
```

**ContentEvolveDef**（遗传算法进化）：进化出高适应度的组合（如词缀装备），
个体 = 基础名 + N 个基因，适应度 = 基因数值(`ContentEntryDef.weight`)之和：

```gdscript
var evolve: ContentEvolveDef = load("res://Assets/Def/PCG/Evolve_Equipment.tres")
var result: Array = PCGTool.evolve_content(evolve, PCGTool.make_rng(seed))
# [{name: "战弓·雷霆·雷霆", fitness: 18.0}, ...]  按适应度降序
```

`NoiseLayerDef` 提供 `sample_3d` / `get_value_3d`，可直接做 3D 噪声体素。3D 生成结果仍是纯数据，交给游戏侧渲染（demo 用 MultiMesh 体素化 + 相机拖拽查看）。

### 5.7 3D 分块世界与 3D 散布

**ChunkedWorld3D**：3D 无限分块世界。地表模式用**统一种子 + 世界坐标偏移**采样噪声，相邻 chunk 地形无缝衔接；洞穴模式每 chunk 独立生成。

```gdscript
var world := ChunkedWorld3D.new()
world.seed_base = 20260811
world.grid3d_def = grid3d_def           # 任意 Grid3DGenDef
world.chunk_size = 8
var vox := world.get_chunk(1, 0, -1)    # 懒生成并缓存（同 seed 必复现）
var v := world.get_cell(50, 20, 30)     # 按世界坐标取值
world.generate_chunk_async(cx, cy, cz)  # 后台线程生成
```

**PlacementDef3D**：3D 空间散布（泊松圆盘 / 抖动网格 / 均匀随机），可指定 `exclude_grid3d_key` 剔除实体格内的点：

```gdscript
var def: PlacementDef3D = load("res://Assets/Def/PCG/Place_3D_Nature.tres")
var pts: PackedVector3Array = PCGTool.place_3d(def, PCGTool.make_rng(seed))
```

### 6. 生物群系图

```gdscript
var def: BiomeMapDef = load("res://Assets/Def/PCG/Biome_World.tres")
var bm := PCGTool.generate_biome(def, PCGTool.make_rng(seed))
var b := bm.biome_at(x, y)      # 该格群系（BiomeEntryDef）
var img := PCGTool.biome_to_image(bm)   # 按群系颜色渲染
```

`BiomeMapDef` 用 高度/湿度/温度 三层噪声采样，映射到 `biomes`（`BiomeEntryDef` 定义各群系的数值区间，顺序即优先级）。
`BiomeMapDef.smoothing_passes` 做群系过渡平滑（3×3 邻域多数投票），消除硬边界的碎斑。

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
地形(岛屿) → 群系(海洋/沙漠/草原/森林/山地，带过渡平滑) → 河流(梯度下降) → 道路(最小生成树连接枢纽) → 资源点(自动避开地形实体格) → 战利品(词缀命名)。
在 PCGDemo 的「综合」类别可查看总览合成图（群系色底 + 地形加深 + 河流蓝线 + 道路灰线 + 资源点高亮）。

### 10. 存档（序列化 + seed 增量）

世界由 seed 确定性生成，存档只存 **seed + 玩家改动格**，加载时重新生成并应用改动，体积极小：

```gdscript
# GeneratedGrid / GeneratedGrid3D 可整体序列化
var data := grid.to_data()
var restored := GeneratedGrid.from_data(data)

# ChunkedWorld / ChunkedWorld3D：seed + 增量改动
var world := ChunkedWorld.new()
world.seed_base = 20260811
world.grid_def = grid_gen_def
world.set_cell(50, 30, 9)               # 玩家改动（记录进增量）
SaveTool.save_data("user://world.json", world.save_data(), SaveTool.Mode.JSON)

var w2 := ChunkedWorld.new()
w2.load_data(SaveTool.load_data("user://world.json", SaveTool.Mode.JSON))
w2.get_cell(50, 30)                     # == 9，改动恢复
w2.get_cell(5, 5)                       # 未改动格由 seed 复现
```

3D 版 `ChunkedWorld3D` 同样支持（键 "x,y,z"）。demo 见 ChunkDemo 的「存档/读档」按钮。

## 设计要点

| 原则 | 说明 |
|---|---|
| **Seed 驱动可复现** | 所有生成只依赖 `PCGTool.make_rng(seed)`，同 seed 必复现，利于存档/分享/联调 |
| **配置驱动** | 一切参数都是 `.tres` 资源，策划可调不动代码 |
| **管线组合** | 小算法组合成多通道管线（地形→群系→结构→散布），是业界主流做法 |
| **结果与渲染解耦** | 生成结果（栅格/点集/内容/群系图）是纯数据，交给游戏侧自由渲染 |
| **只包装内置能力** | 噪声用 Godot 内置 `FastNoiseLite`；重算法可走 gdextension 路线加速（参考框架 ECS） |

## 演示

- `res://Scenes/PCG/PCGDemo.tscn` — 2D 生成展示：噪声层 / 网格（WFC 固定格涂色 + 过程动画、Voronoi、模板拼接）/ 散布 / 内容（含词缀）/ 生物群系 / 综合管线
- `res://Scenes/PCG/PCGDemo3D.tscn` — 3D 体素展示：地表高度图 / 3D 细胞洞穴 / 3D WFC，鼠标拖拽旋转查看
- `res://Scenes/PCG/ChunkDemo.tscn` — 2D 分块世界：确定性无限世界、同步/异步生成、seed 增量存档
- `res://Scenes/PCG/ChunkDemo3D.tscn` — 3D 分块世界（地表跨块连续）/ 3D 散布，鼠标拖拽旋转查看
- `res://Scenes/PCG/DungeonGame.tscn` — **地牢小游戏**：PCG 随机生成地牢（BSP/模板/洞穴/迷宫），回合制打怪（普通/精英/首领三色怪，属性随层数）、装备掉落（词缀命名+攻击加成换武器）、经验/等级成长、金币/药水、多层递增、seed 复现；勾选 **「AI 自动游玩」** 可自动寻路捡物/打怪/下楼（BFS 寻路，可观赏）

WFC 演示小贴士：切到「网格」选 WFC 配置，左侧选「刷子」瓦片，在图上**左键点击涂格**（固定该格）、**右键擦除**已固定的格，点「重新生成」即可看到 WFC 在保持你手绘格子的前提下自动补全整张地图（固定格带亮色边框）。勾选「生成过程」可逐帧观看观测-传播动画，点「重置」回到未生成状态重放。

预置配置资源位于 `res://Assets/Def/PCG/`。

## 数据消费约定（重要）

**本模块是"数据生成器"，只产出纯数据**（`GeneratedGrid` / `GeneratedGrid3D` / `BiomeMap` / 点集 / 内容数组），
**不实现** 栅格→`TileMapLayer` 填充、3D 体素→Mesh、点集→场景实例化、碰撞/物理等"消费数据"的环节。

如何把数据变成可玩内容，由**具体项目自己实现**，或使用**第三方插件**（如 TileMap 编辑器 / 体素地形插件 / 地形 Mesh 工具）完成。这样本模块保持纯净通用，不绑定任何渲染方案。

**数据语义约定**（消费方按此对接）：

| 数据 | 语义 | 消费示例 |
|---|---|---|
| `GeneratedGrid` | `cells` 每个格一个 int：`empty_value`(通常 0)=可走/空地，`solid_value`(通常 1)=墙/实体，WFC 为瓦片索引 | `TileMapLayer.set_cell(coords, source_id, atlas)` 逐格填；`WFC` 用瓦片索引映射到瓦片源 |
| `GeneratedGrid3D` | 体素栅格，同样 0/1 或瓦片索引 | 逐格放 BoxMesh / 用 `MultiMesh` / 交给体素渲染插件 |
| `BiomeMap` | 每格群系索引（`biomes[idx]`） | 按群系色/贴图渲染，或驱动群系规则 |
| `PackedVector2Array` | 散布/河流/道路点（单位=格，区域坐标） | `for p in pts: 实例化场景`；与 grid 映射用 `p/region_size*grid.width` |
| `Array[ContentEntryDef]` / 字符串 | 抽取内容 / 生成文本 | 直接消费为物品/事件/名字 |

**坐标约定**：栅格与点集坐标均为**格坐标**（0..width/height），乘 `tile_size` 即得像素/世界坐标；
`ChunkedWorld.get_cell(世界坐标)` 直接按世界坐标取值，chunk 边界由内部自动处理。
存档用 `seed + 增量改动`（见[存档](#10-存档序列化--seed-增量)）。

> 示例参考：`Scenes/PCG/DungeonGame.tscn` 演示了"消费 `GeneratedGrid` 做撞墙寻路"，
> `PCGDemo3D.tscn` 演示了"用 MultiMesh 消费 `GeneratedGrid3D`"——这些是消费范例，不是本模块内置功能。

## 测试与基准

`res://Tests/PCG/` 提供确定性 / 约束 / 性能三套自检（`class_name XXTest extends RefCounted`，`static run()`）：

| 脚本 | 验证内容 |
|---|---|
| `PCTDeterminismTest` | 全部 2D/3D 算法 + WFC 固定格 + 管线 同 seed 复现、不同 seed 不同 |
| `PCTConstraintTest` | 迷宫/BSP/模板/3D 洞穴连通域=1、3D WFC 交替无违规、泊松最小间距、序列化往返、增量存档 |
| `PCTBenchmarkTest` | 各算法耗时基准（GDScript 参考值） |

运行方式（在编辑器执行，结果打印到日志）：
```gdscript
PCTDeterminismTest.run()
PCTConstraintTest.run()
PCTBenchmarkTest.run()
```

**当前基准参考**（64 位桌面）：2D 网格 96×96 多数 <20ms（WFC 64×64 ≈1.9s 需后台线程）；3D 地表 8ms、3D 洞穴 1.3s、3D WFC 16³ 176ms；分块世界 49 chunk 269ms；综合管线 112ms。

## 扩展

新增一种生成器：继承 `PCGGeneratorDef`，实现 `generate(ctx)`，把结果写入 `ctx.output[键]`，
即自动接入管线（参考 `GridGenDef` / `BiomeMapDef`）。
