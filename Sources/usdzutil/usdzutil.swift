import Foundation
import ArgumentParser
import USDZSimplifier
import RealityKit

// ANSI 颜色代码
struct Colors {
    static let reset = "\u{001B}[0m"
    static let green = "\u{001B}[32m"
    static let red = "\u{001B}[31m"
    static let yellow = "\u{001B}[33m"
    static let blue = "\u{001B}[34m"
    static let cyan = "\u{001B}[36m"
}

// MARK: - 辅助函数
/// 验证文件是否成功保存（USDZSimplifier 现在使用同步保存，此函数仅作为额外验证）
func verifyFileSaved(url: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return false
    }
    // 检查文件大小是否大于0
    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
       let size = attributes[.size] as? Int64,
       size > 0 {
        return true
    }
    return false
}

/// 创建 Custom 模式的 SimplificationOptions
/// - Parameters:
///   - ratio: 必填，简化比例 (0.0-1.0)
///   - errorThreshold: 选填，误差阈值
///   - minFaceCount: 选填，最小面数保护
///   - useSloppy: 选填，是否使用 Sloppy 模式
///   - lockBorder: 选填，是否锁定边界
///   - attributeWeight: 选填，法线权重
///   - ignoreAttributes: 选填，是否忽略属性
///   - enablePrune: 选填，是否启用 Prune 模式
func createCustomOptions(
    ratio: Float?,
    errorThreshold: Float? = nil,
    minFaceCount: Int? = nil,
    useSloppy: Bool = false,
    lockBorder: Bool = true,
    attributeWeight: Float? = nil,
    ignoreAttributes: Bool = false,
    enablePrune: Bool = false
) throws -> SimplificationOptions {
    guard let ratio = ratio else {
        throw ExitCode.failure
    }
    
    guard ratio >= 0.0 && ratio <= 1.0 else {
        print("\(Colors.red)❌ 错误: ratio 必须在 0.0-1.0 之间\(Colors.reset)")
        throw ExitCode.failure
    }
    
    return SimplificationOptions(
        targetRatio: ratio,
        errorThreshold: errorThreshold ?? 0.01,
        minFaceCount: minFaceCount ?? 200,
        useSloppy: useSloppy,
        lockBorder: lockBorder,
        attributeWeight: attributeWeight ?? 0.5,
        ignoreAttributes: ignoreAttributes,
        enablePrune: enablePrune
    )
}

// MARK: - 主命令
@main
struct USDZUtil: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usdzutil",
        abstract: "USDZ 模型简化工具 - 基于 RealityKit 和 meshoptimizer",
        discussion: """
        使用示例:
        
        【推荐】使用 --quality 参数（每个模式对应单独路径）:
          # 简化单个文件：每个质量级别保存到不同路径
          usdzutil simplify model.usdz \\
            --quality "original:./high_quality/model.usdz" \\
            --quality "standard:./medium_quality/model.usdz" \\
            --quality "custom:./custom_quality/model.usdz:0.3:errorThreshold=0.02"
          
          # 批量处理：每个质量级别保存到不同文件夹
          usdzutil batch ./input_folder \\
            --quality "original:./high_quality/" \\
            --quality "standard:./medium_quality/" \\
            --quality "custom:./custom_quality/:0.3"
        
        【兼容】使用 --preset/--presets 参数:
          # 简化单个文件（单个质量级别）
          usdzutil simplify input.usdz --output output.usdz --preset standard
          
          # 简化单个文件（多个质量级别，保存到同一文件夹）
          usdzutil simplify input.usdz --presets original,standard,minimal --output-dir ./outputs
          
          # 批量处理文件夹（单个质量级别）
          usdzutil batch ./input_folder --output ./output_folder --preset standard
          
          # 批量处理文件夹（多个质量级别）
          usdzutil batch ./input_folder --presets original,standard,minimal --output-base ./outputs
          
          # 生成多个质量级别（使用 multi-quality 命令）
          usdzutil multi-quality input.usdz --output-dir ./outputs
        
        详细帮助:
          usdzutil simplify --help    # 查看 simplify 命令的详细帮助和示例
          usdzutil batch --help       # 查看 batch 命令的详细帮助和示例
        """,
        subcommands: [SimplifyCommand.self, BatchCommand.self, MultiQualityCommand.self]
    )
}

