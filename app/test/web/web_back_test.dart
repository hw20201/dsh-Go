import 'dart:async';

import 'package:dsh_app/ui/web/web_back.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('back consumes history before leaving', () async {
    var history = 1;
    var leaves = 0;
    final back = WebBackDispatcher(
      canGoBack: () async => history > 0,
      goBack: () async {
        history--;
      },
      leave: () async {
        leaves++;
      },
    );
    expect(await back.press(), WebBackOutcome.history);
    expect(history, 0);
    expect(await back.press(), WebBackOutcome.leave);
    expect(leaves, 1);
  });

  test('queued presses are serialized and dropped after disposal', () async {
    final hold = Completer<bool>();
    var calls = 0;
    var active = true;
    final back = WebBackDispatcher(
      canGoBack: () {
        calls++;
        return hold.future;
      },
      goBack: () async {},
      leave: () async {},
      isActive: () => active,
    );
    final first = back.press();
    final second = back.press();
    await pumpEventQueue();
    expect(calls, 1);
    active = false;
    hold.complete(true);
    expect(await first, WebBackOutcome.dropped);
    expect(await second, WebBackOutcome.dropped);
    expect(calls, 1);
  });

  test('an unavailable history channel still permits leaving', () async {
    var leaves = 0;
    final back = WebBackDispatcher(
      canGoBack: () async => throw StateError('renderer closed'),
      goBack: () async {},
      leave: () async {
        leaves++;
      },
    );
    expect(await back.press(), WebBackOutcome.leave);
    expect(leaves, 1);
  });
}
