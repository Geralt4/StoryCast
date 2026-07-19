#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C shim around the deprecated `-[MPMediaItemArtwork initWithImage:]`.
///
/// The Swift call site deliberately uses `init(image:)` because the non-deprecated
/// `init(boundsSize:requestHandler:)` crashes on iPadOS 26+: `MPNowPlayingInfoCenter`
/// invokes the request handler on a background queue where the artwork cannot be safely
/// accessed (this reproduced even with a correct `@Sendable` closure — see commit 9fb39a1).
/// Routing the call through this shim lets us suppress the deprecation warning locally with a
/// clang pragma, which Swift cannot express per-call.
@interface MPArtworkCompat : NSObject

+ (MPMediaItemArtwork *)artworkWithImage:(UIImage *)image;

@end

NS_ASSUME_NONNULL_END
