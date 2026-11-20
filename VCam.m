// 抖音虚拟摄像头注入（TrollStore / TrollFools）
//
// 关键约束与取舍：
//   1. TrollStore 注入的 dylib 没有 Substrate，所以不用 Logos 的 %hook，
//      全部走 ObjC runtime（class_replaceMethod）。
//   2. 手机连电脑用**裸 TCP**，不用 WebSocket：iOS 的 ATS 会拦 ws:// 明文连接，
//      而 BSD socket 不受 ATS 约束。
//   3. 没有 UI 面板，但会在关键状态弹一个提示框（已加载 / 已连接 / 连接失败），
//      方便判断"注入成功了吗""连上了吗"。
//
// 数据协议：[4 字节大端长度][JPEG 数据]，循环。

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>

// ======================= 配置 =======================

// 电脑局域网 IP
static NSString *const kDefaultHost = @"192.168.1.42";
// 裸 TCP 帧端口（电脑端 frames.js 里的 clientPort）
static const int kFramePort = 9003;
// 裸 TCP 音频端口（电脑端 audio.js 里的 tcpPort）
static const int kAudioPort = 9004;
// 断流多久回落到真实摄像头
static const NSTimeInterval kStaleSeconds = 2.0;
// 是否显示调试提示框（调好后关掉，只留控制面板）
static const BOOL kShowAlerts = NO;
// 是否显示逐帧诊断（排查 hook 时临时打开）
static const BOOL kShowDiag = NO;

// 电脑 PCM 缓冲：网络线程写，音频实时线程读（纯 C，不涉及 Objective-C）
#define VCAM_PCM_MAX_FRAMES 48000
static int16_t gPCM[VCAM_PCM_MAX_FRAMES * 2];
static volatile int gPCMFrames = 0;
static volatile double gPCMReadPos = 0.0;
static volatile int gInjectEnabled = 0;

// 实时电平（0~1），供面板波形显示
static volatile float gLevelPCM = 0.0f;
static volatile float gLevelMic = 0.0f;

// ======================= 崩溃取证日志 =======================
// 每行都落盘并 flush：App 崩溃后重启仍能读到最后一步，用来定位死在哪

static NSString *VCamLogPath(void)
{
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!dir) dir = NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"vcam-trace.log"];
}

static void VCamLogLine(NSString *message)
{
    @autoreleasepool {
        NSString *path = VCamLogPath();
        NSString *line = [NSString stringWithFormat:@"%.3f  %@\n",
                          [NSDate timeIntervalSinceReferenceDate], message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [data writeToFile:path atomically:NO];
            return;
        }
        @try {
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh synchronizeFile];
        } @catch (NSException *e) {
            // 写日志失败不能影响主流程
        }
        [fh closeFile];
    }
}

static NSString *VCamLogTail(NSUInteger lines)
{
    NSString *path = VCamLogPath();
    NSString *all = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (!all.length) return @"（还没有日志）\n";
    NSArray *arr = [all componentsSeparatedByString:@"\n"];
    NSUInteger start = arr.count > lines ? arr.count - lines : 0;
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = start; i < arr.count; i++) {
        if ([arr[i] length]) [out appendFormat:@"%@\n", arr[i]];
    }
    return [out length] ? out : @"（日志为空）\n";
}

static NSString *VCamHost(void)
{
    NSString *host = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_host"];
    return host.length ? host : kDefaultHost;
}

// ======================= 调试提示 =======================

static void VCamShowAlert(NSString *message, BOOL force)
{
    if (!kShowAlerts) return;
    static NSTimeInterval lastShown = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!force && now - lastShown < 1.0) return;
    lastShown = now;

    NSLog(@"[vcam] %@", message);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { window = w; break; }
        }
        if (!window) window = [UIApplication sharedApplication].windows.firstObject;
        UIViewController *root = window.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;
        if (!root) return;

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"虚拟摄像头"
                                                message:message
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [root presentViewController:alert animated:YES completion:nil];
    });
}

// ======================= 读满指定字节 =======================

// 读取完整数据
// 返回: 1=读满  0=对端关闭  -2=本帧还没数据（超时，可继续等）  负数取反为 errno
static int VCamReadFull(int fd, void *buf, size_t len)
{
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, (char *)buf + got, len - got, 0);
        if (n > 0) {
            got += (size_t)n;
            continue;
        }
        if (n == 0) {
            return got == 0 ? 0 : -(int)ECONNRESET;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            // 超时：还没收到数据就继续等；已经读了一半说明流错位，按错误处理
            return got == 0 ? -2 : -(int)ETIMEDOUT;
        }
        if (errno == EINTR) {
            continue;
        }
        return -(int)errno;
    }
    return 1;
}

// ======================= 帧接收 =======================

@interface VCamClient : NSObject
@property (nonatomic, strong) CIContext *ciContext;
@property (atomic, strong) NSData *latestJPEG;
@property (atomic, assign) NSTimeInterval latestAt;
@property (atomic, assign) BOOL running;
@property (atomic, assign) NSUInteger frameCount;
@property (atomic, assign) BOOL reportedLoaded;
@property (atomic, copy) NSString *diagReason;
@property (atomic, copy) NSString *lastReason;
@property (atomic, assign) int currentFD;
- (void)restart;
+ (instancetype)shared;
- (void)start;
- (void)stop;
- (CMSampleBufferRef)copySampleBufferForReference:(CMSampleBufferRef)reference CF_RETURNS_RETAINED;
// 推荐路径：直接把电脑画面写进原帧的像素缓冲区（不新建 CMSampleBuffer，零格式风险）
- (BOOL)overwriteFrameBuffer:(CVPixelBufferRef)pixelBuffer;
@end

@implementation VCamClient

+ (instancetype)shared
{
    static VCamClient *client = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ client = [[VCamClient alloc] init]; });
    return client;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _ciContext = [CIContext contextWithOptions:@{ kCIContextWorkingColorSpace : (id)[NSNull null] }];
        _running = NO;
    }
    return self;
}

- (void)start
{
    if (self.running) return;
    self.running = YES;
    [NSThread detachNewThreadSelector:@selector(connectLoop) toTarget:self withObject:nil];
}

- (void)stop
{
    self.running = NO;
}

// 切换电脑 IP 后立即重连：先掐断当前 socket，再重启接收线程
- (void)restart
{
    int fd = self.currentFD;
    if (fd > 0) shutdown(fd, SHUT_RDWR);
    self.running = NO;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf start];
    });
}

- (void)connectLoop
{
    @autoreleasepool {
        BOOL reportedConnect = NO;
        BOOL reportedFail = NO;
        NSString *host = VCamHost();

        while (self.running) {
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) {
                [NSThread sleepForTimeInterval:2.0];
                continue;
            }

            int one = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            struct timeval tv;
            tv.tv_sec = 5;
            tv.tv_usec = 0;
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

            struct sockaddr_in addr;
            memset(&addr, 0, sizeof(addr));
            addr.sin_family = AF_INET;
            addr.sin_port = htons(kFramePort);
            addr.sin_addr.s_addr = inet_addr([host UTF8String]);

            if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
                self.currentFD = fd;
                if (!reportedConnect) {
                    reportedConnect = YES;
                    reportedFail = NO;
                    VCamShowAlert([NSString stringWithFormat:@"已连上电脑 %@:%d，开始接收画面", host, kFramePort],
                                  YES);
                }
                while (self.running) {
                    uint32_t lenBE = 0;
                    int rr = VCamReadFull(fd, &lenBE, sizeof(lenBE));
                    if (rr == -2) continue;            // 暂时没数据（正常，OBS 还没推流）
                    if (rr != 1) {
                        NSLog(@"[vcam] 视频通道断开 r=%d errno=%d", rr, rr < 0 ? -rr : 0);
                        self.lastReason = [NSString stringWithFormat:@"视频通道断开（%d）", rr < 0 ? -rr : rr];
                        break;
                    }
                    uint32_t len = ntohl(lenBE);
                    if (len == 0 || len > 8 * 1024 * 1024) break;

                    NSMutableData *data = [NSMutableData dataWithLength:len];
                    if (VCamReadFull(fd, data.mutableBytes, len) != 1) break;

                    self.latestJPEG = data;
                    self.latestAt = [NSDate timeIntervalSinceReferenceDate];
                    self.frameCount += 1;

                    if (self.frameCount == 1) {
                        NSLog(@"[vcam] 收到第一帧 %u 字节", len);
                    }
                }
                reportedConnect = NO;
            } else if (!reportedFail) {
                reportedFail = YES;
                VCamShowAlert([NSString stringWithFormat:
                                  @"连不上电脑 %@:%d\n\n检查：\n1. 电脑端程序是否在运行\n2. 手机「设置 → 抖音 → 本地网络」是否打开\n3. 手机和电脑是否同一个 Wi-Fi",
                                  host, kFramePort],
                              YES);
            }

            self.currentFD = -1;
            close(fd);
            if (self.running) [NSThread sleepForTimeInterval:2.0];
        }
    }
}

// ======================= 首帧诊断 =======================

static NSString *VCamFourCC(FourCharCode code)
{
    char s[5] = { (char)((code >> 24) & 0xff), (char)((code >> 16) & 0xff),
                  (char)((code >> 8) & 0xff), (char)(code & 0xff), 0 };
    return [NSString stringWithUTF8String:s];
}

static void VCamReportDiag(NSString *key, NSString *reason, NSData *jpeg, NSTimeInterval age,
                           FourCharCode subtype, CMVideoDimensions dims)
{
    static NSMutableSet *shownKeys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shownKeys = [NSMutableSet set]; });

    if (!kShowDiag) {
        NSLog(@"[vcam] 诊断[%@] %@", key, reason);
        return;
    }
    @synchronized (shownKeys) {
        if ([shownKeys containsObject:key]) return;
        [shownKeys addObject:key];
    }

    NSString *msg = [NSString stringWithFormat:
        @"诊断[%@]\n\n结果：%@\n原帧格式：%@  %dx%d\n有电脑画面：%@（延迟 %.1f 秒）",
        key, reason,
        VCamFourCC(subtype), dims.width, dims.height,
        jpeg.length ? @"有" : @"没有", age];
    VCamShowAlert(msg, YES);
}

#pragma mark - 原地写入像素（推荐路径）

- (BOOL)overwriteFrameBuffer:(CVPixelBufferRef)pixelBuffer
{
    self.lastReason = nil;

    if (!pixelBuffer) {
        self.lastReason = @"原帧没有像素缓冲";
        return NO;
    }

    NSData *jpeg = self.latestJPEG;
    if (!jpeg.length) {
        self.lastReason = @"还没收到电脑画面";
        return NO;
    }

    NSTimeInterval age = [NSDate timeIntervalSinceReferenceDate] - self.latestAt;
    if (age > kStaleSeconds) {
        self.lastReason = @"电脑画面太旧（断流）";
        return NO;
    }

    id enabledObj = [[NSUserDefaults standardUserDefaults] objectForKey:@"vcam_enabled"];
    if (enabledObj && ![enabledObj boolValue]) {
        self.lastReason = @"已手动关闭";
        return NO;
    }

    size_t dstW = CVPixelBufferGetWidth(pixelBuffer);
    size_t dstH = CVPixelBufferGetHeight(pixelBuffer);
    if (dstW == 0 || dstH == 0) {
        self.lastReason = @"原帧尺寸为 0";
        return NO;
    }

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    if (!source) {
        self.lastReason = @"JPEG 读取失败";
        return NO;
    }
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) {
        self.lastReason = @"JPEG 解码失败";
        return NO;
    }

    CIImage *ciImage = [CIImage imageWithCGImage:image];
    CGImageRelease(image);
    if (!ciImage) {
        self.lastReason = @"CIImage 创建失败";
        return NO;
    }

    // 面板上的 ↺ / ↻ 旋转（每按一次 90°）
    NSInteger rotation = [[NSUserDefaults standardUserDefaults] integerForKey:@"vcam_rotation"];
    rotation = ((rotation % 360) + 360) % 360;
    if (rotation != 0) {
        CGAffineTransform rot = CGAffineTransformMakeRotation((CGFloat)rotation * (CGFloat)M_PI / 180.0);
        CIImage *rotated = [ciImage imageByApplyingTransform:rot];
        CGRect re = rotated.extent;
        // 旋转后原点可能变成负数，平移回 (0,0)
        rotated = [rotated imageByApplyingTransform:CGAffineTransformMakeTranslation(-re.origin.x, -re.origin.y)];
        ciImage = rotated;
    }

    // 等比缩放居中（contain）
    CGFloat srcW = ciImage.extent.size.width;
    CGFloat srcH = ciImage.extent.size.height;
    if (srcW <= 0 || srcH <= 0) {
        self.lastReason = @"电脑画面尺寸异常";
        return NO;
    }
    BOOL fill = [[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_fill"];
    BOOL mirror = [[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_mirror"];
    CGFloat scale = fill ? MAX((CGFloat)dstW / srcW, (CGFloat)dstH / srcH)
                         : MIN((CGFloat)dstW / srcW, (CGFloat)dstH / srcH);
    CGFloat dx = ((CGFloat)dstW - srcW * scale) / 2.0;
    CGFloat dy = ((CGFloat)dstH - srcH * scale) / 2.0;
    CIImage *scaled = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    scaled = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];
    if (mirror) {
        CGAffineTransform flip = CGAffineTransformMakeTranslation((CGFloat)dstW, 0);
        flip = CGAffineTransformScale(flip, -1, 1);
        scaled = [scaled imageByApplyingTransform:flip];
    }

    // 直接渲染进抖音自己那块缓冲区：格式/尺寸/时间戳都是它原本的，不会不匹配
    @try {
        [self.ciContext render:scaled
              toCVPixelBuffer:pixelBuffer
                      bounds:CGRectMake(0, 0, dstW, dstH)
                  colorSpace:NULL];
    } @catch (NSException *e) {
        self.lastReason = [NSString stringWithFormat:@"渲染异常：%@", e.reason];
        return NO;
    }

    self.lastReason = @"替换成功（原地写入原帧缓冲区）";
    return YES;
}

#pragma mark - JPEG → CMSampleBuffer（备选路径，当前未使用）

- (CMSampleBufferRef)copySampleBufferForReference:(CMSampleBufferRef)reference CF_RETURNS_RETAINED
{
    self.lastReason = nil;

    if (!reference) { self.lastReason = @"没有原始帧"; return NULL; }

    NSData *jpeg = self.latestJPEG;
    if (!jpeg.length) { self.lastReason = @"还没收到电脑画面"; return NULL; }

    // 断流了，回落真实摄像头
    NSTimeInterval age = [NSDate timeIntervalSinceReferenceDate] - self.latestAt;
    if (age > kStaleSeconds) { self.lastReason = @"电脑画面太旧（断流）"; return NULL; }

    // 关键：拿原帧的格式描述，按它的尺寸/像素格式/时间戳来造，下游才不会因为不匹配而崩
    CMFormatDescriptionRef fmtRef = CMSampleBufferGetFormatDescription(reference);
    if (!fmtRef) { self.lastReason = @"原帧没有格式描述"; return NULL; }
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fmtRef);
    FourCharCode subtype = CMFormatDescriptionGetMediaSubType(fmtRef);
    if (dims.width <= 0 || dims.height <= 0) { self.lastReason = @"原帧尺寸异常"; return NULL; }

    BOOL supported = (subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                      subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                      subtype == kCVPixelFormatType_32BGRA);
    if (!supported) {
        // 不认识的格式就放行原帧，宁可不替换也别崩
        self.lastReason = [NSString stringWithFormat:@"像素格式 %@ 不在支持列表", VCamFourCC(subtype)];
        return NULL;
    }

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    if (!source) { self.lastReason = @"JPEG 读取失败"; return NULL; }
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) { self.lastReason = @"JPEG 解码失败"; return NULL; }

    CIImage *ciImage = [CIImage imageWithCGImage:image];
    CGImageRelease(image);
    if (!ciImage) { self.lastReason = @"CIImage 创建失败"; return NULL; }

    // 等比缩放并居中（contain），保证画面完整不裁切
    CGFloat srcW = ciImage.extent.size.width;
    CGFloat srcH = ciImage.extent.size.height;
    if (srcW <= 0 || srcH <= 0) { self.lastReason = @"电脑画面尺寸异常"; return NULL; }
    CGFloat scale = MIN(dims.width / srcW, dims.height / srcH);
    CGFloat dx = (dims.width - srcW * scale) / 2.0;
    CGFloat dy = (dims.height - srcH * scale) / 2.0;
    CIImage *scaled = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    scaled = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];

    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
    };
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn st = CVPixelBufferCreate(kCFAllocatorDefault, (size_t)dims.width, (size_t)dims.height,
                                      subtype, (__bridge CFDictionaryRef)attrs, &pixelBuffer);
    if (st != kCVReturnSuccess || !pixelBuffer) {
        self.lastReason = [NSString stringWithFormat:@"像素缓冲创建失败(%d)", (int)st];
        return NULL;
    }

    @try {
        [self.ciContext render:scaled
              toCVPixelBuffer:pixelBuffer
                      bounds:CGRectMake(0, 0, dims.width, dims.height)
                  colorSpace:CGColorSpaceCreateDeviceRGB()];
    } @catch (NSException *e) {
        self.lastReason = [NSString stringWithFormat:@"渲染异常：%@", e.reason];
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }

    // 沿用原帧的时间戳，避免下游因为 PTS 跳变而崩
    CMSampleTimingInfo timing = {
        .duration = CMSampleBufferGetDuration(reference),
        .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(reference),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    if (CMTIME_IS_INVALID(timing.presentationTimeStamp)) {
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
    }

    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer, fmtRef,
                                                              &timing, &sampleBuffer);
    CVPixelBufferRelease(pixelBuffer);
    if (status != noErr || !sampleBuffer) {
        self.lastReason = [NSString stringWithFormat:@"CMSampleBuffer 创建失败(%d)", (int)status];
        return NULL;
    }

    self.lastReason = @"替换成功";
    return sampleBuffer;
}

