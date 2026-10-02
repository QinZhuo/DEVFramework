# PCG — 3D 程序化生成运行时

> 本模块只服务一件事：**生成 3D 模型世界**。
> 目标产物有两种形态 —— **体素模型**与**lowpoly 场景**，而它们来自**同一次生成**。

---

## 一、模块定位

### 1.1 只做 3D

模块原本是"2D 栅格地图生成（城镇路网 / 高度图 / 河流道路 / 程序化纹理 / L-System /
模板拼接 / 内容进化） + 3D 体素补丁"，其中 2D 占代码量 92.6%。这类产物是**俯视地图数据**，
与"3D 模型"是两个不同的产物类别；混在一个模块里，会让"生成 3D 世界"这件事被
"生成 2D 地图"淹没 —— 打开目录先看到 8 种 2D 算法，真正服务 3D 的 4 种排在后面。

2026-10 全量重构：**2D 能力整体移除**，保留 3D 栅格 / 3D 散布 / 分块世界 / 生成管线，
并把原先平行的 `SDF/` 模块并入，统一为一个模块。

### 1.2 核心主张：一份生成数据，两种投影

```
                    ┌──────────────────────────────────┐
                    │  SdfField（带材质槽位的连续场）    │  ← 只烘焙这一次
                    └───────────────┬──────────────────┘
                          ┌─────────┴─────────┐
                          ▼                   ▼
                  MeshExtractor          VoxelExtractor
                （等值面 → lowpoly）      （体素化 → 体素模型）
                          │                   │
                          └─────────┬─────────┘
                                    ▼
                              ToonStyleDef / ToonPaletteDef
                             （三渲二材质 / 描边 / 色阶）
```

**为什么这是关键**：烘焙（把几何写进场）是全场唯一的耗时环节，实测占总耗时 99.9% 以上
（中等精度下单体 1~3 秒）；两个提取步骤相对它都很便宜。所以：

- 要体素模型**不是**"再生成一遍"，只是多提一次；
- 两个产物**必然同形**（同一份场），不会对不齐；
- 换画风**不必重算几何** —— 风格挂在投影/材质阶段，不沾几何数据。

这也是本模块与"到处各写一套生成器"的根本分野。

### 1.3 两层结构：结构层 + 造型层

| 层 | 回答的问题 | 主要类 |
|---|---|---|
| **结构层** | 哪里是实心、哪里是空、谁挨着谁 | `PCGTool` / `Grid3DGenDef` / `GeneratedGrid3D` / `ChunkedWorld3D` |
| **造型层** | 实心的那些长什么形状 | `SdfField` / `PropGen` / `ModelGraph` / `PropBuild` |

两层不是二选一，而是互补：

- **WFC 3D** 擅长"块状拼接的结构"（房间、模块朝向、管道连接），
- **SDF** 擅长"有机造型"（建筑外形、家具、载具）。

层间衔接由 `PropLayoutTool` 负责（贴地 / 朝向 / 避让）。

---

## 二、目录结构（六层）

```
PCG/
├─ Core/       统一中间表示与几何算子
│  SdfField / SdfChunk / SdfMesh / SdfTool
│  MeshExtractor / SlotPalette / NoiseLayerDef
├─ Voxel/      体素域：3D 栅格 + 体素产物
│  Def/    Grid3DGenDef / PlacementDef3D / TileDef3D / TileSetDef3D
│  Entity/ GeneratedGrid3D / ChunkedWorld3D
│  SdfVoxel / VoxelExtractor
├─ Model/      造型域：生成契约 + 节点图 + 布局
│  Def/    PropGenDef
│  Entity/ PropGen / PropBuild
│  Tool/   PropGenTool / PropLayoutTool / ModelBaker
│  Graph/  ModelGraph + ModelNode + Nodes/（18 种节点）
├─ Pipeline/   生成管线：多生成器协同
│  PCGDef / PCGGeneratorDef / PCGContext / PCGTool
├─ Style/      三渲二风格
│  ToonStyleDef / ToonPaletteDef / ToonShader / ToonMaterial
│  MiniatureStage（长焦 / 景深 / 环境 / 暗角的装配器）
└─ World/      场景级成套配置
   SceneStylePack
   DioramaDef / DioramaRecipe / DioramaBuild / DioramaBuilder（微缩小场景组装）
```

