class XApiException implements Exception {
  const XApiException(
    this.message, {
    this.statusCode,
    this.code,
    this.details,
  });

  final String message;
  final int? statusCode;
  final String? code;
  final Object? details;

  factory XApiException.unauthorized([Object? details]) {
    return XApiException(
      'X API unauthorized. Access token may be expired.',
      statusCode: 401,
      code: 'unauthorized',
      details: details,
    );
  }

  factory XApiException.forbidden([Object? details]) {
    return XApiException(
      'X API forbidden. Check app plan and user scopes.',
      statusCode: 403,
      code: 'forbidden',
      details: details,
    );
  }

  factory XApiException.rateLimited([Object? details]) {
    return XApiException(
      'X API rate limit exceeded.',
      statusCode: 429,
      code: 'rate_limited',
      details: details,
    );
  }

  factory XApiException.serviceUnavailable([Object? details]) {
    return XApiException(
      'X API gateway reached, but upstream/service unavailable. billing/project/app status may be involved.',
      statusCode: 503,
      code: 'service_unavailable',
      details: details,
    );
  }

  factory XApiException.invalidResponse([Object? details]) {
    return XApiException(
      'X API returned an invalid response.',
      code: 'invalid_response',
      details: details,
    );
  }

  factory XApiException.apiError({
    required String message,
    int? statusCode,
    Object? details,
  }) {
    return XApiException(
      message,
      statusCode: statusCode,
      code: 'api_error',
      details: details,
    );
  }

  @override
  String toString() {
    return 'XApiException(message: $message, statusCode: $statusCode, code: $code, details: $details)';
  }
}
