#ifndef DECS_PCG_WFC_H
#define DECS_PCG_WFC_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <atomic>
#include <random>
#include <vector>
#include <cstdint>

namespace godot {

// ---------------------------------------------------------------------------
// PCGWFC 鈥?2D 娉㈠嚱鏁板潔缂╋紙C++, 澶у浘鍔犻€燂級銆?//
// 涓?GDScript 鐗?PCGTool._gen_wfc 鍚岀畻娉?bitmask 娉㈠嚱鏁?+ 鏈€浣庣喌瑙傛祴 +
// 閭诲煙绾︽潫浼犳挱 + 鍥炴函/閲嶈瘯), C++ 浣嶈繍绠?+ 棰勮绠楃浉瀹硅〃, 澶у浘蹇?10-50 鍊嶃€?//
// 鎺ュ彛(渚?FrameworkNative.get_native(&"PCGWFC") 璁块棶):
//   generate(w, h, sockets, weights, backtracks, retries, max_propagations,
//            fixed_idx, fixed_tile, seed, progress_dict = {}) -> PackedInt32Array
//     sockets:    PackedInt32Array, 4 涓竴缁?[up,right,down,left], 姣忕摝鐗囦竴缁?//     weights:    PackedFloat32Array, 姣忕摝鐗囦竴涓?//     fixed_idx:  PackedInt32Array, 鍥哄畾鏍肩嚎鎬х储寮?鍙┖)
//     fixed_tile: PackedInt32Array, 涓?fixed_idx 涓€涓€瀵瑰簲鐨勭摝鐗囩储寮?//     progress_dict: 鍙€? worker 绾跨▼姣忚疆 retry 鍐?{"p": 0.0..1.0},
//                    涓荤嚎绋嬭疆璇㈣瀛楀吀鎷胯繘搴?璺ㄧ嚎绋嬬畝鍗?float 璧嬪€煎畨鍏?銆?//     returns     鎴愬姛: 闀垮害 w*h 鐨勬牸鍊兼暟缁? 澶辫触: 绌烘暟缁?璋冪敤鏂归檷绾?
// 绾嚱鏁板紡: 姣忔璋冪敤鐙珛, 绾跨▼瀹夊叏銆?// ---------------------------------------------------------------------------
class PCGWFC : public RefCounted {
	GDCLASS(PCGWFC, RefCounted)

protected:
	static void _bind_methods();

public:
	PackedInt32Array generate(int p_width, int p_height,
			const PackedInt32Array &sockets, const PackedFloat32Array &weights,
			int backtracks, int retries, int max_propagations,
			const PackedInt32Array &fixed_idx, const PackedInt32Array &fixed_tile,
			int seed, const Variant &progress_dict = Variant());
	double get_last_progress() const;

private:
	static std::atomic<double> _last_progress;
};

} // namespace godot

#endif // DECS_PCG_WFC_H