**功能轴自包含**：整个 `PCG/` 目录删掉，框架其余部分仍能编译运行。

---

## 三、结构层 API

### 3.1 3D 体素栅格

四种算法，全在 `PCGTool.generate_grid_3d(def, rng)` 之下：

| `Grid3DGenDef.Type` | 做法 | 用途 | 实现 |
|---|---|---|---|
| `NOISE_SURFACE` | 每 (x,z) 列按噪声高度填充实体 | 地表、丘陵 | GDScript |
| `CAVE_NOISE_3D` | 3D 噪声阈值挖空 | 丝网状连通通道 | GDScript |
| `CAVE_3D` | 细胞自动机 + 26 邻域平滑 | 团块状经典 Rogue 洞穴 | C++ `PCGCave3D` |
| `WFC_3D` | 六面 socket 约束坍缩 | 结构化拼接 | C++ `PCGWFC3D` |

```gdscript
var def := load("res://Assets/Def/PCG/Grid3D_Cave.tres") as Grid3DGenDef
var grid := PCGTool.generate_grid_3d(def, PCGTool.make_rng(42))
print(grid.count(def.solid_value), " / ", grid.cells.size())

# 大体积不卡主线程（带进度回调，UI 可显示进度条）
var grid2 := await PCGTool.generate_grid_3d_async_progress(def, 42, func(p): bar.value = p * 100.0)
```

`GeneratedGrid3D` 是扁 `PackedInt32Array`（列主序，`_index(x,y,z)`），配
`get_cell / set_cell / in_bounds / count / fill`。

### 3.2 3D 散布

`PCGTool.place_3d(def, rng)` → `PackedVector3Array`。三种模式：

| `PlacementDef3D.Mode` | 特点 |
|---|---|
| `POISSON_3D` | Bridson 3D，间距严格 ≥ `min_distance`，O(n) |
| `JITTER_GRID_3D` | 最快，分布规整但带随机偏移 |
| `RANDOM_3D` | 最快，可能成堆 |

**这里只给点集**，贴地与朝向是布局层的事（见 §4.3）。`exclude_grid3d_key` 可剔除
落在实体格内的点。

### 3.3 3D 分块世界

```gdscript
var world := ChunkedWorld3D.new()
world.seed_base = 42
world.grid3d_def = def          # 尺寸会被 chunk_size 覆写
world.chunk_size = 8
var g := world.get_chunk(0, 0, 0)   # 懒加载 + 缓存，确定性
await world.generate_chunks_async(keys, func(p): ...)
world.set_cell(x, y, z, 1)          # 记入"玩家修改"
world.save_data()                   # { seed, chunk_size, def 路径, modified }
```

**存档只存 seed + 增量改动**，世界本体永远能按 seed 重放出来，所以分块世界不占存档体积。

跨块连续靠 `offset`：所有 chunk 用**同一种子 + 各自 offset**，
而不是各自独立的种子 —— 后者会让相邻块地表高度对不上，缝一眼可见。

### 3.4 生成管线

`PCGDef` 里挂一组 `PCGGeneratorDef`，按顺序执行、共享一个 seed：

```gdscript
var out := PCGTool.generate(pipeline_def, 42)
# out["terrain3d"] → GeneratedGrid3D
# out["points3d"]  → PackedVector3Array
```

每个生成器拿到 `PCGTool.derive_seed(base, slot)` 派生的独立 RNG。
`slot` 是**位置索引**，所以：

- ✅ **往尾部追加**生成器不会改变已有生成器的结果；
- ❌ **从中间插入**会改变其后全部生成器的结果。

