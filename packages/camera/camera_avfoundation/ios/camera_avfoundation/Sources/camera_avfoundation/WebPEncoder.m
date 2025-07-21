#import "WebPEncoder.h"
#import <Accelerate/Accelerate.h>

// VP8 Encoder structure
typedef struct VP8Encoder {
    WebPConfig config;
    int mb_w_, mb_h_;     // number of macroblocks
    uint8_t* y_top_;      // top luma samples
    uint8_t* uv_top_;     // top u/v samples
} VP8Encoder;

// Simple WebP container writer
static NSData* WriteWebPContainer(const uint8_t* vp8_data, size_t vp8_size, 
                                 int width, int height) {
    NSMutableData* webp_data = [NSMutableData data];
    
    // RIFF header
    uint32_t riff = CFSwapInt32HostToLittle(WEBP_RIFF_MAGIC);
    [webp_data appendBytes:&riff length:4];
    
    // File size (will be updated later)
    uint32_t file_size = CFSwapInt32HostToLittle((uint32_t)(4 + 4 + 4 + 10 + vp8_size));
    [webp_data appendBytes:&file_size length:4];
    
    // WEBP signature
    uint32_t webp = CFSwapInt32HostToLittle(WEBP_WEBP_MAGIC);
    [webp_data appendBytes:&webp length:4];
    
    // VP8 chunk header
    uint32_t vp8_magic = CFSwapInt32HostToLittle(WEBP_VP8_MAGIC);
    [webp_data appendBytes:&vp8_magic length:4];
    
    // VP8 chunk size
    uint32_t chunk_size = CFSwapInt32HostToLittle((uint32_t)(10 + vp8_size));
    [webp_data appendBytes:&chunk_size length:4];
    
    // VP8 frame header (10 bytes)
    uint8_t frame_header[10] = {0};
    
    // Frame tag (3 bytes): key frame, version, show_frame
    frame_header[0] = 0x9d;  // key frame + version 0 + show frame
    frame_header[1] = 0x01;
    frame_header[2] = 0x2a;
    
    // Width and height (14 bits each)
    uint16_t w = width & 0x3fff;
    uint16_t h = height & 0x3fff;
    frame_header[3] = w & 0xff;
    frame_header[4] = (w >> 8) & 0x3f;
    frame_header[5] = h & 0xff;
    frame_header[6] = (h >> 8) & 0x3f;
    
    [webp_data appendBytes:frame_header length:10];
    
    // VP8 bitstream data
    [webp_data appendBytes:vp8_data length:vp8_size];
    
    return [webp_data copy];
}

// Simple VP8 encoder (basic implementation)
static NSData* EncodeVP8Simple(const uint8_t* rgba, int width, int height, float quality) {
    NSMutableData* vp8_data = [NSMutableData data];
    
    // Convert RGBA to YUV420
    size_t y_size = width * height;
    size_t uv_size = (width / 2) * (height / 2);
    
    uint8_t* y_plane = malloc(y_size);
    uint8_t* u_plane = malloc(uv_size);
    uint8_t* v_plane = malloc(uv_size);
    
    if (!y_plane || !u_plane || !v_plane) {
        free(y_plane);
        free(u_plane);
        free(v_plane);
        return nil;
    }
    
    // Convert RGBA to YUV420 using vImage
    vImage_Buffer src_buffer = {
        .data = (void*)rgba,
        .height = height,
        .width = width,
        .rowBytes = width * 4
    };
    
    vImage_Buffer y_buffer = {
        .data = y_plane,
        .height = height,
        .width = width,
        .rowBytes = width
    };
    
    vImage_Buffer u_buffer = {
        .data = u_plane,
        .height = height / 2,
        .width = width / 2,
        .rowBytes = width / 2
    };
    
    vImage_Buffer v_buffer = {
        .data = v_plane,
        .height = height / 2,
        .width = width / 2,
        .rowBytes = width / 2
    };
    
    // RGB to YUV conversion matrix
    vImage_YpCbCrToARGB info;
    vImage_YpCbCrToARGBMatrix matrix = {
        .Yp = 1.0f, .Cr_R = 1.402f, .Cr_G = -0.714f, .Cb_G = -0.344f, .Cb_B = 1.772f
    };
    
    vImageConvert_YpCbCrToARGB_GenerateConversion(&matrix, &info, kvImage420Yp8_CbCr8, kvImageARGB8888, kvImageNoFlags);
    
    // Simple YUV conversion (manual approach for better control)
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            int rgba_idx = (y * width + x) * 4;
            uint8_t r = rgba[rgba_idx];
            uint8_t g = rgba[rgba_idx + 1];
            uint8_t b = rgba[rgba_idx + 2];
            
            // YUV conversion
            int Y = (299 * r + 587 * g + 114 * b) / 1000;
            y_plane[y * width + x] = (uint8_t)CLAMP(Y, 0, 255);
            
            // Subsample UV
            if ((x % 2 == 0) && (y % 2 == 0)) {
                int U = (-147 * r - 289 * g + 436 * b) / 1000 + 128;
                int V = (615 * r - 515 * g - 100 * b) / 1000 + 128;
                
                int uv_idx = (y / 2) * (width / 2) + (x / 2);
                u_plane[uv_idx] = (uint8_t)CLAMP(U, 0, 255);
                v_plane[uv_idx] = (uint8_t)CLAMP(V, 0, 255);
            }
        }
    }
    
    // Simple DCT-based compression (very basic)
    // For a full implementation, this would include proper VP8 encoding
    // Here we'll do a simplified version with quality-based quantization
    
    int quantizer = (int)(127 - quality * 1.27f);  // Map quality to quantizer
    quantizer = CLAMP(quantizer, 4, 127);
    
    // Write partition headers (simplified)
    uint8_t partition_header[3] = {
        0x00,  // Segment header
        (uint8_t)quantizer,  // Base quantizer
        0x00   // Filter settings
    };
    
    [vp8_data appendBytes:partition_header length:3];
    
    // Simple block encoding (8x8 blocks)
    for (int by = 0; by < height; by += 8) {
        for (int bx = 0; bx < width; bx += 8) {
            // Extract 8x8 Y block
            uint8_t block[64];
            for (int y = 0; y < 8 && by + y < height; y++) {
                for (int x = 0; x < 8 && bx + x < width; x++) {
                    block[y * 8 + x] = y_plane[(by + y) * width + (bx + x)];
                }
            }
            
            // Simple quantization
            for (int i = 0; i < 64; i++) {
                block[i] = (block[i] / quantizer) * quantizer;
            }
            
            // Append quantized block (simplified)
            [vp8_data appendBytes:block length:64];
        }
    }
    
    free(y_plane);
    free(u_plane);
    free(v_plane);
    
    return [vp8_data copy];
}

