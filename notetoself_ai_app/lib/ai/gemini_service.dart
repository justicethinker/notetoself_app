// ==========================================
// gemini_service.dart
// Google Gemini AI Integration Service
// ==========================================

// 1) Top-of-file: imports & constants
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'dart:io' show Platform;
import 'package:crypto/crypto.dart';

// Constants (Requirement 1)
class GeminiConstants {
  // Models
  static const String defaultModel = 'gemini-1.5-flash';
  static const String proModel = 'gemini-1.5-pro';
  
  // Generation parameters
  static const double defaultTemperature = 0.0;
  static const int defaultMaxTokens = 1024;
  static const double defaultTopP = 0.95;
  static const int defaultTopK = 40;
  
  // Retry & timeout
  static const int maxRetries = 3;
  static const Duration requestTimeout = Duration(seconds: 30);
  static const double backoffFactor = 2.0;
  static const Duration maxBackoffDelay = Duration(seconds: 10);
  
  // Rate limiting
  static const int maxConcurrentRequests = 3;
  static const int maxRequestsPerMinute = 60;
  
  // Caching
  static const Duration cacheTTL = Duration(hours: 1);
  static const int maxCacheEntries = 100;
  
  // Circuit breaker
  static const int circuitBreakerThreshold = 5;
  static const Duration circuitBreakerCooldown = Duration(minutes: 5);
  
  // Content limits
  static const int maxTranscriptLength = 50000; // characters
  static const int maxTokenEstimate = 12000;
  
  // Schema version
  static const String responseSchemaVersion = '1.0';
}

// Cache entry class (Fix #1)
class _CacheEntry {
  final Map<String, dynamic> response;
  final DateTime timestamp;

  _CacheEntry({
    required this.response,
    required this.timestamp,
  });
}

// 4) Prompt templates (Requirement 4)
class PromptTemplates {
  /// Intent extraction prompt template
  /// Example input: "Remind me to call John tomorrow at 9am"
  /// Example output: {"intent":"create_reminder","entities":{...},"summary":"...","confidence":0.92}
  static const String intentExtractionTemplate = '''
You are an AI assistant that analyzes voice notes and extracts structured intent information.

Analyze the following transcript and extract:
1. Primary intent (e.g., create_reminder, create_task, make_call, send_email, schedule_meeting, take_note, unknown)
2. Entities (title, datetime, person, location, priority, etc.)
3. A concise summary
4. Confidence score (0.0 to 1.0)
5. Suggested actions

**Transcript:**
{{TRANSCRIPT}}

**Context:**
{{CONTEXT}}

**Instructions:**
- Return ONLY valid JSON, no markdown or commentary
- Use ISO 8601 format for datetimes (e.g., "2025-11-12T09:00:00+01:00")
- Normalize person names (capitalize properly)
- If uncertain, set intent to "unknown" and confidence below 0.5
- Priority should be: low, medium, high, or null

**Required JSON Schema:**
{
  "intent": "string (create_reminder|create_task|make_call|send_email|schedule_meeting|take_note|unknown)",
  "entities": {
    "title": "string or null",
    "datetime": "ISO 8601 string or null",
    "person": "string or null",
    "location": "string or null",
    "priority": "low|medium|high or null",
    "phone": "string or null",
    "email": "string or null"
  },
  "summary": "string (one sentence)",
  "confidence": number (0.0 to 1.0),
  "actions": [
    {
      "type": "string (create_reminder|create_task|etc.)",
      "params": object
    }
  ]
}

**Response (JSON only):**
''';

  /// Entity extraction template
  static const String entityExtractionTemplate = '''
Extract all entities from the following text. Return ONLY valid JSON.

**Text:**
{{TEXT}}

**Entity Types to Extract:**
{{ENTITY_TYPES}}

**Return JSON format:**
{
  "entities": [
    {
      "type": "person|datetime|location|phone|email|organization",
      "value": "extracted value",
      "canonical": "normalized value",
      "confidence": number (0.0 to 1.0)
    }
  ]
}

**Response (JSON only):**
''';

