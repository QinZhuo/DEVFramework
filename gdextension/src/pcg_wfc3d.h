#ifndef DECS_PCG_WFC3D_H
#define DECS_PCG_WFC3D_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <atomic>
#include <random>
#include <vector>
#include <cstdint>

namespace godot {

// ---------------------------------------------------------------------------
// PCGWFC3D — 3D 波函数坍缩（C++, 六面 socket 体素加速）。
//
// 与 GDScript 版 PCGTool._gen3d_wfc 同算法(bitmask 波函数 + 最低熵观测 +
// 6 邻域约束传播 + 回溯/重试), C++ 位运算 + 预计算相容表。
//
// 接口(供 FrameworkNative.get_native(&"PCGWFC3D") 访问):
//   generate(w, h, d, sockets, weights, backtracks, retries, max_propagations,
//            fixed_idx, fixed_tile, seed) -> PackedInt32Array
//     sockets:    PackedInt32Array, 6 个一组 [east,west,up,down,south,north], 每瓦片一组
//     weights:    PackedFloat32Array, 每瓦片一个
//     fixed_idx:  PackedInt32Array, 固定格线性索引(可空)
//     fixed_tile: PackedInt32Array, 与 fixed_idx 一一对应的瓦片索引
//     returns     成功: 长度 w*h*d 的格值数组; 失败: 空数组(调用方降级)
// 纯函数式, 线程安全。
// ---------------------------------------------------------------------------
class PCGWFC3D : public RefCounted {
	GDCLASS(PCGWFC3D, RefCounted)

protected:
	static void _bind_methods();

public:
	PackedInt32Array generate(int p_width, int p_height, int p_depth,
			const PackedInt32Array &sockets, const PackedFloat32Array &weights,
			int backtracks, int retries, int max_propagations,
			const PackedInt32Array &fixed_idx, const PackedInt32Array &fixed_tile,
			int seed);
	double get_last_progress() const;

private:
	static std::atomic<double> _last_progress;
};

} // namespace godot

#endif // DECS_PCG_WFC3D_H
