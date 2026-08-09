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
	// 协作式并行(参考 Unity Job System / Flecs 无锁调度):
	//  调用线程执行一个分片(不空等), 其余分片交 worker 池, 局部 pending 计数等待。
	// 主线程系统/直接 batch 用此路径(列是自管裸内存, 多线程写不同行安全)。
	std::mutex p_mutex;
	std::condition_variable p_cv;
	int pending = 0;
	{
		std::lock_guard<std::mutex> lock(task_mutex_);
		for (size_t s = 1; s < slices; ++s) {
			const size_t begin = s * chunk;
			const size_t end = std::min(begin + chunk, n);
			if (begin >= end) {
				break;
			}
			++active_tasks_;
			++pending;
			tasks_.emplace_back([&, begin, end]() {
				fn(begin, end);
				{
					std::lock_guard<std::mutex> pl(p_mutex);
					--pending;
					// notify 必须与 --pending 同锁: 保证调用线程 wait 返回(pending==0)时,
					// 本 worker 已彻底完成(含 notify), 不会在 parallel_for 返回销毁 p_cv 后再访问。
					if (pending <= 0) {
						p_cv.notify_all();
					}
				}
			});
		}
	}
	task_cv_.notify_all();
	if (n > 0) {
		fn(0, std::min(chunk, n));
	}
	{
		std::unique_lock<std::mutex> lock(p_mutex);
		p_cv.wait(lock, [&]() { return pending <= 0; });
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
	// 全部系统任务交给 worker 池执行(含单系统: 系统逻辑不占用主线程, 主线程只提交+等待)
	{
		std::lock_guard<std::mutex> lock(task_mutex_);
		for (int32_t i = 0; i < n; ++i) {
			++active_tasks_;
			Variant sys = systems[i];
			tasks_.emplace_back([sys]() {
				Callable cb = sys;
				cb.call();
			});
		}
	}
	task_cv_.notify_all();
	// 主线程等待 worker 全部完成(系统在独立线程执行, 不阻塞主线程的其他并行工作)
	{
		std::unique_lock<std::mutex> lock(task_mutex_);
		task_cv_.wait(lock, [this]() { return active_tasks_ <= 0; });
	}
}

void ECSCore::sync_fields(const PackedInt32Array &nl_rows, const PackedInt32Array &comp_rows,
		const Array &nodes, const StringName &comp,
		const PackedStringArray &fields, const PackedStringArray &props) {
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return;
	}
	const int32_t n = nl_rows.size();
	const int32_t nf = fields.size();
	if (n <= 0 || nf <= 0) {
		return;
	}
	// 构建 comp 聚合行号 -> (arch, row) 表(与 get_column 顺序一致)
	std::vector<std::pair<int32_t, int32_t>> cref; // 聚合行号 -> (arch, row)
	for (int32_t arch = 0; arch < int32_t(archetypes_.size()); ++arch) {
		const auto &a = archetypes_[arch];
		if (!a.has_comp(ci)) {
			continue;
		}
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			cref.emplace_back(arch, r);
		}
	}
	for (int32_t i = 0; i < n; ++i) {
		const int32_t nl_row = nl_rows[i];
		if (nl_row < 0 || nl_row >= (int32_t)nodes.size()) {
			continue;
		}
		Object *obj = nodes[nl_row].operator Object *();
		if (obj == nullptr) {
			continue;
		}
		const int32_t grow = comp_rows[i];
		if (grow < 0 || grow >= (int32_t)cref.size()) {
			continue;
		}
		const auto &cr = cref[grow];
		const auto &a = archetypes_[cr.first];
		const int cp = a.comp_pos(ci);
		if (cp < 0) {
			continue;
		}
		for (int32_t fi = 0; fi < nf; ++fi) {
			const int32_t fi2 = components_[ci].field_index(fields[fi]);
			if (fi2 < 0) {
				continue;
			}
			Variant v = a.cols[cp][fi2].get(cr.second);
			obj->set(props[fi], v);
		}
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
		case Variant::INT: i32.push_back(int32_t(value)); break;
		case Variant::FLOAT: f32.push_back(float(value)); break;
		case Variant::BOOL: b.push_back(bool(value) ? 1 : 0); break;
		case Variant::VECTOR2: v2.push_back(Vector2(value)); break;
		case Variant::VECTOR3: v3.push_back(Vector3(value)); break;
		case Variant::VECTOR4: v4.push_back(Vector4(value)); break;
		case Variant::COLOR: col.push_back(Color(value)); break;
		case Variant::STRING: s.push_back(String(value)); break;
		default: break;
	}
}

void *ECSColumn::write_ptr() {
	switch (type) {
		case Variant::INT: return i32.empty() ? nullptr : i32.data();
		case Variant::FLOAT: return f32.empty() ? nullptr : f32.data();
		case Variant::BOOL: return b.empty() ? nullptr : b.data();
		case Variant::VECTOR2: return v2.empty() ? nullptr : v2.data();
		case Variant::VECTOR3: return v3.empty() ? nullptr : v3.data();
		case Variant::VECTOR4: return v4.empty() ? nullptr : v4.data();
		case Variant::COLOR: return col.empty() ? nullptr : col.data();
		case Variant::STRING: return s.empty() ? nullptr : s.data();
		default: return nullptr;
	}
}

