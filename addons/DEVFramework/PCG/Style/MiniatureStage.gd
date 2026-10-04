@tool
class_name MiniatureStage extends RefCounted
## 微缩舞台 —— 把"这是一张**桌面摆件**的照片"落到相机 / 环境 / 屏幕后期上
##
## ============================ 为什么需要这一层 ============================
## [ToonStyleDef] 只管**单个物体长什么样**，可微缩模型之所以"像摆件"，
## 靠的却是**画幅之外**的东西。三渲二做得再干净，只要镜头一广、边缘一亮、
## 远处一样清楚，观感就退回"游戏截图"而不是"模型照片"。业内把这几件事合称
## "微缩感三要素"（Blender 的 tilt-shift、Houdini 的 diorama kit、
## Unity Stylized 的 mini diorama preset 都是同一套）：
##
## | 要素 | 物理效果 | 本文件的实现 |
## |---|---|---|
## | ① **长焦** | 透视压缩 ⇒ 前后挤在一起，像贴在同一块底板上 | `Camera3D.fov` 调小 + [method frame_scale] 往后退 |
## | ② **浅景深** | 焦点之外糊掉 ⇒ 眼睛把清晰的那一小块当成实物 | `CameraAttributesPractical` 的 near/far 虚化 |
## | ③ **边缘收暗** | 视线被收进画面中央 ⇒ "在关着的小盒子里" | `ToonShader.MINIATURE_VIGNETTE` 挂 `CanvasLayer` |
##
## 缺任何一项都还看，但不叠加就只是"有雾的普通场景"。
##
## 另外还搬一样**不属于三要素但同样要跟画风走**的东西：主光方向（[method apply_key_light]）。
## 材质已改用引擎内置 `StandardMaterial3D`，明暗**完全来自实灯**，
## 所以这盏灯不再只是"锦上添花的补光"，而是画面亮暗的唯一来源。
##
## ============================ 边界在哪 ============================
## * 本类**只搬运数值与朝向**：读风格包的字段 → 写进相机 / `Environment` / 屏幕 shader / 灯的朝向。
##   它不生成几何、不摆物体、不认识"街道"或"糖果屋" —— 那是 [WorldAssembler] 的活。
## * 参数**不在本类**，而在 [SceneStylePack]：本类按鸭子类型读 `pack.xxx`，
##   故对 `pack` 不加类型注解（框架不该为了调用方便就把类型依赖钉死）。
## * **画风色板归 [ToonStyleDef] 管**。环境光颜色 / 雾色 / 雾密度这里**不另设一份**，
##   直接读风格包的 `style.ambient` / `style.fog_color` / `style.fog_density` ——
##   两处各填一次的颜色必然会互相打架，而"雾色与雾密度"本来就是画风事实
##   （微缩要重雾、街景要清透）。只有 [code]Environment[/code] 能表达而
##   `ToonStyleDef` 表达不了的（后期调色、暗角、背景模式）才放在风格包上。
##
## == 典型用法 ==
## [codeblock]
## pack.apply_stage(self, camera)   # 风格包上的便捷入口，等价于下面三行
## # 等价写法：
## MiniatureStage.apply_camera(camera, pack)
## MiniatureStage.apply_environment(get_node("Env"), pack)
## MiniatureStage.apply_vignette(self, pack)
## [/codeblock]

## 暗角挂载层名。固定名字是为了让 [method apply_vignette] **幂等** ——
## 反复切风格包时复用同一个节点，不会在场景里堆出一摞半透明的暗角。
const VIGNETTE_LAYER := &"MiniatureVignette"

## 暗角所在的 CanvasLayer 序号。**必须小于 UI 层**（本项目演示场景 UI 在 10），
## 否则暗角会把按钮也压暗 —— 那是"给照片加的滤镜"，不该盖到 HUD 上。
const VIGNETTE_CANVAS_LAYER := 1