  /// Summary template
  static const String summaryTemplate = '''
Summarize the following text concisely.

**Text:**
{{TEXT}}

**Style:** {{STYLE}}

**Max length:** {{MAX_LENGTH}} words

Return ONLY valid JSON:
{
  "summary": "concise summary",
  "tldr": "one-line summary",
  "bulletPoints": ["point 1", "point 2", "point 3"],
  "wordCount": number
}

**Response (JSON only):**
''';

  /// JSON extraction fallback prompt
  static const String jsonExtractionTemplate = '''
Extract only the JSON object from the following text. Remove any markdown, commentary, or extra text.

**Text:**
{{TEXT}}

**Response (JSON only):**
''';
}

// 3) Main GeminiService class (Requirement 3)
class GeminiService {
  final String apiKey;
  final String model;
  final double temperature;
  final int maxTokens;
  final bool debug;
  
  late final GenerativeModel _model;
  FlutterSecureStorage? _secureStorage;
  
  // 8) Circuit breaker state
  int _consecutiveErrors = 0;
  DateTime? _circuitBreakerTrippedAt;
  bool get _isCircuitBreakerTripped {
    if (_circuitBreakerTrippedAt == null) return false;
    if (DateTime.now().difference(_circuitBreakerTrippedAt!) > GeminiConstants.circuitBreakerCooldown) {
      _circuitBreakerTrippedAt = null;
      _consecutiveErrors = 0;
      return false;
    }
    return true;
  }
  
  // 10) Concurrency control
  int _activeRequests = 0;
  final List<Completer> _requestQueue = [];
  
  // 11) Cancellation support
  bool _isCancelled = false;
  
  // 14) Response cache
  final Map<String, _CacheEntry> _responseCache = {};
  
  // 9) Rate limiting
  final List<DateTime> _requestTimestamps = [];
  
  // 15) Request tracking
  int _requestCounter = 0;

  /// Constructor (Requirement 3)
  GeminiService({
    String? apiKey,
    this.model = GeminiConstants.defaultModel,
    this.temperature = GeminiConstants.defaultTemperature,
    this.maxTokens = GeminiConstants.defaultMaxTokens,
    this.debug = false,
  }) : apiKey = apiKey ?? _getApiKeyFromEnv() {
    _validateApiKey();
    _initializeSecureStorage();
    _initializeModel();
  }

  /// Factory for mock service (Requirement 23) (Fix #2)
  factory GeminiService.mock() {
    return GeminiMockService();
  }

  // 2) Configuration & secrets management (Requirement 2)
  static String _getApiKeyFromEnv() {
    try {
      // Fix #3: Ensure dotenv is loaded before calling this
      final key = dotenv.env['GEMINI_API_KEY'];
      if (key == null || key.isEmpty) {
        throw Exception('GEMINI_API_KEY not found in environment. Make sure dotenv.load() was called in main().');
      }
      return key;
    } catch (e) {
      throw Exception('Failed to load API key: $e');
    }
  }

  /// Initialize secure storage (Fix #8: Handle non-mobile platforms)
  void _initializeSecureStorage() {
    try {
      // Only initialize on mobile platforms
      if (Platform.isAndroid || Platform.isIOS) {
        _secureStorage = const FlutterSecureStorage();
      } else {
        if (debug) print('Secure storage not available on this platform');
      }
    } catch (e) {
      if (debug) print('Failed to initialize secure storage: $e');
    }
  }

  /// Get API key from secure storage (device-specific keys)
  Future<String?> _getApiKeyFromSecureStorage() async {
    if (_secureStorage == null) return null;
    
    try {
      return await _secureStorage!.read(key: 'gemini_api_key');
    } catch (e) {
      if (debug) print('Failed to read API key from secure storage: $e');
      return null;
    }
  }

