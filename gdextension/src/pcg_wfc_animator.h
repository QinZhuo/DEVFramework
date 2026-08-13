#ifndef DECS_PCG_WFC_ANIMATOR_H
#define DECS_PCG_WFC_ANIMATOR_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <random>
#include <vector>
#include <cstdint>

namespace godot {

// ---------------------------------------------------------------------------
// PCGWFCAnimator — WFC 过程动画器（C++, 有状态逐步推进）。
//
// 与 GDScript 版 WFCAnimator 同算法(bitmask 波函数 + 最低熵观测 + 邻域约束传播
// + 回溯), C++ 位运算 + 预计算相容表。持有 wave 状态, 每步推进一个观测+传播,
// 供逐帧可视化生成过程。
//
// 接口(供 FrameworkNative.get_native(&"PCGWFCAnimator") 访问, 实例有状态):
//   setup(width, height, sockets, weights, backtracks, max_propagations,
//         fixed_idx, fixed_tile, seed) -> void
//   step() -> bool          推进一个观测+传播, 完成(或矛盾)返回 true
//   get_wave() -> PackedInt32Array   当前波函数 bitmask(渲染用)
//   is_failed() -> bool     是否矛盾失败
//   step_count() -> int     已推进步数
// ---------------------------------------------------------------------------
class PCGWFCAnimator : public RefCounted {
	GDCLASS(PCGWFCAnimator, RefCounted)

protected:
	static void _bind_methods();

public:
	void setup(int p_width, int p_height,
			const PackedInt32Array &sockets, const PackedFloat32Array &weights,
			int backtracks, int max_propagations,
			const PackedInt32Array &fixed_idx, const PackedInt32Array &fixed_tile,
			int seed);
	bool step();
	PackedInt32Array get_wave() const;
	bool is_failed() const;
	int step_count() const;

private:
	int _pick_lowest_entropy();
	void _propagate();
	void _reset(int all_mask);

	int _width = 0;
	int _height = 0;
	int _n = 0;
	int _cell_count = 0;
	int _all_mask = 0;
	int _backtracks = 0;
	int _max_propagations = 0;
	int _backtracks_used = 0;
	int _propagations = 0;
	int _step_count = 0;
	bool _done = false;
	bool _failed = false;
	std::vector<uint32_t> _wave;
	std::vector<int> _queue;
	std::vector<char> _in_queue;
	std::vector<std::vector<std::vector<bool>>> _compat_by_dir;
	std::vector<double> _cum_weight; // 加权累计
	std::mt19937_64 _rng;
	struct Hist { std::vector<uint32_t> wave; int cell; uint32_t bad; };
	std::vector<Hist> _history;
};

} // namespace godot

#endif // DECS_PCG_WFC_ANIMATOR_H
