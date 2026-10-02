class_name MeshExtractor
extends RefCounted
## SDF 等值面提取器 — 从标量场提取三角网格
##
## 两种算法共享同一套单元遍历与符号检测：
##
## | 算法 | 顶点位置 | 特点 |
## |---|---|---|
## | SURFACE_NETS | 穿越边交点平均 | 三角形均匀、质量好、成本最低，有机曲面首选 |
## | DUAL_CONTOURING | QEF 最小二乘解 | 顶点数少、**保棱角**，硬边风格首选 |
##
## 不提供 Marching Cubes：其 256 项三角表需手写 4096 个索引；Marching Tetrahedra
## 虽等价但面数明显更多。确需 MC 时走 gdextension 路线（框架已有原生库机制）。
##
## 这条取舍**实测过、不是假定**：本构建 Godot 4.7.2-stable 下
## [code]ClassDB.class_exists("MarchingCubes")[/code] 返回 [code]false[/code]，
## 即引擎并未提供内置等值面类，本模块自写 SurfaceNets / Dual Contouring 是必需而非重复造轮子。
## 若将来升级的引擎版本该值变为 true，再回头评估要不要换原生实现。
##
## 同理未用 [SurfaceTool]：它的 [method SurfaceTool.add_vertex] 是逐点调用，
## 而提取是十万级顶点的热路径；直接构造 [constant Mesh.ARRAY_MAX] 数组喂
## [method ArrayMesh.add_surface_from_arrays] 是官方推荐的热路径写法
## （[method SdfMesh.to_arraymesh] 同款取舍）。[MeshDataTool] 只做索引/多边形优化，
## 不做等值面，与本模块无关。
##
## 法线默认走 **主平面特征法线**（sharp_normal）：这是三渲二硬边的关键 ——
## 面法线平均会圆化棱角，梯度法线在棱角处是多个面的平均（同样圆化）；
## 而 QEF 的 ATA 最大特征值特征向量指向棱角所属的主导平面，硬边得以保留。
##
## == 槽位输出（可选）==
## 纯标量场提取出的网格只有一个"整体"，没法表达"屋顶 / 墙 / 玻璃"。
## 若场带了 [SdfField] 的槽位通道，本提取器可额外产出两条顶点通道：
##   - `ARRAY_COLOR`：按槽位查色板直接烘成顶点色（一次提取、一套颜色）
##   - `ARRAY_TEX_UV2`：把槽位号写进 uv2.x（= slot / 255），
##     **shader 端据此查色板 → 换配色不重新提取网格**。
## 两者都默认关闭：不请求就不生成数组，避免无谓的内存与行为变化。

enum Algo {
	SURFACE_NETS,
	DUAL_CONTOURING,
}

## 单元 8 角点（绕行编号，相邻角点同在一条棱上，便于边遍历）
const CORNERS: Array[Vector3i] = [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(1, 1, 0), Vector3i(0, 1, 0),
	Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(1, 1, 1), Vector3i(0, 1, 1),
]

## 12 条棱（角点对）
const EDGES: Array[Vector2i] = [
	Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3), Vector2i(3, 0),
	Vector2i(4, 5), Vector2i(5, 6), Vector2i(6, 7), Vector2i(7, 4),
	Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
]

var _field: SdfField
var _mesh: SdfMesh
var _vmap := {}              ## Vector3i 单元 → 顶点序号
var _cur := PackedFloat32Array()  ## 当前单元 8 角点值
var _vs := 0.25
var _base := Vector3.ZERO     ## chunk 原点 - field.origin（用于顶点定位，块局部 → 场局部）
var _ck_off := Vector3i.ZERO  ## 当前块的场局部体素偏移（cell 是块局部，采样必须加上它）
var _d := PackedFloat32Array()  ## 当前块的稠密数据（内联采样，省掉两层函数调用）
var _cs := 0                   ## 当前块边长

