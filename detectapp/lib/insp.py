#!/usr/bin/env python3
"""
Inspect TFLite model to find correct input/output shapes
"""

import tensorflow as tf
import numpy as np

def inspect_model(model_path):
    print("="*60)
    print(f"INSPECTING MODEL: {model_path}")
    print("="*60)
    
    try:
        interpreter = tf.lite.Interpreter(model_path=model_path)
        interpreter.allocate_tensors()
        
        # Get input details
        input_details = interpreter.get_input_details()
        print("\n📥 INPUT DETAILS:")
        for i, detail in enumerate(input_details):
            print(f"  Input {i}:")
            print(f"    Name: {detail['name']}")
            print(f"    Shape: {detail['shape']}")
            print(f"    Type: {detail['dtype']}")
            print(f"    Index: {detail['index']}")
        
        # Get output details
        output_details = interpreter.get_output_details()
        print("\n📤 OUTPUT DETAILS:")
        for i, detail in enumerate(output_details):
            print(f"  Output {i}:")
            print(f"    Name: {detail['name']}")
            print(f"    Shape: {detail['shape']}")
            print(f"    Type: {detail['dtype']}")
            print(f"    Index: {detail['index']}")
        
        # Test with dummy input
        print("\n🧪 TESTING WITH DUMMY INPUT:")
        input_shape = input_details[0]['shape']
        print(f"  Creating dummy input with shape: {input_shape}")
        
        # Create dummy input
        if input_details[0]['dtype'] == np.float32:
            dummy_input = np.random.randn(*input_shape).astype(np.float32)
            print(f"  Input range: [-1.0, 1.0]")
        else:
            dummy_input = np.random.randint(0, 255, input_shape).astype(np.uint8)
            print(f"  Input range: [0, 255]")
        
        # Run inference
        interpreter.set_tensor(input_details[0]['index'], dummy_input)
        interpreter.invoke()
        output = interpreter.get_tensor(output_details[0]['index'])
        
        print(f"  ✅ Inference successful!")
        print(f"  Output shape: {output.shape}")
        print(f"  Output range: [{output.min():.3f}, {output.max():.3f}]")
        print(f"  First 5 values: {output[0][:5] if len(output.shape) > 1 else output[:5]}")
        
        # Recommendations
        print("\n💡 RECOMMENDATIONS FOR FLUTTER:")
        print(f"  1. Resize face images to: {input_shape[2]}x{input_shape[1]} pixels")
        print(f"  2. Channels: {input_shape[3]}")
        print(f"  3. Embedding dimension: {output_details[0]['shape'][-1]}")
        
        if input_details[0]['dtype'] == np.float32:
            print(f"  4. Normalize pixels: (pixel / 127.5) - 1.0")
        else:
            print(f"  4. Keep pixels as uint8: [0-255]")
        
        return input_shape, output_details[0]['shape']
        
    except Exception as e:
        print(f"\n❌ ERROR: {e}")
        import traceback
        traceback.print_exc()
        return None, None


def generate_test_face(model_path, output_path="test_face.jpg"):
    """Generate a test face image with correct dimensions"""
    print("\n" + "="*60)
    print("GENERATING TEST FACE IMAGE")
    print("="*60)
    
    try:
        import cv2
        
        interpreter = tf.lite.Interpreter(model_path=model_path)
        interpreter.allocate_tensors()
        
        input_details = interpreter.get_input_details()
        height = input_details[0]['shape'][1]
        width = input_details[0]['shape'][2]
        
        # Create a simple test face
        img = np.random.randint(100, 200, (height, width, 3), dtype=np.uint8)
        
        # Draw a simple face
        center_y, center_x = height // 2, width // 2
        cv2.circle(img, (center_x, center_y), min(width, height) // 3, (255, 255, 255), -1)
        cv2.circle(img, (center_x - width//6, center_y - height//8), width//12, (0, 0, 0), -1)
        cv2.circle(img, (center_x + width//6, center_y - height//8), width//12, (0, 0, 0), -1)
        cv2.ellipse(img, (center_x, center_y + height//6), (width//6, height//12), 0, 0, 180, (0, 0, 0), 2)
        
        cv2.imwrite(output_path, img)
        print(f"✅ Test face saved to: {output_path}")
        print(f"   Dimensions: {width}x{height}x3")
        
        return output_path
        
    except ImportError:
        print("⚠️  opencv-python not installed, skipping test image generation")
        return None


if __name__ == "__main__":
    model_path = "assets/models/faceModel.tflite"
    
    input_shape, output_shape = inspect_model(model_path)
    
    if input_shape is not None:
        try:
            generate_test_face(model_path)
        except Exception as e:
            print(f"Could not generate test face: {e}")
    
    print("\n" + "="*60)