#include "ecs_core.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <emmintrin.h> // SSE2 (SIMD 加速 batch 运算)
#include <unordered_map>

using namespace godot;

// ---------------------------------------------------------------------------
// ECSCore 并行线程池 (batch 分片并行)
// ---------------------------------------------------------------------------

void ECSCore::ensure_workers() {
	if (workers_started_) {
		return;
	}
	if (thread_count_ <= 0) {
		unsigned hw = std::thread::hardware_concurrency();
		thread_count_ = std::clamp(int(hw > 1 ? hw - 1 : 1), 1, 8);
	}
	workers_started_ = true;
	for (int i = 0; i < thread_count_; ++i) {
		workers_.emplace_back([this]() {
			while (true) {
				std::function<void()> task;
				{
					std::unique_lock<std::mutex> lock(task_mutex_);
					task_cv_.wait(lock, [this]() { return workers_stop_ || !tasks_.empty(); });
					if (workers_stop_ && tasks_.empty()) {
						return;
					}
					task = std::move(tasks_.back());
					tasks_.pop_back();
				}
				task();
				{
					std::lock_guard<std::mutex> lock(task_mutex_);
					--active_tasks_;
				}
				task_cv_.notify_all();
			}
		});
	}
}

void ECSCore::stop_workers() {
	{
		std::lock_guard<std::mutex> lock(task_mutex_);
		workers_stop_ = true;
	}
	task_cv_.notify_all();
	for (auto &t : workers_) {
		if (t.joinable()) {
			t.join();
		}
	}
	workers_.clear();
	workers_started_ = false;
	workers_stop_ = false;
}

void ECSCore::set_thread_count(int count) {
	stop_workers();
	if (count <= 0) {
		unsigned hw = std::thread::hardware_concurrency();
		thread_count_ = std::clamp(int(hw > 1 ? hw - 1 : 1), 1, 8);
	} else {
		thread_count_ = std::clamp(count, 1, 8);
	}
	ensure_workers();
}

template <typename F>
void ECSCore::parallel_for(size_t n, F &&fn, double cost_per_item) {
	ensure_workers();  // 确保线程池启动 + thread_count_ 就绪
	// 按工作量估算是否值得并行(而非固定条数): 高成本项(向量/SIMD)更早并行
	if (double(n) * cost_per_item < 10000.0 || thread_count_ <= 1) {
		fn(0, n);
		return;
	}
	const size_t slices = size_t(thread_count_);
	const size_t chunk = (n + slices - 1) / slices;
	{
		std::lock_guard<std::mutex> lock(task_mutex_);
		for (size_t s = 0; s < slices; ++s) {
			const size_t begin = s * chunk;
			const size_t end = std::min(begin + chunk, n);
			if (begin >= end) {
				break;
			}
			++active_tasks_;
			tasks_.emplace_back([begin, end, &fn]() { fn(begin, end); });
		}
	}
	task_cv_.notify_all();
	{
		std::unique_lock<std::mutex> lock(task_mutex_);
		task_cv_.wait(lock, [this]() { return active_tasks_ <= 0; });
	}
}

ECSCore::~ECSCore() {
	stop_workers();
}

// 系统批并行执行: 复用持久 worker 池, 免每帧临时建线程。
// systems: Array[Callable](无参, 已 bind 系统+ctx+delta)。主线程执行第一个, 池执行其余。
void ECSCore::run_systems_parallel(const Array &systems) {
	ensure_workers();
	const int32_t n = int32_t(systems.size());
	if (n <= 0) {
		return;
	}
	// 发布 n-1 个任务给 worker(任务执行完即释放 Callable 引用, 无持久循环)
	{
		std::lock_guard<std::mutex> lock(task_mutex_);
		for (int32_t i = 1; i < n; ++i) {
			++active_tasks_;
			Variant sys = systems[i];
			tasks_.emplace_back([sys]() {
				Callable cb = sys;
				cb.call();
			});
		}
	}
	task_cv_.notify_all();
	// 主线程执行第一个系统
	{
		Callable cb0 = systems[0];
		cb0.call();
	}
	// 等待 worker 全部完成
	{
		std::unique_lock<std::mutex> lock(task_mutex_);
		task_cv_.wait(lock, [this]() { return active_tasks_ <= 0; });
	}
}

// ---------------------------------------------------------------------------
// ECSSparseSet
// ---------------------------------------------------------------------------

int32_t ECSSparseSet::add(int32_t entity) {
	const int32_t e = entity;
	if (int32_t(sparse.size()) <= e) {
		sparse.resize(e + 1, -1);
	}
	if (sparse[e] >= 0) {
		return sparse[e]; // 已存在
	}
	const int32_t row = int32_t(dense.size());
	sparse[e] = row;
	dense.push_back(e);
	return row;
}

void ECSSparseSet::remove(int32_t entity) {
	if (int32_t(sparse.size()) <= entity || sparse[entity] < 0) {
		return;
	}
	const int32_t row = sparse[entity];
	const int32_t last_entity = dense.back();
	dense[row] = last_entity;
	sparse[last_entity] = row;
	dense.pop_back();
	sparse[entity] = -1;
}

// ---------------------------------------------------------------------------
// ECSColumn — SoA 列存储 (Packed*Array, 零拷贝)
// ---------------------------------------------------------------------------

void ECSColumn::resize(size_t n) {
	switch (type) {
		case Variant::INT: i32.resize(int32_t(n)); break;
		case Variant::FLOAT: f32.resize(int32_t(n)); break;
		case Variant::BOOL: b.resize(int32_t(n)); break;
		case Variant::VECTOR2: v2.resize(int32_t(n)); break;
		case Variant::VECTOR3: v3.resize(int32_t(n)); break;
		case Variant::VECTOR4: v4.resize(int32_t(n)); break;
		case Variant::COLOR: col.resize(int32_t(n)); break;
		case Variant::STRING: s.resize(int32_t(n)); break;
		default: break;
	}
}

void ECSColumn::push_default(const Variant &value) {
	switch (type) {
		case Variant::INT: i32.push_back(int64_t(value)); break;
		case Variant::FLOAT: f32.push_back(double(value)); break;
		case Variant::BOOL: b.push_back(bool(value)); break;
		case Variant::VECTOR2: v2.push_back(Vector2(value)); break;
		case Variant::VECTOR3: v3.push_back(Vector3(value)); break;
		case Variant::VECTOR4: v4.push_back(Vector4(value)); break;
		case Variant::COLOR: col.push_back(Color(value)); break;
		case Variant::STRING: s.push_back(String(value)); break;
		default: break;
	}
}

void ECSColumn::pop() {
	switch (type) {
		case Variant::INT: i32.resize(i32.size() - 1); break;
		case Variant::FLOAT: f32.resize(f32.size() - 1); break;
		case Variant::BOOL: b.resize(b.size() - 1); break;
		case Variant::VECTOR2: v2.resize(v2.size() - 1); break;
		case Variant::VECTOR3: v3.resize(v3.size() - 1); break;
		case Variant::VECTOR4: v4.resize(v4.size() - 1); break;
		case Variant::COLOR: col.resize(col.size() - 1); break;
		case Variant::STRING: s.resize(s.size() - 1); break;
		default: break;
	}
}

// ---------------------------------------------------------------------------
// ECSComponentData — 行级操作 (列按 dense 行号紧凑存储)
// ---------------------------------------------------------------------------

// swap-remove 一行: 末行数据补到被删行, 列同步删除末行。
// 前提: entity 已拥有本组件 (sparse[entity] >= 0)。
void ECSComponentData::remove_row(int32_t entity) {
	const int32_t row = set.row_of(entity);
	if (row < 0) {
		return;
	}
	const int32_t last_row = int32_t(set.size()) - 1;
	// 稀疏集内部 swap: dense[row] = dense[last]; sparse[dense[last]] = row
	set.remove(entity);
	// 列同步: 若被删行不是末行, 用末行数据覆盖被删行, 再弹掉末行
	if (row != last_row) {
		for (size_t fi = 0; fi < columns.size(); ++fi) {
			ECSColumn &c = columns[fi];
			// 列按行号索引, 末行数据在 last_row 位置
			Variant v = c.get(last_row);
			c.set(row, v);
		}
	}
	for (size_t fi = 0; fi < columns.size(); ++fi) {
		columns[fi].pop();
	}
}

Variant ECSColumn::get(size_t row) const {
	switch (type) {
		case Variant::INT: return int64_t(i32[int32_t(row)]);
		case Variant::FLOAT: return double(f32[int32_t(row)]);
		case Variant::BOOL: return bool(b[int32_t(row)]);
		case Variant::VECTOR2: return v2[int32_t(row)];
		case Variant::VECTOR3: return v3[int32_t(row)];
		case Variant::VECTOR4: return v4[int32_t(row)];
		case Variant::COLOR: return col[int32_t(row)];
		case Variant::STRING: return s[int32_t(row)];
		default: return Variant();
	}
}

void ECSColumn::set(size_t row, const Variant &value) {
	const int32_t r = int32_t(row);
	switch (type) {
		case Variant::INT: i32[r] = int32_t(int64_t(value)); break;
		case Variant::FLOAT: f32[r] = float(double(value)); break;
		case Variant::BOOL: b[r] = uint8_t(bool(value)); break;
		case Variant::VECTOR2: v2[r] = Vector2(value); break;
		case Variant::VECTOR3: v3[r] = Vector3(value); break;
		case Variant::VECTOR4: v4[r] = Vector4(value); break;
		case Variant::COLOR: col[r] = Color(value); break;
		case Variant::STRING: s[r] = String(value); break;
		default: break;
	}
}

size_t ECSColumn::size() const {
	switch (type) {
		case Variant::INT: return size_t(i32.size());
		case Variant::FLOAT: return size_t(f32.size());
		case Variant::BOOL: return size_t(b.size());
		case Variant::VECTOR2: return size_t(v2.size());
		case Variant::VECTOR3: return size_t(v3.size());
		case Variant::VECTOR4: return size_t(v4.size());
		case Variant::COLOR: return size_t(col.size());
		case Variant::STRING: return size_t(s.size());
		default: return 0;
	}
}

// ---------------------------------------------------------------------------
// ECSComponentData
// ---------------------------------------------------------------------------

int ECSComponentData::field_index(const StringName &f) const {
	for (size_t i = 0; i < fields.size(); ++i) {
		if (fields[i].name == f) {
			return int(i);
		}
	}
	return -1;
}

