#import "OIDNBridge.h"

@implementation OIDNMetalDeviceBox {
    OIDNDevice _device;
}

- (nullable instancetype)initWithCommandQueue:(id<MTLCommandQueue>)queue {
    self = [super init];
    if (!self) return nil;

    MTLCommandQueue_id queues[1] = { queue };
    _device = oidnNewMetalDevice(queues, 1);
    if (!_device) return nil;

    oidnCommitDevice(_device);
    const char* message = NULL;
    if (oidnGetDeviceError(_device, &message) != OIDN_ERROR_NONE) {
        NSLog(@"OIDNMetalDeviceBox: device commit failed: %s", message ? message : "(no message)");
        oidnReleaseDevice(_device);
        _device = NULL;
        return nil;
    }

    return self;
}

- (void)dealloc {
    if (_device) oidnReleaseDevice(_device);
}

- (OIDNDevice)handle {
    return _device;
}

@end
