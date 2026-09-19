# BiliDanmaku120 0.3.1 — ExactTickLayerProbe

这一版针对当前实测结果：

- BiliVideoFPS120 的 VID 已恢复正常
- 0.3.0/0.2.2 的通用 `speed/rate` setter 猜测没有让 2x/3x 弹幕减速
- `DMK --/120` 说明上一版的 tick ABI 判断没有命中

## 0.3.1 改动

### 1. 修复 DMK 统计路线

不再只认 `BFCCommentFrameRateBooster -_displayLinkTick` 的无参数形式。按优先级只 Hook **一个**真实回调：

1. `BFCCRONRenderViewV2 -mainOnDisplayLink:`
2. `BFCCRONRenderViewV2 -onDisplayLink:`
3. `BFCCommentFrameRateBooster -_displayLinkTick`
4. `BFCDisplayLink -displayLinkDidRefresh:`

支持经过运行时验证的两种 ABI：

- `void()`
- `void(id)`

只选一个回调，避免同一帧被重复计数。

### 2. 仍然不碰全局 CADisplayLink

120Hz 提升继续交给 BiliVideoFPS120。这个插件不 Hook 系统 `CADisplayLink`，也不碰 IJK / `display_pixels:`，避免再次导致 VID 变成 `--`。

### 3. 弹幕减速：只做一个低风险 layer-speed 实验

如果 `BFCCRONRenderViewV2` 自己的 `CALayer.speed` 被 B站设成 2/3，0.3.1 会在其精确 display-link callback 中把它恢复成 1.0，并尽量保持当前 layer local time 连续。

如果 B站实际上是根据“视频媒体时间”手工计算弹幕位置，那么这一项不会生效；这时不会继续猜 setter。

### 4. 为真正的独立弹幕时钟准备日志

仍会一次性记录以下准确类中与 `time / clock / progress / position / rate / render / frame` 有关的方法、property、ivar：

- `BFCDisplayLink`
- `BFCCRONRenderViewV2`
- `BFCCommentFrameRateBooster`

日志上限约 128KB，不持续刷 FPS。

## 预期

首先验证 `DMK` 是否由 `--/120` 变成实际数字。

如果 2x/3x 下弹幕仍然跟随视频变快，请发送新版 `Documents/BiliDanmaku120.log`。下一版将根据真实 time/clock 接口做“出现时机跟视频、横向运动按 1x wall-clock”的独立时钟。

## 编译

```bash
make clean package FINALPACKAGE=1 messages=yes
```
