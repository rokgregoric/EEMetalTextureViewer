//
//  MTPixelViewer.swift
//  eldade_metal_tests
//
//  Created by Eldad Eilam on 9/21/16.
//  Copyright © 2016 Eldad Eilam. All rights reserved.
//

import UIKit
import MetalKit
import MetalPerformanceShaders

class EETextureViewer: MTKView {

  typealias Float4 = SIMD4<Float>
  fileprivate let statsView = UITextView(frame: CGRect())

  fileprivate let framesPerStatusUpdate = 30
  fileprivate var framesSinceLastUpdate = 0

  var fpsCounterLastTimestamp = Date()

  var lastBufferUnaligned: Bool = false

  private var commandQueue: MTLCommandQueue! = nil
  private var library: MTLLibrary! = nil
  private var pipelineDescriptor = MTLRenderPipelineDescriptor()
  private var pipelineState: MTLRenderPipelineState! = nil
  private var vertexBuffer: MTLBuffer! = nil
  private var texCoordBuffer: MTLBuffer! = nil

  internal var textures = [MTLTexture?](repeating: nil, count: 3)

  internal let lockQueue = DispatchQueue(label:"pixelViewerQueue")

  internal let lock: NSLock! = NSLock.init()
  private var lockedState: Bool = false

  private var permuteTableBuffer: MTLBuffer!

  internal var planeCount: Int?

  private var intermediateTexture: MTLTexture?

  var YpCbCrMatrix_Full = matrix_float4x4(columns: (vector_float4(1.15, 0.0, 1.6123, 0.0),
                                                    vector_float4(1.15, -0.395761, -0.821261, 0.0),
                                                    vector_float4(1.15, 2.0378, 0.0, 0.0),
                                                    vector_float4(0.0, 0.0, 0.0, 1.0)))

  var YpCbCrMatrix_Video = matrix_float4x4(columns: (vector_float4(1.1643, 0.0, 1.5958, 0.0),
                                                     vector_float4(1.1643, -0.39173, -0.81290, 0.0),
                                                     vector_float4(1.1643, 2.017, 0.0, 0.0),
                                                     vector_float4(0.0, 0.0, 0.0, 1.0)))

  var YpCbCrOffsets_FullRange = Float4([0.0625, 0.5, 0.5, 0.0])
  var YpCbCrOffsets_VideoRange = Float4([0.0625, 0.5, 0.5, 0.0])

  var YpCbCrMatrixFullRangeBuffer: MTLBuffer!
  var YpCbCrMatrixVideoRangeBuffer: MTLBuffer!

  var YpCbCrOffsets_FullRangeBuffer: MTLBuffer!
  var YpCbCrOffsets_VideoRangeBuffer: MTLBuffer!

  var activeColorTransformMatrixBuffer: MTLBuffer!
  var activeYpCbCrOffsetsBuffer: MTLBuffer!

  var blur: MPSImageGaussianBlur?
  var edgeDetector: MPSImageSobel?

  override init(frame frameRect: CGRect, device: MTLDevice?) {
    super.init(frame: frameRect, device: device)
    configureWithDevice(device!)
  }

  required init(coder: NSCoder) {
    super.init(coder: coder)
    configureWithDevice(MTLCreateSystemDefaultDevice()!)
  }

  private func configureWithDevice(_ device: MTLDevice) {
    self.clearColor = MTLClearColor.init(red: 0, green: 0, blue: 0, alpha: 0)
    self.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    self.framebufferOnly = false
    self.colorPixelFormat = .bgra8Unorm

    self.preferredFramesPerSecond = 0

    self.device = device
  }

  func reset() {
    lockQueue.sync {
      sourceImageSize = nil
      textures = [MTLTexture?](repeating: nil, count: 3)
      pixelFormat = nil
      vertexBuffer = nil

      framesSinceLastUpdate = 0
    }
  }

  private func calculateAspectFitFillRect() -> CGRect? {
    guard let imageSize = sourceImageSize else { return nil }
    var scale: CGFloat
    var scaledRect: CGRect = CGRect()
    if (contentMode == .scaleAspectFit) {
      scale = min(drawableSize.width / imageSize.width, drawableSize.height / imageSize.height)
    } else {
      scale = max(drawableSize.width / imageSize.width, drawableSize.height / imageSize.height)
    }

    scaledRect.origin.x = (drawableSize.width - imageSize.width * scale) / 2;
    scaledRect.origin.y = (drawableSize.height - imageSize.height * scale) / 2;

    scaledRect.size.width = imageSize.width * scale;
    scaledRect.size.height = imageSize.height * scale;

    return scaledRect;
  }

