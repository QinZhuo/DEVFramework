class_name SdfVoxel
extends RefCounted
## 体素网格产物（SDF 的第二种输出）—— 纯数据，可落地为模型文件
##
## 与 [SdfMesh] 的分工：SdfMesh 是"光滑等值面"（适合渲染有机曲面），
## SdfVoxel 是"能拿去做 3D 打印 / 进 MagicaVoxel 继续编辑 / Minecraft 风格建造"的那一种。
## 同一个 SDF 场两者都能出，节点式 PCG 里由调用方挑输出形态。
##
## 坐标约定与 [MeshExtractor] 严格一致：**场局部坐标**（相对 field.origin），不含世界位移，
## 因此体素模型与网格模型能挂在同一父节点下直接比对。
##
## 每体素存一个调色板索引；[constant EMPTY]=255 表示空。

const EMPTY := 255              ## 空体素哨兵（同时是越界读回的返回值）
const STRUCT := 254             ## 恒定保留给"描边 / 结构色"占位，提取器不会产出它
const MAX_MAGICAVOXEL := 256    ## MagicaVoxel 单边硬上限

## 6 个轴向面：法线 / u 轴 / v 轴。
## (u, v) 的选取满足 cross(u, v) == normal，故四边形按 (u,v) 逆时针绕序即外向绕序，
## 与 MeshExtractor._emit_faces 的绕序约定同源。
const FACE_N: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
const FACE_U: Array[int] = [1, 2, 2, 0, 0, 1]
const FACE_V: Array[int] = [2, 1, 0, 2, 1, 0]

var res := 0                   ## 请求的分辨率（最长边体素数）；实际 size 可能小于它
var size := Vector3i.ZERO      ## 实际三维体素数
var origin := Vector3.ZERO     ## 网格最小角（场局部坐标，米）
var voxel := 1.0               ## 体素边长（米）
var data := PackedByteArray()  ## 每体素一个调色板索引，长度 = voxel_count()
var palette: Array[Color] = [] ## 调色板；索引 [constant STRUCT] 恒为描边/结构色占位

var _solid := -1               ## count_solid 缓存，-1 = 未算
var _buckets := {}             ## 网格化临时分组：palette_index -> {v, n, i}
var _face_of := {}             ## palette_index -> 首次出现的面（无材质回调时也不会丢方向）

#region —— 基本存取 ——

func is_empty() -> bool:
	## 无几何可导出。比"data 为空"更严：全空的体素网格同样返回 true，
	## 上层可以放心"空产物直接丢弃"，不必自己再数一遍。
	if size.x <= 0 or size.y <= 0 or size.z <= 0 or data.size() != voxel_count():
		return true
	return count_solid() == 0

func voxel_count() -> int:
	return size.x * size.y * size.z

func in_bounds(x: int, y: int, z: int) -> bool:
	return x >= 0 and x < size.x and y >= 0 and y < size.y and z >= 0 and z < size.z

## 线性索引（与 SdfChunk 同布局：(z * size.y + y) * size.x + x）；越界返回 [constant EMPTY]
func idx(x: int, y: int, z: int) -> int:
	if not in_bounds(x, y, z):
		return EMPTY
	return data[(z * size.y + y) * size.x + x]

func get_voxel(x: int, y: int, z: int) -> int:
	if not in_bounds(x, y, z):
		return EMPTY
	return data[(z * size.y + y) * size.x + x]

## 写入体素；越界静默忽略（提取器边界回填时不必层层判越界）
func set_voxel(x: int, y: int, z: int, v: int) -> void:
	if not in_bounds(x, y, z):
		return
	var i := (z * size.y + y) * size.x + x
	if data[i] != v:
		data[i] = v
		_solid = -1

func count_solid() -> int:
	if _solid >= 0:
		return _solid
	var n := 0
	for v in data:
		if v != EMPTY:
			n += 1
	_solid = n
	return n

## 网格包围盒（场局部坐标，米）
func bounds() -> AABB:
	return AABB(origin, Vector3(size) * voxel)

func center() -> Vector3:
	return origin + Vector3(size) * voxel * 0.5

func stats() -> Dictionary:
	var total := voxel_count()
	var n := count_solid()
	return {
		"res": res, "size": size, "voxel": voxel,
		"voxels": total, "solid": n,
		"ratio": float(n) / float(total) if total > 0 else 0.0,
		"bytes": data.size(), "palette": palette.size(),
	}

