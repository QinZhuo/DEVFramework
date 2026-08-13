#include "pcg_erode.h"

#include <godot_cpp/core/class_db.hpp>
#include <cmath>
#include <algorithm>

using namespace godot;

void PCGErode::_bind_methods() {
	ClassDB::bind_method(D_METHOD("erode", "heights", "width", "height",
			"droplets", "inertia", "power", "radius", "min_slope", "evaporate", "seed",
			"cliff_drop", "deposition_rate"),
			&PCGErode::erode);
	ClassDB::bind_method(D_METHOD("thermal", "heights", "width", "height",
			"iterations", "talus"),
			&PCGErode::thermal);
}

// 双线性插值取高度(浮点坐标, 边缘 clamp)
static float bilerp(const std::vector<float> &h, int w, int hgt, float x, float y) {
	if (w <= 0 || hgt <= 0 || h.empty())
		return 0.0f;
	auto clampi_ = [](int v, int lo, int hi) { return std::max(lo, std::min(hi, v)); };
	int x0 = clampi_((int)std::floor(x), 0, w - 1);
	int y0 = clampi_((int)std::floor(y), 0, hgt - 1);
	int x1 = clampi_(x0 + 1, 0, w - 1);
	int y1 = clampi_(y0 + 1, 0, hgt - 1);
	float fx = std::max(0.0f, std::min(1.0f, x - std::floor(x)));
	float fy = std::max(0.0f, std::min(1.0f, y - std::floor(y)));
	float h00 = h[(size_t)y0 * w + x0];
	float h10 = h[(size_t)y0 * w + x1];
	float h01 = h[(size_t)y1 * w + x0];
	float h11 = h[(size_t)y1 * w + x1];
	float a = h00 + (h10 - h00) * fx;
	float b = h01 + (h11 - h01) * fx;
	return a + (b - a) * fy;
}

// 对半径邻域施加侵蚀(amount<0 削低, >0 沉积抬高), 按距离加权
static void apply_erosion(std::vector<float> &h, int w, int hgt, float cx, float cy, float amount, int radius) {
	if (std::fabs(amount) < 1e-4f || radius <= 0)
		return;
	int xi = (int)std::floor(cx);
	int yi = (int)std::floor(cy);
	int r = radius;
	float r_sq = (float)(r * r);
	for (int dy = -r; dy <= r; ++dy) {
		for (int dx = -r; dx <= r; ++dx) {
			int nx = xi + dx;
			int ny = yi + dy;
			if (nx < 0 || nx >= w || ny < 0 || ny >= hgt)
				continue;
			float dist_sq = (float)(dx * dx + dy * dy);
			if (dist_sq > r_sq)
				continue;
			float weight = 1.0f - dist_sq / r_sq;
			h[(size_t)ny * w + nx] += amount * weight;
		}
	}
}

