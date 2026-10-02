@tool
class_name AirshipGen
extends PropGen
## 用例五主体 —— 小型蒸汽飞艇：皮革气囊 + 黄铜吊舱 + 两侧螺旋桨 + 尾舵
##
## ## 造型自律
## · **气囊用椭球**。飞艇是这套里唯一"必须有曲面"的东西 —— 方气囊一眼就是积木。
##   [method SdfTool.sd_ellipsoid] 是 iq 一阶近似（误差 ≤3%），在体素下这点误差
##   完全看不出来；反倒是它让"皮革气囊"有了区别于黄铜硬表面的软轮廓。
## · **旋转体用坐标置换，不用旋转矩阵**。螺旋桨轴沿 X、舷窗朝 +X，
##   于是把 `p` 的分量换成 `(p.y, p.z, p.x)` 再喂 [method SdfTool.sd_torus]
##   （环平面是 XY、轴沿 Z）—— 纯置换，不引入任何非轴对齐的面。
## · **螺旋桨叶片用辐条**。[method SdfTool.sd_segment] 从桨毂拉到桨尖，
##   三根就够读出"桨"。真做出扭角叶片在 0.14 的体素下只会变成三块模糊的疙瘩。
##
## ## y 为什么从 0.75 起
## 飞艇是**停在码头旁**的，不是落地的：吊舱底离地 0.75 米，靠配方
## `y_offset = 0.75` 抬起来（摆放层的 lift 会先把 mesh 最低点贴到地面）。
## 少了这个偏移，整艘船会坐在甲板上 —— 那既不"停靠"也不"飞行"。

## 全长 4.5 米。刻意不做得更长：摆放层的避让用的是**外接半径**，
## 一件 5.5 米长的飞艇会拿到近 3 米的避让圆，于是它与锅炉、道具组之间
## 都得留出 3 米以上 —— 那意味着台面上除了它几乎放不下别的（实测 12×9 时
## 它被 relax 顶到台沿）。"小型蒸汽飞艇"本来就该是这个尺寸。
const ELL := Vector3(1.60, 0.85, 0.85)   ## 气囊半轴（X 为飞艇轴向）
const ENV_Y := 2.20                      ## 气囊中心高度
const GONDOLA := Vector3(0.70, 0.28, 0.42)  ## 吊舱半尺寸
const GONDOLA_Y := 1.05                  ## 吊舱中心高度
const PROP_X := -1.05                    ## 螺旋桨所在的 X
const PROP_Z := 0.95                     ## 螺旋桨距中轴的距离（两侧各一）
const PROP_R := 0.42                     ## 桨盘半径
const TAIL_X := -1.85                    ## 尾舵 X
const WIN_R := 0.24                      ## 舷窗半径

func _envelope(p: Vector3) -> float:
	return SdfTool.sd_ellipsoid(p - Vector3(0.0, ENV_Y, 0.0), ELL)

## 三道铜箍：绕气囊的环（轴沿 X ⇒ 置换分量）
func _bands(p: Vector3) -> float:
	var d := 1e9
	for x in [-0.85, 0.0, 0.85]:
		var q := Vector3(p.y - ENV_Y, p.z, p.x - x)
		d = SdfTool.op_union(d, SdfTool.sd_torus(q, 0.86, 0.045))
	return d

func _gondola(p: Vector3) -> float:
	var d := SdfTool.sd_box(p - Vector3(0.0, GONDOLA_Y, 0.0), GONDOLA)
	## 船首：一个前伸的圆台（sd_capped_cone 轴沿 Y，同样靠置换转成沿 X）
	var q := Vector3(p.z, p.y - GONDOLA_Y, p.x - GONDOLA.x)
	d = SdfTool.op_union(d, SdfTool.sd_capped_cone(q, 0.42, 0.40, 0.22))
	## 甲板围栏：沿吊舱上沿一圈细梁
	for z in [-0.40, 0.40]:
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, GONDOLA_Y + 0.28, z), Vector3(0.80, 0.04, 0.03)))
	return d

