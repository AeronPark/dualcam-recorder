import AVFoundation
import Photos
import SwiftUI
import CoreImage

/// MultiCamManager - Records portrait (9:16) and landscape (16:9) simultaneously
/// Portrait: MovieFileOutput from wide camera (simple)
/// Landscape: VideoDataOutput from ultra-wide + cropping + AssetWriter (for true landscape content)
@MainActor
class MultiCamManager: NSObject, ObservableObject {
    
    // MARK: - Published State
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var permissionGranted = false
    @Published var isSessionRunning = false
    @Published var errorMessage: String?
    
    // MARK: - Session & Devices
    private var multiCamSession: AVCaptureMultiCamSession?
    private var wideCamera: AVCaptureDevice?      // For portrait (9:16)
    private var ultraWideCamera: AVCaptureDevice? // For landscape (16:9)
    
    // MARK: - Portrait Output (simple MovieFileOutput)
    private var portraitMovieOutput: AVCaptureMovieFileOutput?
    private var portraitURL: URL?
    private var portraitFinished = false
    
    // MARK: - Landscape Output (VideoDataOutput + AssetWriter for cropping)
    private var landscapeVideoOutput: AVCaptureVideoDataOutput?
    private var landscapeAudioOutput: AVCaptureAudioDataOutput?
    private let landscapeQueue = DispatchQueue(label: "com.dualcam.landscape")
    private let audioQueue = DispatchQueue(label: "com.dualcam.audio")
    
    // Asset writer for landscape (nonisolated for background queue access)
    private let writerLock = NSLock()
    private nonisolated(unsafe) var landscapeWriter: AVAssetWriter?
    private nonisolated(unsafe) var landscapeVideoInput: AVAssetWriterInput?
    private nonisolated(unsafe) var landscapeAudioInput: AVAssetWriterInput?
    private nonisolated(unsafe) var landscapePixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private nonisolated(unsafe) var landscapeURL: URL?
    private nonisolated(unsafe) var landscapeWritingStarted = false
    private nonisolated(unsafe) var landscapeSessionStartTime: CMTime?
    private nonisolated(unsafe) var ciContext: CIContext?
    
    private var landscapeFinished = false
    
    // MARK: - Recording State
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    
    // MARK: - Preview Layers
    var portraitPreviewLayer: AVCaptureVideoPreviewLayer?
    var landscapePreviewLayer: AVCaptureVideoPreviewLayer?
    
    // MARK: - Initialization
    override init() {
        super.init()
        discoverCameras()
    }
    
