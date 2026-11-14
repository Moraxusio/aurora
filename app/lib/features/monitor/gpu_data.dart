String gpuIdentity(Map gpu) {
  for (final field in ['uuid', 'bus_id']) {
    final value = gpu[field];
    if (value is String && value.isNotEmpty) return value;
  }
  return '${gpu['index']}';
}

class GpuPoint {
  final double? util, memory;
  const GpuPoint(this.util, this.memory);
  factory GpuPoint.fromMap(Map gpu) {
    double? number(Object? value) =>
        value is num && value.isFinite ? value.toDouble() : null;
    final total = number(gpu['mem_total']), used = number(gpu['mem_used']);
    return GpuPoint(
      number(gpu['util']),
      total == null || total <= 0 || used == null ? null : 100 * used / total,
    );
  }
}
