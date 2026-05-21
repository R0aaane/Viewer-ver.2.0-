class XTimelineIncludesMapper {
  const XTimelineIncludesMapper();

  Map<String, Map<String, dynamic>> usersById(
    Map<String, List<Map<String, dynamic>>> includes,
  ) {
    return _indexById(includes['users'], 'id');
  }

  Map<String, Map<String, dynamic>> mediaByKey(
    Map<String, List<Map<String, dynamic>>> includes,
  ) {
    return _indexById(includes['media'], 'media_key');
  }

  Map<String, Map<String, dynamic>> tweetsById(
    Map<String, List<Map<String, dynamic>>> includes,
  ) {
    return _indexById(includes['tweets'], 'id');
  }

  Map<String, Map<String, dynamic>> _indexById(
    List<Map<String, dynamic>>? values,
    String field,
  ) {
    final result = <String, Map<String, dynamic>>{};
    for (final value in values ?? const <Map<String, dynamic>>[]) {
      final key = value[field] as String?;
      if (key == null || key.isEmpty) {
        continue;
      }
      result[key] = value;
    }
    return result;
  }
}
