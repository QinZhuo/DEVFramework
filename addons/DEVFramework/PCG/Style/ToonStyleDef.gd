@tool
class_name ToonStyleDef extends Def
## 三渲二造型与渲染风格 —— "怎么画"，回答"这个物体该长成什么样、长成什么样才好看"
##
## == 核心设计：风格 = 几何参数 + 渲染参数 ==
##
## 三渲二的观感有**一半长在几何上**，另一半才在着色器上：
##   · 光滑曲面 + 色阶着色 = 塑料感（像手办上漆，不像动画）
##   · 棱面几何 + 硬边色阶 = 动画赛璐璐（这才是目标）
## 所以本文件把"画风"拆成两半，各自独立可调：
##
## | 组 | 字段 | 消费者 |
## |---|---|---|
## | 几何向 | roughen / voxel_size / shell / smooth_k | SDF 硬边化与等值面提取（`geometry_params()`） |
## | 渲染向 | bands / band_softness / shadow_tint / spec_* | `ToonShader.TOON_SURFACE` |
## | 轮廓向 | outline_* / rim_* | `ToonShader.TOON_OUTLINE` 或框架的 `OutlineEffect` |
## | 环境向 | ambient* / fog_* | 同上（雾与低对比环境光，微缩感的关键） |
##
## 两者**必须成套改**：只调色阶不改 `roughen`，出来的就是"上漆手办"而非动画。
##
## == 分层红线 ==
## 本 Def 是纯静态配置（`Def` 基类纪律）。它不认识 SDF 场、不认识网格、不认识节点树：
## 几何侧只通过 `geometry_params()` 读参数，渲染侧只通过 `make_material()` 取材质。
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


#region 渲染向

## 色阶档数：2 = 清透硬边（大片亮面 + 一刀暗面）/ 3 = 常规动画（亮 / 中 / 暗）
@export_range(2, 4, 1) var bands := 2

## 档位过渡宽度（0~0.5，占一档的比例）：0 = 完全硬阶（日式赛璐璐），
## 略大于 0 时只在台阶边界做极窄过渡，起抗锯齿作用而不破坏硬边观感
@export_range(0.0, 0.5, 0.01) var band_softness := 0.06

## 暗部染色：**不要用黑**。日式动画的阴影是往冷 / 往紫染一层色，不是压暗
@export var shadow_tint := Color(0.45, 0.40, 0.65)

## 是否画二渲二的块状高光（逆光下的一点白）
@export var spec_step := false

## 块状高光颜色：默认取暖白，高光一着色就偏黄会显脏
@export var spec_color := Color(1.0, 0.98, 0.94)

## 块状高光阈值（半程向量 N·H）：越大高光越小越集中
@export_range(0.0, 1.0, 0.01) var spec_threshold := 0.72

#endregion


#region 轮廓向

## 轮廓实现方式。倒壳逐物体、屏幕空间全局统一；两者可同时开（屏幕空间管远景、倒壳管近景）
@export var outline_mode: OutlineMode = OutlineMode.INVERTED_HULL

## 轮廓宽度：**NDC 单位下的半宽**（屏幕空间恒定，与距离无关）。
## 0.006 = 极细 / 0.012 = 日式细描边 / 0.020 = 绘本粗描边
@export_range(0.0, 0.08, 0.001) var outline_width := 0.012

## 轮廓颜色：深紫褐 / 深藏青。留空（全透明）时回退 `ToonPaletteDef.outline`
@export var outline_color := Color(0.20, 0.15, 0.24, 1.0)

## 轮廓光颜色：日式动画的边缘亮边，暖白最自然
@export var rim_color := Color(1.0, 0.95, 0.88)

## 轮廓光强度：0 = 关闭。这是"廉价感 vs 通透感"的分水岭，建议不低于 0.4
@export_range(0.0, 2.0, 0.01) var rim_strength := 0.6

## 轮廓光收束指数：越大越细亮（HDR 的 anime cel 常用 2~4）
@export_range(0.5, 8.0, 0.1) var rim_power := 2.5

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

## 分件色双通道的错配告警：整个会话只报一次，避免批量装配时刷屏。
static var _warned_dual_channel := false


