@tool
class_name ToonShader
## 三渲二 shader 源码集中处 —— 所有 GLSL 只存在于本文件
##
## 存在的理由：着色器源码是**数据**，混在业务脚本里既没法复用也没法对比改版。
## 本文件只导出源码字符串与两个取 Shader 的静态入口，**不含任何场景逻辑**。
##
## == 三支 shader ==
##   · `TOON_SURFACE`   主材质：固有色分档 + 阴影染色 + 轮廓光 + 块状高光
##   · `TOON_OUTLINE`   倒壳描边材质：沿法线外扩且**屏幕宽度恒定**，片元纯色
##   · `MINIATURE_VIGNETTE`  微缩暗角：屏幕空间一圈压暗，把画面"关"成一件小摆件
##
## ============================ 光照怎么分工（别自己重写这条）===========================
## Godot 4 的 spatial shader 拿不到任何逐像素光数据：
##   · 没有 `light()` 函数（实测：`没有找到与之匹配的函数："light"`）
##   · 连片元内置量 `LIGHT` 也**不存在**（Godot 4.7.2 实测：
##     `表达式中的标识符未知："LIGHT"`；`VIEW` / `NORMAL` / `CAMERA_POSITION_WORLD` 存在）
## 也就是说拿不到"这一像素被遮住了多少"—— 唯一带阴影贴图的通道就是
## **引擎光照对 ALBEDO 的乘法**。想三渲二又不想要写实渐变，只有分工：
##
##   引擎（`render_mode diffuse_toon`）→ 受光 / 背光 / 阴影。`diffuse_toon` 会把 N·L
##      自己量化成硬台阶，于是**明暗交界与阴影边界都是硬的**，这正是赛璐璐要的。
##   本 shader → 固有色分档、染色阴影地板、补光、轮廓光、块状高光，
##      且这几项**全部写进 EMISSION**。EMISSION 不参与引擎光照，
##      所以它们在阴影里依然成立 —— 这是"染色而非压黑"能落地的唯一原因。
##
## 若把轮廓光 / 阴影色写进 ALBEDO，引擎光照会把它们一起乘暗：
## 阴影里只剩黑，色阶边缘也会被连续光照糊掉。**别这么写。**
##
## == 明暗方向为什么是 uniform（`u_key_dir`）而不是引擎的光 ==
## 因为 `LIGHT` 不存在（本文件头），"这一块该用第几档颜色"只能自己给一个方向。
## 这反而是对的：色阶是**画风**，本就该由风格包决定，且与"场景里恰好哪盏灯最亮"无关。
## 代价是**必须与实灯同向**——场景里的 DirectionalLight3D 应当照 [code]u_key_dir[/code]，
## 于是"色阶亮面"与"引擎照到的亮面"落在同一条界线上，硬边阴影才不与色阶打架。
## `ToonStyleDef.key_light_dir` 就是这条约定；`MiniatureStage` 会据此摆主光。
##
## == 三渲二的核心只有两件事==
##   ① **色阶化**：连续的光照强度 → 2~3 个台阶。台阶之间用极窄 smoothstep 过渡，
##      既保住"硬边"（动画感），又抗锯齿（不闪）。
##   ② **染色而非压黑**：暗部往 `shadow_tint` 靠，而不是往黑靠。
##      这是"日式动画阴影"与"写实阴影"的分水岭。
##
## == 变体插槽约定（由 ToonStyleDef.make_material 写入）==
## 档位颜色由 CPU 侧决定（ToonStyleDef 按 ToonPaletteDef 算好三档），
## GPU 只负责"选第几档"。这样调色只改配色方案、不必碰 shader。
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

