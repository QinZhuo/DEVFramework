class_name SdfTool
## SDF 场运算工具 — 形状基元 + 算子 + 场级填充
##
## 全部静态函数。这是 SDF 基座的"表达力"所在：硬边棱柱与有机曲面共用同一套基元，
## 只差一个算子（op_round 硬边化 / op_smin 融合）——这是"支持各种画风"的落地方式。
##
## 符号约定：d < 0 内部，d > 0 外部。

## —— 形状基元（局部坐标，单位米）——

static func sd_sphere(p: Vector3, r: float) -> float:
	return p.length() - r

static func sd_box(p: Vector3, b: Vector3) -> float:
	var q := p.abs() - b
	return Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0)).length() + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)

## 圆角盒 —— 三渲二硬边块体的基本形（r=0 即标准硬边盒）
static func sd_round_box(p: Vector3, b: Vector3, r: float) -> float:
	return sd_box(p, Vector3(maxf(b.x - r, 0.0), maxf(b.y - r, 0.0), maxf(b.z - r, 0.0))) - r

## 圆柱（轴沿 Y，h = 半高，r = 半径）—— 三渲二柱体的基本形。
##
## d 的两个分量分别是「到侧面的径向距离」与「到端面的轴向距离」，
## 精确距离 = 两者都负时取 max、任一为正时取 `length(max(d, 0))`。
##
## **不要**简化成 `... + d.length()`（漏掉 maxf 夹取）：那样轴心处
## `-min(r, h) + sqrt(r² + h²) > 0` —— 场把**实心柱的中心判成外部**，
## 症状是柱体被掏出一条贯通孔、且车轴之类细柱整个消失。
static func sd_cylinder(p: Vector3, h: float, r: float) -> float:
	var d := Vector2(Vector2(p.x, p.z).length() - r, absf(p.y) - h)
	return minf(maxf(d.x, d.y), 0.0) + Vector2(maxf(d.x, 0.0), maxf(d.y, 0.0)).length()

## 胶囊（轴沿 Y）—— **总半高** h、**半径** r：柱身半高 `h - r`，两端半球。
##
## `h` 与 [method sd_cylinder] 同义（都是总半高），所以"同一个 h 传给两个基元"
## 不会得到两种长度 —— 这也是节点侧唯一需要关心的约定。
##
## 实现是「到线段的距离 ⊖ r」（线段 = y∈±(h-r) 的铅垂段），**不是**圆柱那个
## `minf(maxf(d,0))` 组合式：后者算的是平头柱，`r → 0` 时给出零粗细线段而非圆柱。
static func sd_capsule(p: Vector3, h: float, r: float) -> float:
	var a := maxf(h - r, 0.0)
	return Vector2(Vector2(p.x, p.z).length(), maxf(absf(p.y) - a, 0.0)).length() - r

static func sd_torus(p: Vector3, major: float, minor: float) -> float:
	return Vector2(Vector2(p.x, p.z).length() - major, p.y).length() - minor

## 半空间（朝上）：地面/地板
static func sd_plane_up(p: Vector3, h: float) -> float:
	return p.y - h

## 椭球（三轴半径）—— 蛋 / 橄榄 / 桶肚。
##
## 严格椭球距离是四次方程、无闭式解，而网格提取只关心**符号**与量级，
## 故用 iq 的一阶近似 `k0·(k0-1)/k1`（k0=|p/r|、k1=|p/r²|）。
## 误差随扁率增大，最大约 3%，越接近球越准。
##
## **不要**用"变换球 + scale"替代：那样得到的场梯度不再为单位长度，
## 后续的 union / 抽壳 / 表面提取都会带上系统性误差（表现为提取面整体偏移）。
static func sd_ellipsoid(p: Vector3, r: Vector3) -> float:
	var rr := Vector3(maxf(absf(r.x), 1e-4), maxf(absf(r.y), 1e-4), maxf(absf(r.z), 1e-4))
	var r2 := Vector3(rr.x * rr.x, rr.y * rr.y, rr.z * rr.z)
	var k0 := Vector3(p.x / rr.x, p.y / rr.y, p.z / rr.z).length()
	var k1 := Vector3(p.x / r2.x, p.y / r2.y, p.z / r2.z).length()
	## 球心处 k0 = k1 = 0，是 0/0。分子里已含 k0，所以单纯把 k1 夹到epsilon
	## 会得到 0 —— 即"恰好在表面上"，从场里穿出一个小孔。故显式返回到最近表面的距离。
	if k1 < 1e-9:
		return -minf(rr.x, minf(rr.y, rr.z))
	return k0 * (k0 - 1.0) / k1

