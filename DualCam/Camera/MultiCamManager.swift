import AVFoundation
import Photos
import SwiftUI

/// MultiCamManager - Records portrait (9:16) and landscape (16:9) simultaneously
/// using two physical cameras with AVCaptureMultiCamSession
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
    
    // MARK: - Outputs
    private var portraitMovieOutput: AVCaptureMovieFileOutput?
    private var landscapeMovieOutput: AVCaptureMovieFileOutput?
    
    // MARK: - Recording State
    private var portraitURL: URL?
    private var landscapeURL: URL?
    private var portraitFinished = false
    private var landscapeFinished = false
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
        
        print("🎬 Setting up MultiCam session...")
        
        let session = AVCaptureMultiCamSession()
        session.beginConfiguration()
        
        do {
            // === WIDE CAMERA (Portrait 9:16) ===
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
            
            // Connect wide camera -> portrait output with PORTRAIT orientation
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
            print("✅ Portrait output connected")
            print("   Camera: \(wide.localizedName) (\(wide.deviceType.rawValue))")
            print("   Port: \(wideVideoPort.sourceDeviceType?.rawValue ?? "nil")")
            
            // === ULTRA-WIDE CAMERA (Landscape 16:9) ===
            let ultraWideInput = try AVCaptureDeviceInput(device: ultraWide)
            guard session.canAddInput(ultraWideInput) else {
                throw NSError(domain: "MultiCam", code: 5, userInfo: [NSLocalizedDescriptionKey: "Cannot add ultra-wide camera input"])
            }
            session.addInputWithNoConnections(ultraWideInput)
            print("✅ Ultra-wide camera input added")
            
            // Landscape movie output
            let landscapeOutput = AVCaptureMovieFileOutput()
            guard session.canAddOutput(landscapeOutput) else {
                throw NSError(domain: "MultiCam", code: 6, userInfo: [NSLocalizedDescriptionKey: "Cannot add landscape output"])
            }
            session.addOutputWithNoConnections(landscapeOutput)
            
            // Connect ultra-wide camera -> landscape output with LANDSCAPE orientation
            guard let ultraWideVideoPort = ultraWideInput.ports(for: .video, sourceDeviceType: .builtInUltraWideCamera, sourceDevicePosition: .back).first else {
                throw NSError(domain: "MultiCam", code: 7, userInfo: [NSLocalizedDescriptionKey: "No ultra-wide camera port"])
            }
            
            let landscapeConnection = AVCaptureConnection(inputPorts: [ultraWideVideoPort], output: landscapeOutput)
            landscapeConnection.videoOrientation = .landscapeRight
            // Try to fix horizontal flip
            if landscapeConnection.isVideoMirroringSupported {
                landscapeConnection.isVideoMirrored = true
                print("📷 Landscape mirroring enabled")
            }
            guard session.canAddConnection(landscapeConnection) else {
                throw NSError(domain: "MultiCam", code: 8, userInfo: [NSLocalizedDescriptionKey: "Cannot add landscape connection"])
            }
            session.addConnection(landscapeConnection)
            landscapeMovieOutput = landscapeOutput
            print("✅ Landscape output connected")
            print("   Camera: \(ultraWide.localizedName) (\(ultraWide.deviceType.rawValue))")
            print("   Port: \(ultraWideVideoPort.sourceDeviceType?.rawValue ?? "nil")")
            
            // === AUDIO (connect to both outputs) ===
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
                    }
                }
            }
            
            // === PREVIEW LAYERS ===
            // Portrait preview (wide camera)
            let portraitPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
            portraitPreview.videoGravity = .resizeAspectFill
            let portraitPreviewConnection = AVCaptureConnection(inputPort: wideVideoPort, videoPreviewLayer: portraitPreview)
            portraitPreviewConnection.videoOrientation = .portrait
            if session.canAddConnection(portraitPreviewConnection) {
                session.addConnection(portraitPreviewConnection)
                self.portraitPreviewLayer = portraitPreview
                print("✅ Portrait preview layer created")
            }
            
            // Landscape preview (ultra-wide camera)
            let landscapePreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
            landscapePreview.videoGravity = .resizeAspectFill
            let landscapePreviewConnection = AVCaptureConnection(inputPort: ultraWideVideoPort, videoPreviewLayer: landscapePreview)
            landscapePreviewConnection.videoOrientation = .landscapeLeft
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
        
        print("🎬 MultiCam session configured, starting...")
        
        // Start session
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
        guard let portraitOutput = portraitMovieOutput,
              let landscapeOutput = landscapeMovieOutput else {
            print("❌ Outputs not ready")
            return
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970)
        
        portraitURL = tempDir.appendingPathComponent("portrait_\(timestamp).mov")
        landscapeURL = tempDir.appendingPathComponent("landscape_\(timestamp).mov")
        
        portraitFinished = false
        landscapeFinished = false
        
        print("🔴 Starting dual recording...")
        print("   Portrait: \(portraitURL!.lastPathComponent)")
        print("   Landscape: \(landscapeURL!.lastPathComponent)")
        
        portraitOutput.startRecording(to: portraitURL!, recordingDelegate: self)
        landscapeOutput.startRecording(to: landscapeURL!, recordingDelegate: self)
        
        isRecording = true
        recordingStartTime = Date()
        startTimer()
    }
    
    func stopRecording() {
        print("⏹ Stopping recording...")
        
        portraitMovieOutput?.stopRecording()
        landscapeMovieOutput?.stopRecording()
        
        isRecording = false
        stopTimer()
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
        if let url = landscapeURL {
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

// MARK: - Recording Delegate
extension MultiCamManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        print("🎬 Started recording: \(fileURL.lastPathComponent)")
        for (i, conn) in connections.enumerated() {
            print("   Connection \(i):")
            print("   - Orientation: \(conn.videoOrientation.rawValue)")
            print("   - Mirrored: \(conn.isVideoMirrored)")
            for port in conn.inputPorts {
                print("   - Port sourceDevice: \(port.sourceDeviceType?.rawValue ?? "nil")")
            }
        }
    }
    
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let name = outputFileURL.lastPathComponent
        
        if let error = error {
            print("❌ Recording error for \(name): \(error.localizedDescription)")
        } else {
            print("✅ Finished recording: \(name)")
        }
        
        Task { @MainActor in
            if outputFileURL.lastPathComponent.contains("portrait") {
                self.portraitFinished = true
            } else {
                self.landscapeFinished = true
            }
            self.checkAndSaveRecordings()
        }
    }
}
