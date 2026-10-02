@tool
class_name ToonPaletteDef extends Def
## 三渲二配色方案 —— "一套颜色"，回答"这个物体是什么颜色系的"
##
## 风格由两件事组成：**几何怎么硬**（ToonStyleDef）与**颜色怎么排**（本文件）。
## 本文件只管后者，且**不含任何几何语义**：它只知道颜色，不知道什么是屋顶。
##
## == 日式动画配色的三条铁律（本文件的默认值即按此设定）==
##   ① **高明度、低饱和**：整体偏亮偏淡，画面才不闷；
##   ② **暗部不压黑，而是染色**：暗部往冷 / 往紫偏（`shade` / `deep`），
##      这是二次元"打一层薄紫阴影"的观感，压成黑面立刻变写实；
##   ③ **描边不是纯黑**：日式描边多用深紫褐 / 深藏青（`outline`），
##      纯黑描边会显得生硬、像线稿而不像动画。
##
## 分层红线：本 Def 是纯静态配置（`Def` 基类纪律），不含运行时缓存，
## 也不认识 SDF / 网格 / 节点——几何侧只通过 `ramp()` / `by_hint()` 取色。

## 内置配色方案的标题（仅 presets 写入）。不叫 `name`——`name` 是基类的翻译名属性，不可重复声明。
var title := ""

#region 导出字段

## 主色：物体最主要的固有色（受光面）
@export var base := Color(0.96, 0.87, 0.76)

## 亮部色：受光面的高光倾向。默认接近白但带一点暖（暖白主导是微缩感的来源）
@export var light := Color(1.0, 0.97, 0.91)

## 暗部染色：**不要用黑**，用偏冷的色（日式"薄紫阴影"）
@export var shade := Color(0.62, 0.60, 0.78)

## 最深档染色：背光面 / 阴影里的第三档，比 shade 再冷一档
@export var deep := Color(0.40, 0.36, 0.58)

## 强调色：日式动画常用品红 / 橘红，用于门窗招牌等视觉焦点
@export var accent := Color(0.96, 0.42, 0.47)

## 次强调色：常用品青 / 天蓝，与 accent 搭配形成冷暖对撞
@export var accent2 := Color(0.47, 0.82, 0.88)

## 描边色：深紫褐 / 深藏青。**不要纯黑**（见文件头铁律③）
@export var outline := Color(0.20, 0.15, 0.24)

## 可选：材质语义名列表（"roof" / "wall" / "wood" / "glass" / "accent"…）。
## 供几何按语义取色——**语义名由生成器决定，本文件只按位置分配颜色槽位**
## （顺序见 `_role_of_index()`）。几何层因此可以问"墙是什么色"而本文件不必知道什么是墙。
@export var material_hints: Array[String] = []

#endregion


#region 取色

## 语义名 → 颜色的直接别名表。这些名字在任何配色方案里都指向同一个字段，
## 因此几何层写死 &"accent" 也能在任何 preset 里拿到强调色。
const HINT_ALIAS := {
	&"base": &"base",
	&"light": &"light",
	&"shade": &"shade",
	&"deep": &"deep",
	&"accent": &"accent",
	&"accent2": &"accent2",
	&"outline": &"outline",
}

## 色阶插值：t = 0 → base，0.5 附近 → shade，1 → deep。
## t 会被 clamp 到 [0,1]；`light` **不在这条链上**——它属于高光，
## 由 ToonStyleDef 的块状高光单独驱动，混进色阶会让暗部提亮发灰。
func ramp(t: float) -> Color:
	var u := clampf(t, 0.0, 1.0)
	return base.lerp(shade, u * 2.0) if u <= 0.5 else shade.lerp(deep, (u - 0.5) * 2.0)


## 按材质语义名取色。先查别名表（accent/base/…），再查 `material_hints` 的位置槽位，
## 都没有则返回 `fallback`（调用方通常传 palette.base 或透明色）。
func by_hint(hint: String, fallback: Color) -> Color:
	if hint.is_empty():
		return fallback
	var key := StringName(hint.to_lower())
	if HINT_ALIAS.has(key):
		return _color_of(HINT_ALIAS[key])
	var idx := material_hints.find(hint)
	if idx >= 0:
		return _color_of(_role_of_index(idx))
	return fallback


## 角色名 → 颜色字段。用显式 match 而非 `get()`：类型明确、拼错角色名能立刻暴露。
func _color_of(role: StringName) -> Color:
	match role:
		&"base":
			return base
		&"light":
			return light
		&"shade":
			return shade
		&"deep":
			return deep
		&"accent":
			return accent
		&"accent2":
			return accent2
		&"outline":
			return outline
	return base


