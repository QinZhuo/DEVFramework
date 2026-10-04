@tool
class_name ToonStyleDef extends Def
## 造型与渲染风格 —— "怎么画"，回答"这个物体该长成什么样、长成什么样才好看"
##
## == 核心设计：几何为主，渲染交给引擎 ==
##
## 微缩观感**主要长在几何上**：棱面几何 + 适度粗糙的 PBR 表面就已经成立，
## 光照与阴影交给引擎的 `StandardMaterial3D`。所以本文件把"画风"拆成两半：
##
## | 组 | 字段 | 消费者 |
## |---|---|---|
## | 几何向 | roughen / voxel_size / shell / smooth_k | SDF 硬边化与等值面提取（`geometry_params()`） |
## | 材质向 | roughness / metallic / specular | `make_material()` → `StandardMaterial3D` |
## | 轮廓向 | outline_* | `ToonMaterial.outline()` 的 `grow_amount` + `cull_front`，或框架的 `OutlineEffect` |
## | 光照向 | key_light_dir | `MiniatureStage` 摆 `DirectionalLight3D` 的位置 |
## | 环境向 | ambient* / fog_* / vignette_* | `MiniatureStage` 写进 `Environment` 与暗角层 |
##
## 另有一批字段标注为**已停用**（原自写 3D shader 的遗留），保留是为了不破坏既有
## `.tres` 与 presets，迁移去向见对应 region 的说明。
##
## == 分层红线 ==
## 本 Def 是纯静态配置（`Def` 基类纪律）。它不认识 SDF 场、不认识网格、不认识节点树：
## 几何侧只通过 `geometry_params()` 读参数，材质侧只通过 `make_material()` 出材质。
## **不含任何具体语义**——它不认识"屋顶"，只提供"棱面化到 0.25"这种能力。

## 内置风格的标题（仅 presets 写入）。不叫 `name`——`name` 是基类的翻译名属性，不可重复声明。
var title := ""

#region 枚举

## 轮廓实现方式。
enum OutlineMode {
	OFF,             ## 不画轮廓（日式动画也有"无描边"的干净画法）
	INVERTED_HULL,   ## 倒壳：几何外扩一圈背面，天然跟随模型，支持逐物体
	SCREEN_SPACE,    ## 屏幕空间膨胀：走框架的 OutlineEffect 后处理，全局统一
}

#endregion


#region 几何向

## 硬边化量化步长（米）—— **画风主开关**，直接喂给 `SdfTool.op_round(field, r)`：
## 0.01 = 几乎原样（光滑） / 0.25 = 棱面化（三渲二首选） / 1.00 = 粗块面（低多边形）
@export_range(0.0, 1.0, 0.01) var roughen := 0.25

## 体素边长（米）：与 `PropGenDef.voxel_size` 同量级，越小越精细也越慢
@export_range(0.02, 0.5, 0.01) var voxel_size := 0.12

## 抽壳厚度（米）：0 = 实心。>0 挖成薄壳（灯笼 / 碗 / 屋顶边这类要透光或减重的形体）
@export_range(0.0, 0.5, 0.01) var shell := 0.0

## 融合半径（米）：0 = 硬边拼接。>0 用 `op_smin` 把相邻形体抹圆
@export_range(0.0, 1.0, 0.01) var smooth_k := 0.0

#endregion


#region 引擎材质向

## 表面粗糙度：0 = 镜面 / 1 = 全哑光。微缩模型偏哑光，金属件靠 `metallic` 而不是压 roughness。
@export_range(0.0, 1.0, 0.01) var roughness := 0.72

## 金属度：0 = 介电质 / 1 = 纯金属。**> 0.5 时 [member ToonPaletteDef.base] 即金属的反射色**，
## 压到 0 会让黄铜看起来像上了漆的塑料；给到 1 则 diffuse 消失、只剩环境反射。
@export_range(0.0, 1.0, 0.01) var metallic := 0.0

## 高光强度（映射到 `StandardMaterial3D.metallic_specular`）：金属件给 0.5~0.7 出金属亮边，
## 0 则连高光都没有，粗糙的金属会显得像脏灰泥
@export_range(0.0, 1.0, 0.01) var specular := 0.35

#endregion


