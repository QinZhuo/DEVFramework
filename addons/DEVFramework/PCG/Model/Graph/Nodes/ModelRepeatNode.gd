@tool
class_name ModelRepeatNode extends ModelNode
## 阵列 —— 一个节点顶三种布局（直线 / 网格 / 圆周），逐实例取 min
##
## 解决什么问题：栅栏的 12 根栏杆、棋盘的 8×8 格、围成一圈的柱子。
## 手写生成器要为每种布局写一遍循环，而且每种都要重算一次包围盒；
## 本节点把"布局"抽象成三组参数，并**保证抖动按实例序号确定性派生**。
##
## 为什么不拆成三个节点：三者只在"实例变换怎么算"上不同，
## 而形状（逐实例 min）、包围盒（并集）、抖动、存档完全一致 ——
## 拆开会产生三份近乎重复的代码，改一处漏两处。
##
## == 抖动必须按实例序号派生（阵列节点最容易踩的坑）==
## 直觉写法是从 `rng` 连续抽 n 次。那是**全局流**：第 5 个实例的抖动依赖前 4 次抽取值，
## 于是"只改第 5 个实例的参数"会连带把后面所有实例一起挪动，
## 改一个参数 → 整排栏杆全变，回归测试无从下手。
## 本节点改为 `hash(节点熵, seed_salt, 实例序号, 通道)` → [0,1)：
## 实例之间完全独立、可并行、可单独重算，改一个实例不影响其余实例。
## 熵取自 [method ModelGraph.rng_for] 给的 rng 的 **seed**（只读，绝不写 `state`），
## 因此仍满足"同图 + 同种子必得同一形状"。

## 布局枚举。存档按 int 存，故**只能追加、不可重排**。
enum Mode {
	ARRAY,   ## 直线阵列：count 个实例，沿 spacing 步进
	GRID,    ## 网格阵列：counts 三轴个数
	RING,    ## 圆周阵列：count 个实例绕 axis 均布
}

## 布局模式。
var mode: int = Mode.ARRAY

#region ARRAY / RING 共用

## 实例个数（[constant Mode.ARRAY] 与 [constant Mode.RING] 用）。
var count: int = 4

#endregion

#region ARRAY

## 步进（米，三轴可不同）。
var spacing: Vector3 = Vector3(0.5, 0.0, 0.0)

## 整体平移（米）—— 阵列是"从第一个实例起算"，不是从原点对称展开。
var offset: Vector3 = Vector3.ZERO

#endregion

#region GRID

## 三轴实例个数。
var counts: Vector3i = Vector3i(2, 1, 2)

#endregion

#region RING

## 圆周半径（米）。
var radius: float = 1.0

## 圆周所在平面的法线（默认 Y 轴水平圆周）。不必归一，内部会归一。
var axis: Vector3 = Vector3.UP

## 起始相位（度）。用来让两段圆弧接得上，而不是永远从 +X 开始。
var phase_offset: float = 0.0

## 让每个实例绕 [member axis] 转向"朝外/朝切线"（栅栏柱、齿轮齿、围栏尖顶）。
## 关闭时所有实例保持输入朝向，只改位置。
var align_to_ring: bool = false

#endregion

#region 抖动

## 各轴抖动幅度（米）。抖动在实例变换**之后**叠加，故不会累积成漂移。
var jitter: Vector3 = Vector3.ZERO

## 抖动随机流盐。同一位置、不同盐 → 两套互不相关的抖动，
## 于是"横排随机"与"竖排随机"不会同步（否则整片看上去是斜的）。
var seed_salt: int = 0

#endregion

var graph: ModelGraph = null

func bind_graph(g: ModelGraph) -> void:
	graph = g

#region 契约