  /// Store API key in secure storage
  Future<void> storeApiKey(String key) async {
    if (_secureStorage == null) {
      if (debug) print('Secure storage not available');
      return;
    }
    
    try {
      await _secureStorage!.write(key: 'gemini_api_key', value: key);
    } catch (e) {
      if (debug) print('Failed to store API key: $e');
    }
  }

  void _validateApiKey() {
    if (apiKey.isEmpty) {
      throw ArgumentError('API key cannot be empty');
    }
    if (apiKey.length < 30) {
      if (debug) print('Warning: API key seems too short');
    }
  }

  void _initializeModel() {
    _model = GenerativeModel(
      model: model,
      apiKey: apiKey,
      generationConfig: GenerationConfig(
        temperature: temperature,
        maxOutputTokens: maxTokens,
        topP: GeminiConstants.defaultTopP,
        topK: GeminiConstants.defaultTopK,
      ),
    );
  }

  // 3) Public methods (Requirement 3)

  /// Analyze intent from transcript
  /// 
  /// Example:
  /// ```dart
  /// var result = await service.analyzeIntent("Remind me to call John tomorrow at 9am");
  /// // Returns: {'success': true, 'data': {'intent': 'create_reminder', ...}}
  /// ```
  Future<Map<String, dynamic>> analyzeIntent(
    String transcript, {
    Map<String, dynamic>? context,
    Function(double progress, String status)? onProgress,
  }) async {
    final requestId = _generateRequestId();
    
    try {
      // Validation
      if (transcript.isEmpty) {
        return _errorResponse('EMPTY_TRANSCRIPT', 'Transcript cannot be empty');
      }

      if (transcript.length > GeminiConstants.maxTranscriptLength) {
        return _errorResponse('TRANSCRIPT_TOO_LONG', 
          'Transcript exceeds maximum length of ${GeminiConstants.maxTranscriptLength} characters');
      }

      // Check cache (Requirement 14)
      final cacheKey = _generateCacheKey(transcript, context);
      final cached = _getCachedResponse(cacheKey);
      if (cached != null) {
        if (debug) print('[$requestId] Returning cached response');
        return cached;
      }

      onProgress?.call(0.1, 'Preparing request');

      // Build prompt (Fix #10: Don't log raw transcript in production)
      final prompt = _buildIntentPrompt(transcript, context ?? {});
      if (debug) _logSanitized(requestId, 'Prompt length: ${prompt.length}');
      
      onProgress?.call(0.3, 'Sending to AI');

      // Make request with retry
      final response = await _makeRequestWithRetry(
        prompt,
        requestId: requestId,
        onProgress: (p) => onProgress?.call(0.3 + (p * 0.5), 'Processing'),
      );

      if (!response['success']) {
        return response;
      }

      onProgress?.call(0.8, 'Parsing response');

      // Parse and validate
      final parsed = _parseIntentResponse(response['data']);
      
      if (!parsed['success']) {
        return parsed;
      }

      onProgress?.call(1.0, 'Complete');

      // Cache successful response
      final result = {
        'success': true,
        'data': parsed['data'],
        'raw': debug ? response['raw'] : null,
        'requestId': requestId,
      };
      
      _cacheResponse(cacheKey, result);
      
      _logRequest(requestId, 'analyzeIntent', true, transcript.length);
      
      return result;

    } catch (e) {
      _logRequest(requestId, 'analyzeIntent', false, transcript.length, error: e.toString());
      return _errorResponse('UNKNOWN_ERROR', 'Failed to analyze intent: $e');
    }
  }

