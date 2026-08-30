#import <Metal/Metal.h>
#import <OpenImageDenoise/oidn.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin ObjC++ shim around the one OIDN Metal entry point Swift can't call
/// directly: `oidnNewMetalDevice` takes a C array of `id<MTLCommandQueue>`,
/// which doesn't marshal cleanly across the Swift/C bridging-header boundary.
/// Everything else (filters, buffers, execute) is plain-C OIDN API and is
/// called straight from Swift via this same bridging header.
@interface OIDNMetalDeviceBox : NSObject

/// Returns nil if OIDN couldn't create/commit a device on this queue (check
/// the Xcode console for OIDN's own error message).
- (nullable instancetype)initWithCommandQueue:(id<MTLCommandQueue>)queue;

/// The underlying OIDNDevice, valid for the box's lifetime.
@property (nonatomic, readonly) OIDNDevice handle;

@end

NS_ASSUME_NONNULL_END
