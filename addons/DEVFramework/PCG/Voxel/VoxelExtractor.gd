class_name VoxelExtractor
extends RefCounted
## 标量场 → 体素网格抽取器 —— [SdfVoxel] 的唯一产地
##
## 与 [MeshExtractor] 是**并列的第二条输出路径**，不是替代品：
## 等值面出光滑网格（渲染好看），体素出可落地模型（3D 打印 / MagicaVoxel / 建造玩法）。
## 两者共享同一套局部空间约定，输出可以直接叠在一起比对。
##
## 全部静态、无状态（不持有场引用），可离线/后台调用。

## 单次抽取的体素总数硬上限（128 M 体素 ≈ 128 MB 索引）。
## 不是质量建议，是防手滑：res 写大一位就会把内存打爆。
const MAX_VOXELS := 134217728

## (x, z) 列候选三角形总数上限（4 字节/条，20 万条约 0.8 MB）。
## 预筛只是省时间、不是正确性前提，超了就整体退回"每列测全部三角形"。
const EDGE_CHECK_MAX := 200000

## 命中点去重的距离阈值（模型最长边的 1e-5 倍，见 [method extract_from_mesh]）。
##
## 打在两个三角形**共享棱**上的射线会被计两次 → 奇偶翻转 → 整条体素列被判成外部。
## 这是奇偶计数唯一的结构性退化，且**抖动起点治不了**（位移平行于接缝时点仍在接缝上）。
## 阈值只需盖过 float32 求交误差（与坐标量级成正比），又要远小于真实交点间距，
## 所以按模型尺寸缩放，不按体素缩放。
const HIT_EPS_RATIO := 1e-5

## 闭合体检的三角形数上限。体检要把每条边塞进 [Dictionary]，代价与三角形数成正比；
## 超过这个量级就跳过体检（只发警告，绝不阻断调用）。
const CLOSED_CHECK_MAX := 200000

#region —— 场 → 体素 ——

