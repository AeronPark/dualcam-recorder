import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var camera: MultiCamManager
    
    func makeUIView(context: Context) -> DualPreviewUIView {
        let view = DualPreviewUIView()
        view.camera = camera
        return view
    }
    
    func updateUIView(_ uiView: DualPreviewUIView, context: Context) {
        uiView.updatePreviews()
    }
}

class DualPreviewUIView: UIView {
    var camera: MultiCamManager?
    
    private var mainPreviewLayer: AVCaptureVideoPreviewLayer?
    private var pipContainer: UIView?
    private var pipPreviewLayer: AVCaptureVideoPreviewLayer?
    private var pipLabel: UILabel?
    
    // Single Lens crop guide overlay
    private var cropGuideTop: UIView?
    private var cropGuideBottom: UIView?
    private var cropLabel: UILabel?
    
    // PiP settings
    private var pipWidth: CGFloat = 120
    private var pipHeight: CGFloat = 68  // 16:9 default
    private let pipMargin: CGFloat = 16
    private var pipCornerRadius: CGFloat = 8
    private var isCircular = false
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        setupPiPContainer()
        setupCropGuides()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupCropGuides() {
        // Semi-transparent overlays for top and bottom (areas that get cropped)
        let topOverlay = UIView()
        topOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        topOverlay.isHidden = true
        topOverlay.isUserInteractionEnabled = false
        addSubview(topOverlay)
        cropGuideTop = topOverlay
        
        let bottomOverlay = UIView()
        bottomOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        bottomOverlay.isHidden = true
        bottomOverlay.isUserInteractionEnabled = false
        addSubview(bottomOverlay)
        cropGuideBottom = bottomOverlay
        
        // Label showing "16:9"
        let label = UILabel()
        label.text = "16:9 Landscape"
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.textAlignment = .center
        label.layer.cornerRadius = 4
        label.layer.masksToBounds = true
        label.isHidden = true
        label.isUserInteractionEnabled = false
        addSubview(label)
        cropLabel = label
    }
    
    private func setupPiPContainer() {
        let container = UIView()
        container.backgroundColor = .black
        container.layer.borderWidth = 2
        container.layer.borderColor = UIColor.white.cgColor
        container.layer.masksToBounds = true
        container.isHidden = true
        addSubview(container)
        pipContainer = container
        
        // Label
        let label = UILabel()
        label.font = .systemFont(ofSize: 9, weight: .bold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        label.textAlignment = .center
        label.layer.cornerRadius = 3
        label.layer.masksToBounds = true
        container.addSubview(label)
        pipLabel = label
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        mainPreviewLayer?.frame = bounds
        
        updatePiPLayout()
        updateCropGuideLayout()
    }
    
    private func updateCropGuideLayout() {
        guard let camera = camera else { return }
        
        let isSingleLens = camera.recordingMode == .singleLens
        
        cropGuideTop?.isHidden = !isSingleLens
        cropGuideBottom?.isHidden = !isSingleLens
        cropLabel?.isHidden = !isSingleLens
        
        guard isSingleLens else { return }
        
        // Calculate 16:9 crop area
        // Frame is 9:16 portrait, crop height = width * 9/16
        let frameWidth = bounds.width
        let cropHeight = frameWidth * 9.0 / 16.0
        let cropY = (bounds.height - cropHeight) / 2.0
        
        // Top overlay (above crop area)
        cropGuideTop?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: cropY)
        
        // Bottom overlay (below crop area)
        cropGuideBottom?.frame = CGRect(x: 0, y: cropY + cropHeight, width: bounds.width, height: bounds.height - cropY - cropHeight)
        
        // Label in center of crop area
        let labelWidth: CGFloat = 100
        let labelHeight: CGFloat = 24
        cropLabel?.frame = CGRect(
            x: (bounds.width - labelWidth) / 2,
            y: cropY + cropHeight - labelHeight - 8,
            width: labelWidth,
            height: labelHeight
        )
    }
    
    private func updatePiPLayout() {
        guard let container = pipContainer else { return }
        
        if isCircular {
            // Circular PiP for face cam (streamer mode)
            // Size based on camera's pipSize setting (scaled for preview)
            let size: CGFloat = 120 + CGFloat((camera?.pipSize ?? 0.35) * 200)  // ~140-220
            container.layer.cornerRadius = size / 2
            container.frame = CGRect(
                x: bounds.width - size - pipMargin,
                y: bounds.height - size - pipMargin - 200, // Above buttons
                width: size,
                height: size
            )
            pipPreviewLayer?.frame = container.bounds
            pipLabel?.isHidden = true
        } else {
            // Rectangular PiP for landscape (dual lens mode)
            container.layer.cornerRadius = pipCornerRadius
            let safeTop = safeAreaInsets.top + 50
            container.frame = CGRect(
                x: bounds.width - pipWidth - pipMargin,
                y: safeTop,
                width: pipWidth,
                height: pipHeight
            )
            pipPreviewLayer?.frame = container.bounds
            pipLabel?.frame = CGRect(x: 4, y: pipHeight - 16, width: 28, height: 12)
            pipLabel?.text = "16:9"
            pipLabel?.isHidden = false
        }
    }
    
    func updatePreviews() {
        guard let camera = camera else { return }
        
        // Update crop guides for single lens
        updateCropGuideLayout()
        
        // Determine mode
        let isStreamerMode = camera.recordingMode == .streamer
        
        // Update PiP style based on mode
        if isCircular != isStreamerMode {
            isCircular = isStreamerMode
            pipPreviewLayer?.removeFromSuperlayer()
            pipPreviewLayer = nil
            updatePiPLayout()
        }
        
        // Main preview (portrait from wide camera)
        if let portraitLayer = camera.portraitPreviewLayer {
            if mainPreviewLayer !== portraitLayer {
                mainPreviewLayer?.removeFromSuperlayer()
                portraitLayer.frame = bounds
                portraitLayer.videoGravity = .resizeAspectFill
                layer.insertSublayer(portraitLayer, at: 0)
                mainPreviewLayer = portraitLayer
                print("📱 Main preview connected (portrait)")
            }
        }
        
        // PiP preview based on mode
        let pipLayer: AVCaptureVideoPreviewLayer?
        if isStreamerMode {
            pipLayer = camera.faceCamPreviewLayer
        } else {
            pipLayer = camera.landscapePreviewLayer
        }
        
        if let layer = pipLayer, let container = pipContainer {
            if pipPreviewLayer !== layer {
                pipPreviewLayer?.removeFromSuperlayer()
                layer.frame = container.bounds
                layer.videoGravity = .resizeAspectFill
                if isCircular {
                    layer.cornerRadius = container.bounds.width / 2
                } else {
                    layer.cornerRadius = pipCornerRadius
                }
                container.layer.insertSublayer(layer, at: 0)
                pipPreviewLayer = layer
                container.isHidden = false
                print("📱 PiP preview connected (\(isStreamerMode ? "face cam" : "landscape"))")
            }
        } else {
            pipContainer?.isHidden = true
        }
    }
}