@end

// ======================= 音频路径诊断 =======================

static NSMutableArray *gAudioTrace;
static NSTimeInterval gStartTime;

static void VCamTrace(NSString *fmt, ...)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gAudioTrace = [NSMutableArray array];
        gStartTime = [NSDate timeIntervalSinceReferenceDate];
    });
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%6.1fs  %@",
                      [NSDate timeIntervalSinceReferenceDate] - gStartTime, s];
    @synchronized (gAudioTrace) {
        [gAudioTrace addObject:line];
        if (gAudioTrace.count > 300) [gAudioTrace removeObjectAtIndex:0];
    }
    NSLog(@"[vcam-audio] %@", s);
    VCamLogLine(s);
}

// 被动观察：不改变行为，只记录抖音的音频管线走了哪条路
static void VCamInstallAudioProbes(void)
{
    // 1) AVCaptureAudioDataOutput：如果命中，说明音频和视频一样走标准采集回调
    Class audioOut = objc_getClass("AVCaptureAudioDataOutput");
    if (audioOut) {
        SEL sel = @selector(setSampleBufferDelegate:queue:);
        Method m = class_getInstanceMethod(audioOut, sel);
        if (m) {
            IMP orig = method_getImplementation(m);
            IMP repl = imp_implementationWithBlock(^(id obj, id delegate, dispatch_queue_t q) {
                VCamTrace(@"AVCaptureAudioDataOutput 设置 delegate → %@", NSStringFromClass([delegate class]));
                ((void (*)(id, SEL, id, dispatch_queue_t))orig)(obj, sel, delegate, q);
            });
            class_replaceMethod(audioOut, sel, repl, method_getTypeEncoding(m));
        }
    }

    // 2) AVAudioEngine：如果命中，说明走的是 AVAudioEngine 管线
    Class engine = objc_getClass("AVAudioEngine");
    if (engine) {
        SEL sel = @selector(startAndReturnError:);
        Method m = class_getInstanceMethod(engine, sel);
        if (m) {
            IMP orig = method_getImplementation(m);
            IMP repl = imp_implementationWithBlock(^BOOL(id obj, NSError **err) {
                VCamTrace(@"AVAudioEngine 启动（可能走 AVAudioEngine 管线）");
                return ((BOOL (*)(id, SEL, NSError **))orig)(obj, sel, err);
            });
            class_replaceMethod(engine, sel, repl, method_getTypeEncoding(m));
        }
    }

    // 3) AVAudioSession：看它的 category，判断是录音还是播放
    Class session = objc_getClass("AVAudioSession");
    if (session) {
        SEL sel = @selector(setCategory:mode:options:error:);
        Method m = class_getInstanceMethod(session, sel);
        if (m) {
            IMP orig = method_getImplementation(m);
            IMP repl = imp_implementationWithBlock(^BOOL(id obj, NSString *cat, NSString *mode,
                                                         NSUInteger opt, NSError **err) {
                VCamTrace(@"AVAudioSession category=%@ mode=%@", cat, mode);
                return ((BOOL (*)(id, SEL, NSString *, NSString *, NSUInteger, NSError **))orig)(
                    obj, sel, cat, mode, opt, err);
            });
            class_replaceMethod(session, sel, repl, method_getTypeEncoding(m));
        }
    }

    // 4) AVAudioSession 的其它常见调用方式（上一版漏了这些）
    if (session) {
        SEL sel2 = @selector(setCategory:error:);
        Method m2 = class_getInstanceMethod(session, sel2);
        if (m2) {
            IMP o2 = method_getImplementation(m2);
            IMP r2 = imp_implementationWithBlock(^BOOL(id obj, NSString *cat, NSError **err) {
                VCamTrace(@"AVAudioSession setCategory:%@ error:", cat);
                return ((BOOL (*)(id, SEL, NSString *, NSError **))o2)(obj, sel2, cat, err);
            });
            class_replaceMethod(session, sel2, r2, method_getTypeEncoding(m2));
        }

        SEL sel3 = @selector(setActive:error:);
        Method m3 = class_getInstanceMethod(session, sel3);
        if (m3) {
            IMP o3 = method_getImplementation(m3);
            IMP r3 = imp_implementationWithBlock(^BOOL(id obj, BOOL active, NSError **err) {
                VCamTrace(@"AVAudioSession setActive:%d", (int)active);
                return ((BOOL (*)(id, SEL, BOOL, NSError **))o3)(obj, sel3, active, err);
            });
            class_replaceMethod(session, sel3, r3, method_getTypeEncoding(m3));
        }

        SEL sel4 = @selector(setMode:error:);
        Method m4 = class_getInstanceMethod(session, sel4);
        if (m4) {
            IMP o4 = method_getImplementation(m4);
            IMP r4 = imp_implementationWithBlock(^BOOL(id obj, NSString *mode, NSError **err) {
                VCamTrace(@"AVAudioSession setMode:%@", mode);
                return ((BOOL (*)(id, SEL, NSString *, NSError **))o4)(obj, sel4, mode, err);
            });
            class_replaceMethod(session, sel4, r4, method_getTypeEncoding(m4));
        }
    }

    VCamTrace(@"音频探针已安装");
}

// 针对重点类，把跟音频采集/处理相关的方法列出来
static NSString *VCamDumpClassMethods(NSString *className)
{
    Class cls = objc_getClass([className UTF8String]);
    if (!cls) return [NSString stringWithFormat:@"\n== %@ ==\n  （类不存在）\n", className];

    NSMutableString *s = [NSMutableString stringWithFormat:@"\n== %@ ==\n", className];
    unsigned int total = 0;
    Method *methods = class_copyMethodList(cls, &total);
    NSMutableArray *matched = [NSMutableArray array];
    for (unsigned int i = 0; i < total; i++) {
        NSString *sel = NSStringFromSelector(method_getName(methods[i]));
        NSString *low = [sel lowercaseString];
        if ([low rangeOfString:@"audio"].location != NSNotFound ||
            [low rangeOfString:@"capture"].location != NSNotFound ||
            [low rangeOfString:@"input"].location != NSNotFound ||
            [low rangeOfString:@"frame"].location != NSNotFound ||
            [low rangeOfString:@"pcm"].location != NSNotFound ||
            [low rangeOfString:@"render"].location != NSNotFound ||
            [low rangeOfString:@"start"].location != NSNotFound ||
            [low rangeOfString:@"stop"].location != NSNotFound ||
            [low rangeOfString:@"observer"].location != NSNotFound) {
            [matched addObject:sel];
        }
    }
    free(methods);
    [matched sortUsingSelector:@selector(compare:)];
    for (NSString *sel in matched) {
        [s appendFormat:@"  - %@\n", sel];
    }
    Class sup = class_getSuperclass(cls);
    [s appendFormat:@"  （共 %u 个方法，列出 %lu 个；父类 %s）\n",
     total, (unsigned long)matched.count, sup ? class_getName(sup) : "-"];
    return s;
}

// 打印指定 selector 的完整类型编码（决定调用时参数怎么传）
static NSString *VCamDumpSignatures(NSString *className, NSArray *selectorNames)
{
    Class cls = objc_getClass([className UTF8String]);
    if (!cls) return [NSString stringWithFormat:@"\n== %@ ==\n  （类不存在）\n", className];

    NSMutableString *s = [NSMutableString stringWithFormat:@"\n== %@ 方法签名 ==\n", className];
    for (NSString *name in selectorNames) {
        if (![cls instancesRespondToSelector:NSSelectorFromString(name)]) {
            [s appendFormat:@"  %@\n     （没有这个方法）\n", name];
            continue;
        }
        Method m = class_getInstanceMethod(cls, NSSelectorFromString(name));
        [s appendFormat:@"  %@\n     %s\n", name, m ? method_getTypeEncoding(m) : "(null)"];
    }
    return s;
}

