@tool
class_name ToonShader
## 三渲二 shader 源码集中处 —— 所有 GLSL 只存在于本文件
##
## 存在的理由：着色器源码是**数据**，混在业务脚本里既没法复用也没法对比改版。
## 本文件只导出源码字符串与两个取 Shader 的静态入口，**不含任何场景逻辑**。
##
## == 两支 shader ==
##   · `TOON_SURFACE`  主色阶材质：走光照，但把 N·L 量化成阶梯（日式动画的关键动作）
##   · `TOON_OUTLINE`  倒壳描边材质：沿法线外扩且**屏幕宽度恒定**，片元纯色
##
## == 三渲二的核心只有两件事==
##   ① **色阶化**：连续的光照强度 → 2~3 个台阶。台阶之间用极窄 smoothstep 过渡，
##      既保住"硬边"（动画感），又抗锯齿（不闪）。
##   ② **染色而非压黑**：暗部往 `shadow_tint` 靠，而不是往黑靠。
##      这是"日式动画阴影"与"写实阴影"的分水岭。
##
## == 变体插槽约定（由 ToonStyleDef.make_material 写入）==
##   档位颜色由 CPU 侧决定（ToonStyleDef 按 ToonPaletteDef 算好三档），
##   GPU 只负责"选第几档"。这样调色只改配色方案、不必碰 shader。
##
## == 与槽位通道的关系 ==
##   SDF 场里的槽位（[constant SdfField.SLOT_NONE] 为哨兵，提取阶段已折叠到 0 号槽）
##   有**两条**进 GPU 的路，本 shader 两条都支持，且前者优先：
##     ① `u_slot_ramp`（256×1 色带纹理）+ `UV2.x = slot / 255.0`
##        —— 换配色只换纹理，**网格不用重提**；采样精度注意事项见 uniform 处的警告。
##     ② `u_use_vcol`（ARRAY_COLOR 顶点色）
##        —— 一次提取配一套颜色，色板直接烘进网格。
##   两者都只决定"这件东西是什么色"（中档），亮/暗档仍向风格色靠，
##   因此"分件各有固有色"与"整体同一画风"可以兼得。

#region 源码