## 从标量场抽取体素网格。
##
## `res` 是**最长边**的目标体素数（短边按同一体素边长等比缩减，体素保持立方）。
## `opts`：
## | 键 | 默认 | 说明 |
## |---|---|---|
## | `&"threshold"` | 0.0 | 实心判定距离；`d < threshold` 即实心。正值 = 膨胀 |
## | `&"band"` | field.band | 场外/缺失体素的距离值，会自动抬到 ≥ threshold 以免误判实心 |
## | `&"palette"` | `[]` | 调色板；给了就按**归一化高度**分层配色（体素产物最常见的上色方式） |
## | `&"tint_regions"` | `[]` | 部位分色：`[{&"aabb": AABB（场全局坐标）, &"index": int}, ...]`，按顺序首个命中即用；都没命中才回退高度分层。通常由 [method PropGen.voxel_regions] 提供 |
## | `&"shrink"` | 0.0 | 等值面整体向内推的体素数，用于让体素块之间出现细缝、产生"倒角感" |
## | `&"margin"` | 0.0 | 窄带盒外扩的**米数**。默认 0 就够：窄带盒本身已经含一个 `field.band` 的余量，
##   而默认 band = 3 * voxel_size，本来就是为"表面附近"设计的。只有当 threshold 膨胀量
##   大于 band、或想让体素网格留出空白边框时才需要给正数（**按模型尺寸给**，给米数不按倍数给）
## | `&"fit"` | `"band"` | 用哪套范围定体素网格：`"band"` = 窄带（跟随形状，推荐）/ `"field"` = 整场分配范围（形状顶到场边界、窄带被截断时用） |
## | `&"cell"` | `0.0` | 体素方块的**物理边长**（米），> 0 时压过 res。要"一场景里所有物体用同一种方块"就填它 |
##
## 体素网格的定位用的是**窄带包围盒**（模型真正占据的范围）而不是整场分配范围：
## 分块世界式的场会留大量余量，按整场算会让 res 被留白稀释 —— 细腿、帽檐
## 这类小结构会整个消失。详见 [method SdfTool.band_bounds]。
##
## 场为空 / 无窄带 / res 非法时返回**空体素网格**（[method SdfVoxel.is_empty] 为 true），不崩。
static func extract(field: SdfField, res: int, opts := {}) -> SdfVoxel:
	var v := SdfVoxel.new()
	v.res = res
	## `cell` = 直接指定体素方块的**物理边长**（米），给了就压过 res。
	## 这不是"多一个参数"的问题，而是分寸问题：res 是"最长边切几格"，
	## 换算出的边长 = 窄带盒最长边 / res，而窄带盒比模型本身宽出约 2×band
	## （band 默认 3×voxel_size，即 0.36~0.8 米）。于是"同一份 res 换算规则"下，
	## 7.9 米的大楼误差 9%，1.16 米的长椅误差 66% —— 同一场景里的方块大小能差一倍以上，
	## 而日志里所有数字都"正常"。要"全场统一方块"就必须能直接说边长是多少米。
	var cell := float(_opt(opts, &"cell", 0.0))
	if field == null or (res <= 0 and cell <= 0.0) or field.chunks.is_empty():
		return v
	## 局部包围盒：SdfTool.*_bounds 给世界坐标，减掉 field.origin 即场局部空间 ——
	## 与 MeshExtractor 的 `c.origin - field.origin` 完全一致，两条输出路径因此可同框比对。
	var fit := String(_opt(opts, &"fit", "band"))
	var wb := SdfTool.band_bounds(field)
	if (wb.size.x <= 0.0 or wb.size.y <= 0.0 or wb.size.z <= 0.0) and fit != "band":
		wb = SdfTool.bounds(field)
	var lb := AABB(wb.position - field.origin, wb.size)
	if lb.size.x <= 0.0 or lb.size.y <= 0.0 or lb.size.z <= 0.0:
		return v
	var margin := float(_opt(opts, &"margin", 0.0))
	if margin != 0.0:
		lb = AABB(lb.position - Vector3.ONE * margin, lb.size + Vector3.ONE * (margin * 2.0))
	var grid := _grid(lb.size, res, cell)
	var voxel: float = grid[0]
	var dims: Vector3i = grid[1]
	if voxel <= 0.0 or dims.x <= 0 or dims.y <= 0 or dims.z <= 0:
		return v
	if dims.x * dims.y * dims.z > MAX_VOXELS:
		push_error("VoxelExtractor.extract: %d³ 超过单次上限，换更大的 res 或先裁场" % dims.x)
		return v
	v.origin = lb.position
	v.voxel = voxel
	v.size = dims
	v.data.resize(v.voxel_count())
	v.data.fill(SdfVoxel.EMPTY)
	v.palette = _palette_of(opts)

	var threshold := float(_opt(opts, &"threshold", 0.0))
	var th := threshold - float(_opt(opts, &"shrink", 0.0)) * voxel
	## 场外值必须 ≥ 阈值：否则缺失体素（读到 band）会被整片判成实心
	var out_v := maxf(float(_opt(opts, &"band", field.band)), th)
	## —— 为什么不用 field.sample() ——
	## sample() 是三线性插值，一个查询要读 8 个场体素（跨块时每格还要一次
	## Dictionary 查找 + 越界判断，实测单次约 1.5 µs）。体素化只需要"这个体素
	## 中心在不在里面"，各向同性采样并不增加信息量，纯属浪费。
	## 下面直接遍历 chunk 的 PackedFloat32Array：每次查询 1 次整数比较 + 1 次
	## 数组读（~0.15 µs），64³ 网格的查询成本降到原来的 1/8~1/10。
	## 代价是最近邻采样（不做插值）—— 体素产物本来就是离散的，无损失。
	var fcs := float(field.chunk_size)
	var fvs := field.voxel_size
	var ox := field.origin.x + v.origin.x
	var oy := field.origin.y + v.origin.y
	var oz := field.origin.z + v.origin.z
	## 块缓存：体素遍历空间局部性极强（同行连续十几个体素几乎总在同一块），
	## 命中缓存即可跳掉 Dictionary 哈希与坐标换算
	var _ck := Vector3i(2147483647, 2147483647, 2147483647)  ## 哨兵：不可能是合法块坐标
	var _cs := 0
	var _cd := PackedFloat32Array()
	var layers := v.palette.size()
	## 部位分色表：[{&"aabb": AABB（场全局坐标）, &"index": int}, ...]，按顺序首个命中即用。
	## 空 = 纯高度分层（历史行为）。见 [method _tinted]。
	var tint: Array = opts.get(&"tint_regions", opts.get("tint_regions", []))
	for z in dims.z:
		var wz := oz + (float(z) + 0.5) * voxel
		var lz := floori((wz - field.origin.z) / fvs)
		var kz := floori(float(lz) / fcs)
		for y in dims.y:
			var wy := oy + (float(y) + 0.5) * voxel
			var ly := floori((wy - field.origin.y) / fvs)
			var ky := floori(float(ly) / fcs)
			var row := (z * dims.y + y) * dims.x
			var pv := _layer_index(y, dims.y, layers)
			for x in dims.x:
				var wx := ox + (float(x) + 0.5) * voxel
				var lx := floori((wx - field.origin.x) / fvs)
				var ck := Vector3i(floori(float(lx) / fcs), ky, kz)
				if ck != _ck:
					_ck = ck
					var c: SdfChunk = field.chunks.get(ck)
					if c == null:
						_cs = 0
						_cd = PackedFloat32Array()
					else:
						_cs = c.size
						_cd = c.data
				var d := out_v
				if _cs > 0:
					var lcx := lx - ck.x * field.chunk_size
					var lcy := ly - ck.y * field.chunk_size
					var lcz := lz - ck.z * field.chunk_size
					if lcx >= 0 and lcx < _cs and lcy >= 0 and lcy < _cs and lcz >= 0 and lcz < _cs:
						d = _cd[(lcz * _cs + lcy) * _cs + lcx]
					else:
						## 跨块边界的 1~2 格：交回给场做钳制（它认得邻块，缺失时返回 band）
						d = field.get_voxel(lx, ly, lz)
				if d < th:
					v.data[row + x] = _tinted(tint, wx, wy, wz, pv)
	## 部位索引钳到调色板长度内。超界不会崩，但会在网格化时多出一个
	## **没有材质可挂的 surface**（[method SdfVoxel.to_greedy_mesh] 按索引建桶），
	## 那个部位就变成一片默认白 —— 又是一个"只丢颜色不报错"的坑。
	## 单趟钳位 + 只警告一次，让写错索引的人一眼看到写的是几。
	##
	## 必须放过 [constant SdfVoxel.EMPTY]（=255）：空体素本来就存 255，
	## 它不是"第 256 号颜色"，第一版漏了这个判断，把每个空体素都当成越界索引，
	## 于是每次抽取都刷一条假警告 —— 假警报和漏警报一样会让人忽略真警报。
	if layers > 0:
		var over := -1
		for i in v.data.size():
			var d := v.data[i]
			if d != SdfVoxel.EMPTY and d >= layers:
				if over < 0:
					over = d
				v.data[i] = layers - 1
		if over >= 0:
			push_warning("[VoxelExtractor] 部位分色索引 %d 超出调色板长度 %d，已钳到最后一位。" % [
				over, layers])
	return v


