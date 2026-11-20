# DouyinVCam — 抖音虚拟摄像头（TrollStore 注入）

把电脑上的 OBS 画面，作为摄像头画面送进抖音（非越狱，TrollStore + TrollFools 注入）。

```
OBS → RTMP → 电脑端(stream-relay) → WebSocket /ws 推 MJPEG → 本 dylib → 替换摄像头帧 → 抖音
```

## 目录

```
VCam.m                    全部逻辑（hook + 收帧 + 解码）
Makefile                  Theos 普通动态库工程（不是 tweak）
.github/workflows/build.yml  GitHub Actions：macOS 上自动编译并产出 dylib
```

## 一、改电脑 IP

打开 `VCam.m`，把第 26 行改成你电脑的局域网 IP：

```objc
static NSString *const kDefaultHost = @"192.168.1.42";
```

> 也可以用 NSUserDefaults 的 `vcam_host` 覆盖，但普通设备改起来麻烦，直接改代码最简单。

## 二、编译（不用 Mac）

1. 把本文件夹的所有内容推到你的 GitHub 仓库
2. 打开仓库的 **Actions** 页面，会自动跑 `build-dylib`
3. 跑完点进去，页面底部 **Artifacts** 下载 `DouyinVCam-dylib`，里面是 `DouyinVCam.dylib`

第一次大概率会报编译错误，把 Actions 里红色的日志发我，我改。

## 三、注入（手机端）

1. 确认手机已装 **TrollStore** 和 **TrollFools**（巨魔注入器）
2. 打开 TrollFools → 选 **抖音** → 注入 → 选择下载的 `DouyinVCam.dylib`
3. 完全杀掉抖音后重新打开

## 四、验证是否生效

电脑端先跑起来（stream-relay），OBS 推流，然后手机开抖音。

看日志（任选其一）：

- 爱思助手 / 3uTools → 工具箱 → 实时日志，过滤 `vcam`
- Mac 上：`idevicesyslog | grep vcam`

正常应该依次看到：

```
[vcam] dylib 已加载，目标 192.168.1.42:8080
[vcam] 已 hook AVCaptureVideoDataOutput
[vcam] 正在连接 ws://192.168.1.42:8080/ws
[vcam] 已接管 XXX 的帧回调
```

如果只到「已 hook」但没有「已接管」，说明抖音的采集 delegate 不是通过
`setSampleBufferDelegate:queue:` 设置的，需要换 hook 点。

## 五、已知限制

- **只 hook 了 `AVCaptureVideoDataOutput`**。如果抖音改用自定义采集管线，这个 hook 不生效，
  日志里就不会出现「已接管」。
- **输出格式固定 420f**（`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`）。
  如果抖音要求别的像素格式，画面会花屏或黑屏。
- **不含任何反检测逻辑**。抖音有完整性校验，可能闪退、可能识别、可能封号，后果自负。
- 电脑断流超过 2 秒会自动**回落真实摄像头**，避免直播定格。
- 帧率 12fps 是电脑端给的（MJPEG，约 2Mbps），画面流畅度不如原生 30fps。

## 六、调试顺序（很重要）

出问题时按这个顺序排查，不要一次改多处：

1. 电脑端：浏览器访问 `http://<IP>:8080/api/status`，看 `frames.running` 是否 true、
   `frames.frames` 是否在增长
2. 手机端：日志有没有「dylib 已加载」——没有就是注入失败
3. 日志有没有「已接管」——没有就是 hook 点没命中
4. 有「已接管」但画面还黑——像素格式或时间戳问题