## 主光约定名。[method apply_key_light] 找不到这名字时会新建一个用它命名，
## 故重复调用不会在场景里越堆越多盏灯。
const KEY_LIGHT_NAME := &"KeyLight"

## 主光摆放距离（米）。平行光只看方向，这个数字纯粹是"够远的方向哨兵"，
## 取大了也只是让 `look_at` 的数值更稳。
const KEY_LIGHT_DISTANCE := 30.0


#region 镜头

## 把风格包的镜头参数落到相机上（FOV + 景深 + 曝光所需的 attributes）。
##
## 曝光**不在这里**：`CameraAttributesPractical` 只有 `dof_*` 与自动曝光灵敏度，
## 没有"曝光倍数"这个属性（实测 ClassDB），所以固定曝光走 [code]Environment.tonemap_exposure[/code]，
## 见 [method apply_environment]。
##
## 若相机上已有非 practical 的 [CameraAttributes]，会被替换 —— 目前只有
## `CameraAttributesPractical` 支持景深与曝光，不换就没有微缩感。
static func apply_camera(cam: Camera3D, pack) -> void:
	if cam == null or pack == null:
		return
	cam.fov = clampf(float(pack.camera_fov), 5.0, 120.0)

	var attr := cam.attributes as CameraAttributesPractical
	if attr == null:
		attr = CameraAttributesPractical.new()

	## 景深开关与强度是同一件事：`dof_*_enabled` 不开时距离参数写了也白写，
	## 而 `dof_blur_amount` 才是"糊多少"。三者一起写，重复调用结果一致。
	var amount := clampf(float(pack.dof_amount), 0.0, 1.0)
	var on := amount > 0.001
	attr.dof_blur_far_enabled = on
	attr.dof_blur_near_enabled = on
	attr.dof_blur_amount = amount
	attr.dof_blur_far_distance = maxf(0.0, float(pack.dof_far_distance))
	attr.dof_blur_far_transition = maxf(0.0, float(pack.dof_far_transition))
	attr.dof_blur_near_distance = maxf(0.0, float(pack.dof_near_distance))
	attr.dof_blur_near_transition = maxf(0.0, float(pack.dof_near_transition))
	cam.attributes = attr


## 换算"为了让画面大小不变，相机该退多远"。
##
## 长焦微缩有个反直觉的副作用：FOV 一调小，画面会**猛地放大**（物体占满屏幕），
## 必须同步把相机往后拉，否则切换风格包时观众看到的是"突然凑近"而不是"换了镜头"。
## 几何关系：同一主体在画面里的占比 ∝ `1/(dist · tan(fov/2))`，令占比不变即得下式。
##
## [param ref_fov_deg] 是基准视场角 —— 用哪个都行，只要调用方一致；
## 传 70（接近人眼默认）时，`frame_scale(35) ≈ 2.14`，即"35mm 长焦要退到两倍远"。
static func frame_scale(fov_deg: float, ref_fov_deg := 70.0) -> float:
	var f := clampf(fov_deg, 5.0, 120.0)
	var r := clampf(ref_fov_deg, 5.0, 120.0)
	return tan(deg_to_rad(r) * 0.5) / maxf(tan(deg_to_rad(f) * 0.5), 0.0001)

#endregion


#region 主光

