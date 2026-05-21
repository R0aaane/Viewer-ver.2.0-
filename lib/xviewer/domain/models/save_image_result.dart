import 'save_failure_reason.dart';
import 'save_location_type.dart';
import 'saved_media_record.dart';

class SaveImageResult {
  const SaveImageResult({
    required this.record,
    required this.locationType,
    required this.wasDuplicate,
    required this.usedFallback,
    this.savedPath,
    this.galleryContentUri,
    this.failureReason,
    this.message,
  });

  final SavedMediaRecord record;
  final SaveLocationType locationType;
  final bool wasDuplicate;
  final bool usedFallback;
  final String? savedPath;
  final String? galleryContentUri;
  final SaveFailureReason? failureReason;
  final String? message;

  bool get isSuccess => failureReason == null;
}