## 未指定槽位在**输出侧**折叠到的槽位号。
## 选 0（而不是 255）而不是留空：uv2.x 会被 shader 直接查色板，
## 折叠成合法索引后着色端不需要任何"未指定"分支。
const SLOT_FALLBACK := 0
var _algo := 0
var _dc_eps := 0.05
var _sharp := true
var _limited := false        ## 是否指定了体素范围（局部提取时裁剪用）
var _lo := Vector3i.ZERO
var _hi := Vector3i.ZERO
var _slots := PackedByteArray()  ## 当前块的槽位通道（与 _d 同样的内联快路径）
var _ck_has_slots := false       ## 当前块是否已分配槽位

#region —— 槽位输出（默认全关）——
var _want_color := false         ## 是否输出 ARRAY_COLOR
var _palette: Array[Color] = []  ## 槽位 → 颜色（按槽位号索引）
var _colors := PackedColorArray()
var _want_uv2 := false           ## 是否输出 ARRAY_TEX_UV2（.x = slot / 255）
var _uv2 := PackedVector2Array()
var _vslot := PackedInt32Array() ## 每顶点的原始槽位（保留 SLOT_NONE 供仲裁）

#endregion

## 提取网格（纯几何产物）。
##
## opts：
##   - `dc_eps` / `sharp_normal` / `voxel_lo` / `voxel_hi` —— 见各字段注释
##   - `vertex_colors`：`Array[Color]`（`PackedColorArray` 也收），**按槽位号索引**的色板。
##     给了就输出 [constant Mesh.ARRAY_COLOR]（索引越界回退白色）。
##   - `emit_slot_uv`：`bool`（默认 false）。给了就把槽位号写进
##     [constant Mesh.ARRAY_TEX_UV2] 的 `.x`（= `slot / 255.0`），
##     shader 端据此查色板，**换配色不必重新提取网格**。
static func extract(field: SdfField, algo := Algo.SURFACE_NETS, opts := {}) -> SdfMesh:
	return _setup(field, algo, opts)._run_mesh()

## 直接产出 Godot arrays（含槽位通道）。
## [method extract] 返回的 SdfMesh 是纯几何数据容器、装不下顶点色/UV2，
## 因此要槽位输出时走本入口（或 [method extract_arraymesh]）。
static func extract_arrays(field: SdfField, algo := Algo.SURFACE_NETS, opts := {}) -> Array:
	return _setup(field, algo, opts)._run_arrays()

## 一步到位出 [ArrayMesh]（要顶点色 / 槽位 UV2 时用这个）。
static func extract_arraymesh(field: SdfField, algo := Algo.SURFACE_NETS, opts := {},
		material: Material = null) -> ArrayMesh:
	var arrays := extract_arrays(field, algo, opts)
	var mesh := ArrayMesh.new()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		return mesh
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if material:
		mesh.surface_set_material(0, material)
	return mesh

static func _setup(field: SdfField, algo, opts) -> MeshExtractor:
	var ex := MeshExtractor.new()
	ex._field = field
	ex._algo = algo
	ex._dc_eps = float(opts.get("dc_eps", 0.05))
	ex._sharp = bool(opts.get("sharp_normal", true))
	## 注意：不能用 _lo/_hi 的默认值判"无限制" —— Vector3i(0) 与 (-1) 比较会误判成受限
	ex._limited = opts.has("voxel_lo") and opts.has("voxel_hi")
	ex._lo = opts.get("voxel_lo", Vector3i.ZERO)
	ex._hi = opts.get("voxel_hi", Vector3i.ZERO)
	## —— 槽位输出：只有显式给了键才开，绝不凭空生成 ——
	## 键名沿用本文件既有的普通 String 字面量风格（dc_eps / sharp_normal ...），
	## 不混用 StringName：跟随本地约定比赌引擎的键互通更稳。
	var colors: Variant = opts.get("vertex_colors", null)
	if colors != null:
		ex._palette = _as_color_array(colors)
		ex._want_color = true
	var slot_uv: bool = bool(opts.get("emit_slot_uv", false))
	ex._want_uv2 = slot_uv
	return ex

