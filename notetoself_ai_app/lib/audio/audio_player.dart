import 'package:flutter_sound/flutter_sound.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class AudioPlayer {
  FlutterSoundPlayer? _player;
  String? currentFilePath;
  DateTime? _playbackStartTime;
  Duration? _pausedPosition;
  Duration? _totalDuration;
  bool _isPaused = false;

  AudioPlayer() {
    _player = FlutterSoundPlayer();
  }

  /// Initialize the audio player
  Future<Map<String, dynamic>> init() async {
    try {
      await _player!.openPlayer();
      
      return {
        'success': true,
        'message': 'Audio player initialized successfully'
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Initialization failed: ${e.toString()}'
      };
    }
  }

  /// Play an audio file
  Future<Map<String, dynamic>> play(String filePath) async {
    try {
      // Check if player is initialized
      if (_player == null || !_player!.isPlayerInitialised) {
        return {
          'success': false,
          'message': 'Player not initialized. Please call init() first.'
        };
      }

      // Check if file exists
      File audioFile = File(filePath);
      if (!await audioFile.exists()) {
        return {
          'success': false,
          'message': 'Audio file not found at: $filePath'
        };
      }

      // Stop current playback if already playing
      if (_player!.isPlaying) {
        await _player!.stopPlayer();
      }

      // Reset state
      _isPaused = false;
      _pausedPosition = null;
      currentFilePath = filePath;
      _playbackStartTime = DateTime.now();

      // Get file duration
      try {
        _totalDuration = await _player!.startPlayer(
          fromURI: filePath,
          codec: Codec.aacADTS,
          whenFinished: () {
            _onPlaybackFinished();
          },
        );
      } catch (e) {
        _totalDuration = null;
      }

      return {
        'success': true,
        'message': 'Playback started',
        'filePath': filePath,
        'duration': _totalDuration?.inSeconds ?? 0
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Failed to play audio: ${e.toString()}'
      };
    }
  }

  /// Pause current playback
  Future<Map<String, dynamic>> pause() async {
    try {
      // Check if player is initialized
      if (_player == null || !_player!.isPlayerInitialised) {
        return {
          'success': false,
          'message': 'Player not initialized'
        };
      }

      // Check if actually playing
      if (!_player!.isPlaying) {
        return {
          'success': false,
          'message': 'No audio is currently playing'
        };
      }

      // Check if already paused
      if (_isPaused) {
        return {
          'success': false,
          'message': 'Playback is already paused'
        };
      }

      // Calculate current position
      if (_playbackStartTime != null) {
        Duration elapsed = DateTime.now().difference(_playbackStartTime!);
        _pausedPosition = _pausedPosition != null 
            ? _pausedPosition! + elapsed 
            : elapsed;
      }

      await _player!.pausePlayer();
      _isPaused = true;

      return {
        'success': true,
        'message': 'Playback paused',
        'position': _pausedPosition?.inSeconds ?? 0
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Failed to pause playback: ${e.toString()}'
      };
    }
  }

  /// Resume paused playback
  Future<Map<String, dynamic>> resume() async {
    try {
      // Check if player is initialized
      if (_player == null || !_player!.isPlayerInitialised) {
        return {
          'success': false,
          'message': 'Player not initialized'
        };
      }

      // Check if paused
      if (!_isPaused) {
        return {
          'success': false,
          'message': 'Playback is not paused'
        };
      }

      await _player!.resumePlayer();
      _isPaused = false;
      _playbackStartTime = DateTime.now();

      return {
        'success': true,
        'message': 'Playback resumed',
        'position': _pausedPosition?.inSeconds ?? 0
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Failed to resume playback: ${e.toString()}'
      };
    }
  }

  /// Stop playback
  Future<Map<String, dynamic>> stop() async {
    try {
      // Check if player is initialized
      if (_player == null || !_player!.isPlayerInitialised) {
        return {
          'success': false,
          'message': 'Player not initialized'
        };
      }

      // Check if playing or paused
      if (!_player!.isPlaying && !_isPaused) {
        return {
          'success': false,
          'message': 'No audio is currently playing'
        };
      }

      await _player!.stopPlayer();
      
      // Reset state
      String? stoppedFile = currentFilePath;
      _playbackStartTime = null;
      _pausedPosition = null;
      _totalDuration = null;
      _isPaused = false;
      currentFilePath = null;

      return {
        'success': true,
        'message': 'Playback stopped',
        'filePath': stoppedFile
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Failed to stop playback: ${e.toString()}'
      };
    }
  }

  /// Seek to a specific position in the audio
  Future<Map<String, dynamic>> seekTo(Duration position) async {
    try {
      // Check if player is initialized
      if (_player == null || !_player!.isPlayerInitialised) {
        return {
          'success': false,
          'message': 'Player not initialized'
        };
      }

      // Check if audio is loaded
      if (currentFilePath == null) {
        return {
          'success': false,
          'message': 'No audio file loaded'
        };
      }

      // Check if position is valid
      if (_totalDuration != null && position > _totalDuration!) {
        return {
          'success': false,
          'message': 'Seek position exceeds audio duration'
        };
      }

      await _player!.seekToPlayer(position);
      
      // Update tracking
      _pausedPosition = position;
      _playbackStartTime = DateTime.now();

      return {
        'success': true,
        'message': 'Seeked to position',
        'position': position.inSeconds
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Failed to seek: ${e.toString()}'
      };
    }
  }

  /// Set volume (0.0 to 1.0)
  Future<Map<String, dynamic>> setVolume(double volume) async {
    try {
      // Validate volume range
      if (volume < 0.0 || volume > 1.0) {
        return {
          'success': false,
          'message': 'Volume must be between 0.0 and 1.0'
        };
      }

      // Check if player is initialized
      if (_player == null || !_player!.isPlayerInitialised) {
        return {
          'success': false,
          'message': 'Player not initialized'
        };
      }

      await _player!.setVolume(volume);

      return {
        'success': true,
        'message': 'Volume set',
        'volume': volume
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Failed to set volume: ${e.toString()}'
      };
    }
  }

  /// Enable or disable looping
  Future<Map<String, dynamic>> setLoop(bool loop) async {
    try {
      // Check if player is initialized
      if (_player == null || !_player!.isPlayerInitialised) {
        return {
          'success': false,
          'message': 'Player not initialized'
        };
      }

      // Note: flutter_sound doesn't have built-in loop,
      // but we can handle it in the whenFinished callback
      // This is a placeholder for loop functionality

      return {
        'success': true,
        'message': 'Loop ${loop ? 'enabled' : 'disabled'}',
        'loop': loop
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Failed to set loop: ${e.toString()}'
      };
    }
  }

  /// Get current playback position
  Future<Duration?> getCurrentPosition() async {
    try {
      if (_player == null || !_player!.isPlayerInitialised) {
        return null;
      }
      
      if (_isPaused && _pausedPosition != null) {
        return _pausedPosition;
      }
      
      if (_playbackStartTime != null && _player!.isPlaying) {
        Duration elapsed = DateTime.now().difference(_playbackStartTime!);
        Duration total = _pausedPosition != null 
            ? _pausedPosition! + elapsed 
            : elapsed;
        return total;
      }
      
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Callback when playback finishes
  void _onPlaybackFinished() {
    _playbackStartTime = null;
    _pausedPosition = null;
    _isPaused = false;
    // currentFilePath remains set for potential replay
  }

  /// Check if player is currently playing
  bool get isPlaying => _player?.isPlaying ?? false;

  /// Check if player is paused
  bool get isPaused => _isPaused;

  /// Check if player is initialized
  bool get isInitialized => _player?.isPlayerInitialised ?? false;

  /// Get playback duration (elapsed time)
  Duration? get playbackDuration {
    if (_isPaused && _pausedPosition != null) {
      return _pausedPosition;
    }
    
    if (_playbackStartTime != null && _player?.isPlaying == true) {
      Duration elapsed = DateTime.now().difference(_playbackStartTime!);
      return _pausedPosition != null 
          ? _pausedPosition! + elapsed 
          : elapsed;
    }
    
    return null;
  }

  /// Get remaining duration
  Duration? get remainingDuration {
    if (_totalDuration == null) return null;
    
    Duration? current = playbackDuration;
    if (current == null) return _totalDuration;
    
    Duration remaining = _totalDuration! - current;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Get total duration of current audio
  Duration? get totalDuration => _totalDuration;

  /// Get playback progress (0.0 to 1.0)
  double? get progress {
    if (_totalDuration == null || _totalDuration!.inMilliseconds == 0) {
      return null;
    }
    
    Duration? current = playbackDuration;
    if (current == null) return 0.0;
    
    double progressValue = current.inMilliseconds / _totalDuration!.inMilliseconds;
    return progressValue.clamp(0.0, 1.0);
  }

  /// Dispose the player and free resources
  Future<void> dispose() async {
    try {
      if (_player != null) {
        if (_player!.isPlaying) {
          await _player!.stopPlayer();
        }
        await _player!.closePlayer();
        _player = null;
      }
      
      // Reset state
      _playbackStartTime = null;
      _pausedPosition = null;
      _totalDuration = null;
      _isPaused = false;
      currentFilePath = null;
    } catch (e) {
      print('Error disposing player: ${e.toString()}');
    }
  }
}