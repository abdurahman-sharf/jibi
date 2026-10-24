enum RecentActivityKind { transaction, credential, document }

final class RecentActivityItem {
  const RecentActivityItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.occurredAt,
  });

  final String id;
  final RecentActivityKind kind;
  final String title;
  final String subtitle;
  final DateTime occurredAt;
}

List<RecentActivityItem> mergeRecentActivities(
  List<RecentActivityItem> items, {
  int limit = 5,
}) {
  final sorted = [...items]
    ..sort((left, right) {
      final time = right.occurredAt.compareTo(left.occurredAt);
      return time != 0 ? time : left.id.compareTo(right.id);
    });
  if (sorted.length <= limit) {
    return List<RecentActivityItem>.unmodifiable(sorted);
  }
  return List<RecentActivityItem>.unmodifiable(sorted.take(limit));
}
