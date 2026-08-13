#include "pcg_wfc.h"

#include <godot_cpp/core/class_db.hpp>
#include <algorithm>
#include <cmath>

using namespace godot;

void PCGWFC::_bind_methods() {
	ClassDB::bind_method(D_METHOD("generate", "width", "height", "sockets", "weights",
			"backtracks", "retries", "max_propagations", "fixed_idx", "fixed_tile", "seed",
			"progress_dict"),
			&PCGWFC::generate);
	ClassDB::bind_method(D_METHOD("get_last_progress"), &PCGWFC::get_last_progress);
}

std::atomic<double> PCGWFC::_last_progress(0.0);

double PCGWFC::get_last_progress() const {
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

// socket 匹配: cur 位于邻居的 dir_idx(0=up,1=right,2=down,3=left) 方向
// cur 的 dir 侧 vs 邻居的 opposite 侧
static inline bool compatible(const PackedInt32Array &sockets, int n,
		int a, int b, int dir_idx) {
	int opp = (dir_idx + 2) & 3;
	return sockets[(size_t)a * 4 + dir_idx] == sockets[(size_t)b * 4 + opp];
}

PackedInt32Array PCGWFC::generate(int p_width, int p_height,
		const PackedInt32Array &sockets, const PackedFloat32Array &weights,
		int backtracks, int retries, int max_propagations,
		const PackedInt32Array &fixed_idx, const PackedInt32Array &fixed_tile,
		int seed, const Variant &progress_dict) {
	PackedInt32Array result;
	int n = (int)(sockets.size() / 4);
	int cell_count = p_width * p_height;
	if (p_width <= 0 || p_height <= 0 || n <= 0 || n >= 30 ||
			sockets.size() < (int64_t)n * 4 || weights.size() < n)
		return result;
	result.resize(cell_count);

	int all_mask = (1 << n) - 1;
	// 预计算相容表: compat[a][b] 是否在任意方向相容(用于传播快速剪枝)
	// 实际传播仍逐方向精确判定, 但先构建 neighbors[a][dir] = 相容的 b 集合
	// 用 vector<bool> 存 per-dir 相容, 传播时取交集
	std::vector<std::vector<std::vector<bool>>> compat_by_dir;
	compat_by_dir.resize(4);
	for (int d = 0; d < 4; ++d) {
		compat_by_dir[d].assign((size_t)n, std::vector<bool>((size_t)n, false));
		for (int a = 0; a < n; ++a)
			for (int b = 0; b < n; ++b)
				compat_by_dir[d][a][b] = compatible(sockets, n, a, b, d);
	}

	std::mt19937_64 rng((uint64_t)seed);
	std::vector<uint32_t> wave((size_t)cell_count, (uint32_t)all_mask);
	// 权重累计(加权采样)
	std::vector<double> cum(n, 0.0);
	{
		double acc = 0.0;
		for (int i = 0; i < n; ++i) {
			acc += std::max(0.0, (double)weights[i]);
			cum[i] = acc;
		}
		if (acc <= 0.0)
			for (int i = 0; i < n; ++i) cum[i] = (double)(i + 1) / n;
	}

	const int DIR_X[4] = {0, 1, 0, -1};
	const int DIR_Y[4] = {-1, 0, 1, 0};

	// 回溯历史: 每格观测前的 wave 快照 + 该格 bad 位
	struct Hist { std::vector<uint32_t> wave; int cell; uint32_t bad; };
	std::vector<Hist> history;
	history.reserve(1024);

	// 应用固定格
	std::vector<uint32_t> wave_snapshot; // 用于回溯恢复
	for (int retry = 0; retry <= retries; ++retry) {
		// 进度: 每轮 retry 写 0..1 (主线程轮询共享 Dictionary 浅拷贝 / 静态量)
		double p = (retries <= 0) ? 1.0 : (double)(retry + 1) / (double)(retries + 1);
		_last_progress.store(p, std::memory_order_relaxed);
		if (progress_dict.get_type() == Variant::DICTIONARY) {
			Dictionary pd = progress_dict;
			pd["p"] = p;
		}
		// 重置 wave(固定格除外)
		for (int i = 0; i < cell_count; ++i) wave[i] = (uint32_t)all_mask;
		for (int k = 0; k < fixed_idx.size() && k < fixed_tile.size(); ++k) {
			int fi = (int)fixed_idx[k];
			int ft = (int)fixed_tile[k];
			if (fi >= 0 && fi < cell_count && ft >= 0 && ft < n)
				wave[fi] = (uint32_t)(1u << ft);
		}
		// 传播队列(BFS)
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
		long observed = 0;

		auto propagate = [&](std::vector<int> &q) -> void {
			while (!q.empty()) {
				if (max_propagations > 0 && propagations >= max_propagations)
					break;
				int cur = q.back();
				q.pop_back();
				in_queue[cur] = 0;
				++propagations;
				int cx = cur % p_width;
				int cy = cur / p_width;
				uint32_t cur_mask = wave[cur];
				for (int dir = 0; dir < 4; ++dir) {
					int nx = cx + DIR_X[dir];
					int ny = cy + DIR_Y[dir];
					if (nx < 0 || nx >= p_width || ny < 0 || ny >= p_height)
						continue;
					int ni = ny * p_width + nx;
					uint32_t nm = wave[ni];
					if (nm == 0)
						continue;
					// 对 ni 的每个候选 b, 检查 cur 的任一候选 a 在 dir 方向相容
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

		// 主循环: 最低熵观测
		for (;;) {
			// 找最低熵(候选数>1 且最小)
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
			// 加权采样一个候选
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
				double acc2 = 0.0;
				for (int i : opts) {
					acc2 += (total > 0.0 ? std::max(0.0, (double)weights[i]) : 1.0);
					if (r <= acc2) { chosen = i; break; }
				}
				if (chosen == -1)
					chosen = opts.back();
			}
			{
				// 保存回溯历史
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
				// 每 cell 粒度进度: 本轮已完成观测数 / 总格数, 叠加 retry 基础进度
				++observed;
				if ((observed & 0x3F) == 0) {  // 每 64 个 cell 写一次, 减少跨线程开销
					double base_p = (retries <= 0) ? 0.0 : (double)retry / (double)(retries + 1);
					double cell_p = (double)observed / (double)cell_count / (double)(retries + 1);
					_last_progress.store(base_p + cell_p, std::memory_order_relaxed);
					if (progress_dict.get_type() == Variant::DICTIONARY) {
						Dictionary pd = progress_dict;
						pd["p"] = base_p + cell_p;
					}
				}
			}
			continue;
		contradiction:
			// 矛盾: 回溯或失败
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
			continue; // 重试

		// 校验无矛盾格
		bool ok = true;
		for (int i = 0; i < cell_count; ++i)
			if (wave[i] == 0) { ok = false; break; }
		if (!ok)
			continue;
		// 写入结果
		for (int i = 0; i < cell_count; ++i) {
			uint32_t m = wave[i];
			if (m != 0 && (m & (m - 1)) == 0) {
				// 单候选
				int idx = 0;
				uint32_t mm = m;
				while (mm > 1) { mm >>= 1; ++idx; }
				result[i] = idx;
			} else {
				result[i] = 1; // solid_value 兜底(与 GDScript 一致)
			}
		}
		return result;
	}
	return PackedInt32Array(); // 重试耗尽 → 空, 调用方降级
}
