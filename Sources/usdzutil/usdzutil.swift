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

// MARK: - 主命令
@main
struct USDZUtil: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usdzutil",
        abstract: "USDZ 模型简化工具 - 基于 RealityKit 和 meshoptimizer",
        discussion: """
        使用示例:
          # 简化单个文件（单个质量级别）
          usdzutil simplify input.usdz --output output.usdz --preset standard
          usdzutil simplify input.usdz --output output.usdz --ratio 0.3
          
          # 简化单个文件（多个质量级别）
          usdzutil simplify input.usdz --presets original,standard,minimal --output-dir ./outputs
          
          # 批量处理文件夹（单个质量级别）
          usdzutil batch ./input_folder --output ./output_folder --preset standard
          
          # 批量处理文件夹（多个质量级别）
          usdzutil batch ./input_folder --presets original,standard,minimal,custom --output-base ./outputs
          
          # 生成多个质量级别（使用 multi-quality 命令）
          usdzutil multi-quality input.usdz --output-dir ./outputs
        """,
        subcommands: [SimplifyCommand.self, BatchCommand.self, MultiQualityCommand.self]
    )
}

// MARK: - 简化单个文件命令
struct SimplifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simplify",
        abstract: "简化单个 USDZ 文件"
    )
    
    @Argument(help: "输入的 USDZ 文件路径")
    var input: String
    
    @Option(name: .shortAndLong, help: "输出文件路径（单个质量级别时使用）")
    var output: String?
    
    @Option(name: .shortAndLong, help: "输出文件夹路径（多个质量级别时使用）")
    var outputDir: String?
    
    @Option(name: .shortAndLong, help: "简化比例 (0.0-1.0, 默认: 0.5，仅用于 custom 模式)")
    var ratio: Float = 0.5
    
    @Flag(name: .shortAndLong, help: "覆盖已存在的输出文件")
    var overwrite: Bool = false
    
    @Option(name: .long, help: "质量预设（单个）: original, standard, minimal, custom")
    var preset: String?
    
    @Option(name: .long, help: "质量预设（多个，用逗号分隔）: original,standard,minimal,custom")
    var presets: String?
    
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
                    return .custom(options: SimplificationOptions(targetRatio: ratio))
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
                simplifyType = .custom(options: SimplificationOptions(targetRatio: ratio))
            default:
                print("\(Colors.red)❌ 错误: 未知的预设类型: \(preset)\(Colors.reset)")
                print("可用预设: original, standard, minimal, custom")
                throw ExitCode.failure
            }
            qualityTypes = [simplifyType]
        } else {
            // 默认使用 custom
            qualityTypes = [.custom(options: SimplificationOptions(targetRatio: ratio))]
        }
        
        let inputName = inputURL.deletingPathExtension().lastPathComponent
        
        // 确定输出路径
        let qualitiesAndURLs: [(SimplifyType, URL)]
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
            
            qualitiesAndURLs = [(qualityTypes[0], outputURL)]
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
            
            qualitiesAndURLs = qualityTypes.map { type in
                let suffix: String
                switch type {
                case .original:
                    suffix = "original"
                case .standard:
                    suffix = "standard"
                case .minimal:
                    suffix = "minimal"
                case .custom:
                    suffix = "custom"
                }
                let outputURL = outputDirURL.appendingPathComponent("\(inputName)_\(suffix).usdz")
                return (type, outputURL)
            }
        }
        
        print("\(Colors.cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(Colors.reset)")
        print("\(Colors.blue)🎯 USDZ 文件简化\(Colors.reset)")
        print("\(Colors.cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(Colors.reset)")
        print("📂 输入文件: \(inputURL.lastPathComponent)")
        if qualityTypes.count == 1 {
            print("📤 输出文件: \(qualitiesAndURLs[0].1.lastPathComponent)")
            print("📊 简化比例: \(qualityTypes[0].ratioValue * 100)%")
        } else {
            print("📤 输出文件夹: \(qualitiesAndURLs[0].1.deletingLastPathComponent().path)")
            print("📊 质量级别数: \(qualityTypes.count)")
            for (type, url) in qualitiesAndURLs {
                print("   - \(type.displayName) → \(url.lastPathComponent)")
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
            if qualityTypes.count == 1 {
                print("📁 输出文件: \(qualitiesAndURLs[0].1.path)")
            } else {
                print("📁 输出文件夹: \(qualitiesAndURLs[0].1.deletingLastPathComponent().path)")
            }
            
        } catch {
            print("")
            print("\(Colors.red)❌ 简化失败: \(error.localizedDescription)\(Colors.reset)")
            throw ExitCode.failure
        }
    }
}

