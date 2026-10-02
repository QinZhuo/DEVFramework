class_name SdfField
extends RefCounted
## 标量距离场（SDF）— 分块稠密存储 + 三线性采样 + 梯度
##
## 坐标系：世界坐标 p → 局部体素坐标 (p - origin) / voxel_size。
## origin = Vector3.ZERO 时即为"局部空间"，用于独立物体生成（物体不知道自己在世界何处）；
## origin 设成块世界原点时即为全局场，用于地形。两种模式共用同一套采样/提取代码。
##
## 符号约定：d < 0 内部，d > 0 外部。
##
## == 槽位（slots）==
## 纯标量场携带不了"这是屋顶 / 这是玻璃"这类语义，因此每个体素并行挂一个
## 材质槽位号（0~253，[constant SLOT_NONE]=255 表示未指定）。
## 槽位是"纯色分件"的底座：几何只算一次，颜色由槽位 → 色板在着色端解决。

const SLOT_NONE := 255            ## 未指定槽位（与 SdfChunk.SLOT_NONE 同值）

var chunk_size := 32          ## 每块边长（体素数）
var voxel_size := 0.25        ## 体素边长（米）
var origin := Vector3.ZERO    ## 场原点（世界坐标）
var band := 0.75              ## 窄带半宽（米）：|d| 超过它即可判定该体素附近无面
var chunks := {}              ## Vector3i → SdfChunk

## —— 读取快路径缓存 ——
## 提取器对体素的访问有极强的空间局部性（同一单元的 8 角点、梯度六邻域都在一块内），
## 缓存上一次命中的块可省掉大部分 Dictionary 哈希查找。
## 哨兵初值必须是不可能出现的块坐标：(0,0,0) 是合法块坐标，会让首次访问误命中空缓存。
const _CK_NONE := Vector3i(2147483647, 2147483647, 2147483647)
var _ck_cache := _CK_NONE
var _c_cache: SdfChunk = null

static func create(p_chunk_size := 32, p_voxel_size := 0.25, p_origin := Vector3.ZERO, p_band := -1.0) -> SdfField:
	var f := SdfField.new()
	f.chunk_size = p_chunk_size
	f.voxel_size = p_voxel_size
	f.origin = p_origin
	f.band = p_band if p_band >= 0.0 else p_voxel_size * 3.0
	return f

func _chunk_coord(lx: int, ly: int, lz: int) -> Vector3i:
	var cs := float(chunk_size)
	return Vector3i(floori(lx / cs), floori(ly / cs), floori(lz / cs))

func get_chunk(ck: Vector3i, create_if_missing := true) -> SdfChunk:
	var c: SdfChunk = chunks.get(ck)
	if c == null and create_if_missing:
		c = SdfChunk.create(chunk_size, band)
		c.origin = origin + Vector3(ck) * float(chunk_size) * voxel_size
		chunks[ck] = c
	return c

func has_chunk(ck: Vector3i) -> bool:
	return chunks.has(ck)

## —— 体素存取（局部体素整数坐标）——

func _voxel(lx: int, ly: int, lz: int) -> float:
	var cs := chunk_size
	var ck := Vector3i(floori(float(lx) / cs), floori(float(ly) / cs), floori(float(lz) / cs))
	var c: SdfChunk = null
	if ck == _ck_cache:
		c = _c_cache
	else:
		c = chunks.get(ck)
		_ck_cache = ck
		_c_cache = c
	if c == null:
		return band
	## 块内索引直接用整数算术（原先走 origin 差 + 浮点除法，慢 ~2 倍且有精度风险）
	return c.get_cell(lx - ck.x * cs, ly - ck.y * cs, lz - ck.z * cs, band)

func _set_voxel(lx: int, ly: int, lz: int, v: float) -> void:
	var ck := _chunk_coord(lx, ly, lz)
	var c := get_chunk(ck)
	var cs := chunk_size
	c.set_cell(lx - ck.x * cs, ly - ck.y * cs, lz - ck.z * cs, v)

func get_voxel(lx: int, ly: int, lz: int) -> float:
	return _voxel(lx, ly, lz)

func set_voxel(lx: int, ly: int, lz: int, v: float) -> void:
	_set_voxel(lx, ly, lz, v)

## 局部体素坐标 → 世界坐标（体素中心）
func voxel_to_world(lx: int, ly: int, lz: int) -> Vector3:
	return origin + (Vector3(lx, ly, lz) + Vector3(0.5, 0.5, 0.5)) * voxel_size

func world_to_voxel(p: Vector3) -> Vector3:
	return (p - origin) / voxel_size

## —— 采样（世界坐标）——