// 全类扫描：不管 App 用什么私有音频框架，只要方法名带这些关键词就抓出来
static NSString *VCamScanAudioAPIs(void)
{
    NSMutableString *out = [NSMutableString string];

    NSArray *keys = @[
        @"pushExternalAudio", @"pushAudio", @"pushAudioFrame", @"pushMic",
        @"audioFrame", @"captureAudio", @"startAudioCapture", @"stopAudioCapture",
        @"setMicVolume", @"setMicMute", @"setAudioMute", @"setCaptureVolume",
        @"setInputVolume", @"setInputMute", @"sendAudio", @"onMic",
        @"microphone", @"pullMicAudio", @"processAudio", @"audioDeviceModule",
        @"enableAudio", @"audioBufferList", @"recordAudio",
    ];

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return out;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    count = objc_getClassList(classes, count);

    NSMutableArray *hits = [NSMutableArray array];
    for (int i = 0; i < count && hits.count < 800; i++) {
        Class cls = classes[i];
        const char *cn = class_getName(cls);
        if (!cn) continue;
        NSString *clsName = [NSString stringWithUTF8String:cn];
        // 跳过系统框架，减少噪音（系统音频采集由探针负责看）
        if ([clsName hasPrefix:@"NS"] || [clsName hasPrefix:@"UI"] ||
            [clsName hasPrefix:@"AV"] || [clsName hasPrefix:@"__"] ||
            [clsName hasPrefix:@"OS_"] || [clsName hasPrefix:@"Swift"]) {
            continue;
        }

        unsigned int mc = 0;
        Method *methods = class_copyMethodList(cls, &mc);
        for (unsigned int j = 0; j < mc; j++) {
            NSString *sel = NSStringFromSelector(method_getName(methods[j]));
            for (NSString *key in keys) {
                if ([sel rangeOfString:key options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    [hits addObject:[NSString stringWithFormat:@"%@\n    -%@", clsName, sel]];
                    break;
                }
            }
            if (hits.count >= 800) break;
        }
        free(methods);
    }
    free(classes);

    [hits sortUsingSelector:@selector(compare:)];
    NSUInteger limit = MIN(hits.count, (NSUInteger)200);
    [out appendString:@"\n== 五、全类扫描：音频注入/采集候选 ==\n"];
    for (NSUInteger i = 0; i < limit; i++) {
        [out appendFormat:@"%@\n", hits[i]];
    }
    [out appendFormat:@"\n（命中 %lu 条，列出 %lu 条）\n",
     (unsigned long)hits.count, (unsigned long)limit];
    return out;
}

// 按方法名反查：哪些类实现了这个方法（用于快手这种 Kotlin/Native 架构）
static NSString *VCamFindImplementors(void)
{
    NSArray *selectors = @[
        @"inputRawAudioFrameFrame:",
        @"inputSpeakerAudioFrame:",
        @"inputAudioMultiTrackDataChannelId:audioFrameArray:needPlay:needMixRtc:needMixLiveStream:timestamp:",
        @"setPartnerAudioFrame:",
        @"muteMicrophone",
        @"unmuteMicrophone",
        @"startAudioCapture",
        @"stopAudioCapture",
        @"setMicrophoneMute:",
        @"enableAudioInternalRecording",
        @"recordAudio",
        @"inputAudioTrackData:audioFrameArray:",
    ];

    NSMutableString *out = [NSMutableString string];
    [out appendString:@"\n== 六、按方法名反查实现类 ==\n"];

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return out;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    count = objc_getClassList(classes, count);

    for (NSString *selName in selectors) {
        SEL sel = NSSelectorFromString(selName);
        [out appendFormat:@"\n--- %@ ---\n", selName];
        BOOL any = NO;

        for (int i = 0; i < count; i++) {
            Class cls = classes[i];
            const char *cn = class_getName(cls);
            if (!cn) continue;
            NSString *clsName = [NSString stringWithUTF8String:cn];
            if ([clsName hasPrefix:@"NS"] || [clsName hasPrefix:@"UI"] ||
                [clsName hasPrefix:@"AV"] || [clsName hasPrefix:@"__"] ||
                [clsName hasPrefix:@"OS_"] || [clsName hasPrefix:@"Swift"] ||
                [clsName hasPrefix:@"KSKNSKC"]) {
                continue;
            }
            if (!class_respondsToSelector(cls, sel)) continue;

            Method m = class_getInstanceMethod(cls, sel);
            [out appendFormat:@"  %@\n     %s\n", clsName, m ? method_getTypeEncoding(m) : "(null)"];
            any = YES;
        }

        if (!any) [out appendString:@"  （没有类实现）\n"];
    }

    free(classes);
    return out;
}

static NSString *VCamKuaishouReport(void);
static NSString *VCamKuaishouDeepReport(void);
static NSString *VCamKuaishouCaptureReport(void);
static NSString *VCamRuntimeLogReport(void);

static NSString *VCamAudioReport(void)
{
    NSMutableString *out = [NSMutableString string];

    [out appendString:@"== 一、运行时观察到的音频调用 ==\n"];
    @synchronized (gAudioTrace) {
        if (gAudioTrace.count == 0) {
            [out appendString:@"（一条都没有——请先进入抖音直播/拍摄画面，再回来打开这个面板）\n"];
        } else {
            for (NSString *line in gAudioTrace) {
                [out appendFormat:@"%@\n", line];
            }
        }
    }

    [out appendString:@"\n== 二、重点类的方法 ==\n"];
    NSArray *targets = @[
        @"IESLiveAudioCapturerImp",
        @"IESLiveAudioCaptureHookHelper",
        @"IESLiveAudioCaptureRequest",
        @"IESLiveRecoderImp_douyinAudioHookHelper",
        @"IESMMAudioCapture",
        @"LSLiveAudioUnitProcess",
        @"LSLiveAudioUnitConfig",
        @"LiveStreamAudioCapture",
        @"LiveStreamAudioRecord",
        @"LSAudioBufferQueue",
        @"LiveCoreAudioBufferQueue",
        @"BDAudioKitObjcAudioDeviceSource",
        @"BDAudioKitObjcAudioDeviceModule",
        @"BAudioKitObjcAudioDeviceSource",
        @"BAudioKitObjcAudioDeviceModule",
        @"ATSAudioOfIESLiveAudioCapturePipeline",
    ];
    for (NSString *name in targets) {
        [out appendString:VCamDumpClassMethods(name)];
    }

    [out appendString:@"\n== 三、类名含 Audio 的业务类（已过滤，最多 120 个）==\n"];
    int count = objc_getClassList(NULL, 0);
    if (count > 0) {
        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
        count = objc_getClassList(classes, count);
        NSMutableArray *names = [NSMutableArray array];
        NSArray *prefixes = @[ @"IES", @"LS", @"BD", @"AWE", @"AT", @"BA", @"CG", @"LM", @"LC", @"Live", @"TT" ];
        for (int i = 0; i < count; i++) {
            const char *n = class_getName(classes[i]);
            if (!n) continue;
            NSString *name = [NSString stringWithUTF8String:n];
            if ([name rangeOfString:@"audio" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            BOOL keep = NO;
            for (NSString *p in prefixes) {
                if ([name hasPrefix:p]) { keep = YES; break; }
            }
            if (keep) [names addObject:name];
        }
        free(classes);
        [names sortUsingSelector:@selector(compare:)];
        NSUInteger limit = MIN(names.count, (NSUInteger)120);
        for (NSUInteger i = 0; i < limit; i++) {
            [out appendFormat:@"%@\n", names[i]];
        }
        [out appendFormat:@"\n（命中 %lu 个，已列出 %lu 个）\n",
         (unsigned long)names.count, (unsigned long)limit];
    }

    [out appendString:@"\n== 四、音频注入候选方法的类型签名 ==\n"];
    NSArray *pushSel = @[
        @"enableAudioPushStream:",
        @"pushAudioBuffer:andDataLen:sampleRate:channels:andBitsPerSample:timestamp:",
        @"pushExternalAudioFrame:DataSize:FormatType:SampleRate:ChannelNumber:PTS:",
        @"pushExternalSpecifiedAudioFrame:DataSize:FormatType:SampleRate:ChannelNumber:PTS:",
        @"pullMicAudio:size:sampleRate:timeStamp:mNumberChannels:numberOfFrames:processedData:earMonitorData:",
        @"setInputStreamMute:",
        @"setInputStreamVolume:",
        @"setAudioSourceType:",
        @"startAudioCapture",
        @"stopAudioCapture",
    ];
    [out appendString:VCamDumpSignatures(@"LiveStreamAudioCapture", pushSel)];
    [out appendString:VCamDumpSignatures(@"BAudioKitObjcAudioDeviceModule", pushSel)];

    [out appendString:VCamScanAudioAPIs()];
    [out appendString:VCamFindImplementors()];
    [out appendString:VCamKuaishouReport()];
    [out appendString:VCamKuaishouDeepReport()];
    [out appendString:VCamKuaishouCaptureReport()];
    [out appendString:VCamRuntimeLogReport()];

    return out;
}

// ======================= 快手（RTC 引擎）探测 =======================

static void *gKuaishouRtc = NULL;          // 捕获到的 RTC 引擎实例
static NSString *gKuaishouFrameInfo = nil; // 捕获到的音频帧对象结构

// 描述一个对象：类名 + 父类 + 属性 + 实例变量
static NSString *VCamDescribeObject(id obj)
{
    if (!obj) return @"(nil)";
    Class cls = object_getClass(obj);
    NSMutableString *s = [NSMutableString stringWithFormat:@"类名: %s\n", class_getName(cls)];

    Class sup = class_getSuperclass(cls);
    if (sup) [s appendFormat:@"父类: %s\n", class_getName(sup)];

    unsigned int pc = 0;
    objc_property_t *props = class_copyPropertyList(cls, &pc);
    [s appendFormat:@"属性 %u 个:\n", pc];
    for (unsigned int i = 0; i < pc && i < 25; i++) {
        [s appendFormat:@"  %s  (%s)\n", property_getName(props[i]),
                      property_getAttributes(props[i]) ?: ""];
    }
    free(props);

    unsigned int ic = 0;
    Ivar *ivars = class_copyIvarList(cls, &ic);
    [s appendFormat:@"实例变量 %u 个:\n", ic];
    for (unsigned int i = 0; i < ic && i < 25; i++) {
        [s appendFormat:@"  %s  (%s)\n", ivar_getName(ivars[i]),
                      ivar_getTypeEncoding(ivars[i]) ?: ""];
    }
    free(ivars);

    return s;
}

// 报告：快手 RTC 引擎的类方法 + 我们抓到了什么
static NSString *VCamKuaishouReport(void)
{
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"\n== 七、快手 RTC 引擎探测 ==\n"];

    NSArray *names = @[
        @"KuaishouRtcEngine", @"KuaishouRtcEngineShadow", @"KuaishouRtcEngineKmp",
        @"KuaishouRtcEngineContext", @"KSKNSRtcEngineExt", @"KSKNSIRtcEngine",
    ];

    NSArray *keys = @[ @"shared", @"instance", @"default", @"create", @"engine", @"manager" ];

    for (NSString *name in names) {
        Class cls = objc_getClass([name UTF8String]);
        if (!cls) {
            [out appendFormat:@"\n%@ : 不存在\n", name];
            continue;
        }
        [out appendFormat:@"\n%@ 的类方法（含关键词）:\n", name];
        Class meta = object_getClass(cls);
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(meta, &mc);
        BOOL any = NO;
        for (unsigned int i = 0; i < mc; i++) {
            NSString *sel = NSStringFromSelector(method_getName(ms[i]));
            for (NSString *key in keys) {
                if ([sel rangeOfString:key options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    [out appendFormat:@"  +%@\n     %s\n", sel, method_getTypeEncoding(ms[i])];
                    any = YES;
                    break;
                }
            }
        }
        free(ms);
        if (!any) [out appendString:@"  （没有匹配）\n"];
    }

    [out appendFormat:@"\n已捕获 RTC 引擎实例: %@\n", gKuaishouRtc ? @"是" : @"否"];
    [out appendFormat:@"已捕获音频帧对象: %@\n", gKuaishouFrameInfo ? @"是" : @"否"];
    if (gKuaishouFrameInfo) {
        [out appendString:gKuaishouFrameInfo];
    } else {
        [out appendString:@"（进入直播画面并播放一下声音，再回来看这里）\n"];
    }

    return out;
}

// 把一个 selector 的所有实现类都替换掉（Kotlin/Native 的接口类和实现类都要覆盖）
static void VCamHookAllImplementorsOfInputSpeakerAudioFrame(void)
{
    SEL sel = @selector(inputSpeakerAudioFrame:);
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    count = objc_getClassList(classes, count);

    int hooked = 0;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!class_respondsToSelector(cls, sel)) continue;
        Method m = class_getInstanceMethod(cls, sel);
        const char *enc = m ? method_getTypeEncoding(m) : NULL;
        if (!enc || enc[0] != 'i') continue;

        IMP orig = method_getImplementation(m);
        IMP repl = imp_implementationWithBlock(^int(id obj, id frame) {
            gKuaishouRtc = (__bridge void *)obj;
            if (!gKuaishouFrameInfo) {
                gKuaishouFrameInfo = [VCamDescribeObject(frame) copy];
                VCamTrace(@"抓到快手音频帧对象（inputSpeakerAudioFrame）");
            }
            return ((int (*)(id, SEL, id))orig)(obj, sel, frame);
        });
        class_replaceMethod(cls, sel, repl, enc);
        hooked += 1;
    }
    free(classes);
    VCamTrace(@"inputSpeakerAudioFrame: 共替换 %d 个实现类", hooked);
}

// 多轨混音入口：返回值有 int 和 void 两种，分别处理
static void VCamHookAllImplementorsOfMultiTrackMix(void)
{
    NSString *selName = @"inputAudioMultiTrackDataChannelId:audioFrameArray:needPlay:needMixRtc:needMixLiveStream:timestamp:";
    SEL sel = NSSelectorFromString(selName);
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    count = objc_getClassList(classes, count);

    int hooked = 0;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!class_respondsToSelector(cls, sel)) continue;
        Method m = class_getInstanceMethod(cls, sel);
        const char *enc = m ? method_getTypeEncoding(m) : NULL;
        if (!enc) continue;

        IMP orig = method_getImplementation(m);
        if (enc[0] == 'i') {
            IMP repl = imp_implementationWithBlock(^int(id obj, id channelId, id frames,
                                                       char needPlay, char needMixRtc,
                                                       char needMixLiveStream, long long ts) {
                gKuaishouRtc = (__bridge void *)obj;
                if (!gKuaishouFrameInfo) {
                    id first = [frames isKindOfClass:[NSArray class]] ? [frames firstObject] : frames;
                    if (first) {
                        gKuaishouFrameInfo = [VCamDescribeObject(first) copy];
                        VCamTrace(@"抓到快手混音帧对象（int 版）");
                    }
                }
                return ((int (*)(id, SEL, id, id, char, char, char, long long))orig)(
                    obj, sel, channelId, frames, needPlay, needMixRtc, needMixLiveStream, ts);
            });
            class_replaceMethod(cls, sel, repl, enc);
            hooked += 1;
        } else if (enc[0] == 'v') {
            IMP repl = imp_implementationWithBlock(^(id obj, id channelId, id frames,
                                                    char needPlay, char needMixRtc,
                                                    char needMixLiveStream, long long ts) {
                gKuaishouRtc = (__bridge void *)obj;
                if (!gKuaishouFrameInfo) {
                    id first = [frames isKindOfClass:[NSArray class]] ? [frames firstObject] : frames;
                    if (first) {
                        gKuaishouFrameInfo = [VCamDescribeObject(first) copy];
                        VCamTrace(@"抓到快手混音帧对象（void 版）");
                    }
                }
                ((void (*)(id, SEL, id, id, char, char, char, long long))orig)(
                    obj, sel, channelId, frames, needPlay, needMixRtc, needMixLiveStream, ts);
            });
            class_replaceMethod(cls, sel, repl, enc);
            hooked += 1;
        }
    }
    free(classes);
    VCamTrace(@"多轨混音入口共替换 %d 个实现类", hooked);
}
// 打印某个类的完整方法列表（不按关键词过滤）
static NSString *VCamDumpAllMethods(NSString *className, NSUInteger limit)
{
    Class cls = objc_getClass([className UTF8String]);
    if (!cls) return [NSString stringWithFormat:@"\n%@: （类不存在）\n", className];

    NSMutableString *s = [NSMutableString stringWithFormat:@"\n%@:\n", className];
    unsigned int total = 0;
    Method *methods = class_copyMethodList(cls, &total);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned int i = 0; i < total; i++) {
        [names addObject:[NSString stringWithFormat:@"  - %@   [%s]",
                          NSStringFromSelector(method_getName(methods[i])),
                          method_getTypeEncoding(methods[i]) ?: ""]];
    }
    free(methods);
    [names sortUsingSelector:@selector(compare:)];
    NSUInteger n = MIN(names.count, limit);
    for (NSUInteger i = 0; i < n; i++) [s appendFormat:@"%@\n", names[i]];
    [s appendFormat:@"  （共 %u 个，列出 %lu）\n", total, (unsigned long)n];
    return s;
}