const void *ECSColumn::read_ptr() const {
	switch (type) {
		case Variant::INT: return i32.empty() ? nullptr : i32.data();
		case Variant::FLOAT: return f32.empty() ? nullptr : f32.data();
		case Variant::BOOL: return b.empty() ? nullptr : b.data();
		case Variant::VECTOR2: return v2.empty() ? nullptr : v2.data();
		case Variant::VECTOR3: return v3.empty() ? nullptr : v3.data();
		case Variant::VECTOR4: return v4.empty() ? nullptr : v4.data();
		case Variant::COLOR: return col.empty() ? nullptr : col.data();
		case Variant::STRING: return s.empty() ? nullptr : s.data();
		default: return nullptr;
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
// 裸内存列 <-> Godot PackedArray 转换 (get_column/set_column/borrow/return 用)
// 列内部是自管 std::vector; 与 GDScript 边界处按需拷贝为 PackedArray(非零拷贝)。
// ---------------------------------------------------------------------------
static Variant col_to_packed(const ECSColumn &col) {
	switch (col.type) {
		case Variant::INT: {
			PackedInt32Array a;
			a.resize(int32_t(col.i32.size()));
			if (!col.i32.empty()) {
				memcpy(a.ptrw(), col.i32.data(), col.i32.size() * sizeof(int32_t));
			}
			return a;
		}
		case Variant::FLOAT: {
			PackedFloat32Array a;
			a.resize(int32_t(col.f32.size()));
			if (!col.f32.empty()) {
				memcpy(a.ptrw(), col.f32.data(), col.f32.size() * sizeof(float));
			}
			return a;
		}
		case Variant::BOOL: {
			PackedByteArray a;
			a.resize(int32_t(col.b.size()));
			if (!col.b.empty()) {
				memcpy(a.ptrw(), col.b.data(), col.b.size());
			}
			return a;
		}
		case Variant::VECTOR2: {
			PackedVector2Array a;
			a.resize(int32_t(col.v2.size()));
			if (!col.v2.empty()) {
				memcpy(a.ptrw(), col.v2.data(), col.v2.size() * sizeof(Vector2));
			}
			return a;
		}
		case Variant::VECTOR3: {
			PackedVector3Array a;
			a.resize(int32_t(col.v3.size()));
			if (!col.v3.empty()) {
				memcpy(a.ptrw(), col.v3.data(), col.v3.size() * sizeof(Vector3));
			}
			return a;
		}
		case Variant::VECTOR4: {
			PackedVector4Array a;
			a.resize(int32_t(col.v4.size()));
			if (!col.v4.empty()) {
				memcpy(a.ptrw(), col.v4.data(), col.v4.size() * sizeof(Vector4));
			}
			return a;
		}
		case Variant::COLOR: {
			PackedColorArray a;
			a.resize(int32_t(col.col.size()));
			if (!col.col.empty()) {
				memcpy(a.ptrw(), col.col.data(), col.col.size() * sizeof(Color));
			}
			return a;
		}
		case Variant::STRING: {
			PackedStringArray a;
			a.resize(int32_t(col.s.size()));
			for (size_t i = 0; i < col.s.size(); ++i) {
				a.set(int32_t(i), col.s[i]);
			}
			return a;
		}
		default:
			return Variant();
	}
}

static void col_from_packed(ECSColumn &col, const Variant &v) {
	switch (col.type) {
		case Variant::INT: {
			PackedInt32Array a = v;
			col.i32.resize(int32_t(a.size()));
			if (a.size() > 0) {
				memcpy(col.i32.data(), a.ptr(), a.size() * sizeof(int32_t));
			}
			break;
		}
		case Variant::FLOAT: {
			PackedFloat32Array a = v;
			col.f32.resize(int32_t(a.size()));
			if (a.size() > 0) {
				memcpy(col.f32.data(), a.ptr(), a.size() * sizeof(float));
			}
			break;
		}
		case Variant::BOOL: {
			PackedByteArray a = v;
			col.b.resize(int32_t(a.size()));
			if (a.size() > 0) {
				memcpy(col.b.data(), a.ptr(), a.size());
			}
			break;
		}
		case Variant::VECTOR2: {
			PackedVector2Array a = v;
			col.v2.resize(int32_t(a.size()));
			if (a.size() > 0) {
				memcpy(col.v2.data(), a.ptr(), a.size() * sizeof(Vector2));
			}
			break;
		}
		case Variant::VECTOR3: {
			PackedVector3Array a = v;
			col.v3.resize(int32_t(a.size()));
			if (a.size() > 0) {
				memcpy(col.v3.data(), a.ptr(), a.size() * sizeof(Vector3));
			}
			break;
		}
		case Variant::VECTOR4: {
			PackedVector4Array a = v;
			col.v4.resize(int32_t(a.size()));
			if (a.size() > 0) {
				memcpy(col.v4.data(), a.ptr(), a.size() * sizeof(Vector4));
			}
			break;
		}
		case Variant::COLOR: {
			PackedColorArray a = v;
			col.col.resize(int32_t(a.size()));
			if (a.size() > 0) {
				memcpy(col.col.data(), a.ptr(), a.size() * sizeof(Color));
			}
			break;
		}
		case Variant::STRING: {
			PackedStringArray a = v;
			col.s.resize(int32_t(a.size()));
			for (int32_t i = 0; i < a.size(); ++i) {
				col.s[i] = a[i];
			}
			break;
		}
		default:
			break;
	}
}

// 借出: 拷贝成 PackedArray 并清空内部列(独占引用, 回调写 PackedArray 后归还写回)
static Variant col_borrow_out(ECSColumn &col) {
	Variant p = col_to_packed(col);
	switch (col.type) {
		case Variant::INT: col.i32.clear(); break;
		case Variant::FLOAT: col.f32.clear(); break;
		case Variant::BOOL: col.b.clear(); break;
		case Variant::VECTOR2: col.v2.clear(); break;
		case Variant::VECTOR3: col.v3.clear(); break;
		case Variant::VECTOR4: col.v4.clear(); break;
		case Variant::COLOR: col.col.clear(); break;
		case Variant::STRING: col.s.clear(); break;
		default: break;
	}
	return p;
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

// 查找/创建 archetype(组件组合分块存储)
int32_t ECSCore::find_archetype(const std::vector<int32_t> &comps) {
	for (int32_t i = 0; i < int32_t(archetypes_.size()); ++i) {
		if (archetypes_[i].comps == comps) {
			return i;
		}
	}
	Archetype a;
	a.comps = comps;
	a.cols.resize(comps.size());
	for (size_t cp = 0; cp < comps.size(); ++cp) {
		const int32_t ci = comps[cp];
		a.cols[cp].resize(components_[ci].fields.size());
		for (size_t f = 0; f < components_[ci].fields.size(); ++f) {
			a.cols[cp][f].type = components_[ci].fields[f].type;
		}
	}
	archetypes_.push_back(std::move(a));
	return int32_t(archetypes_.size()) - 1;
}

void ECSCore::sorted_insert(std::vector<int32_t> &comps, int32_t comp) {
	auto it = std::lower_bound(comps.begin(), comps.end(), comp);
	if (it != comps.end() && *it == comp) {
		return;
	}
	comps.insert(it, comp);
}

// 从 archetype 移除实体(swap-remove + 列同步)
void ECSCore::remove_from_archetype(int32_t arch, int32_t index) {
	Archetype &a = archetypes_[arch];
	const int32_t row = a.row_of(index);
	if (row < 0) {
		return;
	}
	const int32_t last = int32_t(a.entities.size()) - 1;
	const int32_t last_e = a.entities[last];
	if (row != last) {
		a.entities[row] = last_e;
		a.row_map[last_e] = row;
		for (size_t cp = 0; cp < a.comps.size(); ++cp) {
			const int32_t ci = a.comps[cp];
			for (size_t f = 0; f < components_[ci].fields.size(); ++f) {
				ECSColumn &c = a.cols[cp][f];
				c.set(row, c.get(last));
				c.pop();
			}
		}
	} else {
		for (size_t cp = 0; cp < a.comps.size(); ++cp) {
			const int32_t ci = a.comps[cp];
			for (size_t f = 0; f < components_[ci].fields.size(); ++f) {
				a.cols[cp][f].pop();
			}
		}
	}
	a.entities.pop_back();
	a.row_map[index] = -1;
}

// 把实体迁移到目标 archetype(拷贝旧组件数据 + 新组件默认值)
void ECSCore::migrate_entity(int32_t index, int32_t src_arch, int32_t dst_arch) {
	Archetype &dst = archetypes_[dst_arch];
	const int32_t row = int32_t(dst.entities.size());
	dst.entities.push_back(index);
	if (int32_t(dst.row_map.size()) <= index) {
		dst.row_map.resize(index + 1, -1);
	}
	dst.row_map[index] = row;
	if (src_arch >= 0) {
		Archetype &src = archetypes_[src_arch];
		const int32_t src_row = src.row_of(index);
		if (src_row >= 0) {
			for (size_t cp = 0; cp < src.comps.size(); ++cp) {
				const int32_t ci = src.comps[cp];
				const int32_t dp = dst.comp_pos(ci);
				if (dp < 0) {
					continue;
				}
				for (size_t f = 0; f < components_[ci].fields.size(); ++f) {
					ECSColumn &dcol = dst.cols[dp][f];
					dcol.resize(row + 1);
					dcol.set(row, src.cols[cp][f].get(src_row));
				}
			}
		}
	}
	for (size_t cp = 0; cp < dst.comps.size(); ++cp) {
		const int32_t ci = dst.comps[cp];
		if (src_arch >= 0 && archetypes_[src_arch].has_comp(ci)) {
			continue;
		}
		const auto &comp = components_[ci];
		for (size_t f = 0; f < comp.fields.size(); ++f) {
			ECSColumn &dcol = dst.cols[cp][f];
			dcol.resize(row + 1);
			dcol.set(row, comp.defaults[f]);
		}
	}
	if (src_arch >= 0) {
		remove_from_archetype(src_arch, index);
	}
	entity_arch_[index] = dst_arch;
}

// 收集匹配 archetype(含 anchor+must, 不含 without), 返回 archetype 索引
void ECSCore::collect_archs(int32_t ai, const int32_t *mi, int32_t m,
		const int32_t *wi, int32_t w, std::vector<int32_t> &out) const {
	if (ai < 0) {
		return;
	}
	for (int32_t arch = 0; arch < int32_t(archetypes_.size()); ++arch) {
		const auto &a = archetypes_[arch];
		if (!a.has_comp(ai)) {
			continue;
		}
		bool ok = true;
		for (int32_t i = 0; i < m; ++i) {
			if (!a.has_comp(mi[i])) {
				ok = false;
				break;
			}
		}
		if (ok) {
			for (int32_t i = 0; i < w; ++i) {
				if (a.has_comp(wi[i])) {
					ok = false;
					break;
				}
			}
		}
		if (ok) {
			out.push_back(arch);
		}
	}
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
	data.defaults.resize(n);
	for (int32_t i = 0; i < n; ++i) {
		data.fields[i].name = fnames[i];
		data.fields[i].type = Variant::Type(int64_t(ftypes[i]));
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
	if (int32_t(entity_arch_.size()) <= index) {
		entity_arch_.resize(index + 1, -1);
	}
	entity_arch_[index] = -1; // 新实体无组件, 不属于任何 archetype
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
	const int32_t arch = (index < int32_t(entity_arch_.size())) ? entity_arch_[index] : -1;
	if (arch >= 0) {
		remove_from_archetype(arch, index);
	}
	entity_arch_[index] = -1;
	release_entity_id(index);
}

// ---------------------------------------------------------------------------
// ECSCore — 组件增删查 (archetype 迁移)
// ---------------------------------------------------------------------------

bool ECSCore::add_component(int32_t entity, const StringName &comp) {
	const int32_t index = entity & 0x00FFFFFF;
	const int32_t ci = comp_index(comp);
	if (ci < 0 || !is_alive(entity)) {
		return false;
	}
	const int32_t old_arch = (index < int32_t(entity_arch_.size())) ? entity_arch_[index] : -1;
	if (old_arch >= 0 && archetypes_[old_arch].has_comp(ci)) {
		return true; // 幂等
	}
	std::vector<int32_t> comps_new;
	if (old_arch >= 0) {
		comps_new = archetypes_[old_arch].comps;
	}
	sorted_insert(comps_new, ci);
	const int32_t dst = find_archetype(comps_new);
	migrate_entity(index, old_arch, dst);
	return true;
}

bool ECSCore::has_component(int32_t entity, const StringName &comp) const {
	const int32_t index = entity & 0x00FFFFFF;
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return false;
	}
	const int32_t arch = (index < int32_t(entity_arch_.size())) ? entity_arch_[index] : -1;
	return arch >= 0 && archetypes_[arch].has_comp(ci);
}

void ECSCore::remove_component(int32_t entity, const StringName &comp) {
	const int32_t index = entity & 0x00FFFFFF;
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return;
	}
	const int32_t arch = (index < int32_t(entity_arch_.size())) ? entity_arch_[index] : -1;
	if (arch < 0 || !archetypes_[arch].has_comp(ci)) {
		return;
	}
	std::vector<int32_t> comps_new;
	for (int32_t c : archetypes_[arch].comps) {
		if (c != ci) {
			comps_new.push_back(c);
		}
	}
	if (comps_new.empty()) {
		remove_from_archetype(arch, index);
		entity_arch_[index] = -1;
	} else {
		migrate_entity(index, arch, find_archetype(comps_new));
	}
}

int32_t ECSCore::count_entities(const StringName &comp) const {
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return 0;
	}
	int32_t n = 0;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ci)) {
			continue;
		}
		for (int32_t e : a.entities) {
			if (!is_prefab_index(e)) {
				++n;
			}
		}
	}
	return n;
}

PackedStringArray ECSCore::get_entity_components(int32_t entity) const {
	PackedStringArray out;
	const int32_t index = entity & 0x00FFFFFF;
	const int32_t arch = (index < int32_t(entity_arch_.size())) ? entity_arch_[index] : -1;
	if (arch < 0) {
		return out;
	}
	for (int32_t ci : archetypes_[arch].comps) {
		out.append(components_[ci].name);
	}
	return out;
}

// ---------------------------------------------------------------------------
// ECSCore — 查询
// ---------------------------------------------------------------------------

