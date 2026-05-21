import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/constants/x_api_constants.dart';
import '../../core/constants/x_auth_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/errors/x_api_exception.dart';
import '../../domain/models/app_user.dart';

class XAuthClient {
  XAuthClient({required Dio dio}) : _dio = dio;

  final Dio _dio;

  Future<XTokenResponse> exchangeCodeForToken({
    required String clientId,
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) async {
    final requestHeaders = <String, String>{
      Headers.contentTypeHeader: Headers.formUrlEncodedContentType,
    };

    try {
      final response = await _sendWithDnsFallback(
        method: 'POST',
        primaryUrl: XAuthConstants.tokenEndpoint,
        fallbackUrl: XAuthConstants.fallbackTokenEndpoint,
        requestHeaders: requestHeaders,
        send: (url) => _dio.post<Map<String, dynamic>>(
          url,
          data: <String, dynamic>{
            'client_id': clientId,
            'code': code,
            'code_verifier': codeVerifier,
            'grant_type': 'authorization_code',
            'redirect_uri': redirectUri,
          },
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            responseType: ResponseType.json,
          ),
        ),
      );

      _logResponse(
        method: 'POST',
        requestUrl: response.realUri.toString(),
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.data,
      );

      final body = response.data;
      if (body == null) {
        throw const AppException('X token response was empty.');
      }

      final accessToken = body['access_token'] as String? ?? '';
      if (accessToken.isEmpty) {
        throw AppException(
          'X token response did not include an access token.',
          details: body,
        );
      }

      return XTokenResponse(
        accessToken: accessToken,
        refreshToken: body['refresh_token'] as String?,
        expiresIn: (body['expires_in'] as num?)?.toInt(),
      );
    } on DioException catch (error) {
      _logError(
        method: 'POST',
        requestUrl: error.requestOptions.uri.toString(),
        error: error,
      );
      if (_isNetworkReachabilityIssue(error)) {
        throw AppException(
          '\u0044\u004e\u0053\u002f\u30cd\u30c3\u30c8\u30ef\u30fc\u30af\u5230\u9054\u6027\u306e\u554f\u984c\u306e\u53ef\u80fd\u6027\u304c\u3042\u308a\u307e\u3059\u3002\u0058\u0020\u0041\u0050\u0049\u0020\u0068\u006f\u0073\u0074\u0020\u306b\u63a5\u7d9a\u3067\u304d\u307e\u305b\u3093\u3067\u3057\u305f\u3002',
          details: error.message,
        );
      }
      throw AppException(
        'Failed to exchange the X authorization code for a token.',
        details: error.response?.data ?? error.message,
      );
    }
  }

  Future<AppUser> fetchCurrentUser({
    required String accessToken,
    String? debugUserId,
  }) async {
    final requestHeaders = <String, String>{
      'Authorization': 'Bearer $accessToken',
    };

    try {
      final response = await _sendWithDnsFallback(
        method: 'GET',
        primaryUrl: XAuthConstants.currentUserEndpoint,
        fallbackUrl: XAuthConstants.fallbackCurrentUserEndpoint,
        requestHeaders: requestHeaders,
        send: (url) => _dio.get<Map<String, dynamic>>(
          url,
          options: Options(
            headers: requestHeaders,
            responseType: ResponseType.json,
          ),
        ),
      );

      _logResponse(
        method: 'GET',
        requestUrl: response.realUri.toString(),
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.data,
      );

      final body = response.data;
      final data = body?['data'] as Map<String, dynamic>?;
      if (data == null) {
        throw XApiException.invalidResponse('X user response was empty.');
      }

      final id = data['id'] as String? ?? '';
      final name = data['name'] as String? ?? '';
      final username = data['username'] as String? ?? '';
      if (id.isEmpty || name.isEmpty || username.isEmpty) {
        throw XApiException.invalidResponse(
          'X user response did not include the required user fields.',
        );
      }

      return AppUser(
        id: id,
        name: name,
        username: username,
      );
    } on DioException catch (error) {
      _logError(
        method: 'GET',
        requestUrl: error.requestOptions.uri.toString(),
        error: error,
      );
      if (error.response?.statusCode == 503 &&
          (debugUserId ?? '').isNotEmpty) {
        await _debugProbeUserById(
          accessToken: accessToken,
          userId: debugUserId!,
        );
      }
      if (_isNetworkReachabilityIssue(error)) {
        throw AppException(
          '\u0044\u004e\u0053\u002f\u30cd\u30c3\u30c8\u30ef\u30fc\u30af\u5230\u9054\u6027\u306e\u554f\u984c\u306e\u53ef\u80fd\u6027\u304c\u3042\u308a\u307e\u3059\u3002\u0058\u0020\u0041\u0050\u0049\u0020\u0068\u006f\u0073\u0074\u0020\u306b\u63a5\u7d9a\u3067\u304d\u307e\u305b\u3093\u3067\u3057\u305f\u3002',
          details: error.message,
        );
      }
      throw _mapDioException(error);
    }
  }

  Future<void> _debugProbeUserById({
    required String accessToken,
    required String userId,
  }) async {
    final path = XApiConstants.userByIdPath.replaceFirst('{id}', userId);
    final requestHeaders = <String, String>{
      'Authorization': 'Bearer $accessToken',
    };
    final primaryUrl = '${XApiConstants.primaryV2BaseUrl}$path';
    final fallbackUrl = '${XApiConstants.fallbackV2BaseUrl}$path';

    debugPrint(
      '[xviewer][flutter] Debug probe started for /2/users/{id}: userId=$userId',
    );

    try {
      final response = await _sendWithDnsFallback(
        method: 'GET',
        primaryUrl: primaryUrl,
        fallbackUrl: fallbackUrl,
        requestHeaders: requestHeaders,
        send: (url) => _dio.get<Map<String, dynamic>>(
          url,
          options: Options(
            headers: requestHeaders,
            responseType: ResponseType.json,
          ),
        ),
      );
      _logResponse(
        method: 'GET',
        requestUrl: response.realUri.toString(),
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.data,
      );
    } on DioException catch (error) {
      _logError(
        method: 'GET',
        requestUrl: error.requestOptions.uri.toString(),
        error: error,
      );
    }
  }

