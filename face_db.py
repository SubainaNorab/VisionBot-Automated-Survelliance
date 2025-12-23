
import firebase_admin
from firebase_admin import credentials, firestore
import tensorflow as tf
import numpy as np
import cv2
import os

class FaceRecognitionTest: 
    def __init__(self, firebase_credentials='firebase-credentials.json',
                 model_path='vgg_face_embedding_no_opt.tflite'):
        # Initialize Firebase
        cred = credentials.Certificate(firebase_credentials)
        
        # Delete existing app if any
        try:
            firebase_admin.delete_app(firebase_admin.get_app())
        except:
            pass
            
        firebase_admin.initialize_app(cred)
        self.db = firestore.client()
        
        # Load model
        self.interpreter = tf.lite.Interpreter(model_path=model_path)
        self.interpreter.allocate_tensors()
        self.input_details = self.interpreter.get_input_details()
        self.output_details = self.interpreter.get_output_details()
        
        print("✓ Firebase initialized")
        print("✓ TFLite model loaded")
        print(f"   Input shape: {self.input_details[0]['shape']}")
        print(f"   Output shape: {self.output_details[0]['shape']}")
        print()
    
    def _get_embedding(self, image_path, save_crop=True):
        """Extract embedding from image"""
        print(f"\n  📷 Processing: {image_path}")
        
        if not os.path.exists(image_path):
            print(f"  ❌ File not found!")
            return None
        
        # Load image
        img = cv2.imread(image_path)
        if img is None:
            print(f"  ❌ Cannot load image")
            return None
        
        print(f"  ✓ Loaded:  {img.shape} (H x W x C)")
        
        # Detect face
        face_cascade = cv2.CascadeClassifier(cv2.data.haarcascades + 'haarcascade_frontalface_default.xml')
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        faces = face_cascade.detectMultiScale(gray, 1.3, 5)
        
        if len(faces) == 0:
            print(f"  ⚠️  No face detected, using full image")
            face = img
        else:
            x, y, w, h = max(faces, key=lambda f: f[2] * f[3])
            print(f"  ✓ Face detected:  ({x},{y}) {w}x{h}")
            
            # Crop with padding
            padding = int(w * 0.3)
            x1 = max(0, x - padding)
            y1 = max(0, y - padding)
            x2 = min(img.shape[1], x + w + padding)
            y2 = min(img.shape[0], y + h + padding)
            
            face = img[y1:y2, x1:x2]
            
            if save_crop:
                crop_path = f"crop_{os.path.basename(image_path)}"
                cv2.imwrite(crop_path, face)
                print(f"  ✓ Saved crop: {crop_path}")
        
        # Preprocess
        face_resized = cv2.resize(face, (224, 224))
        face_normalized = face_resized. astype(np.float32) / 255.0
        face_input = np.expand_dims(face_normalized, axis=0)
        
        # Get embedding
        self.interpreter.set_tensor(self.input_details[0]['index'], face_input)
        self.interpreter.invoke()
        embedding = self.interpreter.get_tensor(self.output_details[0]['index']).flatten()
        
        # L2 normalize
        norm = np.linalg.norm(embedding)
        if norm > 0:
            embedding = embedding / norm
        
        # Validate
        non_zero = np.count_nonzero(np.abs(embedding) > 0.0001)
        print(f"  📊 Embedding:  {len(embedding)} dims, {non_zero} non-zero ({100*non_zero/len(embedding):.1f}%)")
        print(f"     Range: [{embedding.min():.6f}, {embedding.max():.6f}]")
        print(f"     First 10: {embedding[:10]}")
        
        if non_zero < 100:
            print(f"  ⚠️  WARNING: Too many zeros!  Embedding likely invalid!")
        
        return embedding. tolist()
    
    def cosine_similarity(self, a, b):
        """Calculate cosine similarity"""
        return np.dot(a, b)  # Since both are L2 normalized
    
    def enroll(self, name, image_path):
        """Enroll a person"""
        print(f"\n{'='*70}")
        print(f"ENROLLING: {name}")
        print(f"{'='*70}")
        
        embedding = self._get_embedding(image_path)
        
        if embedding is None:
            print(f"❌ Enrollment failed")
            return None
        
        # Save to Firestore
        doc_ref = self.db.collection('people').document()
        doc_ref.set({
            'name': name,
            'embedding': embedding,
            'image':  image_path,
        })
        
        print(f"\n✅ Enrolled: {name} (ID: {doc_ref. id})")
        return doc_ref.id
    
    def recognize(self, image_path, threshold=0.5):
        """Recognize a face from image"""
        print(f"\n{'='*70}")
        print(f"RECOGNIZING:  {image_path}")
        print(f"{'='*70}")
        
        # Get embedding from input image
        input_embedding = self._get_embedding(image_path, save_crop=True)
        
        if input_embedding is None: 
            print(f"❌ Failed to extract embedding")
            return None
        
        # Load all enrolled people
        docs = self.db.collection('people').stream()
        people = []
        for doc in docs:
            data = doc.to_dict()
            people.append(data)
        
        if len(people) == 0:
            print(f"⚠️  No enrolled people in database")
            return None
        
        print(f"\n🔍 Comparing against {len(people)} enrolled people...")
        print(f"   Threshold: {threshold}")
        
        # Find best match
        best_similarity = -1
        best_match = None
        
        print(f"\n📊 SIMILARITY SCORES:")
        for person in people:
            similarity = self.cosine_similarity(input_embedding, person['embedding'])
            match = "✅ MATCH" if similarity >= threshold else "❌ NO MATCH"
            
            print(f"\n   {person['name']}:")
            print(f"      Similarity: {similarity:.6f}")
            print(f"      Status: {match}")
            print(f"      Stored (first 10): {person['embedding'][:10]}")
            print(f"      Input (first 10):  {input_embedding[:10]}")
            
            if similarity > best_similarity:
                best_similarity = similarity
                best_match = person
        
        print(f"\n{'='*70}")
        if best_match and best_similarity >= threshold:
            print(f"✅ RECOGNIZED: {best_match['name']}")
            print(f"   Similarity: {best_similarity:.6f} ({best_similarity*100:.1f}%)")
            print(f"   Confidence: HIGH" if best_similarity > 0.7 else "   Confidence: MEDIUM")
            return best_match
        else:
            print(f"❌ NO MATCH FOUND")
            print(f"   Best candidate: {best_match['name'] if best_match else 'None'}")
            print(f"   Best similarity: {best_similarity:.6f}")
            print(f"   Threshold: {threshold:. 6f}")
            print(f"   Difference: {threshold - best_similarity:.6f}")
            return None
    
    def clear_all(self):
        """Clear all enrolled people"""
        docs = self.db.collection('people').stream()
        count = 0
        for doc in docs: 
            doc.reference.delete()
            count += 1
        print(f"✓ Cleared {count} people from database")
    
    def test_self_recognition(self, name, image_path):
        """Test if person recognizes themselves"""
        print(f"\n\n{'#'*70}")
        print(f"TEST:  Self-Recognition for {name}")
        print(f"{'#'*70}")
        
        # Enroll
        self.enroll(name, image_path)
        
        # Try to recognize the same image
        print(f"\n🧪 Testing recognition with SAME image...")
        result = self.recognize(image_path, threshold=0.5)
        
        if result and result['name'] == name: 
            print(f"\n✅ PASS: {name} recognized themselves!")
            return True
        else: 
            print(f"\n❌ FAIL: {name} did NOT recognize themselves!")
            return False


