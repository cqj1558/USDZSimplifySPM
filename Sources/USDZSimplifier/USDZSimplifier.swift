//
//  Common.swift
//  USDZSimplifyAndLoading
//
//  Created by J on 2025/12/13.
//
//  USDZSimplify
//
//  Created by J on 2025/12/8.
//

import Foundation
import RealityKit
import simd
import meshoptimizer
import Metal
import CoreImage
#if os(MacOS)
internal import AppKit
#endif

// MARK: - 简化参数配置

/// 网格简化参数配置
public struct SimplificationOptions: Hashable {
    
    // MARK: - 基础参数
    
    /// 目标索引比例（0~1，0.5表示保留50%的三角形）
    public var targetRatio: Float
    
    /// 误差阈值（0~1+，越小越严格，默认0.01=1%）
    public var errorThreshold: Float
    
    /// 最小面数保护（低于此面数不简化）
    public var minFaceCount: Int
    
    // MARK: - 高级参数
    
    /// 是否使用Sloppy模式（激进但快速的简化）
    public var useSloppy: Bool
    
    /// 是否锁定边界顶点（保护UV接缝，但限制简化程度）
    public var lockBorder: Bool
    
    /// 法线权重（0.0=忽略法线，1.0=完全保护法线）
    public var attributeWeight: Float
    
    /// 强制忽略所有属性，仅考虑位置（更激进）
    public var ignoreAttributes: Bool
    
    /// 启用Prune模式（移除断开的网格部分）
    public var enablePrune: Bool
    
    // MARK: - 初始化
    
    public init(
        targetRatio: Float = 0.5,
        errorThreshold: Float = 0.01,
        minFaceCount: Int = 200,
        useSloppy: Bool = false,
        lockBorder: Bool = true,
        attributeWeight: Float = 0.5,
        ignoreAttributes: Bool = false,
        enablePrune: Bool = false
    ) {
        self.targetRatio = targetRatio
        self.errorThreshold = errorThreshold
        self.minFaceCount = minFaceCount
        self.useSloppy = useSloppy
        self.lockBorder = lockBorder
        self.attributeWeight = attributeWeight
        self.ignoreAttributes = ignoreAttributes
        self.enablePrune = enablePrune
    }
}

// MARK: - 预设模式

extension SimplificationOptions {
    
    /// 📊 原始质量模式 - 不简化，仅缓存优化
    /// 用途：原始模型展示，完整保留所有细节
    public static var original: SimplificationOptions {
        SimplificationOptions(
            targetRatio: 1.0,           // 100%保留
            errorThreshold: 0.0,        // 无误差
            minFaceCount: 0,
            useSloppy: false,
            lockBorder: true,
            attributeWeight: 1.0,       // 完全保护法线
            ignoreAttributes: false,
            enablePrune: false
        )
    }
    
    /// 🎨 标准质量模式 - 30%保留，渲染优秀
    /// 用途：常规展示，平衡质量与性能
    public static var standard: SimplificationOptions {
        SimplificationOptions(
            targetRatio: 0.3,           // 30%保留
            errorThreshold: 0.01,       // 1%误差
            minFaceCount: 200,
            useSloppy: false,
            lockBorder: true,
            attributeWeight: 0.5,       // 适度保护法线
            ignoreAttributes: false,
            enablePrune: false
        )
    }
    
    /// ⚡ 极简模式 - 5%保留，极致性能
    /// 用途：列表预览、缩略图、VR/AR场景
    public static var minimal: SimplificationOptions {
        SimplificationOptions(
            targetRatio: 0.05,          // 5%保留
            errorThreshold: 0.3,        // 30%误差容忍
            minFaceCount: 100,
            useSloppy: true,            // 激进算法
            lockBorder: false,          // 不锁定边界
            attributeWeight: 0.0,       // 忽略法线
            ignoreAttributes: true,     // 只考虑位置
            enablePrune: true           // 移除断开部分
        )
    }
    
}

// MARK: - USDZ网格简化器

/// USDZ 网格减面工具（基于 meshoptimizer）

@MainActor final class USDZMeshSimplifier {
    
    @available(iOS 15.0, macOS 12.0, *)
    static func processEntity(_ entity: Entity, options: SimplificationOptions, processedCount: inout Int, simplifiedCount: inout Int) async throws {
        // 先递归处理所有子实体（深度优先遍历）
        for child in entity.children {
            try await processEntity(child, options: options, processedCount: &processedCount, simplifiedCount: &simplifiedCount)
        }
        
        // 然后处理当前实体
        if let modelEntity = entity as? ModelEntity,
           let model = modelEntity.model {
            processedCount += 1
           debugPrint("\n📦 处理网格 #\(processedCount): \(entity.name)")
            
            // 保存原始材质
            let originalMaterials = model.materials
            
            if let simplifiedMesh = try? await simplifyMeshResource(model.mesh, options: options) {
                // 创建新的 ModelComponent，保留原始材质
                var newModel = ModelComponent(
                    mesh: simplifiedMesh,
                    materials: originalMaterials  // 🔥 关键：保留原始材质
                )
                
                // 复制其他可能的属性
                modelEntity.model = newModel
                simplifiedCount += 1
               debugPrint("✅ 简化成功（已保留 \(originalMaterials.count) 个材质）")
            } else {
               debugPrint("⚪️ 保持原样")
            }
        }
    }
    
    @available(iOS 15.0, macOS 12.0, *)
    private static func simplifyMeshResource(_ mesh: MeshResource, options: SimplificationOptions) async throws -> MeshResource? {
        // 获取原始 contents（这应该是一个副本）
        let contents = mesh.contents
        
        // 检查结构
        guard !contents.models.isEmpty else { return nil }
        
        
        // 🔥 尝试修改 contents
        // 注意：这里需要测试是否可行
        
        // 方式 A：直接修改（如果支持）
        
        var newContents = MeshResource.Contents()
        newContents.instances = contents.instances//model的transform
        
        for modelIndex in contents.models.indices {
            let model = contents.models[modelIndex]
            
            var newParts:[MeshResource.Part] = .init()
            for partIndex in model.parts.indices {
                let part = model.parts[partIndex]
                
                // 获取原始数据
                let positions = [SIMD3<Float>](part.positions)
                guard let triangleIndices = part.triangleIndices else {
                   debugPrint("    ⚠️ Part #\(partIndex + 1) 没有三角形索引，跳过")
                    continue
                }
                let indices = [UInt32](triangleIndices)
                let normals = part.normals.map { [SIMD3<Float>]($0) }
                let textureCoordinates = part.textureCoordinates.map { [SIMD2<Float>]($0) }
                
                
                // 使用 meshoptimizer 完整优化
                let result = optimizeMeshWithMeshoptimizer(
                    positions: positions,
                    normals: normals,
                    textureCoordinates: textureCoordinates,
                    indices: indices,
                    options: options
                )
                
                // 创建新的 Part 并更新所有数据
                var newPart = part
                newPart.positions = MeshBuffers.Positions(result.positions)
                newPart.triangleIndices = MeshBuffers.TriangleIndices(result.indices)
                
                // 更新 normals（如果有）
                if let optimizedNormals = result.normals {
                    newPart.normals = MeshBuffers.Normals(optimizedNormals)
                }
                
                // 更新 textureCoordinates（如果有）
                if let optimizedTexCoords = result.textureCoordinates {
                    newPart.textureCoordinates = MeshBuffers.TextureCoordinates(optimizedTexCoords)
                }
                
                newParts.append(newPart)
            }
            
            var newModel = MeshResource.Model(id: model.id, parts: newParts)
            
            newContents.models.insert(newModel)
        }
        
        // ✅ 用修改后的 contents 重新生成
        return try MeshResource.generate(from: newContents)
    }
    
    
    static func changingPathExtension(of url: URL, to newExtension: String) -> URL {
        // 1. 将字符串转换为 URL 对象
        
        
        // 2. 去除原有的路径扩展名，然后添加新的扩展名
        let newURL = url.deletingPathExtension().appendingPathExtension(newExtension)
        
        // 3. 返回处理后的完整 URL 字符串
        return newURL
    }
    
    
    
   
    
    
    
    // MARK: - 优化结果结构体
    private struct OptimizationResult {
        let positions: [SIMD3<Float>]
        let normals: [SIMD3<Float>]?
        let textureCoordinates: [SIMD2<Float>]?
        let indices: [UInt32]
        let originalVertexCount: Int
        let optimizedVertexCount: Int
    }
    
    // MARK: - 使用 meshoptimizer 完整优化（减面 + 删除未使用顶点）
    
