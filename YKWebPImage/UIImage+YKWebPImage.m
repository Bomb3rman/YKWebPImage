//
//  UIImage+YKWebPImage.m
//  YKWebPImage
//
//   Copyright Yakatak 2015
//
//   Licensed under the Apache License, Version 2.0 (the "License");
//   you may not use this file except in compliance with the License.
//   You may obtain a copy of the License at
//
//       http://www.apache.org/licenses/LICENSE-2.0
//
//   Unless required by applicable law or agreed to in writing, software
//   distributed under the License is distributed on an "AS IS" BASIS,
//   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//   See the License for the specific language governing permissions and
//   limitations under the License.
//
//

#import "UIImage+YKWebPImage.h"
#import <objc/runtime.h>
#import "YKSwizzle.h"
#import "webp/decode.h"
#import "webp/encode.h"
#import "webp/mux.h"
#import "webp/demux.h"

// This gets called when the UIImage gets collected and frees the underlying image.
static void free_image_data(void *info, const void *data, size_t size)
{
    if(info != NULL) {
        WebPFreeDecBuffer(&(((WebPDecoderConfig *) info)->output));
        free(info);
    } else {
        free((void *) data);
    }
}

@implementation UIImage (YKWebpImage)

#pragma mark Swizzling
+ (void)load {
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        // -(instancetype)initWithData:(NSData *)data
        swizzleInstanceMethod(@"initWithData:", @"initWithData_yk:", self);
        
        // -(instancetype initWithData:(NSData *)data
        //                       scale:(CGFloat)scale
        swizzleInstanceMethod(@"initWithData:scale:", @"initWithData_yk:scale:", self);
        
        // -(instancetype initWithContentsOfFile:(NSString *)path
        swizzleInstanceMethod(@"initWithContentsOfFile:", @"initWithContentsOfFile_yk:", self);
        
        // +(instancetype imageNamed:(NSString *)name
        //                  inBundle:(NSBundle *)bundle
        // compatibleWithTraitCollection:(UITraitCollection *)traitCollection
        swizzleClassMethod(@"imageNamed:inBundle:compatibleWithTraitCollection:", @"yk_imageNamed:inBundle:compatibleWithTraitCollection:", self);
    });
}

#pragma mark Decoder
+ (UIImage *)webPImageFromData:(NSData *)imgData scale:(CGFloat)scale {
    // `WebPGetInfo` weill return image width and height
    int width = 0, height = 0;
    if(!WebPGetInfo([imgData bytes], [imgData length], &width, &height)) {
        NSMutableDictionary *errorDetail = [NSMutableDictionary dictionary];
        [errorDetail setValue:@"Header formatting error." forKey:NSLocalizedDescriptionKey];
        return nil;
    }
    
    WebPDecoderConfig * config = malloc(sizeof(WebPDecoderConfig));
    if(!WebPInitDecoderConfig(config)) {
        NSMutableDictionary *errorDetail = [NSMutableDictionary dictionary];
        [errorDetail setValue:@"Failed to initialize structure. Version mismatch." forKey:NSLocalizedDescriptionKey];
        return nil;
    }
    
    config->options.no_fancy_upsampling = 1;
    config->options.bypass_filtering = 1;
    config->options.use_threads = 1;
    config->output.colorspace = MODE_RGBA;
    
    // Decode the WebP image data into a RGBA value array
    VP8StatusCode decodeStatus = WebPDecode([imgData bytes], [imgData length], config);
    if (decodeStatus != VP8_STATUS_OK) {
        return nil;
    }
    
    // Construct UIImage from the decoded RGBA value array
    uint8_t *data = WebPDecodeRGBA([imgData bytes], [imgData length], &width, &height);
    CGDataProviderRef provider = CGDataProviderCreateWithData(config, data, config->options.scaled_width  * config->options.scaled_height * 4, free_image_data);
    
    CGColorSpaceRef colorSpaceRef = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault |kCGImageAlphaLast;
    CGColorRenderingIntent renderingIntent = kCGRenderingIntentDefault;
    
    CGImageRef imageRef = CGImageCreate(width, height, 8, 32, 4 * width, colorSpaceRef, bitmapInfo, provider, NULL, YES, renderingIntent);
    
    WebPData webPImageData;
    webPImageData.bytes = imgData.bytes;
    webPImageData.size = imgData.length;
    
    WebPDemuxer *demux = WebPDemux(&webPImageData);
    WebPIterator iter;
    if (WebPDemuxGetFrame(demux, 1, &iter)) {
        do {
        } while (WebPDemuxNextFrame(&iter));
        WebPDemuxReleaseIterator(&iter);
    }
    // ... (Extract metadata).
    WebPChunkIterator chunk_iter;
    int64_t imageOrientation = UIImageOrientationUp;
    // TODO insert real EXIF orientation data
    if (WebPDemuxGetChunk(demux, "EXIF ", 1, &chunk_iter)) {
        imageOrientation = *((int64_t*)chunk_iter.chunk.bytes);
    }
    // ... (Consume the XMP metadata in 'chunk_iter.chunk').
    WebPDemuxReleaseChunkIterator(&chunk_iter);
    WebPDemuxDelete(demux);
    
    UIImage *result = [UIImage imageWithCGImage:imageRef scale:1.0 orientation:(UIImageOrientation)imageOrientation];
    
    // Free resources to avoid memory leaks
    CGImageRelease(imageRef);
    CGColorSpaceRelease(colorSpaceRef);
    CGDataProviderRelease(provider);
    
    return result;
}

