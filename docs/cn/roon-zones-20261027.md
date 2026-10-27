# 区域名称、编组与转移面板验证（2026-10-27）

对象：Roomtone 父仓库 `708ec132`、Flutter 子仓库 `152c8d0` 加未提交工作树；Windows amd64，本机嵌入 Flutter Web。未提交、推送或发布。

## 行为

- 区域设置的音频设备旁增加“修改音箱名称”。单音箱区域与音箱名称双向同步；旧数据恢复与编组前对齐已有区域名，自动发现不覆盖用户名称。
- 多音箱区域使用链接图标；区域选择器逐行显示成员名称，播放条显示“首个成员 + N”。输出设置、派对、闹钟目标、DSP 成员等也使用实际名称。
- 编组音量弹层每台设备有独立滑杆、静音与 ±1。单台调整只写该台并保存相对基准的偏移；底部整体 ±1 保留偏移，全部静音保留原音量。
- 转换区域对话框上方显示当前区域成员和歌曲，下方显示可接收的实际音箱/区域；离线目标禁用。成功转移后焦点跟随目标，错误留在对话框。
- speaker_seen、group_changed、member_changed 事件触发合并刷新的设备/区域快照，改名可同步到已打开的页面。

## 证据与边界

- 输出模块 35 项测试通过，其中新增 4 项覆盖编组名称、成员独立音量与组音量差、静音、转移目标与焦点、音箱改名。相关 Dart 静态分析与 release Web 构建通过（既有 Cupertino 字体提示不影响构建）。
- 后端 app/player 定向测试与 vet 通过；新增改名回归验证重新发现、重启、区域与音箱双向同步和编组后的名称保留。
- 浏览器实际操作了名称编辑保存、两台 EDIFIER 静止状态编组、成员名称/短名称、音量布局及转换区域列表。截图在本机工具目录 `roon-group-selector.png`、`roon-group-volume.png`、`roon-transfer-zones.png`。
- 用户要求“不再测试播放”后没有点击播放或执行真实播放转移。真机独立音量/静音与播放转移的声音验收 Not run；组件测试使用内存 API，不代表新的听感验收。

## 改名故障复盘

首次只增加音箱改名入口，仍保留了独立的 group.name 与 player.Name。用户在区域名称里保存“餐厅”后，编组成员和音量等读取 player.Name 的页面仍显示出厂名。修正为单音箱区域共用名称，并核对全部显示入口与事件刷新。不能只检查编辑框保存成功便宣称“改名完成”。

后续：用户实际转移后发现音量面板缓存旧成员（日志为目标 9764 组内 PATCH 9EC4，404）。新增区域 key、代次检查及成员集合变化刷新，清除旧防抖提交；两项回归覆盖换区域与同组拆成员。最新输出模块 37 项测试通过，相关分析无问题，更新后浏览器音量面板对应 9764 且不再显示旧成员错误；没有点击音量或播放。截图 `volume-target-fixed.png`。


## 窄屏队列与远端重复起播（2026-10-27）

验证对象：Flutter 基线 `152c8d0` 加当前未提交工作树，Windows / Flutter 3.47.0-0.1.pre，本机嵌入 Web。

- 根因：AdaptiveScaffold 的 mobile 分支没有渲染 playlistDrawer。现在队列覆盖手机内容区，保留底部播放控制与导航，支持关闭。
- 根因：远端 playPlaylist 的队列构建递归调用仍进入 `_playCurrent`，会自动播放浏览器音源；playSong 的 autoPlay:false 也会加载浏览器媒体。现在远端队列构建不加载任何本机媒体，播放只发往所选区域。
- 切到远端即失效本机加载代次并调用音频 handler.pause（包括尚未报告 playing 的加载和 HLS）；远端镜像不再被浏览器 HLS/时长事件覆盖。较慢的旧区域请求不能覆盖新焦点的队列。
- 回归覆盖：320/446/599px 队列开关、远端单曲/整队列不加载音源、加载未完成时切换区域、乱序返回的区域队列；同时检查现有播放/输出与侧栏布局测试。旧胶囊测试中两项对标准播放器的假设已更新为现有 Roon 队列按钮和 104px 布局。
- 命令：`dart format lib/ test/`，`flutter test test/features/player test/features/playback test/features/output test/shared/layouts/adaptive_scaffold_queue_test.dart test/shared/layouts/adaptive_scaffold_sidebar_test.dart test/shared/layouts/adaptive_scaffold_reparent_test.dart`；`flutter analyze --no-pub`。
- 分析结果：无新增诊断；现有两项 unawaited_return_in_try_block warning 和 alarms_page unnecessary_import info 共三项。原生平台及多音箱互相关同步：Not run。


最终检查：363 项通过；本次六个实现/测试文件的 `dart analyze` 无问题；`git diff --check` 通过。Web release 构建通过并嵌入本机 Go dev 二进制。实测窄屏约 440px 可打开、关闭和操作队列；在 Cocoon 焦点下从列表起播英语音频，Cocoon state=playing（song_id=2），Web state=idle、空队列，DOM 中没有 audio/video 元素，且无本地 SongloftAudioHandler.playSong 调用。测试后暂停并恢复原队列/下标/位置。当前听感未要求用户再次确认；不把状态/媒体检查当作新的听感验收。

最终构建的队列内切歌复核：Cocoon song_id=5、state=playing，Web song_id=0、state=idle，当前曲目总时长更新为 04:05；DOM 媒体元素与本地加载日志仍为空。证据：`C:/Users/leon/.local/roomtone-tools/narrow-remote-proof.json`、`narrow-queue-fixed.png`。已通过 API 断言恢复原 8 首队列、下标 3、位置 62.2211278 秒及 paused 状态。