#region 已停用：原自写 3D shader 的参数（保留字段，不参与渲染）
#
# 下面这些字段曾经喂给 `ToonShader.TOON_SURFACE`，那支 GLSL 已删除，
# 材质改用引擎内置 `StandardMaterial3D`（理由见 [ToonShader] 文件头）。
#
# **字段刻意保留、不删**：它们已经写进 `.tres` 资源与 `Scripts/Gen/DioramaPresets.gd`
# 的各套预设里，删字段会让那些资源在加载时丢属性、让 presets 直接编译不过。
# 保留即"已知无效"，比"悄悄还在生效但看不出来"安全。
#
# 想找回对应的画面表现，改去这些地方（都是引擎侧、而非材质侧）：
#   · 色阶 / 块状高光 → `bands`、`band_softness`、`spec_*`：引擎没有"硬阶漫反射"，
#     要硬边阴影就开 `Light3D` 的阴影并把 `Environment.tonemap_mode` 调开；
#   · 暗部染色 / 阴影地板 → `shadow_tint`、`shadow_floor`：改由场景 `Environment`
#     的 `ambient_light_color` / `ambient_light_energy` 与 `DirectionalLight3D.light_color`
#     决定，暗部不再是材质里的常量加色；
#   · 补光 → `fill_dir`、`fill_color`、`fill_strength`：改放一盏真实的
#     `OmniLight3D`，位置对着 `fill_dir`，强度对着 `fill_strength`。

## 色阶档数。**已停用**：改用 `StandardMaterial3D` 后无色阶，明暗由引擎光照连续给出。
@export_range(2, 4, 1) var bands := 2

## 档位过渡宽度。**已停用**：色阶整体已移除，本字段不再有任何消费者。
@export_range(0.0, 0.5, 0.01) var band_softness := 0.06

## 暗部染色。**已停用**：染色曾靠 EMISSION 常量底噪实现，材质不再有 EMISSION。
@export var shadow_tint := Color(0.45, 0.40, 0.65)

## 阴影色跟随主光的程度。**已停用**：仅 `derived_shadow_tint()` 用过它，而那个结果已无处可去。
@export_range(0.0, 1.0, 0.01) var shadow_tint_follow := 0.35

## 阴影地板强度。**已停用**：材质不再写 EMISSION，引擎把阴影处的 ALBEDO 乘黑即可。
@export_range(0.0, 1.0, 0.01) var shadow_floor := 0.32

## 主光颜色。**已停用**：曾用于 CPU 侧推导阴影色；现在光照色直接来自场景里的 `Light3D`。
@export var key_light_color := Color(1.0, 0.96, 0.90)

## 是否画块状高光。**已停用**：改由 `metallic` + `specular` 走引擎 PBR 高光。
@export var spec_step := false

## 块状高光颜色。**已停用**：同上。
@export var spec_color := Color(1.0, 0.98, 0.94)

## 块状高光阈值。**已停用**：同上。
@export_range(0.0, 1.0, 0.01) var spec_threshold := 0.72

## 补光方向。**已停用**：改放真实 `OmniLight3D`，本字段仅作"该把灯放哪"的记录。
@export var fill_dir := Vector3(-0.45, 0.30, -0.60)

## 补光颜色。**已停用**：同上，颜色改由那盏灯的 `light_color` 给。
@export var fill_color := Color(0.60, 0.68, 0.95)

## 补光强度。**已停用**：同上，强度改由那盏灯的 `light_energy` 给。
@export_range(0.0, 1.0, 0.01) var fill_strength := 0.22

## 轮廓光颜色 / 强度 / 收束指数。**已停用**：轮廓光曾在 EMISSION 里按 fresnel 加色，
## 现已随 EMISSION 一起移除。边缘亮感改用 `metallic` 的环境反射，或在场景里补一盏背光。
@export var rim_color := Color(1.0, 0.95, 0.88)
@export_range(0.0, 2.0, 0.01) var rim_strength := 0.6
@export_range(0.5, 8.0, 0.1) var rim_power := 2.5

#endregion


#region 光照向

