import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';

class AudioRecorder {
  FlutterSoundRecorder? _recorder;
  String? filePath;
  DateTime? _recordingStartTime;
  
  AudioRecorder() {
    _recorder = FlutterSoundRecorder();
  }

  /// Initialize the audio recorder and request necessary permissions
  Future<Map<String, dynamic>> init() async {
    try {
      await _recorder!.openRecorder();
      
      // Request microphone permission
      PermissionStatus status = await Permission.microphone.request();
      
      if (status.isGranted) {
        return {
          'success': true,
          'message': 'Audio recorder initialized successfully'
        };
      } else if (status.isDenied) {
        return {
          'success': false,
          'message': 'Microphone permission denied'
        };
      } else if (status.isPermanentlyDenied) {
        return {
          'success': false,
          'message': 'Microphone permission permanently denied. Please enable it in settings.',
          'openSettings': true
        };
      }
      
      return {
        'success': false,
        'message': 'Permission status unknown'
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Initialization failed: ${e.toString()}'
      };
    }
  }

  /// Start recording audio
  Future<Map<String, dynamic>> startRecording() async {
    try {
      // Check if recorder is initialized
      if (_recorder == null || !_recorder!.isRecorderInitialised) {
        return {
          'success': false,
          'message': 'Recorder not initialized. Please call init() first.'
        };
      }

      // Check if already recording
      if (_recorder!.isRecording) {
        return {
          'success': false,
          'message': 'Recording is already in progress'
        };
      }

      // Check microphone permission
      PermissionStatus permission = await Permission.microphone.status;
      if (!permission.isGranted) {
        return {
          'success': false,
          'message': 'Microphone permission not granted'
        };
      }

      // Get application documents directory
      Directory appDocDir = await getApplicationDocumentsDirectory();
      
      // Check if directory exists and is writable
      if (!await appDocDir.exists()) {
        return {
          'success': false,
          'message': 'Storage directory not available'
        };
      }

      // Generate unique filename using timestamp
      String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      filePath = '${appDocDir.path}/recording_$timestamp.aac';

      // Start recording with AAC codec
      await _recorder!.startRecorder(
        toFile: filePath,
        codec: Codec.aacADTS,
      );

      _recordingStartTime = DateTime.now();

      return {
        'success': true,
        'message': 'Recording started',
        'filePath': filePath
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Failed to start recording: ${e.toString()}'
      };
    }
  }

  /// Stop recording audio
  Future<Map<String, dynamic>> stopRecording() async {
    try {
      // Check if recorder is initialized
      if (_recorder == null || !_recorder!.isRecorderInitialised) {
        return {
          'success': false,
          'message': 'Recorder not initialized'
        };
      }

      // Check if actually recording
      if (!_recorder!.isRecording) {
        return {
          'success': false,
          'message': 'No recording in progress'
        };
      }

      // Stop the recorder
      await _recorder!.stopRecorder();

      // Calculate recording duration
      Duration? recordingDuration;
      if (_recordingStartTime != null) {
        recordingDuration = DateTime.now().difference(_recordingStartTime!);
      }

      // Verify file was created
      if (filePath != null && await File(filePath!).exists()) {
        File file = File(filePath!);
        int fileSize = await file.length();
        
        return {
          'success': true,
          'message': 'Recording stopped successfully',
          'filePath': filePath,
          'fileSize': fileSize,
          'duration': recordingDuration?.inSeconds ?? 0
        };
      } else {
        return {
          'success': false,
          'message': 'Recording file was not saved properly'
        };
      }
    } catch (e) {
      return {
        'success': false,
        'message': 'Failed to stop recording: ${e.toString()}'
      };
    }
  }

  /// Get current recording duration (if recording)
  Duration? getRecordingDuration() {
    if (_recordingStartTime != null && _recorder?.isRecording == true) {
      return DateTime.now().difference(_recordingStartTime!);
    }
    return null;
  }

  /// Check if currently recording
  bool get isRecording => _recorder?.isRecording ?? false;

  /// Check if recorder is initialized
  bool get isInitialized => _recorder?.isRecorderInitialised ?? false;

  /// Dispose the recorder and free resources
  Future<void> dispose() async {
    try {
      if (_recorder != null) {
        if (_recorder!.isRecording) {
          await _recorder!.stopRecorder();
        }
        await _recorder!.closeRecorder();
        _recorder = null;
      }
      _recordingStartTime = null;
      filePath = null;
    } catch (e) {
      print('Error disposing recorder: ${e.toString()}');
    }
  }

  /// Delete the last recorded file
  Future<Map<String, dynamic>> deleteRecording() async {
    try {
      if (filePath != null && await File(filePath!).exists()) {
        await File(filePath!).delete();
        String deletedPath = filePath!;
        filePath = null;
        
        return {
          'success': true,
          'message': 'Recording deleted',
          'deletedPath': deletedPath
        };
      } else {
        return {
          'success': false,
          'message': 'No recording file found to delete'
        };
      }
    } catch (e) {
      return {
        'success': false,
        'message': 'Failed to delete recording: ${e.toString()}'
      };
    }
  }
}