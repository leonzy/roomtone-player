# iOS 视频中断恢复与后台切歌调查

关联 [songloft-org/songloft-player#52](https://github.com/songloft-org/songloft-player/issues/52)，2026-10-26。状态：中断处理候选补丁，报告现象尚未完成原机复现或验收。

## 报告与调查边界

报告设备为 iPhone 14 Pro / iOS 16.1，包含看视频后音乐无法继续和后台播完一首不接下一首两个现象。Issue 无评论、客户端版本、日志或明确的 IPA / Safari / PWA 类型。当前调查按 Flutter 安装版建立候选，不能外推网页路径。

本地 `main` 与查询时远端一致，基线为 `538c228677350fa7c87f74bb5fe12e6e71b7ef56`；该 SHA 的既有 Build and Release 成功，不代表本次候选已构建或已发布。

## 中断链路与候选行为

原来的 Handler 与锁定的 `just_audio 0.10.6` 都监听 `AudioSession.interruptionEventStream`。逐行核对后，不能仅凭双监听推断正常中断一定无法恢复：just_audio 自己保存恢复意图，旧 Handler 的标准单次中断用例也通过。初步调查曾把双监听当作报告根因，后续已纠正。

旧 Handler 本身存在可验证的边界问题：重复 begin 覆盖原播放意图；结束时不检查类型或清理意图；用户在中断期间主动暂停仍可能被自动续播；异步暂停尚未完成就发起播放；直接调用底层播放绕过直播重连入口；配置尚未完成时销毁仍会安装迟到监听。注入的会话和播放器测试验证这些 Handler 行为，不能证明报告人在原机触发了其中某项。

候选关闭 just_audio 的自动中断处理，由 Handler 统一接管，并保留耳机拔出暂停：

- pause / unknown 开始事件保存播放意图并经正常暂停入口取消旧加载、直播重试；重复开始不覆盖。
- 只有匹配的 pause 结束事件（iOS 对应 `shouldResume`）才能恢复；unknown 结束等待用户主动播放。
- 主动暂停、停止、换源和销毁使旧恢复失效；恢复等待暂停完成，并通过正常播放入口处理直播重连。
- music 配置下 duck 不改播放意图，沿用系统 duck 行为；拔出耳机取消自动恢复。
- 记录中断类型、播放状态、停止状态及恢复决定，便于后续真机日志判别。

`audio_session` 将 iOS 开始映射为 unknown，结束按系统 `shouldResume` 映射为 pause 或 unknown。遵守其[事件契约](https://github.com/ryanheise/audio_session/blob/master/lib/src/core.dart)；不能在系统不允许恢复时承诺视频退出便自动续播。

## 后台切歌仍待定位

已检查 `UIBackgroundModes=audio`、music 会话配置、`_onSongCompleted` 的播放模式与队列推进，以及切歌前不调用 Handler.stop 的已有处理。它们均存在，不能以缺少后台声明或完成回调解释现象；单曲播放、顺序末尾和睡眠定时器也有正常停止语义。

更深一层，vendored `media_kit.open()` 仍会调用内部 stop。上游 [mpv iOS AudioUnit 驱动](https://github.com/mpv-player/mpv/blob/master/audio/out/ao_audiounit.m)的 uninit 会停用音频会话，提示需要在设备上追踪替换媒体时的输出生命周期；该上游源码不证明发布 IPA 的实际行为。本次未修改此层或加入静音保活、强制抢占会话等未经设备验证的策略。

需要确认客户端类型、版本、部署模式、播放模式，后台停止后返回是否立即切歌，以及故障时的日志。应分别检查是否收到 `completed`、是否发起下一首加载、是否发生新的中断、加载/播放是否失败。

## 验证对象与记录

- 仓库：`songloft-org/songloft-player`，上述基线 + 未提交工作树。父仓库基线 `041d34d7e9387b60ed8126022071f731a7268aa6`；其已有后端/插件改动不属于本任务。
- 环境：Linux x86_64 / Flutter 3.44.8 / Dart 3.12.2。
- 代码标识：依次连接 `lib/core/audio/audio_service.dart`、`test/core/audio/audio_interruption_test.dart` 的路径、NUL、文件内容、NUL 后计算 SHA-256，值为 `25b5207ec901f972373edd2f72fe52f26c8caef816f4f97136730db4e75e53ed`。各文件哈希在 `/tmp/songloft-player-52-20261026/validation.json`。
- 旧实现隔离：复制源码和已解析依赖位置，仅给 HEAD 的 Handler 增加会话注入参数，保留旧行为；17 项用例中 14 项按目标行为失败、3 项通过（`before-final.log`）。单次正常恢复本来就通过。最初副本缺少 package graph / 字体 / 图标，未启动用例的失败不计为反向验证。
- 检查命令：`dart format lib/ test/`（458 文件无差异）、`flutter analyze --no-pub`（无问题）、`flutter test --no-pub --concurrency=2`（791 项通过，含 17 项新增中断回归）、`git diff --check`（通过）。最终结果记录于同目录 `analyze-final.log`、`full-final.log` 和 `validation.json`。
- Not run：macOS/iOS 编译、iPhone 14 Pro / iOS 16.1 实际视频打断与恢复、后台连续切歌/长后台、Android 原生焦点与耳机拔出、其他原生平台、Safari/PWA、Bundle 本地后端及候选远端 CI。Linux 注入测试不替代这些验收。

## iPhone 验收步骤

1. 记录整包版本、部署模式和列表循环模式，选三首可正常播放的歌曲，禁用睡眠定时器。
2. 播放中打开视频应用，结束视频返回；区分系统是否发出允许恢复的结束事件。没有允许恢复时手动点播放应可恢复。
3. 中断期间从锁屏主动暂停或停止，确认结束事件不会再次播放；另测耳机拔出。
4. 返回纯音乐播放后锁屏，连续跨越至少三首歌的自然结尾；另测后台手动下一首，以及不同采样率曲目切换。
5. 若停住，先导出故障前后的日志并记录返回前台后是否立即恢复，不把暂停/顺序末尾/睡眠停止算作异常。

2026-10-26，用户授权提交、推送并回复 Issue，明确等待新包后再测试设备行为。本次提交信息为 `fix(audio): 统一中断恢复与取消边界 (Ref #52)`；main 推送触发自动 dev 构建，提交与产物状态以对应 SHA 的 CI 和 Issue 回复为准。报告现象尚未完成设备验收，保持 Issue 开放，不使用 `Fixes #52`，本次不打正式版 tag。