## 主光方向（世界空间，指向光的来向）—— **必须与场景里的 DirectionalLight3D 同向**。
## [MiniatureStage] 用本字段摆那盏主光，所以风格与实灯天然对齐，不会各走各的。
##
## 注意：改用 `StandardMaterial3D` 后材质不再需要这个方向（色阶已移除），
## 但它仍是"这套画风主光从哪来"的唯一记录处，`MiniatureStage` 与调试工具都读它，
## 因此**不要连同上面那批停用字段一起删掉**。
@export var key_light_dir := Vector3(-0.45, 0.82, -0.36)

#endregion


#region 轮廓向

## 轮廓实现方式。倒壳逐物体、屏幕空间全局统一；两者可同时开（屏幕空间管远景、倒壳管近景）
@export var outline_mode: OutlineMode = OutlineMode.INVERTED_HULL

## 轮廓宽度：**世界空间外扩量（米）**。倒壳走 `StandardMaterial3D.grow_amount`，
## 单位与 [method ToonMaterial.build_outline_mesh] 一致，两条路径可互相换算 / 抵消。
## 远景会细到看不见（那台相机在几十米外，6 mm 只有 1 像素不到），需要粗描边就往上调。
@export_range(0.0, 0.08, 0.001) var outline_width := 0.012

## 轮廓颜色：深紫褐 / 深藏青。留空（全透明）时回退 [member ToonPaletteDef.outline]
@export var outline_color := Color(0.20, 0.15, 0.24, 1.0)

#endregion


#region 环境向

## 环境光颜色：微缩感靠"低对比环境光"——不是打暗，而是整体抬亮
@export var ambient := Color(0.80, 0.82, 0.92)

## 环境光强度：0 = 全靠主光（对比强烈） / 0.5+ = 通透柔和（推荐）
@export_range(0.0, 1.0, 0.01) var ambient_energy := 0.35

## 雾色：与 `ambient` 同族即可，否则远处会"发灰出戏"
@export var fog_color := Color(0.86, 0.88, 0.94)

## 雾密度（每米）：微缩感的关键。0.005~0.02 就足够把大场景"缩"成一张桌面
@export_range(0.0, 0.2, 0.001) var fog_density := 0.008

#endregion


#region 几何参数

## 几何参数汇总，供上层节点图消费。键统一用 StringName（省字典查表时的字符串构造）。
## 注意这里**只有几何**，没有渲染——渲染走 `make_material()`，两条路互不污染。
func geometry_params() -> Dictionary:
	return {
		&"roughen": roughen,
		&"voxel_size": voxel_size,
		&"shell": shell,
		&"smooth_k": smooth_k,
	}

#endregion


#region 材质

## 组装表面材质 —— 引擎内置 [StandardMaterial3D]，不再自写 spatial shader。
##
## == 为什么这么简单 ==
## 明暗、阴影、能量守恒全部交给引擎的光照管线。这里只写"这件东西是什么色、
## 表面有多粗糙、是不是金属"，三行就完事。原先那套色阶 + EMISSION 常量底噪
## 的做法已删除，理由（以及它如何在 `tonemap = LINEAR` 下把顶面烧成一片白）
## 见 [ToonShader] 文件头。
##
## == 固有色怎么来 ==
## [param palette] 非空时取 [member ToonPaletteDef.base] 作为 `albedo_color`。
## 分件场景（体素多 surface）走 [method ToonMaterial.part_material]，
## 每个部件一份材质、各自的 `base`，因此**逐部件分色在这里天然成立**，
## 不需要任何 shader 通道去查表。
##
## `use_vertex_color` = 打开"语义分件取色（顶点色）"：网格顶点色（`ARRAY_COLOR`）
## 直接乘进固有色。这是**引擎内置能力**（`vertex_color_use_as_albedo`），
## 替代原先自写 shader 里的 `u_use_vcol` 分支。默认关闭。
##
## `vcol_strength` = 顶点色的权重。引擎只提供"乘上去"这一个开关，没有强度档，
## 所以按等效方式换算：**把固有色往白色推**（权重越低越白），
## 效果与"顶点色影响越弱"一致。这是近似而非精确等价，故此处不做断言级保证。
##
## `slot_ramp` = 旧的"槽位纹理"通道，**已不支持**：`StandardMaterial3D` 没有
## 按 `UV2.x` 查色带的等价功能（它的 UV 通道固定给 albedo / 遮蔽等用途）。
## 给了非 null 就 `push_warning` 一次并忽略——**不静默丢弃**，否则"换配色不用重提网格"
## 这个承诺会继续误导调用方。想要"同一网格换多套配色"，用顶点色通道重新提取即可。
##
## `palette == null` 时给一份中性灰哑光材质（可直接用于预览），而不是 null：
## 返回 null 会让调用方的 `mi.material = ...` 变成"材质被清空"，症状是物体变透明，
## 比直接报错难查得多。
func make_material(palette: ToonPaletteDef, use_vertex_color := false,
		vcol_strength := 1.0, slot_ramp: Texture2D = null) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.roughness = roughness
	mat.metallic = metallic
	mat.metallic_specular = specular
	mat.vertex_color_use_as_albedo = use_vertex_color
	if slot_ramp != null:
		_warn_slot_ramp_unsupported()
	if palette == null:
		mat.albedo_color = Color(0.80, 0.80, 0.80)
		return mat
	# 权重 <1 时往白推，等效于"顶点色影响减弱"（引擎只有乘上去这一个开关）
	mat.albedo_color = palette.base.lerp(Color.WHITE, 1.0 - clampf(vcol_strength, 0.0, 1.0)) \
			if use_vertex_color else palette.base
	return mat