## 主色阶材质。
##
## 内置变量取舍（Godot 4 spatial）：
##   · `LIGHT`（视图空间、已归一化的光照方向）与 `NORMAL`（视图空间法线）
##     在 `fragment()` 里都可用，但为规避版本差异，本 shader 一律在 `vertex()`
##     里取好并用 varying 传下去——varying 是全版本稳定路径。
##   · 仍保留 `u_manual_light` + `u_light_dir` 手动光向开关：某些自定义
##     Compositor / Light3D 配置下 `LIGHT` 不可用，可退回自建光向 uniform。
const TOON_SURFACE := """
shader_type spatial;
render_mode diffuse_burley, specular_toon;

// —— 色阶三档（CPU 侧由 ToonStyleDef 按 palette 算好）——
uniform vec4 u_tier_light : source_color = vec4(1.0, 0.97, 0.91, 1.0);
uniform vec4 u_tier_mid : source_color = vec4(0.96, 0.87, 0.76, 1.0);
uniform vec4 u_tier_dark : source_color = vec4(0.62, 0.60, 0.78, 1.0);

uniform int u_bands = 3;           // 档数：2 = 清透硬边 / 3 = 常规动画
uniform float u_band_soft = 0.06;  // 档位过渡宽度（占一档的比例）。0 = 完全硬阶

uniform vec4 u_shadow_tint : source_color = vec4(0.45, 0.40, 0.65, 1.0);
uniform float u_shadow_mix = 0.30; // 暗部向 shadow_tint 靠拢的比例

uniform vec4 u_ambient : source_color = vec4(0.80, 0.82, 0.92, 1.0);
uniform float u_ambient_energy = 0.35;

// —— 二渲二块状高光（逆光下的"一点白"）——
uniform bool u_spec_step = false;
uniform vec4 u_spec_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float u_spec_threshold = 0.72;
uniform float u_spec_soft = 0.04;

// —— 轮廓光（日式动画的灵魂：物体边缘的一圈亮边）——
uniform vec4 u_rim_color : source_color = vec4(1.0, 0.95, 0.88, 1.0);
uniform float u_rim_strength = 0.6;
uniform float u_rim_power = 2.5;

// —— 微缩感：极淡的距离雾（把物体"关"在一个小盒子里）——
uniform vec4 u_fog_color : source_color = vec4(0.86, 0.88, 0.94, 1.0);
uniform float u_fog_density = 0.008;

// —— 手动光向兜底 ——
uniform bool u_manual_light = false;
uniform vec3 u_light_dir = vec3(0.35, 0.80, 0.45);

// —— 顶点色（语义分件）——
// 上游 SlotPalette 把槽位色烘进 ARRAY_COLOR（屋顶/墙/木/玻璃…各拿各的色）。
// 打开后**中档**由顶点色决定，亮档/暗档仍向风格的暖白与暗部染色靠——
// 于是"每件东西有自己的固有色"与"整体仍是同一种画风"同时成立。
uniform bool u_use_vcol = false;
uniform float u_vcol_strength = 1.0; // 0 = 完全忽略顶点色（退回纯配色方案）

// —— 槽位查表（换配色**不必**重提网格）——
// 上游把槽位号编码进 UV2.x（= slot / 255.0），这里查 256×1 的色带纹理还原颜色。
// 走纹理而不是 `uniform vec4 u_slot_colors[256]`：4KB 定长 uniform 在 GLES3 /
// 移动端的驱动上限偏低，动态下标还会被展成大量寄存器；纹理是逐样本读取，没有这个问题，
// 且色带长度可以随便扩。色带由 `ToonMaterial.make_slot_ramp()` 烘出。
//
// ⚠️⚠️ 采样精度陷阱，改编码或改滤波前务必先读这段 ⚠️⚠️
// 256 宽的纹理里第 i 个 texel 占 [i/256, (i+1)/256)，而 `slot / 255.0` 落在**texel 边界上**：
//   slot = 0   → u = 0.0          → texel 0 的左边界
//   slot = 1   → u = 1/255 ≈ .004 → **仍落在 texel 0 区间内**，LINEAR 读出 slot 0 的色
// 所以必须 `filter_nearest`：此时采样索引为 floor(u*256)，对 slot ∈ [0,254] 全部精确还原。
// 若一定要用线性滤波，编码必须改成 `(slot + 0.5) / 256`（但那要连带改提取侧）。
uniform sampler2D u_slot_ramp : filter_nearest, repeat_disable;
uniform bool u_use_slot_tex = false;

varying vec3 v_normal;
varying vec3 v_light;
varying vec3 v_view;
varying float v_dist;
varying vec3 v_vcol;
varying vec2 v_slot_uv;

void vertex() {
	// NORMAL / LIGHT 在 vertex() 里分别是视图空间法线与视图空间光向（均已归一化）
	v_normal = normalize(NORMAL);
	v_light = u_manual_light
		? normalize((VIEW_MATRIX * vec4(u_light_dir, 0.0)).xyz)
		: normalize(LIGHT);
	// 视图空间里相机在原点，故 VERTEX 的方向就是"片元 → 相机"
	v_view = normalize(VERTEX);
	v_dist = length((MODEL_MATRIX * vec4(VERTEX, 0.0)).xyz - CAMERA_POSITION_WORLD);
	// 网格没有 ARRAY_COLOR 时 COLOR 为白，故这里取到白也不会脏化；由 u_use_vcol 决定是否采信
	v_vcol = COLOR.rgb;
	// 槽位号在 UV2.x（= slot / 255.0）。网格没写 UV2 时为 0，即"槽位 0"——
	// 与提取阶段把 SLOT_NONE 折叠到 0 号槽的处理一致，故这里不必特判未指定。
	v_slot_uv = UV2;
}

// 把 [0,1] 的连续光照量化成 u_bands 个台阶。
// 台阶内是硬边（动画感），只在台阶边界附近用 u_band_soft 做极窄 smoothstep（抗锯齿）。
// 返回值：0 = 全暗档，1 = 全亮档；中间值即"正踩在过渡带上"。
float quantize_bands(float x) {
	float levels = max(1.0, float(u_bands) - 1.0);
	float s = clamp(x, 0.0, 1.0) * levels;
	float w = clamp(u_band_soft, 0.0, 0.5);
	// smoothstep(1-w, 1, frac)：w=0 时恒为 1 ⇒ 纯硬阶；w 增大时边界变柔
	float stepped = floor(s) + smoothstep(1.0 - w, 1.0, fract(s));
	return clamp(stepped / levels, 0.0, 1.0);
}

// 三档取色：tier<1/3 亮档，<2/3 中档，其余暗档。
// 不用分支而用 step 权重，避免不同档走不同代码路径导致抖动。
vec3 pick_tier(float tier, vec3 lt, vec3 md, vec3 dk) {
	vec3 light_w = vec3(step(1.0 / 3.0, tier));
	vec3 mid_w = vec3(step(1.0 / 3.0, tier) * (1.0 - step(2.0 / 3.0, tier)));
	vec3 dark_w = vec3(1.0 - step(1.0 / 3.0, tier));
	return lt * light_w + md * mid_w + dk * dark_w;
}

void fragment() {
	float ndl = dot(normalize(v_normal), normalize(v_light)) * 0.5 + 0.5;
	float tier = quantize_bands(ndl);

	// 固有色（中档）来源，优先级：槽位纹理 > 顶点色 > 配色方案。
	// 三者都只决定"这件东西是什么色"，画风仍由 u_tier_light / u_tier_dark 兜住。
	vec3 mid_col = u_tier_mid.rgb;
	if (u_use_vcol) {
		mid_col = mix(mid_col, v_vcol, clamp(u_vcol_strength, 0.0, 1.0));
	}
	if (u_use_slot_tex) {
		// NEAREST 下采样索引 = floor(u*256)，把 UV2.x 的 slot/255.0 精确还原成槽位号。
		// UV2 缺省为 0 ⇒ 读槽位 0，不会越界、也不需要"未指定"分支。
		mid_col = texture(u_slot_ramp, vec2(clamp(v_slot_uv.x, 0.0, 1.0), 0.5)).rgb;
	}

	vec3 tier_lt = u_tier_light.rgb;
	vec3 tier_md = mid_col;
	vec3 tier_dk = u_tier_dark.rgb;
	if (u_use_vcol || u_use_slot_tex) {
		// 有分件色时另两档向风格色靠（而不是拿分件色自己推亮暗），
		// 这样屋顶/墙/木/玻璃各有固有色，而高光与暗部仍是同一套画风。
		tier_lt = mix(tier_md, u_tier_light.rgb, 0.65);
		tier_dk = mix(tier_md, u_tier_dark.rgb, 0.75);
	}

	vec3 col = pick_tier(tier, tier_lt, tier_md, tier_dk);

	// 暗部染色：tier 越低越向 shadow_tint 靠（染色，不是压黑）
	col = mix(col, u_shadow_tint.rgb, (1.0 - tier) * u_shadow_mix * u_shadow_tint.a);

	// 环境光：抬高暗部整体亮度，制造"低对比、微缩"的观感
	col = mix(col, u_ambient.rgb, clamp(u_ambient_energy, 0.0, 1.0) * (1.0 - tier * 0.65));

	// 块状高光：半程向量阈值化成硬块（不是渐变高光）
	if (u_spec_step) {
		vec3 h = normalize(normalize(v_light) + normalize(v_view));
		float s = smoothstep(u_spec_threshold, u_spec_threshold + max(u_spec_soft, 0.001),
			dot(normalize(v_normal), h));
		col = mix(col, u_spec_color.rgb, s);
	}

	// 轮廓光：掠射角处的一圈亮边，pow 越大越细
	float rim = pow(clamp(1.0 - dot(normalize(v_view), normalize(v_normal)), 0.0, 1.0),
		max(u_rim_power, 0.001));
	col += u_rim_color.rgb * rim * u_rim_strength;

	// 极淡距离雾：把远处物体轻轻推向雾色，制造"放在桌上"的微缩感
	float fog = 1.0 - exp(-u_fog_density * max(v_dist, 0.0));
	col = mix(col, u_fog_color.rgb, clamp(fog, 0.0, 1.0));

	ALBEDO = col;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0; // 二渲二不要 PBR 高光，高光已由 u_spec_step 手动画
	METALLIC = 0.0;
}
"""


