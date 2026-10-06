#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift 无法捕获 ObjC 异常（@try/@catch 不可用），而 ScriptingBridge
/// 的 Apple Event 调用失败可能以 NSException 形式抛出（如授权被拒、超时）。
/// 本模块内对 ScriptingBridge 的全部调用都必须经本工具包裹，
/// 异常被转换为 NSError（domain: ShinMSObjCExceptionDomain）。
///
/// 返回值约定：block 返回 nil 时返回 NSNull（遵循 throws 导入约定的
/// 非空返回；Swift 侧以 `is NSNull` 判别 nil 结果）。
@interface ShinMSExceptionCatcher : NSObject

/// 执行 block 并捕获其中的 ObjC 异常；异常时抛出（Swift 侧 try/catch）。
+ (id)catchException:(id (NS_NOESCAPE ^)(void))block
               error:(NSError *_Nullable *_Nullable)error;

@end

/// 捕获到 ObjC 异常时的 NSError domain。
FOUNDATION_EXPORT NSErrorDomain const ShinMSObjCExceptionDomain;

NS_ASSUME_NONNULL_END