## 三线性插值采样；越界返回 band（视为空）
func sample(p: Vector3) -> float:
	var lv := world_to_voxel(p)
	var fx := floorf(lv.x); var fy := floorf(lv.y); var fz := floorf(lv.z)
	var ix := int(fx); var iy := int(fy); var iz := int(fz)
	var tx := lv.x - fx; var ty := lv.y - fy; var tz := lv.z - fz
	var c000 := _voxel(ix, iy, iz)
	var c100 := _voxel(ix + 1, iy, iz)
	var c010 := _voxel(ix, iy + 1, iz)
	var c110 := _voxel(ix + 1, iy + 1, iz)
	var c001 := _voxel(ix, iy, iz + 1)
	var c101 := _voxel(ix + 1, iy, iz + 1)
	var c011 := _voxel(ix, iy + 1, iz + 1)
	var c111 := _voxel(ix + 1, iy + 1, iz + 1)
	var x00 := lerpf(c000, c100, tx)
	var x10 := lerpf(c010, c110, tx)
	var x01 := lerpf(c001, c101, tx)
	var x11 := lerpf(c011, c111, tx)
	return lerpf(lerpf(x00, x10, ty), lerpf(x01, x11, ty), tz)

## 中心差分梯度 —— SDF 的法线来源（指向外部），三渲二硬边的关键
func gradient(p: Vector3) -> Vector3:
	var h := voxel_size
	var g := Vector3(
		sample(p + Vector3(h, 0, 0)) - sample(p - Vector3(h, 0, 0)),
		sample(p + Vector3(0, h, 0)) - sample(p - Vector3(0, h, 0)),
		sample(p + Vector3(0, 0, h)) - sample(p - Vector3(0, 0, h)))
	var l := g.length()
	return g / l if l > 1e-8 else Vector3.UP

## 该点是否在实心内部
func is_inside(p: Vector3) -> bool:
	return sample(p) < 0.0

## —— 统计 ——
func chunk_count() -> int:
	return chunks.size()

func is_empty() -> bool:
	for ck in chunks:
		var c: SdfChunk = chunks[ck]
		if c.intersects_band(band):
			return false
	return true


#region —— 槽位（材质分件）——
#
# 槽位与 data 平行存储、**懒分配**：一个从没被赋过槽位的场不该为它白付 +25% 内存。
# 因此所有读路径都容忍"未分配"（读出 SLOT_NONE），只有写路径才ensure。

## 全场体素总数（各块 data.size() 之和）
func voxel_count() -> int:
	var n := 0
	for ck in chunks:
		var c: SdfChunk = chunks[ck]
		n += c.data.size()
	return n

## 所有块是否都已分配同长槽位。空场返回 true（无可分件之物）。
func has_slots() -> bool:
	for ck in chunks:
		var c: SdfChunk = chunks[ck]
		if not c.has_slots():
			return false
	return true

## 为所有块懒分配槽位通道（整表填 SLOT_NONE）
func ensure_slots() -> void:
	for ck in chunks:
		var c: SdfChunk = chunks[ck]
		c.ensure_slots()

## 释放全场槽位通道，回到"未分配"状态。
func clear_slots() -> void:
	for ck in chunks:
		var c: SdfChunk = chunks[ck]
		c.clear_slots()

## —— 局部体素整数坐标寻址（跨块）——
## 读取**不**触发全场分配：目标块没分配槽位就直接返回 SLOT_NONE。
## 这样提取器逐顶点查槽位时不会为"其实没分件"的场默默分配几百 MB。
func slot_at_world(voxel: Vector3i) -> int:
	var ck := _chunk_coord(voxel.x, voxel.y, voxel.z)
	var c: SdfChunk = chunks.get(ck)
	if c == null or not c.has_slots():
		return SLOT_NONE
	return c.get_slot(_local_slot_index(voxel, ck))

## 按局部体素整数坐标写槽位；块不存在返回 false（不凭空造块）。
func set_slot_world(voxel: Vector3i, s: int) -> bool:
	var ck := _chunk_coord(voxel.x, voxel.y, voxel.z)
	var c: SdfChunk = chunks.get(ck)
	if c == null:
		return false
	c.set_slot(_local_slot_index(voxel, ck), s)
	return true

## 场局部体素坐标 → 目标块内线性索引（与 SdfChunk 的布局同序）
func _local_slot_index(voxel: Vector3i, ck: Vector3i) -> int:
	var cs := chunk_size
	var lx := voxel.x - ck.x * cs
	var ly := voxel.y - ck.y * cs
	var lz := voxel.z - ck.z * cs
	return (lz * cs + ly) * cs + lx

## —— 全场线性索引寻址 ——
## li 为跨块顺序拼起来的下标：块按 chunks 字典序、块内按 SdfChunk 的线性序。
## 仅供存档 / 外部批量工具用，日常按坐标寻址更直观。

func slot_at(li: int) -> int:
	if li < 0:
		return SLOT_NONE
	for ck in chunks:
		var c: SdfChunk = chunks[ck]
		var n := c.data.size()
		if li < n:
			return c.get_slot(li)
		li -= n
	return SLOT_NONE

func set_slot_at(li: int, s: int) -> void:
	if li < 0:
		return
	ensure_slots()
	for ck in chunks:
		var c: SdfChunk = chunks[ck]
		var n := c.data.size()
		if li < n:
			c.set_slot(li, s)
			return
		li -= n