    private static func optimizeMeshWithMeshoptimizer(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>]?,
        textureCoordinates: [SIMD2<Float>]?,
                                        indices: [UInt32],
        options: SimplificationOptions
    ) -> OptimizationResult {
        let originalVertexCount = positions.count
        
        // 安全检查
        guard !positions.isEmpty, !indices.isEmpty else {
            return OptimizationResult(
                positions: positions,
                normals: normals,
                textureCoordinates: textureCoordinates,
                indices: indices,
                originalVertexCount: originalVertexCount,
                optimizedVertexCount: originalVertexCount
            )
        }
        
        if indices.count % 3 != 0 {
            return OptimizationResult(
                positions: positions,
                normals: normals,
                textureCoordinates: textureCoordinates,
                indices: indices,
                originalVertexCount: originalVertexCount,
                optimizedVertexCount: originalVertexCount
            )
        }
        
        let vertexCount = positions.count
        var currentVertexCount = vertexCount
        if currentVertexCount == 0 {
           debugPrint("    ⚠️ [meshopt] vertexCount = 0，直接返回原数据")
            return OptimizationResult(
                positions: positions,
                normals: normals,
                textureCoordinates: textureCoordinates,
                indices: indices,
                originalVertexCount: originalVertexCount,
                optimizedVertexCount: originalVertexCount
            )
        }
        
        // 转换 positions 为 flat array (meshoptimizer 需要连续的 float 数组)
        var flatPositions = [Float]()
        flatPositions.reserveCapacity(currentVertexCount * 3)
        for pos in positions {
            flatPositions.append(pos.x)
            flatPositions.append(pos.y)
            flatPositions.append(pos.z)
        }
        
        // 工作变量（会在优化过程中更新）
        var workingIndices = indices
        var workingPositions = positions
        var workingNormals = normals
        var workingTexCoords = textureCoordinates
        
        // ================================================================
        // 步骤0: 顶点去重 (meshopt_generateVertexRemap)
        // ================================================================
        
//        debugPrint("\n    🔄 [步骤0-顶点去重] 开始分析...")
//        
//        var remap = [UInt32](repeating: 0, count: currentVertexCount)
//        let uniqueVertexCount = meshopt_generateVertexRemap(
//            &remap,
//            workingIndices,
//            workingIndices.count,
//            flatPositions,
//            currentVertexCount,
//            MemoryLayout<Float>.stride * 3
//        )
//        
//        let duplicateCount = currentVertexCount - uniqueVertexCount
//        let duplicatePercent = Float(duplicateCount) / Float(currentVertexCount) * 100
//        let memorySaved = Float(duplicateCount * (MemoryLayout<SIMD3<Float>>.stride + 
//                                                   (normals != nil ? MemoryLayout<SIMD3<Float>>.stride : 0) + 
//                                                   (textureCoordinates != nil ? MemoryLayout<SIMD2<Float>>.stride : 0))) / 1024.0
//
        // 只有发现重复顶点时才执行去重操作
//        if uniqueVertexCount < currentVertexCount {
//            
//            // 应用重映射到索引
//            var remappedIndices = workingIndices
//            meshopt_remapIndexBuffer(
//                &remappedIndices,
//                workingIndices,
//                workingIndices.count,
//                remap
//            )
//            
//            // 应用重映射到顶点位置
//            var remappedFlatPositions = flatPositions
//            meshopt_remapVertexBuffer(
//                &remappedFlatPositions,
//                flatPositions,
//                currentVertexCount,
//                MemoryLayout<Float>.stride * 3,
//                remap
//            )
//            
//            // 重建 positions
//            var newPositions: [SIMD3<Float>] = []
//            newPositions.reserveCapacity(uniqueVertexCount)
//            for i in 0..<uniqueVertexCount {
//                let idx = i * 3
//                newPositions.append(SIMD3<Float>(
//                    remappedFlatPositions[idx],
//                    remappedFlatPositions[idx + 1],
//                    remappedFlatPositions[idx + 2]
//                ))
//            }
//            
//            // 处理 normals
//            var newNormals: [SIMD3<Float>]? = nil
//            if let sourceNormals = workingNormals, sourceNormals.count == currentVertexCount {
//                var flatNormals = [Float]()
//                flatNormals.reserveCapacity(currentVertexCount * 3)
//                for norm in sourceNormals {
//                    flatNormals.append(norm.x)
//                    flatNormals.append(norm.y)
//                    flatNormals.append(norm.z)
//                }
//                
//                var remappedFlatNormals = flatNormals
//                meshopt_remapVertexBuffer(
//                    &remappedFlatNormals,
//                    flatNormals,
//                    currentVertexCount,
//                    MemoryLayout<Float>.stride * 3,
//                    remap
//                )
//                
//                var rebuiltNormals: [SIMD3<Float>] = []
//                rebuiltNormals.reserveCapacity(uniqueVertexCount)
//                for i in 0..<uniqueVertexCount {
//                    let idx = i * 3
//                    rebuiltNormals.append(SIMD3<Float>(
//                        remappedFlatNormals[idx],
//                        remappedFlatNormals[idx + 1],
//                        remappedFlatNormals[idx + 2]
//                    ))
//                }
//                newNormals = rebuiltNormals
//            }
//            
//            // 处理 textureCoordinates
//            var newTexCoords: [SIMD2<Float>]? = nil
//            if let sourceTexCoords = workingTexCoords, sourceTexCoords.count == currentVertexCount {
//                var flatTexCoords = [Float]()
//                flatTexCoords.reserveCapacity(currentVertexCount * 2)
//                for uv in sourceTexCoords {
//                    flatTexCoords.append(uv.x)
//                    flatTexCoords.append(uv.y)
//                }
//                
//                var remappedFlatTexCoords = flatTexCoords
//                meshopt_remapVertexBuffer(
//                    &remappedFlatTexCoords,
//                    flatTexCoords,
//                    currentVertexCount,
//                    MemoryLayout<Float>.stride * 2,
//                    remap
//                )
//                
//                var rebuiltTexCoords: [SIMD2<Float>] = []
//                rebuiltTexCoords.reserveCapacity(uniqueVertexCount)
//                for i in 0..<uniqueVertexCount {
//                    let idx = i * 2
//                    rebuiltTexCoords.append(SIMD2<Float>(
//                        remappedFlatTexCoords[idx],
//                        remappedFlatTexCoords[idx + 1]
//                    ))
//                }
//                newTexCoords = rebuiltTexCoords
//            }
//            
//            // 更新工作数据
//            workingIndices = remappedIndices
//            workingPositions = newPositions
//            workingNormals = newNormals
//            workingTexCoords = newTexCoords
//            currentVertexCount = uniqueVertexCount
//            flatPositions = Array(remappedFlatPositions.prefix(uniqueVertexCount * 3))
//
//        } else {
//        }
        
        // 计算原始面数和目标面数
        let originalFaceCount = workingIndices.count / 3
        let rawTarget = Int(Float(workingIndices.count) * options.targetRatio)
        var targetIndexCount = max(3, (rawTarget / 3) * 3)
        var targetFaceCount = targetIndexCount / 3
        
        // 🆕 最小面数保护逻辑
        if targetFaceCount <= options.minFaceCount {
            // 计算阈值倍数（默认1.5倍）
            let minFaceThreshold = Int(Float(options.minFaceCount) * 1.5)
            
            if originalFaceCount > minFaceThreshold {                targetFaceCount = options.minFaceCount
                targetIndexCount = options.minFaceCount * 3
                // 继续简化
            } else {
                return OptimizationResult(
                    positions: workingPositions,
                    normals: workingNormals,
                    textureCoordinates: workingTexCoords,
                    indices: workingIndices,
                    originalVertexCount: originalVertexCount,
                    optimizedVertexCount: currentVertexCount
                )
            }
        }
        
        if targetIndexCount >= workingIndices.count {
            return OptimizationResult(
                positions: workingPositions,
                normals: workingNormals,
                textureCoordinates: workingTexCoords,
                indices: workingIndices,
                originalVertexCount: originalVertexCount,
                optimizedVertexCount: currentVertexCount
            )
        }
        
        var simplifiedIndices = workingIndices
        let simplifiedIndexCount: Int
        
        // 🆕 构建动态选项标志
        var simplifyOptions: UInt32 = 0
        if options.lockBorder {
            simplifyOptions |= 1  // meshopt_SimplifyLockBorder
        }
        if options.enablePrune {
            simplifyOptions |= 8  // meshopt_SimplifyPrune
        }
        
        if options.useSloppy {
            
            simplifiedIndexCount = meshopt_simplifySloppy(
                &simplifiedIndices,
                workingIndices,
                workingIndices.count,
                flatPositions,
                currentVertexCount,
                MemoryLayout<Float>.stride * 3,
                targetIndexCount,
                options.errorThreshold,
                nil  // result_error
            )
        } else if options.ignoreAttributes || workingNormals == nil {
            
            simplifiedIndexCount = meshopt_simplify(
                &simplifiedIndices,
                workingIndices,
                workingIndices.count,
                flatPositions,
                currentVertexCount,
                MemoryLayout<Float>.stride * 3,
                targetIndexCount,
                options.errorThreshold,
                simplifyOptions,
                nil
            )
        } else if let sourceNormals = workingNormals {
            
            // 准备法线数据
            var flatNormals: [Float] = []
            flatNormals.reserveCapacity(currentVertexCount * 3)
            for normal in sourceNormals {
                flatNormals.append(normal.x)
                flatNormals.append(normal.y)
                flatNormals.append(normal.z)
            }
            
            // 🆕 使用配置的法线权重
            var attributeWeights: [Float] = [
                options.attributeWeight,
                options.attributeWeight,
                options.attributeWeight
            ]
            
            simplifiedIndexCount = meshopt_simplifyWithAttributes(
                &simplifiedIndices,           // 输出索引
                workingIndices,               // 输入索引
                workingIndices.count,         // 索引数量
                flatPositions,                // 顶点位置
                currentVertexCount,           // 顶点数量
                MemoryLayout<Float>.stride * 3,  // 位置步长（3个float）
                flatNormals,                  // 顶点法线（属性）
                MemoryLayout<Float>.stride * 3,  // 法线步长（3个float）
                &attributeWeights,            // 属性权重
                3,                            // 属性数量（nx, ny, nz）
                nil,                          // 顶点锁定（暂不使用）
                targetIndexCount,             // 目标索引数
                options.errorThreshold,       // 错误阈值
                simplifyOptions,              // 选项标志
                nil                           // 输出错误（暂不需要）
            )
        } else {
            // 降级处理
            debugPrint("       ⚠️ 未知情况，使用 meshopt_simplify")
            
            simplifiedIndexCount = meshopt_simplify(
                &simplifiedIndices,
                workingIndices,
                workingIndices.count,
                flatPositions,
                currentVertexCount,
                MemoryLayout<Float>.stride * 3,
                targetIndexCount,
                options.errorThreshold,
                simplifyOptions,
                nil
            )
        }
        
        guard simplifiedIndexCount > 0 else {
            return OptimizationResult(
                positions: workingPositions,
                normals: workingNormals,
                textureCoordinates: workingTexCoords,
                indices: workingIndices,
                originalVertexCount: originalVertexCount,
                optimizedVertexCount: currentVertexCount
            )
        }
        
        simplifiedIndices = Array(simplifiedIndices.prefix(simplifiedIndexCount))
        let reductionPercent = (1.0 - Float(simplifiedIndexCount)/Float(workingIndices.count)) * 100
        
        
        // 优化前分析
        let cacheStatsBefore = meshopt_analyzeVertexCache(
            simplifiedIndices,
            simplifiedIndices.count,
            currentVertexCount,
            32, 0, 0
        )
        
        var cacheOptimizedIndices = simplifiedIndices
        
        var cacheStatsAfter = cacheStatsBefore
        if cacheStatsBefore.acmr > 1.5{
            meshopt_optimizeVertexCache(
                &cacheOptimizedIndices,
                cacheOptimizedIndices,
                cacheOptimizedIndices.count,
                currentVertexCount
            )
            // 优化后分析
            cacheStatsAfter = meshopt_analyzeVertexCache(
                cacheOptimizedIndices,
                cacheOptimizedIndices.count,
                currentVertexCount,
                32, 0, 0
            )
        }
        
        
        let acmrImprovement = (1.0 - cacheStatsAfter.acmr / cacheStatsBefore.acmr) * 100
        
        
        // 优化前分析
        let overdrawStatsBefore = meshopt_analyzeOverdraw(
            cacheOptimizedIndices,
            cacheOptimizedIndices.count,
            flatPositions,
            currentVertexCount,
            MemoryLayout<Float>.stride * 3
        )
        
        
        var overdrawOptimizedIndices = cacheOptimizedIndices
        if overdrawStatsBefore.overdraw > 1.5{
            meshopt_optimizeOverdraw(
                &overdrawOptimizedIndices,
                overdrawOptimizedIndices,
                overdrawOptimizedIndices.count,
                flatPositions,
                currentVertexCount,
                MemoryLayout<Float>.stride * 3,
                1.05  // threshold: 允许5%的缓存效率损失来换取更好的overdraw
            )
            
            // 优化后分析
            let overdrawStatsAfter = meshopt_analyzeOverdraw(
                overdrawOptimizedIndices,
                overdrawOptimizedIndices.count,
                flatPositions,
                currentVertexCount,
                MemoryLayout<Float>.stride * 3
            )
            
            // 验证缓存效率没有显著下降
            let cacheStatsAfterOverdraw = meshopt_analyzeVertexCache(
                overdrawOptimizedIndices,
                overdrawOptimizedIndices.count,
                currentVertexCount,
                32, 0, 0
            )
            
            let overdrawImprovement = (1.0 - overdrawStatsAfter.overdraw / overdrawStatsBefore.overdraw) * 100
            let cacheDegradation = (cacheStatsAfterOverdraw.acmr / cacheStatsAfter.acmr - 1.0) * 100
            
        }
        else{
            
        }
        
        
        // 3.1 优化 positions
        var optimizedFlatPositions = flatPositions
        var finalIndices = overdrawOptimizedIndices  // 使用 overdraw 优化后的索引
        
        let optimizedVertexCount = meshopt_optimizeVertexFetch(
            &optimizedFlatPositions,
            &finalIndices,
            finalIndices.count,
            flatPositions,
            currentVertexCount,
            MemoryLayout<Float>.stride * 3
        )
        
        let vertexReduction = (1.0 - Float(optimizedVertexCount)/Float(currentVertexCount)) * 100
        
        // 3.2 重建 SIMD3<Float> positions
        var optimizedPositions: [SIMD3<Float>] = []
        optimizedPositions.reserveCapacity(optimizedVertexCount)
        for i in 0..<optimizedVertexCount {
            let idx = i * 3
            optimizedPositions.append(SIMD3<Float>(
                optimizedFlatPositions[idx],
                optimizedFlatPositions[idx + 1],
                optimizedFlatPositions[idx + 2]
            ))
        }
        
        // 3.3 优化其他顶点属性（normals 和 textureCoordinates）
        var optimizedNormals: [SIMD3<Float>]?
        var optimizedTexCoords: [SIMD2<Float>]?
        
        if let sourceNormals = workingNormals, sourceNormals.count == currentVertexCount {
            // 转换为 flat array
            var flatNormals = [Float]()
            flatNormals.reserveCapacity(currentVertexCount * 3)
            for norm in sourceNormals {
                flatNormals.append(norm.x)
                flatNormals.append(norm.y)
                flatNormals.append(norm.z)
            }
            
            // 使用相同的索引优化 normals
            var tempIndices = overdrawOptimizedIndices
            let _ = meshopt_optimizeVertexFetch(
                &flatNormals,
                &tempIndices,
                tempIndices.count,
                flatNormals,
                currentVertexCount,
                MemoryLayout<Float>.stride * 3
            )
            
            // 重建 SIMD3<Float> normals
            var newNormals: [SIMD3<Float>] = []
            newNormals.reserveCapacity(optimizedVertexCount)
            for i in 0..<optimizedVertexCount {
                let idx = i * 3
                newNormals.append(SIMD3<Float>(
                    flatNormals[idx],
                    flatNormals[idx + 1],
                    flatNormals[idx + 2]
                ))
            }
            optimizedNormals = newNormals
        }
        
        if let sourceTexCoords = workingTexCoords, sourceTexCoords.count == currentVertexCount {
            // 转换为 flat array
            var flatTexCoords = [Float]()
            flatTexCoords.reserveCapacity(currentVertexCount * 2)
            for uv in sourceTexCoords {
                flatTexCoords.append(uv.x)
                flatTexCoords.append(uv.y)
            }
            
            // 使用相同的索引优化 textureCoordinates
            var tempIndices = overdrawOptimizedIndices
            let _ = meshopt_optimizeVertexFetch(
                &flatTexCoords,
                &tempIndices,
                tempIndices.count,
                flatTexCoords,
                currentVertexCount,
                MemoryLayout<Float>.stride * 2
            )
            
            // 重建 SIMD2<Float> textureCoordinates
            var newTexCoords: [SIMD2<Float>] = []
            newTexCoords.reserveCapacity(optimizedVertexCount)
            for i in 0..<optimizedVertexCount {
                let idx = i * 2
                newTexCoords.append(SIMD2<Float>(
                    flatTexCoords[idx],
                    flatTexCoords[idx + 1]
                ))
            }
            optimizedTexCoords = newTexCoords
        }
        
        
        let totalVertexReduction = (1.0 - Float(optimizedVertexCount) / Float(originalVertexCount)) * 100
        let totalIndexReduction = (1.0 - Float(finalIndices.count) / Float(indices.count)) * 100
        let estimatedMemorySaved = Float((originalVertexCount - optimizedVertexCount) * (MemoryLayout<SIMD3<Float>>.stride + 
                                         (normals != nil ? MemoryLayout<SIMD3<Float>>.stride : 0) + 
                                         (textureCoordinates != nil ? MemoryLayout<SIMD2<Float>>.stride : 0)) +
                                         (indices.count - finalIndices.count) * MemoryLayout<UInt32>.stride) / 1024.0
        
        
        return OptimizationResult(
            positions: optimizedPositions,
            normals: optimizedNormals,
            textureCoordinates: optimizedTexCoords,
            indices: finalIndices,
            originalVertexCount: originalVertexCount,
            optimizedVertexCount: optimizedVertexCount
        )
    }
    
    // MARK: - 纹理信息检测
    
    /// 获取纹理格式的可读描述
    private static func formatDescription(_ texture: TextureResource) -> String {
        // 直接使用 TextureResource 的 pixelFormat 属性
        return formatFromPixelFormat(texture.pixelFormat)
    }
    
    /// 将 MTLPixelFormat 转换为可读字符串
    private static func formatFromPixelFormat(_ pixelFormat: MTLPixelFormat) -> String {
        switch pixelFormat {
        // 常见未压缩格式
        case .rgba8Unorm:
            return "RGBA8"
        case .rgba8Unorm_srgb:
            return "RGBA8_sRGB"
        case .rgba8Snorm:
            return "RGBA8_Snorm"
        case .rgba8Uint:
            return "RGBA8_Uint"
        case .rgba8Sint:
            return "RGBA8_Sint"
            
        case .bgra8Unorm:
            return "BGRA8"
        case .bgra8Unorm_srgb:
            return "BGRA8_sRGB"
            
        case .rgba16Float:
            return "RGBA16_Float"
        case .rgba16Unorm:
            return "RGBA16"
        case .rgba16Snorm:
            return "RGBA16_Snorm"
        case .rgba16Uint:
            return "RGBA16_Uint"
        case .rgba16Sint:
            return "RGBA16_Sint"
            
        case .rgba32Float:
            return "RGBA32_Float"
        case .rgba32Uint:
            return "RGBA32_Uint"
        case .rgba32Sint:
            return "RGBA32_Sint"
            
        // 单通道格式
        case .r8Unorm:
            return "R8"
        case .r8Snorm:
            return "R8_Snorm"
        case .r8Uint:
            return "R8_Uint"
        case .r8Sint:
            return "R8_Sint"
        case .r16Float:
            return "R16_Float"
        case .r16Unorm:
            return "R16"
        case .r32Float:
            return "R32_Float"
            
        // 双通道格式
        case .rg8Unorm:
            return "RG8"
        case .rg8Snorm:
            return "RG8_Snorm"
        case .rg16Float:
            return "RG16_Float"
        case .rg16Unorm:
            return "RG16"
        case .rg32Float:
            return "RG32_Float"
            
        // ASTC 压缩格式（iOS 推荐）
        case .astc_4x4_ldr:
            return "ASTC_4×4_LDR"
        case .astc_4x4_srgb:
            return "ASTC_4×4_sRGB"
        case .astc_4x4_hdr:
            return "ASTC_4×4_HDR"
            
        case .astc_5x4_ldr:
            return "ASTC_5×4_LDR"
        case .astc_5x4_srgb:
            return "ASTC_5×4_sRGB"
        case .astc_5x4_hdr:
            return "ASTC_5×4_HDR"
            
        case .astc_5x5_ldr:
            return "ASTC_5×5_LDR"
        case .astc_5x5_srgb:
            return "ASTC_5×5_sRGB"
        case .astc_5x5_hdr:
            return "ASTC_5×5_HDR"
            
        case .astc_6x5_ldr:
            return "ASTC_6×5_LDR"
        case .astc_6x5_srgb:
            return "ASTC_6×5_sRGB"
        case .astc_6x5_hdr:
            return "ASTC_6×5_HDR"
            
        case .astc_6x6_ldr:
            return "ASTC_6×6_LDR"
        case .astc_6x6_srgb:
            return "ASTC_6×6_sRGB"
        case .astc_6x6_hdr:
            return "ASTC_6×6_HDR"
            
        case .astc_8x5_ldr:
            return "ASTC_8×5_LDR"
        case .astc_8x5_srgb:
            return "ASTC_8×5_sRGB"
        case .astc_8x5_hdr:
            return "ASTC_8×5_HDR"
            
        case .astc_8x6_ldr:
            return "ASTC_8×6_LDR"
        case .astc_8x6_srgb:
            return "ASTC_8×6_sRGB"
        case .astc_8x6_hdr:
            return "ASTC_8×6_HDR"
            
        case .astc_8x8_ldr:
            return "ASTC_8×8_LDR"
        case .astc_8x8_srgb:
            return "ASTC_8×8_sRGB"
        case .astc_8x8_hdr:
            return "ASTC_8×8_HDR"
            
        case .astc_10x5_ldr:
            return "ASTC_10×5_LDR"
        case .astc_10x5_srgb:
            return "ASTC_10×5_sRGB"
        case .astc_10x5_hdr:
            return "ASTC_10×5_HDR"
            
        case .astc_10x6_ldr:
            return "ASTC_10×6_LDR"
        case .astc_10x6_srgb:
            return "ASTC_10×6_sRGB"
        case .astc_10x6_hdr:
            return "ASTC_10×6_HDR"
            
        case .astc_10x8_ldr:
            return "ASTC_10×8_LDR"
        case .astc_10x8_srgb:
            return "ASTC_10×8_sRGB"
        case .astc_10x8_hdr:
            return "ASTC_10×8_HDR"
            
        case .astc_10x10_ldr:
            return "ASTC_10×10_LDR"
        case .astc_10x10_srgb:
            return "ASTC_10×10_sRGB"
        case .astc_10x10_hdr:
            return "ASTC_10×10_HDR"
            
        case .astc_12x10_ldr:
            return "ASTC_12×10_LDR"
        case .astc_12x10_srgb:
            return "ASTC_12×10_sRGB"
        case .astc_12x10_hdr:
            return "ASTC_12×10_HDR"
            
        case .astc_12x12_ldr:
            return "ASTC_12×12_LDR"
        case .astc_12x12_srgb:
            return "ASTC_12×12_sRGB"
        case .astc_12x12_hdr:
            return "ASTC_12×12_HDR"
            
        // BC 压缩格式（主要用于 macOS）
        case .bc1_rgba:
            return "BC1"
        case .bc1_rgba_srgb:
            return "BC1_sRGB"
        case .bc2_rgba:
            return "BC2"
        case .bc2_rgba_srgb:
            return "BC2_sRGB"
        case .bc3_rgba:
            return "BC3"
        case .bc3_rgba_srgb:
            return "BC3_sRGB"
        case .bc4_rUnorm:
            return "BC4_R"
        case .bc4_rSnorm:
            return "BC4_R_Snorm"
        case .bc5_rgUnorm:
            return "BC5_RG"
        case .bc5_rgSnorm:
            return "BC5_RG_Snorm"
        case .bc6H_rgbFloat:
            return "BC6H_Float"
        case .bc6H_rgbuFloat:
            return "BC6H_UFloat"
        case .bc7_rgbaUnorm:
            return "BC7"
        case .bc7_rgbaUnorm_srgb:
            return "BC7_sRGB"
            
        // ETC2/EAC 压缩格式（iOS 支持）
        case .etc2_rgb8:
            return "ETC2_RGB8"
        case .etc2_rgb8_srgb:
            return "ETC2_RGB8_sRGB"
        case .etc2_rgb8a1:
            return "ETC2_RGB8A1"
        case .etc2_rgb8a1_srgb:
            return "ETC2_RGB8A1_sRGB"
        case .eac_r11Unorm:
            return "EAC_R11"
        case .eac_r11Snorm:
            return "EAC_R11_Snorm"
        case .eac_rg11Unorm:
            return "EAC_RG11"
        case .eac_rg11Snorm:
            return "EAC_RG11_Snorm"
        case .eac_rgba8:
            return "EAC_RGBA8"
        case .eac_rgba8_srgb:
            return "EAC_RGBA8_sRGB"
            
        // 特殊格式
        case .rgb10a2Unorm:
            return "RGB10A2"
        case .rg11b10Float:
            return "RG11B10_Float"
        case .rgb9e5Float:
            return "RGB9E5_Float"
            
        case .invalid:
            return "Invalid"
            
        default:
            return "Unknown(\(pixelFormat.rawValue))"
        }
    }
    
    /// 检测并输出模型的纹理信息
    static func detectTextureInfo(_ entity: Entity) {
        
        
        var textureStats = TextureStatistics()
        detectTextureRecursive(entity, stats: &textureStats)
        
        if !textureStats.resolutionCounts.isEmpty {
            let sortedResolutions = textureStats.resolutionCounts.sorted { $0.key > $1.key }
            for (resolution, count) in sortedResolutions {
            }
        }
        
    }
    
    /// 递归检测纹理信息
    private static func detectTextureRecursive(_ entity: Entity, stats: inout TextureStatistics) {
        // 检查当前实体
        if let modelEntity = entity as? ModelEntity,
           let modelComponent = modelEntity.components[ModelComponent.self] {
            
            stats.entityCount += 1
            
            for (materialIndex, material) in modelComponent.materials.enumerated() {
                stats.materialCount += 1
                
                if let pbr = material as? PhysicallyBasedMaterial {
                    
                    
                    // BaseColor 纹理
                    if let texture = pbr.baseColor.texture?.resource {
                        let resolution = max(texture.width, texture.height)
                        let format = formatDescription(texture)
                        stats.addTexture(resolution: resolution, type: .baseColor, format: format)
                    }
                    
                    // Normal 纹理
                    if let texture = pbr.normal.texture?.resource {
                        let resolution = max(texture.width, texture.height)
                        let format = formatDescription(texture)
                        stats.addTexture(resolution: resolution, type: .normal, format: format)
                    }
                    
                    // Metallic 纹理
                    if let texture = pbr.metallic.texture?.resource {
                        let resolution = max(texture.width, texture.height)
                        let format = formatDescription(texture)
                        stats.addTexture(resolution: resolution, type: .metallic, format: format)
                    }
                    
                    // Roughness 纹理
                    if let texture = pbr.roughness.texture?.resource {
                        let resolution = max(texture.width, texture.height)
                        let format = formatDescription(texture)
                        stats.addTexture(resolution: resolution, type: .roughness, format: format)
                    }
                    
                    // Ambient Occlusion 纹理
                    if let texture = pbr.ambientOcclusion.texture?.resource {
                        let resolution = max(texture.width, texture.height)
                        let format = formatDescription(texture)
                        stats.addTexture(resolution: resolution, type: .ao, format: format)
                    }
                    
                    // Emissive 纹理
                    if let texture = pbr.emissiveColor.texture?.resource {
                        let resolution = max(texture.width, texture.height)
                        let format = formatDescription(texture)
                        stats.addTexture(resolution: resolution, type: .emissive, format: format)
                    }
                }
            }
        }
        
        // 递归检查子实体
        for child in entity.children {
            detectTextureRecursive(child, stats: &stats)
        }
    }
    
    /// 纹理类型
    private enum TextureType {
        case baseColor
        case normal
        case metallic
        case roughness
        case ao
        case emissive
        case specular
        case opacity
        case clearcoat
        case clearcoatRoughness
        case clearcoatNormal
        case anisotropyLevel
        case anisotropyAngle
        case sheenColor
        
        var displayName: String {
            switch self {
            case .baseColor: return "BaseColor"
            case .normal: return "Normal"
            case .metallic: return "Metallic"
            case .roughness: return "Roughness"
            case .ao: return "AO"
            case .emissive: return "Emissive"
            case .specular: return "Specular"
            case .opacity: return "Opacity"
            case .clearcoat: return "Clearcoat"
            case .clearcoatRoughness: return "ClearcoatRoughness"
            case .clearcoatNormal: return "ClearcoatNormal"
            case .anisotropyLevel: return "AnisotropyLevel"
            case .anisotropyAngle: return "AnisotropyAngle"
            case .sheenColor: return "SheenColor"
            }
        }
    }
    
    /// 纹理统计信息
    private struct TextureStatistics {
        var entityCount = 0
        var materialCount = 0
        var totalTextures = 0
        var maxResolution = 0
        var minResolution = Int.max
        var totalResolution = 0
        var resolutionCounts: [Int: Int] = [:]
        var textureTypes: Set<TextureType> = []
        var formatCounts: [String: Int] = [:]  // 格式统计
        
        var averageResolution: Int {
            guard totalTextures > 0 else { return 0 }
            return totalResolution / totalTextures
        }
        
        mutating func addTexture(resolution: Int, type: TextureType, format: String? = nil) {
            totalTextures += 1
            maxResolution = max(maxResolution, resolution)
            minResolution = min(minResolution, resolution)
            totalResolution += resolution
            resolutionCounts[resolution, default: 0] += 1
            textureTypes.insert(type)
            
            if let format = format {
                formatCounts[format, default: 0] += 1
            }
        }
    }
    
    // MARK: - 纹理优化
    
    /// 优化实体树中的所有纹理
    static func optimizeTextures(_ entity: Entity, simplifyRatio: Float) async {
        if simplifyRatio > 0.9{
            return
        }
        
        
        var optimizedCount = 0
        var skippedCount = 0
        var failedCount = 0
        await optimizeTexturesRecursive(entity, simplifyRatio: simplifyRatio, optimizedCount: &optimizedCount, skippedCount: &skippedCount, failedCount: &failedCount)
        
    }
    
    /// 递归优化纹理
    private static func optimizeTexturesRecursive(
        _ entity: Entity,
        simplifyRatio: Float,
        optimizedCount: inout Int,
        skippedCount: inout Int,
        failedCount: inout Int
    ) async {
        // 处理当前实体
        if let modelEntity = entity as? ModelEntity,
           var modelComponent = modelEntity.components[ModelComponent.self] {
            
            var newMaterials: [Material] = []
            
            for (index, material) in modelComponent.materials.enumerated() {
                if var pbr1 = material as? PhysicallyBasedMaterial {
                    
                    // 优化 BaseColor
                    let baseColor = pbr1.baseColor
                    let optimizeBaseColor = await optimizeBaseColorTexture(
                        pbr1.baseColor,
                        simplifyRatio: simplifyRatio,
                        optimizedCount: &optimizedCount,
                        skippedCount: &skippedCount,
                        failedCount: &failedCount
                    )
                    
                    // 优化 Normal
                    let normal = pbr1.normal
                    let optimizeNormal = await optimizeNormalTexture(
                        pbr1.normal,
                        simplifyRatio: simplifyRatio,
                        optimizedCount: &optimizedCount,
                        skippedCount: &skippedCount,
                        failedCount: &failedCount
                    )
                    
                    // 优化 Metallic
                    let metallic = pbr1.metallic
                    let optimizeMetallic = await optimizeMetallicTexture(
                        pbr1.metallic,
                        simplifyRatio: simplifyRatio,
                        optimizedCount: &optimizedCount,
                        skippedCount: &skippedCount,
                        failedCount: &failedCount
                    )
                    
                    // 优化 Roughness
                    let roughness = pbr1.roughness
                    let optimizeRoughness = await optimizeRoughnessTexture(
                        pbr1.roughness,
                        simplifyRatio: simplifyRatio,
                        optimizedCount: &optimizedCount,
                        skippedCount: &skippedCount,
                        failedCount: &failedCount
                    )
                    
                    // 优化 AmbientOcclusion
                    let ambientOcclusion = pbr1.ambientOcclusion
                    let optimizeAmbientOcclusion = await optimizeAOTexture(
                        pbr1.ambientOcclusion,
                        simplifyRatio: simplifyRatio,
                        optimizedCount: &optimizedCount,
                        skippedCount: &skippedCount,
                        failedCount: &failedCount
                    )
                    
                    // 优化 EmissiveColor
                    let emissiveColor = pbr1.emissiveColor
                    let optimizeEmissiveColor = await optimizeEmissiveTexture(
                        pbr1.emissiveColor,
                        simplifyRatio: simplifyRatio,
                        optimizedCount: &optimizedCount,
                        skippedCount: &skippedCount,
                        failedCount: &failedCount
                    )
                    
                    // 优化 Specular
                    let specular = pbr1.specular
                    let optimizeSpecular = await optimizeSpecularTexture(
                        pbr1.specular,
                        simplifyRatio: simplifyRatio,
                        optimizedCount: &optimizedCount,
                        skippedCount: &skippedCount,
                        failedCount: &failedCount
                    )
                    
                    // 优化 Blending（包含 Opacity）
                    let optimizeBlending: PhysicallyBasedMaterial.Blending
                    switch pbr1.blending {
                    case .transparent(let opacity):
                        let optimizedOpacity = await optimizeOpacityTexture(
                            opacity,
                            simplifyRatio: simplifyRatio,
                            optimizedCount: &optimizedCount,
                            skippedCount: &skippedCount,
                            failedCount: &failedCount
                        )
                        optimizeBlending = .transparent(opacity: optimizedOpacity)
                    case .opaque:
                        optimizeBlending = .opaque
                    @unknown default:
                        optimizeBlending = .opaque
                    }
                    
                    // 优化 Clearcoat
                    let clearcoat = pbr1.clearcoat
                    let optimizeClearcoat = await optimizeClearcoatTexture(
                        pbr1.clearcoat,
                        simplifyRatio: simplifyRatio,
                        optimizedCount: &optimizedCount,
                        skippedCount: &skippedCount,
                        failedCount: &failedCount
                    )
                    
                    // 优化 ClearcoatRoughness
                    let clearcoatRoughness = pbr1.clearcoatRoughness
                    let optimizeClearcoatRoughness = await optimizeClearcoatRoughnessTexture(
                        pbr1.clearcoatRoughness,
                        simplifyRatio: simplifyRatio,
                        optimizedCount: &optimizedCount,
                        skippedCount: &skippedCount,
                        failedCount: &failedCount
                    )
                    
                    // 优化 ClearcoatNormal
                    let clearcoatNormal = pbr1.clearcoatNormal
                    let optimizeClearcoatNormal = await optimizeClearcoatNormalTexture(
                        pbr1.clearcoatNormal,
                        simplifyRatio: simplifyRatio,
                        optimizedCount: &optimizedCount,
                        skippedCount: &skippedCount,
                        failedCount: &failedCount
                    )
                    
                    // 优化 AnisotropyLevel
                    let anisotropyLevel = pbr1.anisotropyLevel
                    let optimizeAnisotropyLevel = await optimizeAnisotropyLevelTexture(
                        pbr1.anisotropyLevel,
                        simplifyRatio: simplifyRatio,
                        optimizedCount: &optimizedCount,
                        skippedCount: &skippedCount,
                        failedCount: &failedCount
                    )
                    
                    // 优化 AnisotropyAngle
                    let anisotropyAngle = pbr1.anisotropyAngle
                    let optimizeAnisotropyAngle = await optimizeAnisotropyAngleTexture(
                        pbr1.anisotropyAngle,
                        simplifyRatio: simplifyRatio,
                        optimizedCount: &optimizedCount,
                        skippedCount: &skippedCount,
                        failedCount: &failedCount
                    )
                    
                    // 优化 Sheen
                    let sheen = pbr1.sheen
                    let optimizeSheen = await optimizeSheenTexture(
                        pbr1.sheen,
                        simplifyRatio: simplifyRatio,
                        optimizedCount: &optimizedCount,
                        skippedCount: &skippedCount,
                        failedCount: &failedCount
                    )
                    
                    // 创建新材质 pbr2（优化版本，用于对照）
                    var pbr2 = PhysicallyBasedMaterial()
                    pbr2.baseColor = optimizeBaseColor
                    pbr2.normal = optimizeNormal
                    pbr2.metallic = optimizeMetallic
                    pbr2.roughness = optimizeRoughness
                    pbr2.ambientOcclusion = optimizeAmbientOcclusion
                    pbr2.emissiveColor = optimizeEmissiveColor
                    pbr2.specular = optimizeSpecular
                    pbr2.blending = optimizeBlending  // blending 包含了优化后的 opacity
                    pbr2.clearcoat = optimizeClearcoat
                    pbr2.clearcoatRoughness = optimizeClearcoatRoughness
                    pbr2.clearcoatNormal = optimizeClearcoatNormal
                    pbr2.anisotropyLevel = optimizeAnisotropyLevel
                    pbr2.anisotropyAngle = optimizeAnisotropyAngle
                    pbr2.sheen = optimizeSheen
                    
                    // 复制其他非纹理属性
                    pbr2.opacityThreshold = pbr1.opacityThreshold
                    pbr2.faceCulling = pbr1.faceCulling
                    pbr2.textureCoordinateTransform = pbr1.textureCoordinateTransform
                    
                    // 同时将优化后的纹理赋值给 pbr1（原材质修改）
                    pbr1.baseColor = optimizeBaseColor
                    pbr1.normal = optimizeNormal
                    pbr1.metallic = optimizeMetallic
                    pbr1.roughness = optimizeRoughness
                    pbr1.ambientOcclusion = optimizeAmbientOcclusion
                    pbr1.emissiveColor = optimizeEmissiveColor
                    pbr1.specular = optimizeSpecular
                    pbr1.blending = optimizeBlending  // blending 包含了优化后的 opacity
                    pbr1.clearcoat = optimizeClearcoat
                    pbr1.clearcoatRoughness = optimizeClearcoatRoughness
                    pbr1.clearcoatNormal = optimizeClearcoatNormal
                    pbr1.anisotropyLevel = optimizeAnisotropyLevel
                    pbr1.anisotropyAngle = optimizeAnisotropyAngle
                    pbr1.sheen = optimizeSheen
                    
                    // 按要求，使用 pbr1 放入数组
//                    newMaterials.append(pbr1)
                    
                    
                    // 可选：切换到 pbr2 测试对照
                     newMaterials.append(pbr2)
                    
                } else {
                    newMaterials.append(material)
                }
            }
            
            modelComponent.materials = newMaterials
            modelEntity.components[ModelComponent.self] = modelComponent
        }
        
        // 递归处理子实体
        for child in entity.children {
            await optimizeTexturesRecursive(child, simplifyRatio: simplifyRatio, optimizedCount: &optimizedCount, skippedCount: &skippedCount, failedCount: &failedCount)
        }
    }
    
    /// 优化 BaseColor 纹理
    private static func optimizeBaseColorTexture(
        _ baseColor: PhysicallyBasedMaterial.BaseColor,
        simplifyRatio: Float,
        optimizedCount: inout Int,
        skippedCount: inout Int,
        failedCount: inout Int
    ) async -> PhysicallyBasedMaterial.BaseColor {
        var newBaseColor = baseColor
        if let optimized = await optimizeTextureResource(
            baseColor.texture?.resource,
            type: .baseColor,
            simplifyRatio: simplifyRatio,
            optimizedCount: &optimizedCount,
            skippedCount: &skippedCount,
            failedCount: &failedCount
        ) {
            newBaseColor.texture = .init(optimized)
        }
        return newBaseColor
    }
    
    /// 优化 Normal 纹理
    private static func optimizeNormalTexture(
        _ normal: PhysicallyBasedMaterial.Normal,
        simplifyRatio: Float,
        optimizedCount: inout Int,
        skippedCount: inout Int,
        failedCount: inout Int
    ) async -> PhysicallyBasedMaterial.Normal {
        var newNormal = normal
        if let optimized = await optimizeTextureResource(
            normal.texture?.resource,
            type: .normal,
            simplifyRatio: simplifyRatio,
            optimizedCount: &optimizedCount,
            skippedCount: &skippedCount,
            failedCount: &failedCount
        ) {
            newNormal.texture = .init(optimized)
        }
        return newNormal
    }
    
    /// 优化 Metallic 纹理
    private static func optimizeMetallicTexture(
        _ metallic: PhysicallyBasedMaterial.Metallic,
        simplifyRatio: Float,
        optimizedCount: inout Int,
        skippedCount: inout Int,
        failedCount: inout Int
    ) async -> PhysicallyBasedMaterial.Metallic {
        var newMetallic = metallic
        if let optimized = await optimizeTextureResource(
            metallic.texture?.resource,
            type: .metallic,
            simplifyRatio: simplifyRatio,
            optimizedCount: &optimizedCount,
            skippedCount: &skippedCount,
            failedCount: &failedCount
        ) {
            newMetallic.texture = .init(optimized)
        }
        return newMetallic
    }
    
    /// 优化 Roughness 纹理
    private static func optimizeRoughnessTexture(
        _ roughness: PhysicallyBasedMaterial.Roughness,
        simplifyRatio: Float,
        optimizedCount: inout Int,
        skippedCount: inout Int,
        failedCount: inout Int
    ) async -> PhysicallyBasedMaterial.Roughness {
        var newRoughness = roughness
        if let optimized = await optimizeTextureResource(
            roughness.texture?.resource,
            type: .roughness,
            simplifyRatio: simplifyRatio,
            optimizedCount: &optimizedCount,
            skippedCount: &skippedCount,
            failedCount: &failedCount
        ) {
            newRoughness.texture = .init(optimized)
        }
        return newRoughness
    }
    
    /// 优化 AO 纹理
    private static func optimizeAOTexture(
        _ ao: PhysicallyBasedMaterial.AmbientOcclusion,
        simplifyRatio: Float,
        optimizedCount: inout Int,
        skippedCount: inout Int,
        failedCount: inout Int
    ) async -> PhysicallyBasedMaterial.AmbientOcclusion {
        var newAO = ao
        if let optimized = await optimizeTextureResource(
            ao.texture?.resource,
            type: .ao,
            simplifyRatio: simplifyRatio,
            optimizedCount: &optimizedCount,
            skippedCount: &skippedCount,
            failedCount: &failedCount
        ) {
            newAO.texture = .init(optimized)
        }
        return newAO
    }
    
    /// 优化 Emissive 纹理
    private static func optimizeEmissiveTexture(
        _ emissive: PhysicallyBasedMaterial.EmissiveColor,
        simplifyRatio: Float,
        optimizedCount: inout Int,
        skippedCount: inout Int,
        failedCount: inout Int
    ) async -> PhysicallyBasedMaterial.EmissiveColor {
        var newEmissive = emissive
        if let optimized = await optimizeTextureResource(
            emissive.texture?.resource,
            type: .emissive,
            simplifyRatio: simplifyRatio,
            optimizedCount: &optimizedCount,
            skippedCount: &skippedCount,
            failedCount: &failedCount
        ) {
            newEmissive.texture = .init(optimized)
        }
        return newEmissive
    }
    
    /// 优化 Specular 纹理
    private static func optimizeSpecularTexture(
        _ specular: PhysicallyBasedMaterial.Specular,
        simplifyRatio: Float,
        optimizedCount: inout Int,
        skippedCount: inout Int,
        failedCount: inout Int
    ) async -> PhysicallyBasedMaterial.Specular {
        var newSpecular = specular
        if let optimized = await optimizeTextureResource(
            specular.texture?.resource,
            type: .specular,
            simplifyRatio: simplifyRatio,
            optimizedCount: &optimizedCount,
            skippedCount: &skippedCount,
            failedCount: &failedCount
        ) {
            newSpecular.texture = .init(optimized)
        }
        return newSpecular
    }
    
    /// 优化 Opacity 纹理
    private static func optimizeOpacityTexture(
        _ opacity: PhysicallyBasedMaterial.Opacity,
        simplifyRatio: Float,
        optimizedCount: inout Int,
        skippedCount: inout Int,
        failedCount: inout Int
    ) async -> PhysicallyBasedMaterial.Opacity {
        var newOpacity = opacity
        if let optimized = await optimizeTextureResource(
            opacity.texture?.resource,
            type: .opacity,
            simplifyRatio: simplifyRatio,
            optimizedCount: &optimizedCount,
            skippedCount: &skippedCount,
            failedCount: &failedCount
        ) {
            newOpacity.texture = .init(optimized)
        }
        return newOpacity
    }
    
    /// 优化 Clearcoat 纹理
    private static func optimizeClearcoatTexture(
        _ clearcoat: PhysicallyBasedMaterial.Clearcoat,
        simplifyRatio: Float,
        optimizedCount: inout Int,
        skippedCount: inout Int,
        failedCount: inout Int
    ) async -> PhysicallyBasedMaterial.Clearcoat {
        var newClearcoat = clearcoat
        if let optimized = await optimizeTextureResource(
            clearcoat.texture?.resource,
            type: .clearcoat,
            simplifyRatio: simplifyRatio,
            optimizedCount: &optimizedCount,
            skippedCount: &skippedCount,
            failedCount: &failedCount
        ) {
            newClearcoat.texture = .init(optimized)
        }
        return newClearcoat
    }
    
    /// 优化 ClearcoatRoughness 纹理
    private static func optimizeClearcoatRoughnessTexture(
        _ clearcoatRoughness: PhysicallyBasedMaterial.ClearcoatRoughness,
        simplifyRatio: Float,
        optimizedCount: inout Int,
        skippedCount: inout Int,
        failedCount: inout Int
    ) async -> PhysicallyBasedMaterial.ClearcoatRoughness {
        var newClearcoatRoughness = clearcoatRoughness
        if let optimized = await optimizeTextureResource(
            clearcoatRoughness.texture?.resource,
            type: .clearcoatRoughness,
            simplifyRatio: simplifyRatio,
            optimizedCount: &optimizedCount,
            skippedCount: &skippedCount,
            failedCount: &failedCount
        ) {
            newClearcoatRoughness.texture = .init(optimized)
        }
        return newClearcoatRoughness
    }
    
    /// 优化 ClearcoatNormal 纹理
    private static func optimizeClearcoatNormalTexture(
        _ clearcoatNormal: PhysicallyBasedMaterial.ClearcoatNormal,
        simplifyRatio: Float,
        optimizedCount: inout Int,
        skippedCount: inout Int,
        failedCount: inout Int
    ) async -> PhysicallyBasedMaterial.ClearcoatNormal {
        var newClearcoatNormal = clearcoatNormal
        if let optimized = await optimizeTextureResource(
            clearcoatNormal.texture?.resource,
            type: .clearcoatNormal,
            simplifyRatio: simplifyRatio,
            optimizedCount: &optimizedCount,
            skippedCount: &skippedCount,
            failedCount: &failedCount
        ) {
            newClearcoatNormal.texture = .init(optimized)
        }
        return newClearcoatNormal
    }
    
    /// 优化 AnisotropyLevel 纹理
    private static func optimizeAnisotropyLevelTexture(
        _ anisotropyLevel: PhysicallyBasedMaterial.AnisotropyLevel,
        simplifyRatio: Float,
        optimizedCount: inout Int,
        skippedCount: inout Int,
        failedCount: inout Int
    ) async -> PhysicallyBasedMaterial.AnisotropyLevel {
        var newAnisotropyLevel = anisotropyLevel
        if let optimized = await optimizeTextureResource(
            anisotropyLevel.texture?.resource,
            type: .anisotropyLevel,
            simplifyRatio: simplifyRatio,
            optimizedCount: &optimizedCount,
            skippedCount: &skippedCount,
            failedCount: &failedCount
        ) {
            newAnisotropyLevel.texture = .init(optimized)
        }
        return newAnisotropyLevel
    }
    
    /// 优化 AnisotropyAngle 纹理
    private static func optimizeAnisotropyAngleTexture(
        _ anisotropyAngle: PhysicallyBasedMaterial.AnisotropyAngle,
        simplifyRatio: Float,
        optimizedCount: inout Int,
        skippedCount: inout Int,
        failedCount: inout Int
    ) async -> PhysicallyBasedMaterial.AnisotropyAngle {
        var newAnisotropyAngle = anisotropyAngle
        if let optimized = await optimizeTextureResource(
            anisotropyAngle.texture?.resource,
            type: .anisotropyAngle,
            simplifyRatio: simplifyRatio,
            optimizedCount: &optimizedCount,
            skippedCount: &skippedCount,
            failedCount: &failedCount
        ) {
            newAnisotropyAngle.texture = .init(optimized)
        }
        return newAnisotropyAngle
    }
    
    /// 优化 Sheen 纹理
    private static func optimizeSheenTexture(
        _ sheen: PhysicallyBasedMaterial.SheenColor?,
        simplifyRatio: Float,
        optimizedCount: inout Int,
        skippedCount: inout Int,
        failedCount: inout Int
    ) async -> PhysicallyBasedMaterial.SheenColor? {
        guard var newSheen = sheen else{
            return nil
        }
        if let optimized = await optimizeTextureResource(
            newSheen.texture?.resource,
            type: .sheenColor,
            simplifyRatio: simplifyRatio,
            optimizedCount: &optimizedCount,
            skippedCount: &skippedCount,
            failedCount: &failedCount
        ) {
            newSheen.texture = .init(optimized)
        }
        return newSheen
    }
    
    /// 优化单个 TextureResource
    private static func optimizeTextureResource(
        _ textureResource: TextureResource?,
        type: TextureType,
        simplifyRatio: Float,
        optimizedCount: inout Int,
        skippedCount: inout Int,
        failedCount: inout Int
    ) async -> TextureResource? {
        
        guard let textureResource = textureResource else {
            return nil
        }
        
        let originalWidth = textureResource.width
        let originalHeight = textureResource.height
        let originalSize = max(originalWidth, originalHeight)
        let pixelFormat = textureResource.pixelFormat
        
        // 计算原始纹理内存大小（估算）
        let originalBytesPerPixel = pixelFormatBytesPerPixel(pixelFormat)
        let originalMemoryMB = Float(originalWidth * originalHeight * originalBytesPerPixel) / (1024 * 1024)
        
        
        // 计算目标分辨率
        let targetSize = calculateTargetResolution(
            originalSize: originalSize,
            textureType: type,
            simplifyRatio: simplifyRatio
        )
        
        // 不需要缩小
        if targetSize >= originalSize {
            skippedCount += 1
            return nil
        }
        
        do {
            guard let cgImage = try await extractCGImage(from: textureResource) else {
                throw NSError(domain: "TextureOptimization", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法导出纹理"])
            }
            
            guard let downscaledCGImage = downsampleCGImage(
                cgImage,
                targetSize: targetSize,
                textureType: type,
                originalFormat: pixelFormat  // 传入原始格式，避免单通道/双通道→四通道的转换
            ) else {
                throw NSError(domain: "TextureOptimization", code: 2, userInfo: [NSLocalizedDescriptionKey: "降采样失败"])
            }
            let semantic: TextureResource.Semantic = switch type {
                case .baseColor, .emissive: .color
                case .normal: .normal
                default: .raw
            }
            
            let newTexture = try TextureResource.generate(
                from: downscaledCGImage,
                options: .init(semantic: semantic)
            )
            // 计算优化后的内存大小
            let newBytesPerPixel = pixelFormatBytesPerPixel(newTexture.pixelFormat)
            let newMemoryMB = Float(newTexture.width * newTexture.height * newBytesPerPixel) / (1024 * 1024)
            let memorySaved = originalMemoryMB - newMemoryMB
            let memoryReduction = (memorySaved / originalMemoryMB) * 100
            
            optimizedCount += 1
            
            return newTexture
            
        } catch {
            failedCount += 1
            return nil
        }
    }
    
    /// 计算目标分辨率
    private static func calculateTargetResolution(
        originalSize: Int,
        textureType: TextureType,
        simplifyRatio: Float
    ) -> Int {
        // 🔥 激进模式：纹理分辨率直接跟随面数比例
        // 面数降到10% → 纹理也降到接近10%
        // 面数降到50% → 纹理也降到接近50%
        
        // 纹理是2D的，内存占用 = 宽 × 高
        // 如果想让纹理内存降到 x%，分辨率应该降到 √x
        // 但为了更激进，我们直接用 simplifyRatio（相当于比面数降得更厉害）
        
        // 不同纹理类型的微调系数（可以稍微区分重要性）
        let typeMultiplier: Float = switch textureType {
            case .baseColor: 1.0      // BaseColor最重要，保持1:1
            case .normal: 0.9         // Normal稍微更激进
            case .metallic: 0.8       // 单通道更激进
            case .roughness: 0.8
            case .ao: 0.7             // AO最激进
            case .emissive: 0.9
            case .specular: 0.8       // 高光，和metallic类似
            case .opacity: 0.9        // 透明度比较重要
            case .clearcoat: 0.8      // 清漆层
            case .clearcoatRoughness: 0.7  // 清漆层粗糙度
            case .clearcoatNormal: 0.9     // 清漆层法线，和normal类似
            case .anisotropyLevel: 0.7     // 各向异性级别
            case .anisotropyAngle: 0.7     // 各向异性角度
            case .sheenColor: 0.8          // 光泽颜色
        }
        
        // 直接用 simplifyRatio 作为分辨率缩放因子
        // 例如：0.1 简化 → 纹理降到 0.1 × 1.0 = 10% 的分辨率
        // 例如：0.5 简化 → 纹理降到 0.5 × 1.0 = 50% 的分辨率
        let scale = simplifyRatio * typeMultiplier
        
        let targetSize = Float(originalSize) * scale
        
        // 向下取整到2的幂
        let powerOfTwo = Int(pow(2.0, floor(log2(targetSize))))
        
        // 🔥 最小分辨率32，最大4096
        return min(4096, max(32, powerOfTwo))
    }
    
    /// TextureResource → CGImage
    private static func extractCGImage(from texture: TextureResource) async throws -> CGImage? {
        let width = texture.width
        let height = texture.height
        let pixelFormat = texture.pixelFormat
        
        
        // 创建 Metal 设备
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "TextureOptimization", code: 100, userInfo: [NSLocalizedDescriptionKey: "无法创建 Metal 设备"])
        }
        
        // 创建目标纹理
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        
        guard let metalTexture = device.makeTexture(descriptor: descriptor) else {
            throw NSError(domain: "TextureOptimization", code: 101, userInfo: [NSLocalizedDescriptionKey: "无法创建 MTLTexture"])
        }
        
        // 复制数据
        try await texture.copy(to: metalTexture)
        
        // 读取像素数据
        let bytesPerPixel = pixelFormatBytesPerPixel(pixelFormat)
        let bytesPerRow = width * bytesPerPixel
        let dataSize = height * bytesPerRow
        
        
        var pixelData = [UInt8](repeating: 0, count: dataSize)
        
        metalTexture.getBytes(
            &pixelData,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        
        return createCGImage(
            from: pixelData,
            width: width,
            height: height,
            pixelFormat: pixelFormat
        )
    }
    
    /// 像素数据 → CGImage
    private static func createCGImage(
        from data: [UInt8],
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat
    ) -> CGImage? {
        
        let (bitsPerComponent, bitsPerPixel, colorSpace, bitmapInfo) = cgImageInfo(for: pixelFormat)
        let bytesPerRow = width * (bitsPerPixel / 8)
        
        
        guard let dataProvider = CGDataProvider(data: Data(data) as CFData) else {
            return nil
        }
        
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
        
        return cgImage
    }
    
    /// 降采样 CGImage
    private static func downsampleCGImage(
        _ image: CGImage,
        targetSize: Int,
        textureType: TextureType,
        originalFormat: MTLPixelFormat  // 新增：原始格式参数，用于保持格式一致性
    ) -> CGImage? {
        
        let originalMaxSize = max(image.width, image.height)
        let scale = CGFloat(targetSize) / CGFloat(originalMaxSize)
        let newWidth = Int(CGFloat(image.width) * scale)
        let newHeight = Int(CGFloat(image.height) * scale)
        
        
        // 获取原始格式信息（保持单通道R8、双通道RG8等格式不被转换为RGBA8）
        let imageInfo = cgImageInfo(for: originalFormat)
        
        // 创建CIContext和CIImage
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        let ciImage = CIImage(cgImage: image)
        
        // 使用Lanczos缩放
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else {
            return nil
        }
        
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        
        guard let outputCIImage = filter.outputImage else {
            return nil
        }
        
        // 步骤1: 先用 CIContext 创建临时 CGImage（可能是 RGBA8）
        guard let tempCGImage = ciContext.createCGImage(outputCIImage, from: outputCIImage.extent) else {
            return nil
        }
        
        // 步骤2: 创建具有目标格式的 CGContext（关键：保持原始格式，避免R8→RGBA8、RG8→RGBA8转换）
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: imageInfo.bitsPerComponent,
            bytesPerRow: newWidth * imageInfo.bitsPerPixel / 8,
            space: imageInfo.colorSpace,
            bitmapInfo: imageInfo.bitmapInfo.rawValue
        ) else {
            return nil
        }
        
        context.draw(tempCGImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        
        guard let result = context.makeImage() else {
            return nil
        }
        
        let originalBpp = imageInfo.bitsPerPixel
        let resultBpp = result.bitsPerPixel
        
        return result
    }
    
    /// 获取像素格式的字节数
    private static func pixelFormatBytesPerPixel(_ format: MTLPixelFormat) -> Int {
        switch format {
        case .r8Unorm, .r8Snorm, .r8Uint, .r8Sint, .r8Unorm_srgb:
            return 1
        case .rg8Unorm, .rg8Snorm, .rg8Uint, .rg8Sint, .rg8Unorm_srgb:
            return 2
        case .rgba8Unorm, .rgba8Unorm_srgb, .rgba8Snorm, .rgba8Uint, .rgba8Sint,
             .bgra8Unorm, .bgra8Unorm_srgb:
            return 4
        case .rgba16Float, .rgba16Unorm, .rgba16Snorm, .rgba16Uint, .rgba16Sint:
            return 8
        case .rgba32Float, .rgba32Uint, .rgba32Sint:
            return 16
        default:
            return 4
        }
    }
    
    /// 获取 CGImage 格式信息（支持单通道、双通道、四通道格式）
    private static func cgImageInfo(for format: MTLPixelFormat)
        -> (bitsPerComponent: Int, bitsPerPixel: Int, colorSpace: CGColorSpace, bitmapInfo: CGBitmapInfo) {
        
        switch format {
        // 单通道格式 (8 bpp) - Grayscale
        case .r8Unorm, .r8Snorm, .r8Uint, .r8Sint:
            return (8, 8, CGColorSpaceCreateDeviceGray(), CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue))
        
        case .r8Unorm_srgb:
            // sRGB Grayscale
            return (8, 8, CGColorSpaceCreateDeviceGray(), CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue))
        
        // 单通道格式 (16 bpp) - Grayscale
        case .r16Unorm, .r16Snorm, .r16Uint, .r16Sint:
            return (16, 16, CGColorSpaceCreateDeviceGray(), CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue))
        
        // 双通道格式 (16 bpp) - 注意：CGImage不原生支持RG，需要转为RGB或Gray
        // 这里我们将其视为灰度（只保留R通道），以避免扩展到RGBA
        case .rg8Unorm, .rg8Snorm, .rg8Uint, .rg8Sint:
            // 使用灰度以保持较小的内存占用（8bpp而不是32bpp）
            return (8, 8, CGColorSpaceCreateDeviceGray(), CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue))
        
        case .rg8Unorm_srgb:
            return (8, 8, CGColorSpaceCreateDeviceGray(), CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue))
            
        // 四通道格式 (32 bpp) - RGBA
        case .rgba8Unorm:
            return (8, 32, CGColorSpaceCreateDeviceRGB(), CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
            
        case .rgba8Unorm_srgb:
            return (8, 32, CGColorSpace(name: CGColorSpace.sRGB)!, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        
        case .rgba8Snorm, .rgba8Uint, .rgba8Sint:
            return (8, 32, CGColorSpaceCreateDeviceRGB(), CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
            
        // 四通道格式 (32 bpp) - BGRA
        case .bgra8Unorm:
            return (8, 32, CGColorSpaceCreateDeviceRGB(), CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            
        case .bgra8Unorm_srgb:
            return (8, 32, CGColorSpace(name: CGColorSpace.sRGB)!, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        
        // 其他特殊格式
        case .rgb10a2Unorm, .rgb10a2Uint:
            return (10, 32, CGColorSpaceCreateDeviceRGB(), CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
            
        // 默认：RGBA8
        default:
            return (8, 32, CGColorSpaceCreateDeviceRGB(), CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        }
    }
}

// MARK: - 简化类型枚举

/// 减面类型枚举 - 5个经典模式，满足不同使用场景
public enum SimplifyType: Hashable
//: CaseIterable
{
    case original      // 📊 原始质量 - 100%保留，仅缓存优化
    case standard      // ⚖️ 标准质量 - 30%保留，平衡质量与性能
    case minimal       // 🔥 极简模式 - 5%保留，极致性能优化
    case custom(options:SimplificationOptions) //自定义模式
    
    /// 获取对应的简化配置
    public var options: SimplificationOptions {
        switch self {
        case .original:
            return .original
            
        case .standard:
            return .standard
            
        case .custom(let options):
            return options
            
        case .minimal:
            return .minimal
        }
    }
    
    /// 获取对应的简化比例值（仅供显示）
    public var ratioValue: Float {
        return options.targetRatio
    }
    
    /// 获取缓存文件名后缀
    public var cacheFileSuffix: String {
        switch self {
        case .original:    return "_original"
        case .standard:    return "_standard"
        case .minimal:     return "_minimal"
        case .custom(let options): return "_custom_\(Int(options.targetRatio*100))"
        }
    }
    
    /// 显示名称
    public var displayName: String {
        switch self {
        case .original:    return "📊 原始质量"
        case .standard:    return "⚖️ 标准质量"
        case .minimal:     return "🔥 极简模式"
        case .custom(let options): return "自定义模式"
        }
    }
    
    /// 描述信息
    public var description: String {
        switch self {
        case .original:    return "100%保留，完整细节"
        case .standard:    return "30%保留，平衡性能"
        case .minimal:     return "5%保留，极致优化"
        case .custom(let options): return "自定义模式"
        }
    }
}

extension ModelEntity{
    /// 加载并缓存 USDZ 模型，支持网格简化
    /// - Parameters:
    ///   - url: 原始 USDZ 文件路径
    ///   - simplifyType: 简化类型，控制减面比例
    /// - Returns: 加载或简化后的 ModelEntity
    @MainActor @preconcurrency public static func loadAndCacheReality(
        contentsOf url: URL,
        simplifyType: SimplifyType = .original,
        overwriteExisting: Bool = false
    ) async throws -> ModelEntity {
        var modelEntity = ModelEntity()
        
        guard let documentUrl = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else {
            debugPrint("⚠️ 无法获取 Documents 目录")
            return try await ModelEntity(contentsOf: url)
        }
        
        do {
            // 设置目录结构
                let directory = documentUrl.appending(path: "Resources")
                let simplifiedFilesFolderUrl = directory.appending(path: "simplifiedFiles")
            
            // 根据简化类型生成不同的缓存文件名
            let originalFileName = url.deletingPathExtension().lastPathComponent
            let cacheFileName = "\(originalFileName)\(simplifyType.cacheFileSuffix).reality"
            let simplifiedFileUrl = simplifiedFilesFolderUrl.appending(path: cacheFileName)
            
            
            // 检查缓存是否存在
            if FileManager.default.fileExists(atPath: simplifiedFileUrl.path) {
                if overwriteExisting {
                    debugPrint("🔄 发现缓存文件，将覆盖")
                    try? FileManager.default.removeItem(at: simplifiedFileUrl)
                } else {
                    debugPrint("✅ 发现缓存文件，直接加载")
                    if let fileEntity = try? await Entity(contentsOf: simplifiedFileUrl) {
                        modelEntity.addChild(fileEntity)
                        debugPrint("✅ 缓存加载成功\n")
                        return modelEntity
                    } else {
                        debugPrint("⚠️ 缓存加载失败，将重新简化")
                    }
                }
            } else {
                debugPrint("📭 未找到缓存文件，需要进行简化")
            }
            
            // 创建缓存目录（如果不存在）
            if !FileManager.default.fileExists(atPath: simplifiedFilesFolderUrl.path) {
                        try FileManager.default.createDirectory(at: simplifiedFilesFolderUrl, withIntermediateDirectories: true)
                debugPrint("📁 创建缓存目录成功")
            }
            
            // 使用简化类型对应的配置进行处理
            debugPrint("🚀 开始处理...")
            debugPrint("   简化类型: \(simplifyType.displayName)")
            debugPrint("   简化比例: \(simplifyType.ratioValue * 100)%")
            debugPrint("   描述: \(simplifyType.description)")
            
            // 加载原始文件
            let originalEntity = try await ModelEntity(contentsOf: url)
            
            // 🆕 调用核心处理方法
            modelEntity = try await processSingleQualityLevel(
                sourceEntity: originalEntity,
                simplifyType: simplifyType,
                outputURL: simplifiedFileUrl
            )
            
            debugPrint("✅ 处理完成并已缓存\n")
            
        } catch {
            debugPrint("❌ loadAndCacheReality 发生错误: \(error)")
            // 发生错误时，直接加载原始文件
            modelEntity = try await ModelEntity(contentsOf: url)
        }
        
        return modelEntity
    }
    
    /// 加载 USDZ 并批量生成多个质量级别的缓存（一次加载，多次缓存）
    /// - Parameters:
    ///   - url: 原始 USDZ 文件路径
    ///   - targetQuality: 目标质量级别（方法将返回这个质量的 ModelEntity）
    ///   - additionalQualities: 额外要生成的质量级别数组，默认生成常用级别
    ///   - progressCallback: 进度回调 (当前索引, 总数, 当前类型)
    /// - Returns: 目标质量级别的 ModelEntity
    @MainActor @preconcurrency public static func loadWithMultiQualityCaches(
        contentsOf url: URL,
        targetQuality: SimplifyType = .standard,
        additionalQualities: [SimplifyType] =
    [
//        .minimal,
//        .standard,
        .original
    ],
        overwriteExisting: Bool = false,
        progressCallback: ((Int, Int, SimplifyType) -> Void)? = nil
    ) async throws -> ModelEntity {
        guard let documentUrl = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else {
            debugPrint("⚠️ 无法获取 Documents 目录")
            throw NSError(domain: "ModelEntity", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取 Documents 目录"])
        }
        
        let directory = documentUrl.appending(path: "Resources")
        let simplifiedFilesFolderUrl = directory.appending(path: "simplifiedFiles")
        
        // 创建缓存目录
        if !FileManager.default.fileExists(atPath: simplifiedFilesFolderUrl.path) {
            try FileManager.default.createDirectory(at: simplifiedFilesFolderUrl, withIntermediateDirectories: true)
            debugPrint("📁 创建缓存目录成功")
        }
        
        let originalFileName = url.deletingPathExtension().lastPathComponent
        
        // 合并目标质量和额外质量级别（确保目标质量在列表中，且去重）
        var allQualities = [targetQuality] + additionalQualities
        allQualities = Array(Set(allQualities)).sorted { $0.ratioValue > $1.ratioValue }
        
        debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        debugPrint("🔄 加载并批量生成多级质量缓存")
        debugPrint("📂 原始文件: \(url.lastPathComponent)")
        debugPrint("🎯 目标质量: \(targetQuality.displayName) (将返回此质量)")
        debugPrint("📊 质量级别数: \(allQualities.count) (\(allQualities.map { $0.displayName }.joined(separator: ", ")))")
        debugPrint("🔄 覆盖模式: \(overwriteExisting ? "是" : "否")")
        debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        var targetModelEntity: ModelEntity?
        
        // 🔑 关键优化：只加载一次原始 USDZ 文件
        debugPrint("⏳ 正在加载原始 USDZ 文件（只加载一次）...")
        let startLoadTime = Date()
        var originalLoadEntity : ModelEntity?
        let loadDuration = Date().timeIntervalSince(startLoadTime)
        debugPrint("✅ 原始文件加载完成，耗时: \(String(format: "%.2f", loadDuration))秒")
        debugPrint("")
        
        // 遍历所有质量级别，基于已加载的实体进行处理
        for (index, simplifyType) in allQualities.enumerated() {
            let cacheFileName = "\(originalFileName)\(simplifyType.cacheFileSuffix).reality"
            let cacheFileUrl = simplifiedFilesFolderUrl.appending(path: cacheFileName)
            
            // 通知进度
            progressCallback?(index + 1, allQualities.count, simplifyType)
            
            let isTargetQuality = (simplifyType == targetQuality)
            let qualityMarker = isTargetQuality ? "🎯 [目标]" : "📦"
            
            debugPrint("[\(index + 1)/\(allQualities.count)] \(qualityMarker) 处理质量级别: \(simplifyType.displayName)")
            debugPrint("   比例: \(simplifyType.ratioValue * 100)%")
            debugPrint("   缓存文件: \(cacheFileName)")
            
            // 检查缓存是否已存在
            if FileManager.default.fileExists(atPath: cacheFileUrl.path) {
                if overwriteExisting {
                    debugPrint("   🔄 缓存已存在，将覆盖")
                    try? FileManager.default.removeItem(at: cacheFileUrl)
                } else {
                    debugPrint("   ✅ 缓存已存在")
                    
                    // 如果是目标质量，加载并保存
                    if isTargetQuality {
                        if let fileEntity = try? await Entity(contentsOf: cacheFileUrl) {
                            let modelEntity = ModelEntity()
                            modelEntity.addChild(fileEntity)
                            targetModelEntity = modelEntity
                            debugPrint("   🎯 已加载目标质量模型")
                        }
                    }
                    continue
                }
            }
            if originalLoadEntity == nil{
                originalLoadEntity = try await ModelEntity(contentsOf: url)
            }
            guard let originalEntity = originalLoadEntity else { continue }
            let startTime = Date()
            
            do {
                // 🆕 调用核心处理方法（统一的优化逻辑）
                let processedEntity = try await processSingleQualityLevel(
                    sourceEntity: originalEntity,
                    simplifyType: simplifyType,
                    outputURL: cacheFileUrl
                )
                
                // 如果是目标质量，保存返回的实体
                if isTargetQuality {
                    targetModelEntity = processedEntity
                    debugPrint("   🎯 已保存目标质量模型")
                }
                
                let duration = Date().timeIntervalSince(startTime)
                debugPrint("   ✅ 生成成功，耗时: \(String(format: "%.2f", duration))秒")
                
            } catch {
                debugPrint("   ❌ 生成失败: \(error)")
                // 如果目标质量生成失败，抛出错误
                if isTargetQuality {
                    throw error
                }
                // 继续处理下一个质量级别
            }
            
            debugPrint("")
        }
        
        debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        debugPrint("📊 批量缓存完成")
        debugPrint("✅ 已生成 \(allQualities.count) 个质量级别的缓存")
        debugPrint("🎯 返回目标质量: \(targetQuality.displayName)")
        debugPrint("💾 缓存位置: \(simplifiedFilesFolderUrl.path)")
        debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // 确保目标质量的实体已经生成
        guard let resultEntity = targetModelEntity else {
            debugPrint("⚠️ 目标质量模型未生成，降级使用原始加载")
            return try await ModelEntity(contentsOf: url)
        }
        
        return resultEntity
    }
    
    /// 【核心方法】处理单个质量级别（统一的优化逻辑）
    /// - Parameters:
    ///   - sourceEntity: 源实体（可以是刚加载的或已加载的）
    ///   - simplifyType: 质量类型
    ///   - outputURL: 输出缓存文件路径
    /// - Returns: 处理后的 ModelEntity
    private static func processSingleQualityLevel(
        sourceEntity: ModelEntity,
        simplifyType: SimplifyType,
        outputURL: URL
    ) async throws -> ModelEntity {
        let options = simplifyType.options
        
        // 🔑 关键优化：高保留率（≥95%）跳过处理，直接复制
        if options.targetRatio >= 0.95 {
            debugPrint("   ⏭️ 高保留率（≥95%），跳过优化，直接复制原始数据")
            
            let entityCopy = sourceEntity.clone(recursive: true)
            
            // 异步保存
            Task.detached(priority: .background) {
                do {
                    try await entityCopy.write(to: outputURL)
                    await MainActor.run {
                        debugPrint("      💾 后台保存完成（原始复制）")
                    }
                } catch {
                    await MainActor.run {
                        debugPrint("      ⚠️ 后台保存失败: \(error.localizedDescription)")
                    }
                }
            }
            
            return entityCopy
        }
        
        // 正常的优化流程
        debugPrint("   🔧 开始优化处理...")
        
        let entityCopy = sourceEntity.clone(recursive: true)
        
        // 检测纹理信息
        USDZMeshSimplifier.detectTextureInfo(entityCopy)
        
        // 纹理降采样优化
        await USDZMeshSimplifier.optimizeTextures(entityCopy, simplifyRatio: options.targetRatio)
        
        // 递归处理所有网格
        var processedCount = 0
        var simplifiedCount = 0
        
        try await USDZMeshSimplifier.processEntity(
            entityCopy,
            options: options,
            processedCount: &processedCount,
            simplifiedCount: &simplifiedCount
        )
        
        
        debugPrint("      - 处理网格数: \(processedCount)")
        debugPrint("      - 简化网格数: \(simplifiedCount)")
        
        // 异步保存
        Task.detached(priority: .background) {
            do {
                try await entityCopy.write(to: outputURL)
                await MainActor.run {
                    debugPrint("      💾 后台保存完成")
                }
            } catch {
                await MainActor.run {
                    debugPrint("      ⚠️ 后台保存失败: \(error.localizedDescription)")
                }
            }
        }
        
        return entityCopy
    }
    
    /// 加载 USDZ 并按照指定的质量级别和路径生成多个缓存文件
    /// - Parameters:
    ///   - url: 原始 USDZ 文件路径
    ///   - qualitiesAndURLs: 质量级别和对应输出路径的数组，格式：[(SimplifyType, URL)]
    ///   - overwriteExisting: 是否覆盖已存在的文件，默认为 false
    ///   - progressCallback: 进度回调 (当前索引, 总数, 当前类型)
    /// - Returns: 字典，键为 SimplifyType，值为对应的 ModelEntity（只包含成功处理的）
    @MainActor @preconcurrency public static func loadAndExportToCustomURLs(
        contentsOf url: URL,
        qualitiesAndURLs: [(SimplifyType, URL)],
        overwriteExisting: Bool = false,
        progressCallback: ((Int, Int, SimplifyType) -> Void)? = nil
    ) async throws -> Void {
        
        // 参数校验
        guard !qualitiesAndURLs.isEmpty else {
            debugPrint("⚠️ qualitiesAndURLs 为空，返回空字典")
            return
        }
        
        debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        debugPrint("🎯 自定义路径批量导出")
        debugPrint("📂 原始文件: \(url.lastPathComponent)")
        debugPrint("📊 导出数量: \(qualitiesAndURLs.count)")
        debugPrint("🔄 覆盖模式: \(overwriteExisting ? "是" : "否")")
        debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // 打印导出计划
        for (index, item) in qualitiesAndURLs.enumerated() {
            debugPrint("   [\(index + 1)] \(item.0.displayName) → \(item.1.lastPathComponent)")
        }
        debugPrint("")
        
        var resultDictionary: [SimplifyType: ModelEntity] = [:]
        var originalLoadEntity: ModelEntity?
        
        // 遍历所有质量级别和对应的输出路径
        for (index, item) in qualitiesAndURLs.enumerated() {
            let (simplifyType, outputURL) = item
            
            // 通知进度
            progressCallback?(index + 1, qualitiesAndURLs.count, simplifyType)
            
            debugPrint("[\(index + 1)/\(qualitiesAndURLs.count)] 处理: \(simplifyType.displayName)")
            debugPrint("   比例: \(simplifyType.ratioValue * 100)%")
            debugPrint("   输出: \(outputURL.path)")
            
            // 检查输出文件是否已存在
            if FileManager.default.fileExists(atPath: outputURL.path) {
                if overwriteExisting {
                    debugPrint("   🔄 输出文件已存在，将覆盖")
                    try? FileManager.default.removeItem(at: outputURL)
                } else {
                    debugPrint("   ℹ️ 输出文件已存在，尝试加载")
                    
                    // 尝试加载已存在的文件
                    if let fileEntity = try? await Entity(contentsOf: outputURL) {
                        let modelEntity = ModelEntity()
                        modelEntity.addChild(fileEntity)
                        resultDictionary[simplifyType] = modelEntity
                        debugPrint("   ✅ 已加载现有文件到结果字典")
                    } else {
                        debugPrint("   ⚠️ 现有文件加载失败，将重新生成")
                        // 删除损坏的文件
                        try? FileManager.default.removeItem(at: outputURL)
                    }
                    
                    // 如果成功加载，跳过处理
                    if resultDictionary[simplifyType] != nil {
                        debugPrint("")
                        continue
                    }
                }
            }
            
            // 确保输出目录存在
            let outputDirectory = outputURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: outputDirectory.path) {
                do {
                    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                    debugPrint("   📁 创建输出目录成功")
                } catch {
                    debugPrint("   ❌ 创建输出目录失败: \(error)")
                    debugPrint("")
                    continue
                }
            }
            
            // 🔑 关键优化：只加载一次原始文件
            if originalLoadEntity == nil {
                debugPrint("   ⏳ 加载原始文件...")
                let startLoadTime = Date()
                do {
                    originalLoadEntity = try await ModelEntity(contentsOf: url)
                    let loadDuration = Date().timeIntervalSince(startLoadTime)
                    debugPrint("   ✅ 加载完成，耗时: \(String(format: "%.2f", loadDuration))秒")
                } catch {
                    debugPrint("   ❌ 原始文件加载失败: \(error)")
                    debugPrint("")
                    throw error
                }
            }
            
            guard let originalEntity = originalLoadEntity else {
                debugPrint("   ❌ 原始模型不可用")
                debugPrint("")
                continue
            }
            
            let startTime = Date()
            
            do {
                // 调用核心处理方法
                let processedEntity = try await processSingleQualityLevel(
                    sourceEntity: originalEntity,
                    simplifyType: simplifyType,
                    outputURL: outputURL
                )
                
                // 保存到结果字典
                resultDictionary[simplifyType] = processedEntity
                
                let duration = Date().timeIntervalSince(startTime)
                debugPrint("   ✅ 处理成功，耗时: \(String(format: "%.2f", duration))秒")
                debugPrint("   📝 已添加到结果字典")
                
            } catch {
                debugPrint("   ❌ 处理失败: \(error)")
            }
            
            debugPrint("")
        }
        
        debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        debugPrint("📊 批量导出完成")
        debugPrint("✅ 成功处理: \(resultDictionary.count)/\(qualitiesAndURLs.count)")
        debugPrint("📋 成功的质量级别: \(resultDictionary.keys.map { $0.displayName }.joined(separator: ", "))")
        debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        return 
    }
    
    /// 批量处理文件夹中的所有 USDZ 文件，为每个文件生成多个质量级别并保存到对应文件夹
    /// - Parameters:
    ///   - sourceFolder: 源文件夹路径，包含待处理的 USDZ 文件
    ///   - qualitiesAndFolderURLs: 质量级别和对应输出文件夹的数组，格式：[(SimplifyType, URL)]
    ///   - overwriteExisting: 是否覆盖已存在的文件，默认为 false
    ///   - progressCallback: 进度回调 (当前文件索引, 总文件数, 当前文件名, 当前质量类型)
    /// - Returns: 处理统计信息：(成功文件数, 失败文件数, 总文件数)
    @MainActor @preconcurrency public static func batchProcessFolderToCustomFolders(
        sourceFolder: URL,
        qualitiesAndFolderURLs: [(SimplifyType, URL)],
        overwriteExisting: Bool = false,
        progressCallback: ((Int, Int, String, SimplifyType) -> Void)? = nil
    ) async throws -> (successCount: Int, failureCount: Int, totalCount: Int) {
        
        // 参数校验
        guard !qualitiesAndFolderURLs.isEmpty else {
            debugPrint("⚠️ qualitiesAndFolderURLs 为空，无法处理")
            return (0, 0, 0)
        }
        
        guard FileManager.default.fileExists(atPath: sourceFolder.path) else {
            debugPrint("❌ 源文件夹不存在: \(sourceFolder.path)")
            throw NSError(domain: "batchProcessFolder", code: -1, userInfo: [NSLocalizedDescriptionKey: "源文件夹不存在"])
        }
        
        debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        debugPrint("🚀 批量处理文件夹到多个质量级别文件夹")
        debugPrint("📂 源文件夹: \(sourceFolder.path)")
        debugPrint("📊 质量级别数: \(qualitiesAndFolderURLs.count)")
        debugPrint("🔄 覆盖模式: \(overwriteExisting ? "是" : "否")")
        debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // 打印输出文件夹计划
        for (index, item) in qualitiesAndFolderURLs.enumerated() {
            debugPrint("   [\(index + 1)] \(item.0.displayName) → \(item.1.lastPathComponent)/")
        }
        debugPrint("")
        
        // 确保所有输出文件夹存在
        for (simplifyType, folderURL) in qualitiesAndFolderURLs {
            if !FileManager.default.fileExists(atPath: folderURL.path) {
                do {
                    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                    debugPrint("📁 创建输出文件夹: \(folderURL.lastPathComponent)/")
                } catch {
                    debugPrint("❌ 创建文件夹失败 [\(simplifyType.displayName)]: \(error)")
                    throw error
                }
            }
        }
        debugPrint("")
        
        // 扫描源文件夹中的所有 .usdz 文件
        var usdzFiles: [URL] = []
        
        if let files = try? FileManager.default.contentsOfDirectory(
            at: sourceFolder,
            includingPropertiesForKeys: [.nameKey, .isDirectoryKey]
        ) {
            for fileURL in files {
                if fileURL.pathExtension.lowercased() == "usdz" {
                    usdzFiles.append(fileURL)
                }
            }
        }
        
        // 按文件名排序
        usdzFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
        
        let totalFiles = usdzFiles.count
        guard totalFiles > 0 else {
            debugPrint("⚠️ 源文件夹中没有找到 USDZ 文件")
            return (0, 0, 0)
        }
        
        debugPrint("📋 找到 \(totalFiles) 个 USDZ 文件")
        debugPrint("")
        
        var successCount = 0
        var failureCount = 0
        
        // 遍历每个文件
        for (fileIndex, usdzURL) in usdzFiles.enumerated() {
            let fileName = usdzURL.lastPathComponent
            let fileNumber = fileIndex + 1
            
            debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            debugPrint("📄 [\(fileNumber)/\(totalFiles)] 处理文件: \(fileName)")
            debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            
            var originalLoadEntity: ModelEntity?
            var fileHasError = false
            
            // 遍历所有质量级别
            for (qualityIndex, item) in qualitiesAndFolderURLs.enumerated() {
                let (simplifyType, outputFolder) = item
                
                // 构建输出文件路径（保持原文件名）
                var outputURL = outputFolder.appendingPathComponent(fileName)
                outputURL.deletePathExtension()
                outputURL.appendPathExtension("reality")
                // 通知进度
                progressCallback?(fileNumber, totalFiles, fileName, simplifyType)
                
                debugPrint("\n   [\(qualityIndex + 1)/\(qualitiesAndFolderURLs.count)] 质量: \(simplifyType.displayName)")
                debugPrint("      比例: \(String(format: "%.1f", simplifyType.ratioValue * 100))%")
                debugPrint("      输出: \(outputURL.path)")
                
                // 检查输出文件是否已存在
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    if overwriteExisting {
                        debugPrint("      🔄 输出文件已存在，将覆盖")
                        try? FileManager.default.removeItem(at: outputURL)
                    } else {
                        debugPrint("      ℹ️ 输出文件已存在，跳过")
                        continue
                    }
                }
                
                // 🔑 关键优化：只加载一次原始文件（每个文件只加载一次）
                if originalLoadEntity == nil && !fileHasError {
                    debugPrint("      ⏳ 加载原始文件...")
                    let startLoadTime = Date()
                    do {
                        originalLoadEntity = try await ModelEntity(contentsOf: usdzURL)
                        let loadDuration = Date().timeIntervalSince(startLoadTime)
                        debugPrint("      ✅ 加载完成，耗时: \(String(format: "%.2f", loadDuration))秒")
                    } catch {
                        debugPrint("      ❌ 原始文件加载失败: \(error)")
                        fileHasError = true
                        failureCount += 1
                        break // 跳过该文件的所有质量级别
                    }
                }
                
                guard let originalEntity = originalLoadEntity else {
                    debugPrint("      ❌ 原始模型不可用")
                    continue
                }
                
                let startTime = Date()
                
                do {
                    // 调用核心处理方法
                    _ = try await processSingleQualityLevel(
                        sourceEntity: originalEntity,
                        simplifyType: simplifyType,
                        outputURL: outputURL
                    )
                    
                    let duration = Date().timeIntervalSince(startTime)
                    debugPrint("      ✅ 处理成功，耗时: \(String(format: "%.2f", duration))秒")
                    
                } catch {
                    debugPrint("      ❌ 处理失败: \(error)")
                    // 继续处理该文件的其他质量级别
                }
            }
            
            // 统计：如果文件没有错误，则算作成功
            if !fileHasError {
                successCount += 1
            }
            
            debugPrint("")
        }
        
        debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        debugPrint("🎉 批量处理完成")
        debugPrint("📊 总文件数: \(totalFiles)")
        debugPrint("✅ 成功: \(successCount) 个文件")
        debugPrint("❌ 失败: \(failureCount) 个文件")
        debugPrint("📁 输出文件夹数: \(qualitiesAndFolderURLs.count)")
        debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        return (successCount, failureCount, totalFiles)
    }
}

