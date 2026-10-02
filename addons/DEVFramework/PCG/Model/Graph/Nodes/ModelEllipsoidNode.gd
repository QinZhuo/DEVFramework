@tool
class_name ModelEllipsoidNode extends ModelNode
## 椭球 —— 球的三轴非等比版本（蛋、橄榄、桶肚）
##
## 什么时候用它而不是 `ModelTransformNode` + `scale`：
## · 形状语义不同 —— 变换球得到的是"非等比缩放后的距离场"，梯度不再为单位长度，
##   后续的 union / 抽壳 / 表面提取都会带上系统性误差；
##   椭球的场本身就是近似的**真**距离场，误差只在 3% 量级且各向同性；
## · 蛋形（两轴不等）用变换要歪两个轴，用本节点改一个数即可。
##
## 距离函数转发 [method SdfTool.sd_ellipsoid]（Inigo 的一阶近似 `k0·(k0-1)/k1`）：
## 严格椭球距离是四次方程、无闭式解，而网格提取只关心**符号**与近似的量级。
## 误差各向同性、最大约 3%（越扁越大），故包围盒仍取三轴半径。
## 公式只有这一份 —— 基座改了这里自动跟着变，不留第二份副本。

## 三轴半径（米）。
var radii: Vector3 = Vector3(0.5, 0.35, 0.5)

#region 契约

func bounds_hint() -> AABB:
	var r := radii.abs()
	return AABB(-r, r * 2.0)

func shape(_rng: RandomNumberGenerator) -> Callable:
	## 半轴下限 1e-4：半径为 0 时 sd_ellipsoid 的 k1 分母会趋 0，场变得不可用。
	var r := Vector3(maxf(absf(radii.x), 1e-4), maxf(absf(radii.y), 1e-4),
		maxf(absf(radii.z), 1e-4))
	return func(p: Vector3) -> float:
		return SdfTool.sd_ellipsoid(p, r)

#endregion

#region 存档 / 调试

func params() -> Dictionary:
	return {"radii": radii}

func set_params(d: Dictionary) -> void:
	radii = d.get("radii", radii)

func describe() -> String:
	return "椭球(%.2f×%.2f×%.2f)" % [radii.x, radii.y, radii.z]

#endregion