## 生成 n 级柔和色阶（供体素调色板 / 网格顶点色用）。
##
## ⚠️ 两条硬约定，缺一不可：
##   ① **返回长度恰好等于 n**（n ∈ [0, 255]；超出范围会被 clamp，clamp 后长度等于 clamp 值）；
##   ② **索引 255 必须留空**——体素调色板把 255 当"未占用"哨兵，因此 n 最大取 255：
##      `to_array(SdfField.SLOT_NONE)` 返回 255 个颜色，占 0 ~ 254，255 天然空着。
##
## 色阶分布略偏暗部（幂次 < 1），使暗面层次比亮面更厚——这是动画阴影的观感。
func to_array(n: int) -> Array[Color]:
	var out: Array[Color] = []
	var count := clampi(n, 0, 255)
	if count <= 0:
		return out
	if count == 1:
		out.append(base)
		return out
	for i in count:
		out.append(ramp(pow(float(i) / float(count - 1), 0.85)))
	return out


## `material_hints[i]` 拿第 i 号颜色槽位。顺序刻意从主色开始：
## 生成器最常问的语义（主体 / 墙 / 屋顶）排在前面，槽位才够用。
static func _role_of_index(idx: int) -> StringName:
	const ROLES: Array[StringName] = [
		&"base", &"shade", &"deep", &"accent", &"accent2", &"light", &"outline",
	]
	return ROLES[idx % ROLES.size()]

#endregion


#region 内置配色方案

## 内置 6 套日系动画向配色，`StringName → ToonPaletteDef`。
## 全部遵守铁律：高明度、低饱和、暖白主导，暗部染色而非压黑。
static func presets() -> Dictionary:
	return {
		&"anime_daylight": _preset(
			"正午晴空的日系动画配色",
			Color(0.97, 0.90, 0.79), Color(1.00, 0.98, 0.93), ## base / light
			Color(0.66, 0.66, 0.84), Color(0.44, 0.42, 0.66), ## shade / deep
			Color(0.97, 0.40, 0.42), Color(0.49, 0.81, 0.90), ## accent / accent2
			Color(0.19, 0.16, 0.26)),                            ## outline
		&"anime_sunset": _preset(
			"黄昏温柔：橘红主调 + 品红压暗，适合街道与温泉小镇",
			Color(0.98, 0.83, 0.70), Color(1.00, 0.94, 0.86),
			Color(0.72, 0.58, 0.72), Color(0.50, 0.37, 0.56),
			Color(0.98, 0.51, 0.38), Color(0.63, 0.62, 0.88),
			Color(0.26, 0.16, 0.28)),
		&"storybook": _preset(
			"童话绘本：低饱和粉彩 + 暖褐描边，适合手作感的可爱物体",
			Color(0.95, 0.88, 0.82), Color(1.00, 0.97, 0.94),
			Color(0.74, 0.68, 0.78), Color(0.55, 0.47, 0.63),
			Color(0.96, 0.66, 0.68), Color(0.68, 0.84, 0.86),
			Color(0.32, 0.22, 0.26)),
		&"miniature": _preset(
			"微缩模型：极高明度 + 极低对比，模拟放在桌上的树脂模型",
			Color(0.93, 0.90, 0.86), Color(0.99, 0.98, 0.96),
			Color(0.80, 0.79, 0.82), Color(0.64, 0.63, 0.70),
			Color(0.93, 0.62, 0.55), Color(0.62, 0.79, 0.86),
			Color(0.38, 0.35, 0.42)),
		&"wa_fu": _preset(
			"和风：生成り白 + 藏青 + 朱红，适合鸟居、榻榻米、和室",
			Color(0.96, 0.95, 0.90), Color(1.00, 0.99, 0.97),
			Color(0.71, 0.74, 0.80), Color(0.47, 0.53, 0.66),
			Color(0.93, 0.35, 0.30), Color(0.72, 0.78, 0.68),
			Color(0.17, 0.19, 0.28)),
		&"candy": _preset(
			"清透糖果：高饱和高明度，适合糖果屋、玩具与 UI 立绘道具",
			Color(0.99, 0.87, 0.88), Color(1.00, 0.98, 0.97),
			Color(0.78, 0.66, 0.86), Color(0.58, 0.45, 0.72),
			Color(1.00, 0.55, 0.72), Color(0.62, 0.92, 0.94),
			Color(0.33, 0.20, 0.38)),
	}


## 装配一套配色。参数顺序 = base / light / shade / deep / accent / accent2 / outline。
static func _preset(preset_title: String, base: Color, light: Color, shade: Color, deep: Color,
		accent: Color, accent2: Color, outline: Color) -> ToonPaletteDef:
	var p := ToonPaletteDef.new()
	p.base = base
	p.light = light
	p.shade = shade
	p.deep = deep
	p.accent = accent
	p.accent2 = accent2
	p.outline = outline
	p.title = preset_title
	p.resource_name = preset_title
	return p

#endregion


## 覆写展示文案（不覆写 `_to_string()`——它内部调 `tr()`，翻译模块相关）
func get_desc(_data) -> String:
	return "%s · 暗部 #%s" % [
		title if not title.is_empty() else name, shade.to_html(false),
	]