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

// MARK: - 主命令
@main
struct USDZUtil: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usdzutil",
        abstract: "USDZ 模型简化工具 - 基于 RealityKit 和 meshoptimizer",
        discussion: """
        使用示例:
          # 简化单个文件
          usdzutil simplify input.usdz --output output.usdz --ratio 0.3
          
          # 批量处理文件夹
          usdzutil batch ./input_folder --output ./output_folder --ratio 0.5
          
          # 生成多个质量级别
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
    
    @Option(name: .shortAndLong, help: "输出文件路径")
    var output: String?
    
    @Option(name: .shortAndLong, help: "简化比例 (0.0-1.0, 默认: 0.5)")
    var ratio: Float = 0.5
    
    @Flag(name: .shortAndLong, help: "覆盖已存在的输出文件")
    var overwrite: Bool = false
    
    @Option(name: .long, help: "质量预设: original, standard, minimal, custom")
    var preset: String?
    
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
        
        // 确定输出路径
        let outputURL: URL
        if let output = output {
            outputURL = URL(fileURLWithPath: output)
        } else {
            let inputName = inputURL.deletingPathExtension().lastPathComponent
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
        
        // 确定简化类型
        let simplifyType: SimplifyType
        if let preset = preset {
            switch preset.lowercased() {
            case "original":
                simplifyType = .original
            case "standard":
                simplifyType = .standard
            case "minimal":
                simplifyType = .minimal
            default:
                print("\(Colors.red)❌ 错误: 未知的预设类型: \(preset)\(Colors.reset)")
                print("可用预设: original, standard, minimal")
                throw ExitCode.failure
            }
        } else {
            simplifyType = .custom(options: SimplificationOptions(targetRatio: ratio))
        }
        
        print("\(Colors.cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(Colors.reset)")
        print("\(Colors.blue)🎯 USDZ 文件简化\(Colors.reset)")
        print("\(Colors.cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(Colors.reset)")
        print("📂 输入文件: \(inputURL.lastPathComponent)")
        print("📤 输出文件: \(outputURL.lastPathComponent)")
        print("📊 简化比例: \(simplifyType.ratioValue * 100)%")
        print("")
        
        do {
            let startTime = Date()
            
            // 调用简化函数
            try await ModelEntity.loadAndExportToCustomURLs(
                contentsOf: inputURL,
                qualitiesAndURLs: [(simplifyType, outputURL)],
                overwriteExisting: overwrite,
                progressCallback: { current, total, type in
                    print("\(Colors.blue)⏳ 处理进度: \(current)/\(total) - \(type.displayName)\(Colors.reset)")
                }
            )
            
            let duration = Date().timeIntervalSince(startTime)
            print("")
            print("\(Colors.green)✅ 简化完成！耗时: \(String(format: "%.2f", duration))秒\(Colors.reset)")
            print("📁 输出文件: \(outputURL.path)")
            
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
    
    @Option(name: .shortAndLong, help: "输出文件夹路径")
    var output: String?
    
    @Option(name: .shortAndLong, help: "简化比例 (0.0-1.0, 默认: 0.5)")
    var ratio: Float = 0.5
    
    @Flag(name: .shortAndLong, help: "覆盖已存在的文件")
    var overwrite: Bool = false
    
    @Option(name: .long, help: "质量预设: original, standard, minimal")
    var preset: String?
    
    func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        
        // 验证输入文件夹
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            print("\(Colors.red)❌ 错误: 输入文件夹不存在: \(input)\(Colors.reset)")
            throw ExitCode.failure
        }
        
        // 确定输出文件夹
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
        
        // 确定简化类型
        let simplifyType: SimplifyType
        if let preset = preset {
            switch preset.lowercased() {
            case "original":
                simplifyType = .original
            case "standard":
                simplifyType = .standard
            case "minimal":
                simplifyType = .minimal
            default:
                print("\(Colors.red)❌ 错误: 未知的预设类型: \(preset)\(Colors.reset)")
                throw ExitCode.failure
            }
        } else {
            simplifyType = .custom(options: SimplificationOptions(targetRatio: ratio))
        }
        
        print("\(Colors.cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(Colors.reset)")
        print("\(Colors.blue)🚀 批量处理 USDZ 文件\(Colors.reset)")
        print("\(Colors.cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(Colors.reset)")
        print("📂 输入文件夹: \(inputURL.path)")
        print("📤 输出文件夹: \(outputURL.path)")
        print("📊 简化比例: \(simplifyType.ratioValue * 100)%")
        print("")
        
        do {
            let result = try await ModelEntity.batchProcessFolderToCustomFolders(
                sourceFolder: inputURL,
                qualitiesAndFolderURLs: [(simplifyType, outputURL)],
                overwriteExisting: overwrite,
                progressCallback: { current, total, filename, type in
                    print("\(Colors.blue)⏳ [\(current)/\(total)] 处理: \(filename)\(Colors.reset)")
                }
            )
            
            print("")
            print("\(Colors.cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(Colors.reset)")
            print("\(Colors.green)✅ 批量处理完成！\(Colors.reset)")
            print("📊 总计: \(result.totalCount)")
            print("\(Colors.green)✅ 成功: \(result.successCount)\(Colors.reset)")
            print("\(Colors.red)❌ 失败: \(result.failureCount)\(Colors.reset)")
            print("📁 输出文件夹: \(outputURL.path)")
            
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

