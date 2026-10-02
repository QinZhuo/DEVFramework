@tool
class_name DioramaBuild extends RefCounted
## 微缩小场景构建结果 —— 底座 + 按角色分组的摆放 + 场景叙事元信息
##
## ============================ 为什么单独一个产物类型 ============================
## [WorldAssembler] 交出的是一串扁平的 [PropLayoutTool.Placement]，没有角色概念。
## 但 diorama 的**完整性是可以被检查的** —— 用户那五个测试用例里，
## 「场景完整度：底座、主体、环境、道具、氛围是否齐全」是排在第一位的评估维度。
## 没有分组，演示场景就只能靠人工数数；有了 [member subjects] / [member env] / [member props]，
## [method validate] 才能把"缺了环境层"这种问题变成一条明确的失败而不是"看着空"。
##
## 它仍然是**纯局部空间 + 摆放 transform**：不含网格序列化需求，
## 存档依旧只需 seed + transform（见 [method DioramaBuilder.save_data]）。

## 展示底座。留空 = 无底座场景。
var base: PropBuild = null

## 主体摆放（[enum DioramaRecipe.Role.SUBJECT]）
var subjects: Array = []
## 环境围合件摆放（[enum DioramaRecipe.Role.ENV]）
var env: Array = []
## 道具摆放（[enum DioramaRecipe.Role.PROP]）
var props: Array = []

## 整个 diorama 的世界包围盒（已含底座与全部摆放）。
## 镜头取景、微缩感虚化起点、暗角半径都由它推导。
var bounds := AABB()

## 构建时用的世界种子，存档回读时用于确认是同一份配方
var world_seed := 0

## 底座实际半径（米）。0 = 无底座。
var base_radius := 0.0


## 全部摆放（主体 + 环境 + 道具）。
func all() -> Array:
	var out := []
	out.append_array(subjects)
	out.append_array(env)
	out.append_array(props)
	return out


## 按角色取一组摆放。
func by_role(role: int) -> Array:
	match role:
		DioramaRecipe.Role.SUBJECT: return subjects
		DioramaRecipe.Role.ENV: return env
		_: return props


## 追加一个摆放（由 [DioramaBuilder] 调用）。
func add(pl: PropLayoutTool.Placement, role: int) -> void:
	if pl == null:
		return
	by_role(role).append(pl)


## 全部摆放里的网格三角面总数（不含底座 —— 底座体量通常远大于内容物，
## 混进来会让"内容物面数"这个指标失去意义）。
func triangle_count() -> int:
	var n := 0
	for p in all():
		var pl: PropLayoutTool.Placement = p
		if pl != null and pl.build != null:
			n += pl.build.triangle_count()
	return n


## 体素单元总数（0 = 这套场景没出体素）。贪心合并后的实际块数，
## 用来看"体素化是否退化成空"（扁长物体会，参见 PropBuild.has_voxel）。
func voxel_count() -> int:
	var n := 0
	for p in all():
		var pl: PropLayoutTool.Placement = p
		if pl != null and pl.build != null and pl.build.has_voxel():
			n += pl.build.voxel.voxel_count()
	return n


## 场景叙事摘要（一行）：`主体 1 · 环境 4 · 道具 9 ｜ 三角面 18.2k｜ 体素 6.1k`
func story() -> String:
	var v := voxel_count()
	return "主体 %d · 环境 %d · 道具 %d ｜ 三角面 %s%s" % [
		subjects.size(), env.size(), props.size(), _fmt(triangle_count()),
		("｜ 体素块 %s" % _fmt(v)) if v > 0 else ""]


## 完整度自检 —— 把"场景完整度"这条评估维度变成可执行的断言。
##
## [param require_env] / [param require_props] 置 false 即可允许"纯主体特写"。
## 返回空数组 = 通过；否则每项一条可读的问题。
##
## 为什么要它：那五类 diorama 最常见的失败不是崩溃，而是**静默变空** ——
## 少一类道具时组装器不报错、截图出来只是"看着空"，评审时极难归因。
func validate(require_base := true, require_env := true, require_props := true) -> Array:
	var bad := []
	if require_base and base == null:
		bad.append("缺展示底座")
	elif base != null and base.is_empty():
		bad.append("底座烘焙出空网格")
	if subjects.is_empty():
		bad.append("没有主体（SUBJECT）")
	if require_env and env.is_empty():
		bad.append("没有环境围合件（ENV）")
	if require_props and props.is_empty():
		bad.append("没有道具（PROP）")
	for p in all():
		var pl: PropLayoutTool.Placement = p
		if pl == null or pl.build == null:
			continue
		if pl.build.is_empty():
			bad.append("%s 烘焙出空网格" % pl.meta.get(&"tag", "?"))
			continue
		## 体素化退化的静默形态：有体素需求但一个块都没出（扁长物体）。
		## 不检查的话场景会安静地退回网格形态，且日志一片正常。
		## `want_voxel` 由 [method DioramaBuilder] 按配方的 voxel_res 写进 pl.meta
		## ——不能读 build.meta，那份是 [method PropGen.meta] 的自报属性，不含此项。
		if pl.build.has_voxel() == false and bool(pl.meta.get(&"want_voxel", false)):
			bad.append("%s 体素化退化（形状与 voxel_res 不匹配），已退回网格" %
				pl.meta.get(&"tag", "?"))
	return bad


func _fmt(n: int) -> String:
	if n >= 10000:
		return "%.1fk" % (float(n) / 1000.0)
	return str(n)