## 色板归一化成 Array[Color]。颜色在 Godot 里有两种常见容器，
## 调用方手上多半是 PackedColorArray —— 强转会让它在运行期炸掉，
## 这里一并收下，代价只在装配期一次性遍历。
static func _as_color_array(v: Variant) -> Array[Color]:
	var out: Array[Color] = []
	if v is PackedColorArray:
		for c in v:
			out.append(c)
		return out
	for c in v:
		out.append(c)
	return out

func _run_mesh() -> SdfMesh:
	_run()
	return _mesh

func _run_arrays() -> Array:
	_run()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _mesh.vertices
	arrays[Mesh.ARRAY_NORMAL] = _mesh.normals
	arrays[Mesh.ARRAY_INDEX] = _mesh.indices
	if _want_color:
		arrays[Mesh.ARRAY_COLOR] = _colors
	if _want_uv2:
		arrays[Mesh.ARRAY_TEX_UV2] = _uv2
	return arrays

func _run() -> void:
	_mesh = SdfMesh.new()
	_vs = _field.voxel_size
	_cur.resize(8)
	for ck in _field.chunks:
		var c: SdfChunk = _field.chunks[ck]
		if not c.intersects_band(_field.band):
			continue    ## 整块跳过：窄带外不可能跨零
		_base = c.origin - _field.origin
		_ck_off = Vector3i(ck) * _field.chunk_size
		_d = c.data
		_cs = c.size
		_slots = c.slots
		_ck_has_slots = c.has_slots()
		## 单元归属：**只扫下角点落在本块内的单元**（local 0..n-1），保证唯一归属。
		## 范围取窄带包围盒外扩 1 格：跨零单元的 8 角点里必有一个在带内，
		## 该角点可能是单元的下角点或上角点，所以两侧都要各留 1 格。
		## 同时这也是性能关键：整块扫 32³ 而窄带通常只占一小块。
		var lo := c.band_lo - Vector3i.ONE
		var hi := c.band_hi + Vector3i(2, 2, 2)
		lo = Vector3i(clampi(lo.x, 0, _cs - 1), clampi(lo.y, 0, _cs - 1), clampi(lo.z, 0, _cs - 1))
		hi = Vector3i(clampi(hi.x, 1, _cs), clampi(hi.y, 1, _cs), clampi(hi.z, 1, _cs))
		if _limited:
			lo = Vector3i(maxi(_lo.x, lo.x), maxi(_lo.y, lo.y), maxi(_lo.z, lo.z))
			hi = Vector3i(mini(_hi.x, hi.x), mini(_hi.y, hi.y), mini(_hi.z, hi.z))
		for lz in range(lo.z, hi.z):
			for ly in range(lo.y, hi.y):
				for lx in range(lo.x, hi.x):
					var cell := Vector3i(lx, ly, lz)
					var mask := _sample(cell)
					if mask == 0 or mask == 255:
						continue
					## 可能已被相邻块的 _vertex_of 提前建过（宿主块代理），不能重复建
					if not _vmap.has(_ck_off + cell):
						_make_vertex(cell, mask)
					## 交叉 cell 一律发射，**不要求角点 0 实心**。
					## 原因：一条符号变化的网格边只被**一个** cell 以「角点 0 的 +x/+y/+z 出边」
					## 形式报告 —— 就是角点 0 所在的这个 cell。若再要求角点 0 实心（早期版本的做法），
					## 实心端落在远端的那些边就没人报告，**整块面直接丢失**：
					## 实测半径 0.24 m 的球（284 个交叉 cell，282 条符号变化边）只发出 141 个面，
					## 网格漏掉一半，边界边 192 条、欧拉数 1（闭合球应为 2）。
					## 判据写成 `(mask & 1) != ((mask >> k) & 1)` 是对称的，
					## 去掉守卫不会导致重复：远端那个 cell 的角点 0 出边指向别的网格边。
					_emit_faces(cell, mask)
	_mesh.local_aabb = _mesh_aabb()
	_drop_unused()