PackedInt32Array ECSCore::query_entities(const StringName &anchor, const PackedStringArray &must,
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
	// 遍历所有含 anchor 的 archetype, 收集满足 must/without 的实体 ID
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ai)) {
			continue;
		}
		bool ok = true;
		for (int32_t i = 0; i < m; ++i) {
			if (!a.has_comp(mi[i])) {
				ok = false;
				break;
			}
		}
		if (ok) {
			for (int32_t i = 0; i < w; ++i) {
				if (a.has_comp(wi[i])) {
					ok = false;
					break;
				}
			}
		}
		if (ok) {
			for (int32_t row = 0; row < int32_t(a.entities.size()); ++row) {
				if (is_prefab_index(a.entities[row])) {
					continue;
				}
				out.append(a.entities[row]);
			}
		}
	}
	return out;
}

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
	// 遍历所有含 anchor 的 archetype, 返回满足 must/without 的实体的聚合行号
	// (聚合行号 = 该组件 get_column 的索引, 跨块按 archetype 顺序累积)
	int32_t offset = 0;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ai)) {
			continue;
		}
		bool ok = true;
		for (int32_t i = 0; i < m; ++i) {
			if (!a.has_comp(mi[i])) {
				ok = false;
				break;
			}
		}
		if (ok) {
			for (int32_t i = 0; i < w; ++i) {
				if (a.has_comp(wi[i])) {
					ok = false;
					break;
				}
			}
		}
		int32_t n_nonpref = 0;
		for (int32_t row = 0; row < int32_t(a.entities.size()); ++row) {
			if (is_prefab_index(a.entities[row])) {
				continue;
			}
			if (ok) {
				out.append(offset + n_nonpref);
			}
			++n_nonpref;
		}
		offset += n_nonpref;
	}
	return out;
}

// 对齐行号查询: 返回 [anchor 聚合行号, 各 must 组件聚合行号](同一实体集合, 顺序一致)。
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
	int32_t mi[8];
	for (int32_t i = 0; i < m; ++i) {
		mi[i] = comp_index(must[i]);
	}
	PackedInt32Array anchor_rows = query_rows(anchor, must, without);
	const int32_t n = int32_t(anchor_rows.size());
	out.push_back(anchor_rows);
	// anchor 聚合行号 -> 实体表(一次 O(N), 避免逐实体 get_entity_at O(N^2))
	std::vector<int32_t> agg;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ai)) {
			continue;
		}
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	for (int32_t i = 0; i < m; ++i) {
		PackedInt32Array comp_rows;
		if (mi[i] < 0) {
			out.push_back(comp_rows);
			continue;
		}
		std::unordered_map<int32_t, int32_t> cg;
		int32_t grow = 0;
		for (const auto &a : archetypes_) {
			if (!a.has_comp(mi[i])) {
				continue;
			}
			for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
				if (is_prefab_index(a.entities[r])) {
					continue;
				}
				cg[a.entities[r]] = grow++;
			}
		}
		comp_rows.resize(n);
		for (int32_t k = 0; k < n; ++k) {
			const int32_t e = agg[anchor_rows[k]];
			auto it = cg.find(e);
			comp_rows[k] = (it != cg.end()) ? it->second : -1;
		}
		out.push_back(comp_rows);
	}
	return out;
}

// 聚合行号(某组件的 get_column 索引) -> 实体 ID
int32_t ECSCore::entity_of_row(const StringName &comp, int32_t row) const {
	return get_entity_at(comp, row);
}

// 实体 ID -> 聚合行号(该组件 get_column 索引)
int32_t ECSCore::row_of_entity(const StringName &comp, int32_t entity) const {
	const int32_t index = entity & 0x00FFFFFF;
	const int32_t arch = (index < int32_t(entity_arch_.size())) ? entity_arch_[index] : -1;
	if (arch < 0) {
		return -1;
	}
	const int32_t ci = comp_index(comp);
	if (ci < 0 || !archetypes_[arch].has_comp(ci)) {
		return -1;
	}
	// 聚合行号 = 前面含 ci 的 archetype 非 prefab 数 + 块内非 prefab 位置(快: O(块数 + 块内))
	int32_t grow = 0;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ci)) {
			continue;
		}
		if (&a == &archetypes_[arch]) {
			for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
				if (is_prefab_index(a.entities[r])) {
					continue;
				}
				if (a.entities[r] == index) {
					return grow;
				}
				++grow;
			}
			return -1;
		}
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (!is_prefab_index(a.entities[r])) {
				++grow;
			}
		}
	}
	return -1;
}

// 聚合行号 -> 实体 ID(跨块按 archetype 顺序)
int32_t ECSCore::get_entity_at(const StringName &comp, int32_t row) const {
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return -1;
	}
	int32_t grow = 0;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ci)) {
			continue;
		}
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			if (grow == row) {
				return a.entities[r];
			}
			++grow;
		}
	}
	return -1;
}

// ---------------------------------------------------------------------------
// ECSCore — 单实体字段访问
// ---------------------------------------------------------------------------

Variant ECSCore::get_field(int32_t entity, const StringName &comp, const StringName &field) const {
	const int32_t index = entity & 0x00FFFFFF;
	const int32_t arch = (index < int32_t(entity_arch_.size())) ? entity_arch_[index] : -1;
	if (arch < 0) {
		return Variant();
	}
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return Variant();
	}
	const auto &a = archetypes_[arch];
	const int cp = a.comp_pos(ci);
	if (cp < 0) {
		return Variant();
	}
	const int fi = components_[ci].field_index(field);
	if (fi < 0) {
		return Variant();
	}
	const int32_t row = a.row_of(index);
	if (row < 0) {
		return Variant();
	}
	return a.cols[cp][fi].get(row);
}

void ECSCore::set_field(int32_t entity, const StringName &comp, const StringName &field, const Variant &value) {
	const int32_t index = entity & 0x00FFFFFF;
	const int32_t arch = (index < int32_t(entity_arch_.size())) ? entity_arch_[index] : -1;
	if (arch < 0) {
		return;
	}
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return;
	}
	auto &a = archetypes_[arch];
	const int cp = a.comp_pos(ci);
	if (cp < 0) {
		return;
	}
	const int fi = components_[ci].field_index(field);
	if (fi < 0) {
		return;
	}
	const int32_t row = a.row_of(index);
	if (row < 0) {
		return;
	}
	a.cols[cp][fi].set(row, value);
}

// ---------------------------------------------------------------------------
// ECSCore — 批量列访问 (零拷贝)
// ---------------------------------------------------------------------------

// 跨块列聚合: 含 ci 的 archetype 块按序拼接非 prefab 实体值(get_column 索引 = 聚合顺序)
// 跨块列聚合: 含 ci 的 archetype 块按序拼接非 prefab 实体值(get_column 索引 = 聚合顺序)
Variant ECSCore::column_aggregate(int32_t ci, int32_t fi) const {
	const Variant::Type t = components_[ci].fields[fi].type;
	struct Blk {
		const Archetype *a;
		int cp;
	};
	std::vector<Blk> blocks;
	size_t total = 0;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ci)) {
			continue;
		}
		const int cp = a.comp_pos(ci);
		int cnt = 0;
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (!is_prefab_index(a.entities[r])) {
				++cnt;
			}
		}
		if (cnt > 0) {
			blocks.push_back({&a, cp});
			total += size_t(cnt);
		}
	}
	// 无 prefab 块整块 memcpy(快路径)
	auto has_pref = [this](const Archetype &a) {
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				return true;
			}
		}
		return false;
	};
	switch (t) {
		case Variant::INT: {
			PackedInt32Array a;
			a.resize(int32_t(total));
			int32_t *dst = a.ptrw();
			size_t idx = 0;
			for (const auto &b : blocks) {
				const auto &col = b.a->cols[b.cp][fi].i32;
				if (!has_pref(*b.a)) {
					memcpy(dst + idx, col.data(), col.size() * sizeof(int32_t));
					idx += col.size();
				} else {
					for (int32_t r = 0; r < int32_t(b.a->entities.size()); ++r) {
						if (is_prefab_index(b.a->entities[r])) {
							continue;
						}
						dst[idx++] = col[r];
					}
				}
			}
			return a;
		}
		case Variant::FLOAT: {
			PackedFloat32Array a;
			a.resize(int32_t(total));
			float *dst = a.ptrw();
			size_t idx = 0;
			for (const auto &b : blocks) {
				const auto &col = b.a->cols[b.cp][fi].f32;
				if (!has_pref(*b.a)) {
					memcpy(dst + idx, col.data(), col.size() * sizeof(float));
					idx += col.size();
				} else {
					for (int32_t r = 0; r < int32_t(b.a->entities.size()); ++r) {
						if (is_prefab_index(b.a->entities[r])) {
							continue;
						}
						dst[idx++] = col[r];
					}
				}
			}
			return a;
		}
		case Variant::BOOL: {
			PackedByteArray a;
			a.resize(int32_t(total));
			uint8_t *dst = a.ptrw();
			size_t idx = 0;
			for (const auto &b : blocks) {
				const auto &col = b.a->cols[b.cp][fi].b;
				if (!has_pref(*b.a)) {
					memcpy(dst + idx, col.data(), col.size());
					idx += col.size();
				} else {
					for (int32_t r = 0; r < int32_t(b.a->entities.size()); ++r) {
						if (is_prefab_index(b.a->entities[r])) {
							continue;
						}
						dst[idx++] = col[r];
					}
				}
			}
			return a;
		}
		case Variant::VECTOR2: {
			PackedVector2Array a;
			a.resize(int32_t(total));
			Vector2 *dst = a.ptrw();
			size_t idx = 0;
			for (const auto &b : blocks) {
				const auto &col = b.a->cols[b.cp][fi].v2;
				if (!has_pref(*b.a)) {
					memcpy(dst + idx, col.data(), col.size() * sizeof(Vector2));
					idx += col.size();
				} else {
					for (int32_t r = 0; r < int32_t(b.a->entities.size()); ++r) {
						if (is_prefab_index(b.a->entities[r])) {
							continue;
						}
						dst[idx++] = col[r];
					}
				}
			}
			return a;
		}
		case Variant::VECTOR3: {
			PackedVector3Array a;
			a.resize(int32_t(total));
			Vector3 *dst = a.ptrw();
			size_t idx = 0;
			for (const auto &b : blocks) {
				const auto &col = b.a->cols[b.cp][fi].v3;
				if (!has_pref(*b.a)) {
					memcpy(dst + idx, col.data(), col.size() * sizeof(Vector3));
					idx += col.size();
				} else {
					for (int32_t r = 0; r < int32_t(b.a->entities.size()); ++r) {
						if (is_prefab_index(b.a->entities[r])) {
							continue;
						}
						dst[idx++] = col[r];
					}
				}
			}
			return a;
		}
		case Variant::VECTOR4: {
			PackedVector4Array a;
			a.resize(int32_t(total));
			Vector4 *dst = a.ptrw();
			size_t idx = 0;
			for (const auto &b : blocks) {
				const auto &col = b.a->cols[b.cp][fi].v4;
				if (!has_pref(*b.a)) {
					memcpy(dst + idx, col.data(), col.size() * sizeof(Vector4));
					idx += col.size();
				} else {
					for (int32_t r = 0; r < int32_t(b.a->entities.size()); ++r) {
						if (is_prefab_index(b.a->entities[r])) {
							continue;
						}
						dst[idx++] = col[r];
					}
				}
			}
			return a;
		}
		case Variant::COLOR: {
			PackedColorArray a;
			a.resize(int32_t(total));
			Color *dst = a.ptrw();
			size_t idx = 0;
			for (const auto &b : blocks) {
				const auto &col = b.a->cols[b.cp][fi].col;
				if (!has_pref(*b.a)) {
					memcpy(dst + idx, col.data(), col.size() * sizeof(Color));
					idx += col.size();
				} else {
					for (int32_t r = 0; r < int32_t(b.a->entities.size()); ++r) {
						if (is_prefab_index(b.a->entities[r])) {
							continue;
						}
						dst[idx++] = col[r];
					}
				}
			}
			return a;
		}
		case Variant::STRING: {
			PackedStringArray a;
			a.resize(int32_t(total));
			size_t idx = 0;
			for (const auto &b : blocks) {
				const auto &col = b.a->cols[b.cp][fi].s;
				for (int32_t r = 0; r < int32_t(b.a->entities.size()); ++r) {
					if (is_prefab_index(b.a->entities[r])) {
						continue;
					}
					a.set(int32_t(idx++), col[r]);
				}
			}
			return a;
		}
		default:
			return Variant();
	}
}

