@tool
class_name PropLayoutTool
## 世界布局求解器 —— **只**回答"这个单体该摆在世界的哪个位置、朝哪边"
##
## ============================ 分层红线 ============================
## 与 [PropGen] 完全对偶：
##   PropGen        只知道局部几何，不知道世界 → 产出 [PropBuild]
##   PropLayoutTool 只知道世界，不知道几何细节 → 产出 [PropLayoutTool.Placement]
##
## 本工具**不做**任何造型决策：不改顶点、不加细节、不决定物体"长什么样"。
## 它连"商店"是什么都不认识 —— 只认识 [PropBuild] 的占地与 meta。
## 地形通过鸭子类型注入（见 [method solve] 的 ground_y），框架不引用任何项目地形类。
## ==================================================================

## 贴地方式
enum Snap {
	NONE,    ## 不贴地，放在 y = 0
	MIN,     ## 用占地矩形最低角（宁陷勿浮，适合建筑）
	MAX,     ## 用占地矩形最高角（宁悬勿陷，适合挂壁物）
	CENTER,  ## 取采样平均值（要求地面近似水平）
}

## 一次摆放的结果 —— 这是**布局层**的产物，与 [PropBuild] 分开存放。
## 存档只需存 seed_value + origin + yaw，build 可随时按 seed 重建。
class Placement extends RefCounted:
	var build: PropBuild
	var seed_value := 0
	var xform := Transform3D.IDENTITY
	var yaw := 0.0
	var ground_y := 0.0
	var snapped := false
	var meta := {}

	func origin() -> Vector3:
		return xform.origin

	## [param form] 投影形态，见 [enum PropBuild.Form]。
	## 体素场景整场要一致，所以由调用方（通常是 [method DioramaBuilder.spawn]）统一下发 ——
	## 单个摆放自己挑形态会让同一场景里混进两种网格。
	func instantiate(material: Variant = null,
			form: PropBuild.Form = PropBuild.Form.AUTO) -> MeshInstance3D:
		var mi := PropGenTool.instantiate(build, material, form)
		if mi:
			mi.transform = xform
		return mi

## 求单个摆放。
## [param build] 已烘焙的单体（局部空间）
## [param seed_value] 该单体的 seed，存档用；换 seed 即换造型
## [param at] 目标 XZ 位置（米，at.x / at.y 分别对应世界 x / z）
## [param yaw] 朝向（弧度，绕 +Y）
## [param ground_y] 鸭子类型 func(x: float, z: float) -> float，返回该处地面高度。
##        传空 Callable 表示无地面信息（此时贴地退化为 NONE）。
## [param opts]
##   snap       [enum Snap]，不给则按 build.meta.surface_snap 决定
##   y_offset   额外抬高（米），默认 0
##   blocked    func(x: float, z: float) -> bool，该点不可放则返回 null
##   align_dir  世界 XZ 方向：令 yaw 把局部正面转向它
##   face_dir   局部正面方向（Vector3i），配合 align_dir 使用
##   ground_step 地面采样步长（米）。0 = 只采 4 角 + 中心；
##            长单体（路面板 / 长椅 / 围墙）必须给值，否则 5 个采样点
##            跨不过一个坡，路面会直接穿进地形。
static func solve(
		build: PropBuild,
		seed_value: int,
		at: Vector2,
		yaw: float,
		ground_y := Callable(),
		opts := {}) -> Placement:
	if build == null or build.is_empty():
		return null
	if opts.has("blocked"):
		var blocked := Callable(opts["blocked"])
		if blocked.is_valid() and blocked.call(at.x, at.y):
			return null

	var p := Placement.new()
	p.build = build
	p.seed_value = seed_value
	p.meta = build.meta.duplicate()

	## —— 朝向：外部直接给 yaw，或"把局部正面转向某个世界方向" ——
	if opts.has("align_dir"):
		var face: Vector3i = opts.get("face_dir", Vector3i(0, 0, 1))
		p.yaw = yaw_to_face(opts["align_dir"], face)
	else:
		p.yaw = wrapf(yaw, -PI, PI)

	## —— 贴地 ——
	var mode := _resolve_snap(opts, build)
	var y := 0.0
	if mode == Snap.NONE or not ground_y.is_valid():
		pass
	else:
		var corners := _foot_corners(build, at, p.yaw, float(opts.get("ground_step", 0.0)))
		var lo := INF
		var hi := -INF
		var sum := 0.0
		for i in corners.size():
			var gy := float(ground_y.call(corners[i].x, corners[i].z))
			lo = minf(lo, gy)
			hi = maxf(hi, gy)
			sum += gy
		p.ground_y = sum / maxf(float(corners.size()), 1.0)
		p.snapped = true
		match mode:
			Snap.MIN: y = lo
			Snap.MAX: y = hi
			_: y = p.ground_y
		y += float(opts.get("y_offset", 0.0))

	## 局部空间约定生成器 y 从 0 起算（local_bounds 的 min.y 通常是 0），
	## 贴地时要把包围盒最低点压到 y，而不是把局部原点放上去。
	var lift := 0.0
	if p.snapped:
		lift = -build.bounds.position.y
	p.xform = Transform3D(Basis(Vector3.UP, p.yaw), Vector3(at.x, y + lift, at.y))

	p.meta[&"yaw"] = p.yaw
	p.meta[&"ground_y"] = p.ground_y
	return p