## 取某个体素的调色板索引。
##
## [param base] 是原本的高度分层结果，作为回退值。
##
## ============================ 为什么需要部位分色 ============================
## 纯高度分层（[method _layer_index]）只能表达"下浅上深"这类**与高度相关**的配色。
## 但体素场景里真正要区分的往往是**与高度无关的部位**：门框要深棕、窗户要暖黄发光、
## 招牌要红 —— 它们可能出现在任意高度。按高度上色会把这些部件涂成所在楼层的墙色。
##
## 所以让**生成器自报**部位到调色板索引的映射（[method PropGen.voxel_regions]）：
## 框架只负责按 AABB 命中测试，不理解"门"或"窗"是什么 —— 那是生成器的知识。
##
## 命中测试用 [method AABB.has_point]：体素中心 (wx,wy,wz) 与生成器局部空间同源
## （PropGen 的场原点为零向量），所以生成器给的 AABB 直接可用，框架不做换算。
static func _tinted(tint: Array, wx: float, wy: float, wz: float, base: int) -> int:
	if tint.is_empty():
		return base
	var p := Vector3(wx, wy, wz)
	for r in tint:
		var reg: Dictionary = r
		var box: Variant = reg.get(&"aabb", reg.get("aabb", null))
		if box is AABB and (box as AABB).has_point(p):
			return int(reg.get(&"index", reg.get("index", 0)))
	return base

