#ifndef DECS_PCG_CAVE3D_H
#define DECS_PCG_CAVE3D_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <random>
#include <vector>
#include <cstdint>

namespace godot {

// ---------------------------------------------------------------------------
// PCGCave3D — 3D 细胞自动机洞穴（C++ 加速）。
//
// 与 GDScript 版 PCGTool._gen3d_cave 同算法: 初始随机填充 + N 轮 26 邻域平滑
// (墙壁数 >= 13 → 墙)。纯数据生成(体素栅格), C++ 逐格裸内存, 快数十倍。
//
// 接口(供 FrameworkNative.get_native(&"PCGCave3D") 访问):
//   generate(w, h, d, seed, cave_ratio, smooth_passes, border_solid,
//            solid_value, empty_value) -> PackedInt32Array
//     returns 长度 w*h*d 的体素值数组(值 = solid/empty)
// 纯函数式, 线程安全。
// ---------------------------------------------------------------------------
class PCGCave3D : public RefCounted {
	GDCLASS(PCGCave3D, RefCounted)

protected:
	static void _bind_methods();

public:
	PackedInt32Array generate(int p_width, int p_height, int p_depth,
			int seed, float cave_ratio, int smooth_passes, bool border_solid,
			int solid_value, int empty_value);
};

} // namespace godot

#endif // DECS_PCG_CAVE3D_H
