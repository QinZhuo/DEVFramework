@tool
class_name ModelHardenNode extends ModelNode
## 硬边化 —— 把连续距离场量化成阶梯，**画风开关**
##
## ============================ 三档就是三种画风 ============================
## [method SdfTool.op_round] 把 d 量化成 `step` 的整数倍，量级即风格：
## · `step = 0.01` —— 几乎原样。光滑曲面（写实 / 塑料 / 有机物）。
## · `step = 0.25` —— 棱面化。三渲二、卡通渲染的主档。
## · `step = 1.00` —— 粗块面。低多边形（Low-poly）、像素风的近似。
##
## 注意 `step` 是**绝对距离**（米），不是百分比：同一个 step 在 0.4 m 的小物件上
## 等于彻底碎掉，在 30 m 的建筑上等于没做。粒度必须随物体的**特征尺寸**配，
## 这也是它要放在节点里按部件调、而不是像 sharpen 那样全局设一个值的原因。
##
## == 为什么放 post ==
## 量化是 `data[i] = round(data[i]/step) * step`：**逐体素独立的一元变换**，
## 与邻域无关、不需要梯度、不需要形状表达式。整场跑一遍的代价 = 体素数，
## 而放进 shape 会让每个采样点多付一次调用与一次 round —— 同一个效果，贵几十倍。
##
## == 副作用（必须知道）==
## 量化会把 |d| < step 的窄带**整体推远**，等值面因此略微内缩/外扩，
## 包围盒不再精确 —— 但场是离散的，[method SdfTool.refresh_band_bounds]
## 只关心 |d| 落在窄带内的体素集合，故不会漏提取。

## 量化步长（米）。<= 0 时不做任何处理（相当于开关关）。
var step: float = 0.25

#region 契约

func bounds_hint() -> AABB:
	var b := ModelNodeAccess.input_bounds(self, &"in")
	if ModelNodeAccess.is_empty_box(b):
		return AABB()
	## 量化只在 ±step/2 内挪动等值面，故外扩 step 即为上界；
	## 宁可取整步也不写 step/2 —— 少写一个常数不划算，偏大更安全。
	return b.grow(absf(step))

func shape(_rng: RandomNumberGenerator) -> Callable:
	## 不改形状：硬化是整场后处理，这里只透传。
	return ModelNodeAccess.input_shape(self, &"in")

func post(field: SdfField) -> void:
	if field == null or field.is_empty() or step <= 1e-6:
		return
	## 转发基座：harden 内部就是 apply_op + op_round，参数只有量化步长。
	## 改写 data 后窄带缓存失效，但 [method ModelGraph.fill] 会在所有 post 跑完后
	## 统一 refresh_band_bounds 一次 —— **不要在这里自己调**。
	SdfTool.harden(field, absf(step))

#endregion

#region 存档 / 调试

func params() -> Dictionary:
	return {"step": step}

func set_params(d: Dictionary) -> void:
	step = float(d.get("step", step))

func describe() -> String:
	return "硬边(step=%.3f)" % step

#endregion