#endregion

#region —— 网格 → 体素 ——

## 网格 → 体素网格（**射线奇偶计数**）。
##
## 为什么不用 `Geometry3D.is_point_in_mesh`：该函数要求三角形的**索引**已按盒内/盒外
## 顺序编码，用来测"点在三角形集合内"；直接喂等值面提取出的无序网格会得到错误结果。
## 这里从体素中心沿 +Y 打射线，用 `Geometry3D.ray_intersects_triangle` 数命中，
## **奇数 = 在内部**。
##
## **前提是网格闭合且流形**：奇偶计数只数射线穿过几次，不看法线，所以半破网格、
## 开口面、漏边的导出文件不会报错，只会**静默产出垃圾体素**。因此这里默认做一次
## 边界/非流形边体检（[method open_edge_count]）并 `push_warning`。
## 这也是 [MeshExtractor] 先把闭合修好才敢开这条路径的原因。
##
## 坐标约定与 [method extract] 一致：产物是**场局部坐标**（这里没有场，即网格自身
## 局部坐标），不含世界位移，两个产物可挂同一父节点下直接比对。
##
## `opts`：
## | 键 | 默认 | 说明 |
## |---|---|---|
## | `&"transform"` | `Transform3D.IDENTITY` | 施加到网格顶点上的变换（世界网格转局部就传它的逆） |
## | `&"bounds"` | 变换后的网格 AABB | 覆盖体素网格的定位范围 |
## | `&"margin"` | 0.0 | 定位盒外扩的**米数**，留空白边框用 |
## | `&"palette"` | `[]` | 调色板；给了就按归一化高度分层（同 [method extract]） |
## | `&"check_closed"` | true | 体检边界/非流形边并 `push_warning`。三角形数超
##   [constant CLOSED_CHECK_MAX] 时跳过体检（只警告，不阻断） |
##
## 网格为空 / res 非法时返回**空体素网格**，不崩。
static func extract_from_mesh(mesh: Mesh, res: int, opts := {}) -> SdfVoxel:
	var v := SdfVoxel.new()
	v.res = res
	if mesh == null or res <= 0:
		return v
	var xf: Transform3D = _opt(opts, &"transform", Transform3D.IDENTITY)
	var aabb: AABB = _opt(opts, &"bounds", _mesh_bounds(mesh, xf))
	var margin := float(_opt(opts, &"margin", 0.0))
	if margin != 0.0:
		aabb = AABB(aabb.position - Vector3.ONE * margin, aabb.size + Vector3.ONE * (margin * 2.0))
	if aabb.size.x <= 0.0 or aabb.size.y <= 0.0 or aabb.size.z <= 0.0:
		return v
	var grid := _grid(aabb.size, res)
	var voxel: float = grid[0]
	var dims: Vector3i = grid[1]
	if voxel <= 0.0 or dims.x <= 0 or dims.y <= 0 or dims.z <= 0:
		return v
	if dims.x * dims.y * dims.z > MAX_VOXELS:
		push_error("VoxelExtractor.extract_from_mesh: %d³ 超过单次上限，换更大的 res" % dims)
		return v
	v.origin = aabb.position
	v.voxel = voxel
	v.size = dims
	v.data.resize(v.voxel_count())
	v.data.fill(SdfVoxel.EMPTY)
	v.palette = _palette_of(opts)

	var tris := _mesh_tris(mesh, xf)
	if tris.is_empty():
		return v
	if bool(_opt(opts, &"check_closed", true)) and tris.size() / 3 <= CLOSED_CHECK_MAX:
		var bad := open_edge_count(tris)
		if bad > 0:
			push_warning("VoxelExtractor.extract_from_mesh: 网格有 %d 条边界/非流形边（非闭合），" % bad
				+ "射线奇偶计数会失真，体素结果不可信。请改用 SDF 场的 extract()。")
	var cand := _column_candidates(_tri_aabbs(tris), aabb.position, voxel, dims)
	## 空字典 = 预筛超 [constant EDGE_CHECK_MAX] 被放弃。退化路径只慢不错：
	## 造一张"全部三角形"的候选表给所有列共用，**不能**按列展开 —— 那要 ncol×ntri 条。
	var brute := cand.is_empty()
	var starts := PackedInt32Array()
	var items := PackedInt32Array()
	if brute:
		var ntri := tris.size() / 3
		items.resize(ntri)
		for t in ntri:
			items[t] = t
	else:
		starts = cand["starts"]
		items = cand["items"]
	var layers := v.palette.size()
	var eps := maxf(maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z)) * HIT_EPS_RATIO, 1e-6)
	## 命中高度的去重缓冲。用**普通 Array**而不是 Packed 数组：Packed 是值类型，
	## 跨函数 append 只改副本（缓冲就白开了），而每个体素新建一个 Packed 数组更不能接受。
	var hits: Array = []
	var nx := dims.x
	for z in dims.z:
		for x in dims.x:
			var c0 := 0
			var c1 := items.size()
			if not brute:
				var col := z * nx + x
				c0 = starts[col]
				c1 = starts[col + 1]
				if c0 >= c1:
					continue    ## 本列没有任何候选三角形 → 整列必然空
			var row := z * dims.y * nx
			var px := v.origin.x + (float(x) + 0.5) * voxel
			var pz := v.origin.z + (float(z) + 0.5) * voxel
			for y in dims.y:
				## 采样点取**精确体素中心**，不加任何抖动：去重已经把唯一的结构性退化
				## （共享棱双计数）治好了，抖动只会引入"位移平行于接缝"这种治不好的假希望。
				var p := Vector3(px, v.origin.y + (float(y) + 0.5) * voxel, pz)
				if (_parity_hit(tris, p, items, c0, c1, eps, hits) & 1) == 1:
					v.data[row + y * nx + x] = _layer_index(y, dims.y, layers)
	return v

