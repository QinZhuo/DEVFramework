class_name SdfChunk
extends RefCounted
## SDF 场的单个体素块 — 稠密 float32 场
##
## 线性布局与 GeneratedGrid3D 保持一致：index = (z * size + y) * size + x
## 符号约定：d < 0 在内部（实心），d > 0 在外部（空），d == 0 即等值面。
## 未写入的体素填 band（视为远离表面的空腔），因此新建块即可当"全空"用。
##
## == 槽位（slots）==
## data 是**纯标量**，无法携带"这是屋顶 / 这是玻璃"这类语义，因此并行挂一条
## PackedByteArray 槽位通道：与 data 同序同长，每体素一个 0~253 的材质槽位号。
## 有了它，同一份几何既能直接烘成顶点色，也能在 shader 里按槽位查色板
## ——**换风格不重算网格**，这是本通道存在的全部理由。
## 槽位不参与窄带计算：它只在着色时读，不影响等值面位置。

const SLOT_NONE := 255            ## 未指定槽位。与 SdfField.SLOT_NONE 同值

var size := 32
var data := PackedFloat32Array()
## 与 data 等长的槽位通道（懒分配，未分配时视为全 [constant SLOT_NONE]）
var slots := PackedByteArray()
## 本块 (0,0,0) 体素中心对应的世界坐标
var origin := Vector3.ZERO

## —— 窄带包围盒（体素局部坐标，闭区间）——
## 等值面只能出现在窄带体素内。提取器据此只遍历窄带范围的单元，
## 而非整块 32³ —— 这是提取性能的主要来源（典型 5~10 倍差距）。
var band_valid := false
var band_lo := Vector3i.ZERO
var band_hi := Vector3i.ZERO

static func create(p_size: int, fill_value := 1.0) -> SdfChunk:
	var c := SdfChunk.new()
	c.size = p_size
	c.data.resize(p_size * p_size * p_size)
	c.data.fill(fill_value)
	return c

func _idx(x: int, y: int, z: int) -> int:
	return (z * size + y) * size + x

func in_bounds(x: int, y: int, z: int) -> bool:
	return x >= 0 and x < size and y >= 0 and y < size and z >= 0 and z < size

func get_cell(x: int, y: int, z: int, out_of_bounds := 1.0) -> float:
	if not in_bounds(x, y, z):
		return out_of_bounds
	return data[_idx(x, y, z)]

func set_cell(x: int, y: int, z: int, v: float) -> void:
	if in_bounds(x, y, z):
		data[_idx(x, y, z)] = v
		band_valid = false      ## 写入后窄带包围盒失效，需重算

## 本块是否可能存在等值面（存在 |d| <= band 的体素）。
## 提取器用它整块跳过：SDF 是 1-Lipschitz 的，|d| 远大于体素尺寸处不可能跨零。
## 副作用：同时算出 band_lo/band_hi 供提取器收窄遍历范围。
## SdfTool.fill 会顺手算好并置 band_valid，此处直接复用（提取路径零扫描成本）。
func intersects_band(band: float) -> bool:
	if band_valid:
		return true
	band_valid = false
	var mn := Vector3i(size, size, size)
	var mx := Vector3i(-1, -1, -1)
	var n := size
	for z in n:
		for y in n:
			var row := (z * n + y) * n
			for x in n:
				var v := data[row + x]
				if v < band and v > -band:
					mn.x = mini(mn.x, x); mn.y = mini(mn.y, y); mn.z = mini(mn.z, z)
					mx.x = maxi(mx.x, x); mx.y = maxi(mx.y, y); mx.z = maxi(mx.z, z)
	if mx.x < mn.x:
		return false
	band_lo = mn
	band_hi = mx
	band_valid = true
	return true

## 窄带包围盒（体素局部坐标 AABB）；无窄带时 size 为 0
func band_aabb() -> AABB:
	if not band_valid:
		return AABB()
	var mn := Vector3(band_lo)
	var mx := Vector3(band_hi) + Vector3.ONE
	return AABB(mn, mx - mn)


#region —— 槽位通道 ——

## 槽位通道是否已就绪（长度与 data 一致）。
## 未分配时视为全场 [constant SLOT_NONE]：着色退化为单色，不需要任何额外内存。
func has_slots() -> bool:
	return slots.size() == data.size()

## 懒分配槽位通道。**只有真的要写/读槽位时才付这份内存**（每体素 1 字节，
## 相对 data 的 4 字节是 +25%），因此不放在 create() 里。
func ensure_slots() -> void:
	if slots.size() == data.size():
		return
	slots.resize(data.size())
	slots.fill(SLOT_NONE)

## 写槽位。li 为**局部线性索引**（与 data 同序：lx + ly*size + lz*size*size）；
## 越界忽略。
## 长度不匹配时顺手懒分配：写入被静默丢弃是 bug 温床，宁可多占内存。
func set_slot(li: int, s: int) -> void:
	if li < 0 or li >= data.size():
		return
	if not has_slots():
		ensure_slots()
	slots[li] = clampi(s, 0, 255)

## 读槽位。越界或未分配一律返回 [constant SLOT_NONE]（视作"未指定"，不报错）。
func get_slot(li: int) -> int:
	if li < 0 or li >= data.size() or not has_slots():
		return SLOT_NONE
	return slots[li]

## 释放槽位通道（回到"未分配"状态，[method has_slots] 随之变 false）。
func clear_slots() -> void:
	slots = PackedByteArray()

#endregion
