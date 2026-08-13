#include "pcg_wfc_animator.h"

#include <godot_cpp/core/class_db.hpp>
#include <algorithm>
#include <cmath>

using namespace godot;

void PCGWFCAnimator::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "width", "height", "sockets", "weights",
			"backtracks", "max_propagations", "fixed_idx", "fixed_tile", "seed"),
			&PCGWFCAnimator::setup);
	ClassDB::bind_method(D_METHOD("step"), &PCGWFCAnimator::step);
	ClassDB::bind_method(D_METHOD("get_wave"), &PCGWFCAnimator::get_wave);
	ClassDB::bind_method(D_METHOD("is_failed"), &PCGWFCAnimator::is_failed);
	ClassDB::bind_method(D_METHOD("step_count"), &PCGWFCAnimator::step_count);
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

static inline bool compat2d(const PackedInt32Array &sockets, int n,
		int a, int b, int dir_idx) {
	int opp = (dir_idx + 2) & 3;
	return sockets[(size_t)a * 4 + dir_idx] == sockets[(size_t)b * 4 + opp];
}

void PCGWFCAnimator::setup(int p_width, int p_height,
		const PackedInt32Array &sockets, const PackedFloat32Array &weights,
		int backtracks, int max_propagations,
		const PackedInt32Array &fixed_idx, const PackedInt32Array &fixed_tile,
		int seed) {
	_width = p_width;
	_height = p_height;
	_n = (int)(sockets.size() / 4);
	_cell_count = _width * _height;
	_all_mask = (_n >= 30) ? 0 : ((1 << _n) - 1);
	_backtracks = backtracks;
	_max_propagations = max_propagations;
	_backtracks_used = 0;
	_propagations = 0;
	_step_count = 0;
	_done = false;
	_failed = false;
	_rng.seed((uint64_t)seed);
	if (_n <= 0 || _n >= 30 || _cell_count <= 0) {
		_done = true;
		return;
	}
	// 预计算 4 方向相容表
	_compat_by_dir.assign(4, std::vector<std::vector<bool>>((size_t)_n, std::vector<bool>((size_t)_n, false)));
	for (int d = 0; d < 4; ++d)
		for (int a = 0; a < _n; ++a)
			for (int b = 0; b < _n; ++b)
				_compat_by_dir[d][a][b] = compat2d(sockets, _n, a, b, d);
	// 权重累计
	_cum_weight.resize(_n);
	double acc = 0.0;
	for (int i = 0; i < _n; ++i) {
		acc += std::max(0.0, (double)weights[i]);
		_cum_weight[i] = acc;
	}
	if (acc <= 0.0)
		for (int i = 0; i < _n; ++i) _cum_weight[i] = (double)(i + 1);
	// 初始化 wave + 固定格
	_wave.assign((size_t)_cell_count, (uint32_t)_all_mask);
	_queue.clear();
	_in_queue.assign((size_t)_cell_count, 0);
	for (int k = 0; k < fixed_idx.size() && k < fixed_tile.size(); ++k) {
		int fi = (int)fixed_idx[k];
		int ft = (int)fixed_tile[k];
		if (fi >= 0 && fi < _cell_count && ft >= 0 && ft < _n) {
			_wave[fi] = (uint32_t)(1u << ft);
			_queue.push_back(fi);
			_in_queue[fi] = 1;
		}
	}
	_history.clear();
	_propagate();
}

void PCGWFCAnimator::_reset(int all_mask) {
	for (int i = 0; i < _cell_count; ++i) _wave[i] = (uint32_t)all_mask;
}

int PCGWFCAnimator::_pick_lowest_entropy() {
	int best = -1;
	int best_cnt = INT32_MAX;
	for (int i = 0; i < _cell_count; ++i) {
		uint32_t v = _wave[i];
		if (v == 0)
			continue;
		int cnt = popcount32(v);
		if (cnt > 1 && cnt < best_cnt) {
			best_cnt = cnt;
			best = i;
		}
	}
	return best;
}