// 跨块列拆回: 聚合 PackedArray 按序写回各块(与 column_aggregate 顺序一致)
void ECSCore::column_scatter(int32_t ci, int32_t fi, const Variant &values) {
	const Variant::Type t = components_[ci].fields[fi].type;
	size_t idx = 0;
	auto has_pref = [this](const Archetype &a) {
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				return true;
			}
		}
		return false;
	};
	for (auto &a : archetypes_) {
		if (!a.has_comp(ci)) {
			continue;
		}
		const int cp = a.comp_pos(ci);
		auto &col = a.cols[cp][fi];
		if (!has_pref(a)) {
			switch (t) {
				case Variant::INT: {
					PackedInt32Array p = values;
					memcpy(col.i32.data(), p.ptr() + idx, col.i32.size() * sizeof(int32_t));
					idx += col.i32.size();
					break;
				}
				case Variant::FLOAT: {
					PackedFloat32Array p = values;
					memcpy(col.f32.data(), p.ptr() + idx, col.f32.size() * sizeof(float));
					idx += col.f32.size();
					break;
				}
				case Variant::BOOL: {
					PackedByteArray p = values;
					memcpy(col.b.data(), p.ptr() + idx, col.b.size());
					idx += col.b.size();
					break;
				}
				case Variant::VECTOR2: {
					PackedVector2Array p = values;
					memcpy(col.v2.data(), p.ptr() + idx, col.v2.size() * sizeof(Vector2));
					idx += col.v2.size();
					break;
				}
				case Variant::VECTOR3: {
					PackedVector3Array p = values;
					memcpy(col.v3.data(), p.ptr() + idx, col.v3.size() * sizeof(Vector3));
					idx += col.v3.size();
					break;
				}
				case Variant::VECTOR4: {
					PackedVector4Array p = values;
					memcpy(col.v4.data(), p.ptr() + idx, col.v4.size() * sizeof(Vector4));
					idx += col.v4.size();
					break;
				}
				case Variant::COLOR: {
					PackedColorArray p = values;
					memcpy(col.col.data(), p.ptr() + idx, col.col.size() * sizeof(Color));
					idx += col.col.size();
					break;
				}
				default: {
					for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
						Variant v;
				switch (values.get_type()) {
					case Variant::INT: { PackedInt32Array p = values; v = Variant(int64_t(p[int32_t(idx)])); break; }
					case Variant::FLOAT: { PackedFloat32Array p = values; v = Variant(double(p[int32_t(idx)])); break; }
					case Variant::BOOL: { PackedByteArray p = values; v = Variant(bool(p[int32_t(idx)])); break; }
					case Variant::VECTOR2: { PackedVector2Array p = values; v = Variant(Vector2(p[int32_t(idx)])); break; }
					case Variant::VECTOR3: { PackedVector3Array p = values; v = Variant(Vector3(p[int32_t(idx)])); break; }
					case Variant::VECTOR4: { PackedVector4Array p = values; v = Variant(Vector4(p[int32_t(idx)])); break; }
					case Variant::COLOR: { PackedColorArray p = values; v = Variant(Color(p[int32_t(idx)])); break; }
					case Variant::STRING: { PackedStringArray p = values; v = Variant(p[int32_t(idx)]); break; }
					default: v = Variant();
				}
				++idx;
						col.set(r, v);
					}
					break;
				}
			}
		} else {
			for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
				if (is_prefab_index(a.entities[r])) {
					continue;
				}
				Variant v;
				switch (values.get_type()) {
					case Variant::INT: { PackedInt32Array p = values; v = Variant(int64_t(p[int32_t(idx)])); break; }
					case Variant::FLOAT: { PackedFloat32Array p = values; v = Variant(double(p[int32_t(idx)])); break; }
					case Variant::BOOL: { PackedByteArray p = values; v = Variant(bool(p[int32_t(idx)])); break; }
					case Variant::VECTOR2: { PackedVector2Array p = values; v = Variant(Vector2(p[int32_t(idx)])); break; }
					case Variant::VECTOR3: { PackedVector3Array p = values; v = Variant(Vector3(p[int32_t(idx)])); break; }
					case Variant::VECTOR4: { PackedVector4Array p = values; v = Variant(Vector4(p[int32_t(idx)])); break; }
					case Variant::COLOR: { PackedColorArray p = values; v = Variant(Color(p[int32_t(idx)])); break; }
					case Variant::STRING: { PackedStringArray p = values; v = Variant(p[int32_t(idx)]); break; }
					default: v = Variant();
				}
				++idx;
				col.set(r, v);
			}
		}
	}
}
void ECSCore::set_columns(const Dictionary &values) {
	Array keys = values.keys();
	for (int32_t i = 0; i < keys.size(); ++i) {
		const int32_t ci = comp_index(StringName(keys[i]));
		if (ci < 0) {
			continue;
		}
		Dictionary fields = values[keys[i]];
		Array fkeys = fields.keys();
		for (int32_t j = 0; j < fkeys.size(); ++j) {
			const StringName fname = StringName(fkeys[j]);
			const int32_t fi = components_[ci].field_index(fname);
			if (fi < 0) {
				continue;
			}
			column_scatter(ci, fi, fields[fname]);
		}
	}
}


Variant ECSCore::get_column(const StringName &comp, const StringName &field) const {
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return Variant();
	}
	const int fi = components_[ci].field_index(field);
	if (fi < 0) {
		return Variant();
	}
	return column_aggregate(ci, fi);
}

Dictionary ECSCore::get_columns(const Array &comps_fields) const {
	Dictionary out;
	for (int32_t i = 0; i < comps_fields.size(); ++i) {
		Dictionary cf = comps_fields[i];
		const int32_t ci = comp_index(StringName(cf["comp"]));
		if (ci < 0) {
			continue;
		}
		Dictionary fields_dict;
		Array fields = cf["fields"];
		for (int32_t j = 0; j < fields.size(); ++j) {
			const StringName fname = StringName(fields[j]);
			const int32_t fi = components_[ci].field_index(fname);
			if (fi < 0) {
				continue;
			}
			fields_dict[fname] = column_aggregate(ci, fi);
		}
		out[components_[ci].name] = fields_dict;
	}
	return out;
}

Dictionary ECSCore::borrow_columns(const Array &comps_fields) {
	_borrow_count_.fetch_add(1);
	Dictionary out;
	for (int32_t i = 0; i < comps_fields.size(); ++i) {
		Dictionary cf = comps_fields[i];
		const int32_t ci = comp_index(StringName(cf["comp"]));
		if (ci < 0) {
			continue;
		}
		Dictionary fields_dict;
		Array fields = cf["fields"];
		for (int32_t j = 0; j < fields.size(); ++j) {
			const StringName fname = StringName(fields[j]);
			const int32_t fi = components_[ci].field_index(fname);
			if (fi < 0) {
				continue;
			}
			fields_dict[fname] = column_aggregate(ci, fi);
		}
		out[components_[ci].name] = fields_dict;
	}
	return out;
}

void ECSCore::return_columns(const Dictionary &borrowed) {
	_borrow_count_.fetch_sub(1);
	Array keys = borrowed.keys();
	for (int32_t i = 0; i < keys.size(); ++i) {
		const int32_t ci = comp_index(StringName(keys[i]));
		if (ci < 0) {
			continue;
		}
		Dictionary fields = borrowed[keys[i]];
		Array fkeys = fields.keys();
		for (int32_t j = 0; j < fkeys.size(); ++j) {
			const StringName fname = StringName(fkeys[j]);
			const int32_t fi = components_[ci].field_index(fname);
			if (fi < 0) {
				continue;
			}
			column_scatter(ci, fi, fields[fname]);
		}
	}
}

bool ECSCore::is_column_borrowed() const {
	return _borrow_count_.load() > 0;
}

void ECSCore::set_column(const StringName &comp, const StringName &field, const Variant &values) {
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return;
	}
	const int fi = components_[ci].field_index(field);
	if (fi < 0) {
		return;
	}
	column_scatter(ci, fi, values);
}

