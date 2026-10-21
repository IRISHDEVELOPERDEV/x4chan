import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, HandshakeException;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Bumped whenever the feed filter changes so the Feed screen rebuilds.
final ValueNotifier<int> feedRefresh = ValueNotifier<int>(0);

/// Drives the app's light/dark/system theme (Settings updates this live).
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier<ThemeMode>(ThemeMode.dark);

/// This device's FCM token (set once push is initialised) so the Notifications
/// switch can register/unregister it for push.
String? fcmToken;

/// App-wide navigator so a tapped notification can open a post IN the app.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// App settings. The server URL and API token are fixed at build time (not
/// editable in the UI); everything else below is remembered per device.
class Config {
  // Server details are baked in (kept out of the Settings UI on purpose).
  // HTTPS via Caddy on the server (reverse-proxies to the API on :8787).
  static String baseUrl = 'https://x4chan.duckdns.org';
  // Injected at build time with --dart-define=MONITOR_API_TOKEN=... from the
  // repo secret, so the real key never sits in this public source tree.
  static String token =
      const String.fromEnvironment('MONITOR_API_TOKEN', defaultValue: '__API_TOKEN__');
  static bool keywordsOnly = false;   // feed filter: show only EE/Emily posts
  static bool notificationsEnabled = true;  // push EE/Emily alerts to this phone
  static ThemeMode themeMode = ThemeMode.dark;
  static List<String> savedReplies = [];  // your own canned replies (copy+paste)

  static ThemeMode _parseTheme(String? s) => s == 'light'
      ? ThemeMode.light
      : s == 'system'
          ? ThemeMode.system
          : ThemeMode.dark;
  static String _themeName(ThemeMode m) => m == ThemeMode.light
      ? 'light'
      : m == ThemeMode.system
          ? 'system'
          : 'dark';

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    // Older builds let you save a server URL and token in Settings. Those fields
    // are gone, so a stale saved token would silently override the current one
    // (and break the app the moment the old key is retired). Drop them.
    await p.remove('baseUrl');
    await p.remove('token');
    keywordsOnly = p.getBool('keywordsOnly') ?? false;
    notificationsEnabled = p.getBool('notificationsEnabled') ?? true;
    savedReplies = p.getStringList('savedReplies') ?? [];
    themeMode = _parseTheme(p.getString('themeMode'));
    themeNotifier.value = themeMode;
  }

  static Future<void> setNotificationsEnabled(bool v) async {
    notificationsEnabled = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('notificationsEnabled', v);
  }

  static Future<void> setKeywordsOnly(bool v) async {
    keywordsOnly = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('keywordsOnly', v);
    feedRefresh.value++;   // tell the Feed to re-filter
  }

  static Future<void> setSavedReplies(List<String> v) async {
    savedReplies = v;
    final p = await SharedPreferences.getInstance();
    await p.setStringList('savedReplies', v);
  }

  static Future<void> setThemeMode(ThemeMode m) async {
    themeMode = m;
    themeNotifier.value = m;   // update the app's theme live
    final p = await SharedPreferences.getInstance();
    await p.setString('themeMode', _themeName(m));
  }

  // External permanent /b/ archives (open in browser — they block in-app fetching).
  // Endchan posts have no thebarchive copy, so they link to Endchan itself.
  static String archiveThread(int thread, int no, {String board = 'b'}) {
    if (board == endchanBoard) return endchanThread(thread, no);
    final b = board.isEmpty ? 'b' : board;   // /trash/ is watched too now
    return thread > 0
        ? 'https://thebarchive.com/$b/thread/$thread/#$no'
        : 'https://thebarchive.com/$b/post/$no/';
  }
  /// The server tags posts from the Endchan /b/ OTK general with this board.
  static const endchanBoard = 'endchan';

  /// Endchan thread page, jumping to post [no] (same link as the website).
  static String endchanThread(int thread, int no) => thread > 0
      ? 'https://endchan.net/b/res/$thread.html#$no'
      : 'https://endchan.net/b/';

  /// Endchan thread page with post [no] quoted in its reply box (#q<no>).
  static String endchanReply(int thread, int no) => thread > 0
      ? 'https://endchan.net/b/res/$thread.html#q$no'
      : 'https://endchan.net/b/';

  static String thebarchiveSearch(String q) =>
      'https://thebarchive.com/b/search/text/${Uri.encodeComponent(q.trim())}/';
  static String archivedMoeSearch(String q) =>
      'https://archived.moe/b/search/text/${Uri.encodeComponent(q.trim())}/';
  static String randomArchiveSearch(String q) =>
      'https://www.google.com/search?q=${Uri.encodeComponent('site:randomarchive.com ${q.trim()}')}';
}

