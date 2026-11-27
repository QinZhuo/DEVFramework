# 场景索引

框架自带的可运行示例。`*Demo.tscn` 可按 F6 直接运行；`ECS*Demo` 系列统一从 `ECSDemoHub` 进（各演示是一个"模式"）。
命令行：`godot --path . Scenes/<模块>/<名字>.tscn`；或用 MCP `game_control(action=start, scene="res://Scenes/...")`。

| 场景 | 演示什么 |
|---|---|
| `ECS/ECSDemo.tscn` | 四种实现方式对比（左下按钮切换，表格显示各实现耗时/帧率） |
| `ECS/ECSNodeDemo.tscn` | 三层架构：ECS 与 Godot 节点配合的完整方案 |
| `ECS/impl_query.tscn` | 查询链实现的场景化世界（根节点挂 `DemoQueryWorld`，继承 `World`） |
| `ECSDemo/ECSDemoHub.tscn` | **ECS 演示唯一入口**：下方各演示作为模式挂进来 |
| `ECSDemo/ECSStressDemo.tscn` | 压力对比：同一份"移动 + 生死"循环，ECS vs 普通 Node |
| `ECSDemo/ECSRollbackDemo.tscn` | 确定性与回滚（联机 lockstep / 格斗 rollback 的最小验证） |
| `ECSDemo/ECSSpatialDemo.tscn` | 空间索引（RTS/弹幕原型：英雄周围 200 像素内有多少单位） |
| `ECSDemo/ECSMultiMeshDemo.tscn` | MultiMesh 批量渲染对照：同一份数据，两条显式路径 |
| `ECSDemo/ECSBarrage3DDemo.tscn` | 3D 弹幕：四个模块串成一条真实链路 |
| `AI/GoapDemo.tscn` | GOAP 目标规划（2D 生态箱，观察代理自主选择动作顺序） |
| `Dialogue/DialogueDemo.tscn` | 对话子系统全部能力：单行提示、多行脚本、锚点跟随、插槽、定位策略 |
| `GameCommand/GameCommandDemo.tscn` | 命令模式 + 输入源回放（3 列取宝藏，tick 轮询模型） |
| `Tutorial/TutorialDemo.tscn` | 教程引导：遮罩聚焦、气泡、步骤推进（表现全部交给 `FocusMask`） |
| `Nav/NavPlayer.tscn` | 导航主场景：玩家 + 障碍 + 巡逻 NPC，点击地面移动 |
| `Nav/NavPatrolNPC.tscn` / `Nav/NavObstacle.tscn` | `NavPlayer` 引用的子场景：三态 AI NPC / 可移动动态障碍 |
| `View/PoolDemo.tscn` / `View/PoolDemoCard.tscn` | 对象池复用（滚动列表看实例被反复复用，不新建） |
| `Lightmap/LightmapDemo.tscn` | 资产光照贴图展厅：同一份烘焙光在不同材质上的反应 |
| `Lightmap/LightmapBake.tscn` | 烘焙舞台（只在编辑器里用，运行时永不实例化） |

新增演示：场景与脚本放 `Scenes/<模块>/`，并在上表补一行。脚本与场景同目录；示例业务对象放 `res://Scripts/`。