if __name__ == "__main__": 
    print("\n" + "="*70)
    print("FACE RECOGNITION TEST SUITE")
    print("="*70)
    
    tester = FaceRecognitionTest()
    
    # Clear database
    print("\n🗑️  Clearing database...")
    tester.clear_all()
    
    # Test 1: Self-recognition for Subaina
    test1 = tester.test_self_recognition('Subaina', 'subaina.jpg')
    
    # Test 2: Self-recognition for Test Person
    test2 = tester.test_self_recognition('Test subaina', 'test2.jpg')
    
    # Test 3: Cross-recognition (Subaina's image against both)
    print(f"\n\n{'#'*70}")
    print(f"TEST:  Cross-Recognition")
    print(f"{'#'*70}")
    print("\n🧪 Testing Subaina's image against database with both people...")
    result = tester.recognize('subaina.jpg', threshold=0.5)
    test3 = (result and result['name'] == 'Subaina')
    
    # Summary
    print(f"\n\n{'='*70}")
    print("TEST SUMMARY")
    print(f"{'='*70}")
    print(f"Test 1 - Subaina self-recognition:   {'✅ PASS' if test1 else '❌ FAIL'}")
    print(f"Test 2 - Test Person self-recognition: {'✅ PASS' if test2 else '❌ FAIL'}")
    print(f"Test 3 - Subaina cross-recognition:  {'✅ PASS' if test3 else '❌ FAIL'}")
    print(f"\nOverall: {'✅ ALL TESTS PASSED' if all([test1, test2, test3]) else '❌ SOME TESTS FAILED'}")
    print(f"{'='*70}")
    
    print("\n📝 Next steps:")
    print("1. Check the 'crop_*. jpg' files to verify face detection")
    print("2. If tests pass in Python, the model works!")
    print("3. If tests fail, check embedding statistics for zeros")
    print("4. If Python works but Flutter doesn't, it's a Flutter implementation issue")