static NSString *VCamKuaishouDeepReport(void)
{
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"\n== 八、快手音频相关类完整方法 ==\n"];

    for (NSString *name in @[ @"KWDAudioCaptureSession", @"AemonAudioUnitController",
                              @"AemonAudioQueueController", @"KWDaenerysAudioController",
                              @"KSCameraCoreService" ]) {
        [out appendString:VCamDumpAllMethods(name, 60)];
    }

    // 刨一下 sharedInstance 拿到什么
    Class ctxCls = objc_getClass("KuaishouRtcEngineContext");
    if (ctxCls) {
        SEL sh = NSSelectorFromString(@"sharedInstance");
        if ([ctxCls respondsToSelector:sh]) {
            @try {
                id ctx = ((id (*)(id, SEL))objc_msgSend)((id)ctxCls, sh);
                [out appendFormat:@"\nKuaishouRtcEngineContext.sharedInstance = %@\n",
                 ctx ? NSStringFromClass(object_getClass(ctx)) : @"nil"];
                if (ctx) {
                    [out appendString:VCamDescribeObject(ctx)];
                    if (!gKuaishouRtc) gKuaishouRtc = (__bridge void *)ctx; // 先记下来备用
                }
            } @catch (NSException *e) {
                [out appendFormat:@"\nsharedInstance 调用异常: %@\n", e.reason];
            }
        }
    }

    return out;
}

// ======================= 快手：麦克风采集会话（KWDAudioCaptureSession） =======================

static void *gKwCapture = NULL;       // 采集会话对象
static void *gKwCaptureBlock = NULL;  // 快手拿麦克风数据的回调 block
static NSString *gKwCaptureInfo = nil;

typedef struct {
    void *isa;
    int flags;
    int reserved;
    void *invoke;
    void *descriptor;
} VCamBlockLayout;

typedef struct {
    unsigned long reserved;
    unsigned long size;
    void *copy;
    void *dispose;
    const char *signature;
} VCamBlockDescriptor;

static NSString *VCamDescribeBlock(void *blockPtr)
{
    if (!blockPtr) return @"(nil)";
    VCamBlockLayout *layout = (VCamBlockLayout *)blockPtr;
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"block flags=%d invoke=%p\n", layout->flags, layout->invoke];
    if (layout->descriptor) {
        VCamBlockDescriptor *d = (VCamBlockDescriptor *)layout->descriptor;
        [s appendFormat:@"block 签名: %s\n", d->signature ? d->signature : "(无)"];
        [s appendFormat:@"block 大小: %lu\n", d->size];
    }
    return s;
}

// 读取采集会话的采样参数（getter 返回 unsigned long）
static NSString *VCamDescribeCaptureSession(void)
{
    id session = (__bridge id)gKwCapture;
    if (!session) return @"（还没拿到采集会话）";

    NSMutableString *s = [NSMutableString stringWithFormat:@"类名: %s\n", class_getName(object_getClass(session))];
    @try {
        unsigned long rate = ((unsigned long (*)(id, SEL))objc_msgSend)(session, @selector(sampleRate));
        unsigned long ch = ((unsigned long (*)(id, SEL))objc_msgSend)(session, @selector(channelNum));
        unsigned long bps = ((unsigned long (*)(id, SEL))objc_msgSend)(session, @selector(bytesPerSample));
        [s appendFormat:@"sampleRate=%lu channelNum=%lu bytesPerSample=%lu\n", rate, ch, bps];
    } @catch (NSException *e) {
        [s appendFormat:@"读取格式异常: %@\n", e.reason];
    }
    if (gKwCaptureBlock) {
        [s appendFormat:@"\n%@", VCamDescribeBlock(gKwCaptureBlock)];
    }
    return s;
}

static NSString *VCamKuaishouCaptureReport(void)
{
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"\n== 九、快手麦克风采集回调 ==\n"];
    [out appendString:gKwCaptureInfo ?: @"（还没捕获：进直播画面后再看这里）\n"];
    if (!gKwCaptureInfo) {
        [out appendString:VCamDescribeCaptureSession()];
        [out appendString:@"\n"];
    }
    return out;
}

static void VCamHookKuaishouCapture(void)
{
    // 从 KWDaenerysAudioController 反向摸到 capture session（快手的 live 走这条路）
    Class ctrlCls = objc_getClass("KWDaenerysAudioController");
    if (ctrlCls) {
        SEL startSel = NSSelectorFromString(@"_startAudioSession");
        Method startM = class_getInstanceMethod(ctrlCls, startSel);
        if (startM) {
            IMP startOrig = method_getImplementation(startM);
            IMP startRepl = imp_implementationWithBlock(^(id obj) {
                VCamTrace(@"快手音频控制器启动会话");
                ((void (*)(id, SEL))startOrig)(obj, startSel);

                // 尝试读出它持有的 capture session 和回调 block
                @try {
                    SEL sessSel = NSSelectorFromString(@"audioCaptureSession");
                    if ([obj respondsToSelector:sessSel]) {
                        id session = ((id (*)(id, SEL))objc_msgSend)(obj, sessSel);
                        if (session) {
                            gKwCapture = (__bridge void *)session;
                            SEL blkSel = NSSelectorFromString(@"audioCaptureBlock");
                            if ([session respondsToSelector:blkSel]) {
                                id blk = ((id (*)(id, SEL))objc_msgSend)(session, blkSel);
                                if (blk) {
                                    gKwCaptureBlock = (__bridge void *)blk;
                                    gKwCaptureInfo = [VCamDescribeCaptureSession() copy];
                                    VCamTrace(@"从控制器读到快手采集回调");
                                }
                            }
                        }
                    }
                } @catch (NSException *e) {
                    VCamTrace(@"读取采集会话异常: %@", e.reason);
                }
            });
            class_replaceMethod(ctrlCls, startSel, startRepl, method_getTypeEncoding(startM));
            VCamTrace(@"已 hook KWDaenerysAudioController _startAudioSession");
        }
    }

    Class cls = objc_getClass("KWDAudioCaptureSession");
    if (!cls) return;

    SEL sel = @selector(setAudioCaptureBlock:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        IMP orig = method_getImplementation(m);
        IMP repl = imp_implementationWithBlock(^(id obj, id block) {
            gKwCapture = (__bridge void *)obj;
            gKwCaptureBlock = (__bridge void *)block;
            if (!gKwCaptureInfo) {
                gKwCaptureInfo = [VCamDescribeCaptureSession() copy];
                VCamTrace(@"抓到快手麦克风采集回调（KWDAudioCaptureSession）");
            }
            ((void (*)(id, SEL, id))orig)(obj, sel, block);
        });
        class_replaceMethod(cls, sel, repl, method_getTypeEncoding(m));
        VCamTrace(@"已 hook KWDAudioCaptureSession setAudioCaptureBlock:");
    }

    SEL startSel = @selector(startAudioCapture);
    Method startM = class_getInstanceMethod(cls, startSel);
    if (startM) {
        IMP startOrig = method_getImplementation(startM);
        IMP startRepl = imp_implementationWithBlock(^(id obj) {
            gKwCapture = (__bridge void *)obj;
            VCamTrace(@"快手开始采集麦克风");
            ((void (*)(id, SEL))startOrig)(obj, startSel);
        });
        class_replaceMethod(cls, startSel, startRepl, method_getTypeEncoding(startM));
    }
}

// 装上快手侧的探针：只观察，不改变行为
static void VCamInstallKuaishouHooks(void)
{
    // 先覆盖「所有实现类」，避免只命中接口代理类
    VCamHookKuaishouCapture();
    VCamHookAllImplementorsOfInputSpeakerAudioFrame();
    VCamHookAllImplementorsOfMultiTrackMix();

    Class engine = objc_getClass("KuaishouRtcEngine");
    if (!engine) {
        VCamTrace(@"快手 RTC 引擎不存在（当前不是快手进程）");
        return;
    }

    // 抓引擎实例 + 音频帧对象长什么样
    SEL sel = @selector(inputSpeakerAudioFrame:);
    Method m = class_getInstanceMethod(engine, sel);
    if (m) {
        IMP orig = method_getImplementation(m);
        IMP repl = imp_implementationWithBlock(^int(id obj, id frame) {
            gKuaishouRtc = (__bridge void *)obj;
            if (!gKuaishouFrameInfo) {
                gKuaishouFrameInfo = [VCamDescribeObject(frame) copy];
                VCamTrace(@"抓到快手音频帧对象: %@", [gKuaishouFrameInfo componentsSeparatedByString:@"\n"].firstObject);
            }
            return ((int (*)(id, SEL, id))orig)(obj, sel, frame);
        });
        class_replaceMethod(engine, sel, repl, method_getTypeEncoding(m));
        VCamTrace(@"已 hook KuaishouRtcEngine inputSpeakerAudioFrame:");
    }

    // 内录开关被调用时也能抓到实例
    SEL recSel = @selector(enableAudioInternalRecording);
    Method recM = class_getInstanceMethod(engine, recSel);
    if (recM) {
        IMP recOrig = method_getImplementation(recM);
        IMP recRepl = imp_implementationWithBlock(^(id obj) {
            gKuaishouRtc = (__bridge void *)obj;
            VCamTrace(@"快手开启内录，已记录 RTC 引擎实例");
            ((void (*)(id, SEL))recOrig)(obj, recSel);
        });
        class_replaceMethod(engine, recSel, recRepl, method_getTypeEncoding(recM));
    }

    // 快手往直播流混音频时一定会走这里——能同时拿到引擎实例和音频帧对象模板
    Class ext = objc_getClass("KSKNSRtcEngineExt");
    if (ext) {
        SEL mixSel = NSSelectorFromString(@"inputAudioMultiTrackDataChannelId:audioFrameArray:needPlay:needMixRtc:needMixLiveStream:timestamp:");
        Method mixM = class_getInstanceMethod(ext, mixSel);
        if (mixM) {
            IMP mixOrig = method_getImplementation(mixM);
            IMP mixRepl = imp_implementationWithBlock(^int(id obj, id channelId, id frames,
                                                           char needPlay, char needMixRtc,
                                                           char needMixLiveStream, long long ts) {
                gKuaishouRtc = (__bridge void *)obj;
                if (!gKuaishouFrameInfo) {
                    id first = [frames isKindOfClass:[NSArray class]] ? [frames firstObject] : frames;
                    if (first) {
                        gKuaishouFrameInfo = [VCamDescribeObject(first) copy];
                        VCamTrace(@"抓到快手混音调用，帧对象已记录");
                    }
                }
                return ((int (*)(id, SEL, id, id, char, char, char, long long))mixOrig)(
                    obj, mixSel, channelId, frames, needPlay, needMixRtc, needMixLiveStream, ts);
            });
            class_replaceMethod(ext, mixSel, mixRepl, method_getTypeEncoding(mixM));
            VCamTrace(@"已 hook 快手 inputAudioMultiTrack...（混音入口）");
        }
    }
}

// 抖音直播的音频采集对象（LiveStreamAudioCapture），在 startAudioCapture 时记下来
static void *gLiveAudioCapture = NULL;

// 找到音频设备模块（BAudioKitObjcAudioDeviceModule）——它管物理麦克风，静音它不会影响推送流
static id VCamFindAudioDeviceModule(id stream)
{
    SEL volSel = NSSelectorFromString(@"setCaptureVolume:");
    if (!volSel) return nil;

    if (stream) {
        NSArray *keys = @[ @"audioDeviceModule", @"adm", @"audioDevice", @"deviceModule", @"audioModule" ];
        for (NSString *key in keys) {
            @try {
                id v = [stream valueForKey:key];
                if (v && [v respondsToSelector:volSel]) return v;
            } @catch (NSException *e) {
                // 该属性不存在，试下一个
            }
        }
    }

    Class admClass = objc_getClass("BAudioKitObjcAudioDeviceModule");
    if (admClass) {
        NSArray *singletons = @[ @"sharedInstance", @"defaultModule", @"sharedModule", @"instance", @"shared" ];
        for (NSString *name in singletons) {
            SEL sel = NSSelectorFromString(name);
            if (![admClass respondsToSelector:sel]) continue;
            @try {
                id v = ((id (*)(id, SEL))objc_msgSend)((id)admClass, sel);
                if (v && [v respondsToSelector:volSel]) return v;
            } @catch (NSException *e) {
                // 忽略
            }
        }
    }
    return nil;
}

// 麦克风采集器（IESLiveAudioCapturerImp）实例，用它自己的静音接口只掐麦克风
static void *gAudioCapturer = NULL;

// 调用「数字 + 字符串」两个参数的方法（如 setAudioMute:reason:）
static BOOL VCamCallNumberString(id target, NSString *selectorName, double number, NSString *text)
{
    SEL sel = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:sel]) return NO;

    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments < 4) return NO;

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:target];
    [inv setSelector:sel];

    const char *t2 = [sig getArgumentTypeAtIndex:2];
    switch (t2 ? t2[0] : 'B') {
        case 'B': case 'c': { char c = (number != 0.0) ? 1 : 0; [inv setArgument:&c atIndex:2]; break; }
        case 'i': case 'l': { int i = (int)number; [inv setArgument:&i atIndex:2]; break; }
        case 'q': { long long q = (long long)number; [inv setArgument:&q atIndex:2]; break; }
        case 'f': { float f = (float)number; [inv setArgument:&f atIndex:2]; break; }
        case 'd': { double d = number; [inv setArgument:&d atIndex:2]; break; }
        default: return NO;
    }

    const char *t3 = [sig getArgumentTypeAtIndex:3];
    if (!t3 || t3[0] != '@') return NO;
    id s = text ? text : @"vcam";
    [inv setArgument:&s atIndex:3];

    @try { [inv invoke]; }
    @catch (NSException *e) {
        NSLog(@"[vcam] 调用 %@ 异常: %@", selectorName, e.reason);
        return NO;
    }
    return YES;
}

