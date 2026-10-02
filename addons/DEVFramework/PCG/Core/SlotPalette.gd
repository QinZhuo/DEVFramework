class_name SlotPalette
extends RefCounted
## 槽位 → 颜色的解析器 —— 把"语义名"翻译成"槽位号"，把"槽位号"翻译成"颜色"
##
## 槽位通道（[SdfField] 的 slots）只存 0~253 的整数，本身不含任何颜色信息。
## 本文件是那一层翻译：
##   语义（"roof" / "wall" / "wood"）→ 槽位号 → 颜色
##
## ## 为什么不让 SDF 场直接存颜色
## 存颜色就等于把配色焊死在几何上：换画风必须重算整场、重提网格。
## 而槽位是**几何无关**的语义标签，同一份槽位可以喂给任意 [ToonPaletteDef]，
## 顶点色烘一次即可，shader 端查色板更是连网格都不用重提。
##
## ## 分层红线
## 本文件不认识体素、不认识网格、不认识节点：它只是一张"整数 → 颜色"的表。
## 槽位号的分配由生成器决定（它知道什么是屋顶），本文件只负责按号取色。

## 未指定槽位（与 [constant SdfField.SLOT_NONE] 同值）
const SLOT_NONE := 255

## 最高可用槽位号 —— **254 刻意留空**：它与 [constant SdfVoxel.STRUCT]（描边/结构色的
## 调色板索引占位）数值相同但语义无关，两个命名空间绝不能混写。
## 留空的好处是"槽位空间"与"调色板索引空间"永不需要仲裁，代价是白白浪费一个槽位号。
const SLOT_MAX := 254

## 槽位号 → 颜色。长度不足时 [method resolve] 回退到 [member fallback]
var colors: Array[Color] = []
## 语义名 → 槽位号（[method from_style_def] 填）。给生成器反查用：
## 几何侧可以问"我该写几号槽"，而不必自己数偏移。
var slot_of_hint := {}
## 越界 / 未指定槽位的回退色
var fallback := Color.WHITE

#region —— 装配 ——

static func create(n: int, fill := Color.WHITE) -> SlotPalette:
	var p := SlotPalette.new()
	p.resize(n, fill)
	return p

## 按语义名表装配：`hints[i]` 拿 first_slot + i 号槽位。
## 这与 [method ToonPaletteDef.by_hint] 的 `material_hints` 槽位约定同源，
## 因此生成器可以只声明"我是屋顶"，色板从哪来完全交给风格。
## 未在 hints 中出现的槽位填 [member fallback]，不猜、不留空 ——
## 猜错颜色比缺色更难看，缺色在 shader 里一眼能看出来。
##
## 词表里没有的 hint（如 "tile"）会拿到 [method ToonPaletteDef.by_hint] 的 fallback，
## 也就是这里的 fill —— 是**静默**的，不报错。宁可如此也不猜：色板宁可缺色不可错色。
## 多出来的 hints 在槽位用尽后**丢弃**（不覆盖已有槽），保证 colors 下标恒在 0~253 内。
static func from_style_def(def: ToonPaletteDef, hints: Array[String] = [],
		first_slot := 0, fill := Color.WHITE) -> SlotPalette:
	var p := SlotPalette.new()
	p.fallback = fill
	if hints.is_empty():
		return p
	var s0 := clampi(first_slot, 0, SLOT_MAX)
	var n := mini(hints.size(), SLOT_MAX - s0)
	p.resize(s0 + n, fill)
	for i in n:
		var h := hints[i]
		var s := s0 + i
		p.colors[s] = def.by_hint(h, fill)
		p.slot_of_hint[h] = s
	return p

## 纯色阶盘：把 [method ToonPaletteDef.to_array] 的 n 级色阶直接铺成 0~n-1 号槽。
## 用于"不区分语义、只区分明暗"的场合（如整体调子映射、按高度分层）。
static func from_ramp(def: ToonPaletteDef, levels := 8) -> SlotPalette:
	var p := SlotPalette.new()
	var arr := def.to_array(levels)
	p.resize(arr.size(), def.base)
	for i in arr.size():
		p.colors[i] = arr[i]
	return p

## 调整槽位数（新槽位填 fill；不保留已有色 —— 调用方要保留请自行备份）。
## 长度硬夹到 [constant SLOT_MAX]：即使 `first_slot + hints.size()` 越过哨兵号也不会建出
## 254/255 这两个"不该存在"的下标，语义槽位空间因此恒定停在 0~253。
func resize(n: int, fill := Color.WHITE) -> void:
	n = clampi(n, 0, SLOT_MAX)
	while colors.size() > n:
		colors.pop_back()
	while colors.size() < n:
		colors.append(fill)

