//
//  EECVImageBufferViewer.swift
//  eldade_metal_tests
//
//  Created by Eldad Eilam on 10/27/16.
//  Copyright © 2016 Eldad Eilam. All rights reserved.
//

import UIKit
import Foundation
import Metal
import CoreVideo

class EECVImageBufferViewer: EEPixelBufferViewer {

  private var textureCache: CVMetalTextureCache?

  override init(frame frameRect: CGRect, device: MTLDevice?) {
    super.init(frame: frameRect, device: device)
    initializeCVImageBufferViewer()
  }

  required init(coder: NSCoder) {
    super.init(coder: coder)
  }

  override func reset() {
    super.reset()
    CVMetalTextureCacheFlush(textureCache!, 0)
  }

  override var device: MTLDevice! {
    didSet { initializeCVImageBufferViewer() }
  }

  func initializeCVImageBufferViewer() {
    var newTextureCache: CVMetalTextureCache?
    let result = CVMetalTextureCacheCreate(nil, nil, device, nil, &newTextureCache)

    if result == kCVReturnSuccess {
      textureCache = newTextureCache!
    } else {
      Log.error("Failed to create CV texture cache!", context: "metal")
    }
  }

  func update(imageBuffer: CVImageBuffer) {
    var metalPixelFormat: MTLPixelFormat

    let imageBufferPixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)

    pixelFormat = imageBufferPixelFormat

    var planes = CVPixelBufferGetPlaneCount(imageBuffer)

    if planes == 0 { planes = 1 }

    for planeIndex in 0..<planes {
      let width = CVPixelBufferGetWidthOfPlane(imageBuffer, planeIndex)
      let height = CVPixelBufferGetHeightOfPlane(imageBuffer, planeIndex)

      switch imageBufferPixelFormat {
        case kCVPixelFormatType_16LE555:
          metalPixelFormat = .bgr5A1Unorm
        case kCVPixelFormatType_32RGBA:
          metalPixelFormat = .rgba8Unorm
//        case kCVPixelFormatType_32ABGR:
//          metalPixelFormat = .abgr8Unorm
//        case kCVPixelFormatType_32ARGB:
//          metalPixelFormat = .argb8Unorm
        case kCVPixelFormatType_32BGRA:
          metalPixelFormat = .rgba8Unorm
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
          metalPixelFormat = planeIndex == 0 ? .r8Unorm : .rg8Unorm
        default:
          assert(false, "EECVImageBufferViewer.presentCVImageBuffer(): Unsupported pixel format \(imageBufferPixelFormat)")
          metalPixelFormat = .invalid
      }

      var cvTexture: CVMetalTexture?
      let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache!, imageBuffer, nil, metalPixelFormat, width, height, planeIndex, &cvTexture)
      if status != kCVReturnSuccess { return }
      textures[planeIndex] = CVMetalTextureGetTexture(cvTexture!)
    }
    draw()
  }
}
