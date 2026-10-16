import Foundation

/// Music 的云端封面可能晚于曲目元数据准备好；每次可见请求只补试两次。
enum ArtworkLoadingPolicy {
    static let retryDelays: [Duration] = [.seconds(1), .seconds(3)]
}
