import 'package:flutter_test/flutter_test.dart';
import 'package:fourchan_monitor/api.dart';
import 'package:fourchan_monitor/reply_browser.dart';

void main() {
  group('defensive JSON', () {
    test('Post tolerates missing and wrongly typed fields', () {
      final p = Post.fromJson({'no': '123', 'ts': 1.5, 'name': null, 'media': 5});
      expect(p.no, 123);
      expect(p.ts, 1);
      expect(p.name, 'Anonymous');
      expect(p.media, isNull);
      expect(p.hasMedia, isFalse);
    });

    test('Stats tolerates junk', () {
      final s = Stats.fromJson({
        'per_day': [
          {'date': '2026-10-01', 'count': 3},
          'junk',
        ],
        'per_hour': ['2', null],
        'per_term': {'EE': 4, 'Emily': 'x'},
      });
      expect(s.perDay.length, 2);
      expect(s.perDay.first.count, 3);
      expect(s.perHour, [2, 0]);
      expect(s.perTerm, {'EE': 4, 'Emily': 0});
    });
  });

  group('Endchan posts', () {
    final ec = Post.fromJson({
      'no': 80863,
      'board': 'endchan',
      'thread': 75321,
      'ts': 1792610580,
      'ext': '.jpg',
      'url': 'https://endchan.net/b/res/75321.html#80863',
      'media': 'https://endchan.net/.media/eeb95db79133841e06d1fa9c9cf1f473-imagejpeg.jpg',
    });
    final fc = Post.fromJson({
      'no': 955000000,
      'board': 'b',
      'thread': 954990000,
      'ts': 1792610000,
      'ext': '.jpg',
      'media': 'https://i.4cdn.org/b/1792610000123.jpg',
    });

    test('recognised and keyed by board', () {
      expect(ec.isEndchan, isTrue);
      expect(fc.isEndchan, isFalse);
      expect(ec.key, 'endchan/80863');
    });

    test('thumbnail goes through /thumb with Endchan t_ name', () {
      const ecThumb =
          'https://endchan.net/.media/t_eeb95db79133841e06d1fa9c9cf1f473-imagejpeg';
      const fcThumb = 'https://i.4cdn.org/b/1792610000123s.jpg';
      expect(ec.thumb,
          '${Config.baseUrl}/thumb?u=${Uri.encodeQueryComponent(ecThumb)}');
      expect(fc.thumb,
          '${Config.baseUrl}/thumb?u=${Uri.encodeQueryComponent(fcThumb)}');
    });

    test('ordered by time, not post number', () {
      expect(ec.isNewerThan(fc), isTrue);   // later post, much smaller number
      expect(fc.isNewerThan(ec), isFalse);
    });

    test('links go to Endchan, 4chan links unchanged', () {
      expect(Config.archiveThread(75321, 80863, board: 'endchan'),
          'https://endchan.net/b/res/75321.html#80863');
      expect(Config.endchanReply(75321, 80863),
          'https://endchan.net/b/res/75321.html#q80863');
      expect(Config.archiveThread(954990000, 955000000, board: 'b'),
          'https://thebarchive.com/b/thread/954990000/#955000000');
    });

    test('time cursor for paging', () {
      expect(Api.beforeParams(null), isEmpty);
      expect(Api.beforeParams(ec), {
        'before_ts': '1792610580',
        'before_no': '80863',
        'before': '80863',
      });
    });
  });

  test('auth errors carry the rebuild message', () {
    expect(const AuthException(401).toString(), contains('Token rejected'));
  });

  group('reply browser allow-list', () {
    test('4chan domains allowed', () {
      for (final h in [
        'boards.4chan.org',
        'sys.4chan.org',
        '4chan.org',
        'www.4chan.org',
        'boards.4channel.org',
        'i.4cdn.org',
      ]) {
        expect(isAllowedBrowserHost(h), isTrue, reason: h);
      }
    });

    test('other domains blocked', () {
      for (final h in ['evil.com', '4chan.org.evil.com', 'not4chan.org', 'x4cdn.org']) {
        expect(isAllowedBrowserHost(h), isFalse, reason: h);
      }
    });

    test('text fill only on thread pages', () {
      expect(isFourchanThreadPage('https://boards.4chan.org/b/thread/123#p456'), isTrue);
      expect(isFourchanThreadPage('https://boards.4chan.org/b/'), isFalse);
      expect(isFourchanThreadPage('https://sys.4chan.org/auth'), isFalse);
      expect(isFourchanThreadPage('https://example.com/b/thread/1'), isFalse);
    });
  });
}