  private func calculateTextureRect() -> CGRect? {
    guard let imageSize = sourceImageSize else { return nil }
    switch (self.contentMode) {
      case .topLeft:
        return CGRect(x: 0,
                      y: 0,
                      width: imageSize.width / self.drawableSize.width,
                      height: imageSize.height / self.drawableSize.height)
      case .top:
        return CGRect(x: (1 - imageSize.width / self.drawableSize.width) / 2,
                      y: 0,
                      width: imageSize.width / self.drawableSize.width,
                      height: imageSize.height / self.drawableSize.height)
      case .topRight:
        return CGRect(x: 1 - imageSize.width / self.drawableSize.width,
                      y: 0,
                      width: imageSize.width / self.drawableSize.width,
                      height: imageSize.height / self.drawableSize.height)
      case .left:
        return CGRect(x: 0,
                      y: (1 - imageSize.height / self.drawableSize.height) / 2,
                      width: imageSize.width / self.drawableSize.width,
                      height: imageSize.height / self.drawableSize.height)
      case .center:
        return CGRect(x: (1 - imageSize.width / self.drawableSize.width) / 2,
                      y: (1 - imageSize.height / self.drawableSize.height) / 2,
                      width: imageSize.width / self.drawableSize.width,
                      height: imageSize.height / self.drawableSize.height)
      case .right:
        return CGRect(x: 1 - imageSize.width / self.drawableSize.width,
                      y: (1 - imageSize.height / self.drawableSize.height) / 2,
                      width: imageSize.width / self.drawableSize.width,
                      height: imageSize.height / self.drawableSize.height)
      case .bottomLeft:
        return CGRect(x: 0,
                      y: 1 - imageSize.height / self.drawableSize.height,
                      width: imageSize.width / self.drawableSize.width,
                      height: imageSize.height / self.drawableSize.height)
      case .bottom:
        return CGRect(x: (1 - imageSize.width / self.drawableSize.width) / 2,
                      y: 1 - imageSize.height / self.drawableSize.height,
                      width: imageSize.width / self.drawableSize.width,
                      height: imageSize.height / self.drawableSize.height)
      case .bottomRight:
        return CGRect(x: 1 - imageSize.width / self.drawableSize.width,
                      y: 1 - imageSize.height / self.drawableSize.height,
                      width: imageSize.width / self.drawableSize.width,
                      height: imageSize.height / self.drawableSize.height)
      case .scaleAspectFit, .scaleAspectFill:
        let fittedRect = calculateAspectFitFillRect()

        return CGRect(x: fittedRect!.origin.x / drawableSize.width,
                      y:fittedRect!.origin.y / drawableSize.height,
                      width: fittedRect!.size.width / drawableSize.width,
                      height:fittedRect!.size.height / drawableSize.height)
      case .scaleToFill:
        return CGRect(x: 0, y: 0, width: 1.0, height: 1.0)
      default:
        Log.error("Unsupported contentMode:", contentMode.rawValue, context: "metal")
        return CGRect()
    }
  }

  private func calculateVertexesForRect(rect: CGRect) -> [Float] {
    var calculatedVertexes: [Float] = []
    let tempRect = CGRect(x: rect.origin.x * 2 - 1,
                          y: 1 - rect.origin.y * 2,
                          width: rect.size.width * 2,
                          height: rect.size.height * 2)

    let top = Float(tempRect.origin.y - tempRect.size.height)
    let left = Float(tempRect.origin.x)
    let right = Float(tempRect.origin.x + tempRect.size.width)
    let bottom = Float(tempRect.origin.y)

    // bottomLeft:
    calculatedVertexes.append(left)
    calculatedVertexes.append(bottom)
    calculatedVertexes.append(Float(0.0))
    calculatedVertexes.append(Float(1.0))

    // bottomRight:
    calculatedVertexes.append(right)
    calculatedVertexes.append(bottom)
    calculatedVertexes.append(Float(0.0))
    calculatedVertexes.append(Float(1.0))

    // topLeft:
    calculatedVertexes.append(left)
    calculatedVertexes.append(top)
    calculatedVertexes.append(Float(0.0))
    calculatedVertexes.append(Float(1.0))

    // topRight:
    calculatedVertexes.append(right)
    calculatedVertexes.append(top)
    calculatedVertexes.append(Float(0.0))
    calculatedVertexes.append(Float(1.0))

    return calculatedVertexes
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    setupVertexBuffer()
    let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                           width: Int(drawableSize.width),
                                                           height: Int(drawableSize.height),
                                                           mipmapped: false)

