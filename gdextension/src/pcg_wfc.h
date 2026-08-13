#ifndef DECS_PCG_WFC_H
#define DECS_PCG_WFC_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <random>
#include <vector>
#include <cstdint>

namespace godot {

// ---------------------------------------------------------------------------
// PCGWFC — 2D 波函数坍缩（C++, 大图加速）。
//
// 与 GDScript 版 PCGTool._gen_wfc 同算法(bitmask 波函数 + 最低熵观测 +
// 邻域约束传播 + 回溯/重试), C++ 位运算 + 预计算相容表, 大图快 10-50 倍。
//
// 接口(供 FrameworkNative.get_native(&"PCGWFC") 访问):
//   generate(w, h, sockets, weights, backtracks, retries, max_propagations,
//            fixed_idx, fixed_tile, seed) -> PackedInt32Array
//     sockets:    PackedInt32Array, 4 个一组 [up,right,down,left], 每瓦片一组
//     weights:    PackedFloat32Array, 每瓦片一个
//     fixed_idx:  PackedInt32Array, 固定格线性索引(可空)
//     fixed_tile: PackedInt32Array, 与 fixed_idx 一一对应的瓦片索引
//     returns     成功: 长度 w*h 的格值数组; 失败: 空数组(调用方降级)
// 纯函数式: 每次调用独立, 线程安全。
// ---------------------------------------------------------------------------
class PCGWFC : public RefCounted {
	GDCLASS(PCGWFC, RefCounted)

protected:
	static void _bind_methods();

public:
	PackedInt32Array generate(int p_width, int p_height,
			const PackedInt32Array &sockets, const PackedFloat32Array &weights,
			int backtracks, int retries, int max_propagations,
			const PackedInt32Array &fixed_idx, const PackedInt32Array &fixed_tile,
			int seed);
};

} // namespace godot

#endif // DECS_PCG_WFC_H
