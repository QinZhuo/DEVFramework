@tool
class_name ModelSphereNode extends ModelNode
## 球 —— 最便宜、最不容易出错的基元
##
## 什么时候用它而不是别的节点：
## · 想要一个**各向同性**的体（珠子、球形关节、桶底）——旋转不变意味着包围盒不用改；
## · 想给布尔运算当"圆角填充"：union 一个球天然得到倒角，替代昂贵的圆角盒；
## · **不适合**做主体：球的表面积/体积比最差，同样的包围盒要占最多体素。
##
## 形状转发 [method SdfTool.sd_sphere]，不在本地重写距离函数。

## 半径（米）。
var radius: float = 0.5

## 球心（局部空间，米）。形状节点**允许**带中心：让"偏移一个身位"不必外挂变换节点，
## 少一层函数复合 = 每个采样点少一次 Callable。
var center: Vector3 = Vector3.ZERO

#region 契约

func bounds_hint() -> AABB:
	var r := absf(radius)
	return AABB(center - Vector3.ONE * r, Vector3.ONE * (r * 2.0))

func shape(_rng: RandomNumberGenerator) -> Callable:
	var r := absf(radius)
	var c := center
	return func(p: Vector3) -> float:
		return SdfTool.sd_sphere(p - c, r)

#endregion

#region 存档 / 调试

func params() -> Dictionary:
	return {"radius": radius, "center": center}

func set_params(d: Dictionary) -> void:
	radius = float(d.get("radius", radius))
	center = d.get("center", center)

func describe() -> String:
	return "球(r=%.2f)" % radius

#endregion