    intermediateTexture = device.makeTexture(descriptor: texDesc)
  }

  override var contentMode: UIView.ContentMode {
    didSet {
      if contentMode != oldValue {
        setupVertexBuffer()
      }
    }
  }

  private func setupVertexBuffer() {
    let textureRect = calculateTextureRect()

    if textureRect == nil { return }

    let vertexes = calculateVertexesForRect(rect: textureRect!)
    let vertexDataSize = vertexes.count * MemoryLayout.size(ofValue: vertexes[0])
    self.vertexBuffer = device?.makeBuffer(bytes: vertexes, length: vertexDataSize, options: .storageModeShared)
  }

  var sourceImageSize: CGSize? = nil {
    didSet {
      if sourceImageSize != oldValue {
        setupVertexBuffer()
        try? pipelineState = device?.makeRenderPipelineState(descriptor: pipelineDescriptor)
      }
    }
  }

  func generatePermuteTableBuffer(permuteTable: [UInt8]) -> MTLBuffer {
    device!.makeBuffer(bytes: permuteTable, length: permuteTable.count * MemoryLayout.size(ofValue:permuteTable), options: .storageModeShared)!
  }

  override var device: MTLDevice! {
    didSet {
      super.device = device
      commandQueue = (self.device?.makeCommandQueue())!

      library = device?.makeDefaultLibrary()
      pipelineDescriptor.vertexFunction = library?.makeFunction(name: "vertex_passthrough")
      pipelineDescriptor.fragmentFunction = library?.makeFunction(name: "basic_fragment")
      pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

      YpCbCrMatrixFullRangeBuffer = device!.makeBuffer(bytes: &YpCbCrMatrix_Full,
                                                       length: MemoryLayout<matrix_float4x4>.size,
                                                       options: .storageModeShared)
      YpCbCrMatrixVideoRangeBuffer = device!.makeBuffer(bytes: &YpCbCrMatrix_Video,
                                                        length: MemoryLayout<matrix_float4x4>.size,
                                                        options: .storageModeShared)

      YpCbCrOffsets_FullRangeBuffer = device!.makeBuffer(bytes: &YpCbCrOffsets_FullRange,
                                                         length: MemoryLayout<Float4>.size,
                                                         options: .storageModeShared)
      YpCbCrOffsets_VideoRangeBuffer = device!.makeBuffer(bytes: &YpCbCrOffsets_VideoRange,
                                                          length: MemoryLayout<Float4>.size,
                                                          options: .storageModeShared)

      blur = MPSImageGaussianBlur.init(device: device, sigma: 50.0)
      edgeDetector = MPSImageSobel.init(device: device)

      let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                             width: Int(self.bounds.size.width),
                                                             height: Int(self.bounds.size.height),
                                                             mipmapped: false)

      intermediateTexture = device.makeTexture(descriptor: texDesc)
    }
  }

  var pixelFormat: OSType? = nil {
    didSet {
      if pixelFormat == nil || pixelFormat == oldValue { return }

      pipelineDescriptor.fragmentFunction = library?.makeFunction(name: "rgba_fragment")
      permuteTableBuffer = generatePermuteTableBuffer(permuteTable: [0, 1, 2, 3])

      switch (pixelFormat!) {
        case kCVPixelFormatType_420YpCbCr8Planar:           /* Planar Component Y'CbCr 8-bit 4:2:0. */
          activeColorTransformMatrixBuffer = YpCbCrMatrixVideoRangeBuffer
          activeYpCbCrOffsetsBuffer = YpCbCrOffsets_VideoRangeBuffer
          pipelineDescriptor.fragmentFunction = library?.makeFunction(name: "YpCbCr_3P_fragment")
          planeCount = 3
        case kCVPixelFormatType_420YpCbCr8PlanarFullRange:  /* Planar Component Y'CbCr 8-bit 4:2:0, full range.*/
          activeColorTransformMatrixBuffer = YpCbCrMatrixFullRangeBuffer
          activeYpCbCrOffsetsBuffer = YpCbCrOffsets_FullRangeBuffer
          pipelineDescriptor.fragmentFunction = library?.makeFunction(name: "YpCbCr_3P_fragment")
          planeCount = 3
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:   /*  Bi-Planar Component Y'CbCr 8-bit 4:2:0, video-range */
          activeColorTransformMatrixBuffer = YpCbCrMatrixVideoRangeBuffer
          activeYpCbCrOffsetsBuffer = YpCbCrOffsets_VideoRangeBuffer
          pipelineDescriptor.fragmentFunction = library?.makeFunction(name: "YpCbCr_2P_fragment")
          planeCount = 2;
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:    /* Bi-Planar Component Y'CbCr 8-bit 4:2:0, full-range */
          activeColorTransformMatrixBuffer = YpCbCrMatrixFullRangeBuffer
          activeYpCbCrOffsetsBuffer = YpCbCrOffsets_FullRangeBuffer
          pipelineDescriptor.fragmentFunction = library?.makeFunction(name: "YpCbCr_2P_fragment")
          planeCount = 2;
        case kCVPixelFormatType_4444YpCbCrA8:   /* Component Y'CbCrA 8-bit 4:4:4:4, ordered Cb Y' Cr A */
          activeColorTransformMatrixBuffer = YpCbCrMatrixFullRangeBuffer
          activeYpCbCrOffsetsBuffer = YpCbCrOffsets_FullRangeBuffer
          planeCount = 1;
        case kCVPixelFormatType_4444AYpCbCr8:   /* Component Y'CbCrA 8-bit 4:4:4:4, ordered A Y' Cb Cr, full range alpha, video range Y'CbCr. */
          activeColorTransformMatrixBuffer = YpCbCrMatrixVideoRangeBuffer
          activeYpCbCrOffsetsBuffer = YpCbCrOffsets_VideoRangeBuffer
          planeCount = 1;
        case kCVPixelFormatType_422YpCbCr8:   /* Component Y'CbCr 8-bit 4:2:2, ordered Cb Y'0 Cr Y'1 */
          activeColorTransformMatrixBuffer = YpCbCrMatrixVideoRangeBuffer
          activeYpCbCrOffsetsBuffer = YpCbCrOffsets_VideoRangeBuffer
          pipelineDescriptor.fragmentFunction = library?.makeFunction(name: "YpCbCr_1P_fragment")
          planeCount = 1;
        case kCVPixelFormatType_32ARGB:     /* 32 bit ARGB */
          planeCount = 1;
          permuteTableBuffer = generatePermuteTableBuffer(permuteTable: [3, 2, 1, 0])
        case kCVPixelFormatType_32BGRA:     /* 32 bit BGRA */
          planeCount = 1;
          permuteTableBuffer = generatePermuteTableBuffer(permuteTable: [2, 1, 0, 3])
        case kCVPixelFormatType_32ABGR:     /* 32 bit ABGR */
          planeCount = 1;
          permuteTableBuffer = generatePermuteTableBuffer(permuteTable: [3, 2, 1, 0])
        case kCVPixelFormatType_24BGR, kCVPixelFormatType_24RGB:
          pipelineDescriptor.fragmentFunction = library?.makeFunction(name: "rgb24_fragment")
          planeCount = 1;
          permuteTableBuffer = generatePermuteTableBuffer(permuteTable: [3, 2, 1, 0])
        case kCVPixelFormatType_32RGBA:     /* 32 bit RGBA */
          planeCount = 1;
        case kCVPixelFormatType_16LE555:      /* 16 bit BE RGB 555 */
          planeCount = 1;
        case kCVPixelFormatType_16LE5551:     /* 16 bit LE RGB 5551 */
          planeCount = 1;
        case kCVPixelFormatType_16LE565:      /* 16 bit BE RGB 565 */
          planeCount = 1;
        default:
          Log.error("Unsupported pixel format", pixelFormat, context: "metal")
          return
      }

      try? pipelineState = device?.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
  }

  override func draw(_ rect: CGRect) {
    let commandBuffer = commandQueue!.makeCommandBuffer()
    let renderPassDescriptor = self.currentRenderPassDescriptor!

    if textures[0] == nil || vertexBuffer == nil || sourceImageSize == nil {
      Log.error("Texture or vertex buffer haven't been generated. Please ensure .sourceImageSize, .pixelFormat and .planeDescriptors are set with valid parameters.", context: "metal")
      return
    }

    if let renderEncoder = commandBuffer!.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
      renderEncoder.setVertexBuffer(self.vertexBuffer, offset: 0, index: 0)

      for plane in 0..<planeCount! {
        renderEncoder.setFragmentTexture(textures[plane], index: plane)
      }

      if permuteTableBuffer != nil {
        renderEncoder.setFragmentBuffer(permuteTableBuffer, offset: 0, index: 0)
      }

      if activeColorTransformMatrixBuffer != nil {
        renderEncoder.setFragmentBuffer(activeColorTransformMatrixBuffer, offset: 0, index: 1)
      }

      if activeYpCbCrOffsetsBuffer != nil {
        renderEncoder.setFragmentBuffer(activeYpCbCrOffsetsBuffer, offset: 0, index: 2)
      }

      renderEncoder.setRenderPipelineState(pipelineState)
      renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
      renderEncoder.endEncoding()
    }

    commandBuffer!.present(self.currentDrawable!)
    commandBuffer!.commit()
  }
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertFromNSAttributedStringKey(_ input: NSAttributedString.Key) -> String {
  return input.rawValue
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertToOptionalNSAttributedStringKeyDictionary(_ input: [String: Any]?) -> [NSAttributedString.Key: Any]? {
  guard let input = input else { return nil }
  return Dictionary(uniqueKeysWithValues: input.map { key, value in (NSAttributedString.Key(rawValue: key), value)})
}