## 槽位色带已无等价实现时的告警。整个会话只报一次，避免批量装配时刷屏。
static var _warned_slot_ramp := false


static func _warn_slot_ramp_unsupported() -> void:
	if _warned_slot_ramp:
		return
	_warned_slot_ramp = true
	push_warning("[ToonStyleDef.make_material] slot_ramp 已不再生效：材质改用引擎内置 "
		+ "StandardMaterial3D，它没有'按 UV2.x 查色带'的通道。本次调用按未给处理。"
		+ "需要语义分件色请改用 use_vertex_color（重新提取一次网格）。")


## 供场景摆主光用：**`DirectionalLight3D` 放到本返回值处、再 `look_at(目标点)` 即可**。
##
## 之所以给"位置"而不是给欧拉角 / Basis：`DirectionalLight3D` 沿自身局部 **-Z** 出光，
## 而"局部 -Z 该朝哪"要同时考虑上方向，绕顺序与正负号极易搞反。这里直接给出
## "光该站在哪"，把朝向交给 `look_at` —— 那是引擎自己的约定，不会有歧义。
##
## == 方向约定：同向，不取反 ==
## [member key_light_dir] 是**光源所在的方向**（来向），不是光行进的向量：
## 预设里一律写成 y 为正（`Vector3(-0.62, 0.55, -0.55)` = 光从右上后方来），
## [method MiniatureStage.apply_key_light] 也正是拿它当 `_basis_with_z()` 的 +Z，
## 而 +Z 才是"来光方向"。所以站位与它**同侧**、不取反。
##
## 取反过一次，后果不报错也不崩，只是画面整个反了：光源落到 `y = -11` 的地下，
## 顶面全部背光（只剩环境光那层托底），投影也投到背光的那一面 ——
## 实测画面是"顶面死灰、底座上一道与光照方向自相矛盾的斜切三角形"。
##
## 用法：`light.position = style.key_light_position(); light.look_at(Vector3.ZERO)`
func key_light_position(distance := 10.0) -> Vector3:
	return key_light_aim() * maxf(distance, 0.01)


## 归一化后的主光来向。零向量 / 与 UP 近乎共线时都退化成一个安全的斜上方向，
## 否则 `normalized()` 出 NaN、或 `look_at` 因上方向退化而报 `上方向与前方向共线`。
func key_light_aim() -> Vector3:
	var d := key_light_dir
	if d.length_squared() < 0.000001:
		d = Vector3(-0.45, 0.82, -0.36)
	d = d.normalized()
	if absf(d.dot(Vector3.UP)) > 0.999:
		d = Vector3(0.0, 0.0, -1.0)
	return d

#endregion


#region 内置风格