func bounds_hint() -> AABB:
	var src := ModelNodeAccess.input_bounds(self, &"in")
	if ModelNodeAccess.is_empty_box(src):
		return AABB()
	var out := AABB()
	## 取**全部**实例 AABB 的并集，而不是只并首末两个：
	## 有抖动时中间实例可能越出首末张成的范围，只并首末会漏掉它们的凸出部分
	## —— 漏掉的正是几何本体，表现为局部缺面。实例数是几十级别，8 角点变换的成本可忽略。
	var xf := _transforms(_entropy())
	for i in xf.size():
		var t := xf[i]
		out = ModelNodeAccess.merge(out, ModelNodeAccess.xform_aabb(t.basis, src, t.origin))
	return out

func shape(rng: RandomNumberGenerator) -> Callable:
	var src_shape := ModelNodeAccess.input_shape(self, &"in")
	var invs: Array[Transform3D] = []
	for t in _transforms(_entropy_of(rng)):
		invs.append(t.affine_inverse())
	if invs.is_empty():
		return ModelNode.null_shape
	return func(p: Vector3) -> float:
		## 逐实例变换后取 min = 把所有实例并成一个形状。
		## 先求逆：每个采样点只付一次 3×3 求逆，而不是每个实例一次。
		var d := 1.0e9
		for i in invs.size():
			d = minf(d, src_shape.call((invs[i] as Transform3D) * p))
		return d

#endregion

#region 布局与实例变换

## 实例总数（当前模式）。
func instance_count() -> int:
	match mode:
		Mode.GRID:
			return maxi(counts.x, 0) * maxi(counts.y, 0) * maxi(counts.z, 0)
		_:
			return maxi(count, 0)

## 抖动熵：只读 [member RandomNumberGenerator.seed]，绝不写 `state`
## （PCG32 里 state 与 seed 是两回事，覆盖它会让不同种子塌成同一串值）。
func _entropy_of(rng: RandomNumberGenerator) -> int:
	return rng.seed if rng != null else 0

func _entropy() -> int:
	## bounds_hint() 拿不到 rng，但抖动熵可以从 (图种子, 稳定序号) **重算**出来 ——
	## 这正是 [method ModelGraph.rng_for] 的公式，故包围盒里的抖动与形状里的逐位一致。
	## 没绑图时退化为 0 熵：此时形状本身也拿不到 rng，抖动一并消失，两边仍然自洽。
	var g := graph
	if g == null:
		return 0
	return PropGenTool.mix_seed(g.seed_value, ModelGraph.RNG_KIND, g.stable_index(id))

## 实例变换表。bounds_hint 与 shape 各建一次 —— 每次几微秒，
## 换来"包围盒不依赖求值顺序"的纯函数性质（宁可重算也不缓存中间态）。
func _transforms(entropy: int) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var n := instance_count()
	if n <= 0:
		return out
	match mode:
		Mode.GRID:
			_out_grid(out, entropy)
		Mode.RING:
			_out_ring(out, entropy)
		_:
			_out_array(out, entropy)
	return out

func _out_array(out: Array[Transform3D], entropy: int) -> void:
	for i in maxi(count, 0):
		var t := Transform3D(Basis.IDENTITY, offset + spacing * float(i))
		t.origin += _jitter_vec(entropy, i)
		out.append(t)

func _out_grid(out: Array[Transform3D], entropy: int) -> void:
	var k := 0
	for z in maxi(counts.z, 0):
		for y in maxi(counts.y, 0):
			for x in maxi(counts.x, 0):
				var t := Transform3D(Basis.IDENTITY,
					Vector3(spacing.x * x, spacing.y * y, spacing.z * z))
				t.origin += _jitter_vec(entropy, k)
				out.append(t)
				k += 1

func _out_ring(out: Array[Transform3D], entropy: int) -> void:
	var n := maxi(count, 0)
	var ax := _safe_axis()
	var u := _plane_axis(ax)
	var v := ax.cross(u).normalized()
	var base_ang := deg_to_rad(phase_offset)
	for i in n:
		var ang := base_ang + TAU * float(i) / float(n)
		var dir := (u * cos(ang) + v * sin(ang)).normalized()
		var t := Transform3D(Basis.IDENTITY, dir * radius)
		if align_to_ring:
			## 实例绕 axis 转到"面朝外"：Basis(axis, ang) 把局部 -Z 转到 dir。
			t.basis = Basis(ax, ang)
		t.origin += _jitter_vec(entropy, i)
		out.append(t)

