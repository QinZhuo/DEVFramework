@tool
class_name ModelPlaneNode extends ModelNode
## 有限板（半空间被裁成板）—— 地面、水面、底板、隔层
##
## 解决的问题：SDF 的"平面"是**半空间**（`n·p - h`，负侧无限延伸），
## 而 [method ModelGraph.make_field] 要靠 [method ModelNode.bounds_hint] 分配场 ——
## 半空间的包围盒是无限的，直接用会让场分配爆掉。
## 因此本节点 = 半空间 ∩ 板厚 ∩ 平面内矩形范围：
## **既要"平面"的方程语义（normal / height），又必须有界**。
##
## 什么时候用它而不是 `ModelBoxNode`：
## · 地面 / 水面这类"极薄且大"的板 —— 盒在薄到远小于体素时会烘出空网格（见 Readme §6.3），
##   板可以用 [member thickness] 明确给出真实厚度；
## · 需要斜面（坡道）：把 [member normal] 倾一下即可，盒做不到"上表面斜、侧面竖"。
##
## 实体侧是**法线正对的一侧**：normal = +Y、height = 0 时实体在 y < 0 一侧，
## 即"脚下的地面"（此时平面项转发 [method SdfTool.sd_plane_up]）。
## 想让板往上长就把 normal 取反。

## 平面法线（不必归一，内部会归一）。实体在 `n·p < height` 一侧。
var normal: Vector3 = Vector3.UP

## 平面高度（米）：平面方程 `n·p - height = 0`。
var height: float = 0.0

## 板厚（米），沿法线从平面往实体侧延伸。必须 > 0，否则实体无界（场会爆）。
var thickness: float = 0.4

## 板在其平面内的半尺寸（XZ 局部轴，米）。
var extent: Vector2 = Vector2(10.0, 10.0)

#region 契约

func bounds_hint() -> AABB:
	var b := _frame()
	## 在板局部系里：X ∈ ±extent.x，Y ∈ [-thickness, 0]（贴平面往实体侧长），Z ∈ ±extent.y。
	## 再把 8 个角点转到世界 —— 斜板的世界 AABB 远大于"直接用 extent 撑出来的盒子"。
	var local := AABB(
		Vector3(-absf(extent.x), -maxf(thickness, 1e-3), -absf(extent.y)),
		Vector3(absf(extent.x) * 2.0, maxf(thickness, 1e-3), absf(extent.y) * 2.0))
	return ModelNodeAccess.xform_aabb(b, local, Vector3.ZERO)

func shape(_rng: RandomNumberGenerator) -> Callable:
	var n := _safe_normal()
	var u := _plane_axis_u(n)
	var v := n.cross(u).normalized()
	var ex := absf(extent.x)
	var ez := absf(extent.y)
	var th := maxf(thickness, 1e-3)
	var h := height
	## 法线就是 +Y（地面 / 水面 / 底板的最常见情形）时，平面那一项直接转发
	## [method SdfTool.sd_plane_up]（它就是 `p.y - h`），不重写一遍点积。
	## 斜面才走通用式 `p·n - h`：基座只有 +Y 这一个取向的平面基元。
	var up := n.is_equal_approx(Vector3.UP)
	return func(p: Vector3) -> float:
		var d_plane := SdfTool.sd_plane_up(p, h) if up else p.dot(n) - h
		## 板厚方向：切掉远离实体侧的无限延伸。
		var d_thick := maxf(d_plane, -d_plane - th)
		## 平面内的矩形范围：切掉四边外的无限延伸（局部 X/Z 轴由法线正交化而来）。
		var dx := absf(p.dot(u)) - ex
		var dz := absf(p.dot(v)) - ez
		return maxf(maxf(d_thick, dx), dz)

#endregion

#region 局部标架

## 归一化法线。退化输入（零向量）退化为 +Y，否则后面所有点积都是 0、板变成一条缝。
func _safe_normal() -> Vector3:
	var n := normal
	if n.length_squared() < 1e-9:
		n = Vector3.UP
	return n.normalized()

## 平面内的一根正交轴 u：取与法线夹角最大的世界轴做投影，避免叉乘退化。
## v 由 `n × u` 重建，故 (u, n, v) 是右手正交基 —— 只含旋转，不含缩放。
func _plane_axis_u(n: Vector3) -> Vector3:
	var helper := Vector3.RIGHT
	if absf(n.dot(helper)) > 0.9:
		helper = Vector3.FORWARD
	return (helper - n * n.dot(helper)).normalized()

## 板局部基底：三列分别是 (u, n, v)，局部 Y 即法线。
func _frame() -> Basis:
	var n := _safe_normal()
	var u := _plane_axis_u(n)
	var v := n.cross(u).normalized()
	return Basis(u, n, v)

#endregion

#region 存档 / 调试

func params() -> Dictionary:
	return {"normal": normal, "height": height, "thickness": thickness, "extent": extent}

func set_params(d: Dictionary) -> void:
	normal = d.get("normal", normal)
	height = float(d.get("height", height))
	thickness = float(d.get("thickness", thickness))
	extent = d.get("extent", extent)

func describe() -> String:
	return "板(n=%s h=%.2f 厚%.2f)" % [str(normal.normalized()), height, thickness]

#endregion
