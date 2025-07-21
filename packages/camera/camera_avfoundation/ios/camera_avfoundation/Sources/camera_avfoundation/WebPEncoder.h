#ifndef WebPEncoder_h
#define WebPEncoder_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// WebP file format constants
#define WEBP_RIFF_MAGIC 0x46464952  // "RIFF"
#define WEBP_WEBP_MAGIC 0x50424557  // "WEBP"
#define WEBP_VP8_MAGIC  0x20385056  // "VP8 "

// VP8 encoder configuration
typedef struct {
    int quality;        // 0-100
    int width;
    int height;
    int method;         // 0=fastest, 6=slowest
    int target_size;    // if non-zero, set the desired target size in bytes
} WebPConfig;

// WebP encoder interface
@interface WebPEncoder : NSObject

+ (NSData *)encodeImage:(UIImage *)image quality:(float)quality;
+ (NSData *)encodeRGBAData:(const uint8_t *)rgba 
                     width:(int)width 
                    height:(int)height 
                   quality:(float)quality;

@end

// Internal VP8 encoding functions
typedef struct VP8Encoder VP8Encoder;

VP8Encoder* VP8EncoderNew(const WebPConfig* config);
void VP8EncoderDelete(VP8Encoder* enc);
int VP8EncoderEncode(VP8Encoder* enc, const uint8_t* rgba, 
                     int stride, uint8_t** output, size_t* output_size);

#endif /* WebPEncoder_h */