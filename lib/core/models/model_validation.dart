import '../errors/app_exception.dart';

String requireId(String value, String field) {
  if (value.trim().isEmpty) {
    throw ValidationException(
      code: 'invalid_$field',
      userMessage: 'البيانات المطلوبة غير مكتملة.',
    );
  }
  return value;
}

String requireText(String value, String field) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw ValidationException(
      code: 'invalid_$field',
      userMessage: 'البيانات المطلوبة غير مكتملة.',
    );
  }
  return trimmed;
}

DateTime requireChronologicalDates(DateTime createdAt, DateTime updatedAt) {
  if (updatedAt.isBefore(createdAt)) {
    throw const ValidationException(
      code: 'invalid_timestamps',
      userMessage: 'تواريخ السجل غير صالحة.',
    );
  }
  return updatedAt;
}
