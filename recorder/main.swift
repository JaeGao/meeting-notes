// Meeting Recorder: records a screen (or part of one, or no picture at all), the Mac's
// sound and the microphone to one file with ScreenCaptureKit. No window; it is driven by gui.py.
//
//   meeting-recorder --out <file.mov> --state <state.json> [--cmd <cmd.json>] [--no-mic]
//                    [--display <id> | --window <id> | --no-screen] [--rect x,y,w,h]
//   meeting-recorder --list --dir <folder>
//
// --rect is in points from the top left of the chosen display. --list writes
// sources.json and a preview picture of every screen and open window into the folder.
//
// While recording, SIGUSR1 makes it read <cmd.json> and switch what is recorded:
//   {"display": id, "rect": [x,y,w,h]} | {"window": id} | {"none": true}
// The picture's size is set at the start; a later source is fitted inside it. A recording
// that never had a picture is saved as .m4a instead of .mov; the state file's "out" says which.
//
// Stops cleanly on SIGINT or SIGTERM. Progress is written to the state file as JSON.
import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

var outPath = ""
var statePath = ""
var cmdPath = ""
var noScreen = false
var wantMic = true
var listDir = ""
var displayID: UInt32?
var windowID: UInt32?
var cropRect: CGRect?
var args = Array(CommandLine.arguments.dropFirst())

// Opened by hand (from Finder or Spotlight) there is nothing to record and no window to
// show, so open the Meeting Notes page instead of quitting silently.
if !args.contains("--out") && !args.contains("--list") && !args.contains("--dir") {
    let notes = URL(fileURLWithPath: "/Applications/Meeting Notes.app")
    if FileManager.default.fileExists(atPath: notes.path) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [notes.path]
        try? p.run()
        p.waitUntilExit()
    }
    exit(0)
}
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--out": outPath = args.isEmpty ? "" : args.removeFirst()
    case "--state": statePath = args.isEmpty ? "" : args.removeFirst()
    case "--no-mic": wantMic = false
    case "--no-screen": noScreen = true
    case "--cmd": cmdPath = args.isEmpty ? "" : args.removeFirst()
    case "--list": listDir = "."
    case "--dir": listDir = args.isEmpty ? "" : args.removeFirst()
    case "--display": displayID = args.isEmpty ? nil : UInt32(args.removeFirst())
    case "--window": windowID = args.isEmpty ? nil : UInt32(args.removeFirst())
    case "--rect":
        let n = (args.isEmpty ? "" : args.removeFirst()).split(separator: ",").compactMap { Double($0) }
        if n.count == 4 { cropRect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
    default: break
    }
}

// Connect to the window server first. Without this, making a filter for a single window
// aborts inside ScreenCaptureKit (SLSGetDisplaysWithRect assertion).
_ = NSApplication.shared

