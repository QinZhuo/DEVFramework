#ifndef DECS_ECS_CORE_H
#define DECS_ECS_CORE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_vector4_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector4.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <cstdint>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

namespace godot {

// ---------------------------------------------------------------------------
// 稀疏集: 实体 <-> dense 行号 双向映射 (EnTT 风格)
//   dense[row]  = entity    拥有该组件的实体, 行号连续
//   sparse[e]   = row       O(1) 判断实体是否拥有该组件
// ---------------------------------------------------------------------------
struct ECSSparseSet {
	std::vector<int32_t> dense;
	std::vector<int32_t> sparse; // 实体 -> 行号, -1 = 无

	int32_t add(int32_t entity);
	void remove(int32_t entity);
	bool has(int32_t entity) const { return int32_t(entity) < int32_t(sparse.size()) && sparse[entity] >= 0; }
	int32_t row_of(int32_t entity) const {
		return (int32_t(entity) < int32_t(sparse.size()) && sparse[entity] >= 0) ? sparse[entity] : -1;
	}
	inline size_t size() const { return dense.size(); }
};

// ---------------------------------------------------------------------------
// SoA 列存储: 每组件每字段一块连续内存。
// 用 Godot Packed*Array 直接存储:
//   - get_column 返回内部引用 (Variant 包装, 共享底层内存, 零拷贝)
//   - set_column 引用赋值 (指针交换, 无逐元素拷贝)
// 列下标 = dense 行号 (0..拥有该组件的实体数-1, 紧凑连续, 缓存友好)。
// 实体 ID 需经 sparse[entity] 映射为行号 (O(1)), 由 ECSCore 内部处理。
// ---------------------------------------------------------------------------
struct ECSColumn {
	Variant::Type type = Variant::NIL;
	PackedInt32Array i32;    // INT
	PackedFloat32Array f32;  // FLOAT
	PackedByteArray b;       // BOOL
	PackedVector2Array v2;   // VECTOR2
	PackedVector3Array v3;   // VECTOR3
	PackedVector4Array v4;   // VECTOR4
	PackedColorArray col;    // COLOR
	PackedStringArray s;     // STRING

	void resize(size_t n);
	void push_default(const Variant &value);
	void pop();                 // 移除末尾行(swap-remove 时同步)
	Variant get(size_t row) const;
	void set(size_t row, const Variant &value);
	size_t size() const;
};

struct ECSField {
	StringName name;
	Variant::Type type;
};

struct ECSComponentData {
	StringName name;
	std::vector<ECSField> fields;
	std::vector<ECSColumn> columns;
	std::vector<Variant> defaults; // 每字段默认值, add_component 时填充新行
	ECSSparseSet set;

	int field_index(const StringName &f) const;
	inline ECSColumn &column(int fi) { return columns[fi]; }
	inline const ECSColumn &column(int fi) const { return columns[fi]; }
	// 给实体追加一行(列按 dense 行号紧凑存储, 行号 = dense 下标)
	inline void push_row(int32_t entity) {
		const int32_t row = set.add(entity);
		for (size_t fi = 0; fi < columns.size(); ++fi) {
			columns[fi].push_default(defaults[fi]);
		}
		(void)row; // 行号恒为 old size, 列 push 已对齐
	}
	// 移除实体所在行(swap-remove: 末行补位, 列同步)
	void remove_row(int32_t entity);
	// 行号 -> 实体 (dense[row])
	inline int32_t entity_at(int32_t row) const {
		return (row >= 0 && row < int32_t(set.dense.size())) ? set.dense[row] : -1;
	}
};

// ---------------------------------------------------------------------------
// 组件签名 (有序组件索引列表) -> 聚簇组
// 用于: 同签名实体 ID 连续分配, 遍历时缓存友好
// ---------------------------------------------------------------------------
struct ECSSignature {
	std::vector<int32_t> comps; // 升序组件索引
	// 聚簇 ID 池: 本签名实体复用的 ID(保证同签名实体 ID 数值接近)
	std::vector<int32_t> free_ids;
	int32_t next_hint = 0; // 分配游标
};

// ---------------------------------------------------------------------------
// ECSCore — 唯一对外原生类 (GDScript 侧经 ECSNative 桥接访问)
// ---------------------------------------------------------------------------
class ECSCore : public RefCounted {
	GDCLASS(ECSCore, RefCounted)

protected:
	static void _bind_methods();

public:
	// ---- 组件注册 ----
	// name: 组件类名; fnames: 字段名; ftypes: 字段 Variant::Type; fdefaults: 默认值
	int32_t register_component(const StringName &name, const PackedStringArray &fnames,
			const PackedInt32Array &ftypes, const Array &fdefaults);