// MARK: - 批量处理命令
struct BatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract: "批量处理文件夹中的所有 USDZ 文件"
    )
    
    @Argument(help: "输入的文件夹路径")
    var input: String
    
    @Option(name: .shortAndLong, help: "输出文件夹路径（单个质量级别时使用）")
    var output: String?
    
    @Option(name: .shortAndLong, help: "输出基础文件夹路径（多个质量级别时使用，会在此文件夹下创建子文件夹）")
    var outputBase: String?
    
    @Option(name: .shortAndLong, help: "简化比例 (0.0-1.0, 默认: 0.5，仅用于 custom 模式)")
    var ratio: Float = 0.5
    
    @Flag(name: .shortAndLong, help: "覆盖已存在的文件")
    var overwrite: Bool = false
    
    @Option(name: .long, help: "质量预设（单个）: original, standard, minimal, custom")
    var preset: String?
    
    @Option(name: .long, help: "质量预设（多个，用逗号分隔）: original,standard,minimal,custom")
    var presets: String?
    
    func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        
        // 验证输入文件夹
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            print("\(Colors.red)❌ 错误: 输入文件夹不存在: \(input)\(Colors.reset)")
            throw ExitCode.failure
        }
        
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
                    return .custom(options: SimplificationOptions(targetRatio: ratio))
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
                simplifyType = .custom(options: SimplificationOptions(targetRatio: ratio))
            default:
                print("\(Colors.red)❌ 错误: 未知的预设类型: \(preset)\(Colors.reset)")
                print("可用预设: original, standard, minimal, custom")
                throw ExitCode.failure
            }
            qualityTypes = [simplifyType]
        } else {
            // 默认使用 custom
            qualityTypes = [.custom(options: SimplificationOptions(targetRatio: ratio))]
        }
        
        // 确定输出文件夹
        let qualitiesAndFolderURLs: [(SimplifyType, URL)]
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
            
            qualitiesAndFolderURLs = [(qualityTypes[0], outputURL)]
        } else {
            // 多个质量级别：使用 outputBase 参数或默认路径
            let baseOutputURL: URL
            if let outputBase = outputBase {
                baseOutputURL = URL(fileURLWithPath: outputBase)
            } else {
                baseOutputURL = inputURL.appendingPathComponent("simplified_multi_quality")
            }
            
            qualitiesAndFolderURLs = qualityTypes.map { type in
                let folderName: String
                switch type {
                case .original:
                    folderName = "original"
                case .standard:
                    folderName = "standard"
                case .minimal:
                    folderName = "minimal"
                case .custom:
                    folderName = "custom"
                }
                let folderURL = baseOutputURL.appendingPathComponent(folderName)
                return (type, folderURL)
            }
        }
        
        print("\(Colors.cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(Colors.reset)")
        print("\(Colors.blue)🚀 批量处理 USDZ 文件\(Colors.reset)")
        print("\(Colors.cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(Colors.reset)")
        print("📂 输入文件夹: \(inputURL.path)")
        if qualityTypes.count == 1 {
            print("📤 输出文件夹: \(qualitiesAndFolderURLs[0].1.path)")
            print("📊 简化比例: \(qualityTypes[0].ratioValue * 100)%")
        } else {
            print("📤 输出基础文件夹: \(qualitiesAndFolderURLs[0].1.deletingLastPathComponent().path)")
            print("📊 质量级别数: \(qualityTypes.count)")
            for (type, folderURL) in qualitiesAndFolderURLs {
                print("   - \(type.displayName) → \(folderURL.lastPathComponent)/")
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
            if qualityTypes.count == 1 {
                print("📁 输出文件夹: \(qualitiesAndFolderURLs[0].1.path)")
            } else {
                print("📁 输出基础文件夹: \(qualitiesAndFolderURLs[0].1.deletingLastPathComponent().path)")
            }
            
        } catch {
            print("")
            print("\(Colors.red)❌ 批量处理失败: \(error.localizedDescription)\(Colors.reset)")
            throw ExitCode.failure
        }
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