## 顶点坐标 → 量化键（1e-5 m 网格，[Vector3i]）。
## 量化是为了让"同一个位置的不同索引"认成同一个顶点，见 [method open_edge_count]。
static func _qkey(v: Vector3) -> Vector3i:
	return Vector3i(roundi(v.x * 100000.0), roundi(v.y * 100000.0), roundi(v.z * 100000.0))

## **非闭合边数**：每条边没有被恰好两个三角形共用（1 = 边界洞，>2 = 非流形）的条数。
## 0 = 闭合流形，此时射线奇偶计数的结果才可信。
##
## 必须按**量化顶点坐标**配对，不能按顶点下标 —— 同一个几何位置完全可能有多个下标。
## 活例子就是 [BoxMesh]：六个面各带自己的一套顶点，位置重合但下标不同，
## 按下标配对会把闭合盒子判成"到处是洞"。
static func open_edge_count(tris: PackedVector3Array) -> int:
	var ids := {}    ## Vector3i(量化位置) → int32 唯一编号
	var edges := {}  ## int64(打包的两个编号) → 共用次数
	for b in range(0, tris.size(), 3):
		for e in 3:
			var ka := _qkey(tris[b + e])
			var kb := _qkey(tris[b + (e + 1) % 3])
			var ia := _id_of(ids, ka)
			var ib := _id_of(ids, kb)
			if ia == ib:
				continue    ## 退化边（两点重合），不计入
			var lo := mini(ia, ib)
			var hi := maxi(ia, ib)
			## GDScript 的 int 本身就是 64 位，**没有** `int64()` 构造（写了直接解析报错）。
			var k := (lo << 32) | hi
			edges[k] = int(edges.get(k, 0)) + 1
	var bad := 0
	for k in edges:
		if int(edges[k]) != 2:
			bad += 1
	return bad

