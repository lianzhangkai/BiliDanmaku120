# BiliDanmaku120 0.2.2 — SafeExactSpeed

这是针对 0.2.1 启动闪退的安全重构版。

## 0.2.1 为什么风险高

0.2.1 同时做了两件比较激进的事：

1. 把疑似弹幕 `CADisplayLink` 的原始 target 替换成 proxy，再转发 callback
2. 扫描整个 Objective-C runtime，并对名字像 danmaku/danmu/barrage/bullet 的类动态安装 speed/rate hook

这两部分都可能碰到 B站自己的私有实现，因此 0.2.2 全部移除。

## 0.2.2 做什么

- 不替换 `CADisplayLink` target/selector
- 不扫描并 hook 任意 B站类
- 只识别疑似弹幕 `CADisplayLink`，请求 120Hz
- 只对精确类名 `BarrageClock` / `BarrageRenderer` 的 `setSpeed:` 尝试 hook
- hook 前必须确认签名是 arm64 下安全的 `void(double)`
- 如果 B站不用这两个类，则只记录真实弹幕类和方法，不强行修改速度

目标仍然是：视频可以 2x/3x，弹幕尽量保持 1x，同时请求 120Hz。

## 日志

路径：

`Bilibili 数据容器/Documents/BiliDanmaku120.log`

重点看：

- `DMK MATCH target=... selector=...`
- `DMK CLASS ... methods=...`
- `EXACT BarrageClock setSpeed: hook OK`
- `EXACT BarrageRenderer setSpeed: hook OK`
- `SPEED CAP ... 2.000 -> 1.000`

如果弹幕仍随视频 2x/3x 加速，把日志发回来。下一版就只针对日志中出现的真实类/selector 做 hook。

## 编译

```bash
make clean package FINALPACKAGE=1 messages=yes
```

目标：iPadOS 13.7 / arm64 + old-ABI arm64e / Odyssey + libhooker。