  /// Summarize text
  /// 
  /// Example:
  /// ```dart
  /// var result = await service.summarize("Long text here...", maxTokens: 100);
  /// // Returns: {'success': true, 'data': {'summary': '...', 'tldr': '...'}}
  /// ```
  Future<Map<String, dynamic>> summarize(
    String text, {
    int? maxTokens,
    String style = 'concise',
  }) async {
    final requestId = _generateRequestId();
    
    try {
      if (text.isEmpty) {
        return _errorResponse('EMPTY_TEXT', 'Text cannot be empty');
      }

      // Check cache
      final cacheKey = _generateCacheKey(text, {'style': style, 'maxTokens': maxTokens});
      final cached = _getCachedResponse(cacheKey);
      if (cached != null) return cached;

      final prompt = _buildSummaryPrompt(text, style, maxTokens ?? 100);
      
      final response = await _makeRequestWithRetry(prompt, requestId: requestId);
      
      if (!response['success']) return response;

      final parsed = _parseSummaryResponse(response['data']);
      
      if (!parsed['success']) return parsed;

      final result = {
        'success': true,
        'data': parsed['data'],
        'raw': debug ? response['raw'] : null,
        'requestId': requestId,
      };
      
      _cacheResponse(cacheKey, result);
      _logRequest(requestId, 'summarize', true, text.length);
      
      return result;

    } catch (e) {
      _logRequest(requestId, 'summarize', false, text.length, error: e.toString());
      return _errorResponse('UNKNOWN_ERROR', 'Failed to summarize: $e');
    }
  }

  /// Extract entities from text
  /// 
  /// Example:
  /// ```dart
  /// var result = await service.extractEntities("Call John at 555-1234 tomorrow");
  /// // Returns: {'success': true, 'data': {'entities': [...]}}
  /// ```
  Future<Map<String, dynamic>> extractEntities(
    String text, {
    List<String>? entityTypes,
  }) async {
    final requestId = _generateRequestId();
    
    try {
      if (text.isEmpty) {
        return _errorResponse('EMPTY_TEXT', 'Text cannot be empty');
      }

      final types = entityTypes ?? ['person', 'datetime', 'location', 'phone', 'email'];
      
      final cacheKey = _generateCacheKey(text, {'entityTypes': types});
      final cached = _getCachedResponse(cacheKey);
      if (cached != null) return cached;

      final prompt = _buildEntityExtractionPrompt(text, types);
      
      final response = await _makeRequestWithRetry(prompt, requestId: requestId);
      
      if (!response['success']) return response;

      final parsed = _parseEntityResponse(response['data']);
      
      if (!parsed['success']) return parsed;

      final result = {
        'success': true,
        'data': parsed['data'],
        'raw': debug ? response['raw'] : null,
        'requestId': requestId,
      };
      
      _cacheResponse(cacheKey, result);
      _logRequest(requestId, 'extractEntities', true, text.length);
      
      return result;

    } catch (e) {
      _logRequest(requestId, 'extractEntities', false, text.length, error: e.toString());
      return _errorResponse('UNKNOWN_ERROR', 'Failed to extract entities: $e');
    }
  }

  /// Generate reply to prompt
  /// 
  /// Example:
  /// ```dart
  /// var result = await service.generateReply("What's the weather?");
  /// ```
  Future<Map<String, dynamic>> generateReply(
    String prompt, {
    Map<String, dynamic>? options,
  }) async {
    final requestId = _generateRequestId();
    
    try {
      if (prompt.isEmpty) {
        return _errorResponse('EMPTY_PROMPT', 'Prompt cannot be empty');
      }

      final response = await _makeRequestWithRetry(prompt, requestId: requestId);
      
      if (!response['success']) return response;

      final result = {
        'success': true,
        'data': {'reply': response['data']},
        'raw': debug ? response['raw'] : null,
        'requestId': requestId,
      };
      
      _logRequest(requestId, 'generateReply', true, prompt.length);
      
      return result;

    } catch (e) {
      _logRequest(requestId, 'generateReply', false, prompt.length, error: e.toString());
      return _errorResponse('UNKNOWN_ERROR', 'Failed to generate reply: $e');
    }
  }

  /// Warmup the service (test connectivity)
  Future<void> warmup() async {
    try {
      if (debug) print('Warming up Gemini service...');
      
      final response = await _model.generateContent([
        Content.text('Hello')
      ]).timeout(Duration(seconds: 10));
      
      if (debug) print('Warmup successful');
    } catch (e) {
      if (debug) print('Warmup failed: $e');
    }
  }