## 剔除未被任何三角形引用的顶点。
## 跨块边界时 _vertex_of 会为相邻块的单元预建顶点，若该四边形最终因
## 另一角为 -1 被整块丢弃，预建顶点就成了孤立项（多块拼接比单块多出约 5%）。
func _drop_unused() -> void:
	if _mesh.indices.is_empty():
		return
	var used := {}
	for i in _mesh.indices:
		used[i] = true
	if used.size() == _mesh.vertices.size():
		return
	var remap := PackedInt32Array()
	remap.resize(_mesh.vertices.size())
	var nv := PackedVector3Array()
	var nn := PackedVector3Array()
	var nc := PackedColorArray()
	var nu := PackedVector2Array()
	var nvs := PackedInt32Array()
	for i in _mesh.vertices.size():
		if used.has(i):
			remap[i] = nv.size()
			nv.append(_mesh.vertices[i])
			nn.append(_mesh.normals[i])
			if _want_color:
				nc.append(_colors[i])
			if _want_uv2:
				nu.append(_uv2[i])
			if _want_color or _want_uv2:
				nvs.append(_vslot[i])
	for i in _mesh.indices.size():
		_mesh.indices[i] = remap[_mesh.indices[i]]
	_mesh.vertices = nv
	_mesh.normals = nn
	if _want_color:
		_colors = nc
	if _want_uv2:
		_uv2 = nu
	if _want_color or _want_uv2:
		_vslot = nvs

func _mesh_aabb() -> AABB:
	if _mesh.vertices.is_empty():
		return AABB()
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for v in _mesh.vertices:
		mn = mn.min(v)
		mx = mx.max(v)
	return AABB(mn, mx - mn)

## 单个体素值：块内走内联索引，跨块/越界回退到 field。
## GDScript 每次函数调用 ~0.2µs，采样是热点（每单元 8 次、每顶点梯度再 6 次），
## 内联后单次读取从 ~1.5µs 降到 ~0.4µs。
func _val(lx: int, ly: int, lz: int) -> float:
	if lx >= 0 and lx < _cs and ly >= 0 and ly < _cs and lz >= 0 and lz < _cs:
		return _d[(lz * _cs + ly) * _cs + lx]
	return _field.get_voxel(_ck_off.x + lx, _ck_off.y + ly, _ck_off.z + lz)

## 采样单元 8 角点，返回符号掩码（bit=1 表示实心 d<0）
func _sample(cell: Vector3i) -> int:
	var mask := 0
	var lx := cell.x
	var ly := cell.y
	var lz := cell.z
	for i in 8:
		var o: Vector3i = CORNERS[i]
		var d := _val(lx + o.x, ly + o.y, lz + o.z)
		_cur[i] = d
		if d < 0.0:
			mask |= 1 << i
	return mask

## 取（缺失则创建）单元顶点。cell 为**当前块局部**坐标。
## _vmap 一律以**场全局**单元坐标为键 —— 跨块边界的单元会被相邻块的扫描
## 与本块的 _emit_faces 同时触及，用局部键会生成重复顶点。
func _vertex_of(cell: Vector3i) -> int:
	var g := _ck_off + cell
	if _vmap.has(g):
		return _vmap[g]
	if cell.x < 0 or cell.y < 0 or cell.z < 0 or cell.x >= _cs or cell.y >= _cs or cell.z >= _cs:
		return _vertex_of_host(g)     ## 该单元属于相邻块，临时切到宿主块生成
	var mask := _sample(cell)
	if mask == 0 or mask == 255:
		_vmap[g] = -1
		return -1
	return _make_vertex(cell, mask)