## 量化位置 → 稠密 int32 编号（顺带把位置去重，收敛表大小）。
static func _id_of(ids: Dictionary, k: Vector3i) -> int:
	var n := int(ids.get(k, -1))
	if n < 0:
		n = ids.size()
		ids[k] = n
	return n

## 摊平三角形（每 3 个 [Vector3] 一个三角形），已施加 `xf`。
## 量化顶点坐标后按 [_key_gt] 定序：三角形顺序与 surface 顺序、索引顺序无关，
## 同一网格两次调用得到逐位一致的结果。
static func _mesh_tris(mesh: Mesh, xf: Transform3D) -> PackedVector3Array:
	var tris := PackedVector3Array()
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		if not xf.is_equal_approx(Transform3D.IDENTITY):
			for i in verts.size():
				verts[i] = xf * verts[i]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if idx.size() >= 3:
			for t in idx.size() / 3:
				tris.append(verts[idx[t * 3]])
				tris.append(verts[idx[t * 3 + 1]])
				tris.append(verts[idx[t * 3 + 2]])
		else:
			for t in verts.size() / 3:
				tris.append(verts[t * 3])
				tris.append(verts[t * 3 + 1])
				tris.append(verts[t * 3 + 2])
	return _reorder(tris)

## 按量化最小角点给三角形定序，返回**新**数组。
##
## 不能原地重排后返回 `void`：[Packed*Array] 是值类型（写时复制），跨函数写元素
## 触发 CoW 改到的是副本 —— 调用方拿回的还是乱序，且**不报任何错**。
## 同 [SdfVoxel._push_quad] 那条坑：容器要么走返回值，要么走 Dictionary 进出。
static func _reorder(tris: PackedVector3Array) -> PackedVector3Array:
	var n := tris.size() / 3
	if n < 2:
		return tris
	var keys: Array[Vector3i] = []
	keys.resize(n)
	for t in n:
		var b := t * 3
		var lo := tris[b]
		lo = lo.min(tris[b + 1]).min(tris[b + 2])
		keys[t] = _qkey(lo)
	var order := range(n)
	order.sort_custom(func(a: int, b: int) -> bool: return _key_gt(keys[a], keys[b]))
	var sorted := PackedVector3Array()
	sorted.resize(tris.size())
	for o in n:
		var t: int = order[o]
		sorted[o * 3] = tris[t * 3]
		sorted[o * 3 + 1] = tris[t * 3 + 1]
		sorted[o * 3 + 2] = tris[t * 3 + 2]
	return sorted

