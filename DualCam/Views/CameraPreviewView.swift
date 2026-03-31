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
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
