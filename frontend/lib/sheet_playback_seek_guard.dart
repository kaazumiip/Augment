/// Reject delayed native-player positions while a sheet seek is settling.
class SheetPlaybackSeekGuard {
  Duration? _target;
  DateTime? _deadline;

  void seek(Duration target, DateTime now) {
    _target = target;
    _deadline = now.add(const Duration(seconds: 2));
  }

  void clear() {
    _target = null;
    _deadline = null;
  }

  bool accept(Duration position, DateTime now, {required bool dragging}) {
    if (dragging) return false;
    final target = _target;
    if (target == null) return true;
    final arrived = (position - target).inMilliseconds.abs() <= 250;
    if (!arrived && now.isBefore(_deadline!)) return false;
    clear();
    return true;
  }
}