#endregion

#region —— 网格化 ——

## 贪心合并网格 —— **默认输出形态**。
## 在 6 个轴向面上分别做贪心合并：同调色板索引、共面的相邻体素面并成一个大四边形；
## 被同类实心体素包住的内面不生成。球体这类形状三角形数通常降到逐体素方块的 1/20~1/50。
##
## material_provider: `func(palette_index: int, face_dir: int) -> Material`，
## face_dir 为 [constant FACE_N] 的下标（0=+X, 1=-X, 2=+Y, 3=-Y, 4=+Z, 5=-Z）。
## 留空则只出几何、不挂材质（调用方自己 surface_set_material）。
func to_greedy_mesh(material_provider: Callable = Callable()) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if is_empty():
		return mesh
	_buckets = {}
	_face_of = {}
	for f in 6:
		_greedy_face(f)
	var keys := _buckets.keys()
	keys.sort()      ## surface 顺序稳定 → 同一模型两次导出的 mesh 可逐字节对比
	for k in keys:
		var b: Dictionary = _buckets[k]
		if b.i.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = b.v
		arrays[Mesh.ARRAY_NORMAL] = b.n
		arrays[Mesh.ARRAY_INDEX] = b.i
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		if material_provider.is_valid():
			mesh.surface_set_material(mesh.get_surface_count() - 1,
				material_provider.call(int(k), int(_face_of.get(k, 0))))
	return mesh

## 逐体素方块网格 —— 剔除不可见面后的"看得见的方块"（Minecraft / MagicaVoxel 那种效果）。
## 面数远多于贪心合并，但**每个体素都独立可辨**，是验证体素数据正确性的基准形态。
func to_item_mesh(material_provider: Callable = Callable()) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if is_empty():
		return mesh
	var box := _new_box()
	var q := Vector3i.ZERO
	for z in size.z:
		for y in size.y:
			for x in size.x:
				if get_voxel(x, y, z) == EMPTY:
					continue
				for f in 6:
					q = Vector3i(x, y, z) + FACE_N[f]
					if q.x >= 0 and q.x < size.x and q.y >= 0 and q.y < size.y \
							and q.z >= 0 and q.z < size.z \
							and get_voxel(q.x, q.y, q.z) != EMPTY:
						continue    ## 内部面
					var fa := _axis_of(FACE_N[f])
					var cell := Vector3i(x, y, z)
					if FACE_N[f][fa] > 0:
						cell[fa] += 1     ## 面在体素远侧：基角要 +1
					_push_quad(box, f, cell, 1, 1)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = box.v
	arrays[Mesh.ARRAY_NORMAL] = box.n
	arrays[Mesh.ARRAY_INDEX] = box.i
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if material_provider.is_valid():
		mesh.surface_set_material(0, material_provider.call(0, 0))
	return mesh

#endregion

#region —— 网格化内部实现 ——

## 单个轴向面的贪心合并。切片内先算可见面掩码，再做二维矩形并合。
func _greedy_face(f: int) -> void:
	var n: Vector3i = FACE_N[f]
	var ua: int = FACE_U[f]
	var va: int = FACE_V[f]
	var a := _axis_of(n)
	var nu: int = size[ua]
	var nv: int = size[va]
	var ns: int = size[a]
	if nu <= 0 or nv <= 0 or ns <= 0:
		return
	var mask := PackedInt32Array()
	mask.resize(nu * nv)
	var used := PackedByteArray()
	used.resize(nu * nv)
	var p := Vector3i.ZERO
	var q := Vector3i.ZERO
	for s in ns:
		for iv in nv:
			for iu in nu:
				var mi := iu * nv + iv
				used[mi] = 0
				mask[mi] = 0
				p[a] = s
				p[ua] = iu
				p[va] = iv
				var vi := get_voxel(p.x, p.y, p.z)
				if vi == EMPTY:
					continue
				q = p + n
				## 邻格在网格内且实心 → 内部面，剔除；越界视为空（网格边缘的面要保留）
				if q[a] >= 0 and q[a] < size[a] and get_voxel(q.x, q.y, q.z) != EMPTY:
					continue
				mask[mi] = vi + 1      ## +1 使 0 可表示"无面"
		_merge_slice(f, s, mask, used, nu, nv)