#pragma mark Init Methods
- (instancetype)initWithData_yk:(NSData *)data {
    UIImage *image = [UIImage webPImageFromData:data scale:[[UIScreen mainScreen] scale]];
    if (image) {
        self = image;
        return image;
    }
    return [self initWithData_yk:data];
}

- (instancetype)initWithData_yk:(NSData *)data
                          scale:(CGFloat)scale {
    UIImage *image = [UIImage webPImageFromData:data scale:scale];
    if (image) {
        self = image;
        return self;
    }
    return [self initWithData_yk:data scale:scale];
}

- (instancetype)initWithContentsOfFile_yk:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (data) {
        UIImage *image = [UIImage webPImageFromData:data scale:[[UIScreen mainScreen] scale]];
        if (image) {
            self = image;
            return image;
        }
    }
    return [self initWithContentsOfFile_yk:path];
}

+ (instancetype)yk_imageNamed:(NSString *)name
                     inBundle:(NSBundle *)bundle
compatibleWithTraitCollection:(UITraitCollection *)traitCollection {
    NSString *path = [bundle pathForResource:name ofType:nil];
    if (path) {
        NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
        if (data) {
            UIImage *image = [UIImage webPImageFromData:data scale:[[UIScreen mainScreen] scale]];
            if (image) {
                return image;
            }
        }
    }
    return [self yk_imageNamed:name inBundle:bundle compatibleWithTraitCollection:traitCollection];
}


+ (NSData *)imageToWebP:(UIImage *)image quality:(CGFloat)quality
{
    NSParameterAssert(image != nil);
    NSParameterAssert(quality >= 0.0f && quality <= 100.0f);
    return [self convertToWebP:image quality:quality alpha:1.0f preset:WEBP_PRESET_DEFAULT configBlock:nil error:nil];
}