  /// Close and cleanup
  Future<void> close() async {
    _responseCache.clear();
    _requestQueue.clear();
    _requestTimestamps.clear();
    if (debug) print('GeminiService closed');
  }

  // 5) Request building & sending (Requirement 5)

  String _buildIntentPrompt(String transcript, Map<String, dynamic> context) {
    return PromptTemplates.intentExtractionTemplate
        .replaceAll('{{TRANSCRIPT}}', transcript)
        .replaceAll('{{CONTEXT}}', json.encode(context));
  }

  String _buildSummaryPrompt(String text, String style, int maxLength) {
    return PromptTemplates.summaryTemplate
        .replaceAll('{{TEXT}}', text)
        .replaceAll('{{STYLE}}', style)
        .replaceAll('{{MAX_LENGTH}}', maxLength.toString());
  }

  String _buildEntityExtractionPrompt(String text, List<String> entityTypes) {
    return PromptTemplates.entityExtractionTemplate
        .replaceAll('{{TEXT}}', text)
        .replaceAll('{{ENTITY_TYPES}}', entityTypes.join(', '));
  }

  /// Make request with retry logic (Requirement 8)
  Future<Map<String, dynamic>> _makeRequestWithRetry(
    String prompt, {
    required String requestId,
    Function(double progress)? onProgress,
  }) async {
    // 8) Circuit breaker check
    if (_isCircuitBreakerTripped) {
      return _errorResponse('CIRCUIT_BREAKER_OPEN', 
        'Service temporarily unavailable. Please try again later.');
    }

    // 9) Rate limiting check
    if (!_checkRateLimit()) {
      _recordRequest(); // Fix #6: Count rejected requests
      return _errorResponse('RATE_LIMIT', 
        'Too many requests. Please slow down.');
    }

    // 10) Concurrency control
    await _acquireRequestSlot();

    int attempt = 0;
    Duration backoffDelay = Duration(seconds: 1);

    while (attempt <= GeminiConstants.maxRetries) {
      if (_isCancelled) {
        _releaseRequestSlot();
        return _errorResponse('CANCELLED', 'Request was cancelled');
      }

      try {
        onProgress?.call(attempt / (GeminiConstants.maxRetries + 1));

        if (debug) print('[$requestId] Attempt ${attempt + 1}/${GeminiConstants.maxRetries + 1}');

        final response = await _model.generateContent([
          Content.text(prompt)
        ]).timeout(GeminiConstants.requestTimeout);

        // Fix #5: Defensive check for response.text
        final text = response.text;
        
        if (text == null || text.isEmpty) {
          throw Exception('Empty response from model');
        }

        // Reset error counter on success
        _consecutiveErrors = 0;
        
        _releaseRequestSlot();
        _recordRequest();

        return {
          'success': true,
          'data': text,
          'raw': response,
        };

      } catch (e) {
        attempt++;
        
        if (debug) print('[$requestId] Attempt $attempt failed: $e');

        // Determine if error is retryable
        final errorCode = _categorizeError(e);
        
        // Don't retry on auth errors or bad requests
        if (errorCode == 'INVALID_API_KEY' || errorCode == 'AUTH_ERROR') {
          _releaseRequestSlot();
          return _errorResponse(errorCode, e.toString());
        }

        if (attempt > GeminiConstants.maxRetries) {
          _consecutiveErrors++;
          
          // Trip circuit breaker if too many errors
          if (_consecutiveErrors >= GeminiConstants.circuitBreakerThreshold) {
            _circuitBreakerTrippedAt = DateTime.now();
            if (debug) print('[$requestId] Circuit breaker tripped');
          }
          
          _releaseRequestSlot();
          return _errorResponse(errorCode, 'Request failed after ${GeminiConstants.maxRetries} retries: $e');
        }

        // Exponential backoff with jitter
        await Future.delayed(_calculateBackoff(attempt, backoffDelay));
        backoffDelay = Duration(
          milliseconds: (backoffDelay.inMilliseconds * GeminiConstants.backoffFactor).round()
        );
        if (backoffDelay > GeminiConstants.maxBackoffDelay) {
          backoffDelay = GeminiConstants.maxBackoffDelay;
        }
      }
    }

    _releaseRequestSlot();
    return _errorResponse('MAX_RETRIES_EXCEEDED', 'Failed after maximum retries');
  }