## 量化顶点坐标的字典序比较（1e-5 m 网格）。只用于给三角形定序，
## 不参与任何几何判定 —— 量化精度抖动不到体素量级。
static func _key_gt(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x:
		return a.x > b.x
	if a.y != b.y:
		return a.y > b.y
	return a.z > b.z

## 变换后的网格 AABB。**必须变换 8 个角点**再取 min/max ——
## 直接对 AABB 套变换（`xf * aabb`）只搬了原有角点，旋转/缩放后新占据的位置会被漏掉。
static func _mesh_bounds(mesh: Mesh, xf: Transform3D) -> AABB:
	var src := mesh.get_aabb()
	if xf.is_equal_approx(Transform3D.IDENTITY):
		return src
	var out := AABB()
	for i in 8:
		var p := xf * src.get_endpoint(i)
		out = out.expand(p) if i > 0 else AABB(p, Vector3.ZERO)
	return out

## 每三角形的 AABB（含自身），预筛与闭合排查都要用。
static func _tri_aabbs(tris: PackedVector3Array) -> Array[AABB]:
	var out: Array[AABB] = []
	for b in range(0, tris.size(), 3):
		var ab := AABB(tris[b], Vector3.ZERO)
		ab = ab.expand(tris[b + 1])
		ab = ab.expand(tris[b + 2])
		out.append(ab)
	return out

## (x, z) 列 → 候选三角形下标。同列所有体素共享一份候选，命中率极高。
##
## 用**计数排序**而不是 `Dictionary[key] += tri` 拼 PackedInt32Array：
## Packed 数组是值类型，字典取值再 append 只会改到副本（每 append 一次全量拷贝，
## 退化到 O(n²)）。这里两遍扫描（先计数再填）一趟成型。
##
## 返回 `{starts: PackedInt32Array(nx*nz+1), items: PackedInt32Array}`，
## 第 k 列的候选是 `items[starts[k] .. starts[k+1])`。
static func _column_candidates(aabbs: Array[AABB], origin: Vector3, voxel: float,
		dims: Vector3i) -> Dictionary:
	var nx := dims.x
	var nz := dims.z
	var ncol := nx * nz
	## —— 第一遍：逐三角形数它横跨多少 (x, z) 列；总量超限就返回空字典表示"放弃预筛" ——
	var counts := PackedInt32Array()
	counts.resize(ncol)
	var total := 0
	for t in aabbs.size():
		var r := _col_range(aabbs[t], origin, voxel, nx, nz)
		for j in range(r.y, r.w + 1):
			for i in range(r.x, r.z + 1):
				counts[j * nx + i] += 1
				total += 1
		if total > EDGE_CHECK_MAX:
			return {}
	## —— 前缀和：第 k 列的候选段是 [starts[k], starts[k+1]) ——
	var starts := PackedInt32Array()
	starts.resize(ncol + 1)
	var cursor := PackedInt32Array()
	cursor.resize(ncol)
	var acc := 0
	for k in ncol:
		starts[k] = acc
		cursor[k] = acc
		acc += counts[k]
	starts[ncol] = acc
	## —— 第二遍：按计数填表 ——
	var items := PackedInt32Array()
	items.resize(acc)
	for t in aabbs.size():
		var r := _col_range(aabbs[t], origin, voxel, nx, nz)
		for j in range(r.y, r.w + 1):
			for i in range(r.x, r.z + 1):
				var k := j * nx + i
				items[cursor[k]] = t
				cursor[k] += 1
	return {"starts": starts, "items": items}

## 三角形 AABB 覆盖的 (x, z) 列区间，返回 `(i0, j0, i1, j1)`（已钳进网格）。
static func _col_range(b: AABB, origin: Vector3, voxel: float, nx: int, nz: int) -> Vector4i:
	return Vector4i(
		clampi(floori((b.position.x - origin.x) / voxel), 0, nx - 1),
		clampi(floori((b.position.z - origin.z) / voxel), 0, nz - 1),
		clampi(floori((b.end.x - origin.x) / voxel), 0, nx - 1),
		clampi(floori((b.end.z - origin.z) / voxel), 0, nz - 1))

## 从 `p` 沿 +Y 打射线，返回**去重后**的命中数（调用方取 `& 1`，奇数 = 在内部）。
##
## 去重是正确性必需，不是优化：射线正好打在两个三角形的**共享棱**上时，
## `ray_intersects_triangle` 对两个三角形都返回命中 → 计 2 次 → 偶数 → 整条列被判空。
## 2×2 盒子的顶面由 2 个三角形拼成，其对角棱正下方的 32 条列会全部变空（实测）。
## 抖动起点治不了这个：位移平行于接缝时点仍留在接缝上。
##
## 射线沿 +Y，命中点的 y 就是射线参数 t，直接按 y 聚类。
## `hits` 是调用方复用的缓冲（普通 Array，引用语义；Packed 数组跨函数写只改副本）。
static func _parity_hit(tris: PackedVector3Array, p: Vector3, items: PackedInt32Array,
		from: int, to: int, eps: float, hits: Array) -> int:
	hits.clear()
	for k in range(from, to):
		var b := items[k] * 3
		var hp: Variant = Geometry3D.ray_intersects_triangle(p, Vector3.UP,
				tris[b], tris[b + 1], tris[b + 2])
		if hp == null:
			continue
		var hy: float = (hp as Vector3).y
		var dup := false
		for i in hits.size():
			if absf(float(hits[i]) - hy) <= eps:
				dup = true
				break
		if not dup:
			hits.append(hy)
	return hits.size()

#endregion

#region —— 内部工具 ——

## 由包围盒尺寸与最长边分辨率推出等比体素网格。体素边长 = 最长边 / res（保持立方）。
## 返回 `[voxel: float, size: Vector3i]`；短边至少 1 体素，避免退化成 0 厚。
##
## [param cell] > 0 时直接用它当边长（见 [method extract] 的说明），此时 res 不参与换算，
## 只影响"切几格"的副产品读数。窄带盒多出来的余量此时只多出几圈空体素，
## 不会再去改变方块本身的物理尺寸 —— 这正是"直接给边长"与"给分辨率"的本质差别。
static func _grid(box: Vector3, res: int, cell := 0.0) -> Array:
	var longest := maxf(box.x, maxf(box.y, box.z))
	if longest <= 0.0:
		return [0.0, Vector3i.ZERO]
	var voxel := cell if cell > 0.0 else longest / float(maxi(res, 1))
	## 减一个极小量：6.0/0.5 在二进制里可能是 12.000001，直接 ceili 会多出一层空片
	var ex := maxf(box.x / voxel - 1e-6, 1e-6)
	var ey := maxf(box.y / voxel - 1e-6, 1e-6)
	var ez := maxf(box.z / voxel - 1e-6, 1e-6)
	return [voxel, Vector3i(maxi(1, ceili(ex)), maxi(1, ceili(ey)), maxi(1, ceili(ez)))]

## 调色板：调用方给了就用，没给就是单色（索引 0）。
static func _palette_of(opts: Dictionary) -> Array[Color]:
	var out: Array[Color] = []
	var src: Array = opts.get(&"palette", opts.get("palette", []))
	for c in src:
		out.append(c)
	return out

## 取 opts 键。StringName 与 String 两种键都认：本模块对外用 [code]&"..."[/code]（GDScript 里
## 字面量本身就是 StringName），但既有 [MeshExtractor] 用的是普通 String 字符串键，
## 两边混用会让调用方踩空，故此处两种都试。
static func _opt(opts: Dictionary, key: StringName, def: Variant) -> Variant:
	if opts.has(key):
		return opts[key]
	return opts.get(String(key), def)

## 按归一化高度选调色板索引（自下而上分层）。索引 254 恒为结构色占位，必须跳过。
static func _layer_index(y: int, dims_y: int, layers: int) -> int:
	if layers <= 0:
		return 0
	if dims_y <= 1:
		return 0
	var i := clampi(int(float(y) / float(dims_y) * float(layers)), 0, layers - 1)
	return mini(i, SdfVoxel.STRUCT - 1)

#endregion