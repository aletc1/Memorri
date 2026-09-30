import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Throwaway spike for spec 003 (task T001). Not committed. Uses only a synthetic picture.

struct Args {
    var seed = 0, size = 2048, think = "false", mode = "native", format = "jpeg", runs = 1, repair = false, label = ""
    var model = "qwen3.8:27b-mlx", url = "http://localhost:11434", timeout = 1200.0
}
var a = Args()
var it = CommandLine.arguments.dropFirst().makeIterator()
while let k = it.next() {
    switch k {
    case "--size": a.size = Int(it.next()!)!
    case "--seed": a.seed = Int(it.next()!)!
    case "--think": a.think = it.next()!
    case "--mode": a.mode = it.next()!
    case "--format": a.format = it.next()!
    case "--runs": a.runs = Int(it.next()!)!
    case "--repair": a.repair = true
    case "--label": a.label = it.next()!
    case "--model": a.model = it.next()!
    case "--timeout": a.timeout = Double(it.next()!)!
    default: break
    }
}

func drawPicture(longSide: Int) -> CGImage {
    let w = longSide, h = longSide * 9 / 16
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let cols = 5, colW = CGFloat(w) / CGFloat(cols)
    let days = ["Mon", "Tue", "Wed", "Thu", "Fri"]
    let fontSize = max(14, CGFloat(w) / 42)
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat = 0, white: Bool = false) {
        let f = size > 0 ? CTFontCreateWithName("Helvetica" as CFString, size, nil) : font
        let color = white ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, ctx)
    }
    ctx.setStrokeColor(CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)); ctx.setLineWidth(max(1, CGFloat(w) / 1024))
    for c in 0...cols { let x = CGFloat(c) * colW; ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: CGFloat(h))); ctx.strokePath() }
    for (i, d) in days.enumerated() { text(d, x: CGFloat(i) * colW + fontSize, y: CGFloat(h) - fontSize * 2) }
    // One event block on Wednesday
    let bx = 2 * colW + colW * 0.06, bw = colW * 0.88, by = CGFloat(h) * 0.40, bh = CGFloat(h) * 0.22
    ctx.setFillColor(CGColor(red: 0.12, green: 0.45, blue: 0.85, alpha: 1)); ctx.fill(CGRect(x: bx, y: by, width: bw, height: bh))
    text("Team sync", x: bx + fontSize * 0.6, y: by + bh - fontSize * 1.6, size: fontSize * 1.2, white: true)
    text("10:00", x: bx + fontSize * 0.6, y: by + bh - fontSize * 3.0, size: fontSize * 1.1, white: true)
    if a.seed != 0 { // a small dot at a seed-dependent place makes the picture new to the server
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: CGFloat((a.seed * 37) % (w - 20)), y: 4, width: 12, height: 12))
    }
    return ctx.makeImage()!
}

func encode(_ img: CGImage, format: String) -> Data {
    let type = format == "png" ? "public.png" : format == "heic" ? "public.heic" : "public.jpeg"
    let d = NSMutableData()
    let dest = CGImageDestinationCreateWithData(d, type as CFString, 1, nil)!
    let opts: CFDictionary? = format == "png" ? nil : [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
    CGImageDestinationAddImage(dest, img, opts)
    precondition(CGImageDestinationFinalize(dest))
    return d as Data
}

let schema: [String: Any] = [
    "type": "object",
    "properties": ["description": ["type": "string"], "contains_text": ["type": "boolean"], "text_sample": ["type": "string"]],
    "required": ["description", "contains_text", "text_sample"],
    "additionalProperties": false]
let basePrompt = "Describe this picture in one or two sentences. Say whether it contains readable text, and copy a short sample of any text you can read."
let schemaText = String(data: try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), encoding: .utf8)!

func valid(_ content: String) -> (Bool, Bool, String) {
    guard let data = content.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (false, false, "not JSON") }
    guard Set(obj.keys) == ["description", "contains_text", "text_sample"] else { return (false, false, "keys \(obj.keys.sorted())") }
    guard let d = obj["description"] as? String, obj["contains_text"] is Bool, let t = obj["text_sample"] as? String else { return (false, false, "types") }
    let hay = (d + " " + t).lowercased()
    return (true, hay.contains("team sync") || hay.contains("10:00"), "")
}

func post(_ body: [String: Any]) -> (Int, [String: Any]?, String, Double) {
    var req = URLRequest(url: URL(string: a.url + "/api/chat")!)
    req.httpMethod = "POST"; req.httpBody = try! JSONSerialization.data(withJSONObject: body); req.timeoutInterval = a.timeout
    let cfg = URLSessionConfiguration.ephemeral; cfg.timeoutIntervalForRequest = a.timeout; cfg.timeoutIntervalForResource = a.timeout + 30
    let session = URLSession(configuration: cfg)
    let sem = DispatchSemaphore(value: 0)
    var status = 0, json: [String: Any]?, err = ""
    let t0 = Date()
    session.dataTask(with: req) { data, resp, error in
        status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if let error { err = error.localizedDescription }
        if let data { json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]; if json == nil { err = String(data: data, encoding: .utf8)?.prefix(200).description ?? "" } }
        sem.signal()
    }.resume()
    sem.wait()
    return (status, json, err, Date().timeIntervalSince(t0) * 1000)
}

let picture = encode(drawPicture(longSide: a.size), format: a.format)
for run in 1...a.runs {
    var prompt = basePrompt
    if a.mode == "fallback" { prompt += " Answer with JSON only, matching exactly this JSON schema: \(schemaText)" }
    if a.repair { prompt += " Your previous answer was not valid for this schema. Answer with JSON only." }
    var body: [String: Any] = [
        "model": a.model, "stream": false, "options": ["temperature": 0],
        "messages": [["role": "user", "content": prompt, "images": [picture.base64EncodedString()]]]]
    if a.mode == "native" { body["format"] = schema }
    switch a.think {
    case "none": break
    case "false": body["think"] = false
    case "true": body["think"] = true
    default: body["think"] = a.think
    }
    let (status, json, err, wallMs) = post(body)
    let msg = json?["message"] as? [String: Any]
    let content = (msg?["content"] as? String) ?? ""
    let thinking = (msg?["thinking"] as? String) ?? ""
    let (ok, correct, why) = valid(content)
    func ms(_ k: String) -> Int { Int(((json?[k] as? NSNumber)?.doubleValue ?? 0) / 1_000_000) }
    let out: [String: Any] = [
        "label": a.label, "size": a.size, "format": a.format, "think": a.think, "mode": a.mode, "repair": a.repair, "run": run,
        "bytes": picture.count, "http": status, "valid": ok, "correct": correct, "why": why, "wallMs": Int(wallMs),
        "totalMs": ms("total_duration"), "loadMs": ms("load_duration"), "promptEvalMs": ms("prompt_eval_duration"),
        "evalMs": ms("eval_duration"), "promptTokens": (json?["prompt_eval_count"] as? Int) ?? 0, "evalCount": (json?["eval_count"] as? Int) ?? 0,
        "thinkingChars": thinking.count, "contentChars": content.count, "doneReason": (json?["done_reason"] as? String) ?? "",
        "error": (json?["error"] as? String) ?? err, "sample": String(content.prefix(160))]
    print(String(data: try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
    fflush(stdout)
}