## 二维矩形并合（贪心）：对每个未使用的非零格，沿 u 尽量拉宽、再沿 v 尽量拉高。
## 行主序扫描 + used 标记保证每个面只生成一次，无需回溯。
func _merge_slice(f: int, s: int, mask: PackedInt32Array, used: PackedByteArray,
		nu: int, nv: int) -> void:
	var n: Vector3i = FACE_N[f]
	var ua: int = FACE_U[f]
	var va: int = FACE_V[f]
	var a := _axis_of(n)
	for iu in nu:
		for iv in nv:
			var mi := iu * nv + iv
			if used[mi] != 0 or mask[mi] == 0:
				continue
			var tag := mask[mi]
			var w := 1
			while iu + w < nu:
				var mj := (iu + w) * nv + iv
				if used[mj] != 0 or mask[mj] != tag:
					break
				w += 1
			var h := 1
			var grow := true
			while grow and iv + h < nv:
				for k in w:
					var mj := (iu + k) * nv + iv + h
					if used[mj] != 0 or mask[mj] != tag:
						grow = false
						break
				if grow:
					h += 1
			for dy in h:
				for dx in w:
					used[(iu + dx) * nv + iv + dy] = 1
			## 面所在的格坐标：法线正轴取切片号 s+1（外表面），负轴取 s
			var base := Vector3i.ZERO
			base[a] = s + (1 if n[a] > 0 else 0)
			base[ua] = iu
			base[va] = iv
			_emit_quad(int(tag) - 1, f, base, w, h)

## 把一个四边形并入对应调色板的分组（多调色板 → 多 surface）
func _emit_quad(pi: int, f: int, base: Vector3i, du: int, dv: int) -> void:
	## 这里**不能**写 `var b: Dictionary = _buckets.get(pi)` 再 `if b == null`：
	## Dictionary 缺键时 get 返回 null，而把 null 赋给一个静态类型为 Dictionary 的
	## 局部变量在 Godot 4.4+ 是**运行期错误**（不是警告），会在赋值那一行直接抛出，
	## 后面的 null 判断根本没机会执行。而"缺键"恰恰是**每个新调色板索引的第一个面**
	## 的正常情形 —— 等于贪心网格化每次都在第一个四边形上崩，
	## 而 has_voxel() / count_solid() 这些不碰网格的接口全都不受影响，
	## 于是"体素产物齐全"与"网格化能跑"看起来毫不相干。
	if not _buckets.has(pi):
		_buckets[pi] = _new_box()
	var b: Dictionary = _buckets[pi]
	if not _face_of.has(pi):
		_face_of[pi] = f
	_push_quad(b, f, base, du, dv)

static func _new_box() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(), "i": PackedInt32Array()}

## 发一个四边形（4 顶点 2 三角）。base 为面在体素网格中的最小角（格坐标），
## du/dv 为沿 u/v 轴的格数。法线取面法线而非平均（SdfMesh 同款取舍）：保住硬棱。
##
## 容器走字典进出而非三个形参：**Packed*Array 是值类型（写时复制）**，
## 当引用传参再 append 只会改到副本，调用方的数组仍是空的。
func _push_quad(c: Dictionary, f: int, base: Vector3i, du: int, dv: int) -> void:
	var n: Vector3i = FACE_N[f]
	var du_v := Vector3.ZERO
	du_v[FACE_U[f]] = du
	var dv_v := Vector3.ZERO
	dv_v[FACE_V[f]] = dv
	var p0 := origin + Vector3(base) * voxel
	var p1 := p0 + du_v * voxel
	var p2 := p1 + dv_v * voxel
	var p3 := p0 + dv_v * voxel
	var verts: PackedVector3Array = c.v
	var norms: PackedVector3Array = c.n
	var idxs: PackedInt32Array = c.i
	verts.append(p0)
	verts.append(p1)
	verts.append(p2)
	verts.append(p3)
	var nv := Vector3(n) * voxel
	for _i in 4:
		norms.append(nv)
	var b := idxs.size()
	idxs.append(b)
	idxs.append(b + 1)
	idxs.append(b + 2)
	idxs.append(b)
	idxs.append(b + 2)
	idxs.append(b + 3)
	c.v = verts
	c.n = norms
	c.i = idxs

## 法线的非零轴 → 0/1/2
static func _axis_of(n: Vector3i) -> int:
	return 0 if n.x != 0 else (1 if n.y != 0 else 2)

#endregion

#region —— 导出 ——

