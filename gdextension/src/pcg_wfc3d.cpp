#include "pcg_wfc3d.h"

#include <godot_cpp/core/class_db.hpp>
#include <algorithm>
#include <cmath>

using namespace godot;

void PCGWFC3D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("generate", "width", "height", "depth", "sockets", "weights",
			"backtracks", "retries", "max_propagations", "fixed_idx", "fixed_tile", "seed"),
			&PCGWFC3D::generate);
	ClassDB::bind_method(D_METHOD("get_last_progress"), &PCGWFC3D::get_last_progress);
}

std::atomic<double> PCGWFC3D::_last_progress(0.0);

double PCGWFC3D::get_last_progress() const {
	return _last_progress.load(std::memory_order_relaxed);
}

static inline int popcount32(uint32_t v) {
#if defined(__GNUC__) || defined(__clang__)
	return __builtin_popcount(v);
#else
	int c = 0;
	while (v) { v &= v - 1; ++c; }
	return c;
#endif
}

// 3D socket 匹配: 方向 0=+x,1=-x,2=+y,3=-y,4=+z,5=-z, opp=[1,0,3,2,5,4]
static inline bool compatible3d(const PackedInt32Array &sockets, int n,
		int a, int b, int dir_idx) {
	static const int OPP[6] = {1, 0, 3, 2, 5, 4};
	int opp = OPP[dir_idx];
	return sockets[(size_t)a * 6 + dir_idx] == sockets[(size_t)b * 6 + opp];
}

