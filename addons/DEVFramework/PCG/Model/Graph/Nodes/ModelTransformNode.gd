@tool
class_name ModelTransformNode extends ModelNode
## 单输入刚体/缩放变换 —— 位移、旋转、缩放、镜像
##
## 什么时候用它而不是改基元参数：
## · **复用**：同一根柱子要摆到四个位置 —— 造四次不如造一次 + 阵列，
##   更不如造一次 + 一个变换；
## · 形状节点刻意不带"贴地 / 朝向"语义（节点不得知道世界坐标），
##   因此"把整段子图抬到地面高度""整体转 30°"只能由变换节点做；
## · **不适合**做非等比缩放（见下）：SDF 空间里那只是近似。
##
## == 非等比缩放为什么是近似 ==
## 变换 F(p) = base(S⁻¹p) 的梯度是 ∇F = S⁻ᵀ∇base，模长已不是 1，
## 所以 F 的值**不再等于**到表面的距离：
## · 不修正（默认）：乘以 `min(scale)` —— Lipschitz 安全的**下界**，
##   形状略瘦，等值面位置正确但提取出的网格会偏保守；
## · [member normalize_scale]：乘以三轴的平均拉伸，形状更接近直觉，
##   代价是局部可能略微高估距离（仅影响远离表面的场值，不影响等值面）。
## 严格做法要逐点算 |∇F|，代价是每次采样多 4 次形状求值 —— 不划算，故只给开关。

## 局部位移（米）。
var translate: Vector3 = Vector3.ZERO

## 欧拉旋转（度，XYZ 序）。
var rotate_deg: Vector3 = Vector3.ZERO

## 三轴缩放。分量可以为负（等价于该轴镜像），绝对值 < 1 为缩小。
var scale: Vector3 = Vector3.ONE

## 沿局部 X 轴镜像。与 `scale.x = -1` 等价，单独给出是为了不必改动缩放语义。
var mirror_x: bool = false

## 开启非等比缩放的长度修正（近似，见文件头）。
var normalize_scale: bool = false

#region 契约

## 由 [method ModelGraph]（或 [method ModelNodeAccess.bind_all]）回灌的图引用。
## 节点自身不 new 图，也不缓存输入形状 —— 每次现问，保证拓扑序语义。
var graph: ModelGraph = null

func bind_graph(g: ModelGraph) -> void:
	graph = g

func bounds_hint() -> AABB:
	var b := ModelNodeAccess.input_bounds(self, &"in")
	if ModelNodeAccess.is_empty_box(b):
		return AABB()
	## 8 个角点全变换：只变换 min/max 两个角点在旋转 45° 时是错的
	## —— 那两个角点恰好落在旋转后盒子的对角线上，各轴投影都会偏小，几何被截出缺面。
	return ModelNodeAccess.xform_aabb(_basis(), b, translate)

func shape(_rng: RandomNumberGenerator) -> Callable:
	var src_shape := ModelNodeAccess.input_shape(self, &"in")
	var xf := Transform3D(_basis(), translate)
	var inv := xf.affine_inverse()
	var k := _length_gain()
	## 注意 `.call()`：GDScript 4 **不允许**用 `f(x)` 直接调用 Callable 变量，
	## 那样会被解析成调用本对象上名为 f 的方法，编译期就报
	## "Function \"f()\" not found in base self."
	if is_equal_approx(k, 1.0):
		return func(p: Vector3) -> float:
			return src_shape.call(inv * p)
	return func(p: Vector3) -> float:
		return src_shape.call(inv * p) * k

#endregion

#region 内部

## 变换基底。Godot 4 的 [Basis] 用 from_euler（度），没有 Matrix3；
## 镜像折进 scale.x 的符号，不额外引入负行列式矩阵。
func _basis() -> Basis:
	var s := scale
	if mirror_x:
		s.x = -s.x
	var b := Basis.from_euler(Vector3(
		deg_to_rad(rotate_deg.x), deg_to_rad(rotate_deg.y), deg_to_rad(rotate_deg.z)))
	b = b.scaled(Vector3(
		1.0 if is_zero_approx(s.x) else s.x,
		1.0 if is_zero_approx(s.y) else s.y,
		1.0 if is_zero_approx(s.z) else s.z))
	return b

## 距离增益因子：默认取 min(scale)（保守下界），开启归一化后取平均拉伸。
func _length_gain() -> float:
	var s := scale.abs()
	if normalize_scale:
		return (maxf(s.x, 1e-4) + maxf(s.y, 1e-4) + maxf(s.z, 1e-4)) / 3.0
	return maxf(minf(s.x, minf(s.y, s.z)), 1e-4)

#endregion

#region 存档 / 调试

func params() -> Dictionary:
	return {
		"translate": translate, "rotate_deg": rotate_deg, "scale": scale,
		"mirror_x": mirror_x, "normalize_scale": normalize_scale,
	}

func set_params(d: Dictionary) -> void:
	translate = d.get("translate", translate)
	rotate_deg = d.get("rotate_deg", rotate_deg)
	scale = d.get("scale", scale)
	mirror_x = bool(d.get("mirror_x", mirror_x))
	normalize_scale = bool(d.get("normalize_scale", normalize_scale))

func describe() -> String:
	return "变换(t=%s r=%s° s=%s)" % [str(translate.round()),
		str(rotate_deg.round()), str(scale.round())]

#endregion
