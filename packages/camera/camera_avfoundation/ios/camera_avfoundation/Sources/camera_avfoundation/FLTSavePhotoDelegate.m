// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "./include/camera_avfoundation/FLTSavePhotoDelegate.h"
#import "./include/camera_avfoundation/FLTSavePhotoDelegate_Test.h"
#import <webp/encode.h>

@interface FLTSavePhotoDelegate ()
/// The file path for the captured photo.
@property(readonly, nonatomic) NSString *path;
/// The queue on which captured photos are written to disk.
@property(readonly, nonatomic) dispatch_queue_t ioQueue;
@end

@implementation FLTSavePhotoDelegate

// WebP 인코딩 헬퍼 메소드
- (NSData *)encodeImageToWebP:(UIImage *)image quality:(float)quality {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return nil;
    
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    
    // RGBA 형식으로 비트맵 데이터 생성
    size_t bytesPerRow = 4 * width;
    size_t bitmapSize = bytesPerRow * height;
    uint8_t *bitmapData = (uint8_t *)malloc(bitmapSize);
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
    
    // WebP 인코딩
    uint8_t *webpData;
    size_t webpSize = WebPEncodeRGBA(bitmapData, (int)width, (int)height, (int)bytesPerRow, quality * 100, &webpData);
    
    free(bitmapData);
    
    if (webpSize == 0 || !webpData) return nil;
    
    NSData *result = [NSData dataWithBytes:webpData length:webpSize];
    WebPFree(webpData);
    
    return result;
}

- (instancetype)initWithPath:(NSString *)path
                     ioQueue:(dispatch_queue_t)ioQueue
           completionHandler:(FLTSavePhotoDelegateCompletionHandler)completionHandler {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _path = path;
  _ioQueue = ioQueue;
  _completionHandler = completionHandler;
  return self;
}

- (void)handlePhotoCaptureResultWithError:(NSError *)error
                        photoDataProvider:(NSObject<FLTWritableData> * (^)(void))photoDataProvider {
  if (error) {
    self.completionHandler(nil, error);
    return;
  }
  __weak typeof(self) weakSelf = self;
  dispatch_async(self.ioQueue, ^{
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf) return;

    NSDate *totalStartTime = [NSDate date];
    
    // 1. 이미지 데이터 가져오기
    NSDate *dataStartTime = [NSDate date];
    NSData *photoData = photoDataProvider();
    NSTimeInterval dataTime = [[NSDate date] timeIntervalSinceDate:dataStartTime];
    NSLog(@"1. 이미지 데이터 가져오기: %.3f초", dataTime);
    
    // 2. UIImage 생성 및 리사이즈를 한번에 처리
    NSDate *processStartTime = [NSDate date];
    UIImage *image = [UIImage imageWithData:photoData];
    
    // 이미지 방향 정규화
    if (image.imageOrientation != UIImageOrientationUp) {
        UIGraphicsBeginImageContextWithOptions(image.size, NO, image.scale);
        [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
        image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }
    
    // 이미지 크롭 처리
    CGFloat imageWidth = image.size.width * image.scale;
    CGFloat imageHeight = image.size.height * image.scale;
    CGFloat imageRatio = imageWidth / imageHeight;
    CGFloat previewRatio = 3.0 / 4.0; // 4:3 비율
    
    CGRect cropRect;
    if (imageRatio > previewRatio) {
        CGFloat newWidth = imageHeight * previewRatio;
        CGFloat xOffset = (imageWidth - newWidth) / 2;
        cropRect = CGRectMake(xOffset, 0, newWidth, imageHeight);
    } else {
        CGFloat newHeight = imageWidth / previewRatio;
        CGFloat yOffset = (imageHeight - newHeight) / 2;
        cropRect = CGRectMake(0, yOffset, imageWidth, newHeight);
    }
    
    CGImageRef croppedCGImage = CGImageCreateWithImageInRect(image.CGImage, cropRect);
    UIImage *croppedImage = [UIImage imageWithCGImage:croppedCGImage scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(croppedCGImage);
    
    // 리사이즈 처리
    CGFloat maxWidth = 1000.0;
    CGFloat scale = 1.0;
    
    if (croppedImage.size.width > maxWidth) {
        scale = maxWidth / croppedImage.size.width;
    }
    
    UIImage *finalImage = croppedImage;
    if (scale < 1.0) {
        CGSize newSize = CGSizeMake(croppedImage.size.width * scale, croppedImage.size.height * scale);
        UIGraphicsBeginImageContextWithOptions(newSize, NO, 1.0);
        [croppedImage drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
        finalImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }
    NSTimeInterval processTime = [[NSDate date] timeIntervalSinceDate:processStartTime];
    NSLog(@"2. 이미지 처리: %.3f초", processTime);
    
    // 3. WebP 압축 및 저장
    NSDate *saveStartTime = [NSDate date];
    NSData *finalData = [strongSelf encodeImageToWebP:finalImage quality:0.8];
    if (!finalData) {
        strongSelf.completionHandler(nil, [NSError errorWithDomain:@"FLTSavePhotoDelegate" 
                                                             code:-1 
                                                         userInfo:@{NSLocalizedDescriptionKey: @"WebP encoding failed"}]);
        return;
    }
    
    NSError *ioError;
    if ([finalData writeToFile:strongSelf.path options:NSDataWritingAtomic error:&ioError]) {
        NSTimeInterval saveTime = [[NSDate date] timeIntervalSinceDate:saveStartTime];
        NSTimeInterval totalTime = [[NSDate date] timeIntervalSinceDate:totalStartTime];
        NSLog(@"3. WebP 파일 저장: %.3f초", saveTime);
        NSLog(@"총 소요 시간: %.3f초", totalTime);
        NSLog(@"압축률: %.1f%% (원본: %luKB → WebP: %luKB)", 
              (1.0 - (double)finalData.length / (double)photoData.length) * 100,
              (unsigned long)photoData.length / 1024,
              (unsigned long)finalData.length / 1024);
        strongSelf.completionHandler(self.path, nil);
    } else {
        strongSelf.completionHandler(nil, ioError);
    }
  });
}

- (void)captureOutput:(AVCapturePhotoOutput *)output
    didFinishProcessingPhoto:(AVCapturePhoto *)photo
                       error:(NSError *)error {
  [self handlePhotoCaptureResultWithError:error
                        photoDataProvider:^NSData * {
                          return [photo fileDataRepresentation];
                        }];
}

- (NSString *)filePath {
  return self.path;
}

 - (void)captureOutput:(AVCapturePhotoOutput *)output willCapturePhotoForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings
 API_AVAILABLE(ios(10.0)){
     AudioServicesDisposeSystemSoundID(1108);
 }
 
@end