想让新增步骤不影响存量，把它的 slot 取一个未使用的固定值（如 100+），别指望追加到末尾。

扩展新生成器只需继承 `PCGGeneratorDef` 并实现 `generate(ctx)`，
产物写 `ctx.output[key]`，需要上游产物就 `ctx.get_result(key)`。

---

## 四、造型层 API

### 4.1 两种写法产出同一份场

**写法 A：`PropGen` 子类**（手写 SDF 组合，最直接）

```gdscript
extends PropGen
func local_bounds() -> AABB:
    return AABB(Vector3(-3, 0, -2), Vector3(6, 5, 4))
func build(field: SdfField) -> void:
    union_shape(_wall)
    sub_shape(_window)
    union_shape(_roof)
    fill_shape(_sdf_box)     # 把 shape 填进场
```

**写法 B：`ModelGraph` 节点图**（配方化、可参数化、换风格不重搭）

```gdscript
var g := ModelGraph.new()
var wall := g.add(ModelBoxNode.new())          # 18 种节点：Box/Capsule/Cylinder/
                                               # Ellipsoid/Prism/Torus/Sphere/Plane/
                                               # Union/Subtract/Intersect/Shell/
                                               # Harden/Transform/Repeat/Slot/Group
g.link(roof_id, &"in", wall_id)
g.set_seed(42)
var b := ModelBaker.bake(g, 42, {
    "style": ToonStyleDef.presets()[&"anime_clean"],
    "palette": ToonPaletteDef.presets()[&"anime_daylight"],
    "voxel_res": 64,                 # >0 即产体素
})
```

### 4.2 双产物

```gdscript
var def := PropGenDef.new()
def.voxel_size = 0.18            # 场体素边长（米）
def.algo = MeshExtractor.Algo.DUAL_CONTOURING   # 三渲二首选（保棱角）
def.sharp_normal = true# 主平面特征法线，硬边的关键
def.voxel_res = 40               # >0 才产体素；按**最长边**定尺
def.voxel_palette = palette      # 体素与网格同属一套配色

var b := PropGenTool.bake(MyGen.new(), def, 42)
b.mesh              # → SdfMesh：低多边形网格
b.voxel             # → SdfVoxel：体素模型（b.has_voxel() 为真时才有）
b.bounds / b.footprint / b.triangle_count()
```

**`voxel_res` 按最长边定尺**，所以扁长物体（24×0.6×10.8 米的路面）
短边只剩一两格，体素化会退化。调用方应检查 `b.has_voxel()` 并准备回退到网格 ——
静默跳过会让模型"凭空消失"且日志一片正常。

装配成可视节点：

```gdscript
var n1 := ModelBaker.build_node(b, {"style": style, "palette": palette})
var n2 := ModelBaker.build_voxel_node(b.voxel, {"style": style, "palette": palette,
                "greedy": true})   # false = 逐体素方块（Minecraft 观感）
```

### 4.3 布局：PropLayoutTool

**与 `PropGen` 完全对偶**：

| | 知道 | 不知道 | 产物 |
|---|---|---|---|
| `PropGen` | 局部几何 | 世界 | `PropBuild` |
| `PropLayoutTool` | 尺寸 / 朝向 / 地面高度 | 几何细节 | `Placement` |

```gdscript
var pl := PropLayoutTool.solve(build, seed, Vector2(x, z), 0.0,
    func(x, z): return ground_height(x, z),      # 鸭子类型，框架不引用任何地形类
    {&"snap": PropLayoutTool.Snap.MIN,
     &"align_dir": Vector2(0, -1),                # 令 yaw 把局部正面转向它
     &"face_dir": Vector3i(0, 0, 1),
     &"ground_step": 4.0})                        # 长单体必须给，否则穿地形
PropLayoutTool.relax(placements, 32, 0.95)       # 批量避让松弛
```

