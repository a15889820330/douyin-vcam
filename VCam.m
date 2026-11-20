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
// 是否显示调试提示框
static const BOOL kShowAlerts = YES;

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
+ (instancetype)shared;
- (void)start;
- (void)stop;
- (CMSampleBufferRef)copySampleBuffer CF_RETURNS_RETAINED;
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

            close(fd);
            if (self.running) [NSThread sleepForTimeInterval:2.0];
        }
    }
}

#pragma mark - JPEG → CMSampleBuffer

- (CVPixelBufferRef)newPixelBufferFromImage:(CGImageRef)image
{
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    if (width == 0 || height == 0) return NULL;

    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
    };
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                          (__bridge CFDictionaryRef)attrs, &pixelBuffer);
    if (status != kCVReturnSuccess || !pixelBuffer) return NULL;

    CIImage *ciImage = [CIImage imageWithCGImage:image];
    if (!ciImage) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }
    @try {
        [self.ciContext render:ciImage
              toCVPixelBuffer:pixelBuffer
                      bounds:CGRectMake(0, 0, width, height)
                  colorSpace:CGColorSpaceCreateDeviceRGB()];
    } @catch (NSException *e) {
        NSLog(@"[vcam] 转像素缓冲区失败: %@", e.reason);
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }
    return pixelBuffer;
}

- (CMSampleBufferRef)copySampleBuffer CF_RETURNS_RETAINED
{
    NSData *jpeg = self.latestJPEG;
    if (!jpeg.length) return NULL;

    NSTimeInterval age = [NSDate timeIntervalSinceReferenceDate] - self.latestAt;
    if (age > kStaleSeconds) return NULL;   // 断流了，回落真实摄像头

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    if (!source) return NULL;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return NULL;

    CVPixelBufferRef pixelBuffer = [self newPixelBufferFromImage:image];
    CGImageRelease(image);
    if (!pixelBuffer) return NULL;

    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);
    if (st != noErr || !formatDesc) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sampleBuffer = NULL;
    st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer, formatDesc,
                                                  &timing, &sampleBuffer);
    CFRelease(formatDesc);
    CVPixelBufferRelease(pixelBuffer);
    if (st != noErr || !sampleBuffer) return NULL;
    return sampleBuffer;
}

@end

// ======================= Hook（纯 runtime） =======================

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
        CMSampleBufferRef ours = [[VCamClient shared] copySampleBuffer];
        if (ours) {
            ((void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))original)(
                self, sel, output, ours, connection);
            CFRelease(ours);
        } else {
            ((void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))original)(
                self, sel, output, sampleBuffer, connection);
        }
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

        // 加载后 2 秒弹提示：看到这个框就说明 dylib 真的进去了
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            VCamShowAlert([NSString stringWithFormat:@"插件已加载，正在连接电脑 %@:%d", VCamHost(), kFramePort],
                          YES);
            [[VCamClient shared] start];
        });
    }
}