let startedAt = Date()
func writeState(_ state: String, error: String? = nil, extra: [String: Any] = [:]) {
    guard !statePath.isEmpty else { return }
    var d: [String: Any] = [
        "state": state, "pid": ProcessInfo.processInfo.processIdentifier, "out": outPath,
        "started": startedAt.timeIntervalSince1970, "updated": Date().timeIntervalSince1970,
    ]
    if let error { d["error"] = error }
    for (k, v) in extra { d[k] = v }
    if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }
}
func fail(_ message: String, code: Int32 = 1) -> Never {
    writeState("error", error: message)
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

/// What to record: a whole screen, part of one, the place a window sits, or no picture.
struct Choice {
    var none = false
    var displayID: UInt32?
    var windowID: UInt32?
    var rect: CGRect?
}

final class Recorder: NSObject, SCStreamDelegate, SCStreamOutput {
    var stream: SCStream?
    var config = SCStreamConfiguration()
    var micOn = false
    var stopping = false
    var source = "display"

    // Everything below is touched only on `q`.
    let q = DispatchQueue(label: "write")
    var writer: AVAssetWriter?
    var videoIn: AVAssetWriterInput?
    var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    var soundIn: AVAssetWriterInput?
    var micIn: AVAssetWriterInput?
    var sessionStarted = false
    var finishing = false
    var screenOn = true       // false while recording sound only
    var everScreen = false    // a picture was recorded at some point
    var needBlack = false     // the next sample should put a black picture in the file
    var lastTime = CMTime.invalid
    let black = CGColor(gray: 0, alpha: 1)  // kept here: the configuration does not hold on to it

    /// The filter, the part of it to record (in points) and the name of the kind of source.
    func resolve(_ c: Choice, in content: SCShareableContent) -> (SCContentFilter, CGRect, String)? {
        var wanted = c.displayID ?? CGMainDisplayID()
        var crop = c.rect
        var kind = c.none ? "none" : "display"
        // A filter for one window records only that app's sound, so a window is recorded
        // as the part of its screen where it sits now. The Mac's whole sound is kept.
        if !c.none, let wid = c.windowID {
            guard let win = content.windows.first(where: { $0.windowID == wid }) else { return nil }
            let mid = CGPoint(x: win.frame.midX, y: win.frame.midY)
            guard let home = content.displays.first(where: { $0.frame.contains(mid) }) ?? content.displays.first
            else { return nil }
            wanted = home.displayID
            crop = win.frame.offsetBy(dx: -home.frame.minX, dy: -home.frame.minY)
            kind = "window"
        }
        guard let display = content.displays.first(where: { $0.displayID == wanted }) ?? content.displays.first
        else { return nil }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        var area = CGRect(origin: .zero, size: filter.contentRect.size)
        if !c.none, let r = crop {
            area = r.intersection(area)
            if area.width < 40 || area.height < 40 { return nil }
            if kind == "display" { kind = "area" }
        }
        return (filter, area, kind)
    }

    func start(_ first: Choice) async {
        if outPath.isEmpty { fail("no --out file given") }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            fail("Screen recording is not allowed yet. Open System Settings > Privacy & Security > "
                + "Screen & System Audio Recording, turn on Meeting Recorder, then press Record again.", code: 2)
        }
        if wantMic {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: micOn = true
            case .notDetermined: micOn = await AVCaptureDevice.requestAccess(for: .audio)
            default: micOn = false
            }
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let (filter, area, kind) = resolve(first, in: content) else {
                fail(first.windowID != nil ? "That window is no longer open. Choose what to record again."
                    : "The chosen screen or area could not be recorded. Choose what to record again.")
            }
            source = kind
            // The picture's size is fixed for the whole file. Whatever is switched to later
            // is fitted inside it, so the file stays one ordinary video.
            let scale = CGFloat(filter.pointPixelScale)
            var w = area.width * scale
            var h = area.height * scale
            let longSide = max(w, h)
            if longSide > 1920 { w = w * 1920 / longSide; h = h * 1920 / longSide }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(w) / 2 * 2
            cfg.height = Int(h) / 2 * 2
            cfg.sourceRect = area
            cfg.scalesToFit = true
            cfg.backgroundColor = black
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            cfg.showsCursor = true
            cfg.capturesAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = true
            if micOn { cfg.captureMicrophone = true }
            config = cfg

            try? FileManager.default.removeItem(atPath: outPath)
            let wr = try AVAssetWriter(outputURL: URL(fileURLWithPath: outPath), fileType: .mov)
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: cfg.width, AVVideoHeightKey: cfg.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 2_500_000, AVVideoMaxKeyFrameIntervalDurationKey: 4,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
            vIn.expectsMediaDataInRealTime = true
            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: cfg.width, kCVPixelBufferHeightKey as String: cfg.height,
            ])
            func audioInput(channels: Int, rate: Int) -> AVAssetWriterInput {
                let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: rate,
                ])
                a.expectsMediaDataInRealTime = true
                return a
            }
            let sIn = audioInput(channels: 2, rate: 160_000)
            wr.add(vIn); wr.add(sIn)
            var mIn: AVAssetWriterInput?
            if micOn { let m = audioInput(channels: 1, rate: 96_000); wr.add(m); mIn = m }
            guard wr.startWriting() else {
                fail("Recording could not start: \(wr.error?.localizedDescription ?? "the file could not be opened")")
            }
            q.sync {
                writer = wr; videoIn = vIn; adaptor = ad; soundIn = sIn; micIn = mIn
                screenOn = kind != "none"; everScreen = screenOn; needBlack = !screenOn
            }

            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
            if micOn { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: q) }
            stream = s
            try await s.startCapture()
            report()
        } catch {
            fail("Recording could not start: \(error.localizedDescription)")
        }
    }

    func report(_ state: String = "recording", note: String? = nil) {
        var extra: [String: Any] = ["mic": micOn, "width": config.width, "height": config.height, "source": source]
        if let note { extra["switchError"] = note; extra["switchAt"] = Date().timeIntervalSince1970 }
        writeState(state, extra: extra)
    }

    /// Changes what is recorded while the recording runs. A failure keeps what was recorded before.
    func switchTo(_ c: Choice) async {
        guard let stream, !stopping else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let (filter, area, kind) = resolve(c, in: content) else {
                report(note: c.windowID != nil ? "That window is no longer open, so the recording was not changed."
                    : "That screen or area could not be recorded, so the recording was not changed.")
                return
            }
            if kind == "none" {
                q.sync { screenOn = false; needBlack = true }
            } else {
                let cfg = config
                cfg.sourceRect = area
                try await stream.updateContentFilter(filter)
                try await stream.updateConfiguration(cfg)
                q.sync { screenOn = true; everScreen = true; needBlack = false }
            }
            source = kind
            report()
        } catch {
            report(note: "The recording was not changed: \(error.localizedDescription)")
        }
    }

    func blackFrame() -> CVPixelBuffer? {
        guard let pool = adaptor?.pixelBufferPool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    // Called on `q` for every picture and every piece of sound.
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let writer, !finishing, writer.status == .writing, CMSampleBufferDataIsReady(sb) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sb)
        guard t.isValid else { return }
        var picture: CVPixelBuffer?
        if type == .screen {
            // Only whole new pictures; "idle" samples just say nothing changed on screen.
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            picture = pb
        }
        if !sessionStarted {
            writer.startSession(atSourceTime: t)
            sessionStarted = true
        }
        if !lastTime.isValid || t > lastTime { lastTime = t }
        // Going to sound only puts one black picture in the file, so the last screen does
        // not stay frozen on it. It rides on whatever sample comes next, sound included.
        if needBlack, let v = videoIn, v.isReadyForMoreMediaData, laterThanLastPicture(t), let black = blackFrame() {
            if adaptor?.append(black, withPresentationTime: t) == true { needBlack = false; lastPicture = t }
        }
        switch type {
        case .screen:
            if screenOn, let picture, let v = videoIn, v.isReadyForMoreMediaData, laterThanLastPicture(t) {
                if adaptor?.append(picture, withPresentationTime: t) == true { lastPicture = t }
            }
        case .audio:
            if let a = soundIn, a.isReadyForMoreMediaData { a.append(sb) }
        case .microphone:
            if let a = micIn, a.isReadyForMoreMediaData { a.append(sb) }
        @unknown default: break
        }
    }
    var lastPicture = CMTime.invalid
    func laterThanLastPicture(_ t: CMTime) -> Bool { !lastPicture.isValid || t > lastPicture }

    func stop() {
        if stopping { return }
        stopping = true
        report("stopping")
        Task {
            try? await self.stream?.stopCapture()
            let (wr, started, end, hadScreen): (AVAssetWriter?, Bool, CMTime, Bool) = q.sync {
                finishing = true
                return (writer, sessionStarted, lastTime, everScreen)
            }
            guard let wr, started, wr.status == .writing else {
                wr?.cancelWriting()
                fail("Nothing was recorded: \(wr?.error?.localizedDescription ?? "no picture or sound arrived").")
            }
            self.videoIn?.markAsFinished(); self.soundIn?.markAsFinished(); self.micIn?.markAsFinished()
            if end.isValid { wr.endSession(atSourceTime: end) }
            await wr.finishWriting()
            if wr.status != .completed {
                fail("The recording could not be finished: \(wr.error?.localizedDescription ?? "unknown error"). The file so far may still open.")
            }
            if !hadScreen { await self.keepSoundOnly() }
            self.report("finished")
            exit(0)
        }
    }

    /// A recording with no picture at all is kept as a sound file (.m4a), not a black video.
    func keepSoundOnly() async {
        let mov = URL(fileURLWithPath: outPath)
        let m4a = mov.deletingPathExtension().appendingPathExtension("m4a")
        let asset = AVURLAsset(url: mov)
        let mix = AVMutableComposition()
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let length = try? await asset.load(.duration) else { return }
        for t in tracks {
            let to = mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            guard let range = try? await t.load(.timeRange) else { continue }
            try? to?.insertTimeRange(CMTimeRange(start: range.start, duration: min(range.duration, length)), of: t, at: range.start)
        }
        // Copy the sound as it is when the file allows it. With the microphone there are two
        // tracks, which an .m4a made this way refuses, so then they are mixed into one.
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
            guard let export = AVAssetExportSession(asset: mix, presetName: preset) else { continue }
            try? FileManager.default.removeItem(at: m4a)
            do {
                try await export.export(to: m4a, as: .m4a)
                try? FileManager.default.removeItem(at: mov)
                outPath = m4a.path
                return
            } catch {
                try? FileManager.default.removeItem(at: m4a)
            }
        }
        // Neither worked: the .mov stays. It has all the sound, under a black picture.
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if stopping { return }
        fail("Recording stopped: \(error.localizedDescription). The file so far may still open.")
    }
}