# import tensorflow as tf
# import numpy as np
# import cv2
# from deepface. modules import detection, verification

# class VGGFaceTFLite:
#     """TFLite-based face verification using VGG-Face model"""
    
#     def __init__(self, model_path='vgg_face_embedding_no_opt. tflite'):
#         self.model_path = model_path
#         self.interpreter = tf.lite.Interpreter(model_path=model_path)
#         self.interpreter.allocate_tensors()
        
#         self.input_details = self.interpreter.get_input_details()
#         self.output_details = self.interpreter.get_output_details()
        
#         print(f"✓ VGG-Face TFLite model loaded:  {model_path}")
    
#     def preprocess(self, image_path, use_face_detection=True, target_size=(224, 224)):
#         """
#         Preprocess image for VGG-Face model
        
#         Args:
#             image_path: Path to image file
#             use_face_detection: If True, detect and crop face.  If False, use whole image
#             target_size: Model input size (default 224x224)
        
#         Returns:
#             Preprocessed image ready for model input
#         """
#         if use_face_detection:
#             # Extract and crop face
#             face_objs = detection.extract_faces(
#                 img_path=image_path,
#                 detector_backend="opencv",
#                 align=True,
#                 enforce_detection=False,
#                 normalize_face=False,
#                 color_face="bgr"
#             )
            
#             if len(face_objs) > 0:
#                 face = face_objs[0]["face"]
#                 if face.shape[: 2] != target_size: 
#                     img = cv2.resize(face, target_size)
#                 else: 
#                     img = face
#             else:
#                 # Fallback:  use whole image
#                 img = cv2.imread(image_path)
#                 img = cv2.resize(img, target_size)
#         else:
#             # Use whole image
#             img = cv2.imread(image_path)
#             img = cv2.resize(img, target_size)
        
#         # Normalize to [0, 1]
#         img = img.astype(np.float32) / 255.0
        
#         # Add batch dimension
#         img = np. expand_dims(img, axis=0)
        
#         return img
    
#     def get_embedding(self, image_path, use_face_detection=True):
#         """
#         Get face embedding from image
        
#         Args:
#             image_path: Path to image file
#             use_face_detection: If True, detect and crop face
        
#         Returns: 
#             L2-normalized embedding vector (numpy array)
#         """
#         # Preprocess
#         img = self.preprocess(image_path, use_face_detection)
        