## 找（或建）一盏主平行光，并把它对准 [ToonStyleDef] 声明的光向。
##
## == 为什么"对齐"是硬要求而不是锦上添花 ==
## 材质改用引擎内置 `StandardMaterial3D` 之后，`style.key_light_dir` 就是
## **这盏灯的唯一记录处**：方向由画风给，不由场景里恰好哪盏灯亮决定。
## 记录与实灯一旦错开，画面表现为"亮面和投影不在一处"，**不报错、不崩，只能靠肉眼发现**。
##
## == 为什么只动一盏、且保留已有节点 ==
## * 只动**找到的那一盏**（缺省名 [constant KEY_LIGHT_NAME]）：场景里可能有作者
##   特意摆的补光/点光，全被重摆一遍会让"切风格包"变成"拆掉作者的布光"。
## * 找不到就新建，但不覆盖已有的：宁可不动，也不破坏手动布光。
##   新建的节点会带上 [constant KEY_LIGHT_NAME]，故重复调用不会越堆越多。
## * 强度与阴影只对**新建**的灯设默认值 —— 作者调过的 `light_energy`
##   是布光的一部分，切个风格包不该被抹掉。
static func apply_key_light(host: Node, pack) -> DirectionalLight3D:
	if host == null or pack == null:
		return null
	var st = pack.style      # 鸭子类型：style 可能为 null
	if st == null:
		return null

	var sun := _find_key_light(host)
	var created := sun == null
	if created:
		sun = DirectionalLight3D.new()
		sun.name = KEY_LIGHT_NAME
		host.add_child(sun)
		# 新建的灯必须给足默认值，否则场景"看起来就是没打光"：
		# 材质走 PBR，N·L 恒为 0 时全画面只剩环境光的底色。
		sun.light_energy = 1.15
		sun.light_color = st.key_light_color
		sun.shadow_enabled = true

	## 朝向**不用 `Node3D.look_at()`**：它要求节点已在场景树里，
	## 而本函数有两类正当调用方都不满足 —— ① 编辑器里搭场景（节点还没 add_child）；
	## ② 单元测试（临时 `Node3D` 根本不进树）。两处都会拿到
	## `Node not inside tree. Use look_at_from_position() instead.`，灯直接转不动。
	##
	## 改成自己拼正交基 + 显式换到 host 的局部空间：
	##   · 位置只是"够远的方向哨兵"—— 平行光只看方向，与距离无关；
	##   · `host` 可能带任意变换（也可能不在树里），故用 `affine_inverse()` 换算；
	##   · 顺带把方向**回写**进 `style.key_light_dir`，让"灯实际朝哪"与
	##     "风格里记录的是多少"永远同源，不会各记一份。
	var host_pos := Vector3.ZERO
	var to_local := Transform3D.IDENTITY
	if host.is_inside_tree():
		host_pos = host.global_position
		to_local = host.global_transform.affine_inverse()
	var world_xf := Transform3D(
		_basis_with_z(st.key_light_aim()),
		host_pos + st.key_light_position(KEY_LIGHT_DISTANCE))
	sun.transform = to_local * world_xf
	## 回写实际生效的光向：`DirectionalLight3D` 沿局部 -Z 出光，故 +Z 才是"光的来向"
	st.key_light_dir = _basis_with_z(st.key_light_aim()).z
	return sun


## 子树里找一盏主光。找不到返回 null（由调用方决定要不要新建）。
static func _find_key_light(host: Node) -> DirectionalLight3D:
	var found := host.find_children(KEY_LIGHT_NAME, "DirectionalLight3D", true, false)
	for f in found:
		if f is DirectionalLight3D:
			return f as DirectionalLight3D
	## 没有约定名时退而求其次取第一盏 —— 但只在子树里**恰好一盏**时才用，
	## 否则"改哪一盏"变成猜谜，且必然有人觉得"我明明关了它怎么还亮"。
	var suns := host.find_children("*", "DirectionalLight3D", true, false)
	if suns.size() == 1 and suns[0] is DirectionalLight3D:
		return suns[0] as DirectionalLight3D
	return null