// ---------------------------------------------------------------------------
// ECSCore — 内部工具
// ---------------------------------------------------------------------------

ECSComponentData *ECSCore::find_comp(const StringName &name) {
	for (auto &c : components_) {
		if (c.name == name) {
			return &c;
		}
	}
	return nullptr;
}

const ECSComponentData *ECSCore::find_comp(const StringName &name) const {
	for (const auto &c : components_) {
		if (c.name == name) {
			return &c;
		}
	}
	return nullptr;
}

int32_t ECSCore::comp_index(const StringName &name) const {
	for (int32_t i = 0; i < int32_t(components_.size()); ++i) {
		if (components_[i].name == name) {
			return i;
		}
	}
	return -1;
}

// 签名聚簇索引: 相同组件集合共享一个签名组(用于 ID 分配)
int32_t ECSCore::sig_index_for(const std::vector<int32_t> &comps) {
	for (int32_t i = 0; i < int32_t(signatures_.size()); ++i) {
		if (signatures_[i].comps == comps) {
			return i;
		}
	}
	ECSSignature sig;
	sig.comps = comps;
	signatures_.push_back(std::move(sig));
	return int32_t(signatures_.size()) - 1;
}

int32_t ECSCore::allocate_entity_id() {
	// 优先复用空闲 ID(数值接近的复用, 保持聚簇)
	if (!free_list_.empty()) {
		int32_t index = free_list_.back();
		free_list_.pop_back();
		return index;
	}
	int32_t index = int32_t(versions_.size());
	versions_.push_back(0);
	return index;
}

void ECSCore::release_entity_id(int32_t index) {
	versions_[index]++;
	free_list_.push_back(index);
}

// ---------------------------------------------------------------------------
// ECSCore — 组件注册
// ---------------------------------------------------------------------------

int32_t ECSCore::register_component(const StringName &name, const PackedStringArray &fnames,
		const PackedInt32Array &ftypes, const Array &fdefaults) {
	if (find_comp(name) != nullptr) {
		return int32_t(components_.size()); // 已注册, 幂等
	}
	const int32_t n = int32_t(fnames.size());
	ECSComponentData data;
	data.name = name;
	data.fields.resize(n);
	data.columns.resize(n);
	data.defaults.resize(n);
	for (int32_t i = 0; i < n; ++i) {
		data.fields[i].name = fnames[i];
		data.fields[i].type = Variant::Type(int64_t(ftypes[i]));
		data.columns[i].type = data.fields[i].type;
		data.defaults[i] = (i < fdefaults.size()) ? fdefaults[i] : Variant();
	}
	components_.push_back(std::move(data));
	return int32_t(components_.size());
}

// ---------------------------------------------------------------------------
// ECSCore — 实体
// ---------------------------------------------------------------------------

int32_t ECSCore::create_entity() {
	int32_t index = allocate_entity_id();
	uint32_t version = versions_[index];
	if (int32_t(entity_sig_.size()) <= index) {
		entity_sig_.resize(index + 1, -1);
	}
	entity_sig_[index] = -1; // 新实体无组件, 不属于任何签名
	return (int32_t(version) << 24) | index;
}

bool ECSCore::is_alive(int32_t entity) const {
	const int32_t index = entity & 0x00FFFFFF;
	const uint32_t version = uint32_t(entity >> 24) & 0xFF;
	if (index < 0 || index >= int32_t(versions_.size())) {
		return false;
	}
	return versions_[index] == version;
}

void ECSCore::destroy_entity(int32_t entity) {
	const int32_t index = entity & 0x00FFFFFF;
	if (index < 0 || index >= int32_t(versions_.size()) || !is_alive(entity)) {
		return;
	}
	// 从所有组件稀疏集中移除(列按行号 swap-remove 同步)
	for (auto &c : components_) {
		if (c.set.has(index)) {
			c.remove_row(index);
		}
	}
	// 组件已清空 → 从签名列表移除
	if (int32_t(entity_sig_.size()) > index && entity_sig_[index] >= 0) {
		auto &list = signatures_[entity_sig_[index]].entities;
		auto it = std::find(list.begin(), list.end(), index);
		if (it != list.end()) {
			list.erase(it);
		}
		entity_sig_[index] = -1;
	}
	release_entity_id(index);
}

// ---------------------------------------------------------------------------
// ECSCore — 签名增量视图辅助
// 签名实体列表 = "拥有该签名全部组件的实体", 结构变更时增量维护。
// 查询按签名匹配直接返回实体集合, 从 O(anchor.dense) 全扫降为 O(结果数)。
// ---------------------------------------------------------------------------

void ECSCore::recompute_entity_sig(int32_t index) {
	if (index < 0) {
		return;
	}
	// 收集实体当前组件索引(升序)
	std::vector<int32_t> comps;
	for (int32_t ci = 0; ci < int32_t(components_.size()); ++ci) {
		if (components_[ci].set.has(index)) {
			comps.push_back(ci);
		}
	}
	const int32_t new_sig = comps.empty() ? -1 : sig_index_for(comps);
	const int32_t old_sig = (index < int32_t(entity_sig_.size())) ? entity_sig_[index] : -1;
	if (old_sig == new_sig) {
		return;
	}
	if (old_sig >= 0) {
		auto &list = signatures_[old_sig].entities;
		auto it = std::find(list.begin(), list.end(), index);
		if (it != list.end()) {
			list.erase(it);
		}
	}
	if (new_sig >= 0) {
		signatures_[new_sig].entities.push_back(index);
	}
	if (int32_t(entity_sig_.size()) <= index) {
		entity_sig_.resize(index + 1, -1);
	}
	entity_sig_[index] = new_sig;
}

// 重建全部签名实体列表(批量结构变更如 deserialize/instantiate 末尾调用)。
void ECSCore::rebuild_signatures() {
	for (auto &sig : signatures_) {
		sig.entities.clear();
	}
	if (int32_t(entity_sig_.size()) < int32_t(versions_.size())) {
		entity_sig_.resize(versions_.size(), -1);
	}
	std::fill(entity_sig_.begin(), entity_sig_.end(), -1);
	for (int32_t index = 0; index < int32_t(versions_.size()); ++index) {
		if (std::find(free_list_.begin(), free_list_.end(), index) != free_list_.end()) {
			continue; // 已释放
		}
		recompute_entity_sig(index);
	}
}

// 收集匹配签名(含 anchor+must, 不含 without)的 anchor 行号。
void ECSCore::collect_sig_rows(int32_t ai, const int32_t *mi, int32_t m,
		const int32_t *wi, int32_t w, PackedInt32Array &out) const {
	if (ai < 0) {
		return;
	}
	const auto &a_col = components_[ai].set;
	for (const auto &sig : signatures_) {
		if (!std::binary_search(sig.comps.begin(), sig.comps.end(), ai)) {
			continue;
		}
		bool ok = true;
		for (int32_t i = 0; i < m; ++i) {
			if (!std::binary_search(sig.comps.begin(), sig.comps.end(), mi[i])) {
				ok = false;
				break;
			}
		}
		if (ok) {
			for (int32_t i = 0; i < w; ++i) {
				if (std::binary_search(sig.comps.begin(), sig.comps.end(), wi[i])) {
					ok = false;
					break;
				}
			}
		}
		if (!ok) {
			continue;
		}
		for (int32_t e : sig.entities) {
			if (is_prefab_index(e)) {
				continue;
			}
			const int32_t row = a_col.row_of(e);
			if (row >= 0) {
				out.append(row);
			}
		}
	}
}

// ---------------------------------------------------------------------------
// ECSCore — 组件增删查
// ---------------------------------------------------------------------------

bool ECSCore::add_component(int32_t entity, const StringName &comp) {
	const int32_t index = entity & 0x00FFFFFF;
	ECSComponentData *c = find_comp(comp);
	if (c == nullptr || !is_alive(entity)) {
		return false;
	}
	if (c->set.has(index)) {
		return true; // 幂等
	}
	// 列按 dense 行号紧凑存储: push 一行默认值 (行号 = old dense size)
	c->push_row(index);
	recompute_entity_sig(index);
	return true;
}

bool ECSCore::has_component(int32_t entity, const StringName &comp) const {
	const int32_t index = entity & 0x00FFFFFF;
	const ECSComponentData *c = find_comp(comp);
	return c != nullptr && c->set.has(index);
}

void ECSCore::remove_component(int32_t entity, const StringName &comp) {
	const int32_t index = entity & 0x00FFFFFF;
	ECSComponentData *c = find_comp(comp);
	if (c == nullptr) {
		return;
	}
	if (!c->set.has(index)) {
		return;
	}
	// swap-remove: 列按行号同步
	c->remove_row(index);
	recompute_entity_sig(index);
}

int32_t ECSCore::count_entities(const StringName &comp) const {
	const ECSComponentData *c = find_comp(comp);
	if (c == nullptr) {
		return 0;
	}
	// 排除 prefab 模板
	int32_t n = 0;
	for (int32_t r = 0; r < int32_t(c->set.dense.size()); ++r) {
		if (!is_prefab_index(c->set.dense[r])) {
			++n;
		}
	}
	return n;
}

// 枚举实体的全部组件名(按注册顺序)。低频路径: destroy 前收集钩子信息用。
PackedStringArray ECSCore::get_entity_components(int32_t entity) const {
	PackedStringArray out;
	const int32_t index = entity & 0x00FFFFFF;
	for (const auto &cd : components_) {
		if (cd.set.has(index)) {
			out.append(cd.name);
		}
	}
	return out;
}

// ---------------------------------------------------------------------------
// ECSCore — 查询
// ---------------------------------------------------------------------------

PackedInt32Array ECSCore::query_rows(const StringName &anchor, const PackedStringArray &must,
		const PackedStringArray &without) const {
	PackedInt32Array out;
	if (must.size() > 8 || without.size() > 8) {
		return out;
	}
	const int32_t ai = comp_index(anchor);
	if (ai < 0) {
		return out;
	}
	int32_t mi[8];
	int32_t wi[8];
	const int32_t m = int32_t(must.size());
	const int32_t w = int32_t(without.size());
	for (int32_t i = 0; i < m; ++i) {
		mi[i] = comp_index(must[i]);
	}
	for (int32_t i = 0; i < w; ++i) {
		wi[i] = comp_index(without[i]);
	}
	// 签名增量视图: 遍历匹配签名收集实体(无需全扫 anchor dense)
	collect_sig_rows(ai, mi, m, wi, w, out);
	return out;
}

