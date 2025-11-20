Here is the complete, detailed implementation plan formatted as a Markdown file. You can copy the code block below and save it as implementation_plan.md.

Markdown

# Langscape Neuro-Spatial Implementation Plan

**Objective:** Transformation of Langscape from a 2D video-stream classifier into a spatial AR experience with intelligent context awareness and cloud-based "High-Res Referee" capabilities.

---

## Phase 1: Intelligent Context Detection

**Goal:** Automatically detect the user's environment (e.g., "Gym", "Kitchen") to load the correct vocabulary dictionary without manual input.

**Strategy:** Reuse the existing `MobileCLIP` model in `VLMDetector` to classify the entire scene frame against a list of 20 common life contexts.

### 1.1 Update `VLMDetector.swift`

Modify `DetectionKit/Sources/DetectionKit/VLMDetector.swift` to include the scene classification logic.

```swift
// DetectionKit/Sources/DetectionKit/VLMDetector.swift

public func classifyScene(pixelBuffer: CVPixelBuffer) async -> String? {
    // The 20 "Life Contexts" - Most common environments for language learners
    let contexts = [
        "Kitchen", "Living Room", "Bedroom", "Bathroom", "Office",
        "Classroom", "Gym", "Park", "Supermarket", "Cafe",
        "Restaurant", "Street", "Bus Station", "Train Station", "Airport",
        "Hospital", "Library", "Clothing Store", "Bakery", "Pharmacy"
    ]
    
    // 1. Embed these contexts (Perform once during init if possible to save compute)
    let contextEmbeddings = contexts.map { tokenizer.encode("A photo of a \($0)") }
    
    // 2. Embed the image using MobileCLIP S2
    guard let imageEmbedding = embedImage(pixelBuffer) else { return nil }
    
    // 3. Find best match using Dot Product
    let (bestIndex, confidence) = findBestMatch(image: imageEmbedding, candidates: contextEmbeddings)
    
    // 4. Threshold Verification (0.25 is a standard robust threshold for CLIP)
    return confidence > 0.25 ? contexts[bestIndex] : "General"
}
Phase 2: Dynamic Vision Pipeline (YOLO-World)
Goal: Generate "baked" detection models for each of the 20 contexts. This removes the heavy text encoder from runtime, allowing the app to run at ~30FPS on iPhone.

2.1 Instructions: Getting the YOLO-World Model
You do not need to manually download model weights. The script below uses the ultralytics library, which automatically handles downloading the yolov8s-worldv2.pt file (~50MB) if it is not found locally.

Install Dependencies:

Bash

pip install ultralytics
2.2 The Master Export Script
Save this file as Scripts/export_all_contexts.py. It contains the optimized dictionary of 1,000 words (20 contexts × 50 nouns).

Python

from ultralytics import YOLOWorld
import os

# 1. Initialize the Model (Auto-downloads 'yolov8s-worldv2.pt' if missing)
print("Loading YOLO-World (v2 Small)...")
model = YOLOWorld('yolov8s-worldv2.pt') 

# 2. The Master Dictionary: 20 Contexts x 50 Common Nouns
contexts = {
    "Kitchen": [
        "fridge", "oven", "microwave", "sink", "dishwasher", "toaster", "kettle", "blender", "stove", "cabinet",
        "drawer", "plate", "bowl", "cup", "mug", "glass", "fork", "spoon", "knife", "pan", "pot", "lid",
        "spatula", "whisk", "ladle", "grater", "peeler", "cutting board", "colander", "apron", "napkin",
        "paper towel", "trash can", "sponge", "soap", "counter", "faucet", "freezer", "ice cube tray",
        "spice jar", "olive oil", "salt shaker", "pepper grinder", "coffee maker", "tea pot", "kitchen timer",
        "oven mitt", "tongs", "measuring cup", "rolling pin"
    ],
    "Living Room": [
        "sofa", "armchair", "coffee table", "television", "tv stand", "remote", "rug", "lamp", "cushion",
        "curtain", "blinds", "bookshelf", "fireplace", "mantel", "vase", "painting", "photo frame", "clock",
        "plant", "pot", "speaker", "candle", "coaster", "magazine", "book", "blanket", "throw pillow",
        "side table", "floor lamp", "ceiling fan", "light switch", "outlet", "window", "door", "wall",
        "carpet", "ottoman", "recliner", "bean bag", "console", "wifi router", "cable box", "dvd player",
        "video game console", "controller", "headset", "laptop", "tablet", "charger", "mirror"
    ],
    "Bedroom": [
        "bed", "mattress", "pillow", "duvet", "blanket", "sheet", "headboard", "nightstand", "alarm clock",
        "lamp", "wardrobe", "closet", "hanger", "drawer", "mirror", "dresser", "rug", "curtain", "blinds",
        "window", "slipper", "pajamas", "robe", "laundry basket", "trash can", "charger", "phone", "book",
        "glasses", "jewelry box", "perfume", "lotion", "tissue box", "teddy bear", "fan", "heater",
        "air conditioner", "light switch", "painting", "poster", "laptop", "desk", "chair", "shelf",
        "makeup", "comb", "brush", "sock", "shoe", "hat"
    ],
    "Bathroom": [
        "toilet", "sink", "bathtub", "shower", "shower curtain", "faucet", "mirror", "towel", "towel rack",
        "toilet paper", "plunger", "toilet brush", "soap", "shampoo", "conditioner", "body wash", "sponge",
        "loofah", "toothbrush", "toothpaste", "floss", "mouthwash", "razor", "shaving cream", "lotion",
        "deodorant", "comb", "hairbrush", "hair dryer", "straightener", "makeup", "lipstick", "mascara",
        "nail polish", "cotton ball", "q-tip", "trash can", "scale", "bath mat", "tile", "drain", "shelf",
        "cabinet", "medicine cabinet", "perfume", "cologne", "robe", "slipper", "rubber duck", "basket"
    ],
    "Office": [
        "desk", "office chair", "computer", "monitor", "keyboard", "mouse", "mousepad", "laptop", "tablet",
        "printer", "scanner", "copier", "shredder", "phone", "headset", "webcam", "microphone", "speaker",
        "lamp", "stapler", "staples", "tape", "tape dispenser", "scissors", "paperclip", "binder clip",
        "thumbtack", "corkboard", "whiteboard", "marker", "eraser", "pen", "pencil", "highlighter", "notebook",
        "notepad", "sticky note", "folder", "file cabinet", "trash can", "recycling bin", "calendar", "clock",
        "bookshelf", "book", "plant", "coffee mug", "water bottle", "backpack", "briefcase"
    ],
    "Classroom": [
        "desk", "chair", "table", "whiteboard", "blackboard", "chalk", "marker", "eraser", "projector",
        "screen", "computer", "laptop", "tablet", "bookshelf", "book", "textbook", "notebook", "binder",
        "folder", "paper", "pencil", "pen", "ruler", "eraser", "sharpener", "scissors", "glue", "tape",
        "stapler", "calculator", "globe", "map", "flag", "clock", "calendar", "poster", "chart", "trash can",
        "recycling bin", "backpack", "lunchbox", "water bottle", "teacher", "student", "uniform", "coat rack",
        "cubby", "locker", "speaker", "door"
    ],
    "Gym": [
        "treadmill", "elliptical", "stationary bike", "rowing machine", "dumbbell", "barbell", "weight plate",
        "kettlebell", "bench", "squat rack", "pull-up bar", "dip bar", "cable machine", "leg press",
        "yoga mat", "foam roller", "medicine ball", "stability ball", "jump rope", "resistance band",
        "punching bag", "boxing glove", "mirror", "scale", "water fountain", "water bottle", "shaker bottle",
        "towel", "locker", "lock", "bench", "shower", "sauna", "clock", "timer", "speaker", "fan",
        "chalk", "belt", "shoes", "sneakers", "shorts", "leggings", "tank top", "headband", "sweatband",
        "monitor", "tv", "gym bag", "trainer"
    ],
    "Park": [
        "bench", "tree", "bush", "flower", "grass", "path", "sidewalk", "trash can", "recycling bin",
        "lamp post", "fountain", "statue", "pond", "duck", "bird", "squirrel", "dog", "leash", "bicycle",
        "skateboard", "scooter", "stroller", "playground", "swing", "slide", "seesaw", "monkey bars",
        "sandbox", "picnic table", "grill", "gazebo", "pavilion", "restroom", "sign", "fence", "gate",
        "bridge", "rock", "stone", "cloud", "sun", "sky", "ball", "frisbee", "kite", "drone", "runner",
        "cyclist", "pedestrian", "car"
    ],
    "Supermarket": [
        "cart", "basket", "shelf", "aisle", "freezer", "fridge", "cash register", "conveyor belt", "scale",
        "scanner", "bag", "receipt", "produce", "fruit", "vegetable", "apple", "banana", "orange", "bread",
        "milk", "egg", "cheese", "meat", "chicken", "fish", "cereal", "rice", "pasta", "can", "jar",
        "bottle", "box", "price tag", "sign", "employee", "customer", "checkout", "kiosk", "money", "card",
        "wallet", "purse", "scale", "mop", "bucket", "broom", "display", "sample", "coupon", "flyer"
    ],
    "Cafe": [
        "table", "chair", "booth", "stool", "counter", "barista", "espresso machine", "coffee grinder",
        "blender", "kettle", "fridge", "display case", "pastry", "croissant", "muffin", "cake", "cookie",
        "sandwich", "salad", "menu", "board", "cup", "mug", "glass", "straw", "lid", "sleeve", "napkin",
        "sugar", "creamer", "stirrer", "spoon", "fork", "knife", "plate", "tray", "trash can", "recycling bin",
        "laptop", "wifi", "outlet", "plant", "painting", "light", "door", "window", "sign", "customer",
        "line", "register"
    ],
    "Restaurant": [
        "table", "chair", "booth", "tablecloth", "napkin", "silverware", "fork", "knife", "spoon", "plate",
        "bowl", "glass", "wine glass", "menu", "candle", "vase", "flower", "salt shaker", "pepper shaker",
        "waiter", "waitress", "chef", "host", "kitchen", "stove", "oven", "grill", "fridge", "sink",
        "tray", "stand", "check", "bill", "credit card", "terminal", "sign", "door", "window", "curtain",
        "light", "chandelier", "artwork", "restroom", "bar", "stool", "bottle", "cork", "bucket", "ice",
        "bread", "basket"
    ],
    "Street": [
        "car", "truck", "bus", "motorcycle", "bicycle", "scooter", "van", "taxi", "police car", "ambulance",
        "firetruck", "traffic light", "stop sign", "street sign", "crosswalk", "sidewalk", "curb", "road",
        "lane", "pavement", "manhole", "drain", "lamp post", "fire hydrant", "parking meter", "trash can",
        "mailbox", "newsstand", "bench", "tree", "building", "store", "window", "door", "pedestrian",
        "driver", "cyclist", "pigeon", "dog", "leash", "stroller", "umbrella", "rain", "puddle", "snow",
        "bridge", "tunnel", "fence", "wall", "graffiti"
    ],
    "Bus Station": [
        "bus", "stop", "shelter", "bench", "schedule", "map", "sign", "screen", "ticket machine", "ticket",
        "card reader", "turnstile", "platform", "curb", "lane", "driver", "passenger", "line", "luggage",
        "suitcase", "backpack", "purse", "trash can", "recycling bin", "lamp post", "camera", "speaker",
        "announcement", "clock", "roof", "pillar", "wall", "window", "door", "wheel", "tire", "mirror",
        "wiper", "headlight", "taillight", "number", "destination", "seat", "handle", "pole", "bell",
        "button", "card", "pass", "kiosk"
    ],
    "Train Station": [
        "train", "tracks", "platform", "bench", "ticket machine", "ticket", "turnstile", "gate", "screen",
        "schedule", "clock", "sign", "map", "escalator", "stairs", "elevator", "tunnel", "bridge",
        "roof", "column", "light", "camera", "speaker", "announcement", "kiosk", "shop", "cafe",
        "vending machine", "trash can", "recycling bin", "passenger", "conductor", "guard", "luggage",
        "suitcase", "backpack", "bicycle", "wheelchair", "stroller", "rail", "sleeper", "gravel",
        "electric line", "pantograph", "locomotive", "wagon", "door", "window", "seat", "handle"
    ],
    "Airport": [
        "airplane", "runway", "gate", "terminal", "check-in", "counter", "kiosk", "screen", "schedule",
        "luggage", "suitcase", "bag", "conveyor belt", "security", "scanner", "tray", "passport", "ticket",
        "boarding pass", "pilot", "flight attendant", "passenger", "seat", "window", "cart", "wheelchair",
        "stroller", "escalator", "moving walkway", "elevator", "stairs", "shop", "restaurant", "cafe",
        "restroom", "sign", "clock", "announcement", "speaker", "control tower", "tarmac", "bus", "truck",
        "fuel truck", "stairs truck", "cone", "vest", "badge", "metal detector", "x-ray"
    ],
    "Hospital": [
        "bed", "stretcher", "wheelchair", "walker", "crutches", "cane", "doctor", "nurse", "surgeon",
        "patient", "scrubs", "coat", "mask", "gloves", "stethoscope", "thermometer", "monitor", "screen",
        "iv stand", "drip", "needle", "syringe", "bandage", "cast", "medicine", "pill", "bottle",
        "tray", "cart", "ambulance", "siren", "light", "sign", "reception", "desk", "computer", "phone",
        "chair", "waiting room", "magazine", "tv", "elevator", "stairs", "door", "hallway", "room",
        "curtain", "sink", "soap", "sanitizer"
    ],
    "Library": [
        "bookshelf", "book", "magazine", "newspaper", "desk", "table", "chair", "armchair", "computer",
        "monitor", "keyboard", "mouse", "printer", "scanner", "copier", "librarian", "patron", "card",
        "scanner", "cart", "stairs", "elevator", "lamp", "light", "window", "door", "carpet", "quiet sign",
        "poster", "bulletin board", "clock", "plant", "trash can", "recycling bin", "outlet", "wifi",
        "headphone", "tablet", "ebook", "audiobook", "cd", "dvd", "catalog", "index", "pen", "pencil",
        "paper", "notebook", "backpack", "bag"
    ],
    "Clothing Store": [
        "rack", "shelf", "hanger", "mannequin", "mirror", "fitting room", "curtain", "bench", "counter",
        "register", "cashier", "customer", "bag", "receipt", "tag", "sign", "sale", "shirt", "t-shirt",
        "blouse", "sweater", "hoodie", "jacket", "coat", "pants", "jeans", "shorts", "skirt", "dress",
        "suit", "tie", "belt", "hat", "cap", "beanie", "scarf", "gloves", "sock", "shoe", "sneaker",
        "boot", "sandal", "heel", "underwear", "bra", "swimsuit", "jewelry", "watch", "glasses", "sunglasses"
    ],
    "Bakery": [
        "bread", "baguette", "roll", "bun", "croissant", "danish", "muffin", "scone", "donut", "bagel",
        "cake", "slice", "pie", "tart", "cookie", "brownie", "pastry", "cupcake", "display case", "tray",
        "tongs", "bag", "box", "napkin", "menu", "price tag", "sign", "baker", "apron", "hat", "oven",
        "mixer", "bowl", "flour", "sugar", "dough", "rolling pin", "cutter", "table", "chair", "counter",
        "register", "coffee", "tea", "milk", "juice", "customer", "window", "door", "smell"
    ],
    "Pharmacy": [
        "counter", "register", "pharmacist", "technician", "customer", "prescription", "pill", "tablet",
        "capsule", "bottle", "jar", "box", "blister pack", "medicine", "vitamin", "supplement", "shelf",
        "aisle", "cart", "basket", "crutches", "cane", "walker", "wheelchair", "brace", "bandage",
        "band-aid", "gauze", "tape", "thermometer", "mask", "gloves", "sanitizer", "soap", "shampoo",
        "conditioner", "lotion", "cream", "ointment", "toothpaste", "toothbrush", "floss", "mouthwash",
        "razor", "shaving cream", "makeup", "candy", "drink", "magazine", "card"
    ]
}

# 3. Export Loop
os.makedirs("exported_models", exist_ok=True)

for context_name, vocabulary in contexts.items():
    print(f"Exporting context: {context_name} ({len(vocabulary)} words)...")
    
    # Set the vocab
    model.set_classes(vocabulary)
    
    # Export to CoreML (Int8 Quantization + NMS)
    # The filename will be 'yolo_world_{context}.mlpackage'
    success = model.export(
        format='coreml', 
        int8=True, 
        nms=True, 
        # Simplify filename for the app: 'kitchen', 'gym', etc.
        name=f"yolo_world_{context_name.lower().replace(' ', '_')}" 
    )
    
    if success:
        print(f"✅ Successfully exported {context_name}")
    else:
        print(f"❌ Failed to export {context_name}")

print("🎉 All contexts exported!")
2.3 Dynamic Model Loading (Swift)
Refactor YOLOInterpreter.swift to load these exported models based on the detected context.

Swift

// DetectionKit/Sources/DetectionKit/YOLOInterpreter.swift

public actor YOLOInterpreter: DetectionService {
    private var visionModel: VNCoreMLModel?
    
    public func loadContext(_ contextName: String) async throws {
        let modelName = "yolo_world_\(contextName.lowercased().replacingOccurrences(of: " ", with: "_"))"
        
        guard let url = Bundle.module.url(forResource: modelName, withExtension: "mlmodelc") else {
            // Fallback to General or Kitchen if specific context missing
            try await loadContext("kitchen") 
            return
        }
        
        let model = try MLModel(contentsOf: url)
        self.visionModel = try VNCoreMLModel(for: model)
        // Configure NMS thresholds here...
    }
}
Phase 3: The "High-Res Referee" (Cloud Layer)
Goal: Layer a "Deep Scan" feature using Gemini 1.5 Flash to provide detailed analysis when requested (e.g., "Find a wooden chair").

3.1 VLMReferee Service
Create DetectionKit/Sources/DetectionKit/VLMReferee.swift.

Swift

// DetectionKit/Sources/DetectionKit/VLMReferee.swift
import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct RefereeResponse: Codable {
    public let description: String
    public let tags: [String]
}

public actor VLMReferee {
    private let apiKey = "YOUR_GEMINI_API_KEY" // Recommendation: Store in Keychain or xcconfig
    
    public func adjudicate(image: CVPixelBuffer, objectName: String) async throws -> RefereeResponse {
        // 1. Convert CVPixelBuffer to base64 JPEG
        guard let base64Image = convertToBase64(image) else { 
            throw DetectionError.invalidInput 
        }
        
        // 2. Construct the Payload
        let promptText = "Analyze this image crop. The user detects a '\(objectName)'. 1. Confirm or correct the object name. 2. Describe it in the target language using 3 adjectives (material, color, style). 3. Return strictly JSON: { \"description\": \"...\", \"tags\": [...] }"
        
        let jsonBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": promptText],
                        ["inline_data": ["mime_type": "image/jpeg", "data": base64Image]]
                    ]
                ]
            ]
        ]
        
        // 3. Network Request (Gemini 1.5 Flash endpoint)
        let url = URL(string: "[https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=](https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=)\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        // Parse JSON response...
        return try parseGeminiResponse(data)
    }
}
Phase 4: The Spatial AR Refactor
Goal: Migrate from AVCaptureSession to ARKit to solve object jitter and enable 3D persistence.

4.1 AR Session Coordinator
Replace CameraPreviewView.swift with this AR-backed implementation.

Swift

// LangscapeApp/Sources/LangscapeApp/CameraPreviewView.swift
import SwiftUI
import ARKit
import RealityKit

struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var viewModel: DetectionVM
    let contextManager: ContextManager // Inject this to manage state
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        // 1. Configure World Tracking (Horizontal + Vertical planes)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        arView.session.run(config)
        
        // 2. Set Delegate for Vision Processing
        context.coordinator.arView = arView
        arView.session.delegate = context.coordinator
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {}
    
    func makeCoordinator() -> ARSessionCoordinator {
        ARSessionCoordinator(viewModel: viewModel, contextManager: contextManager)
    }
}

// The Bridge between ARKit and DetectionKit
class ARSessionCoordinator: NSObject, ARSessionDelegate {
    var viewModel: DetectionVM
    var contextManager: ContextManager
    weak var arView: ARView?
    
    // Throttle vision to 4 FPS to save battery
    private var lastFrameTime: TimeInterval = 0
    
    init(viewModel: DetectionVM, contextManager: ContextManager) {
        self.viewModel = viewModel
        self.contextManager = contextManager
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = Date().timeIntervalSince1970
        guard now - lastFrameTime > 0.25 else { return } // 4 FPS
        lastFrameTime = now
        
        // 1. Run Scene Classification (Once at startup)
        if contextManager.currentContext == .unknown {
            Task { await contextManager.classify(frame.capturedImage) }
        }
        
        // 2. Run Object Detection (Continuous)
        // ARKit captures in landscape (.right / 1), handle orientation accordingly
        let request = DetectionRequest(pixelBuffer: frame.capturedImage, imageOrientationRaw: 1) 
        viewModel.enqueue(request)
    }
}
Implementation Checklist
Generate Models:

[ ] Install Ultralytics: pip install ultralytics

[ ] Save the script from Section 2.2 as Scripts/export_all_contexts.py.

[ ] Run the script to generate 20 .mlpackage files.

[ ] Move these files into Xcode under DetectionKit/Resources.

Update DetectionKit:

[ ] Implement classifyScene in VLMDetector.swift.

[ ] Implement loadContext in YOLOInterpreter.swift.

[ ] Create VLMReferee.swift.

Update App UI:

[ ] Refactor CameraPreviewView to use ARView instead of AVCaptureSession.

[ ] Add a UI indicator for the current context (e.g., "Context: Kitchen") with a "Change" button.