## 两条固有色通道同时开启时提醒一次。**只警告、不断言、不改返回值。**
##
## 之所以只是"降级"而非"错误"：两条都给本身合法（比如调用方想临时用纹理覆盖），
## 实际生效的是优先级更高的一条——可诊断的静默降级，好过运行期硬失败。
static func _warn_dual_channel(use_vertex_color: bool, slot_ramp: Texture2D) -> void:
	if slot_ramp == null or not use_vertex_color or _warned_dual_channel:
		return
	_warned_dual_channel = true
	push_warning("[ToonStyleDef.make_material] slot_ramp 与 use_vertex_color 同时开启："
		+ "shader 里槽位纹理优先级更高，顶点色会被静默覆盖（两者都只影响中档固有色）。"
		+ "分件色请只开一条——顶点色 = 一次提取一套颜色（批量烘焙快）；"
		+ "槽位纹理 = 同一网格换多套配色（不重提网格）。")


## 组装色阶材质。档位颜色由本文件按配色方案**算好**再传给 shader——
## 调色只改 `ToonPaletteDef`，shader 与本文件都不必动。
##
## `use_vertex_color` = 打开"语义分件取色（顶点色）"：网格顶点色（由 `SlotPalette.to_array()`
## 烘进 ARRAY_COLOR）成为中档基色，亮档/暗档仍向本风格的暖白与暗部染色靠拢。
## 于是屋顶/墙/木/玻璃各拿各的固有色，而整体仍是同一种画风。
##
## `slot_ramp` = 打开"语义分件取色（槽位纹理）"：传 `ToonMaterial.make_slot_ramp()`
## 烘出的 256×1 色带，shader 按 `UV2.x` 查色。**换配色只换这张纹理，网格不用重提**，
## 且优先级高于 `use_vertex_color`。两者都默认关闭 —— 不分件的单色模型不必付这份开销。
##
## 两条同时给**不是错误**，只是槽位纹理会盖掉顶点色，故只 `push_warning` 一次不断言：
## 断言会把一个本来合法、只是被降级的组合变成运行期硬失败，可诊断性反而更差。
func make_material(palette: ToonPaletteDef, use_vertex_color := false,
		vcol_strength := 1.0, slot_ramp: Texture2D = null) -> ShaderMaterial:
	_warn_dual_channel(use_vertex_color, slot_ramp)
	var mat := ShaderMaterial.new()
	mat.shader = ToonShader.surface_shader()
	mat.set_shader_parameter(&"u_use_vcol", use_vertex_color)
	mat.set_shader_parameter(&"u_vcol_strength", clampf(vcol_strength, 0.0, 1.0))
	# 色带纹理给了就接管固有色；没给则保持关闭，uniform 留 null 也绝不会被采样
	mat.set_shader_parameter(&"u_use_slot_tex", slot_ramp != null)
	if slot_ramp != null:
		mat.set_shader_parameter(&"u_slot_ramp", slot_ramp)
	if palette == null:
		return mat
	# 三档：亮档掺 palette.light（暖白主导），暗档取 shade↔deep 中间（不压到最深）
	var tier_light := palette.base.lerp(palette.light, 0.55)
	var tier_mid := palette.base.lerp(palette.shade, 0.45)
	var tier_dark := palette.shade.lerp(palette.deep, 0.5)
	if bands <= 2:
		# 只有 2 档时让中档与暗档重合 ⇒ 实际就是"亮面 + 一刀暗面"的清透画法
		tier_mid = tier_dark
	mat.set_shader_parameter(&"u_tier_light", tier_light)
	mat.set_shader_parameter(&"u_tier_mid", tier_mid)
	mat.set_shader_parameter(&"u_tier_dark", tier_dark)
	mat.set_shader_parameter(&"u_bands", bands)
	mat.set_shader_parameter(&"u_band_soft", band_softness)
	mat.set_shader_parameter(&"u_shadow_tint", shadow_tint)
	mat.set_shader_parameter(&"u_shadow_mix", 0.30)
	mat.set_shader_parameter(&"u_ambient", ambient)
	mat.set_shader_parameter(&"u_ambient_energy", ambient_energy)
	mat.set_shader_parameter(&"u_spec_step", spec_step)
	mat.set_shader_parameter(&"u_spec_color", spec_color)
	mat.set_shader_parameter(&"u_spec_threshold", spec_threshold)
	mat.set_shader_parameter(&"u_spec_soft", maxf(band_softness, 0.02))
	mat.set_shader_parameter(&"u_rim_color", rim_color)
	mat.set_shader_parameter(&"u_rim_strength", rim_strength)
	mat.set_shader_parameter(&"u_rim_power", rim_power)
	mat.set_shader_parameter(&"u_fog_color", fog_color)
	mat.set_shader_parameter(&"u_fog_density", fog_density)
	return mat