// 对齐行号查询: 基于签名视图收集匹配实体, 同步填充 anchor 与各 must 组件的行号。
Array ECSCore::query_rows_aligned(const StringName &anchor, const PackedStringArray &must,
		const PackedStringArray &without) const {
	Array out;
	if (must.size() > 8 || without.size() > 8) {
		return out;
	}
	const int32_t ai = comp_index(anchor);
	if (ai < 0) {
		return out;
	}
	const int32_t m = int32_t(must.size());
	const int32_t w = int32_t(without.size());
	int32_t mi[8];
	int32_t wi[8];
	for (int32_t i = 0; i < m; ++i) {
		mi[i] = comp_index(must[i]);
	}
	for (int32_t i = 0; i < w; ++i) {
		wi[i] = comp_index(without[i]);
	}

	PackedInt32Array anchor_rows;
	collect_sig_rows(ai, mi, m, wi, w, anchor_rows);
	const int32_t n = int32_t(anchor_rows.size());
	out.push_back(anchor_rows);

	// 每个 must 组件: 对齐行号(同一实体集合, 顺序与 anchor_rows 一致)
	const auto &a_dense = components_[ai].set.dense;
	for (int32_t i = 0; i < m; ++i) {
		PackedInt32Array comp_rows;
		if (mi[i] < 0) {
			out.push_back(comp_rows);
			continue;
		}
		const auto &c_set = components_[mi[i]].set;
		comp_rows.resize(n);
		for (int32_t k = 0; k < n; ++k) {
			const int32_t e = a_dense[anchor_rows[k]];
			comp_rows[k] = c_set.row_of(e);
		}
		out.push_back(comp_rows);
	}
	return out;
}

// 行号(anchor dense 下标) -> 实体 ID
int32_t ECSCore::entity_of_row(const StringName &comp, int32_t row) const {
	const ECSComponentData *c = find_comp(comp);
	if (c == nullptr || row < 0 || row >= int32_t(c->set.dense.size())) {
		return -1;
	}
	return c->set.dense[row];
}

// 实体 ID -> 行号 (dense 下标)
int32_t ECSCore::row_of_entity(const StringName &comp, int32_t entity) const {
	const ECSComponentData *c = find_comp(comp);
	if (c == nullptr) {
		return -1;
	}
	return c->set.row_of(entity & 0x00FFFFFF);
}

// ---------------------------------------------------------------------------
// ECSCore — 单实体字段访问
// ---------------------------------------------------------------------------

Variant ECSCore::get_field(int32_t entity, const StringName &comp, const StringName &field) const {
	const int32_t index = entity & 0x00FFFFFF;
	const ECSComponentData *c = find_comp(comp);
	if (c == nullptr) {
		return Variant();
	}
	// 稀疏集: 实体 -> 行号, 列按行号索引(紧凑)
	const int32_t row = c->set.row_of(index);
	if (row < 0) {
		return Variant();
	}
	const int fi = c->field_index(field);
	if (fi < 0) {
		return Variant();
	}
	return c->columns[fi].get(row);
}

void ECSCore::set_field(int32_t entity, const StringName &comp, const StringName &field, const Variant &value) {
	const int32_t index = entity & 0x00FFFFFF;
	ECSComponentData *c = find_comp(comp);
	if (c == nullptr) {
		return;
	}
	const int32_t row = c->set.row_of(index);
	if (row < 0) {
		return;
	}
	const int fi = c->field_index(field);
	if (fi < 0) {
		return;
	}
	c->columns[fi].set(row, value);
}

// ---------------------------------------------------------------------------
// ECSCore — 批量列访问 (零拷贝)
// ---------------------------------------------------------------------------

Variant ECSCore::get_column(const StringName &comp, const StringName &field) const {
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return Variant();
	}
	const ECSComponentData &cd = components_[ci];
	const int fi = cd.field_index(field);
	if (fi < 0) {
		return Variant();
	}
	// 直接返回内部 Packed*Array 引用 —— 零拷贝, GDScript 共享同一内存
	const ECSColumn &col = cd.columns[fi];
	switch (col.type) {
		case Variant::INT: return col.i32;
		case Variant::FLOAT: return col.f32;
		case Variant::BOOL: return col.b;
		case Variant::VECTOR2: return col.v2;
		case Variant::VECTOR3: return col.v3;
		case Variant::VECTOR4: return col.v4;
		case Variant::COLOR: return col.col;
		case Variant::STRING: return col.s;
		default: return Variant();
	}
}

// 一次取多组件多列: 返回 {compName: {fieldName: PackedArray}}, 一次跨语言替代 N 次 get_column。
Dictionary ECSCore::get_columns(const Array &comps_fields) const {
	Dictionary out;
	for (int32_t i = 0; i < comps_fields.size(); ++i) {
		Dictionary cf = comps_fields[i];
		const ECSComponentData *c = find_comp(StringName(cf["comp"]));
		if (c == nullptr) {
			continue;
		}
		Dictionary fields_dict;
		Array fields = cf["fields"];
		for (int32_t j = 0; j < fields.size(); ++j) {
			const StringName fname = StringName(fields[j]);
			const int32_t fi = c->field_index(fname);
			if (fi < 0) {
				continue;
			}
			const ECSColumn &col = c->columns[fi];
			switch (col.type) {
				case Variant::INT: fields_dict[fname] = col.i32; break;
				case Variant::FLOAT: fields_dict[fname] = col.f32; break;
				case Variant::BOOL: fields_dict[fname] = col.b; break;
				case Variant::VECTOR2: fields_dict[fname] = col.v2; break;
				case Variant::VECTOR3: fields_dict[fname] = col.v3; break;
				case Variant::VECTOR4: fields_dict[fname] = col.v4; break;
				case Variant::COLOR: fields_dict[fname] = col.col; break;
				case Variant::STRING: fields_dict[fname] = col.s; break;
				default: break;
			}
		}
		out[c->name] = fields_dict;
	}
	return out;
}

// 借出列: 把内部列移出(内部置空), 返回独占引用 —— 回调内写列无 COW 深拷贝。
Dictionary ECSCore::borrow_columns(const Array &comps_fields) {
	if (_borrowed_active_) {
		UtilityFunctions::push_error("ECSCore::borrow_columns: 存在未归还的借出列! 必须 return_columns 归还后再借出。");
	}
	_borrowed_active_ = true;
	Dictionary out;
	for (int32_t i = 0; i < comps_fields.size(); ++i) {
		Dictionary cf = comps_fields[i];
		ECSComponentData *c = find_comp(StringName(cf["comp"]));
		if (c == nullptr) {
			continue;
		}
		Dictionary fields_dict;
		Array fields = cf["fields"];
		for (int32_t j = 0; j < fields.size(); ++j) {
			const StringName fname = StringName(fields[j]);
			const int32_t fi = c->field_index(fname);
			if (fi < 0) {
				continue;
			}
			ECSColumn &col = c->columns[fi];
			switch (col.type) {
				case Variant::INT: { PackedInt32Array a = col.i32; col.i32 = PackedInt32Array(); fields_dict[fname] = a; break; }
				case Variant::FLOAT: { PackedFloat32Array a = col.f32; col.f32 = PackedFloat32Array(); fields_dict[fname] = a; break; }
				case Variant::BOOL: { PackedByteArray a = col.b; col.b = PackedByteArray(); fields_dict[fname] = a; break; }
				case Variant::VECTOR2: { PackedVector2Array a = col.v2; col.v2 = PackedVector2Array(); fields_dict[fname] = a; break; }
				case Variant::VECTOR3: { PackedVector3Array a = col.v3; col.v3 = PackedVector3Array(); fields_dict[fname] = a; break; }
				case Variant::VECTOR4: { PackedVector4Array a = col.v4; col.v4 = PackedVector4Array(); fields_dict[fname] = a; break; }
				case Variant::COLOR: { PackedColorArray a = col.col; col.col = PackedColorArray(); fields_dict[fname] = a; break; }
				case Variant::STRING: { PackedStringArray a = col.s; col.s = PackedStringArray(); fields_dict[fname] = a; break; }
				default: break;
			}
		}
		out[c->name] = fields_dict;
	}
	return out;
}

// 归还列: 内部列 = 返回数组(指针交换 O(1))。
void ECSCore::return_columns(const Dictionary &borrowed) {
	_borrowed_active_ = false;
	Array keys = borrowed.keys();
	for (int32_t i = 0; i < keys.size(); ++i) {
		const StringName comp = StringName(keys[i]);
		ECSComponentData *c = find_comp(comp);
		if (c == nullptr) {
			continue;
		}
		Dictionary fields = borrowed[comp];
		Array fkeys = fields.keys();
		for (int32_t j = 0; j < fkeys.size(); ++j) {
			const StringName fname = StringName(fkeys[j]);
			const int32_t fi = c->field_index(fname);
			if (fi < 0) {
				continue;
			}
			ECSColumn &col = c->columns[fi];
			const Variant val = fields[fname];
			switch (col.type) {
				case Variant::INT: col.i32 = val; break;
				case Variant::FLOAT: col.f32 = val; break;
				case Variant::BOOL: col.b = val; break;
				case Variant::VECTOR2: col.v2 = val; break;
				case Variant::VECTOR3: col.v3 = val; break;
				case Variant::VECTOR4: col.v4 = val; break;
				case Variant::COLOR: col.col = val; break;
				case Variant::STRING: col.s = val; break;
				default: break;
			}
		}
	}
}

bool ECSCore::is_column_borrowed() const {
	return _borrowed_active_;
}
void ECSCore::set_columns(const Dictionary &values) {
	// Godot Dictionary 无顺序索引, 用 keys()
	Array keys = values.keys();
	for (int32_t i = 0; i < keys.size(); ++i) {
		const StringName comp = StringName(keys[i]);
		ECSComponentData *c = find_comp(comp);
		if (c == nullptr) {
			continue;
		}
		Dictionary fields = values[comp];
		Array fkeys = fields.keys();
		for (int32_t j = 0; j < fkeys.size(); ++j) {
			const StringName fname = StringName(fkeys[j]);
			const int32_t fi = c->field_index(fname);
			if (fi < 0) {
				continue;
			}
			ECSColumn &col = c->columns[fi];
			const Variant val = fields[fname];
			// 引用赋值(指针交换): 无逐元素拷贝
			switch (col.type) {
				case Variant::INT: col.i32 = val; break;
				case Variant::FLOAT: col.f32 = val; break;
				case Variant::BOOL: col.b = val; break;
				case Variant::VECTOR2: col.v2 = val; break;
				case Variant::VECTOR3: col.v3 = val; break;
				case Variant::VECTOR4: col.v4 = val; break;
				case Variant::COLOR: col.col = val; break;
				case Variant::STRING: col.s = val; break;
				default: break;
			}
		}
	}
}