## 为属于其他块的单元生成顶点：临时把采样上下文切到宿主块，算完恢复。
## 只发生在块边界的 3 个低侧面，调用量很小。
func _vertex_of_host(g: Vector3i) -> int:
	var ck := Vector3i(floori(float(g.x) / _cs), floori(float(g.y) / _cs), floori(float(g.z) / _cs))
	if not _field.has_chunk(ck):
		return -1
	var sv_base := _base
	var sv_off := _ck_off
	var sv_d := _d
	var sv_cs := _cs
	var sv_slots := _slots
	var sv_has_slots := _ck_has_slots
	var hc: SdfChunk = _field.chunks[ck]
	_ck_off = Vector3i(ck) * _cs
	_d = hc.data
	_cs = hc.size
	_base = hc.origin - _field.origin
	_slots = hc.slots
	_ck_has_slots = hc.has_slots()
	var r := -1
	var mask := _sample(g - _ck_off)
	if mask != 0 and mask != 255:
		r = _make_vertex(g - _ck_off, mask)
	else:
		_vmap[g] = -1
	_base = sv_base
	_ck_off = sv_off
	_d = sv_d
	_cs = sv_cs
	_slots = sv_slots
	_ck_has_slots = sv_has_slots
	return r

func _make_vertex(cell: Vector3i, mask: int) -> int:
	var p: Vector3
	var normal := Vector3.INF
	if _algo == Algo.DUAL_CONTOURING:
		var r := _dual(cell, mask)
		p = r[0]
		normal = r[1]
	else:
		p = _nets(cell, mask)
	var vi := _mesh.vertices.size()
	_mesh.vertices.append(p)
	_mesh.normals.append(normal if normal != Vector3.INF else _grad_at(p))
	if _want_color or _want_uv2:
		## 先按顶点自身所在体素给一份默认槽位；随后 _quad 的分件仲裁会覆写它
		var s := _slot_of_vertex(p)
		_vslot.append(s)
		if _want_color:
			_colors.append(_color_of(_eff_slot(s)))
		if _want_uv2:
			_uv2.append(_slot_uv2(_eff_slot(s)))
	_vmap[_ck_off + cell] = vi
	return vi

## SurfaceNets：穿越边交点平均
func _nets(cell: Vector3i, _mask: int) -> Vector3:
	var acc := Vector3.ZERO
	var cnt := 0
	for e in EDGES:
		var va := _cur[e.x]
		var vb := _cur[e.y]
		if (va < 0.0) == (vb < 0.0):
			continue
		acc += _edge_point(cell, e)
		cnt += 1
	return acc / float(cnt) if cnt > 0 else _cell_center(cell)

## Dual Contouring：QEF 最小二乘解（保棱角）
func _dual(cell: Vector3i, _mask: int) -> Array:
	var center := _cell_center(cell)
	## QEF 累积量：对称矩阵用 6 个标量表示
	## （不用 Matrix3 —— 本构建的 GDScript 解析器无该全局类型）
	var a00 := 0.0
	var a01 := 0.0
	var a02 := 0.0
	var a11 := 0.0
	var a12 := 0.0
	var a22 := 0.0
	var atb := Vector3.ZERO
	var acc := Vector3.ZERO
	var cnt := 0
	for e in EDGES:
		var va := _cur[e.x]
		var vb := _cur[e.y]
		if (va < 0.0) == (vb < 0.0):
			continue
		var t := va / (va - vb)
		var ca: Vector3i = CORNERS[e.x]
		var cb: Vector3i = CORNERS[e.y]
		var p := _edge_point(cell, e) - center
		var n := _grad_cell(cell + ca).lerp(_grad_cell(cell + cb), t).normalized()
		a00 += n.x * n.x
		a01 += n.x * n.y
		a02 += n.x * n.z
		a11 += n.y * n.y
		a12 += n.y * n.z
		a22 += n.z * n.z
		atb += n * n.dot(p)
		acc += p
		cnt += 1
	if cnt == 0:
		return [center, Vector3.INF]
	## 正则项：平面/线状情形 QEF 奇异，加 eps 后有唯一解
	var eps := _dc_eps
	var sol := _solve_sym3(a00 + eps, a01, a02, a11 + eps, a12, a22, atb)
	# 数值不稳 / 溢出单元 → 退回质心；并夹在单元内防自交
	if not _finite(sol) or sol.length() > _vs * 2.0:
		sol = acc / float(cnt)
	sol = sol.clamp(-Vector3.ONE * (_vs * 0.5), Vector3.ONE * (_vs * 0.5))
	var normal := _grad_cell(cell)
	if _sharp:
		normal = _dominant_normal(a00 + eps, a01, a02, a11 + eps, a12, a22, normal)
	return [center + sol, normal]