## 写单个槽位的颜色。越界（含 [constant SLOT_MAX] 与 [constant SLOT_NONE]）静默忽略 ——
## 与 resize 用同一条上界，避免"能从 set_slot 写进去、却 resolve 不回来"的不对称。
func set_slot(slot: int, c: Color) -> void:
	if slot < 0 or slot >= SLOT_MAX:
		return
	while colors.size() <= slot:
		colors.append(fallback)
	colors[slot] = c

#endregion

#region —— 取色 ——

## 槽位 → 颜色。越界 / [constant SLOT_NONE] 回退 [member fallback]。
func resolve(slot: int) -> Color:
	if slot < 0 or slot >= colors.size() or slot == SLOT_NONE:
		return fallback
	return colors[slot]

## 语义名 → 槽位号；未登记返回 -1（生成器据此判断"没分件"）
func slot_of(hint: String) -> int:
	return int(slot_of_hint.get(hint, -1))

## 全部槽位色（给 MeshExtractor 的 `vertex_colors` 用；索引即槽位号）。
## 返回副本：GDScript 的 Array 是**引用类型**，直接 `return colors` 会让调用方
## 改"到一半的色板"时原地改掉本对象，症状是色板莫名少几格且极难定位。
func to_array() -> Array[Color]:
	return colors.duplicate()

## 已用槽位数（不含全等 fallback 的空槽）。调试 / 校验用。
func used_count() -> int:
	var n := 0
	for c in colors:
		if c != fallback:
			n += 1
	return n

#endregion

#region —— 跨产物桥接（体素调色板 → 槽位）——

## 体素产物（[SdfVoxel]）的 `data` 存的是**调色板下标**，不是语义槽位号；
## 本表把下标翻成槽位号，让"体素路径也能分件"。
##
## 返回长度 = `maxi(palette.size(), SLOT_NONE + 1)`（**不是** palette.size()）：
## 调用方会写 `map[vox.get_voxel(x, y, z)]`，而 [constant SdfVoxel.EMPTY]（255）
## 是合法取值，表必须够长才不越界。255 号原样透传为 [constant SLOT_NONE]，
## 空体素因此仍是"未指定"，不会被凭空赋一个假槽位。
##
## 未匹配（最近色距离 > max_dist）返回 **-1**，与 [method slot_of] 的"未登记"同义。
## **不用 255 表示未匹配**：255 在槽位侧已被 [constant SLOT_NONE] 占作"未指定"，
## 再让它兼任"没匹配上"就是同一个数字第二次承载另一种语义，跨产物合并时必踩。
##
## ## 何时是精确的、何时是塌缩
## 若 palette 正是本槽位表的来源（[method from_ramp] 走 `def.to_array(levels)`，
## 而体素提取器原样拷贝调用方传的 palette），两边是同一批颜色值，距离恒为 0，
## 映射退化为**精确恒等**、零误差。只有走 [method from_style_def]（语义 hint，
## 色板是墙/地/顶/木几个平坦色）时才会**塌缩**：体素侧的高度渐变 N 层会被
## 映射成少数几个槽位，多层落进同一槽。这不是 bug，但调用方必须知情 ——
## 想要层次就得用 [method from_ramp]，想要分件色就用 hint 模式。
##
## 平局取**最小槽位下标**（严格 `<`，首个最小值胜出）：小语义色板里重复色很常见
## （两个材质同底色、fallback 与某槽同色），不定死就是隐式偏置。
##
## 刻意复制 [method SdfVoxel] 私有 `_nearest_slot` 的算法而不反向调用：
## 两个模块的调色板语义不同（索引 vs 槽位），耦合过去等于把命名空间也耦合起来。
func slot_map_of(palette: Array[Color], max_dist := 0.25) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(maxi(palette.size(), SLOT_NONE + 1))
	for i in palette.size():
		out[i] = -1 if colors.is_empty() else _nearest_slot_to(palette[i], max_dist)
	out[SLOT_NONE] = SLOT_NONE    ## 空体素哨兵原样透传
	return out

## 单个颜色 → 最近槽位号；无匹配返回 -1。
## 距离用**实际 RGB 欧氏距离**（不是平方），max_dist 才有"每通道差多少"的直白含义；
## 比较用 `<` 保证平局取最小下标。开方只在装配期跑，代价可忽略。
func _nearest_slot_to(c: Color, max_dist: float) -> int:
	var best := -1
	var bd := max_dist * max_dist    ## 平方域比较，省开方
	for i in mini(colors.size(), SLOT_MAX):
		var t: Color = colors[i]
		var dr := t.r - c.r
		var dg := t.g - c.g
		var db := t.b - c.b
		var d := dr * dr + dg * dg + db * db
		if d <= bd:
			bd = d
			best = i
	return best

#endregion