    // MARK: - Camera Discovery
    private func discoverCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera],
            mediaType: .video,
            position: .back
        )
        
        for device in discovery.devices {
            switch device.deviceType {
            case .builtInWideAngleCamera:
                wideCamera = device
                print("📷 Found wide camera: \(device.localizedName)")
            case .builtInUltraWideCamera:
                ultraWideCamera = device
                print("📷 Found ultra-wide camera: \(device.localizedName)")
            default:
                break
            }
        }
    }
    
    // MARK: - Permissions
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionGranted = true
            setupMultiCamSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    self?.permissionGranted = granted
                    if granted {
                        self?.setupMultiCamSession()
                    }
                }
            }
        default:
            permissionGranted = false
            errorMessage = "Camera access denied"
        }
        
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }
    
    // MARK: - MultiCam Session Setup
    private func setupMultiCamSession() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            errorMessage = "Multi-cam not supported on this device"
            print("❌ Multi-cam not supported")
            return
        }
        
        guard let wide = wideCamera, let ultraWide = ultraWideCamera else {
            errorMessage = "Required cameras not available"
            print("❌ Missing cameras - wide: \(wideCamera != nil), ultraWide: \(ultraWideCamera != nil)")
            return
        }
        
        print("🎬 Setting up MultiCam session with cropping...")
        
        let session = AVCaptureMultiCamSession()
        session.beginConfiguration()
        
        do {
            // === WIDE CAMERA (Portrait 9:16) - Simple MovieFileOutput ===
            let wideInput = try AVCaptureDeviceInput(device: wide)
            guard session.canAddInput(wideInput) else {
                throw NSError(domain: "MultiCam", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add wide camera input"])
            }
            session.addInputWithNoConnections(wideInput)
            print("✅ Wide camera input added")
            
            // Portrait movie output
            let portraitOutput = AVCaptureMovieFileOutput()
            guard session.canAddOutput(portraitOutput) else {
                throw NSError(domain: "MultiCam", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add portrait output"])
            }
            session.addOutputWithNoConnections(portraitOutput)
            
            guard let wideVideoPort = wideInput.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .back).first else {
                throw NSError(domain: "MultiCam", code: 3, userInfo: [NSLocalizedDescriptionKey: "No wide camera port"])
            }
            
            let portraitConnection = AVCaptureConnection(inputPorts: [wideVideoPort], output: portraitOutput)
            portraitConnection.videoOrientation = .portrait
            guard session.canAddConnection(portraitConnection) else {
                throw NSError(domain: "MultiCam", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot add portrait connection"])
            }
            session.addConnection(portraitConnection)
            portraitMovieOutput = portraitOutput
            print("✅ Portrait MovieFileOutput connected")
            
            // === ULTRA-WIDE CAMERA (Landscape 16:9) - VideoDataOutput for cropping ===
            let ultraWideInput = try AVCaptureDeviceInput(device: ultraWide)
            guard session.canAddInput(ultraWideInput) else {
                throw NSError(domain: "MultiCam", code: 5, userInfo: [NSLocalizedDescriptionKey: "Cannot add ultra-wide camera input"])
            }
            session.addInputWithNoConnections(ultraWideInput)
            print("✅ Ultra-wide camera input added")
            
            // Video data output for landscape (we'll process frames)
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.setSampleBufferDelegate(self, queue: landscapeQueue)
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            guard session.canAddOutput(videoOutput) else {
                throw NSError(domain: "MultiCam", code: 6, userInfo: [NSLocalizedDescriptionKey: "Cannot add landscape video output"])
            }
            session.addOutputWithNoConnections(videoOutput)
            
            guard let ultraWideVideoPort = ultraWideInput.ports(for: .video, sourceDeviceType: .builtInUltraWideCamera, sourceDevicePosition: .back).first else {
                throw NSError(domain: "MultiCam", code: 7, userInfo: [NSLocalizedDescriptionKey: "No ultra-wide camera port"])
            }
            
            // Capture in PORTRAIT orientation - we'll crop for landscape content
            let landscapeVideoConnection = AVCaptureConnection(inputPorts: [ultraWideVideoPort], output: videoOutput)
            landscapeVideoConnection.videoOrientation = .portrait
            guard session.canAddConnection(landscapeVideoConnection) else {
                throw NSError(domain: "MultiCam", code: 8, userInfo: [NSLocalizedDescriptionKey: "Cannot add landscape video connection"])
            }
            session.addConnection(landscapeVideoConnection)
            landscapeVideoOutput = videoOutput
            print("✅ Landscape VideoDataOutput connected (portrait capture, will crop to 16:9)")
            
            // === AUDIO ===
            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice) {
                if session.canAddInput(audioInput) {
                    session.addInputWithNoConnections(audioInput)
                    
                    if let audioPort = audioInput.ports(for: .audio, sourceDeviceType: nil, sourceDevicePosition: .unspecified).first {
                        // Audio to portrait
                        let portraitAudioConnection = AVCaptureConnection(inputPorts: [audioPort], output: portraitOutput)
                        if session.canAddConnection(portraitAudioConnection) {
                            session.addConnection(portraitAudioConnection)
                            print("✅ Audio connected to portrait output")
                        }
                        
                        // Audio data output for landscape
                        let audioOutput = AVCaptureAudioDataOutput()
                        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
                        if session.canAddOutput(audioOutput) {
                            session.addOutputWithNoConnections(audioOutput)
                            let landscapeAudioConnection = AVCaptureConnection(inputPorts: [audioPort], output: audioOutput)
                            if session.canAddConnection(landscapeAudioConnection) {
                                session.addConnection(landscapeAudioConnection)
                                landscapeAudioOutput = audioOutput
                                print("✅ Audio connected to landscape output")
                            }
                        }
                    }
                }
            }
            
            // === PREVIEW LAYERS ===
            let portraitPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
            portraitPreview.videoGravity = .resizeAspectFill
            let portraitPreviewConnection = AVCaptureConnection(inputPort: wideVideoPort, videoPreviewLayer: portraitPreview)
            portraitPreviewConnection.videoOrientation = .portrait
            if session.canAddConnection(portraitPreviewConnection) {
                session.addConnection(portraitPreviewConnection)
                self.portraitPreviewLayer = portraitPreview
                print("✅ Portrait preview layer created")
            }
            
            let landscapePreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
            landscapePreview.videoGravity = .resizeAspectFill
            let landscapePreviewConnection = AVCaptureConnection(inputPort: ultraWideVideoPort, videoPreviewLayer: landscapePreview)
            landscapePreviewConnection.videoOrientation = .portrait
            if session.canAddConnection(landscapePreviewConnection) {
                session.addConnection(landscapePreviewConnection)
                self.landscapePreviewLayer = landscapePreview
                print("✅ Landscape preview layer created")
            }
            
        } catch {
            print("❌ Setup failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            session.commitConfiguration()
            return
        }
        
        session.commitConfiguration()
        multiCamSession = session
        
        // Initialize CIContext for image processing
        writerLock.lock()
        ciContext = CIContext(options: [.useSoftwareRenderer: false])
        writerLock.unlock()
        
        print("🎬 MultiCam session configured, starting...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            session.startRunning()
            DispatchQueue.main.async {
                self?.isSessionRunning = session.isRunning
                print("🎬 Session running: \(session.isRunning)")
            }
        }
    }
    
    // MARK: - Recording
    func startRecording() {
        guard let portraitOutput = portraitMovieOutput else {
            print("❌ Portrait output not ready")
            return
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970)
        
        // Portrait - simple file output
        portraitURL = tempDir.appendingPathComponent("portrait_\(timestamp).mov")
        portraitFinished = false
        
        // Landscape - asset writer setup
        setupLandscapeWriter(tempDir: tempDir, timestamp: timestamp)
        landscapeFinished = false
        
        print("🔴 Starting dual recording...")
        print("   Portrait: \(portraitURL!.lastPathComponent)")
        
        writerLock.lock()
        if let url = landscapeURL {
            print("   Landscape: \(url.lastPathComponent)")
        }
        writerLock.unlock()
        
        portraitOutput.startRecording(to: portraitURL!, recordingDelegate: self)
        
        isRecording = true
        recordingStartTime = Date()
        startTimer()
    }
    
    private func setupLandscapeWriter(tempDir: URL, timestamp: Int) {
        writerLock.lock()
        defer { writerLock.unlock() }
        
        let url = tempDir.appendingPathComponent("landscape_\(timestamp).mov")
        landscapeURL = url
        
        do {
            let writer = try AVAssetWriter(url: url, fileType: .mov)
            
            // Video input - 1920x1080 landscape
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1920,
                AVVideoHeightKey: 1080
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            
            // Pixel buffer adaptor for writing cropped frames
            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1920,
                kCVPixelBufferHeightKey as String: 1080
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: pixelBufferAttributes
            )
            
            // Audio input
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            
            if writer.canAdd(videoInput) {
                writer.add(videoInput)
            }
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
            }
            
            landscapeWriter = writer
            landscapeVideoInput = videoInput
            landscapeAudioInput = audioInput
            landscapePixelBufferAdaptor = adaptor
            landscapeWritingStarted = false
            landscapeSessionStartTime = nil
            
            print("✅ Landscape AssetWriter configured for 1920x1080")
            
        } catch {
            print("❌ Failed to create landscape writer: \(error)")
        }
    }
    
    func stopRecording() {
        print("⏹ Stopping recording...")
        
        portraitMovieOutput?.stopRecording()
        finishLandscapeWriter()
        
        isRecording = false
        stopTimer()
    }
    
    private func finishLandscapeWriter() {
        landscapeQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.writerLock.lock()
            
            self.landscapeVideoInput?.markAsFinished()
            self.landscapeAudioInput?.markAsFinished()
            
            guard let writer = self.landscapeWriter, writer.status == .writing else {
                self.writerLock.unlock()
                Task { @MainActor in
                    self.landscapeFinished = true
                    self.checkAndSaveRecordings()
                }
                return
            }
            
            let url = self.landscapeURL
            self.writerLock.unlock()
            
            writer.finishWriting {
                print("✅ Finished landscape recording")
                
                // Log dimensions
                if let url = url {
                    let asset = AVAsset(url: url)
                    Task {
                        if let track = try? await asset.loadTracks(withMediaType: .video).first {
                            let size = try? await track.load(.naturalSize)
                            print("📐 Landscape actual size: \(size?.width ?? 0) x \(size?.height ?? 0)")
                        }
                    }
                }
                
                Task { @MainActor in
                    self.landscapeFinished = true
                    self.checkAndSaveRecordings()
                }
            }
            
            // Cleanup
            self.writerLock.lock()
            self.landscapeWriter = nil
            self.landscapeVideoInput = nil
            self.landscapeAudioInput = nil
            self.landscapePixelBufferAdaptor = nil
            self.landscapeWritingStarted = false
            self.landscapeSessionStartTime = nil
            self.writerLock.unlock()
        }
    }
    
    // MARK: - Timer
    private func startTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let start = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }
    
    private func stopTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingDuration = 0
        recordingStartTime = nil
    }
    
    // MARK: - Save to Photos
    private func checkAndSaveRecordings() {
        guard portraitFinished && landscapeFinished else { return }
        
        print("💾 Both recordings finished, saving to Photos...")
        
        if let url = portraitURL {
            saveToPhotos(url: url, name: "Portrait")
        }
        
        writerLock.lock()
        let landscapeURLCopy = landscapeURL
        writerLock.unlock()
        
        if let url = landscapeURLCopy {
            saveToPhotos(url: url, name: "Landscape")
        }
    }
    
    private func saveToPhotos(url: URL, name: String) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        } completionHandler: { success, error in
            if success {
                print("✅ \(name) saved to Photos")
            } else {
                print("❌ Failed to save \(name): \(error?.localizedDescription ?? "unknown")")
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    // MARK: - Session Access
    func getSession() -> AVCaptureSession? {
        return multiCamSession
    }
}

// MARK: - Video/Audio Sample Buffer Delegate
extension MultiCamManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        if output is AVCaptureVideoDataOutput {
            processLandscapeVideoFrame(sampleBuffer, timestamp: timestamp)
        } else if output is AVCaptureAudioDataOutput {
            processLandscapeAudioFrame(sampleBuffer, timestamp: timestamp)
        }
    }
    
    /// Process ultra-wide camera frames: crop center horizontal strip (16:9), scale to 1920x1080
    nonisolated private func processLandscapeVideoFrame(_ sampleBuffer: CMSampleBuffer, timestamp: CMTime) {
        writerLock.lock()
        defer { writerLock.unlock() }
        
        guard let writer = landscapeWriter,
              let videoInput = landscapeVideoInput,
              let adaptor = landscapePixelBufferAdaptor,
              let context = ciContext,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        // Start writer on first frame
        if !landscapeWritingStarted {
            landscapeWritingStarted = true
            landscapeSessionStartTime = timestamp
            writer.startWriting()
            writer.startSession(atSourceTime: timestamp)
            
            let w = CVPixelBufferGetWidth(imageBuffer)
            let h = CVPixelBufferGetHeight(imageBuffer)
            print("📐 Landscape source frame: \(w) x \(h) (portrait)")
            print("📐 Will crop center 16:9 strip and scale to 1920x1080 (no rotation)")
        }
        
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
        
        // Frame is portrait: e.g., 1080w x 1920h
        let frameWidth = CGFloat(CVPixelBufferGetWidth(imageBuffer))
        let frameHeight = CGFloat(CVPixelBufferGetHeight(imageBuffer))
        
        // Crop a horizontal strip from center
        // Strip dimensions: frameWidth x (frameWidth * 9/16) = 1080 x 607.5
        // This is already 16:9 aspect ratio (wider than tall)
        let cropHeight = frameWidth * 9.0 / 16.0
        let cropY = (frameHeight - cropHeight) / 2.0
        let cropRect = CGRect(x: 0, y: cropY, width: frameWidth, height: cropHeight)
        
        // Crop
        var ciImage = CIImage(cvPixelBuffer: imageBuffer)
        ciImage = ciImage.cropped(to: cropRect)
        
        // Translate origin to (0,0)
        ciImage = ciImage.transformed(by: CGAffineTransform(translationX: 0, y: -cropY))
        
        // Scale from 1080x607.5 to 1920x1080 (no rotation needed - already landscape aspect)
        let scaleX = 1920.0 / frameWidth
        let scaleY = 1080.0 / cropHeight
        ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        // Render to pixel buffer
        guard let pixelBufferPool = adaptor.pixelBufferPool else { return }
        var newPixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &newPixelBuffer)
        
        guard let outputBuffer = newPixelBuffer else { return }
        context.render(ciImage, to: outputBuffer)
        adaptor.append(outputBuffer, withPresentationTime: timestamp)
    }
    
    nonisolated private func processLandscapeAudioFrame(_ sampleBuffer: CMSampleBuffer, timestamp: CMTime) {
        writerLock.lock()
        defer { writerLock.unlock() }
        
        guard landscapeWritingStarted,
              let audioInput = landscapeAudioInput,
              audioInput.isReadyForMoreMediaData else {
            return
        }
        
        audioInput.append(sampleBuffer)
    }
}

// MARK: - Portrait Recording Delegate
extension MultiCamManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        print("🎬 Portrait recording started: \(fileURL.lastPathComponent)")
    }
    
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error = error {
            print("❌ Portrait recording error: \(error.localizedDescription)")
        } else {
            print("✅ Portrait recording finished: \(outputFileURL.lastPathComponent)")
            
            // Log dimensions
            let asset = AVAsset(url: outputFileURL)
            Task {
                if let track = try? await asset.loadTracks(withMediaType: .video).first {
                    let size = try? await track.load(.naturalSize)
                    print("📐 Portrait actual size: \(size?.width ?? 0) x \(size?.height ?? 0)")
                }
            }
        }
        
        Task { @MainActor in
            self.portraitFinished = true
            self.checkAndSaveRecordings()
        }
    }
}
