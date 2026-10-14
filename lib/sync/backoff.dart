import 'dart:math' as math;

class Backoff {
  Backoff({
    this.base = const Duration(seconds: 1),
    this.cap = const Duration(seconds: 60),
    math.Random? random,
  }) : _random = random ?? math.Random();

  final Duration base;
  final Duration cap;
  final math.Random _random;

  Duration delayFor(int attempt) {
    final exponent = math.max(0, attempt - 1);
    final raw = base.inMilliseconds * math.pow(2, exponent).toDouble();
    final capped = math.min(raw, cap.inMilliseconds.toDouble());
    final half = capped / 2;
    return Duration(milliseconds: (half + _random.nextDouble() * half).round());
  }
}
