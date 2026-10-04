// Cut the main subject out of every frame of a GIF using Apple's Vision
// foreground-instance mask, crop all frames to their shared bounding box,
// and write a transparent PNG sequence plus frame delays.
//
// usage: swift tools/cutout.swift <input.gif> <output_dir>
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("usage: cutout <input.gif> <output_dir>") }
let inURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil) else { fatalError("cannot open \(inURL.path)") }
let count = CGImageSourceGetCount(src)
let ctx = CIContext()

func delay(_ i: Int) -> Double {
    let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
    let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
    return d < 0.02 ? 0.1 : d
}

var frames: [CIImage] = []
var delays: [Double] = []
var union = CGRect.null

for i in 0..<count {
    guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
    let handler = VNImageRequestHandler(cgImage: cg)
    let req = VNGenerateForegroundInstanceMaskRequest()
    try handler.perform([req])
    guard let obs = req.results?.first, !obs.allInstances.isEmpty else {
        FileHandle.standardError.write("frame \(i): no subject\n".data(using: .utf8)!)
        continue
    }
    let masked = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: false)
    let img = CIImage(cvPixelBuffer: masked)
    // bounding box of non-transparent pixels via the mask
    let maskBuf = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
    let mask = CIImage(cvPixelBuffer: maskBuf)
    if let bbox = alphaBounds(mask) { union = union.union(bbox) }
    frames.append(img)
    delays.append(delay(i))
}

func alphaBounds(_ mask: CIImage) -> CGRect? {
    let ext = mask.extent
    guard let cg = CIContext().createCGImage(mask, from: ext) else { return nil }
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h)
    let cs = CGColorSpaceCreateDeviceGray()
    guard let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: cs, bitmapInfo: 0) else { return nil }
    c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h { for x in 0..<w where px[y * w + x] > 40 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    guard maxX >= 0 else { return nil }
    // CGContext rows are top-down in memory; convert to CI (bottom-up) coords
    return CGRect(x: minX, y: h - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
}

guard !frames.isEmpty else { fatalError("no frames with a subject") }
let crop = union.insetBy(dx: -4, dy: -4).integral
for (i, f) in frames.enumerated() {
    let cropped = f.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    let url = outDir.appendingPathComponent(String(format: "%03d.png", i))
    try ctx.writePNGRepresentation(of: cropped, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
}
let meta: [String: Any] = ["frames": frames.count, "delays": delays, "width": Int(crop.width), "height": Int(crop.height)]
try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]).write(to: outDir.appendingPathComponent("meta.json"))
print("\(inURL.lastPathComponent): \(frames.count)/\(count) frames, \(Int(crop.width))x\(Int(crop.height))")
