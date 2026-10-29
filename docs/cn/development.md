# 开发指南

## 首页歌单布局与首字母提示

首页区域标题旁可选择自动、横向滑动、宫格或纵向列表，选择只保存在本机。自动模式沿用手机轮播、宽屏宫格；所有布局显示歌曲数量。设置 → 外观 → 首页歌单网格提供「显示电台区块」开关，默认开启，关闭后隐藏整个首页电台区块；偏好保存在本机，可随时重新开启。此处也配置每行数量和显示行数，手机宫格也生效，宽度不足时自动减列。全部行数和纵向列表最多续拉约 200 个歌单，完整集合从「查看全部」进入。

歌单详情保留歌曲序号；连续同首字母仅在第一行的序号上方显示字母。中文取拼音首字母，英文统一大写，数字、符号及其他文字归入 `#`。提示随当前排序和搜索变化，不修改歌名或歌单顺序。拖动滚动条时显示「首字母 · 当前歌名」及「序号 / 总数」，按实际列表布局计算当前行；多选和手动排序仍使用复选框与拖动手柄。

AI 任务的连续执行、验证证据、跨仓库 Issue 排查和经验复盘见 [AI 开发流程](ai-development.md)，经验保存在仓库根 `LESSONS.md`。提交、推送、发布和 Issue 写操作按明确授权执行。

## 导航与插件

入口：设置 → 扩展 → 导航与插件。页面按「插件管理 → 内置导航 → 插件导航排序」排列；曲库入口开关位于插件列表下方，外观设置不再提供重复入口。数量、首页/设置固定显示和移动端折叠提示统一放在页尾。

「显示曲库入口」只改变导航显示，不影响音乐数据。复用 `/settings/tab-config` 和同一保存状态；修改曲库开关保留全部插件显示偏好和顺序，停用插件不占导航名额。无插件时也能修改曲库入口；读取失败、保存期间或新增入口超过 12 项上限时禁用对应操作。

验证：`flutter analyze`、完整 656 项测试和嵌入 Web 构建通过；Docker Chromium 中文 1280px/390px 与英文宽屏实际操作并目测截图，真实临时后端确认曲库开关只改变入口、插件偏好与顺序完整保留，外观页无重复开关。中英西文案及生成产物同步，自审额外将外观分类说明改为「主题和显示」，避免仍指向已迁走的菜单设置。证据为 `/tmp/issue-501-navigation-flutter-{zh,en}.json` 和同前缀 PNG；原生 Flutter 设备未执行。

## GitHub 社区插件发现

入口：设置 → 扩展 → 插件商店 → 选源菜单 →「GitHub 发现」。这是独立发现页面，不作为订阅源保存；返回后保留商店的源和搜索状态，源设置按钮继续管理订阅源。

客户端直接搜索公开 `songloft-plugin` topic，校验根 `plugin.json`、同仓库更新链、哈希格式和对应稳定 Release 的 `.jsplugin.zip` 资产。支持搜索、排序、分页、刷新、GitHub 代理与限流提示；不合规和暂未验证分别计数。GitHub 请求不携带服务器登录凭据。

发现页顶部的 GitHub Token 入口支持保存、更换和清除。通过已认证的 `GET/PUT /settings/github-discovery-token` 将 Token 保存在当前服务器，客户端进入页面和主动刷新时读取；GitHub 发现仍由客户端请求。配置 Token 后，搜索和 Release API 绕过 GitHub 加速代理，直连 `https://api.github.com` 并携带 Authorization 头；代理和公开清单请求不带此 Token，认证失败不降级到代理。未配置时保留原有匿名代理流程。保存或清除会取消旧请求并重新发现，保留搜索和排序；失效 Token 显示专门提示。配置接口的请求/响应内容不进入 Flutter 调试日志。

本次 Token 与商店验证：完整 682 项测试通过；最后空源状态和取消断言修正后，`flutter analyze` 无问题、商店组件定向 15 项与嵌入 Web 构建通过。覆盖输入隐藏、保存/清除、失败保留配置、凭据日志隔离、渐进加载、凭据优先级与缓存边界。真实临时 Go 后端验证重启持久化、清除和 no-store 响应；后端完整检查通过。本批 Flutter 原生设备与浏览器尚未实测；下方 539 项与浏览器结果是此前发现功能的验证记录。

### 商店客户端请求与凭据优先级