// 通用调用器：不知道参数是 float/double/int/BOOL，就按方法签名里的实际类型传
static BOOL VCamCallNumber(id target, NSString *selectorName, double value)
{
    SEL sel = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:sel]) return NO;

    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments < 3) return NO;

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:target];
    [inv setSelector:sel];

    const char *type = [sig getArgumentTypeAtIndex:2];
    char t = type ? type[0] : 'i';
    switch (t) {
        case 'f': { float f = (float)value; [inv setArgument:&f atIndex:2]; break; }
        case 'd': { double d = value; [inv setArgument:&d atIndex:2]; break; }
        case 'B': case 'c': { char c = (value != 0.0) ? 1 : 0; [inv setArgument:&c atIndex:2]; break; }
        case 'i': case 'l': { int i = (int)value; [inv setArgument:&i atIndex:2]; break; }
        case 'q': { long long q = (long long)value; [inv setArgument:&q atIndex:2]; break; }
        default: return NO;
    }

    @try { [inv invoke]; }
    @catch (NSException *e) {
        NSLog(@"[vcam] 调用 %@ 异常: %@", selectorName, e.reason);
        return NO;
    }
    return YES;
}

@interface VCamAudio : NSObject
+ (instancetype)shared;
- (void)start;
- (void)stop;
- (BOOL)isEnabled;
- (void)setEnabled:(BOOL)enabled;
- (BOOL)micMuteEnabled;
- (void)setMicMuteEnabled:(BOOL)enabled;
- (void)applyMicMute;
- (BOOL)targetAvailable;
@property (atomic, copy) NSString *muteMode;
@property (atomic, assign) float ksSavedVolume;
@property (atomic, assign) BOOL ksVolumeSaved;
@property (atomic, strong) NSData *latestPCM;
- (void)enablePushStreamIfNeeded;
- (NSUInteger)pushedChunks;
@end

@implementation VCamAudio {
    BOOL _running;
    int _fd;
    unsigned long long _samples;
    NSUInteger _chunks;
    BOOL _pushStreamEnabled;
    NSString *_muteMode;
}

+ (instancetype)shared
{
    static VCamAudio *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ a = [[VCamAudio alloc] init]; });
    return a;
}

- (BOOL)isEnabled
{
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"vcam_audio"];
    return v ? [v boolValue] : NO;
}

- (void)setEnabled:(BOOL)enabled
{
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"vcam_audio"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    gInjectEnabled = enabled ? 1 : 0;
    NSLog(@"[vcam] 声音内录 -> %@", enabled ? @"开" : @"关");
    [self applyMicMute];
}

// 内录时不要让麦克风把环境声混进来：把输入流静音/音量归零
- (BOOL)micMuteEnabled
{
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"vcam_mic_mute"];
    return v ? [v boolValue] : YES;
}

- (void)setMicMuteEnabled:(BOOL)enabled
{
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"vcam_mic_mute"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self applyMicMute];
}

- (void)enablePushStreamIfNeeded
{
    id target = (__bridge id)gLiveAudioCapture;
    if (!target) return;
    if (_pushStreamEnabled) return;

    BOOL ok = VCamCallNumber(target, @"enableAudioPushStream:", 1.0);
    _pushStreamEnabled = ok;
    NSLog(@"[vcam] enableAudioPushStream -> %@", ok ? @"成功" : @"失败/无此方法");
}

- (void)applyMicMute
{
    BOOL shouldMute = [self isEnabled] && [self micMuteEnabled];

    // 快手：KuaishouRtcEngineContext 单例里的麦克风输入音量
    Class ksCtxCls = objc_getClass("KuaishouRtcEngineContext");
    if (ksCtxCls) {
        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        if ([ksCtxCls respondsToSelector:sharedSel]) {
            @try {
                id ctx = ((id (*)(id, SEL))objc_msgSend)((id)ksCtxCls, sharedSel);
                if (ctx) {
                    if (shouldMute) {
                        if (!self.ksVolumeSaved) {
                            float v = ((float (*)(id, SEL))objc_msgSend)(ctx, NSSelectorFromString(@"audioInputVolume"));
                            self.ksSavedVolume = v;
                            self.ksVolumeSaved = YES;
                        }
                        if (VCamCallNumber(ctx, @"setAudioInputVolume:", 0.0)) {
                            self.muteMode = @"快手输入音量";
                            NSLog(@"[vcam] 快手掌风静音（audioInputVolume=0）");
                            return;
                        }
                    } else if (self.ksVolumeSaved) {
                        VCamCallNumber(ctx, @"setAudioInputVolume:", self.ksSavedVolume);
                        self.ksVolumeSaved = NO;
                        self.muteMode = @"快手已恢复";
                        NSLog(@"[vcam] 快手麦克风恢复（audioInputVolume=%.2f）", self.ksSavedVolume);
                        return;
                    }
                }
            } @catch (NSException *e) {
                NSLog(@"[vcam] 快手音量设置异常: %@", e.reason);
            }
        }
    }

    // 第 0 级（最精准）：设备级音量——只作用在物理麦克风上，不影响我们推送的音频
    id adm = VCamFindAudioDeviceModule((__bridge id)gLiveAudioCapture);
    if (adm && VCamCallNumber(adm, @"setCaptureVolume:", shouldMute ? 0.0 : 1.0)) {
        self.muteMode = @"设备音量";
        NSLog(@"[vcam] 麦克风%@（设备级 setCaptureVolume）", shouldMute ? @"静音" : @"恢复");
        return;
    }

    // 第 1 级：采集器自己的静音
    id capturer = (__bridge id)gAudioCapturer;
    if (capturer) {
        BOOL okCap = VCamCallNumberString(capturer, @"setAudioMute:reason:",
                                          shouldMute ? 1.0 : 0.0, @"vcam");
        if (okCap) {
            self.muteMode = @"采集器静音";
            NSLog(@"[vcam] 麦克风%@（采集器 setAudioMute）", shouldMute ? @"静音" : @"恢复");
            return;
        }
    }

    // 退路：输入流静音（会把推送的音频一起掐掉，只剩静音）
    id target = (__bridge id)gLiveAudioCapture;
    if (!target) {
        NSLog(@"[vcam] 音频对象还没出现，等开播后再静音麦克风");
        return;
    }

    // 退路：静音输入流 / 音量归零（会连推送的音频一起静音）
    BOOL ok = VCamCallNumber(target, @"setInputStreamMute:", shouldMute ? 1.0 : 0.0);
    NSString *how = @"setInputStreamMute:";
    if (!ok) {
        ok = VCamCallNumber(target, @"setInputStreamVolume:", shouldMute ? 0.0 : 1.0);
        how = @"setInputStreamVolume:";
    }
    if (!ok) {
        ok = VCamCallNumber(target, @"setCaptureVolume:", shouldMute ? 0.0 : 1.0);
        how = @"setCaptureVolume:";
    }

    NSLog(@"[vcam] 麦克风静音 %@（%@ %@）", shouldMute ? @"开" : @"关", how, ok ? @"成功" : @"无可用接口");
}

- (BOOL)targetAvailable
{
    return gLiveAudioCapture != NULL;
}

- (NSUInteger)pushedChunks { return _chunks; }

- (void)start
{
    if (_running) return;
    _running = YES;
    [NSThread detachNewThreadSelector:@selector(readLoop) toTarget:self withObject:nil];
}

- (void)stop
{
    _running = NO;
    int fd = _fd;
    if (fd > 0) shutdown(fd, SHUT_RDWR);
}

- (void)readLoop
{
    @autoreleasepool {
        // 20ms @ 48kHz 立体声 16bit = 3840 字节
        const size_t chunkBytes = 3840;
        NSMutableData *buf = [NSMutableData dataWithLength:chunkBytes];

        while (_running) {
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) {
                [NSThread sleepForTimeInterval:2.0];
                continue;
            }
            int one = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            struct timeval tv = { 5, 0 };
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

            struct sockaddr_in addr;
            memset(&addr, 0, sizeof(addr));
            addr.sin_family = AF_INET;
            addr.sin_port = htons(kAudioPort);
            addr.sin_addr.s_addr = inet_addr([VCamHost() UTF8String]);

            if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
                _fd = fd;
                NSLog(@"[vcam] 音频通道已连接 %@:%d", VCamHost(), kAudioPort);
                while (_running) {
                    int r = VCamReadFull(fd, buf.mutableBytes, chunkBytes);
                    if (r == -2) continue;             // 还没数据，继续等
                    if (r != 1) {
                        NSLog(@"[vcam] 音频通道断开 r=%d errno=%d", r, r < 0 ? -r : 0);
                        break;
                    }
                    [self pushAudio:buf];
                }
                _fd = -1;
            }

            close(fd);
            if (_running) [NSThread sleepForTimeInterval:2.0];
        }
    }
}

- (void)pushAudio:(NSData *)pcm
{
    self.latestPCM = pcm;

    // 同步一份到纯 C 缓冲，供音频实时线程使用（那边不能碰 Objective-C）
    NSUInteger frames = pcm.length / 4;   // 16bit 立体声
    if (frames > VCAM_PCM_MAX_FRAMES) frames = VCAM_PCM_MAX_FRAMES;
    if (frames > 1) {
        memcpy(gPCM, pcm.bytes, frames * 4);
        gPCMReadPos = 0.0;
        gPCMFrames = (int)frames;

        // 计算峰值电平（每 8 个采样取一个，够用且省 CPU）
        const int16_t *s = (const int16_t *)pcm.bytes;
        int peak = 0;
        for (NSUInteger i = 0; i < frames * 2; i += 8) {
            int v = s[i] < 0 ? -s[i] : s[i];
            if (v > peak) peak = v;
        }
        gLevelPCM = peak / 32768.0f;
    }

    if (![self isEnabled]) return;

    id target = (__bridge id)gLiveAudioCapture;
    if (!target) return;

    // 必须先打开外部推流通道，否则 push 的帧会被丢弃
    [self enablePushStreamIfNeeded];

    SEL sel = NSSelectorFromString(@"pushAudioBuffer:andDataLen:sampleRate:channels:andBitsPerSample:timestamp:");
    if (![target respondsToSelector:sel]) return;

    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments < 8) return;

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:target];
    [inv setSelector:sel];

    char *bytes = (char *)pcm.bytes;
    unsigned long len = (unsigned long)pcm.length;
    int sampleRate = 48000;
    int channels = 2;
    int bitsPerSample = 16;
    long long timestamp = (long long)(_samples * 1000ULL / 48000ULL);

    [inv setArgument:&bytes atIndex:2];
    [inv setArgument:&len atIndex:3];
    [inv setArgument:&sampleRate atIndex:4];
    [inv setArgument:&channels atIndex:5];
    [inv setArgument:&bitsPerSample atIndex:6];
    [inv setArgument:&timestamp atIndex:7];

    @try {
        [inv invoke];
    } @catch (NSException *e) {
        NSLog(@"[vcam] 音频注入异常: %@", e.reason);
        gLiveAudioCapture = NULL;
        return;
    }

    _samples += pcm.length / 4;   // 16bit × 2 声道 = 4 字节/采样
    _chunks += 1;
    if (_chunks == 1) {
        NSLog(@"[vcam] 已推送第一块音频 %lu 字节", (unsigned long)pcm.length);
    }
}

@end

// ======================= 音频注入（抖音：LiveStreamAudioCapture） =======================

static void VCamInstallAudioHooks(void)
{
    Class capCls = objc_getClass("IESLiveAudioCapturerImp");
    if (capCls) {
        SEL capSel = NSSelectorFromString(@"startAudioCaptureWithReason:completion:");
        Method capMethod = class_getInstanceMethod(capCls, capSel);
        if (capMethod) {
            IMP capOrig = method_getImplementation(capMethod);
            IMP capRepl = imp_implementationWithBlock(^(id obj, id reason, id completion) {
                gAudioCapturer = (__bridge void *)obj;
                VCamTrace(@"IESLiveAudioCapturerImp 开始采集，已记录实例（可用精确静音）");
                ((void (*)(id, SEL, id, id))capOrig)(obj, capSel, reason, completion);
                [[VCamAudio shared] applyMicMute];
            });
            class_replaceMethod(capCls, capSel, capRepl, method_getTypeEncoding(capMethod));
        }
    }

    Class cls = objc_getClass("LiveStreamAudioCapture");
    if (!cls) {
        NSLog(@"[vcam] 找不到 LiveStreamAudioCapture，音频注入不可用");
        return;
    }

    SEL startSel = @selector(startAudioCapture);
    Method m1 = class_getInstanceMethod(cls, startSel);
    if (m1) {
        IMP o1 = method_getImplementation(m1);
        IMP r1 = imp_implementationWithBlock(^(id obj) {
            gLiveAudioCapture = (__bridge void *)obj;
            VCamTrace(@"LiveStreamAudioCapture 开始采集，已记录实例，音频注入就绪");
            ((void (*)(id, SEL))o1)(obj, startSel);
            // 开播后立刻：打开外部推流 + 按当前开关状态静音麦克风
            [[VCamAudio shared] enablePushStreamIfNeeded];
            [[VCamAudio shared] applyMicMute];
        });
        class_replaceMethod(cls, startSel, r1, method_getTypeEncoding(m1));
    }

    SEL stopSel = @selector(stopAudioCapture);
    Method m2 = class_getInstanceMethod(cls, stopSel);
    if (m2) {
        IMP o2 = method_getImplementation(m2);
        IMP r2 = imp_implementationWithBlock(^(id obj) {
            ((void (*)(id, SEL))o2)(obj, stopSel);
            if (gLiveAudioCapture == (__bridge void *)obj) gLiveAudioCapture = NULL;
            VCamTrace(@"LiveStreamAudioCapture 停止采集，清除实例");
        });
        class_replaceMethod(cls, stopSel, r2, method_getTypeEncoding(m2));
    }

    VCamTrace(@"音频注入 hook 已安装");
}

