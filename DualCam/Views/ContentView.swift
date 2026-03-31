import SwiftUI

struct ContentView: View {
    @StateObject private var camera = MultiCamManager()
    
    var body: some View {
        ZStack {
            // Camera Preview
            CameraPreviewView(camera: camera)
                .ignoresSafeArea()
            
            // UI Overlay
            VStack {
                // Status bar
                HStack {
                    // Recording indicator
                    if camera.isRecording {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.red)
                                .frame(width: 10, height: 10)
                            Text(formatDuration(camera.recordingDuration))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.6))
                        .cornerRadius(16)
                    }
                    
                    Spacer()
                    
                    // Session status
                    HStack(spacing: 6) {
                        Circle()
                            .fill(camera.isSessionRunning ? .green : .orange)
                            .frame(width: 8, height: 8)
                        Text(camera.isSessionRunning ? "Ready" : "Starting...")
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6))
                    .cornerRadius(12)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                
                Spacer()
                
                // Error message
                if let error = camera.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(10)
                        .background(.red.opacity(0.8))
                        .cornerRadius(8)
                        .padding(.bottom, 10)
                }
                
                // PiP Size slider (only show in Streamer mode)
                if camera.recordingMode == .streamer {
                    VStack(spacing: 4) {
                        Text("Face Cam Size")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                        HStack {
                            Image(systemName: "person.crop.circle")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.6))
                            Slider(value: $camera.pipSize, in: 0.2...0.5, step: 0.05)
                                .accentColor(.yellow)
                                .frame(width: 150)
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title3)
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.5))
                    .cornerRadius(12)
                    .padding(.bottom, 10)
                }
                
                // Mode selector
                HStack(spacing: 0) {
                    ForEach(RecordingMode.allCases, id: \.self) { mode in
                        Button(action: {
                            camera.switchMode(to: mode)
                        }) {
                            Text(mode.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(camera.recordingMode == mode ? .black : .white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    camera.recordingMode == mode 
                                        ? Color.yellow 
                                        : Color.black.opacity(0.5)
                                )
                        }
                        .disabled(camera.isRecording)
                    }
                }
                .cornerRadius(25)
                .overlay(
                    RoundedRectangle(cornerRadius: 25)
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
                .padding(.bottom, 20)
                
                // Record button
                Button(action: {
                    if camera.isRecording {
                        camera.stopRecording()
                    } else {
                        camera.startRecording()
                    }
                }) {
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 80, height: 80)
                        
                        if camera.isRecording {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.red)
                                .frame(width: 32, height: 32)
                        } else {
                            Circle()
                                .fill(.red)
                                .frame(width: 64, height: 64)
                        }
                    }
                }
                .disabled(!camera.isSessionRunning)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            camera.checkPermissions()
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#Preview {
    ContentView()
}
