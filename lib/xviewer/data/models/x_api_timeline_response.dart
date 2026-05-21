import '../../core/errors/x_api_exception.dart';
import 'x_api_error.dart';

class XApiTimelineResponse {
  const XApiTimelineResponse({
    required this.data,
    required this.includes,
    required this.meta,
    required this.errors,
  });

  final List<Map<String, dynamic>> data;
  final Map<String, List<Map<String, dynamic>>> includes;
  final Map<String, dynamic> meta;
  final List<XApiError> errors;

  String? get newestId => meta['newest_id'] as String?;
  String? get nextToken => meta['next_token'] as String?;
  String? get previousToken => meta['previous_token'] as String?;
  int get resultCount => meta['result_count'] as int? ?? data.length;

  factory XApiTimelineResponse.fromJson(Map<String, dynamic> json) {
    final rawData = json['data'];
    if (rawData != null && rawData is! List) {
      throw XApiException.invalidResponse('Expected data to be a list');
    }

    final rawIncludes = json['includes'];
    final includesMap = <String, List<Map<String, dynamic>>>{};
    if (rawIncludes is Map) {
      for (final entry in rawIncludes.entries) {
        final value = entry.value;
        if (value is List) {
          includesMap['${entry.key}'] = value
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList(growable: false);
        }
      }
    }

    return XApiTimelineResponse(
      data: (rawData as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false),
      includes: includesMap,
      meta: json['meta'] is Map
          ? Map<String, dynamic>.from(json['meta'] as Map)
          : const {},
      errors: (json['errors'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .map(XApiError.fromJson)
          .toList(growable: false),
    );
  }
}