func _cell_center(cell: Vector3i) -> Vector3:
	return _base + (Vector3(cell) + Vector3.ONE * 0.5) * _vs

func _edge_point(cell: Vector3i, e: Vector2i) -> Vector3:
	var ca: Vector3i = CORNERS[e.x]
	var cb: Vector3i = CORNERS[e.y]
	var t := _cur[e.x] / (_cur[e.x] - _cur[e.y])
	var pa := _base + (Vector3(cell + ca) + Vector3.ONE * 0.5) * _vs
	var pb := _base + (Vector3(cell + cb) + Vector3.ONE * 0.5) * _vs
	return pa.lerp(pb, t)

## 体素中心差分梯度（6 次体素读，远快于三线性的 48 次），块局部坐标
func _grad_cell(cell: Vector3i) -> Vector3:
	var lx := cell.x
	var ly := cell.y
	var lz := cell.z
	var g := Vector3(
		_val(lx + 1, ly, lz) - _val(lx - 1, ly, lz),
		_val(lx, ly + 1, lz) - _val(lx, ly - 1, lz),
		_val(lx, ly, lz + 1) - _val(lx, ly, lz - 1))
	var l := g.length()
	return g / l if l > 1e-9 else Vector3.UP

func _grad_at(p: Vector3) -> Vector3:
	var lv := _field.world_to_voxel(p)
	return _grad_cell(Vector3i(floori(lv.x), floori(lv.y), floori(lv.z)) - _ck_off)

## 幂迭代求 ATA 最大特征值特征向量（主平面法线 → 三渲二硬边）
func _dominant_normal(m00: float, m01: float, m02: float, m11: float, m12: float, m22: float, guess: Vector3) -> Vector3:
	var v := guess if guess.length_squared() > 0.5 else Vector3.UP
	v = v.normalized()
	for _i in 16:
		var r := Vector3(
			m00 * v.x + m01 * v.y + m02 * v.z,
			m01 * v.x + m11 * v.y + m12 * v.z,
			m02 * v.x + m12 * v.y + m22 * v.z)
		var l := r.length()
		if l < 1e-9:
			return guess.normalized()
		v = r / l
	return v

## 3x3 对称线性方程求解（伴随矩阵法）。利用对称性消掉一半余子式。
static func _solve_sym3(m00: float, m01: float, m02: float, m11: float, m12: float, m22: float, b: Vector3) -> Vector3:
	var c00 := m11 * m22 - m12 * m12
	var c01 := m12 * m02 - m01 * m22
	var c02 := m01 * m12 - m11 * m02
	var det := m00 * c00 + m01 * c01 + m02 * c02
	if absf(det) < 1e-14:
		return Vector3(NAN, NAN, NAN)
	var inv := 1.0 / det
	return Vector3(
		c00 * b.x * inv,
		(c01 * b.x + (m00 * m22 - m02 * m02) * b.y + (m01 * m02 - m00 * m12) * b.z) * inv,
		(c02 * b.x + (m01 * m02 - m00 * m12) * b.y + (m00 * m11 - m01 * m01) * b.z) * inv)

static func _finite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)