// MARK: - 简化单个文件命令
struct SimplifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simplify",
        abstract: "简化单个 USDZ 文件，支持为每个质量级别指定单独的输出路径和参数",
        discussion: """
        使用示例:
        
        【推荐方式】使用 --quality 参数（每个模式对应单独路径）:
          # 基本用法：每个质量级别保存到不同路径
          usdzutil simplify model.usdz \\
            --quality "original:./high_quality/model.usdz" \\
            --quality "standard:./medium_quality/model.usdz" \\
            --quality "minimal:./low_quality/model.usdz"
          
          # Custom 模式（只有 ratio）
          usdzutil simplify model.usdz \\
            --quality "custom:./custom_quality/model.usdz:0.3"
          
          # Custom 模式 + 基础参数
          usdzutil simplify model.usdz \\
            --quality "custom:./output/model.usdz:0.3:errorThreshold=0.02:minFaceCount=300"
          
          # Custom 模式 + 所有参数
          usdzutil simplify model.usdz \\
            --quality "custom:./output/model.usdz:0.3:errorThreshold=0.02:minFaceCount=300:useSloppy=false:lockBorder=true:attributeWeight=0.5:ignoreAttributes=false:enablePrune=false"
          
          # 多个不同的 custom 配置
          usdzutil simplify model.usdz \\
            --quality "original:./path1/model.usdz" \\
            --quality "custom:./path2/model.usdz:0.3:errorThreshold=0.02" \\
            --quality "custom:./path3/model.usdz:0.7:attributeWeight=0.8:useSloppy=true"
          
          # 使用简短键名
          usdzutil simplify model.usdz \\
            --quality "custom:./output/model.usdz:0.5:e=0.02:m=300:w=0.8"
        
        【兼容方式】使用 --preset/--presets 参数:
          # 单个质量级别
          usdzutil simplify model.usdz --preset standard --output output.usdz
          
          # 多个质量级别（保存到同一文件夹）
          usdzutil simplify model.usdz --presets original,standard,minimal --output-dir ./outputs
        
        Custom 模式参数说明（在 --quality 中使用）:
          格式: custom:path:ratio[:key=value[:key=value...]]
          
          必填:
            path: 输出文件路径（可以是文件或文件夹）
            ratio: 简化比例 (0.0-1.0)
          
          可选键值对（支持完整名和简短名）:
            errorThreshold=0.01 或 e=0.01          - 误差阈值 (默认: 0.01)
            minFaceCount=200 或 m=200              - 最小面数保护 (默认: 200)
            useSloppy=false 或 sloppy=false       - 使用 Sloppy 模式 (默认: false)
            lockBorder=true 或 border=true         - 锁定边界顶点 (默认: true)
            attributeWeight=0.5 或 w=0.5           - 法线权重 (默认: 0.5)
            ignoreAttributes=false 或 ignore=false - 忽略所有属性 (默认: false)
            enablePrune=false 或 prune=false       - 启用 Prune 模式 (默认: false)
        """
    )
    
    @Argument(help: "输入的 USDZ 文件路径")
    var input: String
    
    // MARK: - 新参数：质量级别和输出路径映射（推荐使用）
    /// 质量级别和输出路径映射
    /// 格式：preset:path 或 custom:path:ratio[:key=value...]
    /// 每个 --quality 参数对应一个质量级别和其输出路径
    /// 示例：
    ///   --quality "original:./high/model.usdz"
    ///   --quality "custom:./custom/model.usdz:0.3:errorThreshold=0.02"
    @Option(name: .long, help: "质量级别和输出路径（格式：preset:path 或 custom:path:ratio[:key=value...]）")
    var quality: [String] = []
    
    // MARK: - 兼容旧参数（单个质量级别）
    @Option(name: .shortAndLong, help: "输出文件路径（单个质量级别时使用，与 --preset 配合）")
    var output: String?
    
    @Option(name: .shortAndLong, help: "输出文件夹路径（多个质量级别时使用，与 --presets 配合）")
    var outputDir: String?
    
    @Flag(name: .shortAndLong, help: "覆盖已存在的输出文件")
    var overwrite: Bool = false
    
    @Option(name: .long, help: "质量预设（单个，与 --output 配合）: original, standard, minimal, custom")
    var preset: String?
    
    @Option(name: .long, help: "质量预设（多个，与 --output-dir 配合）: original,standard,minimal,custom")
    var presets: String?
    
    // ========== Custom 模式参数（仅在使用 custom 预设时有效）==========
    // 必填参数
    @Option(name: .shortAndLong, help: "[Custom 必填] 简化比例 (0.0-1.0, 例如 0.5 表示保留50%)")
    var ratio: Float?
    
    // 选填参数 - 基础参数
    @Option(name: .long, help: "[Custom 选填] 误差阈值 (0~1+, 默认: 0.01, 越小越严格)")
    var errorThreshold: Float?
    
    @Option(name: .long, help: "[Custom 选填] 最小面数保护 (默认: 200, 低于此面数不简化)")
    var minFaceCount: Int?
    
    // 选填参数 - 高级参数
    @Flag(name: .long, help: "[Custom 选填] 使用 Sloppy 模式（激进但快速的简化）")
    var useSloppy: Bool = false
    
    @Flag(name: .long, help: "[Custom 选填] 锁定边界顶点（保护UV接缝，默认开启，使用 --no-lock-border 关闭）")
    var lockBorder: Bool = true
    
    @Option(name: .long, help: "[Custom 选填] 法线权重 (0.0-1.0, 默认: 0.5, 0.0=忽略法线, 1.0=完全保护)")
    var attributeWeight: Float?
    
    @Flag(name: .long, help: "[Custom 选填] 忽略所有属性，仅考虑位置（更激进）")
    var ignoreAttributes: Bool = false
    
    @Flag(name: .long, help: "[Custom 选填] 启用 Prune 模式（移除断开的网格部分）")
    var enablePrune: Bool = false
    
    func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        
        // 验证输入文件
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            print("\(Colors.red)❌ 错误: 输入文件不存在: \(input)\(Colors.reset)")
            throw ExitCode.failure
        }
        
        guard inputURL.pathExtension.lowercased() == "usdz" else {
            print("\(Colors.red)❌ 错误: 输入文件必须是 .usdz 格式\(Colors.reset)")
            throw ExitCode.failure
        }
        
        let inputName = inputURL.deletingPathExtension().lastPathComponent
        var qualitiesAndURLs: [(SimplifyType, URL)] = []
        
        // MARK: - 优先使用新的 --quality 参数
        if !quality.isEmpty {
            // 解析每个 --quality 参数
            for qualitySpec in quality {
                let (simplifyType, outputURL) = try parseQualitySpec(
                    qualitySpec: qualitySpec,
                    inputName: inputName
                )
                qualitiesAndURLs.append((simplifyType, outputURL))
            }
        } else {
            // MARK: - 兼容旧参数方式
            // 解析质量级别
            let qualityTypes: [SimplifyType]
            if let presets = presets {
            // 多个质量级别
            let presetList = presets.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            qualityTypes = try presetList.map { presetStr in
                switch presetStr.lowercased() {
                case "original":
                    return .original
                case "standard":
                    return .standard
                case "minimal":
                    return .minimal
                case "custom":
                    guard let ratio = ratio else {
                        print("\(Colors.red)❌ 错误: custom 模式必须指定 --ratio 参数\(Colors.reset)")
                        throw ExitCode.failure
                    }
                    let options = try createCustomOptions(
                        ratio: ratio,
                        errorThreshold: errorThreshold,
                        minFaceCount: minFaceCount,
                        useSloppy: useSloppy,
                        lockBorder: lockBorder,
                        attributeWeight: attributeWeight,
                        ignoreAttributes: ignoreAttributes,
                        enablePrune: enablePrune
                    )
                    return .custom(options: options)
                default:
                    print("\(Colors.red)❌ 错误: 未知的预设类型: \(presetStr)\(Colors.reset)")
                    print("可用预设: original, standard, minimal, custom")
                    throw ExitCode.failure
                }
            }
        } else if let preset = preset {
            // 单个质量级别
            let simplifyType: SimplifyType
            switch preset.lowercased() {
            case "original":
                simplifyType = .original
            case "standard":
                simplifyType = .standard
            case "minimal":
                simplifyType = .minimal
            case "custom":
                guard let ratio = ratio else {
                    print("\(Colors.red)❌ 错误: custom 模式必须指定 --ratio 参数\(Colors.reset)")
                    throw ExitCode.failure
                }
                let options = try createCustomOptions(
                    ratio: ratio,
                    errorThreshold: errorThreshold,
                    minFaceCount: minFaceCount,
                    useSloppy: useSloppy,
                    lockBorder: lockBorder,
                    attributeWeight: attributeWeight,
                    ignoreAttributes: ignoreAttributes,
                    enablePrune: enablePrune
                )
                simplifyType = .custom(options: options)
            default:
                print("\(Colors.red)❌ 错误: 未知的预设类型: \(preset)\(Colors.reset)")
                print("可用预设: original, standard, minimal, custom")
                throw ExitCode.failure
            }
            qualityTypes = [simplifyType]
            } else {
                // 默认使用 custom（需要 ratio）
                guard let ratio = ratio else {
                    print("\(Colors.red)❌ 错误: 使用 custom 模式时必须指定 --ratio 参数\(Colors.reset)")
                    throw ExitCode.failure
                }
                let options = try createCustomOptions(
                    ratio: ratio,
                    errorThreshold: errorThreshold,
                    minFaceCount: minFaceCount,
                    useSloppy: useSloppy,
                    lockBorder: lockBorder,
                    attributeWeight: attributeWeight,
                    ignoreAttributes: ignoreAttributes,
                    enablePrune: enablePrune
                )
                qualityTypes = [.custom(options: options)]
            }
            
            // 确定输出路径
            var tempQualitiesAndURLs: [(SimplifyType, URL)] = []
        if qualityTypes.count == 1 {
            // 单个质量级别：使用 output 参数或默认路径
            let outputURL: URL
            if let output = output {
                outputURL = URL(fileURLWithPath: output)
            } else {
                let outputDir = inputURL.deletingLastPathComponent()
                outputURL = outputDir.appendingPathComponent("\(inputName)_simplified.usdz")
            }
            
            // 确保输出目录存在
            let outputDir = outputURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: outputDir.path) {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            }
            
            // 检查输出文件是否已存在
            if FileManager.default.fileExists(atPath: outputURL.path) && !overwrite {
                print("\(Colors.yellow)⚠️ 输出文件已存在: \(outputURL.path)\(Colors.reset)")
                print("使用 --overwrite 标志来覆盖现有文件")
                throw ExitCode.failure
            }
            
            tempQualitiesAndURLs = [(qualityTypes[0], outputURL)]
            } else {
                // 多个质量级别：使用 outputDir 参数或默认路径
                let outputDirURL: URL
                if let outputDir = outputDir {
                    outputDirURL = URL(fileURLWithPath: outputDir)
                } else {
                    let inputDir = inputURL.deletingLastPathComponent()
                    outputDirURL = inputDir.appendingPathComponent("\(inputName)_multi_quality")
                }
                
                // 创建输出文件夹
                if !FileManager.default.fileExists(atPath: outputDirURL.path) {
                    try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)
                }
                
                tempQualitiesAndURLs = qualityTypes.map { type in
                    let suffix: String
                    switch type {
                    case .original:
                        suffix = "original"
                    case .standard:
                        suffix = "standard"
                    case .minimal:
                        suffix = "minimal"
                    case .custom(let opts):
                        suffix = "custom_\(Int(opts.targetRatio * 100))"
                    }
                    let outputURL = outputDirURL.appendingPathComponent("\(inputName)_\(suffix).usdz")
                    return (type, outputURL)
                }
            }
            qualitiesAndURLs = tempQualitiesAndURLs
        }
        
        // 打印处理计划
        print("\(Colors.cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(Colors.reset)")
        print("\(Colors.blue)🎯 USDZ 文件简化\(Colors.reset)")
        print("\(Colors.cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(Colors.reset)")
        print("📂 输入文件: \(inputURL.lastPathComponent)")
        if qualitiesAndURLs.count == 1 {
            print("📤 输出文件: \(qualitiesAndURLs[0].1.lastPathComponent)")
            print("📊 简化比例: \(qualitiesAndURLs[0].0.ratioValue * 100)%")
        } else {
            print("📤 输出路径数: \(qualitiesAndURLs.count)")
            print("📊 质量级别:")
            for (index, (type, url)) in qualitiesAndURLs.enumerated() {
                print("   [\(index + 1)] \(type.displayName) → \(url.path)")
            }
        }
        print("")
        
        do {
            let startTime = Date()
            
            // 调用简化函数
            try await ModelEntity.loadAndExportToCustomURLs(
                contentsOf: inputURL,
                qualitiesAndURLs: qualitiesAndURLs,
                overwriteExisting: overwrite,
                progressCallback: { current, total, type in
                    print("\(Colors.blue)⏳ 处理进度: \(current)/\(total) - \(type.displayName)\(Colors.reset)")
                }
            )
            
            // 验证文件是否成功保存
            for (type, url) in qualitiesAndURLs {
                if verifyFileSaved(url: url) {
                    print("\(Colors.green)✅ 文件已保存: \(url.lastPathComponent)\(Colors.reset)")
                } else {
                    print("\(Colors.yellow)⚠️ 警告: 文件可能未正确保存: \(url.lastPathComponent)\(Colors.reset)")
                }
            }
            
            let duration = Date().timeIntervalSince(startTime)
            print("")
            print("\(Colors.green)✅ 简化完成！耗时: \(String(format: "%.2f", duration))秒\(Colors.reset)")
            if qualitiesAndURLs.count == 1 {
                print("📁 输出文件: \(qualitiesAndURLs[0].1.path)")
            } else {
                print("📁 输出文件列表:")
                for (type, url) in qualitiesAndURLs {
                    print("   - \(type.displayName): \(url.path)")
                }
            }
            
        } catch {
            print("")
            print("\(Colors.red)❌ 简化失败: \(error.localizedDescription)\(Colors.reset)")
            throw ExitCode.failure
        }
    }
    
    // MARK: - 辅助函数：解析 --quality 参数
    /// 解析 --quality 参数，返回 SimplifyType 和输出 URL
    /// - Parameters:
    ///   - qualitySpec: 质量规格字符串，格式：preset:path 或 custom:path:ratio[:key=value...]
    ///   - inputName: 输入文件名（用于自动生成文件名）
    /// - Returns: (SimplifyType, URL) 元组
    /// - Throws: 解析错误时抛出
    ///
    /// 支持的格式：
    ///   - 预设模式: "original:./path/to/file.usdz"
    ///   - Custom 模式: "custom:./path/to/file.usdz:0.3"
    ///   - Custom 模式 + 参数: "custom:./path/to/file.usdz:0.3:errorThreshold=0.02:minFaceCount=300"
    private func parseQualitySpec(qualitySpec: String, inputName: String) throws -> (SimplifyType, URL) {
        // 使用冒号分隔，最多支持 10 个部分（preset:path:ratio:key1=value1:...）
        let parts = qualitySpec.split(separator: ":", maxSplits: 10)
        guard parts.count >= 2 else {
            print("\(Colors.red)❌ 错误: 无效的质量级别格式: \(qualitySpec)\(Colors.reset)")
            print("格式应为: preset:path 或 custom:path:ratio[:key=value...]")
            throw ExitCode.failure
        }
        
        let presetStr = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
        let pathStr = String(parts[1]).trimmingCharacters(in: .whitespaces)
        
        // 解析质量级别
        let simplifyType: SimplifyType
        switch presetStr {
        case "original":
            simplifyType = .original
        case "standard":
            simplifyType = .standard
        case "minimal":
            simplifyType = .minimal
        case "custom":
            // 解析 custom:path:ratio[:key=value...]
            guard parts.count >= 3 else {
                print("\(Colors.red)❌ 错误: custom 格式错误，至少需要 path 和 ratio\(Colors.reset)")
                print("格式: custom:path:ratio[:key=value...]")
                throw ExitCode.failure
            }
            
            let ratioStr = String(parts[2]).trimmingCharacters(in: .whitespaces)
            guard let customRatio = Float(ratioStr), customRatio >= 0 && customRatio <= 1 else {
                print("\(Colors.red)❌ 错误: 无效的 ratio 值: \(ratioStr)\(Colors.reset)")
                print("ratio 必须在 0.0-1.0 之间")
                throw ExitCode.failure
            }
            
            // 解析可选的键值对参数（使用默认值）
            var customErrorThreshold: Float? = nil
            var customMinFaceCount: Int? = nil
            var customUseSloppy: Bool = false
            var customLockBorder: Bool = true
            var customAttributeWeight: Float? = nil
            var customIgnoreAttributes: Bool = false
            var customEnablePrune: Bool = false
            
            // 解析键值对（从第4个部分开始，索引为3）
            for i in 3..<parts.count {
                let kvPair = String(parts[i]).trimmingCharacters(in: .whitespaces)
                let kv = kvPair.split(separator: "=", maxSplits: 1)
                
                guard kv.count == 2 else {
                    print("\(Colors.yellow)⚠️ 警告: 忽略无效的键值对: \(kvPair)\(Colors.reset)")
                    continue
                }
                
                let key = String(kv[0]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(kv[1]).trimmingCharacters(in: .whitespaces)
                
                switch key {
                case "errorthreshold", "e":
                    if let val = Float(value) {
                        customErrorThreshold = val
                    } else {
                        print("\(Colors.yellow)⚠️ 警告: 无效的 errorThreshold 值: \(value)，使用默认值 0.01\(Colors.reset)")
                    }
                case "minfacecount", "m":
                    if let val = Int(value) {
                        customMinFaceCount = val
                    } else {
                        print("\(Colors.yellow)⚠️ 警告: 无效的 minFaceCount 值: \(value)，使用默认值 200\(Colors.reset)")
                    }
                case "usesloppy", "sloppy", "s":
                    customUseSloppy = value.lowercased() == "true"
                case "lockborder", "border", "b":
                    customLockBorder = value.lowercased() == "true"
                case "attributeweight", "weight", "w":
                    if let val = Float(value) {
                        customAttributeWeight = val
                    } else {
                        print("\(Colors.yellow)⚠️ 警告: 无效的 attributeWeight 值: \(value)，使用默认值 0.5\(Colors.reset)")
                    }
                case "ignoreattributes", "ignore", "i":
                    customIgnoreAttributes = value.lowercased() == "true"
                case "enableprune", "prune", "p":
                    customEnablePrune = value.lowercased() == "true"
                default:
                    print("\(Colors.yellow)⚠️ 警告: 未知的参数键: \(key)，已忽略\(Colors.reset)")
                }
            }
            
            // 创建 SimplificationOptions（使用解析的值或默认值）
            let options = SimplificationOptions(
                targetRatio: customRatio,
                errorThreshold: customErrorThreshold ?? 0.01,
                minFaceCount: customMinFaceCount ?? 200,
                useSloppy: customUseSloppy,
                lockBorder: customLockBorder,
                attributeWeight: customAttributeWeight ?? 0.5,
                ignoreAttributes: customIgnoreAttributes,
                enablePrune: customEnablePrune
            )
            
            simplifyType = .custom(options: options)
        default:
            print("\(Colors.red)❌ 错误: 未知的预设类型: \(presetStr)\(Colors.reset)")
            print("可用预设: original, standard, minimal, custom")
            throw ExitCode.failure
        }
        
        // 构建输出路径
        var outputURL = URL(fileURLWithPath: pathStr)
        
        // 如果路径是文件夹（没有扩展名或是目录路径），自动添加文件名
        if outputURL.pathExtension.isEmpty || outputURL.hasDirectoryPath {
            let suffix: String
            switch simplifyType {
            case .original:
                suffix = "original"
            case .standard:
                suffix = "standard"
            case .minimal:
                suffix = "minimal"
            case .custom(let opts):
                suffix = "custom_\(Int(opts.targetRatio * 100))"
            }
            outputURL = outputURL.appendingPathComponent("\(inputName)_\(suffix).usdz")
        }
        
        // 确保输出目录存在
        let outputDir = outputURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: outputDir.path) {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        }
        
        return (simplifyType, outputURL)
    }
}