PackedInt32Array PCGWFC3D::generate(int p_width, int p_height, int p_depth,
		const PackedInt32Array &sockets, const PackedFloat32Array &weights,
		int backtracks, int retries, int max_propagations,
		const PackedInt32Array &fixed_idx, const PackedInt32Array &fixed_tile,
		int seed) {
	PackedInt32Array result;
	int n = (int)(sockets.size() / 6);
	int cell_count = p_width * p_height * p_depth;
	if (p_width <= 0 || p_height <= 0 || p_depth <= 0 || n <= 0 || n >= 30 ||
			sockets.size() < (int64_t)n * 6 || weights.size() < n)
		return result;
	result.resize(cell_count);

	int all_mask = (1 << n) - 1;
	// 预计算 6 方向相容表
	std::vector<std::vector<std::vector<bool>>> compat_by_dir(6,
		std::vector<std::vector<bool>>((size_t)n, std::vector<bool>((size_t)n, false)));
	for (int d = 0; d < 6; ++d)
		for (int a = 0; a < n; ++a)
			for (int b = 0; b < n; ++b)
				compat_by_dir[d][a][b] = compatible3d(sockets, n, a, b, d);

	std::mt19937_64 rng((uint64_t)seed);
	std::vector<uint32_t> wave((size_t)cell_count, (uint32_t)all_mask);

	// 6 邻域方向
	const int DX[6] = {1, -1, 0, 0, 0, 0};
	const int DY[6] = {0, 0, 1, -1, 0, 0};
	const int DZ[6] = {0, 0, 0, 0, 1, -1};

	struct Hist { std::vector<uint32_t> wave; int cell; uint32_t bad; };
	std::vector<Hist> history;
	history.reserve(1024);

	for (int retry = 0; retry <= retries; ++retry) {
		// 进度: 每轮 retry 写 0..1 (主线程轮询静态量)
		_last_progress.store((retries <= 0) ? 1.0 : (double)(retry + 1) / (double)(retries + 1),
				std::memory_order_relaxed);
		for (int i = 0; i < cell_count; ++i) wave[i] = (uint32_t)all_mask;
		for (int k = 0; k < fixed_idx.size() && k < fixed_tile.size(); ++k) {
			int fi = (int)fixed_idx[k];
			int ft = (int)fixed_tile[k];
			if (fi >= 0 && fi < cell_count && ft >= 0 && ft < n)
				wave[fi] = (uint32_t)(1u << ft);
		}
		std::vector<int> queue;
		std::vector<char> in_queue((size_t)cell_count, 0);
		for (int k = 0; k < fixed_idx.size(); ++k) {
			int fi = (int)fixed_idx[k];
			if (fi >= 0 && fi < cell_count) { queue.push_back(fi); in_queue[fi] = 1; }
		}
		history.clear();
		int backtracks_used = 0;
		int propagations = 0;
		bool failed = false;

		auto propagate = [&](std::vector<int> &q) -> void {
			while (!q.empty()) {
				if (max_propagations > 0 && propagations >= max_propagations)
					break;
				int cur = q.back();
				q.pop_back();
				in_queue[cur] = 0;
				++propagations;
				int x = cur % p_width;
				int y = (cur / p_width) % p_height;
				int z = cur / (p_width * p_height);
				uint32_t cur_mask = wave[cur];
				for (int dir = 0; dir < 6; ++dir) {
					int nx = x + DX[dir];
					int ny = y + DY[dir];
					int nz = z + DZ[dir];
					if (nx < 0 || nx >= p_width || ny < 0 || ny >= p_height || nz < 0 || nz >= p_depth)
						continue;
					int ni = (nz * p_height + ny) * p_width + nx;
					uint32_t nm = wave[ni];
					if (nm == 0)
						continue;
					uint32_t allowed = 0;
					uint32_t bit_b = 1;
					for (int b = 0; b < n; ++b, bit_b <<= 1) {
						if (!(nm & bit_b))
							continue;
						bool ok = false;
						uint32_t bit_a = 1;
						for (int a = 0; a < n && !ok; ++a, bit_a <<= 1) {
							if ((cur_mask & bit_a) && compat_by_dir[dir][a][b])
								ok = true;
						}
						if (ok)
							allowed |= bit_b;
					}
					if (allowed == 0) {
						wave[ni] = 0;
						if (!in_queue[ni]) { queue.push_back(ni); in_queue[ni] = 1; }
						continue;
					}
					if ((nm & allowed) != nm) {
						wave[ni] = nm & allowed;
						if (!in_queue[ni]) { queue.push_back(ni); in_queue[ni] = 1; }
					}
				}
			}
		};

		propagate(queue);

		for (;;) {
			int best = -1;
			int best_cnt = INT32_MAX;
			for (int i = 0; i < cell_count; ++i) {
				uint32_t v = wave[i];
				if (v == 0)
					continue;
				int cnt = popcount32(v);
				if (cnt > 1 && cnt < best_cnt) {
					best_cnt = cnt;
					best = i;
				}
			}
			if (best == -1)
				break;
			uint32_t mask = wave[best];
			int chosen = -1;
			{
				std::vector<int> opts;
				for (int i = 0; i < n; ++i)
					if (mask & (1u << i))
						opts.push_back(i);
				if (opts.empty())
					goto contradiction;
				double total = 0.0;
				for (int i : opts)
					total += std::max(0.0, (double)weights[i]);
				double r = (double)rng() / (double)UINT64_MAX * (total > 0.0 ? total : (double)opts.size());
				double acc = 0.0;
				for (int i : opts) {
					acc += (total > 0.0 ? std::max(0.0, (double)weights[i]) : 1.0);
					if (r <= acc) { chosen = i; break; }
				}
				if (chosen == -1)
					chosen = opts.back();
			}
			{
				Hist h;
				h.wave = wave;
				h.cell = best;
				h.bad = (uint32_t)(1u << chosen);
				if (history.size() < 65536)
					history.push_back(std::move(h));
				wave[best] = (uint32_t)(1u << chosen);
				queue.push_back(best);
				in_queue[best] = 1;
				propagate(queue);
			}
			continue;
		contradiction:
			if (backtracks > 0 && backtracks_used < backtracks && !history.empty()) {
				++backtracks_used;
				Hist &h = history.back();
				wave = h.wave;
				wave[h.cell] &= ~h.bad;
				history.pop_back();
				queue.push_back(h.cell);
				in_queue[h.cell] = 1;
				propagate(queue);
			} else {
				failed = true;
				break;
			}
		}
		if (failed)
			continue;

		bool ok = true;
		for (int i = 0; i < cell_count; ++i)
			if (wave[i] == 0) { ok = false; break; }
		if (!ok)
			continue;
		for (int i = 0; i < cell_count; ++i) {
			uint32_t m = wave[i];
			if (m != 0 && (m & (m - 1)) == 0) {
				int idx = 0;
				uint32_t mm = m;
				while (mm > 1) { mm >>= 1; ++idx; }
				result[i] = idx;
			} else {
				result[i] = 1;
			}
		}
		return result;
	}
	return PackedInt32Array();
}