## MagicaVoxel `.txt`（`name N` + `XYZI x y z color`），单边上限 256。
##
## 局限（明说，别指望它配色无损）：MagicaVoxel 的默认调色板顺序**没有公开文档**，
## 这里按 6 级 RGB ramp 量化成 1~216 的索引写出。要精确配色请用 [method to_obj]
## （写 .mtl，RGB 无损）或在目标软件里按 palette 重映射。
## 另：本实现**不做坐标轴转换**（不把 Godot 的 Y-up 转成 MagicaVoxel 的 Z-up），
## 导入后自行旋转即可，形状不会错。
func to_magicavoxel(path: String) -> bool:
	if is_empty():
		push_error("SdfVoxel.to_magicavoxel: 空体素网格，无可导出内容")
		return false
	var longest := maxi(size.x, maxi(size.y, size.z))
	if longest > MAX_MAGICAVOXEL:
		push_error("SdfVoxel.to_magicavoxel: 单边 %d 超过 MagicaVoxel 上限 %d" %
			[longest, MAX_MAGICAVOXEL])
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("SdfVoxel.to_magicavoxel: 无法写入 %s（错误 %d）" % [path, FileAccess.get_open_error()])
		return false
	f.store_line("name %d" % longest)
	var row := PackedStringArray()
	for z in size.z:
		for y in size.y:
			for x in size.x:
				var v := get_voxel(x, y, z)
				if v == EMPTY:
					continue
				row.append("XYZI %d %d %d %d" % [x, y, z, _mv_color(v)])
	## 一次拼好再落盘：256³ 满网格约 16M 行，逐行 store_line 的调用开销比字符串拼接大得多
	if row.size() > 0:
		f.store_string("\n".join(row) + "\n")
	f.close()
	return true

## MagicaVoxel 调色板索引：6 级 RGB ramp，1 起（0 留给 MagicaVoxel 的默认色）
func _mv_color(pi: int) -> int:
	var c: Color = palette[pi] if pi >= 0 and pi < palette.size() else Color.WHITE
	var r := clampi(int(c.r * 5.0 + 0.5), 0, 5)
	var g := clampi(int(c.g * 5.0 + 0.5), 0, 5)
	var b := clampi(int(c.b * 5.0 + 0.5), 0, 5)
	return clampi(1 + r * 36 + g * 6 + b, 1, 255)

## Wavefront OBJ + MTL。用 [method to_greedy_mesh] 的面（顶点/法线/索引），
## 调色板**降到 8 个 mtl 槽**（OBJ 的 `usemtl` 逐面切换，槽太多反而难用）。
func to_obj(path: String) -> bool:
	if is_empty():
		push_error("SdfVoxel.to_obj: 空体素网格，无可导出内容")
		return false
	var mesh := to_greedy_mesh()
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var idxs: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var reps := _mtl_reps()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("SdfVoxel.to_obj: 无法写入 %s（错误 %d）" % [path, FileAccess.get_open_error()])
		return false
	var mtl_name := path.get_file().get_basename() + ".mtl"
	f.store_line("# 由 DEVFramework SdfVoxel 导出（贪心合并面，Y-up，Z 逆时针）")
	f.store_line("mtllib " + mtl_name)
	f.store_line("o " + mtl_name)
	for v in verts:
		f.store_line("v %.5f %.5f %.5f" % [v.x, v.y, v.z])
	for n in norms:
		f.store_line("vn %.3f %.3f %.3f" % [n.x, n.y, n.z])
	## 面按材质槽分段输出：先算每个三角面的槽，再逐段写 usemtl
	var slot := PackedInt32Array()
	slot.resize(idxs.size() / 3)
	for t in slot.size():
		var pi := _palette_of_face(verts, idxs, t * 3)
		slot[t] = _nearest_slot(reps, palette, pi)
	var cur := -1
	for t in slot.size():
		if slot[t] != cur:
			cur = slot[t]
			f.store_line("usemtl " + mtl_name + "_%d" % cur)
		f.store_line("f %d//%d %d//%d %d//%d" % [
			idxs[t * 3] + 1, t * 3 + 1, idxs[t * 3 + 1] + 1, t * 3 + 1,
			idxs[t * 3 + 2] + 1, t * 3 + 2])
	f.close()
	var mf := FileAccess.open(path.get_basename() + ".mtl", FileAccess.WRITE)
	if mf != null:
		for i in reps.size():
			var c := reps[i]
			mf.store_line("newmtl %s_%d" % [mtl_name, i])
			mf.store_line("Kd %.4f %.4f %.4f" % [c.r, c.g, c.b])
			mf.store_line("Ka 0.0000 0.0000 0.0000")
			mf.store_line("Ks 0.0000 0.0000 0.0000")
			mf.store_line("d 1.0")
			mf.store_line("illum 1")
		mf.close()
	return true