存档只需 `seed_value + origin + yaw`，`build` 可随时按 seed 重建。

### 4.4 SdfField 常用算子（SdfTool）

```gdscript
SdfTool.allocate_cells(field, lo, hi)   # 开一块恰好够用的场
SdfTool.harden(field, step)             # 硬边化（三渲二棱面）
SdfTool.shell(field, w)                # 抽壳（薄壁）
SdfTool.refresh_band_bounds(field)      # 改写 data 后必须调，窄带缓存会失效
```

`SdfField` 带**材质槽位**（`slot_at_world` / `SLOT_NONE`），槽位最终写进
网格顶点色与体素调色板 —— 于是"换配色"不用重算几何，"换分件色"也不用。

### 4.5 微缩小场景组装器：DioramaBuilder

项目层 `WorldAssembler` 摆的是**街道**（沿路排布、贴地采样）；微缩小场景摆的是
**底座上的簇**：一块展示底座 + 若干圈道具，没有街道也没有地形高度，落位是纯极坐标。
框架层给出这套组装器，项目层只负责往里填生成器（`DioramaPresets`）。

```gdscript
var def := DioramaDef.new()            # 底座 + 环带 + 背板弧
var recipes := [ ... ]                 # DioramaRecipe[]，每条一种道具
var b := DioramaBuilder.build(def, recipes, seed)      # 同步（测试与烘焙用）

var asm := DioramaBuilder.new()                       # 分帧（演示场景用）
asm.begin(def, recipes, seed)
while not asm.step():                                # step() 返回 true 即已推进完
    bar.value = asm.progress() * 100.0
var b := asm.finish()                                 # finish() 才做吸附与分桶

DioramaBuilder.spawn(b, self, null, PropBuild.Form.VOXEL_ITEM)   # 产出节点
DioramaBuilder.save_data(b)            # 只存 seed + transform，7 字段/条
```

| 概念 | 归属 | 要点 |
|---|---|---|
| `DioramaDef` | 底座与环带 | `inner_radius` / `ring_step` 定环带，`backdrop_angle` + `backdrop_arc` 定背板弧；`base_radius()` 与 `base_half_extent()` 都由 `base_gen` **现算**，不手填 |
| `DioramaRecipe` | 一条配方 | 复用 `PropRecipe` 的字段，另加 `role` / `layout` / `band` / `facing` / 抖动 |
| `DioramaBuild` | 产物 | 按角色分桶 `subjects` / `env` / `props`，`all()` 是三者之和 |
| `DioramaBuilder` | 组装器 | 烘焙 → 落位 → `relax` → 越界剔除 → 体素吸附 → 分桶 |

三种落位语义（`DioramaRecipe.Layout`）：

| 布局 | 角位怎么来 | 半径 | 典型用途 |
|---|---|---|---|
| `CENTER` | 显式 `angle`（给主体定镜头侧） | 显式 `radius` | 主体，且必须唯一 |
| `BACKDROP` | **`count` 在弧上均分（含两端）** | 显式 `radius` | 围合背板 |
| `RING` | `angle` 是**相位**，第 i 个再 `+360°·i/count` | `radius_for_band(band)` | 同一类道具均分整圈 |

`RING` 的 `angle` 是相位而不是"所有实例的同一个角"：两盏路灯会相差 180°，
而不是叠在同一坐标上让 `relax` 原地打转。

**体素"统一正方体"的两条约束**（缺一条就散）：

- 边长一致靠 `voxel_cell` 直达提取器（物理量直接指定，不能"按最长边切几格"）；
- 位置一致靠 `voxel_grid_snap`，且吸附必须发生在 `relax` **之后** ——
  每个单体的体素格点锚在**它自己的局部原点**上，先吸附再避让等于白做。

```gdscript
print(b.story())        # 人类可读的组成清单
print(b.validate())     # 缺底座 / 主体不唯一 / 体素化退化 —— 静默失败全靠它兜住
```

