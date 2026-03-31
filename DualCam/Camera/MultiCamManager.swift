import AVFoundation
import Photos
import SwiftUI
import CoreImage

// MARK: - Recording Mode
enum RecordingMode: String, CaseIterable {
    case singleLens = "Single Lens"
    case dualLens = "Dual Lens"
    case streamer = "Streamer"
    
    var description: String {
        switch self {
        case .singleLens: return "One camera, crops for both outputs"
        case .dualLens: return "Two cameras, full quality both"
        case .streamer: return "Main + face cam PiP"
        }
    }
    
    var requiresMultiCam: Bool {
        switch self {
        case .singleLens: return false
        case .dualLens, .streamer: return true
        }
    }
}

/// MultiCamManager - Records video using multiple cameras
/// - Dual Lens: Portrait (9:16) + Landscape (16:9) as separate files
/// - Streamer: Main video + face cam PiP baked in as single file
@MainActor
class MultiCamManager: NSObject, ObservableObject {
    
    // MARK: - Published State
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var permissionGranted = false
    @Published var isSessionRunning = false
    @Published var errorMessage: String?
    @Published var recordingMode: RecordingMode = .dualLens
    
    // MARK: - Session & Devices
    private var multiCamSession: AVCaptureMultiCamSession?
    private var singleLensSession: AVCaptureSession?  // For single lens fallback
    private var wideCamera: AVCaptureDevice?      // For portrait (9:16) / main view
    private var ultraWideCamera: AVCaptureDevice? // For landscape (16:9)
    private var frontCamera: AVCaptureDevice?     // For streamer face cam
    
    // MARK: - Portrait Output (simple MovieFileOutput)
    private var portraitMovieOutput: AVCaptureMovieFileOutput?
    private var portraitURL: URL?
    private var portraitFinished = false
    
    // MARK: - Landscape Output (VideoDataOutput + AssetWriter for cropping)
    private nonisolated(unsafe) var landscapeVideoOutput: AVCaptureVideoDataOutput?
    private nonisolated(unsafe) var landscapeAudioOutput: AVCaptureAudioDataOutput?
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
    
    // Portrait writer for single lens mode
    private nonisolated(unsafe) var portraitWriter: AVAssetWriter?
    private nonisolated(unsafe) var portraitVideoInput: AVAssetWriterInput?
    private nonisolated(unsafe) var portraitAudioInput: AVAssetWriterInput?
    private nonisolated(unsafe) var portraitPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private nonisolated(unsafe) var portraitWritingStarted = false
    private nonisolated(unsafe) var isSingleLensMode = false
    
    // MARK: - Streamer Mode State
    private nonisolated(unsafe) var mainVideoOutput: AVCaptureVideoDataOutput?
    private nonisolated(unsafe) var faceCamVideoOutput: AVCaptureVideoDataOutput?
    private nonisolated(unsafe) var streamerAudioOutput: AVCaptureAudioDataOutput?
    private let mainQueue = DispatchQueue(label: "com.dualcam.main")
    private let faceCamQueue = DispatchQueue(label: "com.dualcam.facecam")
    
    // Streamer writer state
    private nonisolated(unsafe) var streamerWriter: AVAssetWriter?
    private nonisolated(unsafe) var streamerVideoInput: AVAssetWriterInput?
    private nonisolated(unsafe) var streamerAudioInput: AVAssetWriterInput?
    private nonisolated(unsafe) var streamerPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private nonisolated(unsafe) var streamerURL: URL?
    private nonisolated(unsafe) var streamerWritingStarted = false
    private nonisolated(unsafe) var streamerSessionStartTime: CMTime?
    private nonisolated(unsafe) var latestFaceCamBuffer: CVPixelBuffer?
    private let faceCamLock = NSLock()
    
    // MARK: - Recording State
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    
    // MARK: - Preview Layers
    var portraitPreviewLayer: AVCaptureVideoPreviewLayer?
    var landscapePreviewLayer: AVCaptureVideoPreviewLayer?
    var faceCamPreviewLayer: AVCaptureVideoPreviewLayer?
    
    // MARK: - Initialization
    override init() {
        super.init()
        discoverCameras()
    }
    