## 批量摆放：[param items] 每项 {build, seed, at, yaw?, opts?}
## 其中 at 为 Vector2（x, z）。整体做一次冲突松弛。
static func place_all(items: Array, ground_y := Callable(), shrink := 0.92) -> Array:
	var out: Array = []
	for i in items.size():
		var it: Dictionary = items[i]
		var p := solve(
			it.get("build"),
			int(it.get("seed", 0)),
			it.get("at", Vector2.ZERO),
			float(it.get("yaw", 0.0)),
			ground_y,
			it.get("opts", {}))
		if p:
			out.append(p)
	relax(out, 24, shrink)
	return out

## 冲突松弛：把互相重叠的摆放沿水平面推开。这是布局层**唯一**的冲突处理，
## 只依赖占地矩形，不依赖任何几何细节。
##
## 用**旋转矩形 OBB + 分离轴（SAT）**，而不是外接圆：
## 6×8 米的建筑外接圆半径 5m，用圆做分离会把两栋楼强行推开到 10m，
## 而真实城镇里建筑间距只有 1~2 米 —— 圆模型会让整张图稀疏得没法看。
##
## [param shrink] 占地缩放。1.0 = 严格不重叠；0.9 = 允许 10% 挤压（街道更紧凑）
## [param iterations] 松弛轮数。Gauss-Seidel 解一个 pair 可能重新引入另一 pair 的
##        重叠，必须迭代到收敛（用 moved 提前退出），单轮不保证严格分离。
static func relax(placements: Array, iterations := 24, shrink := 0.92) -> void:
	var n := placements.size()
	if n < 2:
		return
	var centers := PackedVector2Array()
	var ax_u := PackedVector2Array()   ## 局部 X 轴在世界 XZ 平面的方向
	var ax_v := PackedVector2Array()   ## 局部 Z 轴
	var half := PackedVector2Array()   ## 占地半尺寸
	for i in n:
		var pl: Placement = placements[i]
		centers.append(Vector2(pl.xform.origin.x, pl.xform.origin.z))
		var c := cos(pl.yaw)
		var s := sin(pl.yaw)
		ax_u.append(Vector2(c, -s))
		ax_v.append(Vector2(s, c))
		half.append(pl.build.footprint * 0.5 * maxf(shrink, 0.0))

	for _it in iterations:
		var moved := false
		for i in n:
			for j in range(i + 1, n):
				var dlt := centers[j] - centers[i]
				var cand := [ax_u[i], ax_v[i], ax_u[j], ax_v[j]]
				var best := INF
				var baxis := Vector2.ZERO
				for k in 4:
					var na: Vector2 = cand[k]
					var ra := half[i].x * absf(ax_u[i].dot(na)) + half[i].y * absf(ax_v[i].dot(na))
					var rb := half[j].x * absf(ax_u[j].dot(na)) + half[j].y * absf(ax_v[j].dot(na))
					var ov := ra + rb - absf(dlt.dot(na))
					if ov <= 0.0:
						best = 0.0      ## 存在分离轴 → 已不重叠
						break
					if ov < best:
						best = ov
						baxis = na
				if best <= 0.0:
					continue
				moved = true
				var dir := baxis if dlt.dot(baxis) >= 0.0 else -baxis
				var push := dir * (best * 0.5)
				centers[i] -= push
				centers[j] += push
		if not moved:
			break

	for i in n:
		var pl: Placement = placements[i]
		var o := pl.xform.origin
		pl.xform.origin = Vector3(centers[i].x, o.y, centers[i].y)

