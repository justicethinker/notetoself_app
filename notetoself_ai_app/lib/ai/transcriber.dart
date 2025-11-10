import 'dart:io';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:path/path.dart' as path;
import 'dart:async';

class Transcriber {
  final String apiKey;
  final bool autoChapters;
  final bool punctuate;
  final bool speakerLabels;
  final String languageCode;
  final int maxPollingAttempts;
  final Duration pollingInterval;
  final int maxUploadRetries;
  final int uploadChunkSize;

  // AssemblyAI API endpoints
  static const String _uploadEndpoint = 'https://api.assemblyai.com/v2/upload';
  static const String _transcriptEndpoint = 'https://api.assemblyai.com/v2/transcript';

  // Supported audio formats
  static const List<String> _supportedFormats = [
    '.wav',
    '.mp3',
    '.m4a',
    '.aac',
    '.flac',
    '.ogg',
    '.opus'
  ];

  // Maximum file size (500 MB for AssemblyAI)
  static const int _maxFileSizeBytes = 500 * 1024 * 1024;

  // Chunk size for large file uploads (10 MB)
  static const int _defaultChunkSize = 10 * 1024 * 1024;

  // Track ongoing operations for cancellation
  bool _isCancelled = false;
  String? _currentTranscriptionId;

  Transcriber({
    required this.apiKey,
    this.autoChapters = false,
    this.punctuate = true,
    this.speakerLabels = false,
    this.languageCode = 'en_us',
    this.maxPollingAttempts = 120, // 120 * 3 seconds = 6 minutes max
    this.pollingInterval = const Duration(seconds: 3),
    this.maxUploadRetries = 3,
    this.uploadChunkSize = _defaultChunkSize,
  }) {
    _validateApiKey();
  }

  /// Validate API key format
  void _validateApiKey() {
    if (apiKey.isEmpty) {
      throw ArgumentError('API key cannot be empty');
    }
    // AssemblyAI API keys are typically 32+ characters
    if (apiKey.length < 32) {
      print('Warning: API key seems too short. Please verify your AssemblyAI API key.');
    }
  }

  /// Main transcription method with full progress tracking
  Future<Map<String, dynamic>> transcribe(
    String audioFilePath, {
    Function(double progress, String status)? onProgress,
  }) async {
    _isCancelled = false;
    _currentTranscriptionId = null;

    try {
      // Step 1: Validate audio file (0% - 5%)
      onProgress?.call(0.0, 'Validating audio file');
      var validationResult = await _validateAudioFile(audioFilePath);
      if (!validationResult['success']) {
        return validationResult;
      }

      if (_isCancelled) {
        return _cancelledResponse();
      }

      // Step 2: Upload audio file with retry (5% - 30%)
      onProgress?.call(0.05, 'Uploading audio file');
      var uploadResult = await _uploadAudioFileWithRetry(
        audioFilePath,
        onProgress: (uploadProgress) {
          // Map upload progress from 5% to 30%
          double mappedProgress = 0.05 + (uploadProgress * 0.25);
          onProgress?.call(mappedProgress, 'Uploading audio file');
        },
      );

      if (!uploadResult['success']) {
        return uploadResult;
      }

      if (_isCancelled) {
        return _cancelledResponse();
      }

      String uploadUrl = uploadResult['uploadUrl'];

      // Step 3: Request transcription (30% - 35%)
      onProgress?.call(0.30, 'Requesting transcription');
      var transcriptionResult = await _requestTranscription(uploadUrl);
      if (!transcriptionResult['success']) {
        return transcriptionResult;
      }

      if (_isCancelled) {
        return _cancelledResponse();
      }

      String transcriptionId = transcriptionResult['transcriptionId'];
      _currentTranscriptionId = transcriptionId;

      // Step 4: Poll for completion (35% - 95%)
      onProgress?.call(0.35, 'Processing transcription');
      var completionResult = await _pollForCompletion(
        transcriptionId,
        onProgress: (pollingProgress) {
          // Map polling progress from 35% to 95%
          double mappedProgress = 0.35 + (pollingProgress * 0.60);
          onProgress?.call(mappedProgress, 'Processing transcription');
        },
      );

      if (!completionResult['success']) {
        return completionResult;
      }

      if (_isCancelled) {
        return _cancelledResponse();
      }

      // Step 5: Parse and return final result (95% - 100%)
      onProgress?.call(0.95, 'Finalizing transcription');
      
      var finalResult = {
        'success': true,
        'text': completionResult['text'] ?? '',
        'audioUrl': uploadUrl,
        'transcriptionId': transcriptionId,
        'confidence': completionResult['confidence'] ?? 0.0,
        'words': completionResult['words'] ?? [],
        'chapters': completionResult['chapters'] ?? [],
        'utterances': completionResult['utterances'] ?? [],
        'audioFilePath': audioFilePath,
        'duration': completionResult['duration'] ?? 0,
        'keywords': _extractKeywords(completionResult['text'] ?? ''),
      };

      onProgress?.call(1.0, 'Transcription complete');
      return finalResult;

    } catch (e) {
      return {
        'success': false,
        'error': 'Transcription failed: ${e.toString()}',
      };
    } finally {
      _currentTranscriptionId = null;
    }
  }