`validate()` 存在的理由和 `has_voxel()` 一样：**少一类道具时组装器不报错**，
画面只是"安静地少东西"。

---

## 五、风格层

### 5.1 三渲二：引擎管光影，shader 管色

```gdscript
var style   = ToonStyleDef.presets()[&"anime_clean"]    # 多硬 / 多光滑 / 描边多粗
var palette = ToonPaletteDef.presets()[&"anime_daylight"]
ToonMaterial.apply(mi, style, palette, parent)         # 上材质 + 描边
```

`ToonShader` 用 `render_mode diffuse_toon, specular_disabled`：**引擎的 toon 光照是
唯一带阴影贴图通道的路径**，光影阶梯交给它；shader 自己只写 `EMISSION`
（固有色分档 + 染色阴影地板 + 补光 + 轮廓光 + 块高光），因为 `EMISSION` 不受光 ——
阴影里会显色而不是死黑。

> **踩过的弯路（都在 Godot 4.7.2 上实测过）**：
>
> 1. 片元着色器**没有 `light()` 内置函数** —— 拿不到任何逐像素光数据，
>    唯一带阴影贴图的通道就是**引擎光照对 `ALBEDO` 的乘法**。
> 2. 片元内置量 **`LIGHT` 也不存在**（`VIEW` / `NORMAL` / `CAMERA_POSITION_WORLD` 存在）。
>    写 `v_light = LIGHT;` 会在**任何阶段**编译失败：
>    `表达式中的标识符未知："LIGHT"`（顶点阶段同样没有）。
> 3. 所以"哪一面亮"只能由 CPU 侧传方向进来，即 uniform **`u_key_dir`**
>    （来源 `ToonStyleDef.key_light_dir`）。这反而是对的：色阶是**画风**，
>    本就不该随"场景里恰好哪盏灯最亮"而漂移。
>    **代价是必须与实灯同向**，否则色阶亮面与实灯亮面错开一道、
>    硬边阴影与色阶互相打架 —— 不崩、不报错、只能靠肉眼发现。
>    `MiniatureStage.apply_key_light()` 就是为此存在，`apply_stage()` 会自动调它。
> 4. `normalize()` 遇零向量产出 NaN，会污染整片元，故一律过 `safe_dir()`
>    （无光 / 忘配时退化为 `(0,0,1)`，而不是 NaN）。

`ToonStyleDef` 里与调色板无关的光照向参数（`shadow_floor` / `key_light_color` /
`key_light_dir` / `fill_dir` / `fill_color` / `fill_strength`）会在 `make_material()` 里
**先于**调色板分支写入 —— 否则 `make_material(null)` 会产出一份无雾无补光的哑光材质。

主光的摆法**不用 `Node3D.look_at()`**：它要求节点已在场景树里，而编辑器搭场景
（节点还没 `add_child`）与单元测试（临时 `Node3D` 不进树）都不满足，会拿到
`Node not inside tree. Use look_at_from_position() instead.`。
`MiniatureStage` 自己拼正交基并显式换到 host 的局部空间。

### 5.2 描边双通道（自动降级）

| 通道 | 实现 | 适用 |
|---|---|---|
| `INVERTED_HULL` | 额外画一圈背面外扩壳 | 任何场景，零依赖 |
| `SCREEN_SPACE` | 复用场景里的 `OutlineEffect` 后处理 | 有后处理时更干净 |

`ToonMaterial.apply()` 在 `SCREEN_SPACE` 找不到 `OutlineEffect` 时会 **push_warning
并自动降级为倒壳**。体素产物（`ModelBaker.build_voxel_node`）**默认带描边**
（`outline` 默认 `true`），与 `build_node` 对齐 —— 要"看得见的方块"得显式传 `false`。

### 5.3 微缩舞台：长焦 + 浅景深 + 边缘收暗