// MARK: - 批量处理命令
struct BatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract: "批量处理文件夹中的所有 USDZ 文件，支持为每个质量级别指定单独的输出文件夹",
        discussion: """
        使用示例:
        
        【推荐方式】使用 --quality 参数（每个模式对应单独文件夹）:
          # 基本用法：每个质量级别保存到不同文件夹
          usdzutil batch ./input_folder \\
            --quality "original:./high_quality/" \\
            --quality "standard:./medium_quality/" \\
            --quality "minimal:./low_quality/"
          
          # Custom 模式（只有 ratio）
          usdzutil batch ./input_folder \\
            --quality "custom:./custom_quality/:0.3"
          
          # Custom 模式 + 参数
          usdzutil batch ./input_folder \\
            --quality "custom:./output/:0.3:errorThreshold=0.02:minFaceCount=300"
          
          # 多个不同的 custom 配置
          usdzutil batch ./input_folder \\
            --quality "original:./path1/" \\
            --quality "custom:./path2/:0.3:errorThreshold=0.02" \\
            --quality "custom:./path3/:0.7:attributeWeight=0.8:useSloppy=true"
        
        【兼容方式】使用 --preset/--presets 参数:
          # 单个质量级别
          usdzutil batch ./input_folder --preset standard --output ./output_folder
          
          # 多个质量级别（保存到基础文件夹下的子文件夹）
          usdzutil batch ./input_folder --presets original,standard,minimal --output-base ./outputs
        
        Custom 模式参数说明（在 --quality 中使用）:
          格式: custom:folder:ratio[:key=value[:key=value...]]
          
          必填:
            folder: 输出文件夹路径
            ratio: 简化比例 (0.0-1.0)
          
          可选键值对（支持完整名和简短名）:
            errorThreshold=0.01 或 e=0.01          - 误差阈值 (默认: 0.01)
            minFaceCount=200 或 m=200              - 最小面数保护 (默认: 200)
            useSloppy=false 或 sloppy=false       - 使用 Sloppy 模式 (默认: false)
            lockBorder=true 或 border=true         - 锁定边界顶点 (默认: true)
            attributeWeight=0.5 或 w=0.5           - 法线权重 (默认: 0.5)
            ignoreAttributes=false 或 ignore=false - 忽略所有属性 (默认: false)
            enablePrune=false 或 prune=false       - 启用 Prune 模式 (默认: false)
        """
    )
    
    @Argument(help: "输入的文件夹路径")
    var input: String
    
    // MARK: - 新参数：质量级别和输出文件夹映射（推荐使用）
    /// 质量级别和输出文件夹映射
    /// 格式：preset:folder 或 custom:folder:ratio[:key=value...]
    /// 每个 --quality 参数对应一个质量级别和其输出文件夹
    /// 示例：
    ///   --quality "original:./high_quality/"
    ///   --quality "custom:./custom_quality/:0.3:errorThreshold=0.02"
    @Option(name: .long, help: "质量级别和输出文件夹（格式：preset:folder 或 custom:folder:ratio[:key=value...]）")
    var quality: [String] = []
    
    // MARK: - 兼容旧参数（单个质量级别）
    @Option(name: .shortAndLong, help: "输出文件夹路径（单个质量级别时使用，与 --preset 配合）")
    var output: String?
    
    @Option(name: .shortAndLong, help: "输出基础文件夹路径（多个质量级别时使用，与 --presets 配合）")
    var outputBase: String?
    
    @Flag(name: .shortAndLong, help: "覆盖已存在的文件")
    var overwrite: Bool = false
    
    @Option(name: .long, help: "质量预设（单个，与 --output 配合）: original, standard, minimal, custom")
    var preset: String?
    
    @Option(name: .long, help: "质量预设（多个，与 --output-base 配合）: original,standard,minimal,custom")
    var presets: String?
    
    // ========== Custom 模式参数（仅在使用 custom 预设时有效）==========
    // 必填参数
    @Option(name: .shortAndLong, help: "[Custom 必填] 简化比例 (0.0-1.0, 例如 0.5 表示保留50%)")
    var ratio: Float?
    
    // 选填参数 - 基础参数
    @Option(name: .long, help: "[Custom 选填] 误差阈值 (0~1+, 默认: 0.01, 越小越严格)")
    var errorThreshold: Float?
    
    @Option(name: .long, help: "[Custom 选填] 最小面数保护 (默认: 200, 低于此面数不简化)")
    var minFaceCount: Int?
    
    // 选填参数 - 高级参数
    @Flag(name: .long, help: "[Custom 选填] 使用 Sloppy 模式（激进但快速的简化）")
    var useSloppy: Bool = false
    
    @Flag(name: .long, help: "[Custom 选填] 锁定边界顶点（保护UV接缝，默认开启，使用 --no-lock-border 关闭）")
    var lockBorder: Bool = true
    
    @Option(name: .long, help: "[Custom 选填] 法线权重 (0.0-1.0, 默认: 0.5, 0.0=忽略法线, 1.0=完全保护)")
    var attributeWeight: Float?
    
    @Flag(name: .long, help: "[Custom 选填] 忽略所有属性，仅考虑位置（更激进）")
    var ignoreAttributes: Bool = false
    
    @Flag(name: .long, help: "[Custom 选填] 启用 Prune 模式（移除断开的网格部分）")
    var enablePrune: Bool = false
    
    func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        
        // 验证输入文件夹
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            print("\(Colors.red)❌ 错误: 输入文件夹不存在: \(input)\(Colors.reset)")
            throw ExitCode.failure
        }
        
        var qualitiesAndFolderURLs: [(SimplifyType, URL)] = []
        
        // MARK: - 优先使用新的 --quality 参数
        if !quality.isEmpty {
            // 解析每个 --quality 参数（批量处理中路径是文件夹）
            for qualitySpec in quality {
                let (simplifyType, folderURL) = try parseQualityFolderSpec(
                    qualitySpec: qualitySpec
                )
                qualitiesAndFolderURLs.append((simplifyType, folderURL))
            }
        } else {
            // MARK: - 兼容旧参数方式
            // 解析质量级别
            let qualityTypes: [SimplifyType]
            if let presets = presets {
            // 多个质量级别
            let presetList = presets.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            qualityTypes = try presetList.map { presetStr in
                switch presetStr.lowercased() {
                case "original":
                    return .original
                case "standard":
                    return .standard
                case "minimal":
                    return .minimal
                case "custom":
                    guard let ratio = ratio else {
                        print("\(Colors.red)❌ 错误: custom 模式必须指定 --ratio 参数\(Colors.reset)")
                        throw ExitCode.failure
                    }
                    let options = try createCustomOptions(
                        ratio: ratio,
                        errorThreshold: errorThreshold,
                        minFaceCount: minFaceCount,
                        useSloppy: useSloppy,
                        lockBorder: lockBorder,
                        attributeWeight: attributeWeight,
                        ignoreAttributes: ignoreAttributes,
                        enablePrune: enablePrune
                    )
                    return .custom(options: options)
                default:
                    print("\(Colors.red)❌ 错误: 未知的预设类型: \(presetStr)\(Colors.reset)")
                    print("可用预设: original, standard, minimal, custom")
                    throw ExitCode.failure
                }
            }
        } else if let preset = preset {
            // 单个质量级别
            let simplifyType: SimplifyType
            switch preset.lowercased() {
            case "original":
                simplifyType = .original
            case "standard":
                simplifyType = .standard
            case "minimal":
                simplifyType = .minimal
            case "custom":
                guard let ratio = ratio else {
                    print("\(Colors.red)❌ 错误: custom 模式必须指定 --ratio 参数\(Colors.reset)")
                    throw ExitCode.failure
                }
                let options = try createCustomOptions(
                    ratio: ratio,
                    errorThreshold: errorThreshold,
                    minFaceCount: minFaceCount,
                    useSloppy: useSloppy,
                    lockBorder: lockBorder,
                    attributeWeight: attributeWeight,
                    ignoreAttributes: ignoreAttributes,
                    enablePrune: enablePrune
                )
                simplifyType = .custom(options: options)
            default:
                print("\(Colors.red)❌ 错误: 未知的预设类型: \(preset)\(Colors.reset)")
                print("可用预设: original, standard, minimal, custom")
                throw ExitCode.failure
            }
            qualityTypes = [simplifyType]
        } else {
            // 默认使用 custom（需要 ratio）
            guard let ratio = ratio else {
                print("\(Colors.red)❌ 错误: 使用 custom 模式时必须指定 --ratio 参数\(Colors.reset)")
                throw ExitCode.failure
            }
            let options = try createCustomOptions(
                ratio: ratio,
                errorThreshold: errorThreshold,
                minFaceCount: minFaceCount,
                useSloppy: useSloppy,
                lockBorder: lockBorder,
                attributeWeight: attributeWeight,
                ignoreAttributes: ignoreAttributes,
                enablePrune: enablePrune
            )
            qualityTypes = [.custom(options: options)]
            }
            
            // 确定输出文件夹
            var tempQualitiesAndFolderURLs: [(SimplifyType, URL)] = []
            if qualityTypes.count == 1 {
                // 单个质量级别：使用 output 参数或默认路径
                let outputURL: URL
                if let output = output {
                    outputURL = URL(fileURLWithPath: output)
                } else {
                    outputURL = inputURL.appendingPathComponent("simplified")
                }
                
                // 创建输出文件夹
                if !FileManager.default.fileExists(atPath: outputURL.path) {
                    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
                }
                
                tempQualitiesAndFolderURLs = [(qualityTypes[0], outputURL)]
            } else {
                // 多个质量级别：使用 outputBase 参数或默认路径
                let baseOutputURL: URL
                if let outputBase = outputBase {
                    baseOutputURL = URL(fileURLWithPath: outputBase)
                } else {
                    baseOutputURL = inputURL.appendingPathComponent("simplified_multi_quality")
                }
                
                tempQualitiesAndFolderURLs = qualityTypes.map { type in
                    let folderName: String
                    switch type {
                    case .original:
                        folderName = "original"
                    case .standard:
                        folderName = "standard"
                    case .minimal:
                        folderName = "minimal"
                    case .custom(let opts):
                        folderName = "custom_\(Int(opts.targetRatio * 100))"
                    }
                    let folderURL = baseOutputURL.appendingPathComponent(folderName)
                    return (type, folderURL)
                }
            }
            qualitiesAndFolderURLs = tempQualitiesAndFolderURLs
        }
        
        // 打印处理计划
        print("\(Colors.cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(Colors.reset)")
        print("\(Colors.blue)🚀 批量处理 USDZ 文件\(Colors.reset)")
        print("\(Colors.cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(Colors.reset)")
        print("📂 输入文件夹: \(inputURL.path)")
        if qualitiesAndFolderURLs.count == 1 {
            print("📤 输出文件夹: \(qualitiesAndFolderURLs[0].1.path)")
            print("📊 简化比例: \(qualitiesAndFolderURLs[0].0.ratioValue * 100)%")
        } else {
            print("📤 输出文件夹数: \(qualitiesAndFolderURLs.count)")
            print("📊 质量级别:")
            for (index, (type, folderURL)) in qualitiesAndFolderURLs.enumerated() {
                print("   [\(index + 1)] \(type.displayName) → \(folderURL.path)/")
            }
        }
        print("")
        
        do {
            let result = try await ModelEntity.batchProcessFolderToCustomFolders(
                sourceFolder: inputURL,
                qualitiesAndFolderURLs: qualitiesAndFolderURLs,
                overwriteExisting: overwrite,
                progressCallback: { current, total, filename, type in
                    print("\(Colors.blue)⏳ [\(current)/\(total)] 处理: \(filename) - \(type.displayName)\(Colors.reset)")
                }
            )
            
            // 批量处理已完成，文件已同步保存
            
            print("")
            print("\(Colors.cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(Colors.reset)")
            print("\(Colors.green)✅ 批量处理完成！\(Colors.reset)")
            print("📊 总计: \(result.totalCount)")
            print("\(Colors.green)✅ 成功: \(result.successCount)\(Colors.reset)")
            print("\(Colors.red)❌ 失败: \(result.failureCount)\(Colors.reset)")
            if qualitiesAndFolderURLs.count == 1 {
                print("📁 输出文件夹: \(qualitiesAndFolderURLs[0].1.path)")
            } else {
                print("📁 输出文件夹列表:")
                for (type, folderURL) in qualitiesAndFolderURLs {
                    print("   - \(type.displayName): \(folderURL.path)/")
                }
            }
            
        } catch {
            print("")
            print("\(Colors.red)❌ 批量处理失败: \(error.localizedDescription)\(Colors.reset)")
            throw ExitCode.failure
        }
    }
    
    // MARK: - 辅助函数：解析 --quality 参数（批量处理版本）
    /// 解析 --quality 参数，返回 SimplifyType 和输出文件夹 URL（批量处理专用）
    /// - Parameter qualitySpec: 质量规格字符串，格式：preset:folder 或 custom:folder:ratio[:key=value...]
    /// - Returns: (SimplifyType, URL) 元组，URL 是文件夹路径
    /// - Throws: 解析错误时抛出
    ///
    /// 支持的格式：
    ///   - 预设模式: "original:./output_folder/"
    ///   - Custom 模式: "custom:./output_folder/:0.3"
    ///   - Custom 模式 + 参数: "custom:./output_folder/:0.3:errorThreshold=0.02:minFaceCount=300"
    private func parseQualityFolderSpec(qualitySpec: String) throws -> (SimplifyType, URL) {
        // 使用冒号分隔，最多支持 10 个部分
        let parts = qualitySpec.split(separator: ":", maxSplits: 10)
        guard parts.count >= 2 else {
            print("\(Colors.red)❌ 错误: 无效的质量级别格式: \(qualitySpec)\(Colors.reset)")
            print("格式应为: preset:folder 或 custom:folder:ratio[:key=value...]")
            throw ExitCode.failure
        }
        
        let presetStr = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
        let folderStr = String(parts[1]).trimmingCharacters(in: .whitespaces)
        
        // 解析质量级别（与 SimplifyCommand 相同的逻辑）
        let simplifyType: SimplifyType
        switch presetStr {
        case "original":
            simplifyType = .original
        case "standard":
            simplifyType = .standard
        case "minimal":
            simplifyType = .minimal
        case "custom":
            // 解析 custom:folder:ratio[:key=value...]
            guard parts.count >= 3 else {
                print("\(Colors.red)❌ 错误: custom 格式错误，至少需要 folder 和 ratio\(Colors.reset)")
                print("格式: custom:folder:ratio[:key=value...]")
                throw ExitCode.failure
            }
            
            let ratioStr = String(parts[2]).trimmingCharacters(in: .whitespaces)
            guard let customRatio = Float(ratioStr), customRatio >= 0 && customRatio <= 1 else {
                print("\(Colors.red)❌ 错误: 无效的 ratio 值: \(ratioStr)\(Colors.reset)")
                print("ratio 必须在 0.0-1.0 之间")
                throw ExitCode.failure
            }
            
            // 解析可选的键值对参数（使用默认值）
            var customErrorThreshold: Float? = nil
            var customMinFaceCount: Int? = nil
            var customUseSloppy: Bool = false
            var customLockBorder: Bool = true
            var customAttributeWeight: Float? = nil
            var customIgnoreAttributes: Bool = false
            var customEnablePrune: Bool = false
            
            // 解析键值对（从第4个部分开始）
            for i in 3..<parts.count {
                let kvPair = String(parts[i]).trimmingCharacters(in: .whitespaces)
                let kv = kvPair.split(separator: "=", maxSplits: 1)
                
                guard kv.count == 2 else {
                    print("\(Colors.yellow)⚠️ 警告: 忽略无效的键值对: \(kvPair)\(Colors.reset)")
                    continue
                }
                
                let key = String(kv[0]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(kv[1]).trimmingCharacters(in: .whitespaces)
                
                switch key {
                case "errorthreshold", "e":
                    if let val = Float(value) {
                        customErrorThreshold = val
                    } else {
                        print("\(Colors.yellow)⚠️ 警告: 无效的 errorThreshold 值: \(value)，使用默认值 0.01\(Colors.reset)")
                    }
                case "minfacecount", "m":
                    if let val = Int(value) {
                        customMinFaceCount = val
                    } else {
                        print("\(Colors.yellow)⚠️ 警告: 无效的 minFaceCount 值: \(value)，使用默认值 200\(Colors.reset)")
                    }
                case "usesloppy", "sloppy", "s":
                    customUseSloppy = value.lowercased() == "true"
                case "lockborder", "border", "b":
                    customLockBorder = value.lowercased() == "true"
                case "attributeweight", "weight", "w":
                    if let val = Float(value) {
                        customAttributeWeight = val
                    } else {
                        print("\(Colors.yellow)⚠️ 警告: 无效的 attributeWeight 值: \(value)，使用默认值 0.5\(Colors.reset)")
                    }
                case "ignoreattributes", "ignore", "i":
                    customIgnoreAttributes = value.lowercased() == "true"
                case "enableprune", "prune", "p":
                    customEnablePrune = value.lowercased() == "true"
                default:
                    print("\(Colors.yellow)⚠️ 警告: 未知的参数键: \(key)，已忽略\(Colors.reset)")
                }
            }
            
            // 创建 SimplificationOptions
            let options = SimplificationOptions(
                targetRatio: customRatio,
                errorThreshold: customErrorThreshold ?? 0.01,
                minFaceCount: customMinFaceCount ?? 200,
                useSloppy: customUseSloppy,
                lockBorder: customLockBorder,
                attributeWeight: customAttributeWeight ?? 0.5,
                ignoreAttributes: customIgnoreAttributes,
                enablePrune: customEnablePrune
            )
            
            simplifyType = .custom(options: options)
        default:
            print("\(Colors.red)❌ 错误: 未知的预设类型: \(presetStr)\(Colors.reset)")
            print("可用预设: original, standard, minimal, custom")
            throw ExitCode.failure
        }
        
        // 构建输出文件夹路径
        let folderURL = URL(fileURLWithPath: folderStr)
        
        // 确保输出文件夹存在
        if !FileManager.default.fileExists(atPath: folderURL.path) {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
        
        return (simplifyType, folderURL)
    }
}

// MARK: - 多质量级别命令
struct MultiQualityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "multi-quality",
        abstract: "生成多个质量级别的简化文件"
    )
    
    @Argument(help: "输入的 USDZ 文件路径")
    var input: String
    
    @Option(name: .shortAndLong, help: "输出文件夹路径")
    var outputDir: String?
    
    @Flag(name: .shortAndLong, help: "覆盖已存在的文件")
    var overwrite: Bool = false
    
    func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        
        // 验证输入文件
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            print("\(Colors.red)❌ 错误: 输入文件不存在: \(input)\(Colors.reset)")
            throw ExitCode.failure
        }
        
        // 确定输出文件夹
        let outputDirURL: URL
        if let outputDir = outputDir {
            outputDirURL = URL(fileURLWithPath: outputDir)
        } else {
            let inputName = inputURL.deletingPathExtension().lastPathComponent
            let inputDir = inputURL.deletingLastPathComponent()
            outputDirURL = inputDir.appendingPathComponent("\(inputName)_multi_quality")
        }
        
        // 创建输出文件夹
        if !FileManager.default.fileExists(atPath: outputDirURL.path) {
            try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)
        }
        
        let inputName = inputURL.deletingPathExtension().lastPathComponent
        
        // 定义质量级别
        let qualities: [(SimplifyType, String)] = [
            (.original, "original"),
            (.standard, "standard"),
            (.minimal, "minimal")
        ]
        
        let qualitiesAndURLs: [(SimplifyType, URL)] = qualities.map { type, suffix in
            let outputURL = outputDirURL.appendingPathComponent("\(inputName)_\(suffix).usdz")
            return (type, outputURL)
        }
        
        print("\(Colors.cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(Colors.reset)")
        print("\(Colors.blue)🎨 生成多质量级别文件\(Colors.reset)")
        print("\(Colors.cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(Colors.reset)")
        print("📂 输入文件: \(inputURL.lastPathComponent)")
        print("📤 输出文件夹: \(outputDirURL.path)")
        print("📊 质量级别: \(qualities.count)")
        for (type, suffix) in qualities {
            print("   - \(type.displayName) → \(inputName)_\(suffix).usdz")
        }
        print("")
        
        do {
            let startTime = Date()
            
            let _ = try await ModelEntity.loadAndExportToCustomURLs(
                contentsOf: inputURL,
                qualitiesAndURLs: qualitiesAndURLs,
                overwriteExisting: overwrite,
                progressCallback: { current, total, type in
                    print("\(Colors.blue)⏳ [\(current)/\(total)] 生成: \(type.displayName)\(Colors.reset)")
                }
            )
            
            // 验证文件是否成功保存
            for (type, url) in qualitiesAndURLs {
                if verifyFileSaved(url: url) {
                    print("\(Colors.green)✅ 文件已保存: \(url.lastPathComponent)\(Colors.reset)")
                } else {
                    print("\(Colors.yellow)⚠️ 警告: 文件可能未正确保存: \(url.lastPathComponent)\(Colors.reset)")
                }
            }
            
            let duration = Date().timeIntervalSince(startTime)
            print("")
            print("\(Colors.green)✅ 多质量级别生成完成！耗时: \(String(format: "%.2f", duration))秒\(Colors.reset)")
            print("📁 输出文件夹: \(outputDirURL.path)")
            
        } catch {
            print("")
            print("\(Colors.red)❌ 生成失败: \(error.localizedDescription)\(Colors.reset)")
            throw ExitCode.failure
        }
    }
}

