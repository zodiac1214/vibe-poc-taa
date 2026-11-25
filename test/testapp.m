// taa_testapp — tiny stand-in "game" for exercising the injector.
//
// Renders a fan of thin white wedges (worst-case aliasing) into a CAMetalLayer at a
// fixed low drawableSize, like a game running at a reduced in-game resolution.
//
//   taa_testapp [--size WxH] [--frames N] [--static] [--direct-present] [--srgb]
//
// Without the injector the window shows the low-res image stretched by Core Animation.
// With it, the real drawable is upscaled by MetalFX to the window's native size.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const kShader =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct P { float t; float aspect; };\n"
     "vertex float4 vs(uint vid [[vertex_id]], constant P &p [[buffer(0)]]) {\n"
     "  uint w = vid / 3, k = vid % 3;\n"
     "  if (k == 0) return float4(0, 0, 0, 1);\n"
     "  float a = p.t * 0.15 + float(w) * (2.0 * M_PI_F / 96.0) + (k == 2 ? 0.012 : 0.0);\n"
     "  float2 q = float2(cos(a), sin(a)) * 1.5;\n"
     "  q.x /= p.aspect;\n"
     "  return float4(q, 0, 1);\n"
     "}\n"
     "fragment float4 fs() { return float4(1, 1, 1, 1); }\n";

@interface TestApp : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property CAMetalLayer *layer;
@property id<MTLDevice> device;
@property id<MTLCommandQueue> queue;
@property id<MTLRenderPipelineState> pso;
@property CGSize size;
@property long frames, frame;
@property BOOL isStatic, directPresent, srgb;
@property NSTimer *timer;
@end

@implementation TestApp

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    self.device = MTLCreateSystemDefaultDevice();
    self.queue = [self.device newCommandQueue];

    NSError *err = nil;
    id<MTLLibrary> lib = [self.device newLibraryWithSource:kShader options:nil error:&err];
    if (!lib) {
        fprintf(stderr, "shader error: %s\n", err.description.UTF8String);
        exit(1);
    }
    MTLPixelFormat fmt = self.srgb ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatBGRA8Unorm;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vs"];
    d.fragmentFunction = [lib newFunctionWithName:@"fs"];
    d.colorAttachments[0].pixelFormat = fmt;
    self.pso = [self.device newRenderPipelineStateWithDescriptor:d error:&err];

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 1280, 720)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"taa_testapp";
    NSView *view = [[NSView alloc] initWithFrame:self.window.contentView.bounds];
    self.layer = [CAMetalLayer layer];
    self.layer.device = self.device;
    self.layer.pixelFormat = fmt;
    self.layer.contentsScale = self.window.backingScaleFactor;
    self.layer.drawableSize = self.size;  // "in-game resolution"
    view.layer = self.layer;
    view.wantsLayer = YES;
    self.window.contentView = view;
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                                  target:self
                                                selector:@selector(tick)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)tick {
    @autoreleasepool {
        id<CAMetalDrawable> drawable = [self.layer nextDrawable];
        if (!drawable) return;
        if (self.frame == 0) {
            CGSize ds = self.layer.drawableSize;
            fprintf(stderr, "[testapp] layer.drawableSize=%.0fx%.0f drawable.texture=%lux%lu drawable=%s\n",
                    ds.width, ds.height, (unsigned long)drawable.texture.width,
                    (unsigned long)drawable.texture.height, NSStringFromClass([(NSObject *)drawable class]).UTF8String);
        }

        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = drawable.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.08, 1);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;

        struct {
            float t, aspect;
        } p = {self.isStatic ? 0.0f : (float)self.frame / 60.0f,
               (float)(drawable.texture.width / (double)drawable.texture.height)};

        id<MTLCommandBuffer> cb = [self.queue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:self.pso];
        [enc setVertexBytes:&p length:sizeof p atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:96 * 3];
        [enc endEncoding];
        if (self.directPresent) {
            [cb addScheduledHandler:^(id<MTLCommandBuffer> b) { [drawable present]; }];
        } else {
            [cb presentDrawable:drawable];
        }
        [cb commit];

        self.frame++;
        if (self.frames > 0 && self.frame >= self.frames) {
            [cb waitUntilCompleted];
            [self.timer invalidate];
            // Give the injector's completion handlers (PNG dumps) a moment to finish.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(),
                           ^{ [NSApp terminate:nil]; });
        }
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }

@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        TestApp *t = [TestApp new];
        t.size = CGSizeMake(960, 540);
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--size") && i + 1 < argc) {
                int w, h;
                if (sscanf(argv[++i], "%dx%d", &w, &h) == 2) t.size = CGSizeMake(w, h);
            } else if (!strcmp(argv[i], "--frames") && i + 1 < argc) {
                t.frames = atol(argv[++i]);
            } else if (!strcmp(argv[i], "--static")) {
                t.isStatic = YES;
            } else if (!strcmp(argv[i], "--direct-present")) {
                t.directPresent = YES;
            } else if (!strcmp(argv[i], "--srgb")) {
                t.srgb = YES;
            } else {
                fprintf(stderr, "usage: %s [--size WxH] [--frames N] [--static] [--direct-present] [--srgb]\n", argv[0]);
                return 2;
            }
        }
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        app.delegate = t;
        [app run];
    }
    return 0;
}
