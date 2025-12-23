#!/usr/bin/env python3
"""
FaceNet Enrollment Script with Firebase Storage - FIXED
"""

import tensorflow as tf
import numpy as np
import cv2
import os
import json
from datetime import datetime
import firebase_admin
from firebase_admin import credentials, firestore, storage

print("="*70)
print("FACENET ENROLLMENT TO FIREBASE")
print("="*70)

# ============================================================================
# CONFIGURATION
# ============================================================================

TFLITE_MODEL = 'facenet.tflite'  # NO SPACE
FIREBASE_CONFIG = 'firebase-credentials.json'
ENROLLED_IMAGES_DIR = 'enrolled_faces'

# People to enroll
PEOPLE_TO_ENROLL = {
    'Subaina': 'subaina.jpg',
    'Person1': 'test.jpg',
    'Person2':  'test2.jpg',
}

# Create directory
if not os.path.exists(ENROLLED_IMAGES_DIR):
    os.makedirs(ENROLLED_IMAGES_DIR)

# ============================================================================
# INITIALIZE FIREBASE
# ============================================================================

print(f"\n🔥 Initializing Firebase...")

if not os.path.exists(FIREBASE_CONFIG):
    print(f"❌ Firebase config not found:  {FIREBASE_CONFIG}")
    exit(1)

try:
    cred = credentials. Certificate(FIREBASE_CONFIG)
    
    with open(FIREBASE_CONFIG, 'r') as f:
        config_data = json.load(f)
        project_id = config_data. get('project_id', '')
    
    firebase_admin.initialize_app(cred, {
        'storageBucket': f'{project_id}.appspot.com'
    })
    
    db = firestore.client()
    bucket = storage.bucket()
    
    print(f"✅ Firebase initialized!")
    print(f"   Project:  {project_id}")
    
except Exception as e:
    print(f"❌ Firebase initialization failed: {e}")
    exit(1)

# ============================================================================
# LOAD MODEL
# ============================================================================

print(f"\n📦 Loading FaceNet model...")

if not os.path.exists(TFLITE_MODEL):
    print(f"❌ Model not found: {TFLITE_MODEL}")
    exit(1)

interpreter = tf.lite.Interpreter(model_path=TFLITE_MODEL)
interpreter.allocate_tensors()

input_details = interpreter.get_input_details()
output_details = interpreter.get_output_details()

input_shape = input_details[0]['shape']
batch_size, height, width, channels = input_shape
embedding_size = output_details[0]['shape'][-1]

print(f"✅ Model loaded!")
print(f"   Input:  {height}x{width}x{channels}")
print(f"   Output: {embedding_size}-dim embeddings")

# Load face detector
face_cascade = cv2.CascadeClassifier(cv2.data.haarcascades + 'haarcascade_frontalface_default.xml')
print(f"✅ Face detector loaded!")

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

def detect_face(image):
    """Detect the largest face in image"""
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    faces = face_cascade. detectMultiScale(gray, scaleFactor=1.1, minNeighbors=5, minSize=(50, 50))
    
    if len(faces) == 0:
        return None
    
    faces = sorted(faces, key=lambda x: x[2] * x[3], reverse=True)
    return faces[0]


def extract_and_preprocess_face(image, face_box, padding=0.3):
    """Extract and preprocess face from image"""
    x, y, w, h = face_box
    
    pad = int(w * padding)
    x1 = max(0, x - pad)
    y1 = max(0, y - pad)
    x2 = min(image.shape[1], x + w + pad)
    y2 = min(image.shape[0], y + h + pad)
    
    face = image[y1:y2, x1:x2]
    face_resized = cv2.resize(face, (width, height))
    face_rgb = cv2.cvtColor(face_resized, cv2.COLOR_BGR2RGB)
    face_normalized = face_rgb. astype(np.float32) / 255.0
    face_input = np.expand_dims(face_normalized, axis=0)
    
    return face_input, face_resized


def get_embedding(face_input):
    """Get FaceNet embedding for face"""
    interpreter.set_tensor(input_details[0]['index'], face_input)
    interpreter.invoke()
    embedding = interpreter.get_tensor(output_details[0]['index'])
    
    embedding_flat = embedding.flatten()
    norm = np.linalg.norm(embedding_flat)
    
    if norm > 0:
        embedding_normalized = embedding_flat / norm
    else:
        embedding_normalized = embedding_flat
    
    return embedding_normalized. tolist()


def upload_image_to_firebase(local_path, firebase_path):
    """Upload image to Firebase Storage"""
    try:
        blob = bucket.blob(firebase_path)
        blob.upload_from_filename(local_path)
        blob.make_public()
        return blob.public_url
    except Exception as e:
        print(f"   ⚠️ Upload failed: {e}")
        return None


# ============================================================================
# ENROLLMENT
# ============================================================================

print(f"\n{'='*70}")
print(f"ENROLLING {len(PEOPLE_TO_ENROLL)} PEOPLE")
print(f"{'='*70}")

enrolled_count = 0
failed_count = 0

