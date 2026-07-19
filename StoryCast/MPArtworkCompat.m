#import "MPArtworkCompat.h"

@implementation MPArtworkCompat

+ (MPMediaItemArtwork *)artworkWithImage:(UIImage *)image {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [[MPMediaItemArtwork alloc] initWithImage:image];
#pragma clang diagnostic pop
}

@end