## 构造"局部 **+Z** 轴对齐 [param z_dir]（世界空间）"的正交基。
##
## 之所以自己拼而不用 `Basis.looking_at()`：那个函数的"前方是 +Z 还是 -Z"
## 各版本文档说法不一致，写错了就是一个**静默反 180°** 的灯 ——
## 画面上表现为"色阶亮面和实灯亮面正好错开"，极难一眼看出是符号问题。
## 这里把"Godot 的 -Z 是出光方向"写成代码里唯一的一条事实，不再依赖文档措辞。
static func _basis_with_z(z_dir: Vector3, up := Vector3.UP) -> Basis:
	var z := z_dir
	if z.length_squared() < 0.000001:
		z = Vector3.FORWARD
	z = z.normalized()
	## 上方向与 z 共线时 `cross()` 会得到零向量 ⇒ 基向量塌成 0 ⇒ 整盏灯失去朝向。
	## 换一个不共线的备用轴，而不是让调用方在外面判。
	var u := up
	if absf(z.dot(u)) > 0.999:
		u = Vector3.FORWARD if absf(z.dot(Vector3.FORWARD)) < 0.999 else Vector3.RIGHT
	var x := u.cross(z).normalized()
	var y := z.cross(x)
	return Basis(x, y, z)

#endregion


#region 环境

## 把风格包的环境参数落到 [Environment]（背景 / 环境光 / 雾 / 调色 / 曝光）。
##
## 返回实际使用的 [Environment]（`we.environment` 为空时会新建一个并挂回去），
## 便于调用方接着微调，也便于测试断言。
##
## [param cam_distance] 是相机到场景的实际距离（米）。**雾密度必须按它归一化**，
## 原因见[method _fog_density_for]。不传（≤0）时退化为"不缩放"，适合贴脸机位。
static func apply_environment(we: WorldEnvironment, pack,
		cam_distance := 0.0) -> Environment:
	if pack == null:
		return null
	if we == null:
		return null
	var env := we.environment
	if env == null:
		env = Environment.new()
		we.environment = env

	# ---- 颜色与雾的"真值"来自画风（ToonStyleDef），不在风格包上重复一份 ----
	var st = pack.style          # 鸭子类型：pack.style 可能为 null，也可能是别的实现
	var amb := Color(0.80, 0.82, 0.92)
	var amb_energy := 0.35
	var fog_col := Color(0.86, 0.88, 0.94)
	var fog_density := 0.008
	if st != null:
		amb = st.ambient
		amb_energy = st.ambient_energy
		fog_col = st.fog_color
		fog_density = st.fog_density

	# ---- 背景：微缩摆件通常不是"站在天空下"，而是"放在桌面上对着柔光" ----
	match int(pack.backdrop):
		1:  # FLAT：单色背景 + 暗角 ⇒ 最像"拍在纯色台布上"
			env.background_mode = Environment.BG_COLOR
			env.background_color = pack.backdrop_color
		2:  # SKY：需要天地过渡时用程序天空（黄昏神社这类）
			env.background_mode = Environment.BG_SKY
			var sky := env.sky
			if sky == null:
				sky = Sky.new()
				env.sky = sky
			var mat := sky.sky_material as ProceduralSkyMaterial
			if mat == null:
				mat = ProceduralSkyMaterial.new()
				sky.sky_material = mat
			mat.sky_top_color = pack.sky_top_color
			mat.sky_horizon_color = pack.sky_horizon_color
			mat.ground_horizon_color = pack.sky_horizon_color
			mat.ground_bottom_color = pack.backdrop_color
		_:  # KEEP：场景自己已经布好背景（用户手动配的 WorldEnvironment）
			pass

	# ---- 环境光：来源跟着背景走 ----
	# 背景是纯色时若还从天空取光，取到的会是"上一份天空"或黑，
	# 于是纯色背景 + 高环境光的组合会得到一个看不出环境光的死平画面。
	if env.background_mode == Environment.BG_SKY:
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	else:
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = amb
	env.ambient_light_energy = amb_energy

	# ---- 雾：指数雾。密度按相机距离归一化，理由见 _fog_density_for ----
	# gain 是给"场景级雾比材质级雾更重"的场合留的旋钮。
	env.fog_enabled = bool(pack.env_fog_enabled)
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = fog_col
	env.fog_density = _fog_density_for(float(fog_density), cam_distance,
		float(pack.env_fog_gain))
	# 雾不染天空：微缩摆件的背景要干净，雾一染背景整张图就"灰掉了"
	env.fog_sky_affect = bool(pack.env_fog_sky_affect)

	# ---- 后期调色：三渲二的高光/暗角都靠后期收，饱和度略升才不"塑料" ----
	env.adjustment_enabled = bool(pack.env_adjust_enabled)
	env.adjustment_brightness = float(pack.env_brightness)
	env.adjustment_contrast = float(pack.env_contrast)
	env.adjustment_saturation = float(pack.env_saturation)

	# ---- 曝光：CameraAttributesPractical 没有"曝光倍数"，只能落在 Environment ----
	env.tonemap_exposure = maxf(0.0, float(pack.exposure))

	# ---- 刻意关掉的两项：这是画风决策，不是画质档位 ----
	# SSAO 会在色阶交界处糊出一圈脏灰，把"两档色"变成"三档脏色"；
	# glow 会让描边与高光溢出到轮廓外，把硬边描边糊成一团。
	# 两者都不报错、只是"看起来没那么对"，所以要显式关掉而不是指望默认值。
	if bool(pack.disable_ssao):
		env.ssao_enabled = false
	if bool(pack.disable_glow):
		env.glow_enabled = false
	return env