提交前自审修正了源删除/停用后的回退、全部源删除时的旧请求取消、首条安装后迟到版本的更新提示、匿名 401 的错误分类，以及有效空源刷新后的缓存替换。完整 682 项回归通过；最后空源状态和取消断言修正后，15 项商店组件回归及静态检查通过。隔离副本撤掉保护后，6 条回归按预期失败，副本已恢复。自审阶段保持未提交；原生设备与 Flutter 浏览器未实测。

商店由独立公共 Dio 拉取注册表、includes 和清单，逐个解析、逐个显示，最多并发 8 个请求；完整清单在客户端缓存 5 分钟，搜索与分页复用缓存，主动刷新重新读源配置。取消、搜索、换源、切换服务器和卸载会作废旧进度；安装成功会就地更新行状态。已安装列表和实际安装仍走服务器，Web 跨域或连接失败保留服务器兼容回退。

每个源的 Token 优先，共享 GitHub Token 仅在没有源凭据且访问 `https://api.github.com` 时使用。共享 Token 不传给 raw 清单、第三方源、服务器回退或安装；带任一 Token 的请求绕过 GitHub 前缀代理。源清单中明确列出的插件 URL 继承源凭据，includes 仅同 origin 继承，后续 updateUrl 仅同初始清单或配置源 origin 继承。安装提交 source_url，由服务器读取当前源 Token；客户端不把旧的源凭据覆盖回服务器。服务器 HTTP 代理仅作用于回退和下载；首条结果更早可见不代表总耗时一定更短。

URL 校验在 Dart URI 规范化之前拒绝原始及编码的点路径段、反斜杠，与 Lynx 原生校验保持一致。安装成功的会话标记只用于刷新期间的状态同步；服务器列表刷新成功后会核对标记，防止其他页面卸载或替换插件后仍显示旧安装状态。

发布标签用于定位下载 URL 对应的真实 Release，不要求标签与清单版本相同；例如 `v0.17` 发布标签可配合 `0.17.0` 清单版本。仍核对下载 URL、实际 Release 标签与已上传资产，更新清单链的版本一致性检查保持生效。

详情显示版本、权限和最低宿主版本，安装前确认「未经 Roomtone 审核」；同入口冲突需确认替换，宿主版本未知或不足、已安装信息未就绪时禁用安装。复用服务器现有插件安装接口，校验格式不代表安全审核。窄屏使用详情底部弹层，宽屏使用对话框。

服务端明确返回 `dev` 时，所有插件跳过最低宿主版本检查；正式版继续比较最低版本，版本请求失败或其他无法识别的版本仍需重试。`dev` 不跳过插件校验、已安装信息检查或安装确认。

验证：静态检查、完整 539 项测试及 Web 构建通过；中英西三语在窄屏/宽屏和大字体下的组件测试通过。Docker Chromium 实跑真实 GitHub 查询（7 个仓库：3 个有效、4 个过滤）、确认前零请求、确认后单次安装及返回商店；临时真实 Go 后端查询确认安装的版本和 Release 地址。原生 Flutter 设备尚未验证。

## 环境搭建

### 基础要求

- Flutter >= 3.41.0
- Dart SDK >= 3.7.0

### 平台额外依赖

**Linux：**

```bash
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev
```

**Android：**

```bash
sdkmanager --licenses
```

需要 Android SDK、NDK、JDK 17+。

**macOS / iOS：**

- Xcode 15+
- CocoaPods：`sudo gem install cocoapods`

**Windows：**

- Visual Studio 2022（带 C++ 桌面开发工作负载）
- Windows 10 SDK

### 首次运行

```bash
flutter pub get
flutter run -d chrome --no-web-resources-cdn   # Web standalone
flutter run -d macos                            # macOS
```

后端需要先启动：在父仓库执行 `make run`（默认 `http://localhost:58091`，账号 admin/admin）。

---

## 新增 Feature 模块

项目采用 Feature-First 架构，每个功能模块遵循三层结构：

```
features/<name>/
├── data/              # API 类（HTTP 调用）+ Repository
│   ├── <name>_api.dart
│   └── <name>_repository.dart  (可选)
├── domain/            # 状态模型 + 业务逻辑
│   └── <name>_state.dart
└── presentation/      # UI 层
    ├── <name>_page.dart
    ├── providers/
    │   └── <name>_provider.dart
    └── widgets/
        └── <name>_xxx.dart
```

### Provider 命名惯例

手写 Riverpod Provider（**不使用** code generation / build_runner）：

