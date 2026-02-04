import AVFoundation
import UIKit
import Photos
import OSLog
import Speech
import Observation

class VideoAudioRecorder{
    private let logger = Logger(subsystem: "com.yourcompany.yourapp", category: "VideoAudioRecorder")
    
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    private var isRecording = false
    private var startTime: CMTime?
    private var frameCount: Int64 = 0
    
    private let videoSettings: [String: Any]
    private let audioSettings: [String: Any]
    private let outputURL: URL
    
    // Audio recording
    private var audioEngine: AVAudioEngine?
    private var audioFormat: AVAudioFormat?
    private var audioStartTime: CMTime?
    
    // MARK: - speech reconition
    weak var viewModel: StreamSessionViewModel?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var recognizeSpeech = false
    public enum RecognizerError: Error {
        case nilRecognizer
        case notAuthorizedToRecognize
        case notPermittedToRecord
        case recognizerIsUnavailable
        
        public var message: String {
            switch self {
            case .nilRecognizer: return "Can't initialize speech recognizer"
            case .notAuthorizedToRecognize: return "Not authorized to recognize speech"
            case .notPermittedToRecord: return "Not permitted to record audio"
            case .recognizerIsUnavailable: return "Recognizer is unavailable"
            }
        }
    }
    
    // MARK: - Initialization
    
    init(width: Int, height: Int, fps: Int32 = 24,
         recognizeSpeech: Bool) {
        
        self.recognizeSpeech = recognizeSpeech
        videoSettings = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6000000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        // Audio settings - standard settings for high quality
        audioSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]
        