## 圆台（两端半径不同的柱）：h 为半高，r1 对应 -y 端、r2 对应 +y 端。
## r1 == r2 时**精确**退化为 [method sd_cylinder] 但更慢 —— 等径柱体请直接用 sd_cylinder。
static func sd_capped_cone(p: Vector3, h: float, r1: float, r2: float) -> float:
	var q := Vector2(Vector2(p.x, p.z).length(), p.y)
	var k1 := Vector2(r2, h)
	var k2 := Vector2(r2 - r1, 2.0 * h)
	var ca := Vector2(q.x - minf(q.x, r1 if q.y < 0.0 else r2), absf(q.y) - h)
	var cb := q - k1 + k2 * clampf((k1 - q).dot(k2) / maxf(k2.dot(k2), 1e-9), 0.0, 1.0)
	var s := -1.0 if (cb.x < 0.0 and ca.y < 0.0) else 1.0
	return s * sqrt(minf(ca.dot(ca), cb.dot(cb)))

## 任意走向的胶囊：线段 a→b 加半径 r。
## [method sd_capsule] 只是它的"竖直、居中"特例，斜撑 / 斜杆 / 任意走向的肢体用它。
static func sd_segment(p: Vector3, a: Vector3, b: Vector3, r: float) -> float:
	var pa := p - a
	var ba := b - a
	var t := clampf(pa.dot(ba) / maxf(ba.dot(ba), 1e-9), 0.0, 1.0)
	return (pa - ba * t).length() - r

## 正 n 棱柱：XZ 轮廓是外接半径 r 的正 n 边形，Y 区间 ±h。n=4 且 r 对应边长时近似为方柱。
static func sd_prism(p: Vector3, r: float, h: float, n: int) -> float:
	var d2 := sd_ngon(Vector2(p.x, p.z), r, maxi(n, 3))
	var dy := absf(p.y) - h
	## 面 / 棱 / 角三段式组合（iq 标准写法）：面内部为负，两轴各自为正时退化为棱柱距离。
	return minf(maxf(d2, dy), 0.0) + Vector2(maxf(d2, 0.0), maxf(dy, 0.0)).length()

## 2D 正 n 边形有符号距离（外正内负）。
##
## 做法：符号由"到各边所在直线的距离"取最大值（半平面交集），
## 幅值由"到边**线段**的最近距离"逐边取最小 —— 只算直线会在顶点附近高估距离、
## 把多边形啃掉一圈；只算线段则定不出符号。
static func sd_ngon(v: Vector2, r: float, n: int) -> float:
	var an := PI / float(n)
	var apothem := r * cos(an)             ## 边心距（外接半径 → 内切半径）
	var half_len := r * sin(an)            ## 单条边半长
	var hd := -1.0e9                      ## 半平面最大值：< 0 表示在多边形内
	var best := 1.0e9                     ## 到边界的最近距离
	for i in n:
		var ang := TAU * (float(i) + 0.5) / float(n)   ## 第 i 条边的外法线角
		var nk := Vector2(cos(ang), sin(ang))
		var tk := Vector2(-nk.y, nk.x)                  ## 边的切向
		var d_plane := v.dot(nk) - apothem
		hd = maxf(hd, d_plane)
		var mid := nk * apothem                         ## 边中点
		var t := clampf((v - mid).dot(tk), -half_len, half_len)
		## 距离必须拿**原始点** v 去量，不能拿它在直线上的垂足去量。
		##
		## 曾经的写法是 `proj = v - nk * d_plane` 再算 `|proj - (mid + tk*t)|`。
		## 垂足 proj 本身就落在这条边上（t 已经把它夹进线段内），于是
		## `proj - 最近点` 恒等于 0 ⇒ 多边形**内部任意一点**的距离都被算成 0，
		## 只有外部点还算得对。后果是 [method sd_prism] 内部永不取负：
		## 整根柱子退化成一层零厚度的壳 —— 树干、塔身、井圈全部只剩上半截，
		## 而画面不报错，只是"模型莫名其妙少了一截"。
		##
		## 用 v 量则法向分量 `d_plane` 被计入，内部点到边的距离就是内切半径那一档，
		## 符号仍由半平面项 [code]hd[/code] 决定 —— 内外一致，才配叫"有符号距离"。
		best = minf(best, (v - (mid + tk * t)).length())
	return signf(hd) * best