+ (NSData *)convertToWebP:(UIImage *)image
                  quality:(CGFloat)quality
                    alpha:(CGFloat)alpha
                   preset:(WebPPreset)preset
              configBlock:(void (^)(WebPConfig *))configBlock
                    error:(NSError **)error
{
    //    if (alpha < 1) {
    //        image = [self webPImage:image withAlpha:alpha];
    //    }
    
    CGImageRef webPImageRef = image.CGImage;
    size_t webPBytesPerRow = CGImageGetBytesPerRow(webPImageRef);
    
    size_t webPImageWidth = CGImageGetWidth(webPImageRef);
    size_t webPImageHeight = CGImageGetHeight(webPImageRef);
    
    CGDataProviderRef webPDataProviderRef = CGImageGetDataProvider(webPImageRef);
    CFDataRef webPImageDatRef = CGDataProviderCopyData(webPDataProviderRef);
    
    uint8_t *webPImageData = (uint8_t *)CFDataGetBytePtr(webPImageDatRef);
    
    WebPConfig config;
    if (!WebPConfigPreset(&config, preset, quality)) {
        NSMutableDictionary *errorDetail = [NSMutableDictionary dictionary];
        [errorDetail setValue:@"Configuration preset failed to initialize." forKey:NSLocalizedDescriptionKey];
        if(error != NULL)
            *error = [NSError errorWithDomain:[NSString stringWithFormat:@"%@.errorDomain",  [[NSBundle mainBundle] bundleIdentifier]] code:-101 userInfo:errorDetail];
        
        CFRelease(webPImageDatRef);
        return nil;
    }
    
    config.method = 6;
    config.target_size = 15000;
    
    if (configBlock) {
        configBlock(&config);
    }
    
    if (!WebPValidateConfig(&config)) {
        NSMutableDictionary *errorDetail = [NSMutableDictionary dictionary];
        [errorDetail setValue:@"One or more configuration parameters are beyond their valid ranges." forKey:NSLocalizedDescriptionKey];
        if(error != NULL)
            *error = [NSError errorWithDomain:[NSString stringWithFormat:@"%@.errorDomain",  [[NSBundle mainBundle] bundleIdentifier]] code:-101 userInfo:errorDetail];
        
        CFRelease(webPImageDatRef);
        return nil;
    }
    
    WebPPicture pic;
    if (!WebPPictureInit(&pic)) {
        NSMutableDictionary *errorDetail = [NSMutableDictionary dictionary];
        [errorDetail setValue:@"Failed to initialize structure. Version mismatch." forKey:NSLocalizedDescriptionKey];
        if(error != NULL)
            *error = [NSError errorWithDomain:[NSString stringWithFormat:@"%@.errorDomain",  [[NSBundle mainBundle] bundleIdentifier]] code:-101 userInfo:errorDetail];
        
        CFRelease(webPImageDatRef);
        return nil;
    }
    pic.width = (int)webPImageWidth;
    pic.height = (int)webPImageHeight;
    pic.colorspace = WEBP_YUV420;
    
    WebPPictureImportBGRA(&pic, webPImageData, (int)webPBytesPerRow);
    WebPPictureARGBToYUVA(&pic, WEBP_YUV420);
    // We do not really care about pictures with opacity
    //WebPCleanupTransparentArea(&pic);
    
    WebPMemoryWriter writer;
    WebPMemoryWriterInit(&writer);
    pic.writer = WebPMemoryWrite;
    pic.custom_ptr = &writer;
    WebPEncode(&config, &pic);
    
    WebPData webPData;
    webPData.bytes = writer.mem;
    webPData.size = writer.size;
    
    int copy_data = 0;
    WebPMux* mux = WebPMuxNew();
    // ... (Prepare image data).
    WebPMuxSetImage(mux, &webPData, copy_data);
    // ... (Prepare XMP metadata).
    
    WebPData orientationData;
    // TODO insert real EXIF orientation data
    int64_t orientation = image.imageOrientation;
    orientationData.bytes = (uint8_t*)&orientation;
    orientationData.size = sizeof(int64_t);
    WebPMuxSetChunk(mux, "EXIF", &orientationData, 1);
    // Get data from mux in WebP RIFF format.
    
    WebPData outData;
    WebPMuxAssemble(mux, &outData);
    WebPMuxDelete(mux);
    
    NSData *webPFinalData = [NSData dataWithBytes:outData.bytes length:outData.size];
    
    WebPDataClear(&outData);
    
    free(writer.mem);
    WebPPictureFree(&pic);
    CFRelease(webPImageDatRef);
    
    return webPFinalData;
}

@end