## ≤8 个 mtl 槽代表色：调色板不超过 8 个就原样用，超过则等间距抽样
func _mtl_reps() -> Array[Color]:
	if palette.is_empty():
		var none: Array[Color] = []
		none.append(Color.WHITE)
		return none
	if palette.size() <= 8:
		return palette.duplicate()
	var reps: Array[Color] = []
	for i in 8:
		reps.append(palette[int(round(float(i) * float(palette.size() - 1) / 7.0))])
	return reps

## 三角面 → 调色板索引：用顶点坐标反查体素（贪心合并后面片可能很大，但四角同格）
func _palette_of_face(verts: PackedVector3Array, idxs: PackedInt32Array, at: int) -> int:
	var v: Vector3 = verts[idxs[at]]
	var p := Vector3i(floori((v.x - origin.x) / voxel),
		floori((v.y - origin.y) / voxel), floori((v.z - origin.z) / voxel))
	p.x = clampi(p.x, 0, size.x - 1)
	p.y = clampi(p.y, 0, size.y - 1)
	p.z = clampi(p.z, 0, size.z - 1)
	var pi := get_voxel(p.x, p.y, p.z)
	return pi if pi != EMPTY else 0

static func _nearest_slot(reps: Array[Color], pal: Array[Color], pi: int) -> int:
	if pi < 0 or pi >= pal.size():
		return 0
	var c: Color = pal[pi]
	var best := 0
	var bd := INF
	for i in reps.size():
		var dr := reps[i].r - c.r
		var dg := reps[i].g - c.g
		var db := reps[i].b - c.b
		var d := dr * dr + dg * dg + db * db
		if d < bd:
			bd = d
			best = i
	return best

## —— 存档（体素模型自己的格式，与 SDF 场序列化无关）——
## 字段用单字母短键：JSON 文本里键名与 data 的 base64 才是体积大头。

func to_data() -> Dictionary:
	var pal := []
	for c in palette:
		pal.append([snappedf(c.r, 0.001), snappedf(c.g, 0.001),
			snappedf(c.b, 0.001), snappedf(c.a, 0.001)])
	return {
		"v": 1, "r": res,
		"s": [size.x, size.y, size.z],
		"o": [snappedf(origin.x, 0.0001), snappedf(origin.y, 0.0001), snappedf(origin.z, 0.0001)],
		"u": snappedf(voxel, 0.0001),
		"p": pal,
		"d": Marshalls.raw_to_base64(data),
	}

static func from_data(d: Dictionary) -> SdfVoxel:
	var v := SdfVoxel.new()
	v.res = int(d.get("r", 0))
	var s: Array = d.get("s", [])
	v.size = Vector3i(int(s[0]) if s.size() > 0 else 0, int(s[1]) if s.size() > 1 else 0,
		int(s[2]) if s.size() > 2 else 0)
	var o: Array = d.get("o", [])
	v.origin = Vector3(float(o[0]) if o.size() > 0 else 0.0, float(o[1]) if o.size() > 1 else 0.0,
		float(o[2]) if o.size() > 2 else 0.0)
	v.voxel = float(d.get("u", 1.0))
	for c in d.get("p", []):
		v.palette.append(Color(float(c[0]), float(c[1]), float(c[2]),
			float(c[3]) if c.size() > 3 else 1.0))
	v.data = Marshalls.base64_to_raw(String(d.get("d", "")))
	return v

## 写 JSON 存档。`user://` / `res://` / 绝对路径都可用（res:// 在导出后只读，会返回 false）
func save(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("SdfVoxel.save: 无法写入 %s（错误 %d）" % [path, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(to_data()))
	f.close()
	return true

static func load(path: String) -> SdfVoxel:
	if not FileAccess.file_exists(path):
		push_error("SdfVoxel.load: 文件不存在 %s" % path)
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("SdfVoxel.load: 无法读取 %s（错误 %d）" % [path, FileAccess.get_open_error()])
		return null
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("SdfVoxel.load: %s 不是合法的体素存档 JSON" % path)
		return null
	return SdfVoxel.from_data(parsed)

#endregion