## 把风格字段里的"每米雾密度"换算成能直接塞进 [member Environment.fog_density] 的值。
##
## ============================ 为什么必须换算 ============================
## [member ToonStyleDef.fog_density] 是**按场景自身尺度**设的（十几米的 diorama，
## 0.003~0.018），而 Godot 原生雾的 `d` 是**到相机的深度**。微缩长焦又把相机推到
## 50~60 m 外 —— 直接把 0.008 塞进去，整幅画在 50 m 处就吃掉
## `1 - exp(-0.008 × 50) ≈ 33%` 的对比，画面被洗成一片均匀的灰紫（实测截图）。
##
## 所以按"**场景所在的深度上雾浓度不变**"反解：令 `density' × cam_dist`
## 等于 `density × scene_depth`，即 `density' = density × scene_depth / cam_dist`。
## 这样风格字段继续保持"每米、场景尺度"的原语义，换机位、换焦段都不用重调。
##
## `scene_depth` 用 [constant FOG_REFERENCE_DEPTH]（本框架服务的微缩场景对径约 18 m）。
## `cam_distance ≤ 0`（调用方没给、贴脸机位）时**不缩放**。
const FOG_REFERENCE_DEPTH := 18.0


static func _fog_density_for(density: float, cam_distance: float, gain: float) -> float:
	var d := maxf(0.0, density * gain)
	if cam_distance <= 0.0:
		return d
	return d * FOG_REFERENCE_DEPTH / maxf(cam_distance, 1.0)


## 找一个可用的 [WorldEnvironment]：子树里已有就复用，没有就挂在 [param host] 下新建。
##
## 复用而不是每次新建，是因为重复挂多个 `WorldEnvironment` 时 Godot 只认其中一个，
## 症状是"切了风格包但环境没变"，且日志完全正常。
static func ensure_environment(host: Node) -> WorldEnvironment:
	if host == null:
		return null
	var found := host.find_children("*", "WorldEnvironment", true, false)
	for f in found:
		if f is WorldEnvironment:
			return f as WorldEnvironment
	var we := WorldEnvironment.new()
	we.name = "Env"
	host.add_child(we)
	return we

#endregion


#region 暗角