PackedFloat32Array PCGErode::erode(const PackedFloat32Array &heights, int p_width, int p_height,
		int droplets, float inertia, float power, int radius,
		float min_slope, float evaporate, int seed,
		float cliff_drop, float deposition_rate) {
	PackedFloat32Array result;
	if (p_width <= 0 || p_height <= 0 || heights.size() < (int64_t)p_width * p_height)
		return result;
	result.resize(p_width * p_height);
	std::vector<float> h;
	h.reserve((size_t)p_width * p_height);
	for (int64_t i = 0; i < (int64_t)p_width * p_height; ++i)
		h.push_back(heights[i]);

	if (droplets > 0 && radius > 0) {
		std::mt19937_64 rng((uint64_t)seed);
		std::uniform_real_distribution<float> unit(0.0f, 1.0f);
		int w = p_width;
		int hgt = p_height;
		int r = radius;
		// 预分配随机数用于起点/扰动
		for (int d = 0; d < droplets; ++d) {
			int x = r + (int)(unit(rng) * (w - 1 - 2 * r + 1));
			int y = r + (int)(unit(rng) * (hgt - 1 - 2 * r + 1));
			float dir_x = 0.0f, dir_y = 0.0f;
			float speed = 1.0f;
			float water = 1.0f;
			float sediment = 0.0f;
			for (int step = 0; step < 30; ++step) {
				float cx = std::max(0.0f, std::min((float)(w - 1), (float)x));
				float cy = std::max(0.0f, std::min((float)(hgt - 1), (float)y));
				float h_cur = bilerp(h, w, hgt, cx, cy);
				// 最陡下降方向
				float lowest = h_cur, ld_x = 0.0f, ld_y = 0.0f;
				for (int iy = -1; iy <= 1; ++iy) {
					for (int ix = -1; ix <= 1; ++ix) {
						if (ix == 0 && iy == 0)
							continue;
						float nx = std::max(0.0f, std::min((float)(w - 1), cx + ix));
						float ny = std::max(0.0f, std::min((float)(hgt - 1), cy + iy));
						float nh = bilerp(h, w, hgt, nx, ny);
						if (nh < lowest) {
							lowest = nh;
							ld_x = (float)ix;
							ld_y = (float)iy;
						}
					}
				}
				float gradient = h_cur - lowest;
				// 悬崖保护: 单步落差超过 cliff_drop → 视为悬崖, 该液滴停止侵蚀(保留陡坡)
				if (cliff_drop > 0.0f && gradient > cliff_drop)
					break;
				// 惯性混合梯度方向
				dir_x = dir_x * inertia - ld_x * (1.0f - inertia);
				dir_y = dir_y * inertia - ld_y * (1.0f - inertia);
				float len = std::sqrt(dir_x * dir_x + dir_y * dir_y);
				if (len < 1e-4f)
					len = 1e-4f;
				dir_x /= len;
				dir_y /= len;
				x += (int)std::round(dir_x);
				y += (int)std::round(dir_y);
				if (x < 0 || x >= w || y < 0 || y >= hgt)
					break;
				if (gradient < min_slope)
					break;
				float carry = std::max(0.0f, gradient * speed * water * power);
				float deposit = (sediment - carry) * deposition_rate;
				apply_erosion(h, w, hgt, cx, cy, deposit, r);
				sediment = std::max(0.0f, carry);
				water *= (1.0f - evaporate);
				speed = std::max(0.0f, speed - 0.05f);
			}
			if (sediment > 0.0f) {
				int ex = std::max(0, std::min(w - 1, x));
				int ey = std::max(0, std::min(hgt - 1, y));
				apply_erosion(h, w, hgt, (float)ex, (float)ey, sediment * deposition_rate, r);
			}
		}
	}
	for (int64_t i = 0; i < (int64_t)p_width * p_height; ++i)
		result[i] = std::max(0.0f, std::min(1.0f, h[i]));
	return result;
}

// 热侵蚀(thermal erosion): 每迭代对每格检查 4 邻域, 高差 > talus 时
// 把超出部分的一半从高格搬到低格, 反复松弛到休止角(talus)。
// 为避免同迭代双向互搬震荡, 只处理(+x,+y)两个方向的邻居(每对相邻格单次处理)。
// 无粒子、O(iterations * w * h)、稳定, 适合平滑坡面/自然山脊。
PackedFloat32Array PCGErode::thermal(const PackedFloat32Array &heights, int p_width, int p_height,
		int iterations, float talus) {
	PackedFloat32Array result;
	if (p_width <= 0 || p_height <= 0 || heights.size() < (int64_t)p_width * p_height)
		return result;
	result.resize(p_width * p_height);
	std::vector<float> h((size_t)p_width * p_height);
	for (int64_t i = 0; i < (int64_t)p_width * p_height; ++i)
		h[i] = heights[i];
	if (talus <= 0.0f)
		talus = 0.05f;
	if (iterations <= 0)
		iterations = 20;
	// 只处理 +x(1,0) 和 +y(0,1) 两个方向: 每对相邻格每次迭代恰好处理一次, 无震荡
	const int DX[2] = {1, 0};
	const int DY[2] = {0, 1};
	for (int it = 0; it < iterations; ++it) {
		std::vector<float> next = h;
		for (int y = 0; y < p_height; ++y) {
			for (int x = 0; x < p_width; ++x) {
				float cur = h[(size_t)y * p_width + x];
				for (int d = 0; d < 2; ++d) {
					int nx = x + DX[d];
					int ny = y + DY[d];
					if (nx >= p_width || ny >= p_height)
						continue;
					int ni = ny * p_width + nx;
					float nh = h[ni];
					float diff = cur - nh;
					if (diff > talus) {
						float transfer = (diff - talus) * 0.5f;
						next[(size_t)y * p_width + x] -= transfer;
						next[ni] += transfer;
					} else if (nh - cur > talus) {
						float transfer = (nh - cur - talus) * 0.5f;
						next[(size_t)y * p_width + x] += transfer;
						next[ni] -= transfer;
					}
				}
			}
		}
		h = std::move(next);
	}
	for (int64_t i = 0; i < (int64_t)p_width * p_height; ++i)
		result[i] = std::max(0.0f, std::min(1.0f, h[i]));
	return result;
}
