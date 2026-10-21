import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'api.dart';
import 'post_card.dart';

/// The full conversation around one post -- every reply in that thread, in
/// order, built from our own archive rather than fetched live from 4chan (so
/// it still works once 4chan has deleted the thread). Opens scrolled to the
/// post you came from, which is outlined so it's easy to find again.
///
/// [ThreadScreen.endchan] shows the Endchan OTK general the server is
/// following instead: every post in it (not just EE/Emily matches), oldest
/// first, opened at the newest post. Pull down to refresh.
class ThreadScreen extends StatefulWidget {
  /// The post this was opened from; null for the Endchan thread view.
  final Post? origin;
  /// From the Archive, posts are usually already gone from 4chan, so every
  /// card in this thread should link out to thebarchive too, same as the
  /// screen this was opened from.
  final bool archiveMode;
  const ThreadScreen(Post this.origin, {this.archiveMode = false, super.key});
  const ThreadScreen.endchan({super.key})
      : origin = null,
        archiveMode = false;

  @override
  State<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends State<ThreadScreen> {
  final _originKey = GlobalKey();
  final _scroll = ScrollController();
  List<Post>? _posts;
  String? _error;
  int _originIndex = 0;
  bool _showFab = false;   // jump button, only for a long Endchan thread
  bool _atEnd = false;     // near the newest post -> the button points up

  bool get _endchanView => widget.origin == null;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!mounted || !_scroll.hasClients) return;
    final show = _scroll.position.maxScrollExtent > 1200;
    final atEnd = _scroll.offset > _scroll.position.maxScrollExtent - 600;
    if (show != _showFab || atEnd != _atEnd) {
      setState(() {
        _showFab = show;
        _atEnd = atEnd;
      });
    }
  }

  Future<void> _load() async {
    try {
      final origin = widget.origin;
      if (origin == null) {
        final tid = await Api.currentEndchanThread();
        if (!mounted) return;
        if (tid == null) {
          setState(() => _posts = const []);
          return;
        }
        final posts = await Api.threadById(tid);
        if (!mounted) return;
        final first = _posts == null;
        setState(() {
          _posts = posts;
          _error = null;
        });
        if (first) _scrollToEnd(jump: true);   // open at the newest post
        return;
      }
      // Endchan posts are looked up by their thread id: our number-based
      // lookup is 4chan's, and Endchan numbers live in a different range.
      final posts = origin.isEndchan && origin.thread > 0
          ? await Api.threadById(origin.thread)
          : await Api.thread(origin.no);
      if (!mounted) return;
      final list = posts.isNotEmpty ? posts : [origin];
      final idx = list.indexWhere((p) => p.key == origin.key);
      setState(() {
        _posts = list;
        _originIndex = idx < 0 ? 0 : idx;
      });
      _scrollToOrigin();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  // ListView.builder only builds items near the viewport, so for a post deep
  // in a long thread the GlobalKey isn't attached to anything yet and
  // ensureVisible alone would silently do nothing. Jump to a rough estimate
  // first (based on an average card height) so the target post actually gets
  // built, then ensureVisible corrects to its exact position.
  static const _estimatedItemHeight = 150.0;
  void _scrollToOrigin() {
    if (_originIndex <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_scroll.hasClients) return;
      final estimate = (_originIndex * _estimatedItemHeight)
          .clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.jumpTo(estimate);
      await Future.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      final ctx = _originKey.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(ctx,
            alignment: 0.15, duration: const Duration(milliseconds: 250));
      }
    });
  }

  /// Scroll to the newest (last) post. maxScrollExtent grows as the lazily
  /// built cards get measured, so repeat a few times until it settles.
  void _scrollToEnd({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      for (var i = 0; i < 6; i++) {
        if (!mounted || !_scroll.hasClients) return;
        final end = _scroll.position.maxScrollExtent;
        if (jump) {
          _scroll.jumpTo(end);
        } else {
          await _scroll.animateTo(end,
              duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
        }
        await Future.delayed(const Duration(milliseconds: 60));
        if (!mounted || !_scroll.hasClients) return;
        if (_scroll.position.maxScrollExtent == end) break;
      }
      _onScroll();
    });
  }

  String get _title {
    final posts = _posts;
    final origin = widget.origin;
    final board = origin == null || origin.isEndchan
        ? 'Endchan'
        : '/${origin.board.isEmpty ? 'b' : origin.board}/';
    if (posts == null) return _endchanView ? 'Endchan thread' : 'Thread';
    return '$board · ${posts.length} post${posts.length == 1 ? '' : 's'}';
  }

  Widget _list() {
    final posts = _posts!;
    if (posts.isEmpty) {
      return ListView(children: const [
        Padding(
          padding: EdgeInsets.all(40),
          child: Center(
              child: Text('No Endchan posts archived yet.\nPull down to refresh.',
                  textAlign: TextAlign.center)),
        ),
      ]);
    }
    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: posts.length,
      itemBuilder: (context, i) {
        final p = posts[i];
        final isOrigin = widget.origin != null && p.key == widget.origin!.key;
        final card = PostCard(p,
            archiveMode: widget.archiveMode, highlighted: isOrigin);
        return isOrigin ? KeyedSubtree(key: _originKey, child: card) : card;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = _error != null && _posts == null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Could not load the thread:\n$_error',
                  textAlign: TextAlign.center),
            ),
          )
        : _posts == null
            ? const Center(child: CircularProgressIndicator())
            : _endchanView
                ? RefreshIndicator(onRefresh: _load, child: _list())
                : _list();
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      // Long thread: one button to jump between the oldest and newest post.
      floatingActionButton: _endchanView && _showFab
          ? FloatingActionButton.small(
              backgroundColor: AppColors.green,
              foregroundColor: Colors.black,
              onPressed: () => _atEnd
                  ? _scroll.animateTo(0,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut)
                  : _scrollToEnd(),
              child: Icon(_atEnd ? Icons.arrow_upward : Icons.arrow_downward),
            )
          : null,
      body: body,
    );
  }
}