// ======================= 悬浮控制面板（奶油 + 暖黄） =======================

static UIColor *VCamInk(void)    { return [UIColor colorWithRed:0.18 green:0.17 blue:0.14 alpha:1.0]; }
static UIColor *VCamCard(void)   { return [UIColor colorWithRed:1.00 green:0.99 blue:0.96 alpha:0.97]; }
static UIColor *VCamAccent(void) { return [UIColor colorWithRed:0.96 green:0.81 blue:0.47 alpha:1.0]; }
static UIColor *VCamMuted(void)  { return [UIColor colorWithRed:0.64 green:0.58 blue:0.49 alpha:1.0]; }

// 触摸穿透的窗口：只有面板本身接收点击，其它区域照常交给抖音
@interface VCamWindow : UIWindow
@end

@implementation VCamWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view || v == nil) return nil;
    return v;
}
@end

@interface VCamOverlay : NSObject
+ (instancetype)shared;
- (void)install;
@end

@implementation VCamOverlay {
    VCamWindow *_window;
    UIView *_bubble;
    UIView *_card;
    UILabel *_statusDot;
    UILabel *_statusText;
    UILabel *_footer;
    UILabel *_rotationLabel;
    UIView *_pcmTrack;
    UIView *_pcmBar;
    UIView *_micTrack;
    UIView *_micBar;
    float _pcmDisp;
    float _micDisp;
    UITextField *_hostField;
    UISwitch *_enableSwitch;
    UISwitch *_mirrorSwitch;
    UISwitch *_audioSwitch;
    UISwitch *_auSwitch;
    UISwitch *_micMuteSwitch;
    UISegmentedControl *_fitSegment;
    NSTimer *_timer;
    NSTimer *_meterTimer;
    BOOL _expanded;
}

+ (instancetype)shared
{
    static VCamOverlay *o = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ o = [[VCamOverlay alloc] init]; });
    return o;
}

- (BOOL)enabled
{
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"vcam_enabled"];
    return v ? [v boolValue] : YES;
}

- (void)install
{
    if (_window) return;

    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)s; break; }
        if (!scene) scene = (UIWindowScene *)s;
    }
    if (!scene) {
        NSLog(@"[vcam] 没有可用的 UIWindowScene，面板不显示");
        return;
    }

    _window = [[VCamWindow alloc] initWithWindowScene:scene];
    _window.windowLevel = UIWindowLevelAlert + 1;
    _window.backgroundColor = [UIColor clearColor];
    _window.rootViewController = [UIViewController new];
    _window.rootViewController.view.backgroundColor = [UIColor clearColor];
    _window.hidden = NO;

    [self buildBubble];
    [self buildCard];

    _meterTimer = [NSTimer scheduledTimerWithTimeInterval:0.08
                                                   target:self
                                                 selector:@selector(updateMeters)
                                                 userInfo:nil
                                                  repeats:YES];

    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                              target:self
                                            selector:@selector(refreshStatus)
                                            userInfo:nil
                                             repeats:YES];
    NSLog(@"[vcam] 控制面板已显示");
}

- (void)buildBubble
{
    CGFloat size = 48;
    CGFloat x = _window.bounds.size.width - size - 14;
    CGFloat y = 120;
    _bubble = [[UIView alloc] initWithFrame:CGRectMake(x, y, size, size)];
    _bubble.backgroundColor = VCamCard();
    _bubble.layer.cornerRadius = size / 2.0;
    _bubble.layer.shadowColor = [UIColor blackColor].CGColor;
    _bubble.layer.shadowOpacity = 0.18;
    _bubble.layer.shadowRadius = 8;
    _bubble.layer.shadowOffset = CGSizeMake(0, 3);

    UILabel *cat = [[UILabel alloc] initWithFrame:_bubble.bounds];
    cat.text = @"🐱";
    cat.font = [UIFont systemFontOfSize:22];
    cat.textAlignment = NSTextAlignmentCenter;
    cat.userInteractionEnabled = NO;
    [_bubble addSubview:cat];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleCard)];
    [_bubble addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [_bubble addGestureRecognizer:pan];

    [_window.rootViewController.view addSubview:_bubble];
}

- (UILabel *)makeLabel:(NSString *)text frame:(CGRect)frame size:(CGFloat)size bold:(BOOL)bold
{
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    l.text = text;
    l.textColor = VCamInk();
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    return l;
}

- (void)buildCard
{
    CGFloat w = 236, h = 512;
    CGFloat x = _window.bounds.size.width - w - 14;
    CGFloat y = 120;
    _card = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, h)];
    _card.backgroundColor = VCamCard();
    _card.layer.cornerRadius = 18;
    _card.layer.shadowColor = [UIColor blackColor].CGColor;
    _card.layer.shadowOpacity = 0.2;
    _card.layer.shadowRadius = 14;
    _card.layer.shadowOffset = CGSizeMake(0, 6);
    _card.hidden = YES;

    UILabel *title = [self makeLabel:@"虚拟摄像头" frame:CGRectMake(16, 14, 150, 22) size:15 bold:YES];
    [_card addSubview:title];

    UIButton *collapse = [UIButton buttonWithType:UIButtonTypeSystem];
    collapse.frame = CGRectMake(w - 44, 10, 32, 30);
    [collapse setTitle:@"—" forState:UIControlStateNormal];
    [collapse setTitleColor:VCamMuted() forState:UIControlStateNormal];
    [collapse addTarget:self action:@selector(toggleCard) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:collapse];

    _statusDot = [self makeLabel:@"●" frame:CGRectMake(16, 42, 14, 18) size:12 bold:NO];
    _statusDot.textColor = VCamMuted();
    [_card addSubview:_statusDot];
    _statusText = [self makeLabel:@"未连接" frame:CGRectMake(32, 42, 190, 18) size:12 bold:NO];
    _statusText.textColor = VCamMuted();
    [_card addSubview:_statusText];

    // 替换画面
    [_card addSubview:[self makeLabel:@"替换画面" frame:CGRectMake(16, 72, 120, 24) size:13.5 bold:YES]];
    _enableSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 68, 68, 52, 32)];
    _enableSwitch.onTintColor = VCamAccent();
    _enableSwitch.on = [self enabled];
    [_enableSwitch addTarget:self action:@selector(enableChanged:) forControlEvents:UIControlEventValueChanged];
    [_card addSubview:_enableSwitch];

    // 镜像
    [_card addSubview:[self makeLabel:@"左右镜像" frame:CGRectMake(16, 108, 120, 24) size:13.5 bold:YES]];
    _mirrorSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 68, 104, 52, 32)];
    _mirrorSwitch.onTintColor = VCamAccent();
    _mirrorSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_mirror"];
    [_mirrorSwitch addTarget:self action:@selector(mirrorChanged:) forControlEvents:UIControlEventValueChanged];
    [_card addSubview:_mirrorSwitch];

    // 画面适配
    [_fitSegment removeFromSuperview];
    _fitSegment = [[UISegmentedControl alloc] initWithItems:@[ @"等比", @"填充" ]];
    _fitSegment.frame = CGRectMake(16, 142, w - 32, 30);
    _fitSegment.selectedSegmentIndex = [[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_fill"] ? 1 : 0;
    _fitSegment.tintColor = VCamAccent();
    [_fitSegment addTarget:self action:@selector(fitChanged:) forControlEvents:UIControlEventValueChanged];
    [_card addSubview:_fitSegment];

    // 电脑 IP（可手动修改）
    [_card addSubview:[self makeLabel:@"电脑 IP" frame:CGRectMake(16, 178, 120, 20) size:12.5 bold:YES]];

    _hostField = [[UITextField alloc] initWithFrame:CGRectMake(16, 198, 150, 30)];
    _hostField.text = VCamHost();
    _hostField.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    _hostField.textColor = VCamInk();
    _hostField.backgroundColor = [UIColor colorWithWhite:0 alpha:0.05];
    _hostField.layer.cornerRadius = 8;
    _hostField.borderStyle = UITextBorderStyleNone;
    _hostField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    _hostField.returnKeyType = UIReturnKeyDone;
    _hostField.autocorrectionType = UITextAutocorrectionTypeNo;
    _hostField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _hostField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 30)];
    _hostField.leftViewMode = UITextFieldViewModeAlways;
    [_card addSubview:_hostField];

    UIButton *connectBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    connectBtn.frame = CGRectMake(172, 198, 48, 30);
    connectBtn.backgroundColor = VCamAccent();
    connectBtn.layer.cornerRadius = 8;
    [connectBtn setTitle:@"连接" forState:UIControlStateNormal];
    [connectBtn setTitleColor:VCamInk() forState:UIControlStateNormal];
    connectBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12.5];
    [connectBtn addTarget:self action:@selector(connectTapped) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:connectBtn];

    // 声音内录
    // 画面旋转（每次 90°）
    [_card addSubview:[self makeLabel:@"画面旋转" frame:CGRectMake(16, 232, 84, 24) size:13.5 bold:YES]];

    UIButton *rotL = [UIButton buttonWithType:UIButtonTypeSystem];
    rotL.frame = CGRectMake(104, 232, 56, 26);
    rotL.backgroundColor = [UIColor colorWithWhite:0 alpha:0.06];
    rotL.layer.cornerRadius = 7;
    [rotL setTitle:@"↺ 90°" forState:UIControlStateNormal];
    [rotL setTitleColor:VCamInk() forState:UIControlStateNormal];
    rotL.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [rotL addTarget:self action:@selector(rotateLeft) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:rotL];

    UIButton *rotR = [UIButton buttonWithType:UIButtonTypeSystem];
    rotR.frame = CGRectMake(164, 232, 56, 26);
    rotR.backgroundColor = [UIColor colorWithWhite:0 alpha:0.06];
    rotR.layer.cornerRadius = 7;
    [rotR setTitle:@"↻ 90°" forState:UIControlStateNormal];
    [rotR setTitleColor:VCamInk() forState:UIControlStateNormal];
    rotR.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [rotR addTarget:self action:@selector(rotateRight) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:rotR];

    _rotationLabel = [self makeLabel:@"" frame:CGRectMake(16, 258, 120, 16) size:11 bold:NO];
    _rotationLabel.textColor = VCamMuted();
    [_card addSubview:_rotationLabel];
    [self updateRotationLabel];

    [_card addSubview:[self makeLabel:@"声音内录" frame:CGRectMake(16, 280, 120, 24) size:13.5 bold:YES]];
    _audioSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 68, 276, 52, 32)];
    _audioSwitch.onTintColor = VCamAccent();
    _audioSwitch.on = [[VCamAudio shared] isEnabled];
    [_audioSwitch addTarget:self action:@selector(audioChanged:) forControlEvents:UIControlEventValueChanged];
    [_card addSubview:_audioSwitch];

    // 静音麦克风（内录时用电脑声音顶替麦克风）
    [_card addSubview:[self makeLabel:@"静音麦克风" frame:CGRectMake(16, 318, 120, 24) size:13.5 bold:YES]];
    _micMuteSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 68, 314, 52, 32)];
    _micMuteSwitch.onTintColor = VCamAccent();
    _micMuteSwitch.on = [[VCamAudio shared] micMuteEnabled];
    [_micMuteSwitch addTarget:self action:@selector(micMuteChanged:) forControlEvents:UIControlEventValueChanged];
    [_card addSubview:_micMuteSwitch];

    // 底层实验开关（危险：开启后重启 App 才会生效）
    [_card addSubview:[self makeLabel:@"底层实验" frame:CGRectMake(16, 356, 120, 24) size:13.5 bold:YES]];
    _auSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 68, 352, 52, 32)];
    _auSwitch.onTintColor = [UIColor colorWithRed:0.90 green:0.45 blue:0.35 alpha:1.0];
    _auSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_au_hook"];
    [_auSwitch addTarget:self action:@selector(auHookChanged:) forControlEvents:UIControlEventValueChanged];
    [_card addSubview:_auSwitch];

    // 实时电平：电脑音频 / 麦克风
    [_card addSubview:[self makeLabel:@"🔊" frame:CGRectMake(16, 390, 24, 20) size:14 bold:NO]];
    _pcmTrack = [[UIView alloc] initWithFrame:CGRectMake(44, 394, 176, 12)];
    _pcmTrack.backgroundColor = [UIColor colorWithWhite:0 alpha:0.08];
    _pcmTrack.layer.cornerRadius = 6;
    _pcmTrack.clipsToBounds = YES;
    [_card addSubview:_pcmTrack];
    _pcmBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 12)];
    _pcmBar.backgroundColor = VCamAccent();
    [_pcmTrack addSubview:_pcmBar];

    [_card addSubview:[self makeLabel:@"🎤" frame:CGRectMake(16, 414, 24, 20) size:14 bold:NO]];
    _micTrack = [[UIView alloc] initWithFrame:CGRectMake(44, 418, 176, 12)];
    _micTrack.backgroundColor = [UIColor colorWithWhite:0 alpha:0.08];
    _micTrack.layer.cornerRadius = 6;
    _micTrack.clipsToBounds = YES;
    [_card addSubview:_micTrack];
    _micBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 12)];
    _micBar.backgroundColor = [UIColor colorWithRed:0.45 green:0.62 blue:0.42 alpha:1.0];
    [_micTrack addSubview:_micBar];

    _footer = [self makeLabel:@"" frame:CGRectMake(16, 446, w - 32, 18) size:11 bold:NO];
    _footer.textColor = VCamMuted();
    [_card addSubview:_footer];

    UIButton *audioBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    audioBtn.frame = CGRectMake(16, 470, w - 32, 30);
    audioBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.06];
    audioBtn.layer.cornerRadius = 8;
    [audioBtn setTitle:@"查看音频路径诊断" forState:UIControlStateNormal];
    [audioBtn setTitleColor:VCamInk() forState:UIControlStateNormal];
    audioBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [audioBtn addTarget:self action:@selector(showAudioReport) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:audioBtn];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [title addGestureRecognizer:pan];
    title.userInteractionEnabled = YES;

    [_window.rootViewController.view addSubview:_card];
}

