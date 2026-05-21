import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/constants/x_api_constants.dart';
import '../../core/errors/x_api_exception.dart';
import '../../data/models/x_api_timeline_response.dart';
import '../../services/x_timeline_request_builder.dart';

class XApiClient {
  XApiClient({
    required Dio dio,
    required XTimelineRequestBuilder requestBuilder,
  }) : _dio = dio,
       _requestBuilder = requestBuilder;

  final Dio _dio;
  final XTimelineRequestBuilder _requestBuilder;

  Future<XApiTimelineResponse> fetchHomeTimeline({
    required String accessToken,
    required String userId,
    required TimelineRequestType requestType,
    required String requestReason,
    String? sinceId,
    String? paginationToken,
  }) async {
    final path = XApiConstants.reverseChronologicalTimelinePath.replaceFirst(
      '{id}',
      userId,
    );
    return _fetchTimelineLikeResponse(
      accessToken: accessToken,
      path: path,
      requestReason: requestReason,
      queryParameters: _requestBuilder.buildHomeTimeline(
        type: requestType,
        sinceId: sinceId,
        paginationToken: paginationToken,
      ),
    );
  }

  Future<XApiTimelineResponse> fetchUserTweets({
    required String accessToken,
    required String userId,
    required TimelineRequestType requestType,
    required String requestReason,
    String? sinceId,
    String? paginationToken,
  }) async {
    final path = XApiConstants.userTweetsPath.replaceFirst('{id}', userId);
    return _fetchTimelineLikeResponse(
      accessToken: accessToken,
      path: path,
      requestReason: requestReason,
      queryParameters: _requestBuilder.buildUserTweets(
        type: requestType,
        sinceId: sinceId,
        paginationToken: paginationToken,
      ),
    );
  }

  Future<XApiTimelineResponse> _fetchTimelineLikeResponse({
    required String accessToken,
    required String path,
    required String requestReason,
    required Map<String, dynamic> queryParameters,
  }) async {
    final primaryUrl = '${XApiConstants.primaryV2BaseUrl}$path';
    final fallbackUrl = '${XApiConstants.fallbackV2BaseUrl}$path';
    final requestHeaders = <String, String>{
      'Authorization': 'Bearer $accessToken',
    };

    try {
      final response = await _sendWithDnsFallback(
        method: 'GET',
        primaryUrl: primaryUrl,
        fallbackUrl: fallbackUrl,
        requestHeaders: requestHeaders,
        requestReason: requestReason,
        send: (url) => _dio.get<Map<String, dynamic>>(
          url,
          queryParameters: queryParameters,
          options: Options(headers: requestHeaders),
        ),
      );
      _logResponse(
        method: 'GET',
        requestUrl: response.realUri.toString(),
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.data,
        requestReason: requestReason,
      );

      final body = response.data;
      if (body == null) {
        throw XApiException.invalidResponse('Response body was null');
      }

      final timelineResponse = XApiTimelineResponse.fromJson(body);
      if (timelineResponse.errors.isNotEmpty && timelineResponse.data.isEmpty) {
        final firstError = timelineResponse.errors.first;
        _logBillingHint(
          statusCode: firstError.status ?? response.statusCode,
          body: body,
        );
        if ((firstError.status ?? response.statusCode) == 503) {
          throw XApiException.serviceUnavailable(body);
        }
        throw XApiException.apiError(
          message: firstError.detail.isEmpty
              ? firstError.title
              : firstError.detail,
          statusCode: firstError.status ?? response.statusCode,
          details: body,
        );
      }

      return timelineResponse;
    } on DioException catch (error) {
      _logError(
        method: 'GET',
        requestUrl: error.requestOptions.uri.toString(),
        error: error,
        requestReason: requestReason,
      );
      if (_isNetworkReachabilityIssue(error)) {
        throw XApiException.apiError(
          message:
              '\u0044\u004e\u0053\u002f\u30cd\u30c3\u30c8\u30ef\u30fc\u30af\u5230\u9054\u6027\u306e\u554f\u984c\u306e\u53ef\u80fd\u6027\u304c\u3042\u308a\u307e\u3059\u3002\u0058\u0020\u0041\u0050\u0049\u0020\u0068\u006f\u0073\u0074\u0020\u306b\u63a5\u7d9a\u3067\u304d\u307e\u305b\u3093\u3067\u3057\u305f\u3002',
          details: error.message,
        );
      }
      throw _mapDioException(error);
    }
  }

  Future<Response<Map<String, dynamic>>> _sendWithDnsFallback({
    required String method,
    required String primaryUrl,
    required String fallbackUrl,
    required Map<String, String> requestHeaders,
    required String requestReason,
    required Future<Response<Map<String, dynamic>>> Function(String url) send,
  }) async {
    _logRequest(
      method: method,
      requestUrl: primaryUrl,
      requestHeaders: requestHeaders,
      switchedToFallback: false,
      requestReason: requestReason,
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
        requestReason: requestReason,
      );
      if (!shouldFallback) {
        rethrow;
      }

      _logRequest(
        method: method,
        requestUrl: fallbackUrl,
        requestHeaders: requestHeaders,
        switchedToFallback: true,
        requestReason: requestReason,
      );

      try {
        return await send(fallbackUrl);
      } on DioException catch (fallbackError) {
        _logNetworkException(
          requestUrl: fallbackUrl,
          method: method,
          error: fallbackError,
          switchedToFallback: true,
          requestReason: requestReason,
        );
        rethrow;
      }
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
          message: 'Failed to fetch X timeline.',
          statusCode: statusCode,
          details: details,
        );
    }
  }

  void _logRequest({
    required String method,
    required String requestUrl,
    required Map<String, String> requestHeaders,
    required bool switchedToFallback,
    required String requestReason,
  }) {
    debugPrint(
      '[xviewer][flutter] X API request: reason=$requestReason method=$method url=$requestUrl headers=${_maskHeaders(requestHeaders)} switchedToFallback=$switchedToFallback',
    );
  }

  void _logResponse({
    required String method,
    required String requestUrl,
    required int? statusCode,
    required Headers headers,
    required Object? body,
    required String requestReason,
  }) {
    debugPrint(
      '[xviewer][flutter] X API response: reason=$requestReason method=$method url=$requestUrl status=$statusCode headers=${headers.map} body=$body',
    );
    _logRateLimitHeaders(headers);
  }

  void _logError({
    required String method,
    required String requestUrl,
    required DioException error,
    required String requestReason,
  }) {
    final response = error.response;
    final headers = response?.headers;
    debugPrint(
      '[xviewer][flutter] X API error: reason=$requestReason method=$method url=$requestUrl status=${response?.statusCode} headers=${headers?.map} body=${response?.data} message=${error.message}',
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
        '[xviewer][flutter] Developer Console check hint: verify app package, billing status, spending limit, and credit balance. status=$statusCode body=$body',
      );
    }
  }

  void _logNetworkException({
    required String requestUrl,
    required String method,
    required DioException error,
    required bool switchedToFallback,
    required String requestReason,
  }) {
    final exception = error.error;
    debugPrint(
      '[xviewer][flutter] Network exception: reason=$requestReason requestUrl=$requestUrl method=$method exceptionType=${exception?.runtimeType ?? error.runtimeType} exceptionMessage=${exception ?? error.message} switchedToFallback=$switchedToFallback',
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