  // 6) Response handling & validation (Requirement 6)

  Map<String, dynamic> _parseIntentResponse(String responseText) {
    try {
      // Strip markdown and extract JSON
      final jsonText = _extractJson(responseText);
      
      final data = json.decode(jsonText) as Map<String, dynamic>;
      
      // Validate required fields
      if (!data.containsKey('intent') || !data.containsKey('summary')) {
        return _errorResponse('INVALID_RESPONSE', 
          'Response missing required fields: intent, summary');
      }

      // Validate confidence
      final confidence = data['confidence'] as num?;
      if (confidence != null && confidence < 0.5) {
        return _errorResponse('LOW_CONFIDENCE', 
          'Intent recognition confidence too low: $confidence',
          data: data);
      }

      // Ensure all expected fields exist
      data['entities'] ??= {};
      data['actions'] ??= [];
      data['confidence'] ??= 1.0;

      return {
        'success': true,
        'data': data,
      };

    } catch (e) {
      if (debug) {
        print('Failed to parse intent response: $e');
        _logSanitized('parse_error', 'Response length: ${responseText.length}');
      }
      
      // Attempt fallback JSON extraction
      return _attemptFallbackParsing(responseText, 'intent');
    }
  }

  Map<String, dynamic> _parseSummaryResponse(String responseText) {
    try {
      final jsonText = _extractJson(responseText);
      final data = json.decode(jsonText) as Map<String, dynamic>;
      
      if (!data.containsKey('summary')) {
        return _errorResponse('INVALID_RESPONSE', 'Response missing summary field');
      }

      data['tldr'] ??= data['summary'];
      data['bulletPoints'] ??= [];

      return {
        'success': true,
        'data': data,
      };

    } catch (e) {
      if (debug) print('Failed to parse summary response: $e');
      return _attemptFallbackParsing(responseText, 'summary');
    }
  }

  Map<String, dynamic> _parseEntityResponse(String responseText) {
    try {
      final jsonText = _extractJson(responseText);
      final data = json.decode(jsonText) as Map<String, dynamic>;
      
      if (!data.containsKey('entities')) {
        return _errorResponse('INVALID_RESPONSE', 'Response missing entities field');
      }

      return {
        'success': true,
        'data': data,
      };

    } catch (e) {
      if (debug) print('Failed to parse entity response: $e');
      return _attemptFallbackParsing(responseText, 'entities');
    }
  }

  /// Extract JSON from text (handle markdown wrappers) (Fix #9: Resilient extraction)
  String _extractJson(String text) {
    // Remove markdown code blocks
    text = text.trim();
    
    // Remove ```json and ``` wrappers
    if (text.startsWith('```json')) {
      text = text.substring(7);
    } else if (text.startsWith('```')) {
      text = text.substring(3);
    }
    
    if (text.endsWith('```')) {
      text = text.substring(0, text.length - 3);
    }
    
    text = text.trim();
    
    // Find JSON object boundaries
    final startIndex = text.indexOf('{');
    final endIndex = text.lastIndexOf('}');
    
    if (startIndex == -1 || endIndex == -1) {
      throw FormatException('No JSON object found in response');
    }
    
    return text.substring(startIndex, endIndex + 1);
  }

