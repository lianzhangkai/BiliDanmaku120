# BiliDanmaku120 0.3.2 DanmakuClockProbe

本版根据 0.3.1 实测继续迭代：

- VID 正常，因此继续 **不 Hook 全局 CADisplayLink**，避免和 BiliVideoFPS120 冲突
- 0.3.1 的 `DMK 120/120` 来自 `BFCCRONRenderViewV2::mainOnDisplayLink:`，说明我们抓到了一个稳定的 120Hz BFC 渲染 tick
- 2x/3x 时弹幕仍然加速，说明 `CALayer.speed` 不是这版 B站控制弹幕速度的入口

## 0.3.2 改动

1. 删除无效的 `BFCCRONRenderViewV2.layer.speed -> 1x` 修改，避免做无意义的运行时写操作
2. 保留 0.3.1 已验证正常的 DMK tick 计数和状态栏显示
3. **只读 Hook** `BFCCRONRenderViewV2::_updateSyncForTimeStep:`，不修改参数，只把 time-step 样本写入日志
4. 周期扫描运行时中新加载的候选类名：
   - danmaku / danmu
   - barrage / bullet
   - comment
   - subtitle / marquee
5. 对候选类只转储与运动和时钟有关的方法/property/ivar，不安装泛化 Hook
6. 日志上限约 256KB

## 为什么先做这一版

目前不能把 `BFCCRONRenderViewV2::_updateSyncForTimeStep:` 直接除以 2 或 3，因为这个类很可能同时参与视频渲染。直接改它有再次影响 VID、造成视频卡顿/不同步的风险。

0.3.2 的目的，是确认：

- `_updateSyncForTimeStep:` 在 1x / 2x / 3x 下是否变成约 1 倍 / 2 倍 / 3 倍的 timestep
- B站真正负责弹幕运动的类叫什么、有哪些 time/speed/progress/position 方法

拿到这两个信息后，下一版才可以把：

- 弹幕出现时机：继续跟视频 media time
- 弹幕进入屏幕后的横向运动：改成 1x wall-clock

真正拆开。

## 测试建议

打开弹幕较多的视频，按顺序测试约 5 秒：

1. 1x
2. 2x
3. 3x
4. 回 1x

然后上传：

`Bilibili Data Container/Documents/BiliDanmaku120.log`

重点会看到：

- `STEP sample ... value=...`
- `CANDIDATE NEW ...`
- `CLASS ... methods=... props=... ivars=...`

## 编译

```bash
make clean package FINALPACKAGE=1 messages=yes
```