## —— 批量赋槽位 ——

## 把**实心**体素（data < 0）赋槽位 s，返回赋值个数。
## overwrite = false 时只动当前为 SLOT_NONE 的体素（先来先得，便于"主体 → 细节"分层赋值）。
##
## band_only = true（默认）**只扫窄带**。这是性能关键，不是省事：
## 等值面只可能出现在 |d| <= band 的体素上（SDF 是 1-Lipschitz 的），
## 窄带外的实心体素全是深埋内部量，**永远不会被提取器读到**，扫它们纯属白烧 CPU。
## 量级上：整块扫是 32³ = 32768 次读，典型薄壳的窄带盒往往只有几百体素 —— 差 1~2 个数量级。
## 需要给"整个实心区域"（含深埋内部）标语义时再传 false。
func assign_slot_solid(s: int, overwrite := false, band_only := true) -> int:
	ensure_slots()
	var total := 0
	for ck in chunks:
		var c: SdfChunk = chunks[ck]
		var lo := Vector3i.ZERO
		var hi := Vector3i(c.size - 1, c.size - 1, c.size - 1)
		if band_only:
			if not c.intersects_band(band):
				continue    ## 整块无面，跳过
			lo = c.band_lo
			hi = c.band_hi
		total += _assign_in(c, lo, hi, s, overwrite)
	return total

## 限定在**局部体素坐标 AABB** 内赋槽位（"这段子图归某色"），
## 供生成器按语义分区（屋顶层 / 墙体层 / 窗洞层）使用。返回赋值个数。
## 与 [method assign_slot_solid] 不同：这里**必须**扫全盒（盒可能被调用方取得比窄带大）。
func assign_slot_solid_aabb(s: int, box: AABB, overwrite := false) -> int:
	ensure_slots()
	if box.size.x <= 0.0 or box.size.y <= 0.0 or box.size.z <= 0.0:
		return 0
	var blo := Vector3i(floori(box.position.x), floori(box.position.y), floori(box.position.z))
	var bhi := Vector3i(ceili(box.end.x) - 1, ceili(box.end.y) - 1, ceili(box.end.z) - 1)
	var cs := chunk_size
	var total := 0
	# 只遍历盒子跨到的块；chunks.get 不造新块
	var cx0 := floori(float(blo.x) / cs)
	var cx1 := floori(float(bhi.x) / cs)
	var cy0 := floori(float(blo.y) / cs)
	var cy1 := floori(float(bhi.y) / cs)
	var cz0 := floori(float(blo.z) / cs)
	var cz1 := floori(float(bhi.z) / cs)
	for cz in range(cz0, cz1 + 1):
		for cy in range(cy0, cy1 + 1):
			for cx in range(cx0, cx1 + 1):
				var ck := Vector3i(cx, cy, cz)
				var c: SdfChunk = chunks.get(ck)
				if c == null:
					continue
				var lo := Vector3i(maxi(blo.x - cx * cs, 0), maxi(blo.y - cy * cs, 0),
						maxi(blo.z - cz * cs, 0))
				var hi := Vector3i(mini(bhi.x - cx * cs, c.size - 1), mini(bhi.y - cy * cs, c.size - 1),
						mini(bhi.z - cz * cs, c.size - 1))
				total += _assign_in(c, lo, hi, s, overwrite)
	return total

## 在单块内对体素局部闭区间 [lo, hi] 赋槽位；只碰实心且符合 overwrite 条件者。
func _assign_in(c: SdfChunk, lo: Vector3i, hi: Vector3i, s: int, overwrite: bool) -> int:
	var n := 0
	var cs := c.size
	## data 取只读局部快照（读不触发 CoW 拷贝）；**写必须走 c.slots[i]**：
	## Packed*Array 是值类型 + 写时拷贝，写进局部副本等于白写。
	var data := c.data
	var x0 := maxi(lo.x, 0)
	var x1 := mini(hi.x, cs - 1)
	var y0 := maxi(lo.y, 0)
	var y1 := mini(hi.y, cs - 1)
	for lz in range(maxi(lo.z, 0), mini(hi.z, cs - 1) + 1):
		var plane := lz * cs * cs
		for ly in range(y0, y1 + 1):
			var row := plane + ly * cs
			for lx in range(x0, x1 + 1):
				var i := row + lx
				if data[i] >= 0.0:
					continue
				if not overwrite and c.slots[i] != SLOT_NONE:
					continue
				c.slots[i] = s
				n += 1
	return n

## 槽位直方图 {slot: 体素数}，**不含** SLOT_NONE（它是"未指定"，不是配色）
func slot_histogram() -> Dictionary:
	var hist := {}
	for ck in chunks:
		var c: SdfChunk = chunks[ck]
		if not c.has_slots():
			continue
		for s in c.slots:
			if s == SLOT_NONE:
				continue
			hist[s] = int(hist.get(s, 0)) + 1
	return hist

#endregion