  Future<Response<Map<String, dynamic>>> _sendWithDnsFallback({
    required String method,
    required String primaryUrl,
    required String fallbackUrl,
    required Map<String, String> requestHeaders,
    required Future<Response<Map<String, dynamic>>> Function(String url) send,
  }) async {
    _logRequest(
      method: method,
      requestUrl: primaryUrl,
      requestHeaders: requestHeaders,
      switchedToFallback: false,
    );

    try {
      return await send(primaryUrl);
    } on DioException catch (error) {
      final shouldFallback =
          primaryUrl.startsWith(XApiConstants.primaryBaseUrl) &&
          _isHostLookupFailure(error);
      _logNetworkException(
        requestUrl: primaryUrl,
        method: method,
        error: error,
        switchedToFallback: shouldFallback,
      );
      if (!shouldFallback) {
        rethrow;
      }

      _logRequest(
        method: method,
        requestUrl: fallbackUrl,
        requestHeaders: requestHeaders,
        switchedToFallback: true,
      );

      try {
        return await send(fallbackUrl);
      } on DioException catch (fallbackError) {
        _logNetworkException(
          requestUrl: fallbackUrl,
          method: method,
          error: fallbackError,
          switchedToFallback: true,
        );
        rethrow;
      }
    }
  }

  void _logRequest({
    required String method,
    required String requestUrl,
    required Map<String, String> requestHeaders,
    required bool switchedToFallback,
  }) {
    debugPrint(
      '[xviewer][flutter] X API request: method=$method url=$requestUrl headers=${_maskHeaders(requestHeaders)} switchedToFallback=$switchedToFallback',
    );
  }

  void _logResponse({
    required String method,
    required String requestUrl,
    required int? statusCode,
    required Headers headers,
    required Object? body,
  }) {
    debugPrint(
      '[xviewer][flutter] X API response: method=$method url=$requestUrl status=$statusCode headers=${headers.map} body=$body',
    );
    _logRateLimitHeaders(headers);
  }

  void _logError({
    required String method,
    required String requestUrl,
    required DioException error,
  }) {
    final response = error.response;
    final headers = response?.headers;
    debugPrint(
      '[xviewer][flutter] X API error: method=$method url=$requestUrl status=${response?.statusCode} headers=${headers?.map} body=${response?.data} message=${error.message}',
    );
    if (headers != null) {
      _logRateLimitHeaders(headers);
    }
    _logBillingHint(
      statusCode: response?.statusCode,
      body: response?.data,
    );
  }

  Map<String, String> _maskHeaders(Map<String, String> headers) {
    return headers.map((key, value) {
      if (key.toLowerCase() == 'authorization') {
        return MapEntry(key, 'Bearer ***');
      }
      return MapEntry(key, value);
    });
  }

  void _logRateLimitHeaders(Headers headers) {
    final limit = headers.value('x-rate-limit-limit');
    final remaining = headers.value('x-rate-limit-remaining');
    final reset = headers.value('x-rate-limit-reset');
    debugPrint(
      '[xviewer][flutter] x-rate-limit headers: limit=$limit remaining=$remaining reset=$reset',
    );
  }

  void _logBillingHint({
    required int? statusCode,
    required Object? body,
  }) {
    final lowerBody = body?.toString().toLowerCase() ?? '';
    if (statusCode == 403 ||
        statusCode == 429 ||
        statusCode == 503 ||
        lowerBody.contains('credit') ||
        lowerBody.contains('spending limit') ||
        lowerBody.contains('usage cap')) {
      debugPrint(
        '[xviewer][flutter] X API access may be affected by app package/billing/credit limits. Check Developer Console package, spending limit, and credit balance. status=$statusCode body=$body',
      );
    }
  }

  XApiException _mapDioException(DioException error) {
    final statusCode = error.response?.statusCode;
    final details = error.response?.data ?? error.message;

    switch (statusCode) {
      case 401:
        return XApiException.unauthorized(details);
      case 403:
        return XApiException.forbidden(details);
      case 429:
        return XApiException.rateLimited(details);
      case 503:
        return XApiException.serviceUnavailable(details);
      default:
        return XApiException.apiError(
          message: 'Failed to fetch the authenticated X user.',
          statusCode: statusCode,
          details: details,
        );
    }
  }

  void _logNetworkException({
    required String requestUrl,
    required String method,
    required DioException error,
    required bool switchedToFallback,
  }) {
    final exception = error.error;
    debugPrint(
      '[xviewer][flutter] Network exception: requestUrl=$requestUrl method=$method exceptionType=${exception?.runtimeType ?? error.runtimeType} exceptionMessage=${exception ?? error.message} switchedToFallback=$switchedToFallback',
    );
  }

  bool _isNetworkReachabilityIssue(DioException error) {
    return _isHostLookupFailure(error) ||
        error.error is SocketException ||
        '${error.error}'.contains('ClientException');
  }

  bool _isHostLookupFailure(DioException error) {
    final message = (error.message ?? '').toLowerCase();
    final inner = '${error.error}'.toLowerCase();
    return message.contains('failed host lookup') ||
        inner.contains('failed host lookup');
  }
}

class XTokenResponse {
  const XTokenResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
  });

  final String accessToken;
  final String? refreshToken;
  final int? expiresIn;
}