    // MARK: - Camera Discovery
    private func discoverCameras() {
        // Back cameras
        let backDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera],
            mediaType: .video,
            position: .back
        )
        
        for device in backDiscovery.devices {
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
        
        // Front camera
        let frontDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        )
        
        if let front = frontDiscovery.devices.first {
            frontCamera = front
            print("📷 Found front camera: \(front.localizedName)")
        }
    }
    
    // MARK: - Permissions
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionGranted = true
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    self?.permissionGranted = granted
                    if granted {
                        self?.setupSession()
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
    
    // MARK: - Mode Switching
    func switchMode(to mode: RecordingMode) {
        guard !isRecording else { return }
        guard recordingMode != mode else { return }  // No change needed
        
        print("🔄 Switching from \(recordingMode.rawValue) to \(mode.rawValue)")
        recordingMode = mode
        isSessionRunning = false
        
        // Stop on background thread, then setup new session
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.stopSessionSync()
            
            // Small delay to ensure cleanup
            Thread.sleep(forTimeInterval: 0.2)
            
            DispatchQueue.main.async {
                self?.setupSession()
            }
        }
    }
    
    private func stopSessionSync() {
        multiCamSession?.stopRunning()
        singleLensSession?.stopRunning()
        
        DispatchQueue.main.async { [weak self] in
            self?.multiCamSession = nil
            self?.singleLensSession = nil
            self?.portraitPreviewLayer = nil
            self?.landscapePreviewLayer = nil
            self?.faceCamPreviewLayer = nil
            self?.portraitMovieOutput = nil
        }
        
        writerLock.lock()
        landscapeVideoOutput = nil
        landscapeAudioOutput = nil
        mainVideoOutput = nil
        faceCamVideoOutput = nil
        streamerAudioOutput = nil
        latestFaceCamBuffer = nil
        writerLock.unlock()
    }
    
    private func setupSession() {
        // Check if multi-cam is needed but not supported
        if recordingMode.requiresMultiCam && !AVCaptureMultiCamSession.isMultiCamSupported {
            print("⚠️ Multi-cam not supported, falling back to Single Lens")
            recordingMode = .singleLens
        }
        
        switch recordingMode {
        case .singleLens:
            setupSingleLensSession()
        case .dualLens:
            setupMultiCamSession()
        case .streamer:
            setupStreamerSession()
        }
    }
    
    private func stopSession() {
        multiCamSession?.stopRunning()
        multiCamSession = nil
        singleLensSession?.stopRunning()
        singleLensSession = nil
        portraitPreviewLayer = nil
        landscapePreviewLayer = nil
        faceCamPreviewLayer = nil
        portraitMovieOutput = nil
        landscapeVideoOutput = nil
        landscapeAudioOutput = nil
        mainVideoOutput = nil
        faceCamVideoOutput = nil
        streamerAudioOutput = nil
        isSessionRunning = false
    }
    
    // MARK: - Single Lens Session Setup (fallback for older phones)
    private func setupSingleLensSession() {
        guard let wide = wideCamera else {
            errorMessage = "Camera not available"
            print("❌ Wide camera not found")
            return
        }
        
        print("🎬 Setting up Single Lens session (one camera, crop for landscape)...")
        
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        
        do {
            // Wide camera input
            let wideInput = try AVCaptureDeviceInput(device: wide)
            guard session.canAddInput(wideInput) else {
                throw NSError(domain: "SingleLens", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
            }
            session.addInput(wideInput)
            print("✅ Wide camera input added")
            
            // Video data output (we'll process frames for both portrait and landscape)
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.setSampleBufferDelegate(self, queue: landscapeQueue)
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            guard session.canAddOutput(videoOutput) else {
                throw NSError(domain: "SingleLens", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add video output"])
            }
            session.addOutput(videoOutput)
            
            if let connection = videoOutput.connection(with: .video) {
                connection.videoOrientation = .portrait
            }
            landscapeVideoOutput = videoOutput  // Reuse for single lens
            print("✅ Video output added (portrait capture)")
            
            // Audio input
            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice) {
                if session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                    
                    let audioOutput = AVCaptureAudioDataOutput()
                    audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
                    if session.canAddOutput(audioOutput) {
                        session.addOutput(audioOutput)
                        landscapeAudioOutput = audioOutput
                        print("✅ Audio output added")
                    }
                }
            }
            
            // Preview layer
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            self.portraitPreviewLayer = preview
            print("✅ Preview layer created")
            
        } catch {
            print("❌ Single lens setup failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            session.commitConfiguration()
            return
        }
        
        session.commitConfiguration()
        
        // Store as regular session (not multi-cam)
        // We need to handle this differently
        singleLensSession = session
        
        print("🎬 Single Lens session configured, starting...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            session.startRunning()
            DispatchQueue.main.async {
                self?.isSessionRunning = session.isRunning
                print("🎬 Single Lens session running: \(session.isRunning)")
            }
        }
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
            
            // Capture in PORTRAIT orientation - we'll crop a 16:9 horizontal strip
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
        
        print("🎬 MultiCam session configured, starting...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            session.startRunning()
            DispatchQueue.main.async {
                self?.isSessionRunning = session.isRunning
                print("🎬 Session running: \(session.isRunning)")
            }
        }
    }
    
    // MARK: - Streamer Session Setup
    private func setupStreamerSession() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            errorMessage = "Multi-cam not supported on this device"
            print("❌ Multi-cam not supported, falling back to Single Lens")
            recordingMode = .singleLens
            setupSingleLensSession()
            return
        }
        
        // Re-discover cameras if needed
        if frontCamera == nil {
            discoverCameras()
        }
        
        guard let wide = wideCamera, let front = frontCamera else {
            errorMessage = "Required cameras not available"
            print("❌ Missing cameras - wide: \(wideCamera != nil), front: \(frontCamera != nil)")
            print("⚠️ Falling back to Single Lens")
            recordingMode = .singleLens
            setupSingleLensSession()
            return
        }
        
        print("🎬 Setting up Streamer session (main + face cam)...")
        
        let session = AVCaptureMultiCamSession()
        session.beginConfiguration()
        
        do {
            // === BACK CAMERA (Main view) ===
            let wideInput = try AVCaptureDeviceInput(device: wide)
            guard session.canAddInput(wideInput) else {
                throw NSError(domain: "Streamer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add wide camera input"])
            }
            session.addInputWithNoConnections(wideInput)
            print("✅ Main camera (wide) input added")
            
            // Main video data output
            let mainOutput = AVCaptureVideoDataOutput()
            mainOutput.setSampleBufferDelegate(self, queue: mainQueue)
            mainOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            guard session.canAddOutput(mainOutput) else {
                throw NSError(domain: "Streamer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add main video output"])
            }
            session.addOutputWithNoConnections(mainOutput)
            
            guard let wideVideoPort = wideInput.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .back).first else {
                throw NSError(domain: "Streamer", code: 3, userInfo: [NSLocalizedDescriptionKey: "No wide camera port"])
            }
            
            let mainConnection = AVCaptureConnection(inputPorts: [wideVideoPort], output: mainOutput)
            mainConnection.videoOrientation = .portrait
            guard session.canAddConnection(mainConnection) else {
                throw NSError(domain: "Streamer", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot add main connection"])
            }
            session.addConnection(mainConnection)
            mainVideoOutput = mainOutput
            print("✅ Main video output connected")
            
            // === FRONT CAMERA (Face cam) ===
            let frontInput = try AVCaptureDeviceInput(device: front)
            guard session.canAddInput(frontInput) else {
                throw NSError(domain: "Streamer", code: 5, userInfo: [NSLocalizedDescriptionKey: "Cannot add front camera input"])
            }
            session.addInputWithNoConnections(frontInput)
            print("✅ Front camera input added")
            
            // Face cam video data output
            let faceCamOutput = AVCaptureVideoDataOutput()
            faceCamOutput.setSampleBufferDelegate(self, queue: faceCamQueue)
            faceCamOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            guard session.canAddOutput(faceCamOutput) else {
                throw NSError(domain: "Streamer", code: 6, userInfo: [NSLocalizedDescriptionKey: "Cannot add face cam output"])
            }
            session.addOutputWithNoConnections(faceCamOutput)
            
            guard let frontVideoPort = frontInput.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .front).first else {
                throw NSError(domain: "Streamer", code: 7, userInfo: [NSLocalizedDescriptionKey: "No front camera port"])
            }
            
            let faceCamConnection = AVCaptureConnection(inputPorts: [frontVideoPort], output: faceCamOutput)
            guard session.canAddConnection(faceCamConnection) else {
                throw NSError(domain: "Streamer", code: 8, userInfo: [NSLocalizedDescriptionKey: "Cannot add face cam connection"])
            }
            session.addConnection(faceCamConnection)
            // Set these AFTER adding connection
            faceCamConnection.videoOrientation = .portrait
            if faceCamConnection.isVideoMirroringSupported {
                faceCamConnection.automaticallyAdjustsVideoMirroring = false
                faceCamConnection.isVideoMirrored = true  // Mirror front camera like a selfie
            }
            faceCamVideoOutput = faceCamOutput
            print("✅ Face cam output connected (mirrored)")
            
            // === AUDIO ===
            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice) {
                if session.canAddInput(audioInput) {
                    session.addInputWithNoConnections(audioInput)
                    
                    if let audioPort = audioInput.ports(for: .audio, sourceDeviceType: nil, sourceDevicePosition: .unspecified).first {
                        let audioOutput = AVCaptureAudioDataOutput()
                        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
                        if session.canAddOutput(audioOutput) {
                            session.addOutputWithNoConnections(audioOutput)
                            let audioConnection = AVCaptureConnection(inputPorts: [audioPort], output: audioOutput)
                            if session.canAddConnection(audioConnection) {
                                session.addConnection(audioConnection)
                                streamerAudioOutput = audioOutput
                                print("✅ Audio connected")
                            }
                        }
                    }
                }
            }
            
            // === PREVIEW LAYERS ===
            let mainPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
            mainPreview.videoGravity = .resizeAspectFill
            let mainPreviewConnection = AVCaptureConnection(inputPort: wideVideoPort, videoPreviewLayer: mainPreview)
            mainPreviewConnection.videoOrientation = .portrait
            if session.canAddConnection(mainPreviewConnection) {
                session.addConnection(mainPreviewConnection)
                self.portraitPreviewLayer = mainPreview
                print("✅ Main preview layer created")
            }
            
            let faceCamPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
            faceCamPreview.videoGravity = .resizeAspectFill
            let faceCamPreviewConnection = AVCaptureConnection(inputPort: frontVideoPort, videoPreviewLayer: faceCamPreview)
            if session.canAddConnection(faceCamPreviewConnection) {
                session.addConnection(faceCamPreviewConnection)
                // Set these AFTER adding connection
                faceCamPreviewConnection.videoOrientation = .portrait
                if faceCamPreviewConnection.isVideoMirroringSupported {
                    faceCamPreviewConnection.automaticallyAdjustsVideoMirroring = false
                    faceCamPreviewConnection.isVideoMirrored = true
                }
                self.faceCamPreviewLayer = faceCamPreview
                print("✅ Face cam preview layer created")
            }
            
        } catch {
            print("❌ Streamer setup failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            session.commitConfiguration()
            return
        }
        
        session.commitConfiguration()
        multiCamSession = session
        
        print("🎬 Streamer session configured, starting...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            session.startRunning()
            DispatchQueue.main.async {
                self?.isSessionRunning = session.isRunning
                print("🎬 Streamer session running: \(session.isRunning)")
            }
        }
    }
    
    // MARK: - Recording
    func startRecording() {
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970)
        
        switch recordingMode {
        case .singleLens:
            startSingleLensRecording(tempDir: tempDir, timestamp: timestamp)
        case .dualLens:
            startDualLensRecording(tempDir: tempDir, timestamp: timestamp)
        case .streamer:
            startStreamerRecording(tempDir: tempDir, timestamp: timestamp)
        }
        
        isRecording = true
        recordingStartTime = Date()
        startTimer()
    }
    
    private func startSingleLensRecording(tempDir: URL, timestamp: Int) {
        // Portrait writer - full frame
        setupPortraitWriter(tempDir: tempDir, timestamp: timestamp)
        portraitFinished = false
        
        // Landscape writer - cropped
        setupLandscapeWriter(tempDir: tempDir, timestamp: timestamp)
        landscapeFinished = false
        
        // Enable single lens processing mode
        writerLock.lock()
        isSingleLensMode = true
        writerLock.unlock()
        
        print("🔴 Starting single lens recording (portrait + landscape from one camera)...")
        
        writerLock.lock()
        if let pUrl = portraitURL {
            print("   Portrait: \(pUrl.lastPathComponent)")
        }
        if let lUrl = landscapeURL {
            print("   Landscape: \(lUrl.lastPathComponent)")
        }
        writerLock.unlock()
    }
    
    private func setupPortraitWriter(tempDir: URL, timestamp: Int) {
        writerLock.lock()
        defer { writerLock.unlock() }
        
        let url = tempDir.appendingPathComponent("portrait_\(timestamp).mov")
        portraitURL = url
        
        do {
            let writer = try AVAssetWriter(url: url, fileType: .mov)
            
            // Video input - 1080x1920 portrait
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1080,
                AVVideoHeightKey: 1920
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            
            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1080,
                kCVPixelBufferHeightKey as String: 1920
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
            
            portraitWriter = writer
            portraitVideoInput = videoInput
            portraitAudioInput = audioInput
            portraitPixelBufferAdaptor = adaptor
            portraitWritingStarted = false
            
            if ciContext == nil {
                ciContext = CIContext(options: [.useSoftwareRenderer: false])
            }
            
            print("✅ Portrait writer configured (1080x1920)")
            
        } catch {
            print("❌ Failed to create portrait writer: \(error)")
        }
    }
    
    private func startDualLensRecording(tempDir: URL, timestamp: Int) {
        guard let portraitOutput = portraitMovieOutput else {
            print("❌ Portrait output not ready")
            return
        }
        
        // Portrait - simple file output
        portraitURL = tempDir.appendingPathComponent("portrait_\(timestamp).mov")
        portraitFinished = false
        
        // Landscape - asset writer setup
        setupLandscapeWriter(tempDir: tempDir, timestamp: timestamp)
        landscapeFinished = false
        
        print("🔴 Starting dual lens recording...")
        print("   Portrait: \(portraitURL!.lastPathComponent)")
        
        writerLock.lock()
        if let url = landscapeURL {
            print("   Landscape: \(url.lastPathComponent)")
        }
        writerLock.unlock()
        
        portraitOutput.startRecording(to: portraitURL!, recordingDelegate: self)
    }
    
    private func startStreamerRecording(tempDir: URL, timestamp: Int) {
        setupStreamerWriter(tempDir: tempDir, timestamp: timestamp)
        
        print("🔴 Starting streamer recording...")
        writerLock.lock()
        if let url = streamerURL {
            print("   Output: \(url.lastPathComponent)")
        }
        writerLock.unlock()
    }
    
    private func setupStreamerWriter(tempDir: URL, timestamp: Int) {
        writerLock.lock()
        defer { writerLock.unlock() }
        
        let url = tempDir.appendingPathComponent("streamer_\(timestamp).mov")
        streamerURL = url
        
        do {
            let writer = try AVAssetWriter(url: url, fileType: .mov)
            
            // Video input - 1080x1920 portrait
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1080,
                AVVideoHeightKey: 1920
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            
            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1080,
                kCVPixelBufferHeightKey as String: 1920
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
            
            streamerWriter = writer
            streamerVideoInput = videoInput
            streamerAudioInput = audioInput
            streamerPixelBufferAdaptor = adaptor
            streamerWritingStarted = false
            streamerSessionStartTime = nil
            
            // Reuse ciContext
            if ciContext == nil {
                ciContext = CIContext(options: [.useSoftwareRenderer: false])
            }
            
            print("✅ Streamer writer configured (1080x1920 portrait with PiP)")
            
        } catch {
            print("❌ Failed to create streamer writer: \(error)")
        }
    }
    
    private func setupLandscapeWriter(tempDir: URL, timestamp: Int) {
        writerLock.lock()
        defer { writerLock.unlock() }
        
        let url = tempDir.appendingPathComponent("landscape_\(timestamp).mov")
        landscapeURL = url
        
        do {
            let writer = try AVAssetWriter(url: url, fileType: .mov)
            
            // Video input - 1920x1080 landscape (we'll rotate portrait frames)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1920,
                AVVideoHeightKey: 1080
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            // No transform - we're writing actual rotated pixels
            
            // Pixel buffer adaptor for rotated frames
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
            ciContext = CIContext(options: [.useSoftwareRenderer: false])
            
            print("✅ Landscape AssetWriter configured (1920x1080 with pixel rotation)")
            
        } catch {
            print("❌ Failed to create landscape writer: \(error)")
        }
    }
    
    func stopRecording() {
        print("⏹ Stopping recording...")
        
        switch recordingMode {
        case .singleLens:
            finishPortraitWriter()
            finishLandscapeWriter()
        case .dualLens:
            portraitMovieOutput?.stopRecording()
            finishLandscapeWriter()
        case .streamer:
            finishStreamerWriter()
        }
        
        isRecording = false
        stopTimer()
    }
    
    private func finishStreamerWriter() {
        mainQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.writerLock.lock()
            
            self.streamerVideoInput?.markAsFinished()
            self.streamerAudioInput?.markAsFinished()
            
            guard let writer = self.streamerWriter, writer.status == .writing else {
                self.writerLock.unlock()
                Task { @MainActor in
                    self.saveStreamerVideo()
                }
                return
            }
            
            let url = self.streamerURL
            self.writerLock.unlock()
            
            writer.finishWriting {
                print("✅ Finished streamer recording")
                
                if let url = url {
                    let asset = AVAsset(url: url)
                    Task {
                        if let track = try? await asset.loadTracks(withMediaType: .video).first {
                            let size = try? await track.load(.naturalSize)
                            print("📐 Streamer video size: \(size?.width ?? 0) x \(size?.height ?? 0)")
                        }
                    }
                }
                
                Task { @MainActor in
                    self.saveStreamerVideo()
                }
            }
            
            // Cleanup
            self.writerLock.lock()
            self.streamerWriter = nil
            self.streamerVideoInput = nil
            self.streamerAudioInput = nil
            self.streamerPixelBufferAdaptor = nil
            self.streamerWritingStarted = false
            self.streamerSessionStartTime = nil
            self.latestFaceCamBuffer = nil
            self.writerLock.unlock()
        }
    }
    
    private func saveStreamerVideo() {
        writerLock.lock()
        let url = streamerURL
        writerLock.unlock()
        
        guard let url = url else { return }
        
        saveToPhotos(url: url, name: "Streamer")
    }
    
    private func finishPortraitWriter() {
        landscapeQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.writerLock.lock()
            
            self.portraitVideoInput?.markAsFinished()
            self.portraitAudioInput?.markAsFinished()
            
            guard let writer = self.portraitWriter, writer.status == .writing else {
                self.writerLock.unlock()
                Task { @MainActor in
                    self.portraitFinished = true
                    self.checkAndSaveRecordings()
                }
                return
            }
            
            let url = self.portraitURL
            self.writerLock.unlock()
            
            writer.finishWriting {
                print("✅ Finished portrait recording")
                
                if let url = url {
                    let asset = AVAsset(url: url)
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
            
            // Cleanup
            self.writerLock.lock()
            self.portraitWriter = nil
            self.portraitVideoInput = nil
            self.portraitAudioInput = nil
            self.portraitPixelBufferAdaptor = nil
            self.portraitWritingStarted = false
            self.isSingleLensMode = false
            self.writerLock.unlock()
        }
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
            self.ciContext = nil
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
        return multiCamSession ?? singleLensSession
    }
}

