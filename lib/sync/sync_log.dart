class SyncLog {
  SyncLog({this.capacity = 500, this.sink, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final int capacity;
  final void Function(String line)? sink;
  final DateTime Function() _clock;
  final List<String> _lines = [];

  List<String> get lines => List.unmodifiable(_lines.reversed);

  void add(String tag, String message) {
    final time = _clock();
    String two(int n) => n.toString().padLeft(2, '0');
    final line =
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)} [$tag] $message';
    _lines.add(line);
    if (_lines.length > capacity) _lines.removeAt(0);
    sink?.call(line);
  }

  void clear() => _lines.clear();
}

String shortId(String id) => id.length > 8 ? id.substring(0, 8) : id;
