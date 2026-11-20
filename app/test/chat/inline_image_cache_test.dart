import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

String _data(int count, int value) =>
    'data:image/png;base64,${base64Encode(Uint8List(count)..fillRange(0, count, value))}';

void main() {
  test('inline decoding accepts base64 and percent-escaped bytes', () {
    final cache = InlineDataImageCache(maxImageBytes: 3);
    expect(cache.read('data:image/png;base64,AAEC'), orderedEquals([0, 1, 2]));
    expect(cache.read('data:image/png,%00%01%02'), orderedEquals([0, 1, 2]));
    expect(cache.read('data:image/png;base64,%41%41%45%43'), orderedEquals([0, 1, 2]));
  });

  test('inline decoding rejects malformed, oversized decoded and oversized encoded input', () {
    final cache = InlineDataImageCache(maxImageBytes: 3);
    expect(cache.read('data:image/png;base64,%%%'), isNull);
    expect(cache.read(_data(4, 0)), isNull);
    // A long metadata header with a tiny payload must not reach UriData parsing.
    expect(cache.read('data:image/png;x=${'x' * 2048},a'), isNull);
    expect(cache.read(_data(3, 0)), hasLength(3));
  });

  test('small inline images share bytes and least recently read entries leave at 32', () {
    final cache = InlineDataImageCache();
    final first = _data(1, 0);
    final second = _data(1, 1);
    final a = cache.read(first);
    final b = cache.read(second);
    for (var i = 2; i < 32; i++) {
      cache.read(_data(1, i));
    }
    expect(cache.read(first), same(a));
    cache.read(_data(1, 32));
    expect(cache.read(first), same(a));
    expect(cache.read(second), isNot(same(b)));
  });

  test('URL storage participates in the total inline cache byte budget', () {
    final cache = InlineDataImageCache();
    // Each 60 KiB payload has a 160 KiB UTF-16 URL: nine fit in 2 MiB,
    // whereas a cache accounting for payload alone would hold all ten.
    final first = _data(60 * 1024, 0);
    final original = cache.read(first);
    for (var i = 1; i < 10; i++) {
      cache.read(_data(60 * 1024, i));
    }
    expect(cache.read(first), isNot(same(original)));
  });

  test('a large allowed inline image is decoded without being held globally', () {
    final cache = InlineDataImageCache();
    final url = _data(256 * 1024, 0);
    final bytes = cache.read(url);
    expect(bytes, hasLength(256 * 1024));
    expect(cache.read(url), isNot(same(bytes)));
  });

  testWidgets('a mounted large inline image memoizes bytes and has no global size probe', (tester) async {
    // Valid 1x1 PNG plus padding: bigger than the global entry limit, still a
    // valid bitmap. Rebuilding this tile must not decode its data URI again.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );
    final bytes = Uint8List(256 * 1024)..setRange(0, png.length, png);
    final url = 'data:image/png;base64,${base64Encode(bytes)}';
    final rebuild = ValueNotifier(0);
    addTearDown(rebuild.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: rebuild,
            builder: (_, value, _) => MarkdownImage(url: url, width: 10 + value.toDouble()),
          ),
        ),
        overrides: [activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null))],
      ),
    );
    Uint8List drawnBytes() {
      final provider = tester.widget<Image>(find.byType(Image)).image as ResizeImage;
      return (provider.imageProvider as MemoryImage).bytes;
    }

    final original = drawnBytes();
    expect(original, orderedEquals(bytes));
    expect(find.byWidgetPredicate((widget) => widget.runtimeType.toString() == '_SizeProbe'), findsNothing);
    rebuild.value++;
    await tester.pump();
    expect(drawnBytes(), same(original));
    expect(tester.takeException(), isNull);
  });
}