## 生成三个轴向的面（每面恰由 solid 侧单元生成一次）
## 绕序 (u-1,v-1)→(u,v-1)→(u,v)→(u-1,v)，(u,v) 轴序满足叉积 = 轴方向 → 法线朝外
func _emit_faces(cell: Vector3i, mask: int) -> void:
	var x := cell.x
	var y := cell.y
	var z := cell.z
	# +x 边：角点 0=(0,0,0) 与 1=(1,0,0)，(u,v)=(y,z)
	if (mask & 1) != ((mask >> 1) & 1):
		_quad(Vector3i(x, y - 1, z - 1), Vector3i(x, y, z - 1), Vector3i(x, y, z), Vector3i(x, y - 1, z))
	# +y 边：角点 0 与 3=(0,1,0)，绕序 (z,x) 反向以保证叉积 = +y
	if (mask & 1) != ((mask >> 3) & 1):
		_quad(Vector3i(x - 1, y, z - 1), Vector3i(x - 1, y, z), Vector3i(x, y, z), Vector3i(x, y, z - 1))
	# +z 边：角点 0 与 4=(0,0,1)，(u,v)=(x,y)
	if (mask & 1) != ((mask >> 4) & 1):
		_quad(Vector3i(x - 1, y - 1, z), Vector3i(x, y - 1, z), Vector3i(x, y, z), Vector3i(x - 1, y, z))

func _quad(a: Vector3i, b: Vector3i, c: Vector3i, d: Vector3i) -> void:
	var ia := _vertex_of(a)
	var ib := _vertex_of(b)
	var ic := _vertex_of(c)
	var id := _vertex_of(d)
	if ia < 0 or ib < 0 or ic < 0 or id < 0:
		return    ## 邻域单元落在场外，跳过（场边界处可能有小缺口，见文档）
	_mesh.indices.append(ia)
	_mesh.indices.append(ib)
	_mesh.indices.append(ic)
	_mesh.indices.append(ia)
	_mesh.indices.append(ic)
	_mesh.indices.append(id)
	if _want_color or _want_uv2:
		_paint_face(ia, ib, ic, id)


#region —— 槽位 → 顶点通道 ——

## 6 个面邻居偏移。槽位只标在实心体素上，而表面顶点常落在空体素里（见 _slot_of_vertex），
## 需要一圈面邻居把标签补回来。只取面邻居、不取对角：斜向体素隔着格心，
## 与顶点的距离已超过一格，补它反而会引入更远的错配。
const _NB6: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

## 顶点所在体素的原始槽位（可能是 [constant SdfField.SLOT_NONE]，由仲裁/输出侧折叠）。
##
## **为什么要补一次 6 邻域探测**：等值面骑在实心/空的交界上，`floor` 命中的那一格
## 有一半概率是**空**体素；而槽位只标在实心体素上（[method SdfField.assign_slot_solid]
## 只认 `data < 0`）。实测半径 4 体素的球：314 个表面顶点里 148 个（47%）落在空体素上，
## 直接取槽位会得到一半的SLOT_NONE，顶点色退化成"白 + 主体色"的花斑。
## 等值面必然紧邻实心体素，所以一圈面邻居足够补齐；只在缺失时才探测，命中即返回，
## 代价摊到"无标签顶点"上而不是全部顶点上。
func _slot_of_vertex(p: Vector3) -> int:
	var lv := _field.world_to_voxel(p)
	var v := Vector3i(floori(lv.x), floori(lv.y), floori(lv.z))
	var s := _slot_at_voxel(v)
	if s != SdfField.SLOT_NONE:
		return s
	for i in _NB6.size():
		var t := _slot_at_voxel(v + _NB6[i])
		if t != SdfField.SLOT_NONE:
			return t
	return SdfField.SLOT_NONE