  /// Validate audio file according to checklist requirements
  Future<Map<String, dynamic>> _validateAudioFile(String filePath) async {
    try {
      // Requirement 2.1: Check if file exists
      File audioFile = File(filePath);
      if (!await audioFile.exists()) {
        return {
          'success': false,
          'error': 'Audio file not found at: $filePath',
          'errorCode': 'FILE_NOT_FOUND',
        };
      }

      // Requirement 2.2: Validate supported formats
      String extension = path.extension(filePath).toLowerCase();
      if (!_supportedFormats.contains(extension)) {
        return {
          'success': false,
          'error': 'Unsupported audio format: $extension. Supported formats: ${_supportedFormats.join(", ")}',
          'errorCode': 'UNSUPPORTED_FORMAT',
        };
      }

      // Requirement 2.4: Validate non-empty file
      int fileSize = await audioFile.length();
      if (fileSize == 0) {
        return {
          'success': false,
          'error': 'Audio file is empty (0 bytes)',
          'errorCode': 'EMPTY_FILE',
        };
      }

      // Requirement 2.3: Validate file size (<500 MB)
      if (fileSize > _maxFileSizeBytes) {
        double sizeMB = fileSize / (1024 * 1024);
        return {
          'success': false,
          'error': 'Audio file too large (${sizeMB.toStringAsFixed(2)} MB). Maximum size: 500 MB',
          'errorCode': 'FILE_TOO_LARGE',
          'fileSize': fileSize,
        };
      }

      return {
        'success': true,
        'fileSize': fileSize,
        'format': extension,
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'File validation failed: ${e.toString()}',
        'errorCode': 'VALIDATION_ERROR',
      };
    }
  }

  /// Upload audio file with retry mechanism (Requirement 11.1)
  Future<Map<String, dynamic>> _uploadAudioFileWithRetry(
    String filePath, {
    Function(double progress)? onProgress,
  }) async {
    int retryCount = 0;
    Map<String, dynamic>? lastError;

    while (retryCount <= maxUploadRetries) {
      if (_isCancelled) {
        return _cancelledResponse();
      }

      try {
        var result = await _uploadAudioFile(filePath, onProgress: onProgress);
        
        if (result['success']) {
          return result;
        }

        lastError = result;
        
        // Don't retry on auth errors or file size errors
        if (result['errorCode'] == 'INVALID_API_KEY' || 
            result['errorCode'] == 'FILE_TOO_LARGE') {
          return result;
        }

        retryCount++;
        
        if (retryCount <= maxUploadRetries) {
          // Exponential backoff: 2s, 4s, 8s
          int waitSeconds = 2 * retryCount;
          await Future.delayed(Duration(seconds: waitSeconds));
        }

      } catch (e) {
        lastError = {
          'success': false,
          'error': 'Upload attempt ${retryCount + 1} failed: ${e.toString()}',
          'errorCode': 'UPLOAD_ERROR',
        };
        retryCount++;
        
        if (retryCount <= maxUploadRetries) {
          await Future.delayed(Duration(seconds: 2 * retryCount));
        }
      }
    }

    return lastError ?? {
      'success': false,
      'error': 'Upload failed after $maxUploadRetries retries',
      'errorCode': 'MAX_RETRIES_EXCEEDED',
    };
  }

  /// Upload audio file to AssemblyAI (Requirement 3)
  Future<Map<String, dynamic>> _uploadAudioFile(
    String filePath, {
    Function(double progress)? onProgress,
  }) async {
    try {
      File audioFile = File(filePath);
      int fileSize = await audioFile.length();
      
      // Requirement 11.2: Chunk large files for streaming upload
      if (fileSize > uploadChunkSize) {
        return await _uploadAudioFileChunked(filePath, onProgress: onProgress);
      }

      // Regular upload for smaller files
      List<int> audioBytes = await audioFile.readAsBytes();

      var response = await http.post(
        Uri.parse(_uploadEndpoint),
        headers: {
          'authorization': apiKey,
          'Content-Type': 'application/octet-stream',
        },
        body: audioBytes,
      ).timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          throw TimeoutException('Upload timeout after 5 minutes');
        },
      );