## 四根吊索：从吊舱四角拉到气囊底部
func _cables(p: Vector3) -> float:
	var d := 1e9
	for x in [-0.62, 0.62]:
		for z in [-0.34, 0.34]:
			d = SdfTool.op_union(d, SdfTool.sd_segment(p,
				Vector3(x, GONDOLA_Y + 0.26, z),
				Vector3(x * 0.7, ENV_Y - 0.72, z * 0.7), 0.035))
	return d

## 两侧螺旋桨：桨毂 + 三根辐条 + 一圈桨环（轴沿 X）
func _props(p: Vector3) -> float:
	var d := 1e9
	for sz in [-PROP_Z, PROP_Z]:
		var hub := Vector3(PROP_X, ENV_Y - 0.62, sz)
		d = SdfTool.op_union(d, SdfTool.sd_sphere(p - hub, 0.13))
		var q := Vector3(p.y - hub.y, p.z - hub.z, p.x - hub.x)
		d = SdfTool.op_union(d, SdfTool.sd_torus(q, PROP_R, 0.035))
		for i in 3:
			var a := TAU * float(i) / 3.0
			var tip := hub + Vector3(0.0, cos(a) * PROP_R, sin(a) * PROP_R)
			d = SdfTool.op_union(d, SdfTool.sd_segment(p, hub, tip, 0.055))
	return d

## 尾舵：十字翼，两片薄盒
func _tail(p: Vector3) -> float:
	var d := SdfTool.sd_box(p - Vector3(TAIL_X, ENV_Y, 0.0),
		Vector3(0.34, 0.62, 0.05))
	d = SdfTool.op_union(d, SdfTool.sd_box(
		p - Vector3(TAIL_X, ENV_Y, 0.0), Vector3(0.34, 0.05, 0.62)))
	return d

## 舷窗：吊舱前端一片玻璃（朝 +X 的扁棱柱）
func _window(p: Vector3) -> float:
	var q := Vector3(p.z, p.y - GONDOLA_Y, p.x - (GONDOLA.x + 0.36))
	return SdfTool.sd_prism(q, WIN_R, 0.05, 8)

func local_bounds() -> AABB:
	return AABB(Vector3(-2.25, 0.0, -1.35), Vector3(4.50, 3.30, 2.70))

func build(_field: SdfField) -> void:
	fill_shape(func(p: Vector3) -> float:
		var d := _envelope(p)
		d = SdfTool.op_union(d, _bands(p))
		d = SdfTool.op_union(d, _gondola(p))
		d = SdfTool.op_union(d, _cables(p))
		d = SdfTool.op_union(d, _props(p))
		d = SdfTool.op_union(d, _tail(p))
		d = SdfTool.op_union(d, _window(p))
		return d)

func voxel_regions() -> Array:
	var b := local_bounds()
	var out := []
	## ① 舷窗玻璃
	out.append(SteamSkin.box(Vector3(GONDOLA.x + 0.36, GONDOLA_Y, 0.0),
		Vector3(0.14, WIN_R * 2.0, WIN_R * 2.0), SteamSkin.GLASS))
	## ② 螺旋桨（暗铜）：两侧的球形范围
	for sz in [-PROP_Z, PROP_Z]:
		out.append(SteamSkin.box(Vector3(PROP_X, ENV_Y - 0.62, sz),
			Vector3(0.30, PROP_R * 2.2, PROP_R * 2.2), SteamSkin.BRASS_DK))
	## ③ 气囊受光的上半（皮革提亮）
	out.append(SteamSkin.band_y(ENV_Y, ENV_Y + ELL.y + 0.1, 2.2, SteamSkin.LEATHER_HI))
	## ④ 气囊下半（皮革）
	out.append(SteamSkin.band_y(ENV_Y - ELL.y - 0.1, ENV_Y, 2.2, SteamSkin.LEATHER))
	## ⑤ 吊舱与吊索（黄铜）
	out.append(SteamSkin.band_y(0.6, ENV_Y - 0.5, 1.6, SteamSkin.BRASS))
	## ⑥ 兜底：黄铜（尾舵 / 铜箍 / 桨毂都落在这一档也不违和）
	out.append(SteamSkin.all(b, SteamSkin.BRASS))
	return out

func meta() -> Dictionary:
	return {
		&"tag": "airship",
		&"surface_snap": true,
		&"wants_ground": false,
		&"face_dir": Vector3i(1, 0, 0),
	}
