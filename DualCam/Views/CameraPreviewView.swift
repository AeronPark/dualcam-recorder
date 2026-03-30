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
    
    // PiP settings (16:9 aspect ratio)
    private let pipWidth: CGFloat = 120
    private let pipHeight: CGFloat = 68  // 120 * 9/16
    private let pipMargin: CGFloat = 16
    private let pipCornerRadius: CGFloat = 8
    
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
        container.layer.cornerRadius = pipCornerRadius
        container.layer.borderWidth = 2
        container.layer.borderColor = UIColor.white.cgColor
        container.layer.masksToBounds = true
        container.isHidden = true
        addSubview(container)
        pipContainer = container
        
        // Label
        let label = UILabel()
        label.text = "16:9"
        label.font = .systemFont(ofSize: 9, weight: .bold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        label.textAlignment = .center
        label.layer.cornerRadius = 3
        label.layer.masksToBounds = true
        label.tag = 100
        container.addSubview(label)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        mainPreviewLayer?.frame = bounds
        
        if let container = pipContainer {
            let safeTop = safeAreaInsets.top + 50
            container.frame = CGRect(
                x: bounds.width - pipWidth - pipMargin,
                y: safeTop,
                width: pipWidth,
                height: pipHeight
            )
            
            pipPreviewLayer?.frame = container.bounds
            
            if let label = container.viewWithTag(100) as? UILabel {
                label.frame = CGRect(x: 4, y: pipHeight - 16, width: 28, height: 12)
            }
        }
    }
    
    func updatePreviews() {
        guard let camera = camera else { return }
        
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
        
        // PiP preview (landscape from ultra-wide camera)
        if let landscapeLayer = camera.landscapePreviewLayer,
           let container = pipContainer {
            if pipPreviewLayer !== landscapeLayer {
                pipPreviewLayer?.removeFromSuperlayer()
                landscapeLayer.frame = container.bounds
                landscapeLayer.videoGravity = .resizeAspectFill
                landscapeLayer.cornerRadius = pipCornerRadius
                container.layer.insertSublayer(landscapeLayer, at: 0)
                pipPreviewLayer = landscapeLayer
                container.isHidden = false
                print("📱 PiP preview connected (landscape)")
            }
        }
    }
}
