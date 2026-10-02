@tool
class_name ModelTorusNode extends ModelNode
## 圆环 —— 环、箍、轮胎、飘带
##
## 什么时候用它而不是别的节点：
## · 需要一个**中空**的环：差集（`ModelSubtractNode`）也能挖空，但那是"实心减实心"，
##   环本身的中空是形状自带的，不用额外两个节点；
## · 想让"环"带厚度变化：改 [member minor] 即可，不必做 union。
##
## 形状转发 [method SdfTool.sd_torus]（轴为 Y，原点居中）。
## 注意它是**环面**，不是圆盘：中心孔是真空的，major <= minor 时孔会消失退化成球壳。

## 主半径（环中心到管中心的距离，米）。
var major: float = 0.5

## 管半径（管的粗细，米）。
var minor: float = 0.12

#region 契约

func bounds_hint() -> AABB:
	## XZ 半宽 = major + minor（管外缘），Y 半高 = minor（管上下缘）。
	## major <= minor 时几何退化，仍按公式返回偏大的盒子 —— 宁可多分配不可截断。
	var r := absf(major) + absf(minor)
	var h := absf(minor)
	return AABB(Vector3(-r, -h, -r), Vector3(r * 2.0, h * 2.0, r * 2.0))

func shape(_rng: RandomNumberGenerator) -> Callable:
	var mj := absf(major)
	var mn := absf(minor)
	return func(p: Vector3) -> float:
		return SdfTool.sd_torus(p, mj, mn)

#endregion

#region 存档 / 调试

func params() -> Dictionary:
	return {"major": major, "minor": minor}

func set_params(d: Dictionary) -> void:
	major = float(d.get("major", major))
	minor = float(d.get("minor", minor))

func describe() -> String:
	return "圆环(R=%.2f r=%.2f)" % [major, minor]

#endregion