// 单实体标量/分量列操作(batch 用)
bool ECSCore::batch_apply_entity(int32_t entity, int32_t oci, int32_t ofi, int32_t op_axis,
		int64_t op, double factor, double addend) {
	const int32_t earch = entity_arch_[entity];
	if (earch < 0) {
		return false;
	}
	const int32_t erow = archetypes_[earch].row_of(entity);
	if (erow < 0) {
		return false;
	}
	const int cp = archetypes_[earch].comp_pos(oci);
	if (cp < 0) {
		return false;
	}
	auto &col = archetypes_[earch].cols[cp][ofi];
	switch (col.type) {
		case Variant::INT: {
			int32_t &w = col.i32[erow];
			switch (op) {
				case BATCH_ADD: w += int32_t(addend); break;
				case BATCH_MUL_ADD: w = int32_t(double(w) * factor + addend); break;
				case BATCH_SET: w = int32_t(addend); break;
				default: break;
			}
			break;
		}
		case Variant::FLOAT: {
			float &w = col.f32[erow];
			switch (op) {
				case BATCH_ADD: w += float(addend); break;
				case BATCH_MUL_ADD: w = float(double(w) * factor + addend); break;
				case BATCH_SET: w = float(addend); break;
				default: break;
			}
			break;
		}
		case Variant::VECTOR2: {
			if (op_axis >= 0 && op_axis < 2) {
				float &w = col.v2[erow][op_axis];
				switch (op) {
					case BATCH_ADD: w += float(addend); break;
					case BATCH_MUL_ADD: w = float(double(w) * factor + addend); break;
					case BATCH_SET: w = float(addend); break;
					default: break;
				}
			}
			break;
		}
		case Variant::VECTOR3: {
			if (op_axis >= 0 && op_axis < 3) {
				float &w = col.v3[erow][op_axis];
				switch (op) {
					case BATCH_ADD: w += float(addend); break;
					case BATCH_MUL_ADD: w = float(double(w) * factor + addend); break;
					case BATCH_SET: w = float(addend); break;
					default: break;
				}
			}
			break;
		}
		default:
			break;
	}
	return true;
}

// 单实体列间操作: op 列 = op 列 OP (src 列*factor+addend)
bool ECSCore::batch_apply_entity_col(int32_t entity, int32_t oci, int32_t ofi, int32_t sci, int32_t sfi,
		int64_t op, double factor, double addend) {
	const int32_t earch = entity_arch_[entity];
	if (earch < 0) {
		return false;
	}
	const int32_t erow = archetypes_[earch].row_of(entity);
	if (erow < 0) {
		return false;
	}
	const int cp = archetypes_[earch].comp_pos(oci);
	const int scp = archetypes_[earch].comp_pos(sci);
	if (cp < 0 || scp < 0) {
		return false;
	}
	auto &ocol = archetypes_[earch].cols[cp][ofi];
	const auto &scol = archetypes_[earch].cols[scp][sfi];
	if (ocol.type == Variant::FLOAT && (scol.type == Variant::FLOAT || scol.type == Variant::INT)) {
		const double sv = (scol.type == Variant::INT) ? double(scol.i32[erow]) : double(scol.f32[erow]);
		const float v = float(sv * factor + addend);
		float &w = ocol.f32[erow];
		switch (op) {
			case COL_ADD: w += v; break;
			case COL_SUB: w -= v; break;
			case COL_MUL: w *= v; break;
			case COL_DIV: if (v != 0.0f) w /= v; break;
			case COL_SET: w = v; break;
			default: break;
		}
		return true;
	}
	if (ocol.type == Variant::INT && scol.type == Variant::INT) {
		const int32_t v = int32_t(double(scol.i32[erow]) * factor + addend);
		int32_t &w = ocol.i32[erow];
		switch (op) {
			case COL_ADD: w += v; break;
			case COL_SUB: w -= v; break;
			case COL_MUL: w *= v; break;
			case COL_DIV: if (v != 0) w /= v; break;
			case COL_SET: w = v; break;
			default: break;
		}
		return true;
	}
	if (ocol.type == Variant::VECTOR2 && scol.type == Variant::VECTOR2) {
		const float f = float(factor);
		Vector2 v = scol.v2[erow] * f;
		Vector2 &w = ocol.v2[erow];
		switch (op) {
			case COL_ADD: w += v; break;
			case COL_SUB: w -= v; break;
			case COL_MUL: w *= v; break;
			case COL_DIV: if (v.x != 0.0f && v.y != 0.0f) w /= v; break;
			case COL_SET: w = v; break;
			default: break;
		}
		return true;
	}
	if (ocol.type == Variant::VECTOR3 && scol.type == Variant::VECTOR3) {
		const float f = float(factor);
		Vector3 v = scol.v3[erow] * f;
		Vector3 &w = ocol.v3[erow];
		switch (op) {
			case COL_ADD: w += v; break;
			case COL_SUB: w -= v; break;
			case COL_MUL: w *= v; break;
			case COL_DIV: if (v.x != 0.0f && v.y != 0.0f && v.z != 0.0f) w /= v; break;
			case COL_SET: w = v; break;
			default: break;
		}
		return true;
	}
	return false;
}

// 单实体是否满足全部条件(直接读 archetype 列, 快路径)
bool ECSCore::cond_matches_entity(int32_t entity, const std::vector<ECSFilterCond> &conds) const {
	for (const auto &c : conds) {
		if (c.comp == nullptr || c.field_idx < 0) {
			return false;
		}
		const int32_t arch = entity_arch_[entity];
		if (arch < 0) {
			return false;
		}
		const int32_t ci = comp_index(c.comp->name);
		if (ci < 0 || !archetypes_[arch].has_comp(ci)) {
			return false;
		}
		const int32_t row = archetypes_[arch].row_of(entity);
		if (row < 0) {
			return false;
		}
		const int cp = archetypes_[arch].comp_pos(ci);
		if (cp < 0) {
			return false;
		}
		const auto &col = archetypes_[arch].cols[cp][c.field_idx];
		double val = 0.0;
		switch (col.type) {
			case Variant::INT: val = double(col.i32[row]); break;
			case Variant::FLOAT: val = double(col.f32[row]); break;
			case Variant::VECTOR2:
				if (c.axis >= 0 && c.axis < 2) val = double(col.v2[row][c.axis]);
				else return false;
				break;
			case Variant::VECTOR3:
				if (c.axis >= 0 && c.axis < 3) val = double(col.v3[row][c.axis]);
				else return false;
				break;
			default: return false;
		}
		switch (c.op) {
			case COND_LT: if (!(val < c.value)) return false; break;
			case COND_LE: if (!(val <= c.value)) return false; break;
			case COND_GT: if (!(val > c.value)) return false; break;
			case COND_GE: if (!(val >= c.value)) return false; break;
			case COND_EQ: if (!(val == c.value)) return false; break;
			case COND_NE: if (!(val != c.value)) return false; break;
			default: return false;
		}
	}
	return true;
}

// ---------------------------------------------------------------------------
// 条件过滤解析(namespace)
// ---------------------------------------------------------------------------
namespace {
static void split_field_axis(const String &fn, String &base, int &axis) {
	axis = -1;
	int dot = fn.find(".");
	if (dot < 0) {
		base = fn;
		return;
	}
	base = fn.substr(0, dot);
	String ax = fn.substr(dot + 1);
	axis = ax == "x" ? 0 : ax == "y" ? 1 : ax == "z" ? 2 : -1;
}

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
		String fbase;
		split_field_axis(String(d["field"]), fbase, c.axis);
		c.field_idx = c.comp->field_index(StringName(fbase));
		if (c.field_idx < 0) {
			continue;
		}
		c.op = int64_t(d.get("op", int64_t(0)));
		c.value = double(d.get("value", 0.0));
		out.push_back(c);
	}
	return int(out.size());
}
// 从聚合 PackedArray(Variant) 取第 k 个值
static Variant agg_at(const Variant &v, int32_t k) {
	switch (v.get_type()) {
		case Variant::INT: {
			PackedInt32Array p = v;
			return (k < p.size()) ? Variant(int64_t(p[k])) : Variant();
		}
		case Variant::FLOAT: {
			PackedFloat32Array p = v;
			return (k < p.size()) ? Variant(double(p[k])) : Variant();
		}
		case Variant::BOOL: {
			PackedByteArray p = v;
			return (k < p.size()) ? Variant(bool(p[k])) : Variant();
		}
		case Variant::VECTOR2: {
			PackedVector2Array p = v;
			return (k < p.size()) ? Variant(Vector2(p[k])) : Variant();
		}
		case Variant::VECTOR3: {
			PackedVector3Array p = v;
			return (k < p.size()) ? Variant(Vector3(p[k])) : Variant();
		}
		case Variant::VECTOR4: {
			PackedVector4Array p = v;
			return (k < p.size()) ? Variant(Vector4(p[k])) : Variant();
		}
		case Variant::COLOR: {
			PackedColorArray p = v;
			return (k < p.size()) ? Variant(Color(p[k])) : Variant();
		}
		case Variant::STRING: {
			PackedStringArray p = v;
			return (k < p.size()) ? Variant(p[k]) : Variant();
		}
		default:
			return Variant();
	}
}
} // namespace

// 收集满足 must/without/conditions 的 anchor 聚合行号(batch 用)
void ECSCore::collect_agg(int32_t ai, const int32_t *mi, int32_t m,
		const int32_t *wi, int32_t w, const Array &conditions,
		std::vector<int32_t> &out) const {
	out.clear();
	std::vector<ECSFilterCond> conds;
	parse_conditions(this, conditions, conds, 8);
	int32_t offset = 0;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ai)) {
			continue;
		}
		bool ok = true;
		for (int32_t i = 0; i < m; ++i) {
			if (!a.has_comp(mi[i])) {
				ok = false;
				break;
			}
		}
		if (ok) {
			for (int32_t i = 0; i < w; ++i) {
				if (a.has_comp(wi[i])) {
					ok = false;
					break;
				}
			}
		}
		int32_t np = 0;
		for (int32_t row = 0; row < int32_t(a.entities.size()); ++row) {
			if (is_prefab_index(a.entities[row])) {
				continue;
			}
			if (ok && cond_matches_entity(a.entities[row], conds)) {
				out.push_back(offset + np);
			}
			++np;
		}
		offset += np;
	}
}

// ---------------------------------------------------------------------------
// ECSCore — Tier 0: 原生批量运算 (archetype 分块)
// ---------------------------------------------------------------------------