void ECSCore::set_column(const StringName &comp, const StringName &field, const Variant &values) {
	ECSComponentData *cd = find_comp(comp);
	if (cd == nullptr) {
		return;
	}
	const int fi = cd->field_index(field);
	if (fi < 0) {
		return;
	}
	// 引用赋值(指针交换): 无逐元素拷贝
	ECSColumn &col = cd->columns[fi];
	switch (col.type) {
		case Variant::INT: col.i32 = values; break;
		case Variant::FLOAT: col.f32 = values; break;
		case Variant::BOOL: col.b = values; break;
		case Variant::VECTOR2: col.v2 = values; break;
		case Variant::VECTOR3: col.v3 = values; break;
		case Variant::VECTOR4: col.v4 = values; break;
		case Variant::COLOR: col.col = values; break;
		case Variant::STRING: col.s = values; break;
		default: break;
	}
}

// ---------------------------------------------------------------------------
// ECSCore — Tier 0: 原生批量运算
// ---------------------------------------------------------------------------

// 收集 anchor dense 中满足 must 的实体行号(直接遍历 anchor 稀疏集)
static void collect_rows(const ECSComponentData *anchor, const ECSComponentData *const *req,
		int32_t m, std::vector<int32_t> &out,
		const std::vector<int32_t> *prefabs = nullptr) {
	out.clear();
	const auto &dense = anchor->set.dense;
	for (int32_t r = 0; r < int32_t(dense.size()); ++r) {
		const int32_t e = dense[r];
		if (prefabs) {
			bool is_pref = false;
			for (int32_t p : *prefabs) {
				if (p == e) { is_pref = true; break; }
			}
			if (is_pref) {
				continue;
			}
		}
		bool ok = true;
		for (int32_t i = 0; i < m; ++i) {
			if (req[i] == nullptr || !req[i]->set.has(e)) {
				ok = false;
				break;
			}
		}
		if (ok) {
			out.push_back(r); // 行号! 列按行号索引
		}
	}
}

// ---------------------------------------------------------------------------
// 条件过滤: 解析 Array[Dictionary] 条件列表, 用于 batch_apply_where / batch_count
// 每个条件: {comp: StringName, field: StringName, op: int(CondOp), value: double}
// ---------------------------------------------------------------------------
namespace {

struct ECSFilterCond {
	const ECSComponentData *comp = nullptr;
	int field_idx = -1;
	int32_t op = 0;      // CondOp
	double value = 0.0;
};

// 解析条件列表, 返回有效条件数
int parse_conditions(const ECSCore *core, const Array &conds,
		std::vector<ECSFilterCond> &out, int max_conds) {
	out.clear();
	for (int i = 0; i < conds.size() && int(out.size()) < max_conds; ++i) {
		Dictionary d = conds[i];
		if (!d.has("comp") || !d.has("field")) {
			continue;
		}
		ECSFilterCond c;
		c.comp = core->find_comp(StringName(d["comp"]));
		if (c.comp == nullptr) {
			continue;
		}
		c.field_idx = c.comp->field_index(StringName(d["field"]));
		if (c.field_idx < 0) {
			continue;
		}
		c.op = int64_t(d.get("op", int64_t(0)));
		c.value = double(d.get("value", 0.0));
		out.push_back(c);
	}
	return int(out.size());
}

// 单实体是否满足所有条件(按列值比较)。entity 为真实实体ID(条件组件列按各自行号访问)
inline bool cond_matches(const ECSCore *core, int32_t entity, const std::vector<ECSFilterCond> &conds) {
	for (const auto &c : conds) {
		const ECSColumn &col = c.comp->columns[c.field_idx];
		const int32_t row = c.comp->set.row_of(entity & 0x00FFFFFF);
		if (row < 0) {
			return false; // 条件组件该实体未拥有 -> 不满足
		}
		double v = 0.0;
		switch (col.type) {
			case Variant::INT: v = double(col.i32[row]); break;
			case Variant::FLOAT: v = double(col.f32[row]); break;
			default: return false; // 条件仅支持数值字段
		}
		switch (c.op) {
			case ECSCore::COND_LT: if (!(v < c.value)) return false; break;
			case ECSCore::COND_LE: if (!(v <= c.value)) return false; break;
			case ECSCore::COND_GT: if (!(v > c.value)) return false; break;
			case ECSCore::COND_GE: if (!(v >= c.value)) return false; break;
			case ECSCore::COND_EQ: if (!(v == c.value)) return false; break;
			case ECSCore::COND_NE: if (!(v != c.value)) return false; break;
			default: return false;
		}
	}
	return true;
}

// 收集 anchor+must+条件 都满足的实体行号
void collect_rows_where(const ECSCore *core, const ECSComponentData *anchor,
		const ECSComponentData *const *req, int32_t m,
		const std::vector<ECSFilterCond> &conds, std::vector<int32_t> &out) {
	out.clear();
	const auto &dense = anchor->set.dense;
	for (int32_t r = 0; r < int32_t(dense.size()); ++r) {
		const int32_t e = dense[r];
		if (core->is_prefab(e)) {
			continue; // 跳过 prefab 模板
		}
		bool ok = true;
		for (int32_t i = 0; i < m; ++i) {
			if (req[i] == nullptr || !req[i]->set.has(e)) {
				ok = false;
				break;
			}
		}
		if (ok && cond_matches(core, e, conds)) {
			out.push_back(r); // 行号
		}
	}
}
} // namespace

