//
//  SpeechToSpeechVC.swift
//  VideoOverlayProcess
//
//  Created by Atik Hasan on 5/21/25.
//


import UIKit
import AVFoundation
import Speech

class SpeechToSpeechVC: UIViewController, AVAudioRecorderDelegate {
    
    var audioPlayer: AVAudioPlayer?
    var audioRecorder: AVAudioRecorder?
    var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    var recognitionTask: SFSpeechRecognitionTask?
    let audioEngine = AVAudioEngine()
    
    var silenceTimer: Timer?
    var recognizedText: String = ""
    var model = "gpt-3.5-turbo"
    private let apiURL = "https://api.openai.com/v1/chat/completions"
    let apiKey = "give_your_api_key_here"

    
    override func viewDidLoad() {
        super.viewDidLoad()
        requestPermissions()
        
    }

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            switch authStatus {
            case .authorized:
                print("Speech recognition authorized")
            default:
                print("Speech recognition not authorized")
            }
        }

        AVAudioSession.sharedInstance().requestRecordPermission { allowed in
            print("Microphone permission: \(allowed)")
        }
    }

    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)

            let settings = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 12000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            let fileURL = getDocumentsDirectory().appendingPathComponent("\(UUID().uuidString)recordedSpeech.m4a")
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            print("Recording audio to: \(fileURL)")
        } catch {
            print("Audio Recorder setup failed: \(error)")
        }
        startSpeechRecognition()
    }

    

    func startSpeechRecognition() {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        guard let recognitionRequest = recognitionRequest else { return }

        recognitionRequest.shouldReportPartialResults = true
        let inputNode = audioEngine.inputNode
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            if let result = result {
                self.recognizedText = result.bestTranscription.formattedString
                print("Text: \(self.recognizedText)")

                //  Reset silence timer on every update
                self.silenceTimer?.invalidate()
                self.silenceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                    self.handleFinalRecognition()
                }
            }

            if error != nil {
                print(" Speech recognition error: \(error!.localizedDescription)")
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                self.recognitionTask = nil
                self.recognitionRequest = nil
            }
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print(" Audio Engine couldn't start: \(error.localizedDescription)")
        }

        print("Listening...")
    }
    

    func handleFinalRecognition() {
        print(" 2 seconds silence detected. Finalizing...")

        let finalText = self.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recognizedText = ""

        if finalText.isEmpty { return }

        self.audioEngine.stop()
        self.audioEngine.inputNode.removeTap(onBus: 0)
        self.recognitionRequest?.endAudio()
        self.recognitionRequest = nil
        self.recognitionTask = nil
        self.audioRecorder?.stop()
        
        let text  = "give me this \(finalText) answer miaximum 40 words, if possible to give me answer minimum of 40 seconds, Then you pay the minimum of answer"
        
        self.podcastGenerateToGPT(text){
            response in
            guard let response = response else {
                return
            }
            print(response)
            self.streamTextToSpeech(text: response) { fileURL in
                if let url = fileURL {
                    print("Speech file saved at: \(url)")
                    self.playAudioWithAVAudioPlayer(from: url)
                }
            }
        }
            
    }


    func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        
        audioEngine.stop()
        recognitionRequest?.endAudio()
    }

    func getDocumentsDirectory() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    @IBAction func startButtonTapped(_ sender: UIButton) {
        startRecording()
    }
}

// MARK: -------- Api Call ----------

extension SpeechToSpeechVC {

    func podcastGenerateToGPT(_ question: String, completion: @escaping (String?) -> Void) {
        // Prepare the request body
        let parameters: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": question]
            ],
            "max_tokens": 150
        ]
        
        // Convert parameters to JSON data
        guard let jsonData = try? JSONSerialization.data(withJSONObject: parameters, options: []) else {
            print("Failed to create request data.")
            completion(nil)
            return
        }
        
        // Create the request
        var request = URLRequest(url: URL(string: apiURL)!)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        // Send the request
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            // Handle the error case
            if let error = error {
                DispatchQueue.main.async {
                    print("Request failed with error: \(error.localizedDescription)")
                    completion(nil)
                }
                return
            }
            
            // Parse the response
            guard let data = data else {
                DispatchQueue.main.async {
                    print("No data received.")
                    completion(nil)
                }
                return
            }
            
            // Print the raw JSON response for debugging
            if let httpResponse = response as? HTTPURLResponse {
                print("HTTP Status Code: \(httpResponse.statusCode)")
            }
            
            do {
                // Parse the JSON response
                if let jsonResponse = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    print("Raw JSON Response: \(jsonResponse)")
                    
                    if let choices = jsonResponse["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let responseText = firstChoice["message"] as? [String: Any],
                       let content = responseText["content"] as? String {
                        DispatchQueue.main.async {
                            // Return the response text via the completion handler
                            completion(content)
                        }
                    } else {
                        DispatchQueue.main.async {
                            print("Unexpected response format: \(jsonResponse)")
                            completion(nil)
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        print("Failed to parse response.")
                        completion(nil)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    print("Error parsing response: \(error.localizedDescription)")
                    completion(nil)
                }
            }
        }
        
        task.resume()
    }
    
    
    func streamTextToSpeech(text: String, completion: @escaping (URL?) -> Void) {
        let url = URL(string: "https://api.openai.com/v1/audio/speech")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "input": text,
            "voice": "coral",
            "response_format": "mp3",
            "instructions": "Speak in a cheerful and positive tone."
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                print("Error: \(error?.localizedDescription ?? "Unknown error")")
                completion(nil)
                return
            }
            
            if let responseString = String(data: data, encoding: .utf8) {
                print("Response as string: \(responseString)")
            }

            if let fileURL = self.saveAudioToDocuments(data: data) {
                completion(fileURL)
            } else {
                completion(nil)
            }
        }
        
        task.resume()
    }
    
    
    func playAudioWithAVAudioPlayer(from url: URL) {
        print("Playing audio from: \(url)")
        print("File exists: \(FileManager.default.fileExists(atPath: url.path))")
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)

            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            audioPlayer?.delegate = self
            print("অডিও প্লে হচ্ছে...")
        } catch {
            print("Audio Player setup failed: \(error.localizedDescription)")
        }
    }

    
    func saveAudioToDocuments(data: Data) -> URL? {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let filename = "\(UUID().uuidString).mp3"
        let fileURL = documentsURL.appendingPathComponent(filename)
        
        do {
            try data.write(to: fileURL)
            print("Permanently saved at: \(fileURL)")
            return fileURL
        } catch {
            print("Error saving audio: \(error)")
            return nil
        }
    }

}


extension SpeechToSpeechVC: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("Audio finished playing")
        self.startRecording()
    }
}