## —— 算子 ——

static func op_union(a: float, b: float) -> float:
	return minf(a, b)

static func op_intersect(a: float, b: float) -> float:
	return maxf(a, b)

## 差集（A 减 B）
static func op_sub(a: float, b: float) -> float:
	return maxf(a, -b)

## 多项式 smooth min（iq）：k 越大融合越强，k<=0 退化为硬 union
static func op_smin(a: float, b: float, k: float) -> float:
	if k <= 1e-6:
		return minf(a, b)
	var h := clampf(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
	return lerpf(b, a, h) - k * h * (1.0 - h)

static func op_smax(a: float, b: float, k: float) -> float:
	if k <= 1e-6:
		return maxf(a, b)
	return -op_smin(-a, -b, k)

## 差集（光滑版）
static func op_sub_smooth(a: float, b: float, k: float) -> float:
	return -op_smin(-a, b, k)

## 硬边化：把连续距离场量化成 r 的整数倍 —— **画风开关**
##   r = 0.01 → 几乎原样（光滑曲面）
##   r = 0.25 → 棱面化（三渲二）
##   r = 1.00 → 粗块面（低多边形）
static func op_round(d: float, r: float) -> float:
	if r <= 1e-6:
		return d
	return roundf(d / r) * r

## 薄壳（挖空成壳体）：用 abs 保留内外信息，d 的符号仍表示内外
static func op_onion(d: float, w: float) -> float:
	return absf(d) - w

## 翻面（实心与空腔互换）
static func op_remap(d: float, t: float) -> float:
	return t - d

## 半空间切割
static func op_clip(d: float, h: float) -> float:
	return maxf(d, -h)

## —— 场级操作 ——

## 预分配体素块（体素整数坐标，闭区间）
static func allocate_cells(field: SdfField, lo: Vector3i, hi: Vector3i) -> void:
	var cs := float(field.chunk_size)
	for cz in range(floori(float(lo.z) / cs), floori(float(hi.z) / cs) + 1):
		for cy in range(floori(float(lo.y) / cs), floori(float(hi.y) / cs) + 1):
			for cx in range(floori(float(lo.x) / cs), floori(float(hi.x) / cs) + 1):
				field.get_chunk(Vector3i(cx, cy, cz))

## 按形状函数填充整个场。
## fn(p: Vector3) -> float，p 为**场局部坐标**（相对 field.origin），返回 signed distance（<0 实心）。
## 每块自包含地计算全部体素（不做外扩裁剪），因此多块拼接天然无缝。
static func fill(field: SdfField, fn: Callable) -> void:
	var vs := field.voxel_size
	var band := field.band
	for ck in field.chunks:
		var c: SdfChunk = field.chunks[ck]
		var n := c.size
		var base := c.origin - field.origin
		## 顺带统计窄带包围盒：提取时无需再整块扫一遍
		var has_band := false
		var mn := Vector3i(n, n, n)
		var mx := Vector3i(-1, -1, -1)
		for z in n:
			for y in n:
				var row := (z * n + y) * n
				var off := base + Vector3(0, y, z) * vs + Vector3.ONE * (vs * 0.5)
				for x in n:
					var d := float(fn.call(off + Vector3(x, 0, 0) * vs))
					c.data[row + x] = d
					if d < band and d > -band:
						has_band = true
						mn.x = mini(mn.x, x); mn.y = mini(mn.y, y); mn.z = mini(mn.z, z)
						mx.x = maxi(mx.x, x); mx.y = maxi(mx.y, y); mx.z = maxi(mx.z, z)
		c.band_valid = has_band
		if has_band:
			c.band_lo = mn
			c.band_hi = mx

## 场并集（A 原地 |= B）
static func union_fields(a: SdfField, b: SdfField) -> void:
	_combine_fields(a, b, op_union)

## 场差集（A 原地 -= B）
static func subtract_fields(a: SdfField, b: SdfField) -> void:
	_combine_fields(a, b, op_sub)

static func _combine_fields(a: SdfField, b: SdfField, op: Callable) -> void:
	## 两场 chunk 集可能不同，取并集；缺席的场按其 band 近似为"远离表面"
	var keys := {}
	for k in a.chunks: keys[k] = true
	for k in b.chunks: keys[k] = true
	for k in keys:
		var c := a.get_chunk(k)
		c.band_valid = false      ## 原地改写 data → 窄带包围盒失效
		if b.has_chunk(k):
			var cb: SdfChunk = b.chunks[k]
			for i in c.data.size():
				c.data[i] = op.call(c.data[i], cb.data[i])
		else:
			for i in c.data.size():
				c.data[i] = op.call(c.data[i], b.band)

## 对场整体施加一元算子
static func apply_op(field: SdfField, op: Callable, param := 0.0) -> void:
	for ck in field.chunks:
		var c: SdfChunk = field.chunks[ck]
		c.band_valid = false
		for i in c.data.size():
			c.data[i] = op.call(c.data[i], param)

## 硬边化：把光滑曲面变棱面（画风切换）
static func harden(field: SdfField, r: float) -> void:
	apply_op(field, func(d: float, p: float) -> float: return op_round(d, p), r)

## 抽壳：把实心体变薄壳
static func shell(field: SdfField, w: float) -> void:
	apply_op(field, func(d: float, p: float) -> float: return op_onion(d, p), w)

## 重算所有块的窄带包围盒。
## 任何改写 data 的算子（harden / shell / apply_op / union）之后都应调用：
## 缓存失效本身是安全的（intersects_band 会重算），但会多扫一遍整块。
static func refresh_band_bounds(field: SdfField) -> void:
	for ck in field.chunks:
		var c: SdfChunk = field.chunks[ck]
		c.band_valid = false
		c.intersects_band(field.band)

## 场包围盒（**世界坐标**）
static func bounds(field: SdfField) -> AABB:
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for ck in field.chunks:
		var c: SdfChunk = field.chunks[ck]
		mn = mn.min(c.origin)
		mx = mx.max(c.origin + Vector3.ONE * (float(c.size) * field.voxel_size))
	## SdfChunk.origin 在 get_chunk 里已经是 `field.origin + ...`（世界坐标），
	## 不要再补一次 field.origin —— 早期版本在这里多加了一遍，
	## 导致 origin != 0 的分块世界场整体偏移，只有 origin == 0 的独立物体场看不出来。
	return AABB(mn, mx - mn)

## **窄带**包围盒（世界坐标）—— 也就是"形状真正占据的那一坨"的包围盒。
##
## 与 [method bounds] 的区别正是体素化该用哪个：
## [method bounds] 覆盖**已分配的全部块**，而分块世界 / 未知形状的场通常要留很大余量
## （本项目的场就常按 [-60,90] 这样的体素范围分配）。若按它算体素网格，
## 留白会按比例吃掉分辨率：实测一个 1.5 m 的微缩桌子，场留白到 3.6 m、
## res=48 时体素边长被撑到 0.075 m，桌面（厚 0.1 m）只剩一层，体素数从应有的
## 数千掉到 140 —— 细腿、帽檐这类小结构直接消失。
##
## 窄带盒只包住等值面可能出现的区域（|d| <= band 的体素），与形状尺寸相差不到
## 一个 band，因此 res 确实落在模型上。形状顶到场边界时窄带会被截断，此时它
## 退化成"场内可见部分"的包围盒，仍比全量分配范围紧。
##
## 无任何窄带（场全空 / 未填充）时返回 size 为 0 的 AABB，由调用方决定回退策略。
static func band_bounds(field: SdfField) -> AABB:
	var vs := field.voxel_size
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for ck in field.chunks:
		var c: SdfChunk = field.chunks[ck]
		if not c.intersects_band(field.band):
			continue
		var bb := c.band_aabb()
		if bb.size.x <= 0.0 or bb.size.y <= 0.0 or bb.size.z <= 0.0:
			continue
		## 块原点是世界坐标；band_aabb 给的是块内体素局部坐标
		var lo := c.origin + bb.position * vs
		mn = mn.min(lo)
		mx = mx.max(lo + bb.size * vs)
	if mx.x < mn.x:
		return AABB()
	return AABB(mn, mx - mn)