## 倒壳描边材质。
##
## 关键：**屏幕宽度恒定**。做法是把视图空间外扩量除以投影矩阵的 [0][0] / [1][1]
## （= 1/tan(fov/2)，Godot 的投影矩阵已含 aspect），再乘以到相机的距离——
## 于是无论物体近还是远，描边在屏幕上都是同样粗的一圈。
## 若直接按固定世界长度外扩，远处描边会细得看不见（微缩场景里物体本就跨深度）。
const TOON_OUTLINE := """
shader_type spatial;
render_mode unshaded, cull_front, shadows_disabled;

uniform vec4 u_outline_color : source_color = vec4(0.20, 0.15, 0.24, 1.0);
uniform float u_width = 0.012;   // NDC 单位下的半宽（0.012 ≈ 屏幕上的细描边）
uniform float u_min_dist = 0.05; // 距离下限：贴脸时防止外扩量退化到 0

void vertex() {
	// MODELVIEW_MATRIX 的平移分量 = 模型原点在视图空间的位置，其长度即到相机距离
	float dist = max(length(MODELVIEW_MATRIX[3].xyz), u_min_dist);
	vec2 proj = vec2(PROJECTION_MATRIX[0][0], PROJECTION_MATRIX[1][1]);
	// 逐轴除以投影缩放 ⇒ x/y 各自得到恒定的 NDC 宽度（aspect 自动被 PROJECTION_MATRIX 处理）
	vec3 offset = normalize(NORMAL) * (u_width * dist) / vec3(max(proj.x, 0.0001),
		max(proj.y, 0.0001), 1.0);
	VERTEX += offset;
}

void fragment() {
	ALBEDO = u_outline_color.rgb;
	ALPHA = u_outline_color.a;
}
"""

#endregion


#region Shader 入口

static var _surface_shader: Shader
static var _outline_shader: Shader


## 主色阶 shader（懒加载并缓存：同一份源码只编译一次）
static func surface_shader() -> Shader:
	if _surface_shader == null:
		var s := Shader.new()
		s.code = TOON_SURFACE
		_surface_shader = s
	return _surface_shader


## 倒壳描边 shader（懒加载并缓存）
static func outline_shader() -> Shader:
	if _outline_shader == null:
		var s := Shader.new()
		s.code = TOON_OUTLINE
		_outline_shader = s
	return _outline_shader

#endregion