int64_t ECSCore::batch_apply_where(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field, int64_t op,
		double factor, double addend, const Array &conditions) {
	const int32_t ai = comp_index(anchor);
	const int32_t oci = comp_index(op_comp);
	if (ai < 0 || oci < 0) {
		return 0;
	}
	String op_fbase;
	int op_axis;
	split_field_axis(String(op_field), op_fbase, op_axis);
	const int ofi = components_[oci].field_index(StringName(op_fbase));
	if (ofi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	int32_t mi[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		mi[i] = comp_index(must[i]);
	}
	std::vector<int32_t> rows;
	collect_agg(ai, mi, m > 8 ? 8 : m, nullptr, 0, conditions, rows);
	std::vector<int32_t> agg;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ai)) {
			continue;
		}
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	std::atomic<int64_t> cnt{0};
	parallel_for(size_t(rows.size()), [&](size_t b, size_t e) {
		for (size_t i = b; i < e; ++i) {
			const int32_t grow = rows[i];
			if (grow < 0 || grow >= (int32_t)agg.size()) {
				continue;
			}
			if (batch_apply_entity(agg[grow], oci, ofi, op_axis, op, factor, addend)) {
				cnt.fetch_add(1, std::memory_order_relaxed);
			}
		}
	}, 1.5);
	return cnt.load();
}

int64_t ECSCore::batch_count(const StringName &anchor, const PackedStringArray &must,
		const Array &conditions) const {
	const int32_t ai = comp_index(anchor);
	if (ai < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	int32_t mi[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		mi[i] = comp_index(must[i]);
	}
	std::vector<int32_t> rows;
	collect_agg(ai, mi, m > 8 ? 8 : m, nullptr, 0, conditions, rows);
	return int64_t(rows.size());
}

int64_t ECSCore::batch_apply(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field, int64_t op,
		double factor, double addend) {
	return batch_apply_where(anchor, must, op_comp, op_field, op, factor, addend, Array());
}

int64_t ECSCore::batch_apply_col(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field,
		const StringName &src_comp, const StringName &src_field,
		int64_t op, double factor, double addend, const Array &conditions) {
	const int32_t ai = comp_index(anchor);
	const int32_t oci = comp_index(op_comp);
	const int32_t sci = comp_index(src_comp);
	if (ai < 0 || oci < 0 || sci < 0) {
		return 0;
	}
	const int ofi = components_[oci].field_index(op_field);
	const int sfi = components_[sci].field_index(src_field);
	if (ofi < 0 || sfi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	int32_t mi[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		mi[i] = comp_index(must[i]);
	}
	std::vector<int32_t> rows;
	collect_agg(ai, mi, m > 8 ? 8 : m, nullptr, 0, conditions, rows);
	std::vector<int32_t> agg;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ai)) {
			continue;
		}
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	std::atomic<int64_t> cnt{0};
	parallel_for(size_t(rows.size()), [&](size_t b, size_t e) {
		for (size_t i = b; i < e; ++i) {
			const int32_t grow = rows[i];
			if (grow < 0 || grow >= (int32_t)agg.size()) {
				continue;
			}
			if (batch_apply_entity_col(agg[grow], oci, ofi, sci, sfi, op, factor, addend)) {
				cnt.fetch_add(1, std::memory_order_relaxed);
			}
		}
	}, 1.5);
	return cnt.load();
}

int64_t ECSCore::batch_apply_rows(const StringName &anchor, const PackedInt32Array &rows,
		const StringName &op_comp, const StringName &op_field, int64_t op,
		double factor, double addend) {
	const int32_t ai = comp_index(anchor);
	const int32_t oci = comp_index(op_comp);
	if (ai < 0 || oci < 0) {
		return 0;
	}
	String op_fbase;
	int op_axis;
	split_field_axis(String(op_field), op_fbase, op_axis);
	const int ofi = components_[oci].field_index(StringName(op_fbase));
	if (ofi < 0) {
		return 0;
	}
	std::vector<int32_t> agg;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ai)) {
			continue;
		}
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	const int32_t cnt = int32_t(rows.size());
	parallel_for(size_t(cnt), [&](size_t b, size_t e) {
		for (size_t i = b; i < e; ++i) {
			const int32_t grow = rows[i];
			if (grow < 0 || grow >= (int32_t)agg.size()) {
				continue;
			}
			batch_apply_entity(agg[grow], oci, ofi, op_axis, op, factor, addend);
		}
	}, 1.5);
	return cnt;
}

int64_t ECSCore::batch_apply_col_rows(const StringName &anchor, const PackedInt32Array &rows,
		const StringName &op_comp, const StringName &op_field,
		const StringName &src_comp, const StringName &src_field,
		int64_t op, double factor, double addend) {
	const int32_t ai = comp_index(anchor);
	const int32_t oci = comp_index(op_comp);
	const int32_t sci = comp_index(src_comp);
	if (ai < 0 || oci < 0 || sci < 0) {
		return 0;
	}
	const int ofi = components_[oci].field_index(op_field);
	const int sfi = components_[sci].field_index(src_field);
	if (ofi < 0 || sfi < 0) {
		return 0;
	}
	std::vector<int32_t> agg;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ai)) {
			continue;
		}
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	const int32_t cnt = int32_t(rows.size());
	// 快路径: 单块 + 连续全行(rows=0..cnt-1) + 无 prefab + 同组件 VECTOR2 COL_ADD → SIMD
	bool single = (cnt > 0);
	int32_t barch = -1;
	if (single) {
		for (int32_t i = 0; i < cnt; ++i) {
			const int32_t grow = rows[i];
			if (grow < 0 || grow >= (int32_t)agg.size()) {
				single = false;
				break;
			}
			const int32_t earch = entity_arch_[agg[grow]];
			if (barch < 0) {
				barch = earch;
			} else if (earch != barch) {
				single = false;
				break;
			}
		}
	}
	bool contiguous = single;
	if (contiguous) {
		for (int32_t i = 0; i < cnt; ++i) {
			if (rows[i] != i) {
				contiguous = false;
				break;
			}
		}
	}
	if (contiguous && barch >= 0 && op == COL_ADD && oci == sci) {
		auto &a = archetypes_[barch];
		bool has_pref = false;
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				has_pref = true;
				break;
			}
		}
		if (!has_pref) {
			const int cp = a.comp_pos(oci);
			const int scp = a.comp_pos(sci);
			if (cp >= 0 && scp >= 0) {
				auto &ocol = a.cols[cp][ofi];
				auto &scol = a.cols[scp][sfi];
				if (ocol.type == Variant::VECTOR2 && scol.type == Variant::VECTOR2 && op == COL_ADD) {
					float *w = reinterpret_cast<float *>(ocol.v2.data());
					const float *s = reinterpret_cast<const float *>(scol.v2.data());
					const float f = float(factor);
					const __m128 fv = _mm_set1_ps(f);
					parallel_for(size_t(cnt), [&](size_t b, size_t e) {
						size_t i = b;
						for (; i + 2 <= e; i += 2) {
							const __m128 pv = _mm_loadu_ps(w + i * 2);
							const __m128 sv = _mm_loadu_ps(s + i * 2);
							_mm_storeu_ps(w + i * 2, _mm_add_ps(pv, _mm_mul_ps(sv, fv)));
						}
						for (; i < e; ++i) {
							ocol.v2[i] += scol.v2[i] * f;
						}
					}, 3.0);
					return cnt;
				}
				if (ocol.type == Variant::FLOAT && scol.type == Variant::FLOAT
						&& (op == COL_ADD || op == COL_SET)) {
					float *w = ocol.f32.data();
					const float *s = scol.f32.data();
					const float f = float(factor);
					const float av = float(addend);
					const __m128 fv = _mm_set1_ps(f);
					const __m128 avv = _mm_set1_ps(av);
					parallel_for(size_t(cnt), [&](size_t b, size_t e) {
						size_t i = b;
						if (op == COL_ADD) {
							for (; i + 4 <= e; i += 4) {
								const __m128 sv = _mm_loadu_ps(s + i);
								const __m128 val = _mm_add_ps(_mm_mul_ps(sv, fv), avv);
								_mm_storeu_ps(w + i, _mm_add_ps(_mm_loadu_ps(w + i), val));
							}
							for (; i < e; ++i) {
								w[i] += s[i] * f + av;
							}
						} else {
							for (; i + 4 <= e; i += 4) {
								const __m128 sv = _mm_loadu_ps(s + i);
								_mm_storeu_ps(w + i, _mm_add_ps(_mm_mul_ps(sv, fv), avv));
							}
							for (; i < e; ++i) {
								w[i] = s[i] * f + av;
							}
						}
					}, 1.5);
					return cnt;
				}
				if (ocol.type == Variant::FLOAT && scol.type == Variant::INT && op == COL_ADD) {
					float *w = ocol.f32.data();
					const int32_t *s = scol.i32.data();
					const float f = float(factor);
					const float av = float(addend);
					const __m128 fv = _mm_set1_ps(f);
					const __m128 avv = _mm_set1_ps(av);
					parallel_for(size_t(cnt), [&](size_t b, size_t e) {
						size_t i = b;
						for (; i + 4 <= e; i += 4) {
							const __m128 sv = _mm_cvtepi32_ps(_mm_loadu_si128(reinterpret_cast<const __m128i *>(s + i)));
							const __m128 val = _mm_add_ps(_mm_mul_ps(sv, fv), avv);
							_mm_storeu_ps(w + i, _mm_add_ps(_mm_loadu_ps(w + i), val));
						}
						for (; i < e; ++i) {
							w[i] += float(double(s[i]) * factor + addend);
						}
					}, 1.5);
					return cnt;
				}
			}
		}
	}
	parallel_for(size_t(cnt), [&](size_t b, size_t e) {
		for (size_t i = b; i < e; ++i) {
			const int32_t grow = rows[i];
			if (grow < 0 || grow >= (int32_t)agg.size()) {
				continue;
			}
			batch_apply_entity_col(agg[grow], oci, ofi, sci, sfi, op, factor, addend);
		}
	}, 1.5);
	return cnt;
}

