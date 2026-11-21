// Serialize browser-history back presses, then leave the native page.
enum WebBackOutcome { history, leave, dropped }

/// Runs presses of back one at a time, each to the end, so a press never
/// sees the half-done step of the one before it (a page asked twice for the
/// same open dialog), and one press is one step.
class WebBackDispatcher {
  WebBackDispatcher({required this.canGoBack, required this.goBack, required this.leave, this.isActive});

  final Future<bool> Function() canGoBack;
  final Future<void> Function() goBack;
  final Future<void> Function() leave;

  /// False once the page is gone: presses still queued are dropped.
  final bool Function()? isActive;

  Future<void> _last = Future<void>.value();

  /// One press of back; completes with where it went once it got there.
  Future<WebBackOutcome> press() {
    final done = _last.then((_) => _step());
    _last = done.then<void>((_) {}, onError: (_) {});
    return done;
  }

  Future<WebBackOutcome> _step() async {
    if (!(isActive?.call() ?? true)) return WebBackOutcome.dropped;
    var history = false;
    try {
      history = await canGoBack();
    } catch (_) {}
    if (!(isActive?.call() ?? true)) return WebBackOutcome.dropped;
    if (history) {
      await goBack();
      return WebBackOutcome.history;
    }
    await leave();
    return WebBackOutcome.leave;
  }
}
