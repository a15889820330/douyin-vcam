// 抖音虚拟摄像头注入（TrollStore / TrollFools）
//
// 关键约束：TrollStore 注入的 dylib 跑在没有 Substrate/ElleKit 的环境里，
// 所以这里**不用 Logos 的 %hook**，全部走 ObjC runtime（class_replaceMethod）。
// 产物是一个普通动态库，不需要 substrate，也不需要越狱。
//
// 原理：
//   1. 替换 -[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]
//   2. 拿到 App 的采集 delegate 后，替换它的
//      captureOutput:didOutputSampleBuffer:fromConnection:
//   3. 回调时若有电脑来的画面，就用它构造 CMSampleBuffer 交给原实现
//
// 这个 dylib 不含任何绕过平台检测的逻辑。

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ======================= 配置 =======================

// 电脑局域网 IP。也可用 NSUserDefaults 的 "vcam_host" 覆盖
static NSString *const kDefaultHost = @"192.168.1.42";
static const int kDefaultPort = 8080;
static NSString *const kDefaultPath = @"/ws";

// 电脑那边断流超过这个秒数就回落真实摄像头，避免直播定格
static const NSTimeInterval kStaleSeconds = 2.0;

static NSString *VCamHost(void)
{
    NSString *host = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_host"];
    return host.length ? host : kDefaultHost;
}

// ======================= 帧接收 =======================

@interface VCamClient : NSObject
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionWebSocketTask *task;
@property (nonatomic, strong) CIContext *ciContext;
@property (atomic, strong) NSData *latestJPEG;
@property (atomic, assign) NSTimeInterval latestAt;
@property (atomic, assign) BOOL running;
@property (atomic, assign) NSUInteger frameCount;
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

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 5;
    self.session = [NSURLSession sessionWithConfiguration:cfg];

    NSString *urlString = [NSString stringWithFormat:@"ws://%@:%d%@", VCamHost(), kDefaultPort, kDefaultPath];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSLog(@"[vcam] 地址不合法: %@", urlString);
        self.running = NO;
        return;
    }

    NSLog(@"[vcam] 正在连接 %@", urlString);
    self.task = [self.session webSocketTaskWithURL:url];
    [self.task resume];
    [self receiveLoop];
}

- (void)stop
{
    self.running = NO;
    [self.task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    self.task = nil;
    [self.session invalidateAndCancel];
    self.session = nil;
}

- (void)receiveLoop
{
    __weak typeof(self) weakSelf = self;
    [self.task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.running) return;

        if (error) {
            NSLog(@"[vcam] 断开: %@，2 秒后重连", error.localizedDescription);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!self.running) return;
                [self stop];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ [self start]; });
            });
            return;
        }

        if (message.type == NSURLSessionWebSocketMessageTypeData && message.data.length > 100) {
            self.latestJPEG = message.data;
            self.latestAt = [NSDate timeIntervalSinceReferenceDate];
            self.frameCount += 1;
        }
        [self receiveLoop];
    }];
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
        NSLog(@"[vcam] dylib 已加载，目标 %@:%d", VCamHost(), kDefaultPort);
        VCamInstallHooks();

        // 不要在 constructor 里直接起网络（此时 App 还没启动完），延后 2 秒
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[VCamClient shared] start];
        });
    }
}