void PCGWFCAnimator::_propagate() {
	const int DX[4] = {0, 1, 0, -1};
	const int DY[4] = {-1, 0, 1, 0};
	while (!_queue.empty()) {
		if (_max_propagations > 0 && _propagations >= _max_propagations)
			break;
		int cur = _queue.back();
		_queue.pop_back();
		_in_queue[cur] = 0;
		++_propagations;
		int cx = cur % _width;
		int cy = cur / _width;
		uint32_t cur_mask = _wave[cur];
		for (int dir = 0; dir < 4; ++dir) {
			int nx = cx + DX[dir];
			int ny = cy + DY[dir];
			if (nx < 0 || nx >= _width || ny < 0 || ny >= _height)
				continue;
			int ni = ny * _width + nx;
			uint32_t nm = _wave[ni];
			if (nm == 0)
				continue;
			uint32_t allowed = 0;
			uint32_t bit_b = 1;
			for (int b = 0; b < _n; ++b, bit_b <<= 1) {
				if (!(nm & bit_b))
					continue;
				bool ok = false;
				uint32_t bit_a = 1;
				for (int a = 0; a < _n && !ok; ++a, bit_a <<= 1) {
					if ((cur_mask & bit_a) && _compat_by_dir[dir][a][b])
						ok = true;
				}
				if (ok)
					allowed |= bit_b;
			}
			if (allowed == 0) {
				_wave[ni] = 0;
				if (!_in_queue[ni]) { _queue.push_back(ni); _in_queue[ni] = 1; }
				continue;
			}
			if ((nm & allowed) != nm) {
				_wave[ni] = nm & allowed;
				if (!_in_queue[ni]) { _queue.push_back(ni); _in_queue[ni] = 1; }
			}
		}
	}
}

bool PCGWFCAnimator::step() {
	if (_done || _failed || _n <= 0 || _cell_count <= 0)
		return true;
	int cell = _pick_lowest_entropy();
	if (cell == -1) {
		_done = true;
		for (uint32_t v : _wave)
			if (v == 0) { _failed = true; break; }
		return true;
	}
	uint32_t mask = _wave[cell];
	if (mask == 0) {
		// 矛盾 → 回溯
		if (_backtracks > 0 && _backtracks_used < _backtracks && !_history.empty()) {
			++_backtracks_used;
			Hist h = _history.back();
			_history.pop_back();
			_wave = h.wave;
			_wave[h.cell] &= ~h.bad;
			_queue.push_back(h.cell);
			_in_queue[h.cell] = 1;
			_propagate();
			++_step_count;
			return false;
		}
		_failed = true;
		_done = true;
		return true;
	}
	// 加权采样
	std::vector<int> opts;
	for (int i = 0; i < _n; ++i)
		if (mask & (1u << i))
			opts.push_back(i);
	double total = _cum_weight.empty() ? 0.0 : _cum_weight[_n - 1];
	double r = (double)_rng() / (double)UINT64_MAX * (total > 0.0 ? total : (double)opts.size());
	int chosen = -1;
	double acc = 0.0;
	for (int i : opts) {
		double w = _cum_weight.empty() ? 1.0 : (i > 0 ? _cum_weight[i] - _cum_weight[i - 1] : _cum_weight[0]);
		if (w < 0.0) w = 1.0;
		acc += w;
		if (r <= acc) { chosen = i; break; }
	}
	if (chosen == -1)
		chosen = opts.back();
	if (_backtracks > 0) {
		Hist h;
		h.wave = _wave;
		h.cell = cell;
		h.bad = (uint32_t)(1u << chosen);
		if (_history.size() < 65536)
			_history.push_back(std::move(h));
	}
	_wave[cell] = (uint32_t)(1u << chosen);
	_queue.push_back(cell);
	_in_queue[cell] = 1;
	_propagate();
	++_step_count;
	return false;
}

PackedInt32Array PCGWFCAnimator::get_wave() const {
	PackedInt32Array out;
	out.resize(_cell_count);
	for (int i = 0; i < _cell_count; ++i)
		out[i] = (int32_t)_wave[i];
	return out;
}

bool PCGWFCAnimator::is_failed() const {
	return _failed;
}

int PCGWFCAnimator::step_count() const {
	return _step_count;
}