  /// Attempt fallback JSON extraction with smaller prompt
  Future<Map<String, dynamic>> _attemptFallbackParsing(
    String responseText, 
    String expectedType
  ) async {
    if (debug) print('Attempting fallback JSON extraction for $expectedType');
    
    try {
      final fallbackPrompt = PromptTemplates.jsonExtractionTemplate
          .replaceAll('{{TEXT}}', responseText);
      
      final response = await _model.generateContent([
        Content.text(fallbackPrompt)
      ]).timeout(Duration(seconds: 10));
      
      final text = response.text;
      if (text == null || text.isEmpty) {
        throw Exception('Empty fallback response');
      }
      
      final extracted = _extractJson(text);
      final data = json.decode(extracted);
      
      return {
        'success': true,
        'data': data,
        'fallbackUsed': true,
      };
    } catch (e) {
      return _errorResponse('PARSE_ERROR', 
        'Failed to parse response even with fallback: $e');
    }
  }

  // 7) Error handling (Requirement 7)

  String _categorizeError(dynamic error) {
    final errorStr = error.toString().toLowerCase();
    
    if (errorStr.contains('api key') || errorStr.contains('unauthorized') || errorStr.contains('401')) {
      return 'INVALID_API_KEY';
    }
    if (errorStr.contains('rate limit') || errorStr.contains('429')) {
      return 'RATE_LIMIT';
    }
    if (errorStr.contains('timeout')) {
      return 'TIMEOUT';
    }
    if (errorStr.contains('network') || errorStr.contains('socket')) {
      return 'NETWORK_ERROR';
    }
    if (errorStr.contains('500') || errorStr.contains('502') || errorStr.contains('503')) {
      return 'MODEL_ERROR';
    }
    
    return 'UNKNOWN_ERROR';
  }

  Map<String, dynamic> _errorResponse(String errorCode, String error, {Map<String, dynamic>? data}) {
    return {
      'success': false,
      'error': error,
      'errorCode': errorCode,
      'data': data,
    };
  }

  // 9) Rate limiting (Requirement 9)

  bool _checkRateLimit() {
    final now = DateTime.now();
    final oneMinuteAgo = now.subtract(Duration(minutes: 1));
    
    // Remove old timestamps
    _requestTimestamps.removeWhere((ts) => ts.isBefore(oneMinuteAgo));
    
    if (_requestTimestamps.length >= GeminiConstants.maxRequestsPerMinute) {
      if (debug) print('Rate limit exceeded: ${_requestTimestamps.length} requests in last minute');
      return false;
    }
    
    return true;
  }

  void _recordRequest() {
    _requestTimestamps.add(DateTime.now());
  }

  // 10) Concurrency control (Requirement 10)

  Future<void> _acquireRequestSlot() async {
    if (_activeRequests >= GeminiConstants.maxConcurrentRequests) {
      final completer = Completer();
      _requestQueue.add(completer);
      await completer.future;
    }
    _activeRequests++;
  }

  void _releaseRequestSlot() {
    _activeRequests--;
    if (_requestQueue.isNotEmpty) {
      final completer = _requestQueue.removeAt(0);
      completer.complete();
    }
  }

  // 8) Backoff calculation with jitter (Requirement 8)

  Duration _calculateBackoff(int attempt, Duration baseDelay) {
    final jitter = Random().nextDouble() * 0.3; // 0-30% jitter
    final delayMs = baseDelay.inMilliseconds * (1 + jitter);
    return Duration(milliseconds: delayMs.round());
  }

  // 11) Cancellation (Requirement 11)

  void cancel() {
    _isCancelled = true;
    if (debug) print('Cancellation requested');
  }

  void resetCancellation() {
    _isCancelled = false;
  }

  // 14) Caching (Requirement 14)

  String _generateCacheKey(String input, Map<String, dynamic>? context) {
    final combined = '$input${json.encode(context ?? {})}';
    return md5.convert(utf8.encode(combined)).toString();
  }

  void _cacheResponse(String key, Map<String, dynamic> response) {
    // Limit cache size
    if (_responseCache.length >= GeminiConstants.maxCacheEntries) {
      // Remove oldest entry
      final oldestKey = _