`[ToonStyleDef]` 只管单个物体长什么样，而微缩感三要素里前两者**根本不在材质上**。
材质再干净，广角 + 全清晰 + 亮边缘 = "游戏截图"，不是"模型照片"。

```gdscript
var pack = SceneStylePresets.presets()[&"mini_fairy"]
pack.apply_stage(self, camera, 62.0)      # FOV + 景深 + 环境 + 暗角一次到位
camera.position += dir * pack.stage_distance_hint   # 长焦必须同步后退
```

| 要素 | 实现 | 备注 |
|---|---|---|
| ① 长焦 | `Camera3D.fov` 调小 | 用 `MiniatureStage.frame_scale(fov)` 换算后退倍率，否则画面会猛地凑近 |
| ② 浅景深 | `CameraAttributesPractical` 的 near/far 虚化 | **没有 `focus_distance`**（实测 ClassDB），对焦带用 near/far distance + transition 表达 |
| ③ 边缘收暗 | `ToonShader.MINIATURE_VIGNETTE` 挂 `CanvasLayer` | `Environment` 里**没有暗角项**，只能自己画；层序号必须小于 UI 层 |

`apply_stage()` 还会顺手做一件**不属于三要素但同样要跟画风走**的事：把主光对准
`style.key_light_dir`（`MiniatureStage.apply_key_light()`）。
只动**一盏**灯（缺省名 `KeyLight`），找不到才新建，且**保留作者调过的强度与阴影开关** ——
切风格包不该拆掉手动布光。重复调用不会越堆越多盏。

曝光只能落在 `Environment.tonemap_exposure`（`CameraAttributesPractical` 没有这个属性）。
`SSAO` / `glow` 被**显式关掉**：这是画风决策而非画质档位（前者糊脏色阶、后者糊硬描边）。

`SceneStylePack` 是**场景级成套配置**：画风 + 配色 + 配方表 + 布局参数 + 输出形态
+ 镜头与舞台，一个配置切换整个场景。

```gdscript
var pack = SceneStylePresets.presets()[&"wa_shrine"]   # 项目层预设
var asm  = WorldAssembler.from_pack(pack, ground_y)    # 项目层组装器
pack.apply_material(mi)
pack.apply_stage(self, camera)
```

**分层边界**：`SceneStylePack` / `MiniatureStage` 在框架层，只认识框架类型；
`recipes` 是未类型化 `Array`（鸭子类型），`MiniatureStage` 对 `pack` 也**不加类型注解**；
内置的具体预设（"日式街道 / 和风神社 / 微缩童话"）引用项目生成器脚本，
因此落在 `Scripts/Gen/SceneStylePresets.gd`。`WorldAssembler.from_pack()` 建在项目层，
依赖方向才是单向的（项目 → 框架）。

雾色 / 环境光色的**真值只在 `style` 上**（`style.fog_color` / `style.ambient`），
`MiniatureStage` 直接读、不另填一份 —— 两处各填一次的颜色必然会互相打架。
风格包上只留 `Environment` 能表达而 `ToonStyleDef` 表达不了的（后期调色、暗角、背景模式）。

---

## 六、三条铁律

### ① 只设 seed，不设 state

一切生成经 `PCGTool.make_rng(seed)` / `PropGenTool.make_rng(seed, salt)`。

```gdscript
rng.seed = s            # ✅
rng.state = rng.seed    # ❌ 会让同 seed 结果依赖调用先后
```

Godot 的 `RandomNumberGenerator` 是 PCG32，seed 与 state 是两个概念：赋值 seed 会用
PCG 初始化状态（state + increment），state 是"当前状态"。把 state 覆盖成 seed 的整数值
（往往是很小的数）会让序列退化，**不同 seed 的首次取值塌成同一个值**。

> 这条坑的特点是：**确定性测试全过**，只有"异 seed 应不同"的断言才抓得到。所以
> `PCTDeterminismTest` 同时断言"同 seed 复现"与"异 seed 不同"。

### ② 存档只存 seed + 增量

