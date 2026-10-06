#import "ShinMSObjC.h"

NSErrorDomain const ShinMSObjCExceptionDomain = @"ShinMSObjCExceptionDomain";

@implementation ShinMSExceptionCatcher

+ (id)catchException:(id (NS_NOESCAPE ^)(void))block
               error:(NSError *_Nullable *_Nullable)error {
    @try {
        id result = block();
        if (error) {
            *error = nil;
        }
        // nil → NSNull：throws 导入约定下成功路径必须非空；
        // Swift 侧用 `is NSNull` 判别「block 返回了 nil」。
        return result ?: NSNull.null;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError
                errorWithDomain:ShinMSObjCExceptionDomain
                           code:-1
                       userInfo:@{
                           NSLocalizedDescriptionKey:
                               exception.reason ?: exception.name,
                           @"ShinMSExceptionName": exception.name ?: @"",
                       }];
        }
        return NSNull.null;
    }
}

@end