// 列间运算: col = col OP (src * factor + addend), 仅满足条件的实体。
// 支持 INT/FLOAT(含 addend) 与 VECTOR2/VECTOR3(用 factor 标量缩放, 忽略 addend)。
int64_t ECSCore::batch_apply_col(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field,
		const StringName &src_comp, const StringName &src_field,
		int64_t op, double factor, double addend, const Array &conditions) {
	ECSComponentData *a = find_comp(anchor);
	ECSComponentData *oc = find_comp(op_comp);
	ECSComponentData *sc = find_comp(src_comp);
	if (a == nullptr || oc == nullptr || sc == nullptr) {
		return 0;
	}
	const int ofi = oc->field_index(op_field);
	const int sfi = sc->field_index(src_field);
	if (ofi < 0 || sfi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	const ECSComponentData *req[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		req[i] = find_comp(must[i]);
	}
	std::vector<ECSFilterCond> conds;
	parse_conditions(this, conditions, conds, 8);
	std::vector<int32_t> rows;
	collect_rows_where(this, a, req, m > 8 ? 8 : m, conds, rows);

	ECSColumn &ocol = oc->columns[ofi];
	const ECSColumn &scol = sc->columns[sfi];
	const bool same_comp = (op_comp == anchor);
	const bool src_is_anchor = (src_comp == anchor);
	const auto &a_dense = a->set.dense;
	int64_t n = 0;
	const int32_t cnt = int32_t(rows.size());
	const double cost = 1.5;

	if (ocol.type == Variant::FLOAT && scol.type == Variant::FLOAT) {
		float *w = ocol.f32.ptrw();
		const float *src = scol.f32.ptr();
		parallel_for(size_t(cnt), [&](size_t b, size_t e) {
			for (size_t i = b; i < e; ++i) {
				const int32_t erow = rows[i];
				const int32_t ee = a_dense[erow];
				const int32_t orow = same_comp ? erow : oc->set.row_of(ee);
				const int32_t srow = src_is_anchor ? erow : sc->set.row_of(ee);
				if (orow < 0 || srow < 0) continue;
				const float v = float(double(src[srow]) * factor + addend);
				switch (op) {
					case COL_ADD: w[orow] += v; break;
					case COL_SUB: w[orow] -= v; break;
					case COL_MUL: w[orow] *= v; break;
					case COL_DIV: if (v != 0.0f) w[orow] /= v; break;
					case COL_SET: w[orow] = v; break;
					default: break;
				}
			}
		}, cost);
		n = cnt;
	} else if (ocol.type == Variant::INT && scol.type == Variant::INT) {
		int32_t *w = ocol.i32.ptrw();
		const int32_t *src = scol.i32.ptr();
		parallel_for(size_t(cnt), [&](size_t b, size_t e) {
			for (size_t i = b; i < e; ++i) {
				const int32_t erow = rows[i];
				const int32_t ee = a_dense[erow];
				const int32_t orow = same_comp ? erow : oc->set.row_of(ee);
				const int32_t srow = src_is_anchor ? erow : sc->set.row_of(ee);
				if (orow < 0 || srow < 0) continue;
				const int32_t v = int32_t(double(src[srow]) * factor + addend);
				switch (op) {
					case COL_ADD: w[orow] += v; break;
					case COL_SUB: w[orow] -= v; break;
					case COL_MUL: w[orow] *= v; break;
					case COL_DIV: if (v != 0) w[orow] /= v; break;
					case COL_SET: w[orow] = v; break;
					default: break;
				}
			}
		}, cost);
		n = cnt;
	} else if (ocol.type == Variant::VECTOR2 && scol.type == Variant::VECTOR2) {
		Vector2 *w = ocol.v2.ptrw();
		const Vector2 *src = scol.v2.ptr();
		const float f = float(factor);
		parallel_for(size_t(cnt), [&](size_t b, size_t e) {
			for (size_t i = b; i < e; ++i) {
				const int32_t erow = rows[i];
				const int32_t ee = a_dense[erow];
				const int32_t orow = same_comp ? erow : oc->set.row_of(ee);
				const int32_t srow = src_is_anchor ? erow : sc->set.row_of(ee);
				if (orow < 0 || srow < 0) continue;
				const Vector2 v = src[srow] * f;
				switch (op) {
					case COL_ADD: w[orow] += v; break;
					case COL_SUB: w[orow] -= v; break;
					case COL_MUL: w[orow] *= v; break;
					case COL_DIV: if (v.x != 0.0f && v.y != 0.0f) w[orow] /= v; break;
					case COL_SET: w[orow] = v; break;
					default: break;
				}
			}
		}, 3.0);
		n = cnt;
	} else if (ocol.type == Variant::VECTOR3 && scol.type == Variant::VECTOR3) {
		Vector3 *w = ocol.v3.ptrw();
		const Vector3 *src = scol.v3.ptr();
		const float f = float(factor);
		parallel_for(size_t(cnt), [&](size_t b, size_t e) {
			for (size_t i = b; i < e; ++i) {
				const int32_t erow = rows[i];
				const int32_t ee = a_dense[erow];
				const int32_t orow = same_comp ? erow : oc->set.row_of(ee);
				const int32_t srow = src_is_anchor ? erow : sc->set.row_of(ee);
				if (orow < 0 || srow < 0) continue;
				const Vector3 v = src[srow] * f;
				switch (op) {
					case COL_ADD: w[orow] += v; break;
					case COL_SUB: w[orow] -= v; break;
					case COL_MUL: w[orow] *= v; break;
					case COL_DIV: if (v.x != 0.0f && v.y != 0.0f && v.z != 0.0f) w[orow] /= v; break;
					case COL_SET: w[orow] = v; break;
					default: break;
				}
			}
		}, 3.0);
		n = cnt;
	}
	return n;
}

// 带条件过滤的列钳制: col = clamp(col, min, max)(仅满足 conditions 的实体)。
int64_t ECSCore::batch_clamp_where(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field,
		const StringName &min_comp, const StringName &min_field,
		const StringName &max_comp, const StringName &max_field,
		const Array &conditions) {
	ECSComponentData *a = find_comp(anchor);
	ECSComponentData *oc = find_comp(op_comp);
	ECSComponentData *minc = find_comp(min_comp);
	ECSComponentData *maxc = find_comp(max_comp);
	if (a == nullptr || oc == nullptr || minc == nullptr || maxc == nullptr) {
		return 0;
	}
	const int ofi = oc->field_index(op_field);
	const int minfi = minc->field_index(min_field);
	const int maxfi = maxc->field_index(max_field);
	if (ofi < 0 || minfi < 0 || maxfi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	const ECSComponentData *req[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		req[i] = find_comp(must[i]);
	}
	std::vector<ECSFilterCond> conds;
	parse_conditions(this, conditions, conds, 8);
	std::vector<int32_t> rows;
	collect_rows_where(this, a, req, m > 8 ? 8 : m, conds, rows);

	ECSColumn &ocol = oc->columns[ofi];
	const ECSColumn &mincol = minc->columns[minfi];
	const ECSColumn &maxcol = maxc->columns[maxfi];
	const bool same_comp = (op_comp == anchor);
	const bool min_is_anchor = (min_comp == anchor);
	const bool max_is_anchor = (max_comp == anchor);
	const auto &a_dense = a->set.dense;
	const int32_t cnt = int32_t(rows.size());
	// 边界列支持 INT 或 FLOAT, 目标支持 INT 或 FLOAT(混合类型用 double 统一钳制)
	const bool min_ok = (mincol.type == Variant::INT || mincol.type == Variant::FLOAT);
	const bool max_ok = (maxcol.type == Variant::INT || maxcol.type == Variant::FLOAT);
	auto bound_val = [](const ECSColumn &c, int32_t row) -> double {
		return (c.type == Variant::FLOAT) ? double(c.f32[row]) : double(c.i32[row]);
	};
	if (ocol.type == Variant::FLOAT && min_ok && max_ok) {
		float *w = ocol.f32.ptrw();
		parallel_for(size_t(cnt), [&](size_t b, size_t e) {
			for (size_t i = b; i < e; ++i) {
				const int32_t erow = rows[i];
				const int32_t ee = a_dense[erow];
				const int32_t orow = same_comp ? erow : oc->set.row_of(ee);
				const int32_t nrow = min_is_anchor ? erow : minc->set.row_of(ee);
				const int32_t xrow = max_is_anchor ? erow : maxc->set.row_of(ee);
				if (orow < 0 || nrow < 0 || xrow < 0) continue;
				w[orow] = float(std::clamp(double(w[orow]), bound_val(mincol, nrow), bound_val(maxcol, xrow)));
			}
		}, 1.5);
		return cnt;
	} else if (ocol.type == Variant::INT && min_ok && max_ok) {
		int32_t *w = ocol.i32.ptrw();
		parallel_for(size_t(cnt), [&](size_t b, size_t e) {
			for (size_t i = b; i < e; ++i) {
				const int32_t erow = rows[i];
				const int32_t ee = a_dense[erow];
				const int32_t orow = same_comp ? erow : oc->set.row_of(ee);
				const int32_t nrow = min_is_anchor ? erow : minc->set.row_of(ee);
				const int32_t xrow = max_is_anchor ? erow : maxc->set.row_of(ee);
				if (orow < 0 || nrow < 0 || xrow < 0) continue;
				w[orow] = int32_t(std::clamp(double(w[orow]), bound_val(mincol, nrow), bound_val(maxcol, xrow)));
			}
		}, 1.0);
		return cnt;
	}
	return 0;
}
void ECSCore::collect_sig_rows_where(int32_t ai, const int32_t *mi, int32_t m,
		const int32_t *wi, int32_t w, const Array &conditions, PackedInt32Array &out) const {
	if (ai < 0) {
		return;
	}
	std::vector<ECSFilterCond> conds;
	parse_conditions(this, conditions, conds, 8);
	const auto &a_col = components_[ai].set;
	for (const auto &sig : signatures_) {
		if (!std::binary_search(sig.comps.begin(), sig.comps.end(), ai)) {
			continue;
		}
		bool ok = true;
		for (int32_t i = 0; i < m; ++i) {
			if (!std::binary_search(sig.comps.begin(), sig.comps.end(), mi[i])) {
				ok = false;
				break;
			}
		}
		if (ok) {
			for (int32_t i = 0; i < w; ++i) {
				if (std::binary_search(sig.comps.begin(), sig.comps.end(), wi[i])) {
					ok = false;
					break;
				}
			}
		}
		if (!ok) {
			continue;
		}
		for (int32_t e : sig.entities) {
			if (is_prefab_index(e)) {
				continue;
			}
			if (!cond_matches(this, e, conds)) {
				continue;
			}
			const int32_t row = a_col.row_of(e);
			if (row >= 0) {
				out.append(row);
			}
		}
	}
}

// 对齐行号 + 条件过滤: 只返回满足 anchor+must+without+conditions 的实体,
// 并对 comps 指定的组件输出对齐行号(基于签名视图)。
Array ECSCore::query_rows_aligned_where(const StringName &anchor, const PackedStringArray &must,
		const PackedStringArray &without, const Array &conditions,
		const PackedStringArray &comps) const {
	Array out;
	if (must.size() > 8 || without.size() > 8) {
		return out;
	}
	const int32_t ai = comp_index(anchor);
	if (ai < 0) {
		return out;
	}
	const int32_t m = int32_t(must.size());
	const int32_t w = int32_t(without.size());
	int32_t mi[8];
	int32_t wi[8];
	for (int32_t i = 0; i < m; ++i) {
		mi[i] = comp_index(must[i]);
	}
	for (int32_t i = 0; i < w; ++i) {
		wi[i] = comp_index(without[i]);
	}

	PackedInt32Array anchor_rows;
	collect_sig_rows_where(ai, mi, m, wi, w, conditions, anchor_rows);
	const int32_t n = int32_t(anchor_rows.size());
	out.push_back(anchor_rows);

	// comps 对齐行号(与 anchor_rows 顺序一一对应)
	const auto &a_dense = components_[ai].set.dense;
	for (int32_t i = 0; i < int32_t(comps.size()) && i < 8; ++i) {
		const ECSComponentData *c = find_comp(comps[i]);
		PackedInt32Array cr;
		if (c == nullptr) {
			out.push_back(cr);
			continue;
		}
		cr.resize(n);
		for (int32_t k = 0; k < n; ++k) {
			const int32_t e = a_dense[anchor_rows[k]];
			cr[k] = c->set.row_of(e);
		}
		out.push_back(cr);
	}
	return out;
}

int64_t ECSCore::batch_count(const StringName &anchor, const PackedStringArray &must,
		const Array &conditions) const {
	const ECSComponentData *a = find_comp(anchor);
	if (a == nullptr) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	const ECSComponentData *req[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		req[i] = find_comp(must[i]);
	}
	std::vector<ECSFilterCond> conds;
	parse_conditions(this, conditions, conds, 8);
	std::vector<int32_t> rows;
	collect_rows_where(this, a, req, m > 8 ? 8 : m, conds, rows);
	return int64_t(rows.size());
}

int64_t ECSCore::batch_apply_where(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field, int64_t op,
		double factor, double addend, const Array &conditions) {
	ECSComponentData *a = find_comp(anchor);
	ECSComponentData *oc = find_comp(op_comp);
	if (a == nullptr || oc == nullptr) {
		return 0;
	}
	const int fi = oc->field_index(op_field);
	if (fi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	const ECSComponentData *req[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		req[i] = find_comp(must[i]);
	}
	std::vector<ECSFilterCond> conds;
	parse_conditions(this, conditions, conds, 8);
	std::vector<int32_t> rows;
	collect_rows_where(this, a, req, m > 8 ? 8 : m, conds, rows);

	ECSColumn &col = oc->columns[fi];
	int64_t n = 0;
	// 目标列行号: anchor 行号 -> 实体ID -> op_comp 行号
	// 若 op_comp == anchor, 行号可直接复用(快路径, 无转换)
	const bool same_comp = (op_comp == anchor);
	const auto &a_dense = a->set.dense;
	switch (col.type) {
		case Variant::INT: {
			int32_t *w = col.i32.ptrw();
			const int32_t add = int32_t(addend);
			if (same_comp) {
				parallel_for(rows.size(), [&](size_t b, size_t e) {
					for (size_t i = b; i < e; ++i) {
						const int32_t row = rows[i];
						switch (op) {
							case BATCH_ADD: w[row] += add; break;
							case BATCH_MUL_ADD: w[row] = int32_t(double(w[row]) * factor + addend); break;
							case BATCH_SET: w[row] = add; break;
							default: break;
						}
					}
				});
			} else {
				parallel_for(rows.size(), [&](size_t b, size_t e) {
					for (size_t i = b; i < e; ++i) {
						const int32_t orow = oc->set.row_of(a_dense[rows[i]]);
						if (orow < 0) continue;
						switch (op) {
							case BATCH_ADD: w[orow] += add; break;
							case BATCH_MUL_ADD: w[orow] = int32_t(double(w[orow]) * factor + addend); break;
							case BATCH_SET: w[orow] = add; break;
							default: break;
						}
					}
				});
			}
			n = int64_t(rows.size());
			break;
		}
		case Variant::FLOAT: {
			float *w = col.f32.ptrw();
			if (same_comp) {
				parallel_for(rows.size(), [&](size_t b, size_t e) {
					for (size_t i = b; i < e; ++i) {
						const int32_t row = rows[i];
						switch (op) {
							case BATCH_ADD: w[row] += float(addend); break;
							case BATCH_MUL_ADD: w[row] = float(double(w[row]) * factor + addend); break;
							case BATCH_SET: w[row] = float(addend); break;
							default: break;
						}
					}
				});
			} else {
				parallel_for(rows.size(), [&](size_t b, size_t e) {
					for (size_t i = b; i < e; ++i) {
						const int32_t orow = oc->set.row_of(a_dense[rows[i]]);
						if (orow < 0) continue;
						switch (op) {
							case BATCH_ADD: w[orow] += float(addend); break;
							case BATCH_MUL_ADD: w[orow] = float(double(w[orow]) * factor + addend); break;
							case BATCH_SET: w[orow] = float(addend); break;
							default: break;
						}
					}
				});
			}
			n = int64_t(rows.size());
			break;
		}
		default:
			break;
	}
	return n;
}

int64_t ECSCore::batch_apply(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field, int64_t op,
		double factor, double addend) {
	ECSComponentData *a = find_comp(anchor);
	ECSComponentData *oc = find_comp(op_comp);
	if (a == nullptr || oc == nullptr) {
		return 0;
	}
	const int fi = oc->field_index(op_field);
	if (fi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	const ECSComponentData *req[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		req[i] = find_comp(must[i]);
	}
	std::vector<int32_t> rows;
	collect_rows(a, req, m > 8 ? 8 : m, rows, &prefab_indices_);

	ECSColumn &col = oc->columns[fi];
	int64_t n = 0;
	// 目标列行号: anchor 行号 -> 实体ID -> op_comp 行号
	const bool same_comp = (op_comp == anchor);
	const auto &a_dense = a->set.dense;
	switch (col.type) {
		case Variant::INT: {
			int32_t *w = col.i32.ptrw();
			const int32_t add = int32_t(addend);
			if (same_comp) {
				// 无 must + 无 prefab → 行号连续, INT 的 ADD/SET 可 SIMD
				const bool contiguous = (m == 0) && prefab_indices_.empty()
						&& (op == BATCH_ADD || op == BATCH_SET);
				if (contiguous) {
					parallel_for(rows.size(), [&](size_t b, size_t e) {
						const __m128i addv = _mm_set1_epi32(add);
						size_t i = b;
						if (op == BATCH_ADD) {
							for (; i + 4 <= e; i += 4) {
								_mm_storeu_si128(reinterpret_cast<__m128i *>(w + i),
										_mm_add_epi32(_mm_loadu_si128(reinterpret_cast<const __m128i *>(w + i)), addv));
							}
							for (; i < e; ++i) w[i] += add;
						} else {
							for (; i + 4 <= e; i += 4) {
								_mm_storeu_si128(reinterpret_cast<__m128i *>(w + i), addv);
							}
							for (; i < e; ++i) w[i] = add;
						}
					});
				} else {
					parallel_for(rows.size(), [&](size_t b, size_t e) {
						for (size_t i = b; i < e; ++i) {
							const int32_t row = rows[i];
							switch (op) {
								case BATCH_ADD: w[row] += add; break;
								case BATCH_MUL_ADD: w[row] = int32_t(double(w[row]) * factor + addend); break;
								case BATCH_SET: w[row] = add; break;
								default: break;
							}
						}
					});
				}
			} else {
				parallel_for(rows.size(), [&](size_t b, size_t e) {
					for (size_t i = b; i < e; ++i) {
						const int32_t orow = oc->set.row_of(a_dense[rows[i]]);
						if (orow < 0) continue;
						switch (op) {
							case BATCH_ADD: w[orow] += add; break;
							case BATCH_MUL_ADD: w[orow] = int32_t(double(w[orow]) * factor + addend); break;
							case BATCH_SET: w[orow] = add; break;
							default: break;
						}
					}
				});
			}
			n = int64_t(rows.size());
			break;
		}
		case Variant::FLOAT: {
			float *w = col.f32.ptrw();
			if (same_comp) {
				// 无 must + 无 prefab → 行号连续 0..n-1, 可 SIMD 连续遍历
				const bool contiguous = (m == 0) && prefab_indices_.empty();
				if (contiguous) {
					parallel_for(rows.size(), [&](size_t b, size_t e) {
						const __m128 addv = _mm_set1_ps(float(addend));
						const __m128 mulv = _mm_set1_ps(float(factor));
						size_t i = b;
						if (op == BATCH_ADD) {
							for (; i + 4 <= e; i += 4) {
								_mm_storeu_ps(w + i, _mm_add_ps(_mm_loadu_ps(w + i), addv));
							}
							for (; i < e; ++i) w[i] += float(addend);
						} else if (op == BATCH_MUL_ADD) {
							for (; i + 4 <= e; i += 4) {
								_mm_storeu_ps(w + i, _mm_add_ps(_mm_mul_ps(_mm_loadu_ps(w + i), mulv), addv));
							}
							for (; i < e; ++i) w[i] = float(double(w[i]) * factor + addend);
						} else if (op == BATCH_SET) {
							for (; i + 4 <= e; i += 4) {
								_mm_storeu_ps(w + i, addv);
							}
							for (; i < e; ++i) w[i] = float(addend);
						}
					}, 2.0); // float 运算成本 ~2x int, 更早并行
				} else {
					parallel_for(rows.size(), [&](size_t b, size_t e) {
						for (size_t i = b; i < e; ++i) {
							const int32_t row = rows[i];
							switch (op) {
								case BATCH_ADD: w[row] += float(addend); break;
								case BATCH_MUL_ADD: w[row] = float(double(w[row]) * factor + addend); break;
								case BATCH_SET: w[row] = float(addend); break;
								default: break;
							}
						}
					});
				}
			} else {
				parallel_for(rows.size(), [&](size_t b, size_t e) {
					for (size_t i = b; i < e; ++i) {
						const int32_t orow = oc->set.row_of(a_dense[rows[i]]);
						if (orow < 0) continue;
						switch (op) {
							case BATCH_ADD: w[orow] += float(addend); break;
							case BATCH_MUL_ADD: w[orow] = float(double(w[orow]) * factor + addend); break;
							case BATCH_SET: w[orow] = float(addend); break;
							default: break;
						}
					}
				});
			}
			n = int64_t(rows.size());
			break;
		}
		default:
			break;
	}
	return n;
}

int64_t ECSCore::batch_clamp(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field,
		const StringName &min_comp, const StringName &min_field,
		const StringName &max_comp, const StringName &max_field) {
	ECSComponentData *a = find_comp(anchor);
	ECSComponentData *oc = find_comp(op_comp);
	ECSComponentData *minc = find_comp(min_comp);
	ECSComponentData *maxc = find_comp(max_comp);
	if (a == nullptr || oc == nullptr || minc == nullptr || maxc == nullptr) {
		return 0;
	}
	const int fi = oc->field_index(op_field);
	const int mini = minc->field_index(min_field);
	const int maxi = maxc->field_index(max_field);
	if (fi < 0 || mini < 0 || maxi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	const ECSComponentData *req[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		req[i] = find_comp(must[i]);
	}
	std::vector<int32_t> rows;
	collect_rows(a, req, m > 8 ? 8 : m, rows, &prefab_indices_);

	ECSColumn &col = oc->columns[fi];
	const ECSColumn &mincol = minc->columns[mini];
	const ECSColumn &maxcol = maxc->columns[maxi];
	int64_t n = 0;
	const bool same_comp = (op_comp == anchor);
	const auto &a_dense = a->set.dense;
	switch (col.type) {
		case Variant::INT: {
			int32_t *w = col.i32.ptrw();
			const int32_t *mn = mincol.i32.ptr();
			const int32_t *mx = maxcol.i32.ptr();
			if (same_comp) {
				parallel_for(rows.size(), [&](size_t b, size_t e) {
					for (size_t i = b; i < e; ++i) {
						const int32_t row = rows[i];
						w[row] = CLAMP(w[row], mn[row], mx[row]);
					}
				});
			} else {
				parallel_for(rows.size(), [&](size_t b, size_t e) {
					for (size_t i = b; i < e; ++i) {
						const int32_t orow = oc->set.row_of(a_dense[rows[i]]);
						if (orow < 0) continue;
						w[orow] = CLAMP(w[orow], mn[orow], mx[orow]);
					}
				});
			}
			n = int64_t(rows.size());
			break;
		}
		case Variant::FLOAT: {
			float *w = col.f32.ptrw();
			const float *mn = mincol.f32.ptr();
			const float *mx = maxcol.f32.ptr();
			if (same_comp) {
				parallel_for(rows.size(), [&](size_t b, size_t e) {
					for (size_t i = b; i < e; ++i) {
						const int32_t row = rows[i];
						w[row] = CLAMP(w[row], mn[row], mx[row]);
					}
				});
			} else {
				parallel_for(rows.size(), [&](size_t b, size_t e) {
					for (size_t i = b; i < e; ++i) {
						const int32_t orow = oc->set.row_of(a_dense[rows[i]]);
						if (orow < 0) continue;
						w[orow] = CLAMP(w[orow], mn[orow], mx[orow]);
					}
				});
			}
			n = int64_t(rows.size());
			break;
		}
		default:
			break;
	}
	return n;
}

int64_t ECSCore::batch_vec_add(const StringName &anchor, const PackedStringArray &must,
		const StringName &pos_comp, const StringName &pos_field,
		const StringName &vel_comp, const StringName &vel_field, double delta) {
	ECSComponentData *a = find_comp(anchor);
	ECSComponentData *posc = find_comp(pos_comp);
	ECSComponentData *velc = find_comp(vel_comp);
	if (a == nullptr || posc == nullptr || velc == nullptr) {
		return 0;
	}
	const int pfi = posc->field_index(pos_field);
	const int vfi = velc->field_index(vel_field);
	if (pfi < 0 || vfi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	const ECSComponentData *req[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		req[i] = find_comp(must[i]);
	}
	std::vector<int32_t> rows;
	collect_rows(a, req, m > 8 ? 8 : m, rows, &prefab_indices_);

	ECSColumn &poscol = posc->columns[pfi];
	const ECSColumn &velcol = velc->columns[vfi];
	int64_t n = 0;
	const bool pos_is_anchor = (pos_comp == anchor);
	const bool vel_is_anchor = (vel_comp == anchor);
	const auto &a_dense = a->set.dense;
	if (poscol.type == Variant::VECTOR2 && velcol.type == Variant::VECTOR2) {
		Vector2 *p = poscol.v2.ptrw();
		const Vector2 *v = velcol.v2.ptr();
		const float d = float(delta);
		if (pos_is_anchor && vel_is_anchor) {
			// 无 must + 无 prefab → 行号连续, SIMD 一次处理 2 个 Vector2(4 float)
			const bool contiguous = (m == 0) && prefab_indices_.empty();
			if (contiguous) {
				parallel_for(rows.size(), [&](size_t b, size_t e) {
					float *pf = reinterpret_cast<float *>(p);
					const float *vf = reinterpret_cast<const float *>(v);
					const __m128 dv = _mm_set1_ps(d);
					size_t i = b;
					for (; i + 2 <= e; i += 2) {
						__m128 posv = _mm_loadu_ps(pf + i * 2);
						__m128 velv = _mm_loadu_ps(vf + i * 2);
						_mm_storeu_ps(pf + i * 2, _mm_add_ps(posv, _mm_mul_ps(velv, dv)));
					}
					for (; i < e; ++i) p[i] += v[i] * d;
				}, 3.0);
			} else {
				parallel_for(rows.size(), [&](size_t b, size_t e) {
					for (size_t i = b; i < e; ++i) {
						const int32_t row = rows[i];
						p[row] += v[row] * d;
					}
				});
			}
		} else {
			parallel_for(rows.size(), [&](size_t b, size_t e) {
				for (size_t i = b; i < e; ++i) {
					const int32_t erow = rows[i];
					const int32_t e = a_dense[erow];
					const int32_t prow = pos_is_anchor ? erow : posc->set.row_of(e);
					const int32_t vrow = vel_is_anchor ? erow : velc->set.row_of(e);
					if (prow < 0 || vrow < 0) continue;
					p[prow] += v[vrow] * d;
				}
			});
		}
		n = int64_t(rows.size());
	} else if (poscol.type == Variant::VECTOR3 && velcol.type == Variant::VECTOR3) {
		Vector3 *p = poscol.v3.ptrw();
		const Vector3 *v = velcol.v3.ptr();
		const float d = float(delta);
		if (pos_is_anchor && vel_is_anchor) {
			parallel_for(rows.size(), [&](size_t b, size_t e) {
				for (size_t i = b; i < e; ++i) {
					const int32_t row = rows[i];
					p[row] += v[row] * d;
				}
			}, 3.0);
		} else {
			parallel_for(rows.size(), [&](size_t b, size_t e) {
				for (size_t i = b; i < e; ++i) {
					const int32_t erow = rows[i];
					const int32_t e = a_dense[erow];
					const int32_t prow = pos_is_anchor ? erow : posc->set.row_of(e);
					const int32_t vrow = vel_is_anchor ? erow : velc->set.row_of(e);
					if (prow < 0 || vrow < 0) continue;
					p[prow] += v[vrow] * d;
				}
			});
		}
		n = int64_t(rows.size());
	}
	return n;
}

// ---------------------------------------------------------------------------
// ECSCore — 调试统计
// ---------------------------------------------------------------------------

Dictionary ECSCore::debug_stats() const {
	Dictionary d;
	d["components"] = int64_t(components_.size());
	d["entity_pool"] = int64_t(versions_.size());
	d["threads"] = int64_t(thread_count_);
	d["workers_started"] = workers_started_;
	Array comp_counts;
	for (const auto &c : components_) {
		comp_counts.append(int64_t(c.set.size()));
	}
	d["component_counts"] = comp_counts;
	return d;
}

// ---------------------------------------------------------------------------
// ECSCore — 序列化/反序列化
// ---------------------------------------------------------------------------

Dictionary ECSCore::serialize() const {
	Dictionary root;
	root["version"] = int64_t(1);
	Array comps;
	for (const auto &c : components_) {
		Dictionary cd;
		cd["name"] = c.name;
		// 字段描述
		Array farr;
		Array fnames_arr;
		Array ftypes_arr;
		Array fdefaults_arr;
		for (size_t fi = 0; fi < c.fields.size(); ++fi) {
			fnames_arr.append(c.fields[fi].name);
			ftypes_arr.append(int64_t(c.fields[fi].type));
			fdefaults_arr.append(c.defaults[fi]);
		}
		cd["field_names"] = fnames_arr;
		cd["field_types"] = ftypes_arr;
		cd["defaults"] = fdefaults_arr;
		// 实体数据: 稀疏集 dense 里的实体 + 各字段值
		// 注意: 列按"dense 行号"索引(紧凑), 用行号 r 取值!
		Array entities;
		const auto &dense = c.set.dense;
		for (int32_t r = 0; r < int32_t(dense.size()); ++r) {
			const int32_t e = dense[r];
			if (is_prefab_index(e)) {
				continue; // 不序列化 prefab 模板
			}
			Dictionary ed;
			ed["entity"] = e;
			Array vals;
			for (size_t fi = 0; fi < c.columns.size(); ++fi) {
				vals.append(c.columns[fi].get(r));
			}
			ed["values"] = vals;
			entities.append(ed);
		}
		cd["entities"] = entities;
		comps.append(cd);
	}
	root["components"] = comps;
	root["pool_size"] = int64_t(versions_.size());
	return root;
}

Array ECSCore::deserialize(const Dictionary &data) {
	Array result; // 新建实体的实体 ID 列表
	if (!data.has("components")) {
		return result;
	}
	// 第一遍: 收集所有需要创建的实体 ID 集合(按出现顺序)
	std::vector<int32_t> entity_ids;
	{
		Array comps = data["components"];
		for (int32_t i = 0; i < comps.size(); ++i) {
			Dictionary cd = comps[i];
			Array entities = cd["entities"];
			for (int32_t j = 0; j < entities.size(); ++j) {
				Dictionary ed = entities[j];
				const int32_t saved_id = int32_t(int64_t(ed["entity"]));
				bool seen = false;
				for (int32_t e : entity_ids) {
					if (e == saved_id) {
						seen = true;
						break;
					}
				}
				if (!seen) {
					entity_ids.push_back(saved_id);
				}
			}
		}
	}
	// 建立 存档ID -> 新实体ID 映射, 并创建实体
	std::unordered_map<int32_t, int32_t> id_map;
	id_map.reserve(entity_ids.size());
	for (int32_t saved_id : entity_ids) {
		const int32_t new_id = create_entity();
		id_map[saved_id] = new_id;
		result.append(new_id); // 返回真实实体 ID
	}

	// 第二遍: 填充组件数据
	Array comps = data["components"];
	for (int32_t i = 0; i < comps.size(); ++i) {
		Dictionary cd = comps[i];
		const StringName name = cd["name"];
		ECSComponentData *c = find_comp(name);
		if (c == nullptr) {
			continue;
		}
		Array entities = cd["entities"];
		for (int32_t j = 0; j < entities.size(); ++j) {
			Dictionary ed = entities[j];
			const int32_t saved_id = int32_t(int64_t(ed["entity"]));
			auto it = id_map.find(saved_id);
			if (it == id_map.end()) {
				continue;
			}
			const int32_t index = it->second & 0x00FFFFFF;
			c->push_row(index); // 列按行号紧凑: 追加一行
			Array vals = ed["values"];
			const int32_t nv = int32_t(vals.size());
			const int32_t row = c->set.row_of(index);
			for (int32_t fi = 0; fi < int32_t(c->columns.size()); ++fi) {
				if (fi < nv) {
					c->columns[fi].set(row, vals[fi]);
				} else {
					c->columns[fi].set(row, c->defaults[fi]);
				}
			}
		}
	}
	// push_row 直接填充不经过 add_component → 重建签名视图
	rebuild_signatures();
	return result;
}

// ---------------------------------------------------------------------------
// ECSCore — Prefab 预制体
// ---------------------------------------------------------------------------

inline bool ECSCore::is_prefab_index(int32_t index) const {
	for (int32_t p : prefab_indices_) {
		if (p == index) {
			return true;
		}
	}
	return false;
}

int32_t ECSCore::create_prefab() {
	const int32_t e = create_entity();
	const int32_t index = e & 0x00FFFFFF;
	prefab_indices_.push_back(index);
	return e;
}

bool ECSCore::is_prefab(int32_t entity) const {
	if (!is_alive(entity)) {
		return false;
	}
	return is_prefab_index(entity & 0x00FFFFFF);
}

bool ECSCore::prefab_add(int32_t prefab, const StringName &comp, const Dictionary &values) {
	if (!is_prefab(prefab)) {
		return false;
	}
	// 给模板挂组件
	if (!add_component(prefab, comp)) {
		return false;
	}
	// 设置初始字段值
	Array keys = values.keys();
	for (int i = 0; i < keys.size(); ++i) {
		const StringName field = StringName(keys[i]);
		set_field(prefab, comp, field, values[keys[i]]);
	}
	return true;
}

Array ECSCore::instantiate(int32_t prefab, int32_t count, const Dictionary &overrides) {
	Array result;
	if (!is_prefab(prefab) || count <= 0) {
		return result;
	}
	const int32_t pindex = prefab & 0x00FFFFFF;

	// 收集 prefab 拥有的组件索引
	std::vector<int32_t> comps;
	for (int32_t ci = 0; ci < int32_t(components_.size()); ++ci) {
		if (components_[ci].set.has(pindex)) {
			comps.push_back(ci);
		}
	}

	for (int32_t n = 0; n < count; ++n) {
		const int32_t e = create_entity();
		const int32_t eindex = e & 0x00FFFFFF;
		result.append(e);
		for (int32_t ci : comps) {
			ECSComponentData &c = components_[ci];
			const int32_t prow = c.set.row_of(pindex); // prefab 行号
			// 挂组件: 列按行号紧凑追加
			c.push_row(eindex);
			const int32_t row = c.set.row_of(eindex);
			// 复制每字段值(带 overrides 覆盖)
			for (size_t fi = 0; fi < c.columns.size(); ++fi) {
				Variant v = c.columns[fi].get(prow); // 从 prefab 行取
				// 检查 overrides: {comp_name: {field_name: value}}
				if (overrides.has(c.name)) {
					Dictionary od = overrides[c.name];
					if (od.has(c.fields[fi].name)) {
						v = od[c.fields[fi].name];
					}
				}
				c.columns[fi].set(row, v);
			}
		}
	}
	// push_row 直接填充不经过 add_component → 重建签名视图
	rebuild_signatures();
	return result;
}

Variant ECSCore::prefab_get_field(int32_t prefab, const StringName &comp, const StringName &field) const {
	if (!is_prefab(prefab)) {
		return Variant();
	}
	return get_field(prefab, comp, field);
}

// ---------------------------------------------------------------------------
// ECSCore — Command Buffer (延迟结构变更)
// 系统内排队, flush_commands() 帧末统一执行, 避免遍历中改结构。
// ---------------------------------------------------------------------------

void ECSCore::cmd_create() {
	cmd_types_.push_back(CMD_CREATE);
	// 新一批命令开始时重置占位索引(保证占位 = -(create序号+1) 从 1 开始)
	if (cmd_types_.size() == 1) {
		cmd_created_.clear();
	}
	// 负句柄 = -(create序号+1), 便于后续 add_component 引用
	const int32_t idx = int32_t(cmd_created_.size());
	cmd_entities_.push_back(-(idx + 1));
	cmd_created_.push_back(-1);
	cmd_comps_.push_back(StringName());
}

void ECSCore::cmd_destroy(int32_t entity) {
	cmd_types_.push_back(CMD_DESTROY);
	cmd_entities_.push_back(entity);
	cmd_comps_.push_back(StringName());
}

void ECSCore::cmd_add_component(int32_t entity, const StringName &comp) {
	cmd_types_.push_back(CMD_ADD_COMP);
	cmd_entities_.push_back(entity);
	cmd_comps_.push_back(comp);
}

void ECSCore::cmd_remove_component(int32_t entity, const StringName &comp) {
	cmd_types_.push_back(CMD_REMOVE_COMP);
	cmd_entities_.push_back(entity);
	cmd_comps_.push_back(comp);
}

int32_t ECSCore::pending_command_count() const {
	return int32_t(cmd_types_.size());
}

// 供 GDScript 查询: 第 index 个 create 命令 flush 后生成的实体 ID(未 flush 返回 -1)
int32_t ECSCore::created_entity_at(int32_t index) const {
	if (index < 0 || index >= int32_t(cmd_created_.size())) {
		return -1;
	}
	return cmd_created_[index];
}

void ECSCore::flush_commands() {
	if (cmd_types_.empty()) {
		return;
	}
	// 第一遍: 执行 create, 把占位句柄替换为真实实体 ID, 并记录映射
	// create 占位句柄 = -(create序号+1)
	{
		size_t create_idx = 0;
		for (size_t i = 0; i < cmd_types_.size(); ++i) {
			if (cmd_types_[i] == CMD_CREATE) {
				const int32_t e = create_entity();
				cmd_entities_[i] = e;
				if (create_idx < cmd_created_.size()) {
					cmd_created_[create_idx] = e;
				}
				++create_idx;
			}
		}
	}
	// 第二遍: 解析占位句柄, 执行其他命令
	for (size_t i = 0; i < cmd_types_.size(); ++i) {
		if (cmd_types_[i] == CMD_CREATE) {
			continue; // 已处理
		}
		int32_t e = cmd_entities_[i];
		if (e < 0) {
			// 负句柄: 引用之前第 (|e|-1) 个 create 生成的实体
			const int32_t ci = -e - 1;
			if (ci >= 0 && ci < int32_t(cmd_created_.size())) {
				e = cmd_created_[ci];
			} else {
				continue; // 无效句柄
			}
		}
		switch (cmd_types_[i]) {
			case CMD_DESTROY:
				if (e >= 0 && is_alive(e)) {
					destroy_entity(e);
				}
				break;
			case CMD_ADD_COMP:
				if (e >= 0 && is_alive(e)) {
					add_component(e, cmd_comps_[i]);
				}
				break;
			case CMD_REMOVE_COMP:
				if (e >= 0 && is_alive(e)) {
					remove_component(e, cmd_comps_[i]);
				}
				break;
			default:
				break;
		}
	}
	cmd_types_.clear();
	cmd_entities_.clear();
	cmd_comps_.clear();
	// cmd_created_ 保留: 供 created_entity_at 查询本次生成的实体, 下次 cmd_create 时重置
}

// ---------------------------------------------------------------------------
// ECSCore — 绑定
// ---------------------------------------------------------------------------

void ECSCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("register_component", "name", "fnames", "ftypes", "fdefaults"), &ECSCore::register_component);
	ClassDB::bind_method(D_METHOD("create_entity"), &ECSCore::create_entity);
	ClassDB::bind_method(D_METHOD("is_alive", "entity"), &ECSCore::is_alive);
	ClassDB::bind_method(D_METHOD("destroy_entity", "entity"), &ECSCore::destroy_entity);
	ClassDB::bind_method(D_METHOD("add_component", "entity", "comp"), &ECSCore::add_component);
	ClassDB::bind_method(D_METHOD("has_component", "entity", "comp"), &ECSCore::has_component);
	ClassDB::bind_method(D_METHOD("remove_component", "entity", "comp"), &ECSCore::remove_component);
	ClassDB::bind_method(D_METHOD("count_entities", "comp"), &ECSCore::count_entities);
	ClassDB::bind_method(D_METHOD("get_entity_components", "entity"), &ECSCore::get_entity_components);
	ClassDB::bind_method(D_METHOD("query_rows", "anchor", "must", "without"), &ECSCore::query_rows);
	ClassDB::bind_method(D_METHOD("query_rows_aligned", "anchor", "must", "without"), &ECSCore::query_rows_aligned);
	ClassDB::bind_method(D_METHOD("query_rows_aligned_where", "anchor", "must", "without", "conditions", "comps"), &ECSCore::query_rows_aligned_where);
	ClassDB::bind_method(D_METHOD("entity_of_row", "comp", "row"), &ECSCore::entity_of_row);
	ClassDB::bind_method(D_METHOD("get_field", "entity", "comp", "field"), &ECSCore::get_field);
	ClassDB::bind_method(D_METHOD("set_field", "entity", "comp", "field", "value"), &ECSCore::set_field);
	ClassDB::bind_method(D_METHOD("get_column", "comp", "field"), &ECSCore::get_column);
	ClassDB::bind_method(D_METHOD("set_column", "comp", "field", "values"), &ECSCore::set_column);
	ClassDB::bind_method(D_METHOD("get_columns", "comps_fields"), &ECSCore::get_columns);
	ClassDB::bind_method(D_METHOD("set_columns", "values"), &ECSCore::set_columns);
	ClassDB::bind_method(D_METHOD("borrow_columns", "comps_fields"), &ECSCore::borrow_columns);
	ClassDB::bind_method(D_METHOD("return_columns", "borrowed"), &ECSCore::return_columns);
	ClassDB::bind_method(D_METHOD("is_column_borrowed"), &ECSCore::is_column_borrowed);
	ClassDB::bind_method(D_METHOD("batch_apply_col", "anchor", "must", "op_comp", "op_field", "src_comp", "src_field", "op", "factor", "addend", "conditions"), &ECSCore::batch_apply_col);
	ClassDB::bind_method(D_METHOD("batch_clamp_where", "anchor", "must", "op_comp", "op_field", "min_comp", "min_field", "max_comp", "max_field", "conditions"), &ECSCore::batch_clamp_where);
	ClassDB::bind_method(D_METHOD("batch_apply", "anchor", "must", "op_comp", "op_field", "op", "factor", "addend"), &ECSCore::batch_apply);
	ClassDB::bind_method(D_METHOD("batch_apply_where", "anchor", "must", "op_comp", "op_field", "op", "factor", "addend", "conditions"), &ECSCore::batch_apply_where);
	ClassDB::bind_method(D_METHOD("batch_count", "anchor", "must", "conditions"), &ECSCore::batch_count);
	ClassDB::bind_method(D_METHOD("batch_clamp", "anchor", "must", "op_comp", "op_field", "min_comp", "min_field", "max_comp", "max_field"), &ECSCore::batch_clamp);
	ClassDB::bind_method(D_METHOD("batch_vec_add", "anchor", "must", "pos_comp", "pos_field", "vel_comp", "vel_field", "delta"), &ECSCore::batch_vec_add);
	ClassDB::bind_method(D_METHOD("debug_stats"), &ECSCore::debug_stats);
	ClassDB::bind_method(D_METHOD("set_thread_count", "count"), &ECSCore::set_thread_count);
	ClassDB::bind_method(D_METHOD("run_systems_parallel", "systems"), &ECSCore::run_systems_parallel);
	ClassDB::bind_method(D_METHOD("serialize"), &ECSCore::serialize);
	ClassDB::bind_method(D_METHOD("deserialize", "data"), &ECSCore::deserialize);
	ClassDB::bind_method(D_METHOD("create_prefab"), &ECSCore::create_prefab);
	ClassDB::bind_method(D_METHOD("is_prefab", "entity"), &ECSCore::is_prefab);
	ClassDB::bind_method(D_METHOD("prefab_add", "prefab", "comp", "values"), &ECSCore::prefab_add);
	ClassDB::bind_method(D_METHOD("instantiate", "prefab", "count", "overrides"), &ECSCore::instantiate);
	ClassDB::bind_method(D_METHOD("prefab_get_field", "prefab", "comp", "field"), &ECSCore::prefab_get_field);
	ClassDB::bind_method(D_METHOD("cmd_create"), &ECSCore::cmd_create);
	ClassDB::bind_method(D_METHOD("cmd_destroy", "entity"), &ECSCore::cmd_destroy);
	ClassDB::bind_method(D_METHOD("cmd_add_component", "entity", "comp"), &ECSCore::cmd_add_component);
	ClassDB::bind_method(D_METHOD("cmd_remove_component", "entity", "comp"), &ECSCore::cmd_remove_component);
	ClassDB::bind_method(D_METHOD("flush_commands"), &ECSCore::flush_commands);
	ClassDB::bind_method(D_METHOD("pending_command_count"), &ECSCore::pending_command_count);
	ClassDB::bind_method(D_METHOD("created_entity_at", "index"), &ECSCore::created_entity_at);
	ClassDB::bind_method(D_METHOD("row_of_entity", "comp", "entity"), &ECSCore::row_of_entity);
}