#         # Run inference
#         self.interpreter.set_tensor(self.input_details[0]['index'], img)
#         self.interpreter.invoke()
        
#         # Get embedding
#         embedding = self.interpreter. get_tensor(self.output_details[0]['index']).flatten()
        
#         # L2 normalization
#         embedding = verification.l2_normalize(embedding)
        
#         return embedding
    
#     def verify(self, img1_path, img2_path, threshold=0.68, use_face_detection=True):
#         """
#         Verify if two face images are of the same person
        
#         Args:
#             img1_path:  Path to first image
#             img2_path: Path to second image
#             threshold: Cosine distance threshold (default 0.68 for VGG-Face)
#             use_face_detection: If True, detect and crop faces
        
#         Returns:
#             Dictionary with verification results
#         """
#         # Get embeddings
#         emb1 = self.get_embedding(img1_path, use_face_detection)
#         emb2 = self.get_embedding(img2_path, use_face_detection)
        
#         # Calculate cosine distance
#         distance = 1 - np.dot(emb1, emb2)
        
#         # Verify
#         is_verified = distance < threshold
        
#         return {
#             'verified': bool(is_verified),
#             'distance': float(distance),
#             'threshold': threshold,
#             'model':  'VGG-Face',
#             'distance_metric': 'cosine',
#             'face_detection_used': use_face_detection
#         }


# # Example usage
# if __name__ == "__main__":
#     # Initialize model
#     model = VGGFaceTFLite('vgg_face_embedding_no_opt.tflite')
    
#     # Verify two faces
#     result = model.verify(
#         img1_path="test.jpg",
#         img2_path="test.jpg",
#         use_face_detection=True
#     )
    
#     print("\n" + "="*70)
#     print("FACE VERIFICATION RESULT")
#     print("="*70)
#     print(f"Verified: {result['verified']}")
#     print(f"Distance: {result['distance']:.6f}")
#     print(f"Threshold: {result['threshold']}")
#     print(f"Match: {'✓ Same person!' if result['verified'] else '✗ Different people'}")
#     print("="*70)

# #     # 
# #     from deepface import DeepFace
# # import tensorflow as tf
# # import os

# # print("Loading VGG-Face model...")
# # try:
# #     model_wrapper = DeepFace.build_model("VGG-Face")
# #     if hasattr(model_wrapper, 'model'):
# #         full_model = model_wrapper.model
# #     else:
# #         full_model = model_wrapper
# # except Exception as e:
# #     print(f"Method 1 failed: {e}")
# #     # Fallback
# #     _ = DeepFace.represent(img_path="test.jpg", model_name="VGG-Face", enforce_detection=False)
# #     home = os.path.expanduser("~")
# #     model_path = os.path.join(home, ". deepface", "weights", "vgg_face_weights.h5")
# #     full_model = tf.keras.models.load_model(model_path)

# # print(f"✓ Model loaded:  {len(full_model.layers)} layers")

# # # Get embedding layer (second-to-last)
# # embedding_layer = full_model.layers[-2]
# # print(f"✓ Embedding layer: {embedding_layer. name} - {embedding_layer.output_shape}")

# # # Create embedding model
# # embedding_model = tf.keras.Model(
# #     inputs=full_model.input,
# #     outputs=embedding_layer.output
# # )

# # print("\n" + "="*70)
# # print("Converting to TFLite WITHOUT optimizations...")
# # print("="*70)

# # # Convert WITHOUT optimizations
# # converter = tf.lite.TFLiteConverter.from_keras_model(embedding_model)
# # # NO optimizations applied

# # tflite_model = converter.convert()

# # # Save
# # output_file = 'vgg_face_embedding_no_opt.tflite'
# # with open(output_file, 'wb') as f:
# #     f.write(tflite_model)

# # print(f"\n✓ Conversion successful!")
# # print(f"  File:  {output_file}")
# # print(f"  Size: {len(tflite_model) / (1024*1024):.2f} MB")