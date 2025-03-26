// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "./include/camera_avfoundation/FLTSavePhotoDelegate.h"
#import "./include/camera_avfoundation/FLTSavePhotoDelegate_Test.h"

@interface FLTSavePhotoDelegate ()
/// The file path for the captured photo.
@property(readonly, nonatomic) NSString *path;
/// The queue on which captured photos are written to disk.
@property(readonly, nonatomic) dispatch_queue_t ioQueue;
@end

@implementation FLTSavePhotoDelegate

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

    NSData *photoData = photoDataProvider();
    UIImage *image = [UIImage imageWithData:photoData];
    
    if (image) {
      CGFloat maxWidth = 1000.0;
      CGFloat scale = 1.0;
      
      if (image.size.width > maxWidth) {
        scale = maxWidth / image.size.width;
      }
      
      if (scale < 1.0) {
        CGSize newSize = CGSizeMake(image.size.width * scale, image.size.height * scale);
        UIGraphicsBeginImageContextWithOptions(newSize, NO, 1.0);
        [image drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
        UIImage *resizedImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        // 압축된 이미지를 JPEG로 저장
        NSData *compressedData = UIImageJPEGRepresentation(resizedImage, 0.8);
        NSError *ioError;
        if ([compressedData writeToFile:strongSelf.path options:NSDataWritingAtomic error:&ioError]) {
          strongSelf.completionHandler(self.path, nil);
        } else {
          strongSelf.completionHandler(nil, ioError);
        }
      } else {
        // 원본 크기가 1000px 이하인 경우 그대로 저장
        NSError *ioError;
        if ([photoData writeToFile:strongSelf.path options:NSDataWritingAtomic error:&ioError]) {
          strongSelf.completionHandler(self.path, nil);
        } else {
          strongSelf.completionHandler(nil, ioError);
        }
      }
    } else {
      NSError *ioError = [NSError errorWithDomain:NSCocoaErrorDomain
                                           code:NSURLErrorUnknown
                                       userInfo:@{NSLocalizedDescriptionKey: @"Failed to create image from photo data"}];
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