// MARK: - Video/Audio Sample Buffer Delegate
extension MultiCamManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        if output is AVCaptureVideoDataOutput {
            // Determine which output this is
            writerLock.lock()
            let isLandscapeOutput = (output === landscapeVideoOutput)
            let isMainOutput = (output === mainVideoOutput)
            let isFaceCamOutput = (output === faceCamVideoOutput)
            writerLock.unlock()
            
            // Check for single lens mode first
            writerLock.lock()
            let singleLens = isSingleLensMode
            writerLock.unlock()
            
            if singleLens && isLandscapeOutput {
                // Single lens: process same frame for both outputs
                processSingleLensVideoFrame(sampleBuffer, timestamp: timestamp)
            } else if isLandscapeOutput {
                processLandscapeVideoFrame(sampleBuffer, timestamp: timestamp)
            } else if isFaceCamOutput {
                processFaceCamFrame(sampleBuffer)
            } else if isMainOutput {
                processStreamerMainFrame(sampleBuffer, timestamp: timestamp)
            }
        } else if output is AVCaptureAudioDataOutput {
            writerLock.lock()
            let isLandscapeAudio = (output === landscapeAudioOutput)
            let isStreamerAudio = (output === streamerAudioOutput)
            writerLock.unlock()
            
            // Check for single lens mode
            writerLock.lock()
            let singleLens = isSingleLensMode
            writerLock.unlock()
            
            if singleLens && isLandscapeAudio {
                processSingleLensAudioFrame(sampleBuffer, timestamp: timestamp)
            } else if isLandscapeAudio {
                processLandscapeAudioFrame(sampleBuffer, timestamp: timestamp)
            } else if isStreamerAudio {
                processStreamerAudioFrame(sampleBuffer, timestamp: timestamp)
            }
        }
    }
    
    // MARK: - Single Lens Processing (write to both portrait and landscape)
    nonisolated private func processSingleLensVideoFrame(_ sampleBuffer: CMSampleBuffer, timestamp: CMTime) {
        writerLock.lock()
        defer { writerLock.unlock() }
        
        guard let context = ciContext,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        let frameWidth = CGFloat(CVPixelBufferGetWidth(imageBuffer))
        let frameHeight = CGFloat(CVPixelBufferGetHeight(imageBuffer))
        
        // Start writers on first frame
        if !portraitWritingStarted {
            portraitWritingStarted = true
            landscapeWritingStarted = true
            landscapeSessionStartTime = timestamp
            
            portraitWriter?.startWriting()
            portraitWriter?.startSession(atSourceTime: timestamp)
            landscapeWriter?.startWriting()
            landscapeWriter?.startSession(atSourceTime: timestamp)
            
            let cropHeight = frameWidth * 9.0 / 16.0
            print("📐 Single Lens frame: \(Int(frameWidth)) x \(Int(frameHeight))")
            print("📐 Portrait: full frame scaled to 1080x1920")
            print("📐 Landscape: center crop \(Int(frameWidth)) x \(Int(cropHeight)) → 1920x1080")
        }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        
        // === PORTRAIT: Full frame scaled to 1080x1920 ===
        if let portraitInput = portraitVideoInput,
           let portraitAdaptor = portraitPixelBufferAdaptor,
           portraitInput.isReadyForMoreMediaData,
           let portraitPool = portraitAdaptor.pixelBufferPool {
            
            let scaleX = 1080.0 / frameWidth
            let scaleY = 1920.0 / frameHeight
            let portraitImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            
            var portraitBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, portraitPool, &portraitBuffer)
            if let buffer = portraitBuffer {
                context.render(portraitImage, to: buffer)
                portraitAdaptor.append(buffer, withPresentationTime: timestamp)
            }
        }
        
        // === LANDSCAPE: Center crop to 16:9, scale to 1920x1080 ===
        if let landscapeInput = landscapeVideoInput,
           let landscapeAdaptor = landscapePixelBufferAdaptor,
           landscapeInput.isReadyForMoreMediaData,
           let landscapePool = landscapeAdaptor.pixelBufferPool {
            
            let cropHeight = frameWidth * 9.0 / 16.0
            let cropY = (frameHeight - cropHeight) / 2.0
            let cropRect = CGRect(x: 0, y: cropY, width: frameWidth, height: cropHeight)
            
            var landscapeImage = ciImage.cropped(to: cropRect)
            landscapeImage = landscapeImage.transformed(by: CGAffineTransform(translationX: 0, y: -cropY))
            
            let scaleX = 1920.0 / frameWidth
            let scaleY = 1080.0 / cropHeight
            landscapeImage = landscapeImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            
            var landscapeBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, landscapePool, &landscapeBuffer)
            if let buffer = landscapeBuffer {
                context.render(landscapeImage, to: buffer)
                landscapeAdaptor.append(buffer, withPresentationTime: timestamp)
            }
        }
    }
    
    // MARK: - Single Lens Audio Processing
    nonisolated private func processSingleLensAudioFrame(_ sampleBuffer: CMSampleBuffer, timestamp: CMTime) {
        writerLock.lock()
        defer { writerLock.unlock() }
        
        guard portraitWritingStarted else { return }
        
        // Write to both outputs
        if let portraitAudio = portraitAudioInput, portraitAudio.isReadyForMoreMediaData {
            portraitAudio.append(sampleBuffer)
        }
        if let landscapeAudio = landscapeAudioInput, landscapeAudio.isReadyForMoreMediaData {
            landscapeAudio.append(sampleBuffer)
        }
    }
    
    // MARK: - Face Cam Processing (just store latest frame)
    nonisolated private func processFaceCamFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        faceCamLock.lock()
        // CVPixelBuffer is automatically retained by Swift ARC
        latestFaceCamBuffer = imageBuffer
        faceCamLock.unlock()
    }
    
    // MARK: - Streamer Main Frame Processing (composite with face cam)
    nonisolated private func processStreamerMainFrame(_ sampleBuffer: CMSampleBuffer, timestamp: CMTime) {
        writerLock.lock()
        defer { writerLock.unlock() }
        
        guard let writer = streamerWriter,
              let videoInput = streamerVideoInput,
              let adaptor = streamerPixelBufferAdaptor,
              let context = ciContext,
              let mainBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        let mainWidth = CGFloat(CVPixelBufferGetWidth(mainBuffer))
        let mainHeight = CGFloat(CVPixelBufferGetHeight(mainBuffer))
        
        // Start writer on first frame
        if !streamerWritingStarted {
            streamerWritingStarted = true
            streamerSessionStartTime = timestamp
            writer.startWriting()
            writer.startSession(atSourceTime: timestamp)
            
            print("📐 Streamer main frame: \(Int(mainWidth)) x \(Int(mainHeight))")
            print("📐 PiP will be composited in bottom-right corner")
        }
        
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
        
        // Create main image
        var mainImage = CIImage(cvPixelBuffer: mainBuffer)
        
        // Scale main to output size if needed
        let outputWidth: CGFloat = 1080
        let outputHeight: CGFloat = 1920
        
        if mainWidth != outputWidth || mainHeight != outputHeight {
            let scaleX = outputWidth / mainWidth
            let scaleY = outputHeight / mainHeight
            mainImage = mainImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        
        // Get face cam frame and composite as PiP
        faceCamLock.lock()
        let faceCamBuffer = latestFaceCamBuffer
        faceCamLock.unlock()
        
        if let faceBuffer = faceCamBuffer {
            // Create face cam image
            var faceImage = CIImage(cvPixelBuffer: faceBuffer)
            
            let faceWidth = CGFloat(CVPixelBufferGetWidth(faceBuffer))
            let faceHeight = CGFloat(CVPixelBufferGetHeight(faceBuffer))
            
            // PiP size: 1/4 of output width
            let pipWidth: CGFloat = outputWidth * 0.35  // 35% of frame width
            let pipHeight = pipWidth * (faceHeight / faceWidth)
            
            // Scale face cam to PiP size
            let faceScaleX = pipWidth / faceWidth
            let faceScaleY = pipHeight / faceHeight
            faceImage = faceImage.transformed(by: CGAffineTransform(scaleX: faceScaleX, y: faceScaleY))
            
            // Position in bottom-right corner with padding
            let padding: CGFloat = 20
            let pipX = outputWidth - pipWidth - padding
            let pipY = padding  // CIImage origin is bottom-left
            faceImage = faceImage.transformed(by: CGAffineTransform(translationX: pipX, y: pipY))
            
            // Create circular mask for PiP
            let centerX = pipX + pipWidth / 2
            let centerY = pipY + pipHeight / 2
            let radius = min(pipWidth, pipHeight) / 2
            
            // Create radial gradient for circular mask
            let maskFilter = CIFilter(name: "CIRadialGradient")!
            maskFilter.setValue(CIVector(x: centerX, y: centerY), forKey: "inputCenter")
            maskFilter.setValue(radius - 2, forKey: "inputRadius0")  // Solid inner
            maskFilter.setValue(radius, forKey: "inputRadius1")       // Fade outer
            maskFilter.setValue(CIColor.white, forKey: "inputColor0")
            maskFilter.setValue(CIColor.clear, forKey: "inputColor1")
            
            if let maskImage = maskFilter.outputImage {
                // Apply mask to face image
                let blendFilter = CIFilter(name: "CIBlendWithMask")!
                blendFilter.setValue(faceImage, forKey: kCIInputImageKey)
                blendFilter.setValue(mainImage, forKey: kCIInputBackgroundImageKey)
                blendFilter.setValue(maskImage, forKey: kCIInputMaskImageKey)
                
                if let composited = blendFilter.outputImage {
                    mainImage = composited
                }
            }
        }
        
        // Render to pixel buffer
        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            print("⚠️ No pixel buffer pool")
            return
        }
        
        var newPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &newPixelBuffer)
        
        guard status == kCVReturnSuccess, let outputBuffer = newPixelBuffer else {
            print("⚠️ Failed to create pixel buffer: \(status)")
            return
        }
        
        // Crop to output size (in case mainImage is larger)
        let outputRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        context.render(mainImage, to: outputBuffer, bounds: outputRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        
        adaptor.append(outputBuffer, withPresentationTime: timestamp)
    }
    
    // MARK: - Streamer Audio Processing
    nonisolated private func processStreamerAudioFrame(_ sampleBuffer: CMSampleBuffer, timestamp: CMTime) {
        writerLock.lock()
        defer { writerLock.unlock() }
        
        guard streamerWritingStarted,
              let audioInput = streamerAudioInput,
              audioInput.isReadyForMoreMediaData else {
            return
        }
        
        audioInput.append(sampleBuffer)
    }
    
    /// Process ultra-wide camera frames: crop center horizontal strip (16:9) for landscape
    /// Ultra-wide has enough horizontal FOV that a center crop gives proper landscape content
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
        
        let frameWidth = CGFloat(CVPixelBufferGetWidth(imageBuffer))
        let frameHeight = CGFloat(CVPixelBufferGetHeight(imageBuffer))
        
        // Calculate crop: take horizontal strip from center
        // Strip has 16:9 aspect ratio: height = width * 9/16
        let cropHeight = frameWidth * 9.0 / 16.0
        let cropY = (frameHeight - cropHeight) / 2.0
        
        // Start writer on first frame
        if !landscapeWritingStarted {
            landscapeWritingStarted = true
            landscapeSessionStartTime = timestamp
            writer.startWriting()
            writer.startSession(atSourceTime: timestamp)
            
            print("📐 Ultra-wide portrait frame: \(Int(frameWidth)) x \(Int(frameHeight))")
            print("📐 Cropping center strip: \(Int(frameWidth)) x \(Int(cropHeight)) (16:9)")
            print("📐 Crop Y offset: \(Int(cropY)) (cutting top/bottom)")
            print("📐 Output: 1920 x 1080")
        }
        
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
        
        // Create CIImage and crop the center horizontal strip
        var ciImage = CIImage(cvPixelBuffer: imageBuffer)
        
        // Crop rectangle (CIImage origin is bottom-left)
        let cropRect = CGRect(x: 0, y: cropY, width: frameWidth, height: cropHeight)
        ciImage = ciImage.cropped(to: cropRect)
        
        // Translate origin to (0,0)
        ciImage = ciImage.transformed(by: CGAffineTransform(translationX: 0, y: -cropY))
        
        // Scale to 1920x1080 (NO ROTATION - crop is already landscape aspect)
        let scaleX = 1920.0 / frameWidth
        let scaleY = 1080.0 / cropHeight
        ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        // Render to pixel buffer
        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            print("⚠️ No pixel buffer pool")
            return
        }
        
        var newPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &newPixelBuffer)
        
        guard status == kCVReturnSuccess, let outputBuffer = newPixelBuffer else {
            print("⚠️ Failed to create pixel buffer: \(status)")
            return
        }
        
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