class Post {
  final int no;
  final String board;
  final int thread;
  final String name;
  final String now;
  final int ts;
  final String com;
  final String? ext;
  final String matched;
  final String url;
  final String? media;

  Post.fromJson(Map<String, dynamic> j)
      : no = asInt(j['no']),
        board = asStr(j['board']),
        thread = asInt(j['thread']),
        name = asStr(j['name'], 'Anonymous'),
        now = asStr(j['now']),
        ts = asInt(j['ts']),
        com = asStr(j['com']),
        ext = j['ext'] is String ? j['ext'] as String : null,
        matched = asStr(j['matched']),
        url = asStr(j['url']),
        media = j['media'] is String ? j['media'] as String : null;

  /// From the Endchan /b/ OTK general rather than 4chan.
  bool get isEndchan => board == Config.endchanBoard;

  /// Same post from another source (4chan and Endchan numbers can overlap).
  String get key => '$board/$no';

  /// True if this post is newer than [o] in the time-ordered feed (post time,
  /// ties by number) -- the same order the server's sort=time uses.
  bool isNewerThan(Post o) => ts != o.ts ? ts > o.ts : no > o.no;

  String get ago {
    if (ts == 0) return now;
    final d = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(ts * 1000));
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  /// 4chan serves a small thumbnail beside every file ("1234s.jpg"), which is
  /// what a grid should load rather than the full-size image or video.
  /// Routed through our own server's /thumb cache rather than 4chan directly:
  /// the gallery can have dozens of these on screen at once, and unlike every
  /// other image in the app they'd otherwise never touch our fast, warm,
  /// server-side cache -- each device would cold-connect to 4chan for every
  /// tile, every time, which is what made the gallery feel slow.
  /// Endchan's thumbnails sit beside the file as "/.media/t_<name>" (no
  /// extension) and go through the same /thumb proxy.
  String? get thumb {
    final m = media;
    if (m == null || m.isEmpty) return null;
    if (isEndchan) {
      final cut = m.lastIndexOf('/') + 1;
      final file = m.substring(cut);
      final d = file.lastIndexOf('.');
      final t = '${m.substring(0, cut)}t_${d > 0 ? file.substring(0, d) : file}';
      return '${Config.baseUrl}/thumb?u=${Uri.encodeQueryComponent(t)}';
    }
    final dot = m.lastIndexOf('.');
    final direct = dot <= 0 ? m : '${m.substring(0, dot)}s.jpg';
    return '${Config.baseUrl}/thumb?u=${Uri.encodeQueryComponent(direct)}';
  }

  String get _e => (ext ?? '').toLowerCase();
  bool get hasMedia => media != null && media!.isNotEmpty;
  bool get isVideo => _e == '.webm' || _e == '.mp4';
  bool get isImage => ['.jpg', '.jpeg', '.png', '.gif', '.webp'].contains(_e);
  bool get isKeyword => matched.isNotEmpty;
}

class TwitchMsg {
  final String text;
  final String name;
  final String ts;
  final String channel;
  /// Twitch's own emote tag: "id:start-end,start-end/id2:start-end".
  final String emotes;
  /// Chat badges as "set/version" pairs, e.g. "broadcaster/1,subscriber/12".
  final String badges;
  /// The chatter's Twitch colour, e.g. "#F272EC" (may be empty).
  final String color;
  TwitchMsg.fromJson(Map<String, dynamic> j)
      : text = asStr(j['text']),
        name = asStr(j['name']),
        ts = asStr(j['ts']),
        emotes = asStr(j['emotes']),
        badges = asStr(j['badges']),
        color = asStr(j['color']),
        channel = asStr(j['channel']);

}