```dart
// API 实例（无状态）
final xxxApiProvider = Provider<XxxApi>((ref) {
  final dio = ref.watch(dioProvider);
  return XxxApi(dio);
});

// 异步数据加载
final xxxDetailProvider = FutureProvider.family<Xxx, int>((ref, id) async {
  final api = ref.watch(xxxApiProvider);
  return api.getDetail(id);
});

// 有状态的业务逻辑
final xxxProvider = NotifierProvider<XxxNotifier, XxxState>(XxxNotifier.new);

// 异步有状态
final xxxListProvider = AsyncNotifierProvider<XxxListNotifier, XxxListState>(
  XxxListNotifier.new,
);
```

---

## 路由添加

路由配置在 `lib/core/router/app_router.dart`：

1. 在 `AppRoutes` 类中添加路径常量：

```dart
class AppRoutes {
  static const String myFeature = '/my-feature';
}
```

2. 在 `routerProvider` 的 `GoRouter` 中添加路由（Shell 内或独立）：

```dart
GoRoute(
  path: AppRoutes.myFeature,
  builder: (context, state) => const MyFeaturePage(),
),
```

3. 认证守卫自动工作：`redirect` 检查 `authStateProvider`，未登录时重定向到 `/login`，`/login` 路径不受守卫保护。

---

## API 对接

### HTTP 客户端

Dio 封装在 `lib/core/network/api_client.dart`：

- `dioProvider` — 带认证拦截器的 Dio 实例
- `publicDioProvider` — 无认证的 Dio（用于登录等公开接口）
- `apiClientProvider` — 高级封装（较少直接使用）

### JWT 双 Token

`AuthInterceptor`（`lib/core/network/auth_interceptor.dart`）自动处理：

- 请求时自动注入 `Authorization: Bearer <accessToken>`
- 401 响应时自动用 refreshToken 刷新
- 并发刷新保护（多个 401 只触发一次刷新）
- 刷新失败时回调 `onTokenExpired` 触发登出

### 资源 URL

`UrlHelper`（`lib/core/utils/url_helper.dart`）构建封面、音频等资源 URL，自动拼接 baseUrl + token。

### 新增 API 类

```dart
class MyFeatureApi {
  final Dio _dio;
  MyFeatureApi(this._dio);

  Future<MyModel> getData(int id) async {
    final response = await _dio.get('/api/v1/my-feature/$id');
    return MyModel.fromJson(response.data);
  }
}
```

---

## 条件导入

Web 平台不支持某些原生功能（如 WebView），使用条件导入 stub 文件模式：

```dart
// plugin_webview_page.dart（入口文件）
export 'plugin_webview_page_stub.dart'
    if (dart.library.io) 'plugin_webview_page_native.dart';
```

```dart
// plugin_webview_page_stub.dart（Web 平台 — 显示占位或替代 UI）
class PluginWebViewPage extends StatelessWidget { ... }

// plugin_webview_page_native.dart（原生平台 — 使用 WebView）
class PluginWebViewPage extends StatelessWidget { ... }
```

项目中使用此模式的文件：

- `plugin_webview_page.dart` / `_native.dart` / `_stub.dart`
- `plugin_tab_page.dart` / `_native.dart` / `_stub.dart`
- `web_cache_clearer.dart` / `_stub.dart`

---

## Lint 规则

`analysis_options.yaml` 中的关键规则：

| 规则 | 说明 |
|------|------|
| `prefer_const_constructors` | Widget 实例化时尽量加 `const` |
| `prefer_const_declarations` | 可以为 `const` 的变量声明为 `const` |
| `prefer_single_quotes` | 统一使用单引号 |
| `avoid_print` | 禁止 `print()`，使用 `debugPrint()` |

排除规则：`*.g.dart` 和 `*.freezed.dart` 不检查。

---

## 测试

```bash
flutter test                                    # 运行全部测试
flutter test test/core/env/tv_detector_test.dart # 运行单个文件
```

测试文件放在 `test/` 下，对应 `lib/` 的路径结构。

### GitHub 发现：跨仓库发布包（2026-10-08）

允许清单的下载地址和公开更新清单来自其他 GitHub 仓库。客户端按下载地址验证目标仓库的稳定 Release 和真实非空资产，保留版本、入口、哈希和 URL 校验。详情显示下载地址，安装确认显示发布包来源；已安装与更新状态按实际发布包仓库判断。

### GitHub 发现：根清单空哈希（2026-10-08）

根目录 plugin.json 的 entryHash、zipHash 可省略或留空；非空值继续校验格式。发现页不要求构建产物哈希回写到源码根清单，实际安装包仍由服务器校验。
