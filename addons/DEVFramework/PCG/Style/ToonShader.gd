@tool
class_name ToonShader
## 微缩暗角 shader 源码 —— 本模块**只剩这一支** canvas_item shader
##
## == 为什么 3D 表面与描边不再写 shader ==
## 本模块曾经有三支 GLSL：`TOON_SURFACE`（色阶 + 阴影染色 + 轮廓光 + 块状高光）、
## `TOON_OUTLINE`（倒壳描边）、`MINIATURE_VIGNETTE`（屏幕暗角）。
## 前两支已删除，改为纯用引擎内置 `StandardMaterial3D`：
##   · 表面 → `StandardMaterial3D.albedo_color` + 引擎真实光照（含阴影）
##   · 描边 → `StandardMaterial3D.grow_amount` + `cull_mode = CULL_FRONT` + `unshaded`
##
## 删掉的理由不只是"少写点代码"，而是自写 3D shader 在本项目里**有两个绕不开的硬伤**：
##   ① **拿不到逐像素光照**。Godot 4 的 spatial shader 没有 `light()` 函数，
##      连片元内置量 `LIGHT` 都不存在（4.7 实测：`表达式中的标识符未知："LIGHT"`）。
##      唯一带阴影的通道就是引擎对 ALBEDO 的乘法，所以"染色而非压黑"只能靠
##      **无条件写进 EMISSION** 来伪造——而 EMISSION 不参与光照，等于在受光面
##      也硬加一层常量底噪。实测后果：固有色稍亮的部件（黄铜 0.85 / 米白 0.92）
##      在受光面上 ALBEDO + EMISSION 直接越过 1.0，顶面成片烧白且**压曝光压不回来**
##      （曝光是相对量，降它会同比例压掉阴影侧染色）。
##   ② **色调映射会把它切平**。`Environment.tonemap_mode = LINEAR` 时超过
##      `tonemap_white` 的值直接截断成纯白，没有高光滚降，自写 shader 堆多少项
##      加色都在争同一份"余量"，越加越白。
##
## 改回内置材质后这两条一起消失：明暗、阴影、能量守恒全部由引擎负责，
## 而 PCG 的本职（生成模型）不被渲染细节绑架。
##
## == 剩下的这一支为什么还得自己写 ==
## 微缩感 = "长焦 + 浅景深 + 边缘收暗"三件事的合力。前两件引擎自带
## （`CameraAttributesPractical` 与长焦 FOV），但 **`Environment` 里没有暗角项**，
## 只能自己画一个全屏 `ColorRect`。

#region 源码

## 微缩暗角（屏幕空间）。
##
## 为什么需要它：见文件头——长焦与浅景深引擎自带，"边缘收暗"没有对应项。
##
## 顺带做了两件与"可收藏摆件"有关的事：
##   · 极轻的暖冷分离（中心偏暖、边缘偏冷），这是让小模型看起来"精致"的老手法
##   · 可选的极弱胶片颗粒，压掉大面积平色带来的"塑料感"
const MINIATURE_VIGNETTE := """
shader_type canvas_item;
render_mode blend_mix;

uniform float u_strength : hint_range(0.0, 2.0) = 0.42;  // 暗角总强度
uniform float u_softness : hint_range(0.05, 2.0) = 0.62; // 越大越柔（小模型要柔，太锐像滤镜）
uniform float u_aspect = 1.0;   // 画面宽高比。不传的话暗角会被拉成椭圆
uniform vec4 u_tint : source_color = vec4(0.06, 0.05, 0.10, 1.0); // 暗角色（偏冷紫）
uniform float u_warmth : hint_range(0.0, 1.0) = 0.18;  // 中心向暖色偏一点
uniform float u_grain = 0.012;  // 颗粒量
uniform float u_grain_seed = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	// 以画面中心为原点、按宽高比校正 ⇒ 暗角是正圆（不随窗口比例变形）
	vec2 d = (uv - vec2(0.5, 0.5)) * vec2(u_aspect, 1.0) * 2.0;
	float r = length(d) * 0.7071;

	// smoothstep(内, 外, r)：内圈不动、外圈全暗，中间平滑过渡
	float v = smoothstep(1.0 - u_softness, 1.0, r);
	vec4 col = vec4(u_tint.rgb, v * clamp(u_strength, 0.0, 2.0));

	// 中心微暖：正圆心往下压一点饱和暖，用极低透明度叠加
	float warm = (1.0 - smoothstep(0.0, 0.85, r)) * u_warmth;
	col = mix(col, vec4(1.0, 0.94, 0.84, 0.10), warm * 0.5);

	// 胶片颗粒：把大块平色打散一点，避免"塑料摆件"感
	float g = hash21(uv * vec2(1920.0, 1080.0) + u_grain_seed) - 0.5;
	col.rgb += g * u_grain;

	COLOR = col;
}
"""

#endregion


#region Shader 入口

static var _vignette_shader: Shader


## 微缩暗角 shader（懒加载并缓存）。由 MiniatureStage 挂到 CanvasLayer 上。
static func vignette_shader() -> Shader:
	if _vignette_shader == null:
		var s := Shader.new()
		s.code = MINIATURE_VIGNETTE
		_vignette_shader = s
	return _vignette_shader

#endregion