Array ECSCore::batch_collect(const StringName &anchor, const PackedStringArray &must,
		const PackedStringArray &without, const Array &groups) const {
	Array out;
	if (groups.size() <= 0) {
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
	for (int32_t i = 0; i < m && i < 8; ++i) {
		mi[i] = comp_index(must[i]);
	}
	for (int32_t i = 0; i < w && i < 8; ++i) {
		wi[i] = comp_index(without[i]);
	}
	const int32_t ng = int32_t(groups.size());
	std::vector<std::vector<ECSFilterCond>> all_conds(ng);
	for (int32_t gi = 0; gi < ng; ++gi) {
		parse_conditions(this, groups[gi], all_conds[gi], 8);
	}
	std::vector<PackedInt32Array> results(ng);
	int32_t offset = 0;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ai)) {
			continue;
		}
		bool ok = true;
		for (int32_t i = 0; i < m && i < 8; ++i) {
			if (!a.has_comp(mi[i])) {
				ok = false;
				break;
			}
		}
		if (ok) {
			for (int32_t i = 0; i < w && i < 8; ++i) {
				if (a.has_comp(wi[i])) {
					ok = false;
					break;
				}
			}
		}
		int32_t np = 0;
		for (int32_t row = 0; row < int32_t(a.entities.size()); ++row) {
			if (is_prefab_index(a.entities[row])) {
				continue;
			}
			const int32_t e = a.entities[row];
			if (ok) {
				for (int32_t gi = 0; gi < ng; ++gi) {
					if (all_conds[gi].empty() || cond_matches_entity(e, all_conds[gi])) {
						results[gi].append(offset + np);
					}
				}
			}
			++np;
		}
		offset += np;
	}
	for (int32_t gi = 0; gi < ng; ++gi) {
		out.push_back(results[gi]);
	}
	return out;
}

// 带条件过滤的列钳制: 仅满足条件的实体 col = clamp(col, min, max)
int64_t ECSCore::batch_clamp_where(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field,
		const StringName &min_comp, const StringName &min_field,
		const StringName &max_comp, const StringName &max_field,
		const Array &conditions) {
	const int32_t ai = comp_index(anchor);
	const int32_t oci = comp_index(op_comp);
	const int32_t nci = comp_index(min_comp);
	const int32_t xci = comp_index(max_comp);
	if (ai < 0 || oci < 0 || nci < 0 || xci < 0) {
		return 0;
	}
	const int ofi = components_[oci].field_index(op_field);
	const int nfi = components_[nci].field_index(min_field);
	const int xfi = components_[xci].field_index(max_field);
	if (ofi < 0 || nfi < 0 || xfi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	int32_t mi[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		mi[i] = comp_index(must[i]);
	}
	std::vector<int32_t> rows;
	collect_agg(ai, mi, m > 8 ? 8 : m, nullptr, 0, conditions, rows);
	std::vector<int32_t> agg;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ai)) {
			continue;
		}
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	std::atomic<int64_t> cnt{0};
	parallel_for(size_t(rows.size()), [&](size_t b, size_t e) {
		for (size_t i = b; i < e; ++i) {
			const int32_t grow = rows[i];
			if (grow < 0 || grow >= (int32_t)agg.size()) {
				continue;
			}
			const int32_t en = agg[grow];
			const int32_t earch = entity_arch_[en];
			if (earch < 0) {
				continue;
			}
			const int32_t erow = archetypes_[earch].row_of(en);
			if (erow < 0) {
				continue;
			}
			const int cp = archetypes_[earch].comp_pos(oci);
			const int ncp = archetypes_[earch].comp_pos(nci);
			const int xcp = archetypes_[earch].comp_pos(xci);
			if (cp < 0 || ncp < 0 || xcp < 0) {
				continue;
			}
			auto &ocol = archetypes_[earch].cols[cp][ofi];
			const auto &minc = archetypes_[earch].cols[ncp][nfi];
			const auto &maxc = archetypes_[earch].cols[xcp][xfi];
			if (ocol.type == Variant::FLOAT && minc.type == Variant::FLOAT && maxc.type == Variant::FLOAT) {
				ocol.f32[erow] = std::clamp(ocol.f32[erow], minc.f32[erow], maxc.f32[erow]);
			} else if (ocol.type == Variant::INT && minc.type == Variant::INT && maxc.type == Variant::INT) {
				ocol.i32[erow] = std::clamp(ocol.i32[erow], minc.i32[erow], maxc.i32[erow]);
			}
			cnt.fetch_add(1, std::memory_order_relaxed);
		}
	}, 1.0);
	return cnt.load();
}

int64_t ECSCore::batch_clamp(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field,
		const StringName &min_comp, const StringName &min_field,
		const StringName &max_comp, const StringName &max_field) {
	return batch_clamp_where(anchor, must, op_comp, op_field,
			min_comp, min_field, max_comp, max_field, Array());
}

// 通用移动原语: pos += vel*delta, 越界回弹(vel 翻转, pos 钳制)
int64_t ECSCore::batch_vec_add(const StringName &anchor, const PackedStringArray &must,
		const StringName &pos_comp, const StringName &pos_field,
		const StringName &vel_comp, const StringName &vel_field, double delta) {
	const int32_t ai = comp_index(anchor);
	const int32_t pci = comp_index(pos_comp);
	const int32_t vci = comp_index(vel_comp);
	if (ai < 0 || pci < 0 || vci < 0) {
		return 0;
	}
	const int pfi = components_[pci].field_index(pos_field);
	const int vfi = components_[vci].field_index(vel_field);
	if (pfi < 0 || vfi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	int32_t mi[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		mi[i] = comp_index(must[i]);
	}
	std::vector<int32_t> rows;
	collect_agg(ai, mi, m > 8 ? 8 : m, nullptr, 0, Array(), rows);
	std::vector<int32_t> agg;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ai)) {
			continue;
		}
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	parallel_for(size_t(rows.size()), [&](size_t b, size_t e) {
		for (size_t i = b; i < e; ++i) {
			const int32_t grow = rows[i];
			if (grow < 0 || grow >= (int32_t)agg.size()) {
				continue;
			}
			const int32_t en = agg[grow];
			const int32_t earch = entity_arch_[en];
			if (earch < 0) {
				continue;
			}
			const int32_t erow = archetypes_[earch].row_of(en);
			if (erow < 0) {
				continue;
			}
			const int pcp = archetypes_[earch].comp_pos(pci);
			const int vcp = archetypes_[earch].comp_pos(vci);
			if (pcp < 0 || vcp < 0) {
				continue;
			}
			auto &pcol = archetypes_[earch].cols[pcp][pfi];
			const auto &vcol = archetypes_[earch].cols[vcp][vfi];
			if (pcol.type == Variant::VECTOR2 && vcol.type == Variant::VECTOR2) {
				pcol.v2[erow] += vcol.v2[erow] * float(delta);
			} else if (pcol.type == Variant::VECTOR3 && vcol.type == Variant::VECTOR3) {
				pcol.v3[erow] += vcol.v3[erow] * float(delta);
			}
		}
	}, 3.0);
	return int64_t(rows.size());
}

int64_t ECSCore::batch_move(const StringName &anchor, const PackedStringArray &must,
		const StringName &pos_comp, const StringName &pos_field,
		const StringName &vel_comp, const StringName &vel_field,
		double delta, double x_min, double x_max, double y_min, double y_max) {
	const int32_t ai = comp_index(anchor);
	const int32_t pci = comp_index(pos_comp);
	const int32_t vci = comp_index(vel_comp);
	if (ai < 0 || pci < 0 || vci < 0) {
		return 0;
	}
	const int pfi = components_[pci].field_index(pos_field);
	const int vfi = components_[vci].field_index(vel_field);
	if (pfi < 0 || vfi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	int32_t mi[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		mi[i] = comp_index(must[i]);
	}
	std::vector<int32_t> rows;
	collect_agg(ai, mi, m > 8 ? 8 : m, nullptr, 0, Array(), rows);
	std::vector<int32_t> agg;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ai)) {
			continue;
		}
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	parallel_for(size_t(rows.size()), [&](size_t b, size_t e) {
		for (size_t i = b; i < e; ++i) {
			const int32_t grow = rows[i];
			if (grow < 0 || grow >= (int32_t)agg.size()) {
				continue;
			}
			const int32_t en = agg[grow];
			const int32_t earch = entity_arch_[en];
			if (earch < 0) {
				continue;
			}
			const int32_t erow = archetypes_[earch].row_of(en);
			if (erow < 0) {
				continue;
			}
			const int pcp = archetypes_[earch].comp_pos(pci);
			const int vcp = archetypes_[earch].comp_pos(vci);
			if (pcp < 0 || vcp < 0) {
				continue;
			}
			auto &pcol = archetypes_[earch].cols[pcp][pfi];
			auto &vcol = archetypes_[earch].cols[vcp][vfi];
			if (pcol.type != Variant::VECTOR2 || vcol.type != Variant::VECTOR2) {
				continue;
			}
			Vector2 &p = pcol.v2[erow];
			Vector2 &v = vcol.v2[erow];
			p += v * float(delta);
			if (p.x < x_min) {
				p.x = x_min;
				v.x = -v.x;
			} else if (p.x > x_max) {
				p.x = x_max;
				v.x = -v.x;
			}
			if (p.y < y_min) {
				p.y = y_min;
				v.y = -v.y;
			} else if (p.y > y_max) {
				p.y = y_max;
				v.y = -v.y;
			}
		}
	}, 3.0);
	return int64_t(rows.size());
}

