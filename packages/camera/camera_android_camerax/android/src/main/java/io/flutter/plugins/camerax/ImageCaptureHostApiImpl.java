// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.content.Context;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.VisibleForTesting;
import androidx.camera.core.ImageCapture;
import androidx.camera.core.ImageCaptureException;
import androidx.camera.core.resolutionselector.ResolutionSelector;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugins.camerax.GeneratedCameraXLibrary.ImageCaptureHostApi;
import java.io.File;
import java.io.IOException;
import java.util.Objects;
import java.util.concurrent.Executors;
import android.util.Log;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Bitmap.CompressFormat;
import java.io.FileOutputStream;
import android.graphics.Matrix;
import androidx.exifinterface.media.ExifInterface;

public class ImageCaptureHostApiImpl implements ImageCaptureHostApi {
  private final BinaryMessenger binaryMessenger;
  private final InstanceManager instanceManager;

  @Nullable private Context context;
  private SystemServicesFlutterApiImpl systemServicesFlutterApiImpl;

  public static final String TEMPORARY_FILE_NAME = "CAP";
  public static final String WEBP_FILE_TYPE = ".webp";

  @VisibleForTesting public @NonNull CameraXProxy cameraXProxy = new CameraXProxy();

  public ImageCaptureHostApiImpl(
          @NonNull BinaryMessenger binaryMessenger,
          @NonNull InstanceManager instanceManager,
          @NonNull Context context) {
    this.binaryMessenger = binaryMessenger;
    this.instanceManager = instanceManager;
    this.context = context;
  }

  /**
   * Sets the context that the {@link ImageCapture} will use to find a location to save a captured
   * image.
   */
  public void setContext(@NonNull Context context) {
    this.context = context;
  }

  /**
   * Creates an {@link ImageCapture} with the requested flash mode and target resolution if
   * specified.
   */
  @Override
  public void create(
          @NonNull Long identifier,
          @Nullable Long rotation,
          @Nullable Long flashMode,
          @Nullable Long resolutionSelectorId) {
    ImageCapture.Builder imageCaptureBuilder = cameraXProxy.createImageCaptureBuilder();

    if (rotation != null) {
      imageCaptureBuilder.setTargetRotation(rotation.intValue());
    }
    if (flashMode != null) {
      // This sets the requested flash mode, but may fail silently.
      imageCaptureBuilder.setFlashMode(flashMode.intValue());
    }
    if (resolutionSelectorId != null) {
      ResolutionSelector resolutionSelector =
              Objects.requireNonNull(instanceManager.getInstance(resolutionSelectorId));
      imageCaptureBuilder.setResolutionSelector(resolutionSelector);
    }

    ImageCapture imageCapture = imageCaptureBuilder.build();
    instanceManager.addDartCreatedInstance(imageCapture, identifier);
  }

  /** Sets the flash mode of the {@link ImageCapture} instance with the specified identifier. */
  @Override
  public void setFlashMode(@NonNull Long identifier, @NonNull Long flashMode) {
    ImageCapture imageCapture = getImageCaptureInstance(identifier);
    imageCapture.setFlashMode(flashMode.intValue());
  }

  /** Captures a still image and uses the result to return its absolute path in memory. */
  @Override
  public void takePicture(
          @NonNull Long identifier, @NonNull GeneratedCameraXLibrary.Result<String> result) {
    if (context == null) {
      throw new IllegalStateException("Context must be set to take picture.");
    }

    ImageCapture imageCapture = getImageCaptureInstance(identifier);
    final File outputDir = context.getCacheDir();
    File temporaryCaptureFile;
    try {
      temporaryCaptureFile = File.createTempFile(TEMPORARY_FILE_NAME, WEBP_FILE_TYPE, outputDir);
    } catch (IOException | SecurityException e) {
      result.error(e);
      return;
    }

    ImageCapture.OutputFileOptions outputFileOptions =
            cameraXProxy.createImageCaptureOutputFileOptions(temporaryCaptureFile);
    ImageCapture.OnImageSavedCallback onImageSavedCallback =
            createOnImageSavedCallback(temporaryCaptureFile, result);

    imageCapture.takePicture(
            outputFileOptions, Executors.newSingleThreadExecutor(), onImageSavedCallback);
  }

  /** Creates a callback used when saving a captured image. */
  @VisibleForTesting
  public @NonNull ImageCapture.OnImageSavedCallback createOnImageSavedCallback(
          @NonNull File file, @NonNull GeneratedCameraXLibrary.Result<String> result) {
    return new ImageCapture.OnImageSavedCallback() {
      @Override
      public void onImageSaved(@NonNull ImageCapture.OutputFileResults outputFileResults) {
        try {
          // 1. 이미지 로드
          Bitmap original = BitmapFactory.decodeFile(file.getAbsolutePath());
          if (original == null) {
            throw new IOException("Failed to decode captured image.");
          }

          // 2. EXIF에서 회전 정보 가져오기
          ExifInterface exif = new ExifInterface(file.getAbsolutePath());
          int orientation = exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL);

          Matrix matrix = new Matrix();
          switch (orientation) {
            case ExifInterface.ORIENTATION_ROTATE_90:
              matrix.postRotate(90);
              break;
            case ExifInterface.ORIENTATION_ROTATE_180:
              matrix.postRotate(180);
              break;
            case ExifInterface.ORIENTATION_ROTATE_270:
              matrix.postRotate(270);
              break;
          }

          // 3. 실제 회전 적용
          Bitmap rotated = Bitmap.createBitmap(original, 0, 0, original.getWidth(), original.getHeight(), matrix, true);

          int rotatedWidth = rotated.getWidth();
          int rotatedHeight = rotated.getHeight();

          // 4. 중심 기준 3:4 crop
          float desiredAspect = 3f / 4f;
          int cropWidth = rotatedWidth;
          int cropHeight = (int) (cropWidth / desiredAspect);
          if (cropHeight > rotatedHeight) {
            cropHeight = rotatedHeight;
            cropWidth = (int) (cropHeight * desiredAspect);
          }

          int startX = (rotatedWidth - cropWidth) / 2;
          int startY = (rotatedHeight - cropHeight) / 2;
          Bitmap cropped = Bitmap.createBitmap(rotated, startX, startY, cropWidth, cropHeight);

          // 5. resize to 1000x1334
          Bitmap resized = Bitmap.createScaledBitmap(cropped, 1000, 1334, true);

          // 6. 저장
          FileOutputStream out = new FileOutputStream(file);
          resized.compress(Bitmap.CompressFormat.WEBP, 100, out);
          out.flush();
          out.close();

          result.success(file.getAbsolutePath());
        } catch (Exception e) {
          result.success(file.getAbsolutePath());
        }
      }

      @Override
      public void onError(@NonNull ImageCaptureException exception) {
        result.error(exception);
      }
    };
  }

  /** Dynamically sets the target rotation of the {@link ImageCapture}. */
  @Override
  public void setTargetRotation(@NonNull Long identifier, @NonNull Long rotation) {
    ImageCapture imageCapture = getImageCaptureInstance(identifier);
    imageCapture.setTargetRotation(rotation.intValue());
  }

  /**
   * Retrieves the {@link ImageCapture} instance associated with the specified {@code identifier}.
   */
  private ImageCapture getImageCaptureInstance(@NonNull Long identifier) {
    return Objects.requireNonNull(instanceManager.getInstance(identifier));
  }
}