class Stats {
  final int days, totalPosts, totalMentions;
  final List<({String date, int count})> perDay;
  final List<int> perHour;   // index 0-23, UTC
  final Map<String, int> perTerm;
  Stats.fromJson(Map<String, dynamic> j)
      : days = asInt(j['days']),
        totalPosts = asInt(j['total_posts']),
        totalMentions = asInt(j['total_mentions']),
        perDay = asList(j['per_day'])
            .map((e) => e is Map
                ? (date: asStr(e['date']), count: asInt(e['count']))
                : (date: '', count: 0))
            .toList(),
        perHour = asList(j['per_hour']).map(asInt).toList(),
        perTerm = asMap(j['per_term']).map((k, v) => MapEntry(k, asInt(v)));
}

class TwitchMonth {
  final int year, month;
  final String label;   // "2026-08"
  TwitchMonth.fromJson(Map<String, dynamic> j)
      : year = asInt(j['year']),
        month = asInt(j['month']),
        label = asStr(j['label']);
}

class TwitchChannelHit {
  final String channel;
  final int count;
  final String last;
  TwitchChannelHit.fromJson(Map<String, dynamic> j)
      : channel = asStr(j['channel']),
        count = asInt(j['count']),
        last = asStr(j['last']);
  String get lastDay => last.length >= 10 ? last.substring(0, 10) : last;
}

// ---------------------------------------------------------------------------
// Defensive JSON helpers: a malformed or unexpected server response should
// degrade to empty values rather than throw a type error deep inside a widget.
// ---------------------------------------------------------------------------
int asInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

String asStr(Object? v, [String fallback = '']) {
  if (v is String) return v;
  if (v == null) return fallback;
  return '$v';
}

List<dynamic> asList(Object? v) => v is List ? v : const [];

Map<String, dynamic> asMap(Object? v) => v is Map
    ? v.map((k, val) => MapEntry('$k', val))
    : <String, dynamic>{};

List<Map<String, dynamic>> _maps(Object? v) =>
    asList(v).whereType<Map>().map(asMap).toList();

// ---------------------------------------------------------------------------
// Typed API errors. toString() is the user-facing message, so screens that
// show '$e' get a clear explanation instead of a raw exception dump.
// ---------------------------------------------------------------------------
class ApiException implements Exception {
  final String message;
  final int? statusCode;
  const ApiException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

/// 401/403: the token baked into this build is no longer accepted.
class AuthException extends ApiException {
  const AuthException(int code)
      : super('Token rejected — app needs rebuilding with the current token',
            statusCode: code);
}

/// No connection, DNS failure, TLS failure or timeout.
class NetworkException extends ApiException {
  const NetworkException(super.message);
}

/// The server answered, but with an error status.
class ServerException extends ApiException {
  const ServerException(int code)
      : super('Server error (HTTP $code)', statusCode: code);
}

/// The server answered 200 but the body wasn't the JSON we expected.
class BadResponseException extends ApiException {
  const BadResponseException() : super('Unexpected response from the server');
}

class Api {
  static Map<String, String> get _h => {'Authorization': 'Bearer ${Config.token}'};
  static const _t = Duration(seconds: 20);
  static final http.Client _client = http.Client();

