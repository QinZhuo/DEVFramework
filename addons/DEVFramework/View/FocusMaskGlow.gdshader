shader_type canvas_item;
// 点亮结果的后处理: 只在物体外侧加"柔和外发光", 不画描边、不出圈。
// 目标渲染在透明底视口里, alpha 就是它的真实轮廓; 用多圈加权采样近似高斯, 再平方压一次曲线。
uniform vec4 glow_color : source_color = vec4(1.0, 0.86, 0.55, 1.0);
uniform float glow_radius : hint_range(4.0, 96.0) = 34.0;
uniform float glow_energy : hint_range(0.0, 3.0) = 0.8;
uniform float inner_boost : hint_range(0.0, 1.0) = 0.05;

const int RINGS = 10;
const int DIRS = 12;

float alpha_at(sampler2D tex, vec2 uv) {
	return texture(tex, uv).a;
}

void fragment() {
	vec4 src = texture(TEXTURE, UV);
	vec2 px = TEXTURE_PIXEL_SIZE;

	float acc = 0.0;
	float wsum = 0.0;
	for (int i = 0; i < RINGS; i++) {
		float t = (float(i) + 1.0) / float(RINGS);
		vec2 r = px * glow_radius * t;
		float w = 1.0 - t;                      // 近似高斯: 内圈权重高
		w = w * w;
		float a = 0.0;
		for (int d = 0; d < DIRS; d++) {
			float ang = float(d) * 0.5235987756;  // 2π/12
			a = max(a, alpha_at(TEXTURE, UV + vec2(cos(ang), sin(ang)) * r));
		}
		acc += a * w;
		wsum += w;
	}

	float g = acc / max(wsum, 0.0001);
	float outside = clamp(g, 0.0, 1.0) * (1.0 - src.a);
	// 轻微压一下近处, 让最亮处不贴着轮廓而是散开
	outside = outside * outside * 0.35 + outside * 0.65;
	vec3 rgb = src.rgb * (1.0 + inner_boost * src.a) + glow_color.rgb * outside * glow_energy;
	float alpha = max(src.a, clamp(outside * glow_energy * 0.8, 0.0, 0.8));

	COLOR = vec4(rgb, alpha);
}
