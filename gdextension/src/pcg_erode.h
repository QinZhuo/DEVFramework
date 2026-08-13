#ifndef DECS_PCG_ERODE_H
#define DECS_PCG_ERODE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <random>
#include <vector>

namespace godot {

// ---------------------------------------------------------------------------
// PCGErode — PCG 高度图水力侵蚀 (C++, Sebastian Lague 粒子液滴风格)。
//
// 与 GDScript 版 PCGTool._erode_heightmap 同算法, C++ 实现快约 50-100 倍,
// 支持海量液滴(数十万)而不卡主线程。
//
// 接口(供 FrameworkNative.get_native(&"PCGErode") 访问):
//   erode(heights: PackedFloat32Array, width: int, height: int,
//         droplets: int, inertia: float, power: float, radius: int,
//         min_slope: float, evaporate: float, seed: int,
//         cliff_drop: float = 0.0, deposition_rate: float = 1.0) -> PackedFloat32Array
//   returns 侵蚀后的高度数组(长度 = width*height, 值 clamp 到 0..1)。
// 纯函数式: 不持有状态, 每次调用独立计算(线程安全, 可后台线程跑)。
// 新增参数:
//   cliff_drop:      悬崖落差阈值(高度单位)。液滴单步下降超过此值 → 视为悬崖,
//                    该液滴停止侵蚀(保留悬崖/陡坡不被磨平)。0 = 关闭。
//   deposition_rate: 沉积率(0..1)。控制泥沙沉积强度, 越低越保留下坡处的陡坡。
// ---------------------------------------------------------------------------
class PCGErode : public RefCounted {
	GDCLASS(PCGErode, RefCounted)

private:
	static void _declare() {}

protected:
	static void _bind_methods();

public:
	PackedFloat32Array erode(const PackedFloat32Array &heights, int p_width, int p_height,
			int droplets, float inertia, float power, int radius,
			float min_slope, float evaporate, int seed,
			float cliff_drop, float deposition_rate);

	// 热侵蚀(thermal erosion): 逐迭代把超休止角的高度差从高格搬运到低格,
	// 直到相邻高差 <= talus。产生平滑坡面与自然山脊, 无粒子、O(n) 稳定。
	// thermal(heights, width, height, iterations, talus) -> PackedFloat32Array
	PackedFloat32Array thermal(const PackedFloat32Array &heights, int p_width, int p_height,
			int iterations, float talus);
};

} // namespace godot

#endif // DECS_PCG_ERODE_H