func _safe_axis() -> Vector3:
	var a := axis
	if a.length_squared() < 1e-9:
		return Vector3.UP
	return a.normalized()

## 圆周平面内的一根正交轴：取与法线夹角最大的世界轴做投影，避免叉乘退化。
func _plane_axis(n: Vector3) -> Vector3:
	var helper := Vector3.RIGHT
	if absf(n.dot(helper)) > 0.9:
		helper = Vector3.FORWARD
	return (helper - n * n.dot(helper)).normalized()

#endregion

#region 确定性抖动

## 第 [param i] 个实例在第 [param channel] 轴上的抖动偏移（米）。
## 三轴取三个独立哈希值 —— 共用同一个值会得到沿 (1,1,1) 的斜向抖动，
## 整片看上去是"整体歪了"，而不是自然的随机。
func _jitter_vec(entropy: int, i: int) -> Vector3:
	return Vector3(
		_jit01(entropy, i, 0) - 0.5,
		_jit01(entropy, i, 1) - 0.5,
		_jit01(entropy, i, 2) - 0.5) * jitter * 2.0

## (熵, 盐, 实例序号, 通道) → [0, 1) 的确定性哈希。
##
## 纯整数运算，不碰任何随机源：因此**与求值顺序无关、与其他节点无关**，
## 改一个实例的参数不会牵动其余实例（见文件头）。
## 混洗用 murmur3 finalizer 的常数，实测把相邻序号 / 相邻通道都打散。
func _jit01(entropy: int, index: int, channel: int) -> float:
	var h := _mix32(entropy ^ _mix32(seed_salt))
	h = (h ^ _mix32(index)) & 0xFFFFFFFF
	h = (h ^ _mix32(channel + 1)) & 0xFFFFFFFF
	h = (h ^ (h >> 16)) & 0xFFFFFFFF
	h = (h * 0x7FEB352D) & 0xFFFFFFFF
	h = (h ^ (h >> 15)) & 0xFFFFFFFF
	h = (h * 0x846CA68B) & 0xFFFFFFFF
	h = (h ^ (h >> 16)) & 0xFFFFFFFF
	return float(h & 0xFFFFFF) / 16777215.0

## 32 位散列乘数。乘大质数避免相邻输入在高位上仍然相邻。
static func _mix32(v: int) -> int:
	return (v * 0x9E3779B1) & 0xFFFFFFFF

#endregion

#region 存档 / 调试

func params() -> Dictionary:
	return {
		"mode": mode, "count": count, "spacing": spacing, "offset": offset,
		"counts": counts, "radius": radius, "axis": axis,
		"phase_offset": phase_offset, "align_to_ring": align_to_ring,
		"jitter": jitter, "seed_salt": seed_salt,
	}

func set_params(d: Dictionary) -> void:
	mode = int(d.get("mode", mode))
	count = int(d.get("count", count))
	spacing = d.get("spacing", spacing)
	offset = d.get("offset", offset)
	counts = d.get("counts", counts)
	radius = float(d.get("radius", radius))
	axis = d.get("axis", axis)
	phase_offset = float(d.get("phase_offset", phase_offset))
	align_to_ring = bool(d.get("align_to_ring", align_to_ring))
	jitter = d.get("jitter", jitter)
	seed_salt = int(d.get("seed_salt", seed_salt))

func describe() -> String:
	var kind: String = ["直线", "网格", "圆周"][clampi(mode, 0, 2)]
	return "%s阵列×%d%s" % [kind, instance_count(),
		", 抖动%.2f" % jitter.x if jitter.length_squared() > 0.0 else ""]

#endregion