@implementation WebPEncoder

+ (NSData *)encodeImage:(UIImage *)image quality:(float)quality {
    if (!image) return nil;
    
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return nil;
    
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    size_t bytesPerRow = 4 * width;
    size_t bitmapSize = bytesPerRow * height;
    
    uint8_t* bitmapData = malloc(bitmapSize);
    if (!bitmapData) return nil;
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(bitmapData, width, height, 8, bytesPerRow,
                                                colorSpace, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    
    if (!context) {
        free(bitmapData);
        return nil;
    }
    
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);
    
    NSData* result = [self encodeRGBAData:bitmapData 
                                    width:(int)width 
                                   height:(int)height 
                                  quality:quality];
    
    free(bitmapData);
    return result;
}

+ (NSData *)encodeRGBAData:(const uint8_t *)rgba width:(int)width height:(int)height quality:(float)quality {
    if (!rgba || width <= 0 || height <= 0) return nil;
    
    // Encode VP8 bitstream
    NSData* vp8_data = EncodeVP8Simple(rgba, width, height, quality);
    if (!vp8_data) return nil;
    
    // Wrap in WebP container
    return WriteWebPContainer(vp8_data.bytes, vp8_data.length, width, height);
}

@end

// VP8 Encoder implementation (simplified)
VP8Encoder* VP8EncoderNew(const WebPConfig* config) {
    VP8Encoder* enc = calloc(1, sizeof(VP8Encoder));
    if (!enc) return NULL;
    
    enc->config = *config;
    enc->mb_w_ = (config->width + 15) / 16;
    enc->mb_h_ = (config->height + 15) / 16;
    
    return enc;
}

void VP8EncoderDelete(VP8Encoder* enc) {
    if (enc) {
        free(enc->y_top_);
        free(enc->uv_top_);
        free(enc);
    }
}

int VP8EncoderEncode(VP8Encoder* enc, const uint8_t* rgba, 
                     int stride, uint8_t** output, size_t* output_size) {
    if (!enc || !rgba || !output || !output_size) return 0;
    
    NSData* webp_data = [WebPEncoder encodeRGBAData:rgba 
                                              width:enc->config.width 
                                             height:enc->config.height 
                                            quality:enc->config.quality / 100.0f];
    
    if (!webp_data) return 0;
    
    *output_size = webp_data.length;
    *output = malloc(*output_size);
    if (!*output) return 0;
    
    memcpy(*output, webp_data.bytes, *output_size);
    return 1;
}

// Helper macro for clamping values
#ifndef CLAMP
#define CLAMP(x, min, max) ((x) < (min) ? (min) : ((x) > (max) ? (max) : (x)))
#endif