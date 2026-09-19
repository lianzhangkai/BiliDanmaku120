# BiliDanmaku120 0.2.1 — NormalSpeed120

目标已经从“弹幕跟着视频倍速跑”改成：

- 视频 1x / 2x / 3x 都可以正常播放
- 弹幕运动速度尽量固定在正常 1x
- 弹幕刷新仍尽量使用 120Hz，让慢速移动也更顺滑

## 这一版怎么做

1. 延续 0.1.0 的弹幕 CADisplayLink 识别与 120Hz 解锁
2. 扫描运行时的 danmaku / danmu / barrage / bullet 类
3. 重点兼容 `BarrageRenderer` / `BarrageClock` 这种常见弹幕引擎
4. 对经过签名验证、且参数为 arm64 `CGFloat(double)` 的 `setSpeed:` / `setRate:` / `setPlaybackRate:` / `setTimeScale:` 做定点 Hook
5. 只有当传入值处于 `>1.0 && <=4.0` 时才改成 `1.0`
   - 2x -> 1x
   - 3x -> 1x
   - 0 / pause 不碰
   - <=1x 不碰
   - 100 / 300 这类像素速度不碰

因此它不是全局修改动画速度，而是尽量只截获“弹幕逻辑时钟的倍速系数”。

## 状态栏

显示大致为：

`DMK 118/120 1x`

- `DMK 118/120`：检测到的弹幕 callback FPS / 屏幕最大 FPS
- `1x`：本插件的弹幕速度上限目标

## 最关键的测试

找一个弹幕明显、容易观察滚动速度的视频：

1. 1x 播放观察弹幕速度
2. 切 2x，视频应明显加速，但弹幕横向速度应基本保持 1x
3. 长按 3x，同样观察弹幕是否仍保持正常速度
4. 观察 DMK 是否仍接近 120

### 如果成功

日志会出现类似：

`SPEED HOOK OK class=BarrageRenderer selector=setSpeed:`

随后切倍速时：

`SPEED CAP class=BarrageRenderer sel=setSpeed: 2.000 -> 1.000`

### 如果弹幕仍跟视频一起加速

不要继续盲改。请发送：

`Bilibili 数据容器/Documents/BiliDanmaku120.log`

这一版会记录实际加载的弹幕类及其 speed/rate/time/clock/update/tick 等方法，我们据此做下一版的精确 Hook。

## 编译

```bash
make clean package FINALPACKAGE=1 messages=yes
```

目标环境仍是：

- iPadOS 13.7
- arm64 + old-ABI arm64e
- Odyssey / libhooker
- Theos + iOS 13.7 SDK


## 0.2.1 编译修正

针对 iOS 13.7 SDK + 旧 clang/Werror 修复两处：

- 不再直接把函数指针 `IMP` 传给 `NSValue valueWithPointer:`，改为通过 `uintptr_t`/`NSNumber` 保存和恢复
- 不再从外部直接访问 `GTDDisplayLinkProxy` 的私有 ivar `_frameCount`，改为类内原子 getter

功能逻辑与 0.2.0 保持一致。