// ---------- --list: what can be recorded, with a preview picture of each ----------

func savePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func preview(_ filter: SCContentFilter, maxSide: CGFloat, to path: String) async -> Bool {
    let size = filter.contentRect.size
    guard size.width > 0, size.height > 0 else { return false }
    let k = min(1, maxSide / max(size.width, size.height)) * min(2, CGFloat(filter.pointPixelScale))
    let cfg = SCStreamConfiguration()
    cfg.width = max(2, Int(size.width * k))
    cfg.height = max(2, Int(size.height * k))
    cfg.showsCursor = false
    guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    else { return false }
    savePNG(img, to: path)
    return true
}

func listSources() async {
    let out = URL(fileURLWithPath: listDir).appendingPathComponent("sources.json")
    func finish(_ obj: [String: Any], code: Int32) -> Never {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? data.write(to: out, options: .atomic)
        }
        exit(code)
    }
    if !CGPreflightScreenCaptureAccess() {
        CGRequestScreenCaptureAccess()
        finish(["error": "Screen recording is not allowed yet. Open System Settings > Privacy & Security > "
            + "Screen & System Audio Recording, turn on Meeting Recorder, then try again."], code: 2)
    }
    guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    else { finish(["error": "Could not read the list of screens and windows."], code: 1) }
    var displays: [[String: Any]] = []
    for (i, d) in content.displays.enumerated() {
        let f = SCContentFilter(display: d, excludingApplications: [], exceptingWindows: [])
        let name = "display-\(d.displayID).png"
        let ok = await preview(f, maxSide: 1100, to: listDir + "/" + name)
        displays.append(["id": d.displayID, "width": d.width, "height": d.height,
                         "main": d.displayID == CGMainDisplayID(), "number": i + 1,
                         "thumb": ok ? name : ""])
    }
    let me = Bundle.main.bundleIdentifier ?? ""
    var windows: [[String: Any]] = []
    let candidates = content.windows.filter { w in
        w.windowLayer == 0 && w.isOnScreen && w.frame.width >= 240 && w.frame.height >= 160
            && !(w.title ?? "").isEmpty && w.owningApplication != nil
            && w.owningApplication?.bundleIdentifier != me
    }
    for w in candidates.prefix(40) {
        let f = SCContentFilter(desktopIndependentWindow: w)
        let name = "window-\(w.windowID).png"
        let ok = await preview(f, maxSide: 420, to: listDir + "/" + name)
        windows.append(["id": w.windowID, "title": w.title ?? "", "app": w.owningApplication?.applicationName ?? "",
                        "width": Int(w.frame.width), "height": Int(w.frame.height), "thumb": ok ? name : ""])
    }
    finish(["displays": displays, "windows": windows, "at": Date().timeIntervalSince1970], code: 0)
}

