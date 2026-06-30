#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface XISFBridge : NSObject

/// Decode thumbnail from XISF. Uses the embedded thumbnail if present;
/// falls back to full-image decode with STF stretch scaled to maxSize.
+ (nullable NSImage *)thumbnailImageForURL:(NSURL *)url
                                   maxSize:(CGSize)maxSize
                                     error:(NSError **)error;

/// Decode the first image with PixInsight STF auto-stretch applied.
+ (nullable NSImage *)previewImageForURL:(NSURL *)url
                                   error:(NSError **)error;

/// Return a flat dictionary of display-ready metadata from the file header only
/// (fast — does not read pixel data). Keys are FITS keyword names where available,
/// with XISF properties filling gaps. Special keys: __WIDTH__, __HEIGHT__.
+ (nullable NSDictionary<NSString *, NSString *> *)metadataForURL:(NSURL *)url
                                                            error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