	// ---- 实体 ----
	int32_t create_entity();
	bool is_alive(int32_t entity) const;
	void destroy_entity(int32_t entity);

	// ---- 组件增删查 ----
	bool add_component(int32_t entity, const StringName &comp);
	bool has_component(int32_t entity, const StringName &comp) const;
	void remove_component(int32_t entity, const StringName &comp);
	int32_t count_entities(const StringName &comp) const;

	// ---- 查询 ----
	// 返回匹配实体的实体 ID 列表(可直接索引任意组件列)。
	PackedInt32Array query_rows(const StringName &anchor, const PackedStringArray &must,
			const PackedStringArray &without) const;
	// 对齐行号查询: 一次返回多组件的对齐 dense 行号数组。
	// 返回 Array: [0] = anchor 组件的 dense 行号, [1..] = 对应 must[i] 的组件行号。
	// 第 k 个匹配实体在 anchor 的第 rows[0][k] 行、在 must[i] 的第 rows[1+i][k] 行,
	// 可直接用同一索引 k 并行索引各组件列(免去逐实体跨组件行号转换)。
	Array query_rows_aligned(const StringName &anchor, const PackedStringArray &must,
			const PackedStringArray &without) const;
	int32_t entity_of_row(const StringName &comp, int32_t row) const;

	// ---- 单实体字段访问 (低频路径) ----
	Variant get_field(int32_t entity, const StringName &comp, const StringName &field) const;
	void set_field(int32_t entity, const StringName &comp, const StringName &field, const Variant &value);

	// ---- 批量列访问 (零拷贝: 返回内部 Packed*Array 引用) ----
	Variant get_column(const StringName &comp, const StringName &field) const;
	void set_column(const StringName &comp, const StringName &field, const Variant &values);

	// ---- Tier 0: 原生批量运算 (纯 C++ 循环, 无 GDScript 解释开销) ----
	enum BatchOp { BATCH_ADD = 0, BATCH_MUL_ADD = 1, BATCH_SET = 2, BATCH_CLAMP = 3 };
	// 条件比较符
	enum CondOp { COND_LT = 0, COND_LE = 1, COND_GT = 2, COND_GE = 3, COND_EQ = 4, COND_NE = 5 };
	// batch_apply 带条件版本: conditions 为 Array[Dictionary], 每项 {comp, field, op, value}
	// 仅对满足全部条件的实体执行 op。返回处理的实体数。
	int64_t batch_apply_where(const StringName &anchor, const PackedStringArray &must,
			const StringName &op_comp, const StringName &op_field, int64_t op,
			double factor, double addend, const Array &conditions);
	// 统计满足条件的实体数(纯查询, 不修改)
	int64_t batch_count(const StringName &anchor, const PackedStringArray &must,
			const Array &conditions) const;
	int64_t batch_apply(const StringName &anchor, const PackedStringArray &must,
			const StringName &op_comp, const StringName &op_field, int64_t op,
			double factor, double addend);
	int64_t batch_clamp(const StringName &anchor, const PackedStringArray &must,
			const StringName &op_comp, const StringName &op_field,
			const StringName &min_comp, const StringName &min_field,
			const StringName &max_comp, const StringName &max_field);
	int64_t batch_vec_add(const StringName &anchor, const PackedStringArray &must,
			const StringName &pos_comp, const StringName &pos_field,
			const StringName &vel_comp, const StringName &vel_field, double delta);

	// 内存统计(调试)
	Dictionary debug_stats() const;

	// ---- 序列化/反序列化 (对接 SaveTool 存档) ----
	// 序列化整个世界: 返回 {components: [{name, fields:[{name,type}], defaults:[...],
	//   entities: [{entity, values:[...]}]}], pool_size}
	// 字段值按注册顺序排列; 无组件实体不参与(仅组件数据)。
	Dictionary serialize() const;
	// 反序列化: 重建组件注册 + 实体 + 数据。
	// 返回 Array[int]: 新建实体的真实实体 ID 列表(调用方用它绑定 EntityView 等)。
	// 注意: 需先 register_component 同名的组件(名称一致), 否则忽略该组件数据。
	Array deserialize(const Dictionary &data);