for person_name, image_file in PEOPLE_TO_ENROLL.items():
    print(f"\n{'─'*70}")
    print(f"📋 Enrolling: {person_name}")
    print(f"   Image: {image_file}")
    print(f"{'─'*70}")
    
    if not os.path.exists(image_file):
        print(f"❌ Image not found:  {image_file}")
        failed_count += 1
        continue
    
    print(f"\n📷 Loading image...")
    image = cv2.imread(image_file)
    
    if image is None:
        print(f"❌ Failed to load:  {image_file}")
        failed_count += 1
        continue
    
    print(f"✅ Loaded: {image. shape}")
    
    print(f"\n🔍 Detecting face...")
    face_box = detect_face(image)
    
    if face_box is None:
        print(f"❌ No face detected!")
        failed_count += 1
        continue
    
    x, y, w, h = face_box
    print(f"✅ Face found: ({x},{y}) size: {w}x{h}")
    
    print(f"\n🔄 Preprocessing...")
    face_input, face_display = extract_and_preprocess_face(image, face_box)
    print(f"✅ Preprocessed to {width}x{height}")
    
    print(f"\n⚡ Generating embedding...")
    embedding = get_embedding(face_input)
    
    embedding_array = np.array(embedding)
    non_zero = np.count_nonzero(np.abs(embedding_array) > 0.001)
    norm = np.linalg.norm(embedding_array)
    
    print(f"✅ Embedding generated!")
    print(f"   Dimensions: {len(embedding)}")
    print(f"   Non-zero: {non_zero}/{len(embedding)} ({100*non_zero/len(embedding):.1f}%)")
    print(f"   L2 norm: {norm:.6f}")
    
    if non_zero < 10:
        print(f"❌ Embedding quality too low!")
        failed_count += 1
        continue
    
    # FIXED: No spaces in filename
    safe_name = person_name.replace(' ', '_').replace('/', '_').replace('\\', '_')
    face_filename = f"enrolled_{safe_name}.jpg"  # NO SPACE BEFORE . jpg
    face_path = os.path.join(ENROLLED_IMAGES_DIR, face_filename)
    
    print(f"\n💾 Saving locally...")
    print(f"   File: {face_filename}")
    
    try:
        success = cv2.imwrite(face_path, face_display)
        
        if not success:
            raise Exception("cv2.imwrite failed")
        
        if not os.path.exists(face_path):
            raise Exception("File not created")
        
        file_size = os.path.getsize(face_path)
        print(f"✅ Saved: {face_filename} ({file_size} bytes)")
        
    except Exception as e:
        print(f"❌ Save failed: {e}")
        failed_count += 1
        continue
    
    print(f"\n☁️ Uploading to Firebase Storage...")
    firebase_image_path = f"enrolled_faces/{face_filename}"
    image_url = upload_image_to_firebase(face_path, firebase_image_path)
    
    if image_url:
        print(f"✅ Uploaded:  {image_url}")
    else:
        print(f"⚠️ Upload failed, continuing...")
        image_url = ""
    
    print(f"\n🔥 Saving to Firestore...")
    
    try:
        doc_ref = db.collection('enrolled_faces').document(safe_name)
        
        doc_data = {
            'name': person_name,
            'embedding': embedding,
            'image_url': image_url,
            'image_filename': face_filename,
            'original_image':  image_file,
            'embedding_size': len(embedding),
            'timestamp': firestore.SERVER_TIMESTAMP,
            'enrolled_at': datetime.now().isoformat()
        }
        
        doc_ref.set(doc_data)
        
        print(f"✅ Saved to Firestore!")
        print(f"   Collection: enrolled_faces")
        print(f"   Document:  {safe_name}")
        
        enrolled_count += 1
        print(f"\n✅ ✅ ✅ Successfully enrolled:  {person_name}")
        
    except Exception as e:
        print(f"❌ Firestore save failed: {e}")
        failed_count += 1

# ============================================================================
# FINAL SUMMARY
# ============================================================================

print(f"\n{'='*70}")
print(f"✅ ✅ ✅ ENROLLMENT COMPLETE! ✅ ✅ ✅")
print(f"{'='*70}")

print(f"\n📊 Summary:")
print(f"   ✅ Successfully enrolled: {enrolled_count}")
print(f"   ❌ Failed:  {failed_count}")
print(f"   📝 Total attempted: {len(PEOPLE_TO_ENROLL)}")

if enrolled_count > 0:
    print(f"\n🔥 Firebase Firestore:")
    print(f"   Collection: enrolled_faces")
    
    print(f"\n👥 Enrolled People:")
    try:
        docs = db.collection('enrolled_faces').stream()
        for doc in docs: 
            data = doc.to_dict()
            print(f"   ✅ {data. get('name', doc.id)}")
            print(f"      Image: {data.get('image_url', 'N/A')[:50]}...")
    except Exception as e:
        print(f"   ⚠️ Could not list:  {e}")
    
    print(f"\n📝 Next:  Update Flutter to read from 'enrolled_faces' collection")

print(f"\n✅ Done!")
print(f"{'='*70}")