见 `ChunkedWorld3D.save_data()`、`WorldAssembler.save_data()`。
世界数据永远能从 seed 重放出来。

### ③ 原生类主线程预热

`FrameworkNative` 的 C++ 类首次 instantiate 有线程亲和，
必须在主线程先碰一下再丢给 worker，否则偶发崩溃。`generate_grid_3d_async*` 已内置预热。

---

## 七、常见任务速查

| 我要做… | 用 |
|---|---|
| 生成一块地形/洞穴 | `PCGTool.generate_grid_3d(def, PCGTool.make_rng(seed))` |
| 大体积不卡帧 | `await PCGTool.generate_grid_3d_async_progress(def, seed, on_progress)` |
| 在区域里撒点 | `PCGTool.place_3d(placement_def, rng)` |
| 无限世界 | `ChunkedWorld3D` + `get_chunk(cx,cy,cz)` |
| 多生成器协同（一个种子出一整套数据） | `PCGDef` + `PCGTool.generate(def, seed)` |
| 造一个单体（要体素模型） | `PropGenTool.bake(gen, def_with_voxel_res, seed)` → `b.voxel` |
| 造一个单体（要 lowpoly） | 同上 → `b.mesh`，或 `ModelBaker.build_node(b, ...)` |
| 造一个单体（要节点图配方） | `ModelBaker.bake(graph, seed, {...})` |
| 把单体摆到世界里 | `PropLayoutTool.solve/relax` → `Placement` |
| 换画风 | 换 `ToonStyleDef`/`ToonPaletteDef`，**不重算几何** |
| 换整个场景风格 | 换 `SceneStylePack` |
| 加"微缩摆件感" | `pack.apply_stage(self, camera, 62.0)` + 用 `pack.stage_distance_hint` 当相机距离 |
| 只调暗角 | `MiniatureStage.apply_vignette(host, pack)`（层序号 < UI 层） |
| 长焦该退多远 | `MiniatureStage.frame_scale(fov)`（基准 70°） |

---

## 八、分层红线

按 `addons/DEVFramework/LAYERS.md`：

1. 框架代码**不得出现** `res://Scripts/` `res://Assets/` `res://Scenes/` 路径。
2. 框架**不得类型注解或 import 项目类**；需要项目能力时用鸭子类型
   （`ground_y: Callable`、`recipes: Array`）。
3. 框架**不含游戏语义**：框架内没有"商店/医院/神社"等具体物体；
   `ShopGen` / `HospitalGen` / `VehicleGen` / `StreetGen`、`WorldAssembler`、`PropRecipe`、
   `SceneStylePresets` 全部在项目层 `Scripts/Gen/`。
4. 不要写"世界生成器"把**生成**与**布局**揉在一起 —— 两层的契约就是 `PropBuild`。

自查：

```powershell
grep -E "res://(Scripts|Assets|Scenes)/" addons/DEVFramework/PCG -r --include="*.gd"
```

---

## 九、演示场景与测试

### 演示场景（`Scenes/PCG/`）

| 场景 | 证明什么 |
|---|---|
| `PCGDemo3D.tscn` | 四条能力线：3D 栅格（4 算法 + 进度条 + 导航桥接）/ 3D 散布 / 生成管线 / 场→网格+体素双产物 |
| `ChunkDemo3D.tscn` | 分块世界懒加载、跨块连续、seed 存档、玩家改动增量 |
| `PCGModelGallery.tscn` | 节点图配方 → 双产物网格墙 |
| `PCGStyleDemo.tscn` | 一个配置换整个场景（**含镜头 / 景深 / 暗角**）；同一份数据落成网格 / 体素 / 两者对照 |
| `PCGWorldAssemble.tscn` | 生成与布局解耦：换 seed 只换造型，站位位移实测 0.0 m |
| `PCGDioramaDemo.tscn` | 微缩小场景：底座 + 簇式落位（CENTER / BACKDROP / RING）、分帧烘焙进度、体素"统一正方体" + 反向外壳描边 |