## 内置 6 套完整风格，`StringName → ToonStyleDef`。几何与渲染成套给，照抄即可出片。
static func presets() -> Dictionary:
	return {
		&"anime_clean": _preset({
			"title": "清透日系",
			"desc": "2 档硬边色阶 + 倒壳细描边 + 强轮廓光。街边店面 / 载具 / 主角道具的默认画风",
			"roughen": 0.25, "voxel_size": 0.12, "bands": 2, "band_softness": 0.04,
			"shadow_tint": Color(0.42, 0.38, 0.62), "shadow_floor": 0.30,
			"key_light_color": Color(1.0, 0.96, 0.90), "shadow_tint_follow": 0.35,
			"fill_color": Color(0.58, 0.68, 0.95), "fill_strength": 0.20,
			"outline_mode": OutlineMode.INVERTED_HULL,
			"outline_width": 0.012, "rim_strength": 0.7, "rim_power": 2.4,
			"ambient_energy": 0.32, "fog_density": 0.008,
		}),
		&"storybook_soft": _preset({
			"title": "黄昏童话",
			"desc": "3 档柔和过渡 + 粗描边 + 暖雾。绘本 / 温泉小镇 / 夜景灯火类可爱场景",
			"roughen": 0.15, "voxel_size": 0.10, "bands": 3, "band_softness": 0.16,
			"shadow_tint": Color(0.58, 0.44, 0.58), "shadow_floor": 0.38,
			# 黄昏主光偏橙 ⇒ 阴影往紫走，这是黄昏绘本阴影的经典配色
			"key_light_color": Color(1.0, 0.86, 0.72), "shadow_tint_follow": 0.45,
			# 黄昏 ⇒ 光位压低。色阶边界跟着压低，物体才会有一道"横切"的暖亮面
			"key_light_dir": Vector3(-0.62, 0.36, -0.70),
			"fill_color": Color(0.95, 0.78, 0.72), "fill_strength": 0.26,
			"spec_step": true,
			"outline_mode": OutlineMode.INVERTED_HULL, "outline_width": 0.020,
			"rim_strength": 0.5, "rim_power": 1.8, "ambient_energy": 0.42,
			"ambient": Color(0.92, 0.82, 0.84), "fog_color": Color(0.98, 0.84, 0.78),
			"fog_density": 0.018,
		}),
		&"miniature_diorama": _preset({
			"title": "微缩模型",
			"desc": "低对比 + 强环境光 + 极细描边 + 重雾，模拟「放在桌上看的树脂模型」",
			"roughen": 0.25, "voxel_size": 0.08, "bands": 3, "band_softness": 0.20,
			"shadow_tint": Color(0.68, 0.68, 0.76), "shadow_floor": 0.42,
			"key_light_color": Color(1.0, 0.97, 0.94), "shadow_tint_follow": 0.30,
			# 微缩是"摆在桌上的台灯" ⇒ 光位高且偏正前，色阶边界落在顶面而非侧面
			"key_light_dir": Vector3(-0.28, 0.90, -0.34),
			"fill_color": Color(0.86, 0.90, 1.0), "fill_strength": 0.35,
			"spec_step": true,
			"spec_threshold": 0.80,
			"outline_mode": OutlineMode.INVERTED_HULL, "outline_width": 0.005,
			"outline_color": Color(0.42, 0.40, 0.46, 1.0),
			"rim_strength": 0.35, "rim_power": 3.2,
			"ambient_energy": 0.42, "ambient": Color(0.72, 0.75, 0.86),
			# 雾密度是**每米**的，着色器按 `1 - exp(-d * density)` 把固有色往雾色上拉。
			# 原先 0.022 + 近白雾色是按"桌面尺度"设的，但 diorama 实际有 14 米对径、
			# 相机在 19 米外 —— 19 米处雾已达 0.34、背板侧 0.42，
			# 固有色被洗掉四成，再叠近白环境光就整张过曝（实测截图）。
			# 雾只能"把远处轻轻推远"，不能盖住画面。
			# 再降到 0.003：雾按"距相机"算，而微缩长焦把相机推到 52 米外，
			# 0.006 在那里仍有 27% 洗白；0.003 约 10%，只够"轻轻推远"。
			"fog_color": Color(0.72, 0.75, 0.84), "fog_density": 0.003,
					}),
					&"anime_flat": _preset({
			"title": "低多边形块面",
			"desc": "极粗量化 + 2 档色阶 + 无描边。远景山体 / 大地块的省算力画法",
			"roughen": 1.0, "voxel_size": 0.40, "bands": 2, "band_softness": 0.02,
			"shadow_tint": Color(0.50, 0.50, 0.66), "shadow_floor": 0.26,
			"key_light_color": Color(0.95, 0.96, 1.0), "shadow_tint_follow": 0.30,
			"fill_color": Color(0.72, 0.78, 0.95), "fill_strength": 0.18,
			"outline_mode": OutlineMode.OFF, "rim_strength": 0.25, "rim_power": 3.0,
			"ambient_energy": 0.40, "fog_density": 0.012,
		}),
		&"wa_shoji": _preset({
			"title": "和风障子",
			"desc": "薄壳抽壳 + 3 档柔过渡 + 无描边 + 强环境光。鸟居 / 和室 / 灯笼纸面质感",
			"roughen": 0.10, "voxel_size": 0.09, "shell": 0.06, "smooth_k": 0.05,
			"bands": 3, "band_softness": 0.22,
			"shadow_tint": Color(0.55, 0.58, 0.70), "shadow_floor": 0.40,
			"key_light_color": Color(1.0, 0.95, 0.88), "shadow_tint_follow": 0.40,
			# 和风黄昏：低角度侧逆，纸面与石灯笼的受光面窄而长
			"key_light_dir": Vector3(-0.68, 0.42, -0.60),
			"fill_color": Color(0.80, 0.86, 1.0), "fill_strength": 0.30,
			"spec_step": true,
			"spec_color": Color(1.0, 0.97, 0.88),
			"outline_mode": OutlineMode.INVERTED_HULL, "outline_width": 0.008,
			"outline_color": Color(0.16, 0.18, 0.26, 1.0),
			"rim_strength": 0.85, "rim_power": 1.6,
			"ambient_energy": 0.60, "ambient": Color(0.92, 0.93, 0.90),
			"fog_color": Color(0.92, 0.93, 0.95), "fog_density": 0.016,
		}),
		&"candy_pop": _preset({
			"title": "清透糖果",
			"desc": "光滑几何 + 2 档亮色阶 + 粗描边 + 强轮廓光。糖果屋 / 玩具 / UI 立绘道具",
			"roughen": 0.01, "voxel_size": 0.07, "bands": 2, "band_softness": 0.03,
			"shadow_tint": Color(0.72, 0.56, 0.80), "shadow_floor": 0.34,
			"key_light_color": Color(1.0, 0.94, 0.92), "shadow_tint_follow": 0.30,
			"fill_color": Color(0.85, 0.80, 1.0), "fill_strength": 0.24,
			"spec_step": true,
			"spec_threshold": 0.66, "spec_color": Color(1.0, 1.0, 1.0),
			"outline_mode": OutlineMode.INVERTED_HULL, "outline_width": 0.016,
			"outline_color": Color(0.36, 0.22, 0.40, 1.0),
			"rim_strength": 0.95, "rim_power": 2.0,
			"ambient_energy": 0.38, "fog_density": 0.006,
		}),
	}


## 按字段表装配一套风格。未列出的字段保持默认值。
## `title` 只用作 resource_name，`desc` 纯注释用（不写入任何属性）。
static func _preset(cfg: Dictionary) -> ToonStyleDef:
	var s := ToonStyleDef.new()
	for key in cfg:
		var k := StringName(key)
		if k == &"title":
			s.title = String(cfg[key])
			s.resource_name = s.title
		elif k != &"desc":
			s.set(k, cfg[key])
	return s

#endregion


## 覆写展示文案（不覆写 `_to_string()`——它内部调 `tr()`，翻译模块相关）
## 形如 `"清透日系 · 粗糙0.72 · 描边0.012"`。
## 注意展示的是**几何 + PBR**参数：色阶（`bands`）已随自写 3D shader 一起停用，
## 再显示"几档"会让人以为改它能改画面。
func get_desc(_data) -> String:
	var parts := "%s · 粗糙%.2f · %s" % [
		title if not title.is_empty() else name, roughness,
		"无描边" if outline_mode == OutlineMode.OFF else "描边%.3f" % outline_width,
	]
	if metallic > 0.5:
		parts += " · 金属"
	if roughen > 0.0:
		parts += " · 棱面%.2f" % roughen
	return parts