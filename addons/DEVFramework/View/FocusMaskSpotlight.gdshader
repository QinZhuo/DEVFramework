shader_type canvas_item;
// 屏幕空间聚光: 读"已经画好的一帧", 目标区域内原样显示(可提亮), 区域外压暗。
// 不挖洞、不提层、不与任何 CanvasLayer / SubViewport 比较层级 —— 因此嵌套子视口天然正确。
// 描边/外发光: 3D 目标用"重渲染贴图的 alpha"当轮廓, 2D 控件用圆角矩形 SDF。
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform sampler2D silhouette : filter_linear, repeat_disable;
uniform bool use_silhouette = false;
uniform int sil_rect = 0;

uniform vec4 rects[8];
uniform int rect_count = 0;
uniform vec2 screen_size = vec2(1920.0, 1200.0);

uniform vec4 dim_color : source_color = vec4(0.0, 0.0, 0.0, 0.62);
uniform float corner_radius = 10.0;
uniform float focus_boost = 1.15;
uniform vec4 glow_color : source_color = vec4(1.0, 0.86, 0.55, 1.0);
uniform float glow_radius = 22.0;
uniform float glow_energy = 0.9;

float sd_round_box(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + vec2(r);
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// 轮廓的"外发光场": 由近到远 8 圈 × 4 方向加权求和 ⇒ 平滑衰减, 不会出现一圈圈
float silhouette_ring(vec2 uv, float radius) {
	float acc = 0.0;
	float wsum = 0.0;
	for (int i = 0; i < 8; i++) {
		float t = (float(i) + 1.0) / 8.0;
		vec2 off = vec2(radius * t) / screen_size;
		float a = 0.0;
		a = max(a, texture(silhouette, uv + vec2(off.x, 0.0)).a);
		a = max(a, texture(silhouette, uv - vec2(off.x, 0.0)).a);
		a = max(a, texture(silhouette, uv + vec2(0.0, off.y)).a);
		a = max(a, texture(silhouette, uv - vec2(0.0, off.y)).a);
		float w = 1.0 - t;
		acc += a * w;
		wsum += w;
	}
	return acc / max(wsum, 0.0001);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 src = texture(screen_tex, uv).rgb;
	vec2 px_pos = uv * screen_size;

	float sil = 0.0;
	if (use_silhouette) {
		sil = smoothstep(0.35, 0.7, texture(silhouette, uv).a);
	}

	float cover = 0.0;
	float dist = 100000.0;
	for (int i = 0; i < 8; i++) {
		if (i >= rect_count) {
			break;
		}
		vec4 r = rects[i];
		if (use_silhouette && i == sil_rect) {
			continue;
		}
		vec2 center = r.xy + r.zw * 0.5;
		float d = sd_round_box(px_pos - center, r.zw * 0.5, min(corner_radius, min(r.z, r.w) * 0.5));
		dist = min(dist, d);
		cover = max(cover, 1.0 - smoothstep(-0.75, 0.75, d));
	}
	cover = max(cover, sil);

	vec3 dimmed = mix(src, dim_color.rgb, dim_color.a);
	vec3 col = mix(dimmed, src * focus_boost, cover);

	// 目标外侧的柔和发光(不画硬描边)
	float outside = 1.0 - cover;
	float g = 0.0;
	if (use_silhouette) {
		g = silhouette_ring(uv, glow_radius) * (1.0 - sil);
	} else {
		float d = max(dist, 0.0);
		g = 1.0 - smoothstep(0.0, max(glow_radius, 1.0), d);
		g *= outside;
	}
	col += glow_color.rgb * g * glow_energy;

	COLOR = vec4(col, 1.0);
}