	// ---- Prefab 预制体 (模板实体 + 批量实例化) ----
	// 创建 prefab 模板实体(普通实体 + 内部模板标记, 不参与普通查询/序列化)
	int32_t create_prefab();
	// 该实体是否为 prefab 模板
	bool is_prefab(int32_t entity) const;
	// 给 prefab 模板添加组件并设置初始字段值。
	// values: Dictionary {field_name: value}
	bool prefab_add(int32_t prefab, const StringName &comp, const Dictionary &values);
	// 批量实例化: 复制 prefab 的组件结构与字段值到 count 个新实体。
	// overrides: Dictionary {comp_name: {field_name: value}} 字段覆盖(可选)
	// 返回新实体 ID 数组。
	Array instantiate(int32_t prefab, int32_t count, const Dictionary &overrides);
	// 便捷: 直接从 prefab 实体取组件字段值(供校验/调试)
	Variant prefab_get_field(int32_t prefab, const StringName &comp, const StringName &field) const;

	// 供条件过滤解析内部使用
	const ECSComponentData *find_comp(const StringName &name) const;

	// ---- Command Buffer 延迟结构变更 ----
	// 系统内排队 create/destroy/add/remove, flush_commands() 时统一执行。
	// 好处: 系统遍历中不直接改结构(无重入/迭代失效), 为系统并行执行铺路。
	enum CmdType { CMD_CREATE = 0, CMD_DESTROY = 1, CMD_ADD_COMP = 2, CMD_REMOVE_COMP = 3 };
	void cmd_create();                             // 排队创建(返回实体在 flush 时生成, 这里返回占位 -2)
	void cmd_destroy(int32_t entity);
	void cmd_add_component(int32_t entity, const StringName &comp);
	void cmd_remove_component(int32_t entity, const StringName &comp);
	void flush_commands();                        // 执行全部排队命令(帧末调用)
	int32_t pending_command_count() const;
	int32_t created_entity_at(int32_t index) const; // 查询第 index 个 create 生成的实体

	// 行号 -> 实体 / 实体 -> 行号 (dense 紧凑存储的转换)
	int32_t row_of_entity(const StringName &comp, int32_t entity) const;

private:
	// ---- 内部 ----
	ECSComponentData *find_comp(const StringName &name);
	int32_t comp_index(const StringName &name) const;
	inline bool is_prefab_index(int32_t index) const;

	// 签名聚簇: 实体 ID 分配
	int32_t sig_index_for(const std::vector<int32_t> &comps);
	int32_t allocate_entity_id();
	void release_entity_id(int32_t index);

	// ---- 存储 ----
	std::vector<ECSComponentData> components_;
	std::vector<ECSSignature> signatures_;
	// 实体池: index | (version << 24), 复用防悬垂
	std::vector<uint32_t> versions_;
	std::vector<int32_t> free_list_;
	// prefab 模板实体 index 集合
	std::vector<int32_t> prefab_indices_;

	// ---- 并行线程池 (batch 分片并行) ----
	mutable std::vector<std::thread> workers_;
	mutable std::mutex task_mutex_;
	mutable std::condition_variable task_cv_;
	mutable std::vector<std::function<void()>> tasks_;
	mutable bool workers_stop_ = false;
	mutable int active_tasks_ = 0;
	mutable bool workers_started_ = false;
	int thread_count_ = 0;

	// ---- Command Buffer 队列 ----
	std::vector<int32_t> cmd_types_;         // CmdType
	std::vector<int32_t> cmd_entities_;      // 实体ID(占位或真实)
	std::vector<StringName> cmd_comps_;      // 组件名(add/remove 用)
	std::vector<int32_t> cmd_created_;       // flush 时生成的新实体 ID

	void ensure_workers();
	void stop_workers();
	// 设置线程数(0=自动按硬件, 1=单线程/串行, 用于调试对比)
	void set_thread_count(int count);
	// 并行执行: 把 [0, n) 切成 slices 片, 每片一个线程执行 fn(work_begin, work_end)
	template <typename F>
	void parallel_for(size_t n, F &&fn);

public:
	~ECSCore();
};

} // namespace godot

#endif // DECS_ECS_CORE_H
