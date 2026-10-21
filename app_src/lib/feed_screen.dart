import 'dart:async';
import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'api.dart';
import 'post_card.dart';
import 'retry_button.dart';
import 'reply_browser.dart';
import 'thread_screen.dart';

class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});
  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> with WidgetsBindingObserver {
  static const _green = AppColors.green;
  final List<Post> _posts = [];
  final _scroll = ScrollController();
  bool _paging = false;    // loading OLDER pages (pagination) — must not block live refresh
  bool _polling = false;   // fetching NEWEST posts (the live refresh)
  bool _end = false;
  int _autoLoads = 0;      // caps the auto-load cascade so it can never run away
  final List<Post> _pending = [];   // fresh posts held back while you're scrolled down
  bool _showFab = false;            // scroll-to-top button appears when scrolled down
  String? _error;
  Timer? _live;
  // Bumped on every from-scratch reload (pull-to-refresh, filter toggle) so a
  // slower, older request can never overwrite newer results.
  int _gen = 0;

  // Live refresh: every 20s while the app is in the foreground, backing off
  // (up to 2 min) while the server is unreachable, paused in the background.
  static const _pollEvery = Duration(seconds: 20);
  static const _maxBackoff = Duration(minutes: 2);
  Duration _nextPoll = _pollEvery;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load(refresh: true);
    _scroll.addListener(_onScroll);
    // Live updates: pull any newer posts periodically and slot them in at the
    // top. Runs independently of pagination so it NEVER stalls.
    _schedulePoll();
    feedRefresh.addListener(_onFilterChanged);   // re-filter when the toggle flips
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 500) _load();
    final show = _scroll.offset > 600;
    if (show != _showFab && mounted) setState(() => _showFab = show);
    // Back near the top? merge any held-back posts in quietly.
    if (_scroll.offset < 200 && _pending.isNotEmpty && mounted) {
      setState(() {
        _posts.insertAll(0, _pending);
        _pending.clear();
      });
    }
  }

  void _schedulePoll() {
    _live?.cancel();
    if (!_foreground || !mounted) return;
    _live = Timer(_nextPoll, _tick);
  }

  Future<void> _tick() async {
    final ok = await _pollNew();
    if (!mounted) return;
    final doubled = _nextPoll * 2;
    _nextPoll = ok ? _pollEvery : (doubled > _maxBackoff ? _maxBackoff : doubled);
    _schedulePoll();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Reopening the app shows fresh posts immediately instead of waiting a tick.
      _foreground = true;
      _nextPoll = _pollEvery;
      _tick();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // Backgrounded: stop polling so the app doesn't burn battery and data.
      _foreground = false;
      _live?.cancel();
    }
  }

  void _onFilterChanged() {
    // The toggle changes the data SOURCE (all posts vs the full EE/Emily stream
    // from the server), so reload from scratch instead of client-filtering.
    _pending.clear();
    _load(refresh: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    feedRefresh.removeListener(_onFilterChanged);
    _live?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  // The server already returns the right set (all posts, or only EE/Emily),
  // so this is simply how many we're holding.
  int get _shownCount => _posts.length;

  /// When the EE/Emily filter hides most posts the visible list can be too short
  /// to scroll (which is what triggers pagination), so fetch a few more pages —
  /// but capped, so it can't loop through the whole archive and block refresh.
  void _maybeAutoLoad() {
    if (!mounted || _paging || _end) return;
    if (_shownCount < 8 && _autoLoads < 5) {
      _autoLoads++;
      _load();
    }
  }

  /// Newest post we hold (the feed is ordered by post time, not number, so
  /// Endchan's much smaller post numbers can't be compared with 4chan's).
  Post? get _newest => _pending.isNotEmpty
      ? _pending.first
      : (_posts.isNotEmpty ? _posts.first : null);

  /// Posts already on screen or held back, so a poll never adds one twice.
  Set<String> get _haveKeys =>
      {for (final p in _posts) p.key, for (final p in _pending) p.key};

  /// Fetch the newest posts and slot any we don't have yet in.
  /// Guarded ONLY by its own flag — pagination can never block it.
  /// Returns false if the server couldn't be reached (drives the back-off).
  Future<bool> _pollNew() async {
    if (_polling || !mounted) return true;
    if (_posts.isEmpty) {
      // Nothing loaded yet (e.g. the app opened while the server was briefly
      // unreachable) -- retry the initial load so the feed heals by itself.
      if (_paging) return true;
      await _load(refresh: true);
      return _error == null;
    }
    _polling = true;
    final gen = _gen;
    try {
      final latest =
          await Api.feed(limit: 30, keywordsOnly: Config.keywordsOnly);
      if (!mounted || gen != _gen) return true;   // list was reloaded meanwhile
      final newest = _newest;
      final have = _haveKeys;
      final fresh = latest
          .where((p) => !have.contains(p.key) && (newest == null || p.isNewerThan(newest)))
          .toList();
      if (fresh.isNotEmpty && mounted) {
        final atTop = !_scroll.hasClients || _scroll.offset < 300;
        setState(() {
          if (atTop) {
            _posts.insertAll(0, fresh);    // at the top: show right away
          } else {
            _pending.insertAll(0, fresh);  // scrolled down: hold back + show a pill
          }
        });
      }
      return true;
    } catch (_) {
      return false;   // transient poll error: keep what we have, back off
    } finally {
      _polling = false;
    }
  }

  void _showPending() {
    if (_pending.isNotEmpty && mounted) {
      setState(() {
        _posts.insertAll(0, _pending);
        _pending.clear();
      });
    }
    if (_scroll.hasClients) {
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  Future<void> _load({bool refresh = false}) async {
    // Paging is skipped while another load runs; a refresh always goes ahead
    // (e.g. the filter was flipped mid-page) and supersedes the older load.
    if (!mounted || (!refresh && (_paging || _end))) return;
    final gen = refresh ? ++_gen : _gen;
    _paging = true;
    setState(() {
      if (refresh) {
        _error = null;
        _end = false;
        _autoLoads = 0;
      }
    });
    try {
      final before = (refresh || _posts.isEmpty) ? null : _posts.last;
      final batch =
          await Api.feed(before: before, keywordsOnly: Config.keywordsOnly);
      if (!mounted || gen != _gen) return;   // superseded or screen gone
      setState(() {
        if (refresh) _posts.clear();
        final have = _haveKeys;
        _posts.addAll(batch.where((p) => !have.contains(p.key)));
        if (batch.isEmpty) _end = true;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted && gen == _gen) {
        setState(() => _paging = false);
        _maybeAutoLoad();
      }
    }
  }

  Widget _filterBar() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final unselBg = dark ? AppColors.cardDark : AppColors.segmentLight;
    final unselFg = Theme.of(context).colorScheme.onSurface.withOpacity(0.75);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<bool>(
          showSelectedIcon: false,
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            backgroundColor: WidgetStateProperty.resolveWith((s) =>
                s.contains(WidgetState.selected) ? _green : unselBg),
            foregroundColor: WidgetStateProperty.resolveWith((s) =>
                s.contains(WidgetState.selected) ? Colors.black : unselFg),
          ),
          segments: const [
            ButtonSegment(
                value: false,
                label: Text('All'),
                icon: Icon(Icons.forum_outlined, size: 16)),
            ButtonSegment(
                value: true,
                label: Text('EE / Emily'),
                icon: Icon(Icons.star_rounded, size: 16)),
          ],
          selected: {Config.keywordsOnly},
          onSelectionChanged: (s) => Config.setKeywordsOnly(s.first),
        ),
      ),
    );
  }

  Widget _newPostsPill() {
    final n = _pending.length;
    return Material(
      color: _green,
      elevation: 3,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _showPending,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.arrow_upward, size: 16, color: Colors.black),
            const SizedBox(width: 6),
            Text('$n new post${n == 1 ? '' : 's'}',
                style: const TextStyle(
                    color: Colors.black, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Feed'),
        actions: [
          IconButton(
            // Every post of the Endchan OTK general, not just EE/Emily matches.
            tooltip: 'Endchan thread',
            icon: const Icon(Icons.forum_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const ThreadScreen.endchan())),
          ),
          IconButton(
            tooltip: 'Browse 4chan',
            icon: const Icon(Icons.public),
            // Lives here rather than in the bottom bar: six destinations is too
            // many for a phone, and this is the least-used one.
            onPressed: () => Navigator.restorablePush(
                context, replyBrowserRoute, arguments: {
              'url': 'https://boards.4chan.org/b/',
              'title': 'Browse',
            }),
          ),
        ],
      ),
      floatingActionButton: _showFab
          ? FloatingActionButton.small(
              backgroundColor: _green,
              foregroundColor: Colors.black,
              onPressed: () => _scroll.animateTo(0,
                  duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
              child: const Icon(Icons.arrow_upward),
            )
          : null,
      body: Column(
        children: [
          _filterBar(),
          Expanded(
            child: Stack(children: [
              RefreshIndicator(
              onRefresh: () => _load(refresh: true),
              child: (_posts.isEmpty && _error != null)
                  ? ListView(children: [
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Could not load feed:\n$_error\n\n'
                              'Pull down or tap Retry to try again.',
                            ),
                            const SizedBox(height: 12),
                            RetryButton(onPressed: () => _load(refresh: true)),
                          ],
                        ),
                      ),
                    ])
                  : Builder(builder: (context) {
                      final shown = _posts;   // server already returns the right set
                      if (shown.isEmpty && !_paging) {
                        return ListView(children: [
                          Padding(
                            padding: const EdgeInsets.all(40),
                            child: Center(
                                child: Text(
                                    Config.keywordsOnly
                                        ? 'No EE/Emily posts yet.\nPull down to refresh.'
                                        : 'No posts yet.\nPull down to refresh.',
                                    textAlign: TextAlign.center)),
                          ),
                        ]);
                      }
                      return ListView.builder(
                        controller: _scroll,
                        itemCount: shown.length + 1,
                        itemBuilder: (c, i) {
                          if (i >= shown.length) {
                            return _paging
                                ? const Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Center(child: CircularProgressIndicator()))
                                : const SizedBox(height: 48);
                          }
                          return PostCard(shown[i]);
                        },
                      );
                    }),
              ),
              if (_pending.isNotEmpty)
                Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Center(child: _newPostsPill()),
                ),
            ]),
          ),
        ],
      ),
    );
  }
}