## 主色阶材质。**光影分工见文件头**（引擎管受光与阴影，本 shader 管固有色与染色）。
##
## 内置变量取舍（Godot 4.7 spatial，全部实测过）：
##   · **`LIGHT` 这个片元内置量不存在**，vertex 阶段也没有 —— 主光方向只能走 `u_key_dir`。
##   · `VIEW` / `NORMAL` 虽然在 fragment 里可用，但**约定随版本漂移**（VIEW 到底指向
##     相机还是背离相机，各版本文档说法不一）。所以本 shader 一律在 `vertex()` 里
##     用 `MODELVIEW_NORMAL_MATRIX` / `MODELVIEW_MATRIX` 自算视图空间量再传下去，
##     只依赖这几个从 4.0 到 4.7 都没动过的顶点内置量。
##   · `safe_dir()`：零向量 `normalize()` 出 NaN，一个 NaN 会顺着整个 fragment
##     把物体染成黑块。向量忘配 / 物体正好在相机原点时全靠它兜住。
const TOON_SURFACE := """
shader_type spatial;
// diffuse_toon：引擎把 N·L 自己量化成硬台阶 ⇒ 明暗交界与**阴影边界都是硬的**。
// 这是 Godot 4 里唯一能拿到阴影的通道（没有 light() 也没有 LIGHT），故明暗分层交给它，
// 本 shader 只负责"每一档是什么颜色"+"暗部染什么色"，绝不跟它抢同一个量。
render_mode diffuse_toon, specular_disabled;

// —— 主光方向（世界空间，指向光的来向）——
// 必须与场景里的 DirectionalLight3D 同向，否则色阶亮面和实灯亮面会错开，
// 硬边阴影与色阶互相打架（表现是"物体上一道硬边 + 另一处亮暗反着来"）。
// 由 ToonStyleDef.key_light_dir 写入；MiniatureStage 用同一个值摆主光。
uniform vec3 u_key_dir = vec3(-0.4082, 0.8165, -0.4082); // normalize(-0.5, 1.0, -0.5)

// —— 色阶三档（CPU 侧由 ToonStyleDef 按 palette 算好）——
uniform vec4 u_tier_light : source_color = vec4(1.0, 0.97, 0.91, 1.0);
uniform vec4 u_tier_mid : source_color = vec4(0.96, 0.87, 0.76, 1.0);
uniform vec4 u_tier_dark : source_color = vec4(0.62, 0.60, 0.78, 1.0);

uniform int u_bands = 3;           // 档数：2 = 清透硬边 / 3 = 常规动画
uniform float u_band_soft = 0.06;  // 档位过渡宽度（占一档的比例）。0 = 完全硬阶

// —— 阴影染色（写进 EMISSION，因此不受引擎光影响）——
// 引擎把阴影处的 ALBEDO 乘到接近 0，不补这一层，阴影就是一块死黑。
// 这层地板就是"日式动画阴影"的颜色；颜色由 CPU 侧按主光色推导（见 ToonStyleDef）。
uniform vec4 u_shadow_tint : source_color = vec4(0.45, 0.40, 0.65, 1.0);
uniform float u_shadow_floor = 0.30; // 阴影地板强度。0 = 退回"阴影压黑"

// —— 环境托底：与阴影地板同族，量很小，只负责让暗部不发脏 ——
uniform vec4 u_ambient : source_color = vec4(0.80, 0.82, 0.92, 1.0);
uniform float u_ambient_energy = 0.35;

// —— 补光（第二个光源）——
// 不用第二盏 OmniLight 的理由：灯要摆位置、要被阴影剔除管，而"暗面提亮"是
// **画风参数**而不是场景事实。做成材质里的方向 + 颜色 + 强度：确定、零开销、可复现。
// 真的需要第二盏实灯时（夜里只点一盏灯笼那种），在该位置放 Light3D 即可——
// diffuse_toon 会把它一并算进 ALBEDO。
uniform vec3 u_fill_dir = vec3(-0.45, 0.30, -0.60); // 世界空间，指向光的来向
uniform vec4 u_fill_color : source_color = vec4(0.60, 0.68, 0.95, 1.0);
uniform float u_fill_strength = 0.22;

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

// 全部在 vertex 里算好再传下去：只依赖 MODELVIEW_NORMAL_MATRIX / MODELVIEW_MATRIX /
// VIEW_MATRIX 这三个跨版本稳定的顶点内置量，不碰任何 fragment 专属内置量（见文件头）。
varying vec3 v_normal;  // 视图空间法线
varying vec3 v_key;     // 主光方向（世界 → 视图空间，指向光的来向）
varying vec3 v_fill;    // 补光方向（世界 → 视图空间）
varying vec3 v_view;    // 片元 → 相机（视图空间）
varying float v_dist;   // 到相机的距离。视图空间里相机在原点，故位置向量长度即距离
varying vec3 v_vcol;
varying vec2 v_slot_uv;

// 归一化兜底：零向量 normalize() 出 NaN，而一个 NaN 会顺着整个 fragment
// 把物体染成黑块。方向忘配、或顶点正好落在相机原点时全靠它兜住。
vec3 safe_dir(vec3 v, vec3 fallback) {
	float len = length(v);
	return len > 0.0001 ? v / len : fallback;
}

void vertex() {
	// MODELVIEW_NORMAL_MATRIX 已含逆转置，缩放过也不会把法线压歪
	v_normal = safe_dir((MODELVIEW_NORMAL_MATRIX * NORMAL).xyz, vec3(0.0, 0.0, 1.0));
	// 两个光方向都是世界空间的，转视图空间后与 v_normal 同空间，可直接点乘
	v_key = safe_dir((VIEW_MATRIX * vec4(u_key_dir, 0.0)).xyz, vec3(0.0, 0.0, 1.0));
	v_fill = safe_dir((VIEW_MATRIX * vec4(u_fill_dir, 0.0)).xyz, vec3(0.0, 0.0, -1.0));
	vec3 vp = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// 视图空间里相机在原点 ⇒ 片元指向相机的方向就是 -vp
	// （不能直接 normalize(VERTEX)：那是模型空间，物体一旦有旋转/缩放就指错了）
	v_view = safe_dir(-vp, vec3(0.0, 0.0, 1.0));
	// view 矩阵是刚体变换（无缩放），视图空间长度 == 世界空间距离，可直接当雾深度用
	v_dist = length(vp);
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
	vec3 n = safe_dir(v_normal, vec3(0.0, 0.0, 1.0));
	// 场景无光 / 方向忘配时退化为"光从相机方向来" ⇒ 物体落在最亮的一档，而不是全黑
	vec3 l = safe_dir(v_key, vec3(0.0, 0.0, 1.0));
	vec3 view = safe_dir(v_view, vec3(0.0, 0.0, 1.0));
	// 形体档：只看几何朝向，**不含阴影**。它只决定"这一块该用第几档颜色"；
	// 谁亮谁暗交给引擎的 diffuse_toon —— 阴影贴图只有那边有，本着色器拿不到。
	float tier = quantize_bands(dot(n, l) * 0.5 + 0.5);

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

	// 极淡距离雾：不是"雾"，是"把远处物体轻轻推远"，制造"放在桌上"的微缩感
	float fog = clamp(1.0 - exp(-u_fog_density * max(v_dist, 0.0)), 0.0, 1.0);

	// 固有色交给引擎：受光 / 背光 / 阴影全由 diffuse_toon 决定 —— 硬边，且带阴影贴图。
	// 雾混进 ALBEDO，于是雾也吃引擎光照，阴影里的雾不会被提亮。
	ALBEDO = mix(col, u_fog_color.rgb, fog);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0; // 二渲二不要 PBR 高光，高光已由 u_spec_step 手动画
	METALLIC = 0.0;

	// == 以下全部写进 EMISSION：不参与引擎光照，因此在阴影里依然成立 ==
	// 这是"染色而非压黑"能落地的唯一原因：ALBEDO 会被阴影乘黑，EMISSION 不会。
	vec3 emis = vec3(0.0);

	// 阴影地板：引擎阴影越强 ⇒ ALBEDO 项越小 ⇒ 这里越接近"纯阴影色"。
	// shadow_tint.a 当总开关用（= 0 时整套染色关闭，回到纯硬刻）。
	float floor_w = clamp(u_shadow_floor, 0.0, 1.0) * u_shadow_tint.a;
	emis += mix(u_shadow_tint.rgb, u_tier_dark.rgb, 0.35) * floor_w;

	// 阴影里保留一点固有色 ⇒ 暗部读起来仍是"同一个东西变暗"，而不是被涂了一层平色
	emis += col * floor_w * 0.30 * (1.0 - tier);

	// 环境托底：与阴影地板同族，量很小，只负责把最暗处从"脏灰"拉回"通透"
	emis += u_ambient.rgb * clamp(u_ambient_energy, 0.0, 1.0) * 0.35;

	// 补光（第二个光源）：包裹式暗面提亮。暗面权重更高、亮面只留一点，
	// 于是背光侧不会只剩一层死板的阴影色 —— 夜戏里"灯在另一边"就靠它。
	float fill_w = smoothstep(0.30, 0.85, dot(n, safe_dir(v_fill, vec3(0.0, 0.0, -1.0))) * 0.5 + 0.5);
	emis += u_fill_color.rgb * clamp(u_fill_strength, 0.0, 2.0) * fill_w * (1.0 - tier * 0.45);

	// 块状高光：半程向量阈值化成硬块（不是渐变高光）
	if (u_spec_step) {
		vec3 h = normalize(l + view);
		float s = smoothstep(u_spec_threshold, u_spec_threshold + max(u_spec_soft, 0.001),
			dot(n, h));
		emis += u_spec_color.rgb * s;
	}

	// 轮廓光：掠射角处的一圈亮边，pow 越大越细
	float rim = pow(clamp(1.0 - dot(view, n), 0.0, 1.0), max(u_rim_power, 0.001));
	emis += u_rim_color.rgb * rim * u_rim_strength;

	EMISSION = emis;
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


## 微缩暗角（屏幕空间）。
##
## 为什么需要它：微缩感 = "长焦 + 浅景深 + 边缘收暗"三件事的合力。
## 长焦与浅景深由 `CameraAttributesPractical` 提供（引擎自带，见 MiniatureStage），
## 但"边缘收暗"必须自己画——`Environment` 里没有暗角项。
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

static var _surface_shader: Shader
static var _outline_shader: Shader
static var _vignette_shader: Shader


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


## 微缩暗角 shader（懒加载并缓存）。由 MiniatureStage 挂到 CanvasLayer 上。
static func vignette_shader() -> Shader:
	if _vignette_shader == null:
		var s := Shader.new()
		s.code = MINIATURE_VIGNETTE
		_vignette_shader = s
	return _vignette_shader

#endregion