## 挂（或复用）屏幕空间暗角层，返回该 [CanvasLayer]；`vignette_enabled` 为假时返回 null。
##
## 为什么不用 `Environment`：Godot 的环境里**没有暗角项**（只有 glow / SSAO / 调色），
## 而暗角恰恰是微缩感的第三要素 —— 只能自己画。
##
## 幂等：同名的 [constant VIGNETTE_LAYER] 会被清空重建，不会叠加。
static func apply_vignette(host: Node, pack) -> CanvasLayer:
	if host == null or pack == null or not bool(pack.vignette_enabled):
		return null

	var layer: CanvasLayer = null
	var old := host.get_node_or_null(NodePath(VIGNETTE_LAYER))
	if old is CanvasLayer:
		layer = old as CanvasLayer
		for c in layer.get_children():
			## 不在树里时 `queue_free()` 永远不会被处理（消息队列挂在 SceneTree 上），
			## 于是每切一次风格包就漏一个 ColorRect —— 单元测试里必然复现。
			if c.is_inside_tree():
				c.queue_free()
			else:
				## 必须从**它自己的父节点**摘下来：暗角矩形的父节点是 layer 而不是 host，
				## 拿 host 去 remove 会触发引擎侧的 parent 不一致断言。
				layer.remove_child(c)
				c.free()
	if layer == null:
		layer = CanvasLayer.new()
		layer.name = VIGNETTE_LAYER
		layer.layer = VIGNETTE_CANVAS_LAYER
		host.add_child(layer)

	var rect := ColorRect.new()
	rect.name = "Vignette"
	# 暗角颜色完全由 shader 决定；ColorRect.color 只作为基底（留白会被乘成黑）
	rect.color = Color(1, 1, 1, 1)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(rect)

	var mat := ShaderMaterial.new()
	mat.shader = ToonShader.vignette_shader()
	mat.set_shader_parameter(&"u_strength", float(pack.vignette_strength))
	mat.set_shader_parameter(&"u_softness", float(pack.vignette_softness))
	mat.set_shader_parameter(&"u_tint", pack.vignette_tint)
	mat.set_shader_parameter(&"u_warmth", float(pack.vignette_warmth))
	mat.set_shader_parameter(&"u_grain", float(pack.vignette_grain))
	## 颗粒偏移换新值：固定 seed 下颗粒是静止的，看起来像"屏幕脏了"而不是胶片
	mat.set_shader_parameter(&"u_grain_seed", randf() * 1024.0)
	rect.material = mat

	_refresh_vignette(mat, rect)
	## 窗口尺寸变了要重算宽高比，否则暗角会被拉成椭圆
	rect.resized.connect(func() -> void: _refresh_vignette(mat, rect))
	return layer


## 校正暗角的宽高比。
##
## shader 里按 `[uv - 0.5] * vec2(aspect, 1)` 算半径，正是为了让暗角在
## 16:9 与 4:3 窗口下都是**正圆**。这个值不能写死 —— 窗口随时会变。
static func _refresh_vignette(mat: ShaderMaterial, rect: Control) -> void:
	if mat == null or rect == null:
		return
	var vp := rect.get_viewport()
	if vp == null:
		return
	var s := vp.get_visible_rect().size
	mat.set_shader_parameter(&"u_aspect", s.x / maxf(s.y, 1.0))

#endregion


#region 一次性装配

## 一次把镜头、环境、暗角、主光全部装好。风格包切换的标准入口。
##
## [param we] 传 null 时会在 [param host] 子树里找 / 建一个 [WorldEnvironment]，
## 于是"切风格包"这件事不需要调用方先操心场景里有没有环境节点。
static func apply(host: Node, cam: Camera3D, pack, we: WorldEnvironment = null) -> CanvasLayer:
	if host == null or pack == null:
		return null
	apply_camera(cam, pack)
	apply_environment(we if we != null else ensure_environment(host), pack,
		_camera_distance(cam, pack))
	apply_key_light(host, pack)
	return apply_vignette(host, pack)


## 相机到场景中心的距离（米），供雾密度归一化用。
##
## 优先读相机实位（`cam.global_position`），因为长焦后退是调用方在 `apply` **之后**
## 才做的，此刻相机多半还在原点；此时退回风格包给的 `stage_distance_hint`。
static func _camera_distance(cam: Camera3D, pack) -> float:
	if cam != null:
		var d := cam.global_position.length()
		if d > 0.001:
			return d
	if pack != null and "stage_distance_hint" in pack:
		return float(pack.stage_distance_hint)
	return 0.0

#endregion