if !listDir.isEmpty {
    Task { await listSources() }
    RunLoop.main.run()
}

let recorder = Recorder()
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
signal(SIGUSR1, SIG_IGN)
var sources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { recorder.stop() }
    src.resume()
    sources.append(src)
}

/// Reads the switch command gui.py left in the command file.
func readCommand() -> Choice? {
    guard !cmdPath.isEmpty, let data = FileManager.default.contents(atPath: cmdPath),
          let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    var c = Choice()
    c.none = d["none"] as? Bool ?? false
    if let n = d["display"] as? NSNumber { c.displayID = n.uint32Value }
    if let n = d["window"] as? NSNumber { c.windowID = n.uint32Value }
    if let r = d["rect"] as? [NSNumber], r.count == 4 {
        c.rect = CGRect(x: r[0].doubleValue, y: r[1].doubleValue, width: r[2].doubleValue, height: r[3].doubleValue)
    }
    return (c.none || c.displayID != nil || c.windowID != nil) ? c : nil
}
let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
usr1.setEventHandler {
    guard let c = readCommand() else { return }
    Task { await recorder.switchTo(c) }
}
usr1.resume()
sources.append(usr1)

writeState("starting")
var first = Choice()
first.none = noScreen
first.displayID = displayID
first.windowID = windowID
first.rect = cropRect
Task { await recorder.start(first) }
RunLoop.main.run()