- (void)toggleCard
{
    _expanded = !_expanded;
    _card.hidden = !_expanded;
    _bubble.hidden = _expanded;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan
{
    UIView *target = (_expanded ? _card : _bubble);
    CGPoint delta = [pan translationInView:_window];
    CGRect f = target.frame;
    f.origin.x += delta.x;
    f.origin.y += delta.y;
    f.origin.x = MAX(4, MIN(f.origin.x, _window.bounds.size.width - f.size.width - 4));
    f.origin.y = MAX(60, MIN(f.origin.y, _window.bounds.size.height - f.size.height - 40));
    target.frame = f;
    [pan setTranslation:CGPointZero inView:_window];
}

- (void)enableChanged:(UISwitch *)s
{
    [[NSUserDefaults standardUserDefaults] setBool:s.on forKey:@"vcam_enabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[vcam] 替换画面 -> %@", s.on ? @"开" : @"关");
}

- (void)mirrorChanged:(UISwitch *)s
{
    [[NSUserDefaults standardUserDefaults] setBool:s.on forKey:@"vcam_mirror"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)fitChanged:(UISegmentedControl *)seg
{
    [[NSUserDefaults standardUserDefaults] setBool:seg.selectedSegmentIndex == 1 forKey:@"vcam_fill"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)connectTapped
{
    NSString *ip = [_hostField.text stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (ip.length == 0) {
        _hostField.text = VCamHost();
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:ip forKey:@"vcam_host"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [_hostField resignFirstResponder];
    [[VCamClient shared] restart];
    NSLog(@"[vcam] 电脑 IP 改为 %@，正在重连", ip);
}

- (void)showAudioReport
{
    NSString *text = VCamAudioReport();
    [[UIPasteboard generalPasteboard] setString:text];
    NSLog(@"[vcam] 音频诊断已复制到剪贴板");

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = self->_window.rootViewController;
        if (!root) return;

        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = VCamCard();
        CGFloat W = self->_window.bounds.size.width;
        CGFloat H = self->_window.bounds.size.height;

        UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(0, 88, W, H - 88)];
        tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tv.text = text;
        tv.editable = NO;
        tv.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
        tv.textColor = VCamInk();
        tv.backgroundColor = VCamCard();
        [vc.view addSubview:tv];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 48, W - 100, 24)];
        title.text = @"音频路径诊断（已复制到剪贴板）";
        title.font = [UIFont boldSystemFontOfSize:13];
        title.textColor = VCamInk();
        title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [vc.view addSubview:title];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(W - 76, 44, 60, 32);
        close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        close.backgroundColor = VCamAccent();
        close.layer.cornerRadius = 8;
        [close setTitle:@"关闭" forState:UIControlStateNormal];
        [close setTitleColor:VCamInk() forState:UIControlStateNormal];
        close.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [close addTarget:self action:@selector(dismissReport) forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:close];

        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        [root presentViewController:vc animated:YES completion:nil];
    });
}

- (void)dismissReport
{
    UIViewController *root = _window.rootViewController;
    [root dismissViewControllerAnimated:YES completion:nil];
}

// 电平条动画：上升快、下降慢，像真实音频表
- (void)updateMeters
{
    if (!_pcmBar || !_micBar) return;

    float pcm = gLevelPCM;
    float mic = gLevelMic;

    _pcmDisp = pcm > _pcmDisp ? pcm : _pcmDisp * 0.82f;
    _micDisp = mic > _micDisp ? mic : _micDisp * 0.82f;

    CGFloat maxW = _pcmTrack.bounds.size.width;
    CGFloat pcmW = maxW * MIN(1.0, sqrtf(_pcmDisp) * 1.35f);
    CGFloat micW = maxW * MIN(1.0, sqrtf(_micDisp) * 1.35f);

    _pcmBar.frame = CGRectMake(0, 0, pcmW, 12);
    _micBar.frame = CGRectMake(0, 0, micW, 12);

    // 底层开关没开时，麦克风电平读不到
    BOOL hookOn = [[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_au_hook"];
    _micBar.backgroundColor = hookOn
        ? [UIColor colorWithRed:0.45 green:0.62 blue:0.42 alpha:1.0]
        : [UIColor colorWithWhite:0.6 alpha:0.5];
}

- (void)audioChanged:(UISwitch *)s
{
    [[VCamAudio shared] setEnabled:s.on];
}

- (void)auHookChanged:(UISwitch *)s
{
    [[NSUserDefaults standardUserDefaults] setBool:s.on forKey:@"vcam_au_hook"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    VCamLogLine([NSString stringWithFormat:@"用户切换底层实验开关 -> %@（重启后生效）", s.on ? @"开" : @"关"]);
}

- (void)micMuteChanged:(UISwitch *)s
{
    [[VCamAudio shared] setMicMuteEnabled:s.on];
}

#pragma mark - 画面旋转

- (NSInteger)rotation
{
    NSInteger r = [[NSUserDefaults standardUserDefaults] integerForKey:@"vcam_rotation"];
    return ((r % 360) + 360) % 360;
}

- (void)setRotation:(NSInteger)degrees
{
    NSInteger r = ((degrees % 360) + 360) % 360;
    [[NSUserDefaults standardUserDefaults] setInteger:r forKey:@"vcam_rotation"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self updateRotationLabel];
    NSLog(@"[vcam] 旋转 -> %ld°", (long)r);
}

- (void)rotateLeft
{
    [self setRotation:[self rotation] - 90];
}

- (void)rotateRight
{
    [self setRotation:[self rotation] + 90];
}

- (void)updateRotationLabel
{
    if (!_rotationLabel) return;
    NSInteger r = [self rotation];
    _rotationLabel.text = r == 0
        ? @"当前 0°（未旋转）"
        : [NSString stringWithFormat:@"当前 %ld°", (long)r];
}

- (void)refreshStatus
{
    if (!_statusText) return;
    VCamClient *c = [VCamClient shared];
    BOOL connected = c.latestAt > 0 &&
        ([NSDate timeIntervalSinceReferenceDate] - c.latestAt) < kStaleSeconds;
    _statusDot.textColor = connected ? [UIColor colorWithRed:0.55 green:0.66 blue:0.44 alpha:1.0] : VCamMuted();
    if (connected) {
        _statusText.text = @"已连接电脑";
    } else {
        NSString *why = c.lastReason;
        _statusText.text = why.length ? [NSString stringWithFormat:@"未连接 · %@", why] : @"未连接";
    }
    VCamAudio *audio = [VCamAudio shared];
    NSString *audioDesc;
    if (!audio.isEnabled) {
        audioDesc = @"关";
    } else if (!audio.targetAvailable) {
        audioDesc = @"未适配本App";
    } else {
        audioDesc = [NSString stringWithFormat:@"%lu 块", (unsigned long)audio.pushedChunks];
    }
    NSString *muteDesc = @"";
    if (audio.isEnabled && audio.micMuteEnabled) {
        muteDesc = [NSString stringWithFormat:@" · 静音:%@", audio.muteMode ?: @"未知"];
    }
    _footer.text = [NSString stringWithFormat:@"%lu 帧 · 延迟 %.1fs · 音频 %@%@",
                    (unsigned long)c.frameCount,
                    c.latestAt ? ([NSDate timeIntervalSinceReferenceDate] - c.latestAt) : 0.0,
                    audioDesc, muteDesc];
}

@end

// ======================= 底层音频拦截（AudioUnitRender） =======================
//
// 稳定要点：
//   1. 重绑定只改「当前值确实等于真实 AudioUnitRender 地址」的槽位（用 dlsym 校验）
//      否则跳过，绝不覆盖无关指针
//   2. 实时线程里不调用任何 ObjC、不查属性、不加锁
//   3. 单元格式在 AudioUnitInitialize 时（普通线程）预先查好并缓存
//   4. 任何不认识的格式一律放行原始数据，宁可没效果也不崩

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/vm_param.h>
#import <mach/vm_map.h>
#import <mach/mach.h>
#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import <math.h>
#import <string.h>

// 底层 AudioUnit 拦截：代码可用，但默认不生效，
// 只有面板上的「底层实验」开关打开才启用（默认关闭，稳定优先）
static const BOOL kEnableAudioUnitHook = YES;

// —— PCM 交换缓冲：网络线程写，音频线程读，纯 C 数据，不做任何 Objective-C 操作 ——

// —— 每个 AudioUnit 的缓存（在 AudioUnitInitialize 时填好）——
typedef struct {
    AudioUnit unit;
    int valid;
    int isInput;
    int isFloat;
    int bits;
    int channels;
    double ratio;
} VCamUnitInfo;

static VCamUnitInfo gUnits[8];
static OSStatus (*gOrigAudioUnitRender)(AudioUnit, UInt32, const AudioTimeStamp *,
                                        UInt32, UInt32, AudioBufferList *) = NULL;
static int gRenderCalls = 0;
static int gRenderFills = 0;

// 只改「确实指向 symbol 真实地址」的槽位
static int VCamRebindSymbol(const char *symbol, void *replacement, void **original)
{
    // 插件加载时机很早，AudioToolbox 可能还没被加载，先主动 dlopen
    static BOOL audioToolboxLoaded = NO;
    if (!audioToolboxLoaded) {
        audioToolboxLoaded = YES;
        dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY | RTLD_GLOBAL);
    }

    void *real = dlsym(RTLD_DEFAULT, symbol);
    if (!real) return 0;

    int patched = 0;
    uint32_t imageCount = _dyld_image_count();

    for (uint32_t i = 0; i < imageCount; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) continue;

        const char *imageName = _dyld_get_image_name(i);
        if (imageName && (strncmp(imageName, "/System/", 8) == 0 ||
                          strncmp(imageName, "/usr/lib/", 9) == 0)) {
            continue; // 系统库内部调用不走 GOT，跳过更安全
        }

        const struct mach_header_64 *mh = (const struct mach_header_64 *)header;
        const struct symtab_command *symtabCmd = NULL;
        const struct dysymtab_command *dysymCmd = NULL;
        uint64_t textVmaddr = 0;

        const struct load_command *cmd =
            (const struct load_command *)((const uint8_t *)mh + sizeof(struct mach_header_64));
        for (uint32_t c = 0; c < mh->ncmds; c++) {
            if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
                if (strcmp(seg->segname, "__TEXT") == 0) textVmaddr = seg->vmaddr;
            } else if (cmd->cmd == LC_SYMTAB) {
                symtabCmd = (const struct symtab_command *)cmd;
            } else if (cmd->cmd == LC_DYSYMTAB) {
                dysymCmd = (const struct dysymtab_command *)cmd;
            }
            cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
        }
        if (!symtabCmd || !dysymCmd) continue;

        const char *strtab = (const char *)mh + symtabCmd->stroff;
        const struct nlist_64 *symtab =
            (const struct nlist_64 *)((const uint8_t *)mh + symtabCmd->symoff);
        const uint32_t *indirect =
            (const uint32_t *)((const uint8_t *)mh + dysymCmd->indirectsymoff);

        cmd = (const struct load_command *)((const uint8_t *)mh + sizeof(struct mach_header_64));
        for (uint32_t c = 0; c < mh->ncmds; c++) {
            if (cmd->cmd != LC_SEGMENT_64) {
                cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
                continue;
            }
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            const struct section_64 *section =
                (const struct section_64 *)((const uint8_t *)seg + sizeof(struct segment_command_64));

            for (uint32_t s = 0; s < seg->nsects; s++, section++) {
                uint32_t type = section->flags & SECTION_TYPE;
                if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;

                void **slots = (void **)((uint8_t *)mh + (section->addr - textVmaddr));
                uint32_t count = (uint32_t)(section->size / sizeof(void *));
                if (section->reserved1 + count > dysymCmd->nindirectsyms) continue;  // 间接表越界保护

                vm_address_t page = (vm_address_t)slots & ~(vm_page_size - 1);
                vm_size_t pageSize = section->size + ((vm_address_t)slots - page);
                kern_return_t kr = vm_protect(mach_task_self(), page, pageSize, false,
                                              VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                if (kr != KERN_SUCCESS) continue; // 改不了就不碰，避免写只读页崩溃

                for (uint32_t k = 0; k < count; k++) {
                    uint32_t symIndex = indirect[section->reserved1 + k];
                    if (symIndex == INDIRECT_SYMBOL_LOCAL || symIndex == INDIRECT_SYMBOL_ABS) continue;
                    if (symIndex >= symtabCmd->nsyms) continue;              // 越界保护
                    uint32_t strx = symtab[symIndex].n_un.n_strx;
                    if (strx == 0 || strx >= symtabCmd->strsize) continue;   // 字符串越界保护
                    const char *name = strtab + strx;
                    if (!name) continue;
                    if (name[0] != '_' || strcmp(name + 1, symbol) != 0) continue;

                    // 名字匹配即替换：延迟绑定的槽位此时可能还是桩函数，
                    // 原实现统一用 dlsym 拿到的真实地址
                    if (original) *original = real;
                    if (slots[k] != replacement) {
                        slots[k] = replacement;
                        patched += 1;
                    }
                }
            }
            cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
        }
    }
    return patched;
}

static VCamUnitInfo *VCamInfoForUnit(AudioUnit unit, int create)
{
    for (int i = 0; i < 8; i++) {
        if (gUnits[i].valid && gUnits[i].unit == unit) return &gUnits[i];
    }
    if (!create) return NULL;
    for (int i = 0; i < 8; i++) {
        if (!gUnits[i].valid) {
            memset(&gUnits[i], 0, sizeof(VCamUnitInfo));
            gUnits[i].unit = unit;
            return &gUnits[i];
        }
    }
    return NULL;
}

// 在 AudioUnitInitialize 之后调用（普通线程，安全）
static void VCamRecordUnitFormat(AudioUnit unit)
{
    VCamUnitInfo *info = VCamInfoForUnit(unit, 1);
    if (!info) return;

    UInt32 enableIO = 0;
    UInt32 size = sizeof(enableIO);
    OSStatus st = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1, &enableIO, &size);
    info->isInput = (st == noErr && enableIO != 0);

    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    size = sizeof(fmt);
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, 1, &fmt, &size) != noErr) {
        info->valid = 0;
        return;
    }

    info->isFloat = (fmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    info->bits = (int)fmt.mBitsPerChannel;
    info->channels = (int)fmt.mChannelsPerFrame;
    info->ratio = fmt.mSampleRate > 0 ? fmt.mSampleRate / 48000.0 : 1.0;
    info->valid = 1;

    VCamTrace(@"AudioUnit 记录: 输入=%@ %.0fHz %d 通道 %@",
              info->isInput ? @"是" : @"否",
              fmt.mSampleRate, info->channels, info->isFloat ? @"float" : @"int");
}

