# BiliDanmaku120 0.3.0 — BFCTargetSafe

根据设备日志重新设计，不再猜测 `danmaku/barrage` 类名。

日志已经明确看到 B站自己的：

- `BFCDisplayLink -displayLinkDidRefresh:`
- `BFCCRONRenderViewV2 -onDisplayLink:` / `-mainOnDisplayLink:`
- `BFCCommentFrameRateBooster -_displayLinkTick`

## 为什么 0.2.2 会让 VID 变成 --

0.2.2 仍然全局 Hook 了 `CADisplayLink` 的创建、`setPreferredFramesPerSecond:` 和 `setFrameInterval:`。而 BiliVideoFPS120 本身也 Hook `CADisplayLink`。两个 tweak 同时改系统同一类的链路没有必要，也增加了 Hook 顺序冲突的风险。

0.3.0 **完全不 Hook CADisplayLink**。120Hz 的 60->120 提升继续交给 BiliVideoFPS120；本 tweak 只处理弹幕自己的 BFC 类。

## 这一版做什么

1. 只在 ABI 严格匹配时 Hook `BFCCommentFrameRateBooster -_displayLinkTick`，统计真实弹幕更新频率，显示 `DMK xx/120`。
2. 只检查 `BFCCRONRenderViewV2` 和 `BFCCommentFrameRateBooster` 两个准确类。
3. 如果它们存在以下 setter，且签名是安全的 `void(float)` / `void(double)`，才把 `>1x && <=4x` 压回 1x：
   - `setPlaybackRate:`
   - `setSpeed:`
   - `setRate:`
   - `setTimeScale:`
   - `setTimeRate:`
4. 不扫描整个 Objective-C runtime，不碰 IJK，不碰 renderer `display_pixels:`，因此不会和 VID 计数链直接冲突。
5. 日志最大约 128KB，并且只记录类结构和少量 speed cap 事件，不会持续刷大。

## 如果弹幕仍随视频 2x/3x

这意味着 B站弹幕不是通过上述 speed/rate setter 加速，而是直接使用“视频媒体时间”计算位置。把新的 `Documents/BiliDanmaku120.log` 发回来；本版会记录上述三个 BFC 类中与 `time/rate/speed/clock/progress/position/render` 有关的方法、property 和 ivar，下一版可以精确解耦弹幕时钟。

## 编译

```bash
make clean package FINALPACKAGE=1 messages=yes
```