  /// The one place every request goes through: consistent timeout, typed
  /// errors, and defensive JSON decoding.
  static Future<Map<String, dynamic>> _send(
    String path, {
    Map<String, String>? query,
    Duration timeout = _t,
    Object? postJson,
  }) async {
    var uri = Uri.parse('${Config.baseUrl}$path');
    if (query != null) uri = uri.replace(queryParameters: query);
    final http.Response r;
    try {
      r = postJson == null
          ? await _client.get(uri, headers: _h).timeout(timeout)
          : await _client
              .post(uri,
                  headers: {..._h, 'Content-Type': 'application/json'},
                  body: jsonEncode(postJson))
              .timeout(timeout);
    } on TimeoutException {
      throw const NetworkException('Server took too long to respond');
    } on SocketException {
      throw const NetworkException("Can't reach the server — check your connection");
    } on HandshakeException {
      throw const NetworkException('Secure connection to the server failed');
    } on http.ClientException {
      throw const NetworkException("Can't reach the server — check your connection");
    }
    if (r.statusCode == 401 || r.statusCode == 403) throw AuthException(r.statusCode);
    if (r.statusCode != 200) throw ServerException(r.statusCode);
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) return asMap(j);
    } catch (_) {/* fall through */}
    throw const BadResponseException();
  }

  /// Like [_send], but optional extras (emotes, badges, years...) fall back to
  /// [fallback] on ordinary failures. A rejected token is still surfaced.
  static Future<T> _optional<T>(Future<T> Function() f, T fallback) async {
    try {
      return await f();
    } on AuthException {
      rethrow;
    } on ApiException {
      return fallback;
    }
  }

  static List<Post> _posts(Map<String, dynamic> j) =>
      _maps(j['posts']).map(Post.fromJson).toList();

  /// Paging cursor for the time-ordered feed: everything older than [last].
  /// before_ts/before_no is the sort=time cursor; the plain before=<no> rides
  /// along so paging still works if the server ever answers in number order.
  static Map<String, String> beforeParams(Post? last) => last == null
      ? const {}
      : {
          'before_ts': '${last.ts}',
          'before_no': '${last.no}',
          'before': '${last.no}',
        };

  /// Newest first, ordered by post time so 4chan and Endchan posts interleave.
  /// Pass the oldest post you already have as [before] to get the next page.
  static Future<List<Post>> feed(
      {Post? before,
      int limit = 50,
      bool keywordsOnly = false,
      bool mediaOnly = false}) async {
    final q = <String, String>{'limit': '$limit', 'sort': 'time', ...beforeParams(before)};
    if (keywordsOnly) q['keywords'] = '1';   // full EE/Emily stream, not client-filtered
    if (mediaOnly) q['media'] = '1';         // gallery: only posts with a file
    return _posts(await _send('/feed', query: q));
  }

  /// Every post we've archived from one thread, oldest first -- the full
  /// conversation around a given post, including context 4chan itself may have
  /// since deleted (served from our own DB, not fetched live from 4chan).
  static Future<List<Post>> thread(int postNo) async =>
      _posts(await _send('/thread', query: {'no': '$postNo'}));

  /// Every archived post of thread [threadId] (e.g. the Endchan OTK general),
  /// oldest first, keyword match or not.
  static Future<List<Post>> threadById(int threadId) async =>
      _posts(await _send('/thread', query: {'thread': '$threadId'}));

  /// The Endchan OTK thread currently being followed: the thread of the
  /// newest Endchan post the server has. Looks through the newest few pages of
  /// the time-ordered feed; returns null if no Endchan post turns up.
  static Future<int?> currentEndchanThread({int pages = 5}) async {
    Post? last;
    for (var i = 0; i < pages; i++) {
      final batch = await feed(before: last, limit: 200);
      for (final p in batch) {
        if (p.isEndchan && p.thread > 0) return p.thread;
      }
      if (batch.isEmpty) break;
      last = batch.last;
    }
    return null;
  }

  /// Mentions per day/hour and EE-vs-Emily split, over the last [days] days.
  static Future<Stats> stats({int days = 14}) async =>
      Stats.fromJson(await _send('/stats', query: {'days': '$days'}));

  /// Search OUR archive with filters (year, media-only, sort order).
  static Future<List<Post>> searchAdvanced({
    String q = '',
    int? year,
    bool mediaOnly = false,
    bool oldestFirst = false,
    int limit = 200,
  }) async {
    final params = <String, String>{
      'limit': '$limit',
      'order': oldestFirst ? 'asc' : 'desc',
      'sort': 'time',   // by post time, so Endchan results interleave with 4chan
    };
    if (q.isNotEmpty) params['q'] = q;
    if (year != null) params['year'] = '$year';
    if (mediaOnly) params['media'] = '1';
    return _posts(await _send('/search', query: params));
  }

  static Map<String, String> _stringMap(Object? v) => asMap(v).map(
      (k, val) => MapEntry(k, asStr(val)))..removeWhere((k, val) => val.isEmpty);

  /// Emote name -> image URL for a channel (7TV, BTTV and FFZ, global + channel).
  static Future<Map<String, String>> twitchEmotes(String channel) =>
      _optional(() async {
        final j = await _send('/twitchemotes',
            query: {'channel': channel.trim()}, timeout: const Duration(seconds: 40));
        return _stringMap(j['emotes']);
      }, <String, String>{});

  /// Chat badge images ("set/version" -> url) for a channel.
  static Future<Map<String, String>> twitchBadges(String channel) =>
      _optional(() async {
        final j = await _send('/twitchbadges',
            query: {'channel': channel.trim()}, timeout: const Duration(seconds: 40));
        return _stringMap(j['badges']);
      }, <String, String>{});

  /// Months that have logs for this user in this channel, newest first.
  static Future<List<TwitchMonth>> twitchMonths(String channel, String user) =>
      _optional(() async {
        final j = await _send('/twitchmonths',
            query: {'channel': channel.trim(), 'user': user.trim()},
            timeout: const Duration(seconds: 30));
        return _maps(j['months']).map(TwitchMonth.fromJson).toList();
      }, <TwitchMonth>[]);

  /// Which channels this user actually appears in (newest activity first).
  static Future<List<TwitchChannelHit>> twitchUserChannels(String user) async {
    final j = await _send('/twitchuserchannels',
        query: {'user': user.trim()}, timeout: const Duration(seconds: 60));
    return _maps(j['results']).map(TwitchChannelHit.fromJson).toList();
  }

  /// Twitch chat logs: what [user] said, optionally narrowed to one [channel].
  /// With no channel it searches the main OTK-adjacent channels.
  static Future<({List<TwitchMsg> messages, String? error})> twitchLogs(
      String user, {String channel = '', String period = ''}) async {
    final params = <String, String>{'user': user.trim(), 'limit': '500'};
    if (channel.trim().isNotEmpty) params['channel'] = channel.trim();
    if (period.contains('-')) {
      final p = period.split('-');
      params['year'] = p[0];
      params['month'] = p[1];
    }
    final j = await _send('/twitchlogs',
        query: params, timeout: const Duration(seconds: 40));
    final msgs = _maps(j['messages']).map(TwitchMsg.fromJson).toList();
    final err = j['error'];
    return (messages: msgs, error: err is String ? err : null);
  }

  /// Fetch a single archived post by number (for the notification deep-link).
  /// Returns null when the post isn't in the archive.
  static Future<Post?> post(int no) async {
    final Map<String, dynamic> j;
    try {
      j = await _send('/post', query: {'no': '$no'});
    } on ServerException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
    final p = j['post'];
    return p is Map ? Post.fromJson(asMap(p)) : null;
  }

  /// Years that actually have data in our archive (newest first).
  static Future<List<int>> years() => _optional(() async {
        final j = await _send('/years');
        return asList(j['years']).map(asInt).where((y) => y > 0).toList();
      }, <int>[]);

  static Future<Map<String, dynamic>> health() => _send('/health');

  /// Register this phone for push. Returns true if the server accepted it.
  static Future<bool> registerDevice(String fcmToken) =>
      _device({'token': fcmToken});

  /// Stop push to this phone. Returns true if the server accepted it.
  static Future<bool> unregisterDevice(String fcmToken) =>
      _device({'token': fcmToken, 'remove': true});

  static Future<bool> _device(Map<String, Object> body) async {
    try {
      await _send('/devices', postJson: body);
      return true;
    } on BadResponseException {
      return true;   // 200 with a non-JSON body still means it was accepted
    } catch (e) {
      debugPrint('device registration failed: $e');   // best effort
      return false;
    }
  }
}