// 实时线程：只用缓存 + 纯 C 内存，不加锁、不调 ObjC
static void VCamFillFromPCM(AudioBufferList *ioData, UInt32 frames, VCamUnitInfo *info)
{
    int pcmFrames = gPCMFrames;
    if (pcmFrames < 2 || !ioData) return;

    int channels = info->channels > 0 ? info->channels : 1;
    double ratio = info->ratio > 0 ? info->ratio : 1.0;
    int isFloat = info->isFloat;
    int is16 = (info->bits == 16) && !isFloat;
    if (!isFloat && !is16) return; // 不认识的格式不动

    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        AudioBuffer *buf = &ioData->mBuffers[b];
        if (!buf->mData) continue;

        UInt32 bufChannels = buf->mNumberChannels ? buf->mNumberChannels : (UInt32)channels;
        size_t sampleBytes = isFloat ? 4 : 2;
        size_t availFrames = buf->mDataByteSize / (bufChannels * sampleBytes);
        UInt32 n = frames < availFrames ? frames : (UInt32)availFrames;

        double pos = gPCMReadPos;
        for (UInt32 i = 0; i < n; i++) {
            int idx = (int)pos % pcmFrames;
            int16_t left = gPCM[idx * 2];
            int16_t right = gPCM[idx * 2 + 1];

            if (isFloat) {
                float *dst = (float *)buf->mData;
                dst[i * bufChannels + 0] = left / 32768.0f;
                if (bufChannels > 1) dst[i * bufChannels + 1] = right / 32768.0f;
                for (UInt32 c = 2; c < bufChannels; c++) dst[i * bufChannels + c] = 0.0f;
            } else {
                int16_t *dst = (int16_t *)buf->mData;
                dst[i * bufChannels + 0] = left;
                if (bufChannels > 1) dst[i * bufChannels + 1] = right;
                for (UInt32 c = 2; c < bufChannels; c++) dst[i * bufChannels + c] = 0;
            }
            pos += ratio;
            if (pos >= pcmFrames) pos -= pcmFrames;
        }
        gPCMReadPos = pos;
        buf->mDataByteSize = (UInt32)(n * bufChannels * sampleBytes);
    }
}

static OSStatus (*gOrigAudioUnitInitialize)(AudioUnit) = NULL;
static OSStatus (*gOrigAudioUnitUninitialize)(AudioUnit) = NULL;

static OSStatus VCamAudioUnitRender(AudioUnit unit, UInt32 flags, const AudioTimeStamp *ts,
                                    UInt32 bus, UInt32 frames, AudioBufferList *ioData)
{
    if (!gOrigAudioUnitRender) return -1;
    OSStatus st = gOrigAudioUnitRender(unit, flags, ts, bus, frames, ioData);
    if (st != noErr || !ioData || frames == 0) return st;

    gRenderCalls += 1;

    if (!gInjectEnabled) return st;
    if (bus != 1) return st;

    VCamUnitInfo *info = VCamInfoForUnit(unit, 0);
    if (!info || !info->isInput) return st;

    // 覆盖之前先测一下真实麦克风电平（供面板显示）
    {
        float peak = 0.0f;
        for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
            AudioBuffer *buf = &ioData->mBuffers[b];
            if (!buf->mData) continue;
            if (info->isFloat) {
                const float *f = (const float *)buf->mData;
                UInt32 n = buf->mDataByteSize / 4;
                for (UInt32 i = 0; i < n; i += 8) {
                    float v = f[i] < 0 ? -f[i] : f[i];
                    if (v > peak) peak = v;
                }
            } else if (info->bits == 16) {
                const int16_t *s = (const int16_t *)buf->mData;
                UInt32 n = buf->mDataByteSize / 2;
                for (UInt32 i = 0; i < n; i += 8) {
                    int v = s[i] < 0 ? -s[i] : s[i];
                    if (v > peak) peak = v / 32768.0f;
                }
            }
        }
        gLevelMic = peak;
    }

    VCamFillFromPCM(ioData, frames, info);
    gRenderFills += 1;
    return st;
}

static OSStatus VCamAudioUnitInitialize(AudioUnit unit)
{
    if (!gOrigAudioUnitInitialize) return -1;
    OSStatus st = gOrigAudioUnitInitialize(unit);
    if (st == noErr) VCamRecordUnitFormat(unit);   // 普通线程，安全
    return st;
}

static OSStatus VCamAudioUnitUninitialize(AudioUnit unit)
{
    if (!gOrigAudioUnitUninitialize) return -1;
    VCamUnitInfo *info = VCamInfoForUnit(unit, 0);
    if (info) info->valid = 0;
    return gOrigAudioUnitUninitialize(unit);
}

static void VCamInstallAudioUnitHook(void)
{
    // 危险开关：只有用户主动打开才启用，避免每次启动都冒崩溃风险
    if (!kEnableAudioUnitHook || ![[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_au_hook"]) {
        VCamTrace(@"底层实验开关未打开，跳过 AudioUnit 拦截");
        return;
    }

    // 崩溃自愈：上次尝试没走完就崩溃的话，这次自动跳过并关掉开关
    NSString *marker = [VCamLogPath() stringByDeletingLastPathComponent];
    marker = [marker stringByAppendingPathComponent:@"vcam-au-attempt.flag"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *okMarker = [[VCamLogPath() stringByDeletingLastPathComponent]
                          stringByAppendingPathComponent:@"vcam-au-ok.flag"];
    if ([fm fileExistsAtPath:marker] && ![fm fileExistsAtPath:okMarker]) {
        // 上次「开始安装」后没有走到「安装完成」，才判定为崩溃
        VCamTrace(@"检测到上次安装阶段崩溃，已自动跳过并关闭开关");
        [fm removeItemAtPath:marker error:NULL];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"vcam_au_hook"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        return;
    }
    [fm removeItemAtPath:okMarker error:NULL];
    [fm removeItemAtPath:marker error:NULL];
    [fm createFileAtPath:marker contents:[NSData data] attributes:nil];
    VCamTrace(@"已写入尝试标记，开始安装底层拦截");

    VCamTrace(@"A1 准备重绑定 AudioUnitRender");
    void *orig = NULL;
    int n = VCamRebindSymbol("AudioUnitRender", (void *)VCamAudioUnitRender, &orig);
    gOrigAudioUnitRender = (OSStatus (*)(AudioUnit, UInt32, const AudioTimeStamp *,
                                         UInt32, UInt32, AudioBufferList *))orig;
    VCamTrace(@"A2 AudioUnitRender 重绑定 %d 处（原实现 %p）", n, orig);

    void *origInit = NULL;
    int n2 = VCamRebindSymbol("AudioUnitInitialize", (void *)VCamAudioUnitInitialize, &origInit);
    gOrigAudioUnitInitialize = (OSStatus (*)(AudioUnit))origInit;
    VCamTrace(@"A3 AudioUnitInitialize 重绑定 %d 处", n2);

    void *origUninit = NULL;
    int n3 = VCamRebindSymbol("AudioUnitUninitialize", (void *)VCamAudioUnitUninitialize, &origUninit);
    gOrigAudioUnitUninitialize = (OSStatus (*)(AudioUnit))origUninit;
    VCamTrace(@"A4 AudioUnitUninitialize 重绑定 %d 处", n3);
    VCamTrace(@"A5 底层拦截安装完成");
    [[NSFileManager defaultManager] createFileAtPath:okMarker contents:[NSData data] attributes:nil];

    // 延迟绑定的槽位会在首次调用时被 dyld 覆盖，所以过几秒再补一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        void *o = NULL;
        int n = VCamRebindSymbol("AudioUnitRender", (void *)VCamAudioUnitRender, &o);
        if (!gOrigAudioUnitRender && o) {
            gOrigAudioUnitRender = (OSStatus (*)(AudioUnit, UInt32, const AudioTimeStamp *,
                                                 UInt32, UInt32, AudioBufferList *))o;
        }
        VCamLogLine([NSString stringWithFormat:@"A6 二次补绑 %d 处", n]);
    });

    // 15 秒后仍存活，说明这次没崩，清掉标记
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSFileManager *fm2 = [NSFileManager defaultManager];
        NSString *m = [[VCamLogPath() stringByDeletingLastPathComponent]
                       stringByAppendingPathComponent:@"vcam-au-attempt.flag"];
        if ([fm2 fileExistsAtPath:m]) {
            [fm2 removeItemAtPath:m error:NULL];
            VCamLogLine(@"底层拦截稳定运行 15 秒，清除尝试标记");
        }
        NSString *ok = [[VCamLogPath() stringByDeletingLastPathComponent]
                        stringByAppendingPathComponent:@"vcam-au-ok.flag"];
        if ([fm2 fileExistsAtPath:ok]) [fm2 removeItemAtPath:ok error:NULL];
    });
}

// 运行期统计 + 最近日志（用来定位崩溃点）
static NSString *VCamRuntimeLogReport(void)
{
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"\n== 十、底层拦截状态与最近日志 ==\n"];
    [out appendFormat:@"AudioUnit 拦截开关: %@\n",
     [[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_au_hook"] ? @"开" : @"关"];
    [out appendFormat:@"渲染回调次数: %d，其中替换填充: %d\n", gRenderCalls, gRenderFills];
    [out appendString:@"\n--- 最近 40 行日志 ---\n"];
    [out appendString:VCamLogTail(40)];
    return out;
}

// ======================= Hook =======================

static NSMutableSet *gSwizzledClasses;

static void VCamSwizzleDelegate(Class cls)
{
    if (!cls) return;
    if ([NSStringFromClass(cls) hasPrefix:@"NS"]) return;
    @synchronized (gSwizzledClasses) {
        if ([gSwizzledClasses containsObject:cls]) return;
        [gSwizzledClasses addObject:cls];
    }

    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        NSLog(@"[vcam] %@ 没有实现采集回调，跳过", NSStringFromClass(cls));
        return;
    }
    IMP original = method_getImplementation(method);

    IMP replacement = imp_implementationWithBlock(^(id self, AVCaptureOutput *output,
                                                   CMSampleBufferRef sampleBuffer,
                                                   AVCaptureConnection *connection) {
        VCamClient *client = [VCamClient shared];

        // 诊断 1：确认回调真的进了、原帧格式、有没有电脑画面
        static int diagCalls = 0;
        diagCalls += 1;
        if (diagCalls == 1) {
            CMFormatDescriptionRef f = CMSampleBufferGetFormatDescription(sampleBuffer);
            CMVideoDimensions d = f ? CMVideoFormatDescriptionGetDimensions(f) : (CMVideoDimensions){0, 0};
            FourCharCode st = f ? CMFormatDescriptionGetMediaSubType(f) : 0;
            NSTimeInterval age = client.latestAt
                ? ([NSDate timeIntervalSinceReferenceDate] - client.latestAt) : -1;
            VCamReportDiag(@"entry", @"回调已进入", client.latestJPEG, age, st, d);
        }

        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        [client overwriteFrameBuffer:pixelBuffer];

        // 诊断 2：第 3 次回调时报告替换结果（成功 / 具体卡在哪一步）
        if (diagCalls == 3) {
            CMFormatDescriptionRef f = CMSampleBufferGetFormatDescription(sampleBuffer);
            CMVideoDimensions d = f ? CMVideoFormatDescriptionGetDimensions(f) : (CMVideoDimensions){0, 0};
            FourCharCode st = f ? CMFormatDescriptionGetMediaSubType(f) : 0;
            NSTimeInterval age = client.latestAt
                ? ([NSDate timeIntervalSinceReferenceDate] - client.latestAt) : -1;
            NSString *reason = client.lastReason ? client.lastReason : @"未知原因";
            VCamReportDiag(@"result", reason, client.latestJPEG, age, st, d);
        }

        // 像素已经就地写进原帧缓冲区，直接把原帧交给下游
        ((void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))original)(
            self, sel, output, sampleBuffer, connection);
    });

    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    NSLog(@"[vcam] 已接管 %@ 的帧回调", NSStringFromClass(cls));
}

static void VCamInstallHooks(void)
{
    Class outputClass = objc_getClass("AVCaptureVideoDataOutput");
    if (!outputClass) {
        NSLog(@"[vcam] 找不到 AVCaptureVideoDataOutput");
        return;
    }

    SEL sel = @selector(setSampleBufferDelegate:queue:);
    Method method = class_getInstanceMethod(outputClass, sel);
    if (!method) {
        NSLog(@"[vcam] 找不到 setSampleBufferDelegate:queue:");
        return;
    }
    IMP original = method_getImplementation(method);

    IMP replacement = imp_implementationWithBlock(^(id self, id delegate, dispatch_queue_t queue) {
        ((void (*)(id, SEL, id, dispatch_queue_t))original)(self, sel, delegate, queue);
        if (delegate) {
            @try {
                VCamSwizzleDelegate([delegate class]);
            } @catch (NSException *e) {
                NSLog(@"[vcam] 接管失败: %@", e.reason);
            }
        }
    });

    class_replaceMethod(outputClass, sel, replacement, method_getTypeEncoding(method));
    NSLog(@"[vcam] 已 hook AVCaptureVideoDataOutput");
}

__attribute__((constructor))
static void VCamInit(void)
{
    @autoreleasepool {
        gSwizzledClasses = [NSMutableSet set];
        NSLog(@"[vcam] dylib 已加载，目标 %@:%d", VCamHost(), kFramePort);
        VCamInstallHooks();
        VCamInstallAudioProbes();
        VCamInstallAudioHooks();
        VCamInstallKuaishouHooks();
        VCamInstallAudioUnitHook();

        // 加载后 2 秒：开始收帧 + 弹出控制面板
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[VCamClient shared] start];
            [[VCamAudio shared] start];
            gInjectEnabled = [[VCamAudio shared] isEnabled] ? 1 : 0;
            [[VCamOverlay shared] install];
        });
    }
}
