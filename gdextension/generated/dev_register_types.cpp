// 由 DEVFramework 生成: 扫描 src/** 里的 GDCLASS(...) 自动注册(构建时刷新, 请勿手改)
// godot-cpp API: 4.7
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

#include "ecs_core.h"

using namespace godot;

static void dev_initialize(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(ECSCore);
}

static void dev_uninitialize(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT dev_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address, GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(dev_initialize);
	init_obj.register_terminator(dev_uninitialize);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
