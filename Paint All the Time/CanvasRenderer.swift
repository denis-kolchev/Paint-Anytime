//
//  Renderer.swift
//  Paint All the Time
//
//  Created by Denis Kolchev on 18.09.2026.
//

import MetalKit


final class CanvasRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let controller: CanvasController
    
    init(controller: CanvasController) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "strokeVertex"),
              let fragmentFunction = library.makeFunction(name: "strokeFragment") else {
            fatalError("Could not initialize Metal.")
        }
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        descriptor.colorAttachments[0].isBlendingEnabled = false
        
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Could not create Metal pipeline: \(error)")
        }
        
        self.device = device
        self.commandQueue = commandQueue
        self.controller = controller
        
        super.init()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }
    
    func draw(in view: MTKView) {
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            return
        }
        
        var vertices: [StrokeVertex] = []
        
        for stroke in controller.document.strokes {
            vertices.append(
                contentsOf: StrokeMesher.vertices(for: stroke)
            )
        }
        
        if let activeStroke = controller.activeStroke {
            vertices.append(
                contentsOf: StrokeMesher.vertices(for: activeStroke)
            )
        }
        
        var vertexBuffer: MTLBuffer?
        
        if !vertices.isEmpty {
            vertexBuffer = vertices.withUnsafeBufferPointer { buffer in
                guard let address = buffer.baseAddress else {
                    return nil
                }
                
                return device.makeBuffer(
                    bytes: address,
                    length: buffer.count
                    * MemoryLayout<StrokeVertex>.stride,
                    options: .storageModeShared
                )
            }
            
            guard vertexBuffer != nil else {
                return
            }
        }
        
        guard
            let renderPass = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPass
            )
                else {
            return
        }
        
        encoder.setRenderPipelineState(pipelineState)
        
        if let vertexBuffer {
            var canvasSize = SIMD2<Float>(
                Float(view.bounds.width),
                Float(view.bounds.height)
            )
            
            encoder.setVertexBuffer(
                vertexBuffer,
                offset: 0,
                index: 0
            )
            
            encoder.setVertexBytes(
                &canvasSize,
                length: MemoryLayout<SIMD2<Float>>.stride,
                index: 1
            )
            
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: vertices.count
            )
        }
        
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