#endregion


#region 内置风格

## 内置 6 套完整风格，`StringName → ToonStyleDef`。几何与渲染成套给，照抄即可出片。
static func presets() -> Dictionary:
	return {
		&"anime_clean": _preset({
			"title": "清透日系",
			"desc": "2 档硬边色阶 + 倒壳细描边 + 强轮廓光。街边店面 / 载具 / 主角道具的默认画风",
			"roughen": 0.25, "voxel_size": 0.12, "bands": 2, "band_softness": 0.04,
			"shadow_tint": Color(0.42, 0.38, 0.62), "outline_mode": OutlineMode.INVERTED_HULL,
			"outline_width": 0.012, "rim_strength": 0.7, "rim_power": 2.4,
			"ambient_energy": 0.32, "fog_density": 0.008,
		}),
		&"storybook_soft": _preset({
			"title": "黄昏童话",
			"desc": "3 档柔和过渡 + 粗描边 + 暖雾。绘本 / 温泉小镇 / 夜景灯火类可爱场景",
			"roughen": 0.15, "voxel_size": 0.10, "bands": 3, "band_softness": 0.16,
			"shadow_tint": Color(0.58, 0.44, 0.58), "spec_step": true,
			"outline_mode": OutlineMode.INVERTED_HULL, "outline_width": 0.020,
			"rim_strength": 0.5, "rim_power": 1.8, "ambient_energy": 0.42,
			"ambient": Color(0.92, 0.82, 0.84), "fog_color": Color(0.98, 0.84, 0.78),
			"fog_density": 0.018,
		}),
		&"miniature_diorama": _preset({
			"title": "微缩模型",
			"desc": "低对比 + 强环境光 + 极细描边 + 重雾，模拟「放在桌上看的树脂模型」",
			"roughen": 0.25, "voxel_size": 0.08, "bands": 3, "band_softness": 0.20,
			"shadow_tint": Color(0.68, 0.68, 0.76), "spec_step": true,
			"spec_threshold": 0.80,
			"outline_mode": OutlineMode.INVERTED_HULL, "outline_width": 0.005,
			"outline_color": Color(0.42, 0.40, 0.46, 1.0),
			"rim_strength": 0.35, "rim_power": 3.2,
			"ambient_energy": 0.55, "ambient": Color(0.90, 0.90, 0.94),
			"fog_color": Color(0.90, 0.91, 0.94), "fog_density": 0.022,
		}),
		&"anime_flat": _preset({
			"title": "低多边形块面",
			"desc": "极粗量化 + 2 档色阶 + 无描边。远景山体 / 大地块的省算力画法",
			"roughen": 1.0, "voxel_size": 0.40, "bands": 2, "band_softness": 0.02,
			"shadow_tint": Color(0.50, 0.50, 0.66),
			"outline_mode": OutlineMode.OFF, "rim_strength": 0.25, "rim_power": 3.0,
			"ambient_energy": 0.40, "fog_density": 0.012,
		}),
		&"wa_shoji": _preset({
			"title": "和风障子",
			"desc": "薄壳抽壳 + 3 档柔过渡 + 无描边 + 强环境光。鸟居 / 和室 / 灯笼纸面质感",
			"roughen": 0.10, "voxel_size": 0.09, "shell": 0.06, "smooth_k": 0.05,
			"bands": 3, "band_softness": 0.22,
			"shadow_tint": Color(0.55, 0.58, 0.70), "spec_step": true,
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
			"shadow_tint": Color(0.72, 0.56, 0.80), "spec_step": true,
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
## 形如 `"清透日系 · 2档 · 描边0.012"`
func get_desc(_data) -> String:
	var parts := "%s · %d档 · %s" % [
		title if not title.is_empty() else name, bands,
		"无描边" if outline_mode == OutlineMode.OFF else "描边%.3f" % outline_width,
	]
	if roughen > 0.0:
		parts += " · 棱面%.2f" % roughen
	return parts