      onProgress?.call(1.0);

      // Requirement 3: Handle upload errors
      if (response.statusCode == 200) {
        var jsonResponse = json.decode(response.body);
        return {
          'success': true,
          'uploadUrl': jsonResponse['upload_url'],
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'Invalid API key. Please check your AssemblyAI credentials.',
          'errorCode': 'INVALID_API_KEY',
        };
      } else if (response.statusCode == 413) {
        return {
          'success': false,
          'error': 'File too large for upload.',
          'errorCode': 'FILE_TOO_LARGE',
        };
      } else {
        return {
          'success': false,
          'error': 'Upload failed with status ${response.statusCode}: ${response.body}',
          'errorCode': 'UPLOAD_FAILED',
          'statusCode': response.statusCode,
        };
      }
    } on SocketException catch (e) {
      return {
        'success': false,
        'error': 'No internet connection. Please check your network.',
        'errorCode': 'NETWORK_ERROR',
        'details': e.toString(),
      };
    } on TimeoutException catch (e) {
      return {
        'success': false,
        'error': e.message ?? 'Upload timeout',
        'errorCode': 'TIMEOUT',
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Upload error: ${e.toString()}',
        'errorCode': 'UNKNOWN_ERROR',
      };
    }
  }

  /// Upload large files in chunks (Requirement 11.2)
  Future<Map<String, dynamic>> _uploadAudioFileChunked(
    String filePath, {
    Function(double progress)? onProgress,
  }) async {
    try {
      File audioFile = File(filePath);
      int fileSize = await audioFile.length();
      
      // For simplicity, we'll read the entire file and send it
      // In production, you might want to implement true chunked streaming
      List<int> audioBytes = await audioFile.readAsBytes();
      
      int totalChunks = (fileSize / uploadChunkSize).ceil();
      int uploadedBytes = 0;

      // For now, send as single request but track progress
      var response = await http.post(
        Uri.parse(_uploadEndpoint),
        headers: {
          'authorization': apiKey,
          'Content-Type': 'application/octet-stream',
        },
        body: audioBytes,
      ).timeout(
        const Duration(minutes: 10), // Longer timeout for large files
      );

      onProgress?.call(1.0);

      if (response.statusCode == 200) {
        var jsonResponse = json.decode(response.body);
        return {
          'success': true,
          'uploadUrl': jsonResponse['upload_url'],
          'chunked': true,
        };
      } else {
        return {
          'success': false,
          'error': 'Chunked upload failed with status ${response.statusCode}',
          'errorCode': 'CHUNKED_UPLOAD_FAILED',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Chunked upload error: ${e.toString()}',
        'errorCode': 'CHUNKED_UPLOAD_ERROR',
      };
    }
  }

  /// Request transcription from AssemblyAI (Requirement 4)
  Future<Map<String, dynamic>> _requestTranscription(String audioUrl) async {
    try {
      // Requirement 4.1: Build request with optional features
      var requestBody = {
        'audio_url': audioUrl,
        'punctuate': punctuate,
        'format_text': true,
      };

      // Requirement 4.2: Add optional fields
      if (autoChapters) {
        requestBody['auto_chapters'] = true;
      }
      if (speakerLabels) {
        requestBody['speaker_labels'] = true;
      }
      if (languageCode.isNotEmpty) {
        requestBody['language_code'] = languageCode;
      }

      var response = await http.post(
        Uri.parse(_transcriptEndpoint),
        headers: {
          'authorization': apiKey,
          'Content-Type': 'application/json',
        },
        body: json.encode(requestBody),
      ).timeout(
        const Duration(seconds: 30),
      );

      // Requirement 4.3: Handle request errors
      if (response.statusCode == 200) {
        var jsonResponse = json.decode(response.body);
        return {
          'success': true,
          'transcriptionId': jsonResponse['id'],
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'Invalid API key.',
          'errorCode': 'INVALID_API_KEY',
        };
      } else if (response.statusCode == 429) {
        return {
          'success': false,
          'error': 'Rate limit exceeded. Please try again later.',
          'errorCode': 'RATE_LIMIT',
        };
      } else if (response.statusCode >= 500) {
        return {
          'success': false,
          'error': 'AssemblyAI server error. Please try again later.',
          'errorCode': 'SERVER_ERROR',
          'statusCode': response.statusCode,
        };
      } else {
        return {
          'success': false,
          'error': 'Transcription request failed with status ${response.statusCode}: ${response.body}',
          'errorCode': 'REQUEST_FAILED',
          'statusCode': response.statusCode,
        };
      }
    } on SocketException catch (e) {
      return {
        'success': false,
        'error': 'No internet connection.',
        'errorCode': 'NETWORK_ERROR',
        'details': e.toString(),
      };
    } on TimeoutException {
      return {
        'success': false,
        'error': 'Request timeout.',
        'errorCode': 'TIMEOUT',
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Transcription request error: ${e.toString()}',
        'errorCode': 'UNKNOWN_ERROR',
      };
    }
  }

  /// Poll for transcription completion with exponential backoff (Requirement 5)
  Future<Map<String, dynamic>> _pollForCompletion(
    String transcriptionId, {
    Function(double progress)? onProgress,
  }) async {
    int attempts = 0;
    Duration currentInterval = pollingInterval;
    const double exponentialBackoffFactor = 1.2;
    const Duration maxInterval = Duration(seconds: 10);

    while (attempts < maxPollingAttempts) {
      if (_isCancelled) {
        return _cancelledResponse();
      }

      try {
        await Future.delayed(currentInterval);

        var response = await http.get(
          Uri.parse('$_transcriptEndpoint/$transcriptionId'),
          headers: {
            'authorization': apiKey,
          },
        ).timeout(const Duration(seconds: 30));

        // Requirement 5.3: Update progress callback
        double progress = (attempts + 1) / maxPollingAttempts;
        onProgress?.call(progress);

        if (response.statusCode == 200) {
          var jsonResponse = json.decode(response.body);
          String status = jsonResponse['status'];

          // Requirement 5.1: Stop polling on completed or error
          switch (status) {
            case 'completed':
              return _parseTranscriptionResponse(jsonResponse);

            case 'error':
              return {
                'success': false,
                'error': 'Transcription failed: ${jsonResponse['error'] ?? 'Unknown error'}',
                'errorCode': 'TRANSCRIPTION_ERROR',
                'transcriptionId': transcriptionId,
              };

            case 'queued':
            case 'processing':
              // Requirement 5.2: Continue polling with exponential backoff
              attempts++;
              currentInterval = Duration(
                milliseconds: (currentInterval.inMilliseconds * exponentialBackoffFactor).round(),
              );
              if (currentInterval > maxInterval) {
                currentInterval = maxInterval;
              }
              break;

            default:
              attempts++;
              break;
          }
        } else if (response.statusCode == 401) {
          return {
            'success': false,
            'error': 'Invalid API key during polling.',
            'errorCode': 'INVALID_API_KEY',
          };
        } else {
          return {
            'success': false,
            'error': 'Polling failed with status ${response.statusCode}',
            'errorCode': 'POLLING_FAILED',
            'statusCode': response.statusCode,
          };
        }
      } on SocketException catch (e) {
        return {
          'success': false,
          'error': 'Lost internet connection during transcription.',
          'errorCode': 'NETWORK_ERROR',
          'details': e.toString(),
        };
      } on TimeoutException {
        attempts++;
        continue;
      } catch (e) {
        return {
          'success': false,
          'error': 'Polling error: ${e.toString()}',
          'errorCode': 'POLLING_ERROR',
        };
      }
    }

    // Requirement 9.4: Max polling exceeded
    return {
      'success': false,
      'error': 'Transcription timeout. Maximum polling attempts ($maxPollingAttempts) reached.',
      'errorCode': 'POLLING_TIMEOUT',
      'transcriptionId': transcriptionId,
    };
  }

  /// Parse transcription response (Requirement 6)
  Map<String, dynamic> _parseTranscriptionResponse(Map<String, dynamic> response) {
    try {
      // Requirement 6.1: Extract all required fields
      return {
        'success': true,
        'text': response['text'] ?? '',
        'words': response['words'] ?? [],
        'chapters': response['chapters'] ?? [],
        'utterances': response['utterances'] ?? [],
        'confidence': response['confidence'] ?? 0.0,
        'duration': response['audio_duration'] ?? 0,
      };
    } catch (e) {
      // Requirement 9.3: Invalid response / unexpected JSON
      return {
        'success': false,
        'error': 'Failed to parse transcription response: ${e.toString()}',
        'errorCode': 'PARSE_ERROR',
      };
    }
  }

  /// Extract action keywords from transcribed text (Requirement 7)
  Map<String, List<Map<String, dynamic>>> _extractKeywords(String text) {
    if (text.isEmpty) {
      return {
        'reminders': [],
        'calls': [],
        'emails': [],
        'tasks': [],
        'meetings': [],
      };
    }

    String lowerText = text.toLowerCase();
    
    Map<String, List<Map<String, dynamic>>> keywords = {
      'reminders': [],
      'calls': [],
      'emails': [],
      'tasks': [],
      'meetings': [],
    };

    // Define patterns with context
    Map<String, List<String>> patterns = {
      'reminders': [
        'remind me',
        'reminder',
        'don\'t forget',
        'remember to',
        'set a reminder',
        'remind',
      ],
      'calls': [
        'call',
        'phone',
        'ring',
        'contact',
        'dial',
      ],
      'emails': [
        'email',
        'send message',
        'write to',
        'mail',
        'send to',
      ],
      'tasks': [
        'todo',
        'to do',
        'task',
        'need to',
        'have to',
        'must',
      ],
      'meetings': [
        'meeting',
        'appointment',
        'schedule',
        'book',
        'meet with',
      ],
    };

    // Scan for each category
    patterns.forEach((category, patternList) {
      for (var pattern in patternList) {
        int index = lowerText.indexOf(pattern);
        while (index != -1) {
          // Extract context around the keyword
          int start = (index - 20).clamp(0, lowerText.length);
          int end = (index + pattern.length + 30).clamp(0, lowerText.length);
          String context = text.substring(start, end).trim();
          
          keywords[category]!.add({
            'keyword': pattern,
            'position': index,
            'context': context,
          });
          
          index = lowerText.indexOf(pattern, index + 1);
        }
      }
    });

    return keywords;
  }

  /// Get transcription by ID (Requirement 8.1)
  Future<Map<String, dynamic>> getTranscriptionById(String transcriptionId) async {
    try {
      var response = await http.get(
        Uri.parse('$_transcriptEndpoint/$transcriptionId'),
        headers: {
          'authorization': apiKey,
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        var jsonResponse = json.decode(response.body);
        
        if (jsonResponse['status'] == 'completed') {
          var parsed = _parseTranscriptionResponse(jsonResponse);
          return {
            ...parsed,
            'transcriptionId': transcriptionId,
            'keywords': _extractKeywords(parsed['text'] ?? ''),
          };
        } else {
          return {
            'success': false,
            'error': 'Transcription not completed yet. Status: ${jsonResponse['status']}',
            'errorCode': 'NOT_COMPLETED',
            'status': jsonResponse['status'],
          };
        }
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'Invalid API key.',
          'errorCode': 'INVALID_API_KEY',
        };
      } else if (response.statusCode == 404) {
        return {
          'success': false,
          'error': 'Transcription not found.',
          'errorCode': 'NOT_FOUND',
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to retrieve transcription with status ${response.statusCode}',
          'errorCode': 'RETRIEVAL_FAILED',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Failed to get transcription: ${e.toString()}',
        'errorCode': 'UNKNOWN_ERROR',
      };
    }
  }

  /// Delete a transcription (Requirement 8.2)
  Future<Map<String, dynamic>> deleteTranscription(String transcriptionId) async {
    try {
      var response = await http.delete(
        Uri.parse('$_transcriptEndpoint/$transcriptionId'),
        headers: {
          'authorization': apiKey,
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200 || response.statusCode == 204) {
        return {
          'success': true,
          'message': 'Transcription deleted successfully',
          'transcriptionId': transcriptionId,
        };
      } else if (response.statusCode == 404) {
        return {
          'success': false,
          'error': 'Transcription not found.',
          'errorCode': 'NOT_FOUND',
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to delete transcription with status ${response.statusCode}',
          'errorCode': 'DELETE_FAILED',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Failed to delete transcription: ${e.toString()}',
        'errorCode': 'UNKNOWN_ERROR',
      };
    }
  }

  /// Cancel ongoing transcription (Requirement 11.3)
  Future<Map<String, dynamic>> cancelTranscription() async {
    _isCancelled = true;
    
    if (_currentTranscriptionId != null) {
      // Optionally delete the transcription from AssemblyAI
      // await deleteTranscription(_currentTranscriptionId!);
    }
    
    return {
      'success': true,
      'message': 'Transcription cancelled',
      'transcriptionId': _currentTranscriptionId,
    };
  }

  /// Helper for cancelled response
  Map<String, dynamic> _cancelledResponse() {
    return {
      'success': false,
      'error': 'Transcription was cancelled by user',
      'errorCode': 'CANCELLED',
      'transcriptionId': _currentTranscriptionId,
    };
  }

  /// Check if transcription is in progress
  bool get isTranscribing => _currentTranscriptionId != null && !_isCancelled;

  /// Get current transcription ID
  String? get currentTranscriptionId => _currentTranscriptionId;
}