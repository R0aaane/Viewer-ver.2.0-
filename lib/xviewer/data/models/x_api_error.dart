class XApiError {
  const XApiError({
    required this.title,
    required this.detail,
    required this.type,
    required this.status,
  });

  final String title;
  final String detail;
  final String type;
  final int? status;

  factory XApiError.fromJson(Map<String, dynamic> json) {
    return XApiError(
      title: json['title'] as String? ?? 'Unknown error',
      detail: json['detail'] as String? ?? '',
      type: json['type'] as String? ?? '',
      status: int.tryParse('${json['status'] ?? ''}'),
    );
  }
}
