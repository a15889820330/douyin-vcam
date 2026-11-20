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
// 断流多久回落到真实摄像头
static const NSTimeInterval kStaleSeconds = 2.0;
// 是否显示调试提示框（调好后关掉，只留控制面板）
static const BOOL kShowAlerts = NO;
// 是否显示逐帧诊断（排查 hook 时临时打开）
static const BOOL kShowDiag = NO;

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

static BOOL VCamReadFull(int fd, void *buf, size_t len)
{
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, (char *)buf + got, len - got, 0);
        if (n <= 0) return NO;
        got += (size_t)n;
    }
    return YES;
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
                    if (!VCamReadFull(fd, &lenBE, sizeof(lenBE))) break;
                    uint32_t len = ntohl(lenBE);
                    if (len == 0 || len > 8 * 1024 * 1024) break;

                    NSMutableData *data = [NSMutableData dataWithLength:len];
                    if (!VCamReadFull(fd, data.mutableBytes, len)) break;

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

    VCamTrace(@"音频探针已安装");
}

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

    [out appendString:@"\n== 二、类名含 Audio 的类 ==\n"];
    int count = objc_getClassList(NULL, 0);
    if (count > 0) {
        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
        count = objc_getClassList(classes, count);
        NSMutableArray *names = [NSMutableArray array];
        for (int i = 0; i < count; i++) {
            const char *n = class_getName(classes[i]);
            if (!n) continue;
            NSString *name = [NSString stringWithUTF8String:n];
            if ([name rangeOfString:@"audio" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [names addObject:name];
            }
        }
        free(classes);
        [names sortUsingSelector:@selector(compare:)];
        for (NSString *n in names) {
            [out appendFormat:@"%@\n", n];
        }
        [out appendFormat:@"\n（共 %lu 个）\n", (unsigned long)names.count];
    }

    return out;
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
    UITextField *_hostField;
    UISwitch *_enableSwitch;
    UISwitch *_mirrorSwitch;
    UISegmentedControl *_fitSegment;
    NSTimer *_timer;
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
    CGFloat w = 236, h = 300;
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

    _footer = [self makeLabel:@"" frame:CGRectMake(16, 236, w - 32, 18) size:11 bold:NO];
    _footer.textColor = VCamMuted();
    [_card addSubview:_footer];

    UIButton *audioBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    audioBtn.frame = CGRectMake(16, 260, w - 32, 30);
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

- (void)refreshStatus
{
    if (!_statusText) return;
    VCamClient *c = [VCamClient shared];
    BOOL connected = c.latestAt > 0 &&
        ([NSDate timeIntervalSinceReferenceDate] - c.latestAt) < kStaleSeconds;
    _statusDot.textColor = connected ? [UIColor colorWithRed:0.55 green:0.66 blue:0.44 alpha:1.0] : VCamMuted();
    _statusText.text = connected ? @"已连接电脑" : @"未连接";
    _footer.text = [NSString stringWithFormat:@"已接收 %lu 帧 · 延迟 %.1fs",
                    (unsigned long)c.frameCount,
                    c.latestAt ? ([NSDate timeIntervalSinceReferenceDate] - c.latestAt) : 0.0];
}

@end

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

        // 加载后 2 秒：开始收帧 + 弹出控制面板
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[VCamClient shared] start];
            [[VCamOverlay shared] install];
        });
    }
}