## 摆放间是否已无重叠（回归测试 / 存档校验用）。
## 判定方式与 [method relax] 一致（同一套 SAT），保证"检测通过 = 松弛收敛"。
static func has_overlap(placements: Array, shrink := 0.92) -> bool:
	for i in placements.size():
		for j in range(i + 1, placements.size()):
			if _obb_overlap_depth(placements[i], placements[j], shrink) > 1e-4:
				return true
	return false

static func _obb_overlap_depth(a: Placement, b: Placement, shrink: float) -> float:
	var ca := Vector2(a.xform.origin.x, a.xform.origin.z)
	var cb := Vector2(b.xform.origin.x, b.xform.origin.z)
	var ua := Vector2(cos(a.yaw), -sin(a.yaw))
	var va := Vector2(sin(a.yaw), cos(a.yaw))
	var ub := Vector2(cos(b.yaw), -sin(b.yaw))
	var vb := Vector2(sin(b.yaw), cos(b.yaw))
	var ha := a.build.footprint * 0.5 * maxf(shrink, 0.0)
	var hb := b.build.footprint * 0.5 * maxf(shrink, 0.0)
	var dlt := cb - ca
	var best := INF
	for na in [ua, va, ub, vb]:
		var ra := ha.x * absf(ua.dot(na)) + ha.y * absf(va.dot(na))
		var rb := hb.x * absf(ub.dot(na)) + hb.y * absf(vb.dot(na))
		var ov := ra + rb - absf(dlt.dot(na))
		if ov <= 0.0:
			return 0.0
		best = minf(best, ov)
	return best

## 把 yaw 解成"使局部正面 [param face] 转向世界 XZ 方向 [param dir]"。
## Godot 绕 +Y 旋转 a 时 R(a)·(fx,0,fz) = (fx·cos a + fz·sin a, 0, -fx·sin a + fz·cos a)，
## 令其等于 (dx, 0, dz) 解得：
##   cos a = f·d,  sin a = -(fx·dz - fz·dx)
static func yaw_to_face(dir: Vector2, face := Vector3i(0, 0, 1)) -> float:
	var d := dir.normalized()
	if d == Vector2.ZERO:
		return 0.0
	var f := Vector2(float(face.x), float(face.y)).normalized()
	if f == Vector2.ZERO:
		f = Vector2(0.0, 1.0)
	return atan2(f.y * d.x - f.x * d.y, f.dot(d))

## 旋转后的地面采样点（世界 XZ）。
## [param step] <= 0 时只取 4 角 + 中心（紧凑小体足够）；
## 否则沿占地矩形按步长铺成网格 —— 长单体（路面 24m、围墙）必须走这条，
## 否则采样跨度远大于地形波长，采样点会互相"抵消"成错误的平均值。
static func _foot_corners(build: PropBuild, at: Vector2, yaw: float, step := 0.0) -> PackedVector3Array:
	var half := build.rotated_extent(yaw)
	var c := cos(yaw)
	var s := sin(yaw)
	var out := PackedVector3Array()
	var base: Array[Vector2] = []
	if step > 0.01:
		var nx := clampi(int(ceil(half.x * 2.0 / step)), 1, 64)
		var nz := clampi(int(ceil(half.y * 2.0 / step)), 1, 64)
		for iz in nz + 1:
			for ix in nx + 1:
				base.append(Vector2(
					lerpf(-half.x, half.x, float(ix) / float(nx)),
					lerpf(-half.y, half.y, float(iz) / float(nz))))
	else:
		base = [
			Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
			Vector2(half.x, half.y), Vector2(-half.x, half.y),
			Vector2.ZERO,
		]
	for i in base.size():
		var v: Vector2 = base[i]
		out.append(Vector3(at.x + v.x * c - v.y * s, 0.0, at.y + v.x * s + v.y * c))
	return out

static func _resolve_snap(opts: Dictionary, build: PropBuild) -> int:
	if opts.has("snap"):
		return int(opts["snap"])
	if build.meta.get(&"surface_snap", false):
		return Snap.MIN
	return Snap.NONE
