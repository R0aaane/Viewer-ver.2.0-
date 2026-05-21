import 'package:intl/intl.dart';

class DateFormatter {
  static String shortDateTime(DateTime value) {
    return DateFormat('yyyy/MM/dd HH:mm').format(value.toLocal());
  }
}