### 测试（`Scripts/Test/pcg/`，经 `test_pcg.gd` 接入 TestRunner）

| 文件 | 守什么 |
|---|---|
| `PCGNativeTest` | 原生库可用性与算法一致性 |
| `PCTDeterminismTest` | 同 seed 复现**且**异 seed 不同；分块 / 管线 / 散布 |
| `PCGSdfGenTest` | 场烘焙、双产物开关、包围盒最低点 ≈ 0 |
| `PCGSdfSlotTest` | 材质槽位传播与调色板 |
| `PCGSdfLayoutTest` | 布局层全程不生成真实几何（证明它不认识几何细节） |
| `PCGSdfWorldTest` | 端到端：生成 → 布局 → 存档 → 读档还原 |
| `PCGSdfStyleTest` | 风格包结构完整、配方可烘、设置下发到每个配方 |
| `PCGSdfDioramaTest` | 三种落位语义、越界剔除、体素边长全场一致、格点吸附、分帧 == 同步 == 独立重烘、存档 7 字段 |
| `PCTBenchmarkTest` | 性能基准（手动调用 `PCTBenchmarkTest.run()`，非断言用例） |

---

## 十、踩坑记录（全部来自实测）

| 症状 | 根因 | 修法 |
|---|---|---|
| 换个 seed 世界一模一样 | `rng.state = rng.seed` 让 PCG32 序列退化 | 只设 seed（铁律 ①） |
| 选了体素形态却什么都没出 | `voxel_res` 没下发到配方 | 组装器烘焙用的是配方自己的参数；`SceneStylePack.apply_output_to_recipes()` 逐个下发 |
| 模型"凭空消失"、日志正常 | 扁长物体体素化退化，`has_voxel()` 为假被静默跳过 | 检查 `has_voxel()` 并回退到网格 |
| 分块之间地表接缝明显 | 每个 chunk 用了独立种子 | 同一种子 + 各自 `offset` |
| 路面穿进地形 | 贴地只采 5 点，跨不过坡 | 给 `ground_step` 采样密度 |
| 鸟居一座都没摆出来，无报错 | `WorldAssembler` 的 `STREET` 只认第一个配方 | 改用 `ROADSIDE` |
| 烘焙十几秒窗口白屏 | `assemble()` 同步跑完堵死主线程 | 用 `assemble_step()` + `assemble_finish()` 分帧 |
| 薄几何烘焙出空网格 | 体素比几何最薄处还粗 / `local_bounds` 没盖住 | 调细体素；检查 `bounds_hint` |
| 自引用脚本编译失败 | 新脚本 `class_name` 尚未进全局类表 | 运行时 `load(SELF_PATH)` 绕开编译期解析 |
| 两件围合件叠在同一个角上 | `BACKDROP` 的角位由 **`count` 在弧上均分**，`count=1` 时 `t` 恒为 -0.5 | 一条 `count=2` 的配方，别拆成两条 `count=1` |
| 同类道具全挤在一处 | 把 `RING` 的 `angle` 当成"所有实例的同一个角" | `angle` 是**相位**，第 i 个自动 `+360°·i/count` |
| 体素"统一正方体"散了 | `relax` 之后再吸附才有效；先吸附等于白做 | `voxel_grid_snap` 必须在 `finish()` 里、避让之后 |
| 路灯这类细长物体体素产物为空 | 体素比几何最薄处还粗，跨不满一格 | 细杆要 `voxel_cell` ≤ 0.3 m；`has_voxel()` 为假时回退网格 |

---

## 十一、相关文档

- 分层约定：[`../LAYERS.md`](../LAYERS.md)
- 框架总览：[`../Readme.md`](../Readme.md)
- 镜头模块（PCGDemo3D 的机位可换成 `VirtualCamera3D`）：[`../Camera/Readme.md`](../Camera/Readme.md)
