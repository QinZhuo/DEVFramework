@tool
class_name ModelShellNode extends ModelNode
## 抽壳 —— 把实心体变成等壁厚薄壳
##
## 解决什么问题：一次性造出"壳"类几何 —— 碗、罐、花瓶、盔甲外壳、灯笼。
## 手写生成器得把距离场取绝对值再减壁厚，而且**改一个壁厚要重跑整段代码**；
## 本节点把这步做成一个节点，改 `thickness` 即可。
##
## == 为什么放 post 而不是 shape ==
## 抽壳是 `|d| - w`：**逐体素独立的一元变换**，`data[i] = |data[i]| - w`。
## 它不需要邻域、不需要梯度、不关心 d 的符号从哪来，
## 因此整场跑一遍即可（代价 = 体素数），而放进 shape 会让**每个采样点多付一次调用**
## —— 且壳的厚度要在整场已知之后才有意义。
##
## == 语义提醒 ==
## 壳有内外两层表面，壁厚必须 > 0；`thickness` 大于原物体尺寸时，
## 内外表面会互相吞掉，烘出空网格（见 SDF/Readme.md §6.3"薄 + 粗 = 空"）。
## `thickness <= 0` 时退回实心（`|d|` 变换退化为原值减去非正数），不做额外报错。
##
## == 窄带缓存 ==
## post 改写了 `data`，窄带包围盒随之失效；**不要自己调**
## [method SdfTool.refresh_band_bounds] —— [method ModelGraph.fill] 会在
## 所有 post 跑完后统一重算一次（那里已注明这条约定）。

## 壁厚（米）。必须明显大于体素边长，否则壳体会被体素采样抹掉。
var thickness: float = 0.08

#region 契约

func bounds_hint() -> AABB:
	var b := ModelNodeAccess.input_bounds(self, &"in")
	if ModelNodeAccess.is_empty_box(b):
		return AABB()
	## `|d| - w` 会把原本"实心内部"的负值区翻到壳外侧：
	## 内表面在原表面**内侧** w 处，外表面就在原表面外侧 w 处（|d| 的零点有两个）。
	## 故按 w 等向外扩是精确上界。
	return b.grow(absf(thickness))

func shape(_rng: RandomNumberGenerator) -> Callable:
	## 形状**透传**：抽壳只在 post 里做一次。
	## 若这里也做 op_onion，post 里再 SdfTool.shell 一遍就成了"壳的壳"：
	## | |d| - w | - w 会把内表面再翻一次，壁厚与内外关系全乱。
	return ModelNodeAccess.input_shape(self, &"in")

func post(field: SdfField) -> void:
	if field == null or field.is_empty():
		return
	SdfTool.shell(field, absf(thickness))

#endregion

#region 存档 / 调试

func params() -> Dictionary:
	return {"thickness": thickness}

func set_params(d: Dictionary) -> void:
	thickness = float(d.get("thickness", thickness))

func describe() -> String:
	return "抽壳(壁厚%.3f)" % thickness

#endregion