## 体素的原始槽位。**两条路径都原样返回**（含 SLOT_NONE），不做折叠 ——
## 折叠是仲裁/输出侧的职责，这里折了就等于把"有没有标签"提前定死，
## 还会让同一顶点因落在哪个块而拿到不同结果（快慢路径语义必须一致）。
func _slot_at_voxel(v: Vector3i) -> int:
	var lx := v.x - _ck_off.x
	var ly := v.y - _ck_off.y
	var lz := v.z - _ck_off.z
	if _ck_has_slots and lx >= 0 and lx < _cs and ly >= 0 and ly < _cs and lz >= 0 and lz < _cs:
		return _slots[(lz * _cs + ly) * _cs + lx]
	return _field.slot_at_world(v)

## 未指定槽位在**输出侧**统一折叠到 0；仲裁之前先各自折叠，语义才干净
func _eff_slot(s: int) -> int:
	return SLOT_FALLBACK if s == SdfField.SLOT_NONE else s

## 四边形的槽位。先**剔除无标签顶点**再仲裁 —— 这一步是必需的，不是洁癖：
## 无标签若先折成 0再参与取最小值，它会作为"最小的真槽位"赢下整个面，
## 一个没标签的顶点就能把整个面的颜色拽到 0 号（主体色）。
## 实测未做此剔除时：148 个无标签顶点（占 47%）把 312/314 个顶点染成了 0 号，
## 分件信息几乎全灭。剔除后，**只有四个顶点全无标签**才退到 0 号。
func _face_slot(ia: int, ib: int, ic: int, id: int) -> int:
	var m := -1
	for i in [ia, ib, ic, id]:
		var s := _vslot[i]
		if s == SdfField.SLOT_NONE:
			continue    ## 没标签就不参与竞争，见上文
		if m < 0 or s < m:
			m = s
	if m < 0:
		return SLOT_FALLBACK    ## 整面无标签：退 0 号，保证 uv2.x ∈ [0,1] 且 shader 端不必特判
	## —— 分件边界：四边形骑在两个槽位上（如墙与屋顶的接缝）——
	## Godot 的 COLOR / TEX_UV2 都是**逐顶点**通道，无法逐三角形给值，
	## 所以这里必须取舍：取最小槽位号。选它有两条理由 ——
	##   ① 确定性：与遍历顺序、与 Quad 从哪条边生成无关，同一份场两次提取颜色一致；
	##   ② 低号槽位是生成器留给"主体"的（见 SlotPalette：0 号 = 主体色），
	##边界处退回主体色比切到随机细节色更稳。
	## 代价：共享顶点被"后写覆盖"（本面赢了就丢了邻面的色），
	## 即分件接缝处可能有约 1 个顶点宽的杂色。这是刻意的近似，
	## 要精确分件得拆成多个 surface / 复制顶点，代价是顶点数量翻倍。
	return m

## 把面级槽位刷到它的 4 个顶点上（后写覆盖，见 _face_slot 的取舍说明）
func _paint_face(ia: int, ib: int, ic: int, id: int) -> void:
	var s := _face_slot(ia, ib, ic, id)
	if _want_color:
		var col := _color_of(s)
		_colors[ia] = col
		_colors[ib] = col
		_colors[ic] = col
		_colors[id] = col
	if _want_uv2:
		var uv := _slot_uv2(s)
		_uv2[ia] = uv
		_uv2[ib] = uv
		_uv2[ic] = uv
		_uv2[id] = uv

## 槽位 → 颜色；色板长度不足回退白色（宁可白，也别读到错色）
func _color_of(slot: int) -> Color:
	if slot >= 0 and slot < _palette.size():
		return _palette[slot]
	return Color.WHITE

## 槽位 → uv2（.x = slot / 255.0）。除以 255 而非 254：shader 端
## `round(UV2.x * 255.0)` 才能无损还原槽位号，槽位是字节语义不是归一化语义。
func _slot_uv2(slot: int) -> Vector2:
	return Vector2(clampi(slot, 0, 255) / 255.0, 0.0)

#endregion