        // Create temporary output URL
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording_\(Date().timeIntervalSince1970).mp4"
        outputURL = tempDir.appendingPathComponent(fileName)
    }
    
    // MARK: - Recording Control
    
    func startRecording() throws {
        guard !isRecording else {
            throw RecorderError.alreadyRecording
        }
        
        // Request microphone permission
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true)
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: outputURL)
        
        // Create asset writer
        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        guard let assetWriter = assetWriter else {
            throw RecorderError.failedToCreateWriter
        }
        
        // Setup video input
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = true
        
        guard let videoInput = videoInput, assetWriter.canAdd(videoInput) else {
            throw RecorderError.cannotAddVideoInput
        }
        assetWriter.add(videoInput)
        
        // Setup pixel buffer adaptor
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: videoSettings[AVVideoWidthKey] ?? 0,
            kCVPixelBufferHeightKey as String: videoSettings[AVVideoHeightKey] ?? 0
        ]
        
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )
        
        // Setup audio input
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput?.expectsMediaDataInRealTime = true
        
        guard let audioInput = audioInput, assetWriter.canAdd(audioInput) else {
            throw RecorderError.cannotAddAudioInput
        }
        assetWriter.add(audioInput)
        
        // Start writing
        guard assetWriter.startWriting() else {
            throw RecorderError.failedToStartWriting(assetWriter.error)
        }
        
        assetWriter.startSession(atSourceTime: .zero)
        
        // Setup audio capture
        try setupAudioCapture()
        
        isRecording = true
        startTime = nil
        audioStartTime = nil
        frameCount = 0
        
        print("Recording started: \(outputURL.path)")
    }
    
    // MARK: - Audio Capture
    
    private func setupAudioCapture() throws {
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw RecorderError.failedToCreateAudioEngine
        }
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        audioFormat = inputFormat
        
        if (recognizeSpeech) {
            Task {
                do {
                    guard await SFSpeechRecognizer.hasAuthorizationToRecognize() else {
                        throw RecognizerError.notAuthorizedToRecognize
                    }
                    guard await AVAudioSession.sharedInstance().hasPermissionToRecord() else {
                        throw RecognizerError.notPermittedToRecord
                    }
                } catch {
                    transcribe(error)
                }
            }
            
            recognizer = SFSpeechRecognizer()
            request = SFSpeechAudioBufferRecognitionRequest()
            request?.shouldReportPartialResults = true
            
            guard let recognizer, let request else {
                throw RecorderError.failedToCreateAudioEngine
            }
            self.task = recognizer.recognitionTask(with: request, resultHandler: { [weak self] result, error in
                self?.recognitionHandler(audioEngine: audioEngine, result: result, error: error)
            })
        }
        
        // Install tap to capture audio
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
            
            guard let self = self else {
                return
            }
            self.appendAudioBuffer(buffer, time: time)
            
            if (self.recognizeSpeech) {
                self.request?.append(buffer)
            }
        }
        
        // Start audio engine
        try audioEngine.start()
    }
    private func recognitionHandler(audioEngine: AVAudioEngine, result: SFSpeechRecognitionResult?, error: Error?) {
        let receivedFinalResult = result?.isFinal ?? false
        let receivedError = error != nil
        
        if receivedFinalResult || receivedError {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        if let result {
            let x = result.bestTranscription.formattedString
            logger.notice("In rec:\(x)")
            transcribe(result.bestTranscription.formattedString)
        }
    }
    
    // MARK: - Gynmastics to call StreamSessionView
    private func transcribe(_ message: String) {
        Task { @MainActor in
            await self.viewModel?.updateTranscript(message)
        }
    }
    private func transcribe(_ error: Error) {
        var errorMessage = ""
        if let error = error as? RecognizerError {
            errorMessage += error.message
        } else {
            errorMessage += error.localizedDescription
        }
        logger.notice("<< \(errorMessage) >>")
    }
    
    private func stopAudioCapture() {
        task?.cancel()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        request = nil
        task = nil
    }
    
    private func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard isRecording,
              let audioInput = audioInput,
              audioInput.isReadyForMoreMediaData else {
            return
        }
        
        // Convert AVAudioPCMBuffer to CMSampleBuffer
        guard let sampleBuffer = createSampleBuffer(from: buffer, time: time) else {
            print("Failed to create audio sample buffer")
            return
        }
        
        let success = audioInput.append(sampleBuffer)
        if !success {
            print("Failed to append audio buffer")
        }
    }
    
    private func createSampleBuffer(from buffer: AVAudioPCMBuffer, time: AVAudioTime) -> CMSampleBuffer? {
        guard let formatDescription = createAudioFormatDescription(from: buffer.format) else {
            print("Failed to create audio format description")
            return nil
        }
        
        var sampleBuffer: CMSampleBuffer?
        let frameCount = Int(buffer.frameLength)
        
        // Set audio start time on first buffer
        if audioStartTime == nil {
            audioStartTime = CMTimeMake(
                value: Int64(time.sampleTime),
                timescale: Int32(buffer.format.sampleRate)
            )
        }
        
        // Calculate presentation time relative to start
        let currentTime = CMTimeMake(
            value: Int64(time.sampleTime),
            timescale: Int32(buffer.format.sampleRate)
        )
        
        let presentationTime: CMTime
        if let audioStartTime = audioStartTime {
            presentationTime = CMTimeSubtract(currentTime, audioStartTime)
        } else {
            presentationTime = currentTime
        }
        
        var timing = CMSampleTimingInfo(
            duration: CMTimeMake(value: Int64(frameCount), timescale: Int32(buffer.format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        
        // Create block buffer from audio buffer list
        var blockBuffer: CMBlockBuffer?
        let audioBufferList = buffer.mutableAudioBufferList
        
        let status1 = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: Int(audioBufferList.pointee.mBuffers.mDataByteSize),
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: Int(audioBufferList.pointee.mBuffers.mDataByteSize),
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status1 == kCMBlockBufferNoErr, let blockBuffer = blockBuffer else {
            print("Failed to create block buffer: \(status1)")
            return nil
        }
        
        // Replace data in block buffer with audio data
        let status2 = CMBlockBufferReplaceDataBytes(
            with: audioBufferList.pointee.mBuffers.mData!,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: Int(audioBufferList.pointee.mBuffers.mDataByteSize)
        )
        
        guard status2 == kCMBlockBufferNoErr else {
            print("Failed to replace block buffer data: \(status2)")
            return nil
        }
        
        // Create sample buffer with the block buffer
        let status3 = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        
        guard status3 == noErr else {
            print("Failed to create sample buffer: \(status3)")
            return nil
        }
        
        return sampleBuffer
    }
    
    private func createAudioFormatDescription(from format: AVAudioFormat) -> CMAudioFormatDescription? {
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        
        return status == noErr ? description : nil
    }
    
    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        guard isRecording else {
            completion(.failure(RecorderError.notRecording))
            return
        }
        
        isRecording = false
        
        // Stop audio capture
        stopAudioCapture()
        
        // Mark inputs as finished
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        
        // Capture values we need before entering the closure
        guard let assetWriter = self.assetWriter else {
            completion(.failure(RecorderError.failedToCreateWriter))
            return
        }
        let outputURL = self.outputURL
        
        // Finish writing
        assetWriter.finishWriting { [weak self] in
            guard let self = self else { return }
            
            if let error = assetWriter.error {
                completion(.failure(error))
                return
            }
            
            // Save to Photos library
            Task { @MainActor in
                self.saveToPhotosLibrary(url: outputURL, completion: completion)
            }
        }
    }
    // MARK: - Pixel Buffer Creation
    
    private func createPixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        let width = Int(videoSettings[AVVideoWidthKey] as? Int ?? Int(image.size.width))
        let height = Int(videoSettings[AVVideoHeightKey] as? Int ?? Int(image.size.height))
        
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let pixelData = CVPixelBufferGetBaseAddress(buffer)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }
        
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPopContext()
        
        return buffer
    }
    
    // MARK: - Save to Photos
    
    private func saveToPhotosLibrary(url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                completion(.failure(RecorderError.photoLibraryAccessDenied))
                return
            }
            
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                if success {
                    print("Video saved to Photos library successfully")
                    completion(.success(url))
                } else if let error = error {
                    print("Failed to save video: \(error.localizedDescription)")
                    completion(.failure(error))
                } else {
                    completion(.failure(RecorderError.unknownError))
                }
            }
        }
    }
    
    // MARK: - Frame Processing
    
    func appendVideoFrame(_ image: UIImage, presentationTime: CMTime? = nil) {
        guard isRecording,
              let videoInput = videoInput,
              let pixelBufferAdaptor = pixelBufferAdaptor,
              videoInput.isReadyForMoreMediaData else {
            return
        }
        
        // Calculate presentation time
        let timestamp: CMTime
        if let presentationTime = presentationTime {
            timestamp = presentationTime
        } else {
            // Use frame count to calculate time (assuming 24 fps)
            //let fps: Int64 = 24
            let fps: Int32 = 24
            timestamp = CMTimeMake(value: frameCount, timescale: fps)
        }
        
        // Set start time on first frame
        if startTime == nil {
            startTime = timestamp
        }
        
        // Create pixel buffer from UIImage
        guard let pixelBuffer = createPixelBuffer(from: image) else {
            print("Failed to create pixel buffer from image")
            return
        }
        
        // Append pixel buffer
        let success = pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: timestamp)
        if success {
            frameCount += 1
        } else {
            print("Failed to append pixel buffer at time: \(timestamp.seconds)")
        }
    }
    
    // MARK: - Error Types
    
    enum RecorderError: LocalizedError {
        case alreadyRecording
        case notRecording
        case failedToCreateWriter
        case cannotAddVideoInput
        case cannotAddAudioInput
        case failedToStartWriting(Error?)
        case failedToCreateAudioEngine
        case photoLibraryAccessDenied
        case unknownError
        
        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "Recording is already in progress"
            case .notRecording:
                return "No recording in progress"
            case .failedToCreateWriter:
                return "Failed to create asset writer"
            case .cannotAddVideoInput:
                return "Cannot add video input to asset writer"
            case .cannotAddAudioInput:
                return "Cannot add audio input to asset writer"
            case .failedToStartWriting(let error):
                return "Failed to start writing: \(error?.localizedDescription ?? "unknown error")"
            case .failedToCreateAudioEngine:
                return "Failed to create audio engine"
            case .photoLibraryAccessDenied:
                return "Photo library access denied"
            case .unknownError:
                return "An unknown error occurred"
            }
        }
    }
}
/*
 // Alternative: Single tap, dual purpose
 inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, time in
     // Feed to speech recognition
     self?.recognitionRequest?.append(buffer)
     
     // Feed to video file
     guard let self = self,
           self.isRecording,
           let audioInput = self.audioWriterInput,
           audioInput.isReadyForMoreMediaData else {
         return
     }
     
     let presentationTime = self.convertAudioTime(time)
     if let sampleBuffer = self.createSampleBuffer(from: buffer, presentationTime: presentationTime) {
         audioInput.append(sampleBuffer)
     }
 }
 */