// 通用周期原语: field += dir*rate, 越界(min/max)翻转 dir
int64_t ECSCore::batch_cycle(const StringName &anchor, const PackedStringArray &must,
		const StringName &comp, const StringName &field,
		const StringName &dir_comp, const StringName &dir_field,
		double rate, double min, double max) {
	const int32_t ai = comp_index(anchor);
	const int32_t cci = comp_index(comp);
	const int32_t dci = comp_index(dir_comp);
	if (ai < 0 || cci < 0 || dci < 0) {
		return 0;
	}
	const int cfi = components_[cci].field_index(field);
	const int dfi = components_[dci].field_index(dir_field);
	if (cfi < 0 || dfi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	int32_t mi[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		mi[i] = comp_index(must[i]);
	}
	std::vector<int32_t> rows;
	collect_agg(ai, mi, m > 8 ? 8 : m, nullptr, 0, Array(), rows);
	std::vector<int32_t> agg;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ai)) {
			continue;
		}
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	parallel_for(size_t(rows.size()), [&](size_t b, size_t e) {
		for (size_t i = b; i < e; ++i) {
			const int32_t grow = rows[i];
			if (grow < 0 || grow >= (int32_t)agg.size()) {
				continue;
			}
			const int32_t en = agg[grow];
			const int32_t earch = entity_arch_[en];
			if (earch < 0) {
				continue;
			}
			const int32_t erow = archetypes_[earch].row_of(en);
			if (erow < 0) {
				continue;
			}
			const int ccp = archetypes_[earch].comp_pos(cci);
			const int dcp = archetypes_[earch].comp_pos(dci);
			if (ccp < 0 || dcp < 0) {
				continue;
			}
			auto &fcol = archetypes_[earch].cols[ccp][cfi];
			auto &dcol = archetypes_[earch].cols[dcp][dfi];
			if (fcol.type == Variant::FLOAT && dcol.type == Variant::INT) {
				float &f = fcol.f32[erow];
				f += float(double(dcol.i32[erow]) * rate);
				if (f > max) {
					f = float(max);
					dcol.i32[erow] = -dcol.i32[erow];
				} else if (f < min) {
					f = float(min);
					dcol.i32[erow] = -dcol.i32[erow];
				}
			} else if (fcol.type == Variant::FLOAT && dcol.type == Variant::FLOAT) {
				float &f = fcol.f32[erow];
				f += float(double(dcol.f32[erow]) * rate);
				if (f > max) {
					f = float(max);
					dcol.f32[erow] = -dcol.f32[erow];
				} else if (f < min) {
					f = float(min);
					dcol.f32[erow] = -dcol.f32[erow];
				}
			} else if (fcol.type == Variant::INT && dcol.type == Variant::INT) {
				int32_t &f = fcol.i32[erow];
				f += int32_t(double(dcol.i32[erow]) * rate);
				if (f > max) {
					f = int32_t(max);
					dcol.i32[erow] = -dcol.i32[erow];
				} else if (f < min) {
					f = int32_t(min);
					dcol.i32[erow] = -dcol.i32[erow];
				}
			}
		}
	}, 1.5);
	return int64_t(rows.size());
}

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
	std::vector<int32_t> rows;
	collect_agg(ai, mi, m, wi, w, conditions, rows);
	PackedInt32Array anchor_rows;
	anchor_rows.resize(int32_t(rows.size()));
	for (size_t k = 0; k < rows.size(); ++k) {
		anchor_rows.set(int32_t(k), rows[k]);
	}
	const int32_t n = int32_t(anchor_rows.size());
	out.push_back(anchor_rows);
	// anchor 聚合行号 -> 实体表(一次 O(N), 避免逐实体 get_entity_at O(N^2))
	std::vector<int32_t> agg;
	for (const auto &a : archetypes_) {
		if (!a.has_comp(ai)) {
			continue;
		}
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	for (int32_t i = 0; i < int32_t(comps.size()) && i < 8; ++i) {
		const StringName cname = comps[i];
		const int32_t cci = comp_index(cname);
		PackedInt32Array cr;
		cr.resize(n);
		if (cci >= 0) {
			std::unordered_map<int32_t, int32_t> cg;
			int32_t grow = 0;
			for (const auto &a : archetypes_) {
				if (!a.has_comp(cci)) {
					continue;
				}
				for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
					if (is_prefab_index(a.entities[r])) {
						continue;
					}
					cg[a.entities[r]] = grow++;
				}
			}
			for (int32_t k = 0; k < n; ++k) {
				const int32_t e = agg[anchor_rows[k]];
				auto it = cg.find(e);
				cr[k] = (it != cg.end()) ? it->second : -1;
			}
		}
		out.push_back(cr);
	}
	return out;
}

Dictionary ECSCore::debug_stats() const {
	Dictionary d;
	d["components"] = int64_t(components_.size());
	d["entity_pool"] = int64_t(versions_.size());
	d["threads"] = int64_t(thread_count_);
	d["workers_started"] = workers_started_;
	Array comp_counts;
	for (const auto &c : components_) {
		comp_counts.append(int64_t(count_entities(c.name)));
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
	for (size_t ci = 0; ci < components_.size(); ++ci) {
		const auto &c = components_[ci];
		Dictionary cd;
		cd["name"] = c.name;
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
		// 实体数据: 聚合实体(跨块按顺序) + 各字段聚合列值
		Array entities;
		std::vector<int32_t> agg_entities;
		for (const auto &a : archetypes_) {
			if (!a.has_comp(int32_t(ci))) {
				continue;
			}
			for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
				if (is_prefab_index(a.entities[r])) {
					continue;
				}
				agg_entities.push_back(a.entities[r]);
			}
		}
		std::vector<Variant> agg_cols(c.fields.size());
		for (size_t fi = 0; fi < c.fields.size(); ++fi) {
			agg_cols[fi] = column_aggregate(int32_t(ci), int32_t(fi));
		}
		for (size_t k = 0; k < agg_entities.size(); ++k) {
			Dictionary ed;
			ed["entity"] = int64_t(agg_entities[k]);
			Array vals;
			for (size_t fi = 0; fi < c.fields.size(); ++fi) {
				vals.append(agg_at(agg_cols[fi], int32_t(k)));
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

	// 第二遍: 填充组件数据(add_component + set_field, archetype 自动迁移)
	Array comps = data["components"];
	for (int32_t i = 0; i < comps.size(); ++i) {
		Dictionary cd = comps[i];
		const StringName name = cd["name"];
		const int32_t ci = comp_index(name);
		if (ci < 0) {
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
			const int32_t e = it->second;
			add_component(e, name);
			Array vals = ed["values"];
			for (size_t fi = 0; fi < components_[ci].fields.size(); ++fi) {
				if (fi < size_t(vals.size())) {
					set_field(e, name, components_[ci].fields[fi].name, vals[int32_t(fi)]);
				} else {
					set_field(e, name, components_[ci].fields[fi].name, components_[ci].defaults[fi]);
				}
			}
		}
	}
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
	const int32_t parch = (pindex < int32_t(entity_arch_.size())) ? entity_arch_[pindex] : -1;
	if (parch < 0) {
		return result;
	}
	const auto &par = archetypes_[parch];
	const int32_t prow = par.row_of(pindex);
	std::vector<int32_t> comps = par.comps;

	for (int32_t n = 0; n < count; ++n) {
		const int32_t e = create_entity();
		result.append(e);
		for (int32_t ci : comps) {
			const StringName cname = components_[ci].name;
			add_component(e, cname);
			const int cp = par.comp_pos(ci);
			if (cp < 0) {
				continue;
			}
			for (size_t fi = 0; fi < components_[ci].fields.size(); ++fi) {
				Variant v = par.cols[cp][fi].get(prow);
				if (overrides.has(cname)) {
					Dictionary od = overrides[cname];
					if (od.has(components_[ci].fields[fi].name)) {
						v = od[components_[ci].fields[fi].name];
					}
				}
				set_field(e, cname, components_[ci].fields[fi].name, v);
			}
		}
	}
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
	ClassDB::bind_method(D_METHOD("query_entities", "anchor", "must", "without"), &ECSCore::query_entities);
	ClassDB::bind_method(D_METHOD("query_rows_aligned", "anchor", "must", "without"), &ECSCore::query_rows_aligned);
	ClassDB::bind_method(D_METHOD("query_rows_aligned_where", "anchor", "must", "without", "conditions", "comps"), &ECSCore::query_rows_aligned_where);
	ClassDB::bind_method(D_METHOD("entity_of_row", "comp", "row"), &ECSCore::entity_of_row);
	ClassDB::bind_method(D_METHOD("get_entity_at", "comp", "row"), &ECSCore::get_entity_at);
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
	ClassDB::bind_method(D_METHOD("batch_move", "anchor", "must", "pos_comp", "pos_field", "vel_comp", "vel_field", "delta", "x_min", "x_max", "y_min", "y_max"), &ECSCore::batch_move);
	ClassDB::bind_method(D_METHOD("batch_cycle", "anchor", "must", "comp", "field", "dir_comp", "dir_field", "rate", "min", "max"), &ECSCore::batch_cycle);
	ClassDB::bind_method(D_METHOD("batch_apply", "anchor", "must", "op_comp", "op_field", "op", "factor", "addend"), &ECSCore::batch_apply);
	ClassDB::bind_method(D_METHOD("batch_apply_where", "anchor", "must", "op_comp", "op_field", "op", "factor", "addend", "conditions"), &ECSCore::batch_apply_where);
	ClassDB::bind_method(D_METHOD("batch_count", "anchor", "must", "conditions"), &ECSCore::batch_count);
	ClassDB::bind_method(D_METHOD("batch_clamp", "anchor", "must", "op_comp", "op_field", "min_comp", "min_field", "max_comp", "max_field"), &ECSCore::batch_clamp);
	ClassDB::bind_method(D_METHOD("batch_vec_add", "anchor", "must", "pos_comp", "pos_field", "vel_comp", "vel_field", "delta"), &ECSCore::batch_vec_add);
	ClassDB::bind_method(D_METHOD("batch_collect", "anchor", "must", "without", "groups"), &ECSCore::batch_collect);
	ClassDB::bind_method(D_METHOD("batch_apply_rows", "anchor", "rows", "op_comp", "op_field", "op", "factor", "addend"), &ECSCore::batch_apply_rows);
	ClassDB::bind_method(D_METHOD("batch_apply_col_rows", "anchor", "rows", "op_comp", "op_field", "src_comp", "src_field", "op", "factor", "addend"), &ECSCore::batch_apply_col_rows);
	ClassDB::bind_method(D_METHOD("debug_stats"), &ECSCore::debug_stats);
	ClassDB::bind_method(D_METHOD("set_thread_count", "count"), &ECSCore::set_thread_count);
	ClassDB::bind_method(D_METHOD("run_systems_parallel", "systems"), &ECSCore::run_systems_parallel);
	ClassDB::bind_method(D_METHOD("sync_fields", "nl_rows", "comp_rows", "nodes", "comp", "fields", "props"), &ECSCore::sync_fields);
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
