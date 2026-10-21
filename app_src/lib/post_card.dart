import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'api.dart';
import 'reply_browser.dart';
import 'thread_screen.dart';

class PostCard extends StatelessWidget {
  final Post post;
  /// In the Archive the posts are usually long gone from 4chan, so thebarchive
  /// becomes the main button and the live thread the secondary one.
  final bool archiveMode;
  /// True for the one post a ThreadScreen was opened from -- gets a distinct
  /// tint (blue, since green already means "keyword match") so it's easy to
  /// spot again while scrolling the surrounding conversation.
  final bool highlighted;
  const PostCard(this.post,
      {this.archiveMode = false, this.highlighted = false, super.key});

  static const _green = AppColors.green;
  static const _quoteColor = AppColors.quote;
  // Highlights >>post quote-links and the watched names so gossip is scannable.
  static final RegExp _bodyPattern =
      RegExp(r'>>\d+|\b(?:EE|Emily)\b', caseSensitive: false);

  List<TextSpan> _bodySpans(String text) {
    final spans = <TextSpan>[];
    int last = 0;
    for (final m in _bodyPattern.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      final tok = m.group(0)!;
      spans.add(tok.startsWith('>>')
          ? TextSpan(text: tok, style: const TextStyle(color: _quoteColor))
          : TextSpan(
              text: tok,
              style: const TextStyle(color: _green, fontWeight: FontWeight.bold)));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return spans;
  }

  /// The post on its live site (4chan or Endchan), or our own permanent copy.
  String get _liveUrl => post.url.isNotEmpty
      ? post.url
      : post.isEndchan
          ? Config.endchanThread(post.thread, post.no)
          : '${Config.baseUrl}/p/${post.no}';

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: post.com));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Post copied'), duration: Duration(milliseconds: 900)));
  }

  /// Opens the live thread's reply box quoting this post. If [text] is given it
  /// rides along in the URL fragment, and the X4chan userscript (if installed in
  /// your browser) drops it straight into the box. Without the userscript the
  /// text is still on your clipboard to paste.
  void _openReply(BuildContext context, {String? text}) {
    if (post.isEndchan) {
      // The in-app browser only goes to 4chan, so Endchan's own reply box
      // (#q<no> quotes the post) opens in the phone's browser. Saved text is
      // already on the clipboard to paste.
      if (text != null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Reply copied — paste it into Endchan\'s reply box'),
            duration: Duration(seconds: 2)));
      }
      launchUrl(Uri.parse(Config.endchanReply(post.thread, post.no)),
          mode: LaunchMode.externalApplication);
      return;
    }
    // Opens 4chan's real reply box inside the app, with [text] already typed in.
    // You press Post yourself — the app never submits for you.
    final board = post.board.isEmpty ? 'b' : post.board;
    // #p<no> jumps to the post itself; the browser then puts >>no (and your
    // saved text) into the reply box and scrolls there.
    final url = 'https://boards.4chan.org/$board/thread/${post.thread}#p${post.no}';
    Navigator.restorablePush(context, replyBrowserRoute, arguments: {
      'url': url,
      'quoteNo': post.no,
      'prefill': text,
      'title': 'Reply',
    });
  }

  /// Long-press Reply: pick one of your saved replies. It's copied to the
  /// clipboard and the thread's reply box opens quoting this post -- you paste
  /// and hit send yourself (the app never posts for you).
  void _savedRepliesSheet(BuildContext context) {
    final items = Config.savedReplies;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: items.isEmpty
            ? const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 28),
                child: Text(
                  'No saved replies yet. Add some in Settings, then '
                  'long-press Reply to copy one and jump straight to the reply box.',
                  textAlign: TextAlign.center,
                ),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final r in items)
                    ListTile(
                      leading: const Icon(Icons.bolt, color: _green, size: 20),
                      title: Text(r, maxLines: 3, overflow: TextOverflow.ellipsis),
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: r));  // fallback
                        Navigator.pop(context);
                        _openReply(context, text: r);
                      },
                    ),
                ],
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = AppColors.card(dark);
    final muted = cs.onSurface.withOpacity(0.55);
    return GestureDetector(
      onLongPress: () => _copy(context),   // long-press anywhere to copy the post
      child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: highlighted ? _quoteColor.withOpacity(dark ? 0.16 : 0.10) : cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: highlighted
              ? _quoteColor.withOpacity(0.6)
              : (post.isKeyword ? _green.withOpacity(0.55) : cs.outline.withOpacity(0.18)),
          width: highlighted || post.isKeyword ? 1.4 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: _green.withOpacity(0.18),
              child: const Text('A',
                  style: TextStyle(color: _green, fontWeight: FontWeight.bold, fontSize: 13)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(post.name,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  Text('${post.ago} · No.${post.no}${post.isEndchan ? ' · Endchan' : ''}',
                      style: TextStyle(fontSize: 11, color: muted)),
                ],
              ),
            ),
            if (post.isKeyword)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                    color: _green, borderRadius: BorderRadius.circular(20)),
                child: Text(post.matched,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black)),
              ),
          ]),
          if (post.hasMedia && post.isImage) ...[
            const SizedBox(height: 10),
            GestureDetector(
              // Tap to open fullscreen with pinch-to-zoom.
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  fullscreenDialog: true,
                  builder: (_) => _FullscreenImage(post.media!))),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    CachedNetworkImage(
                      imageUrl: post.media!,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      placeholder: (c, u) => Container(
                          height: 160,
                          color: Colors.black26,
                          child: const Center(child: CircularProgressIndicator())),
                      errorWidget: (c, u, e) => Container(
                          height: 80,
                          color: Colors.black26,
                          child: const Center(child: Icon(Icons.broken_image))),
                    ),
                    Container(
                      margin: const EdgeInsets.all(6),
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6)),
                      child: const Icon(Icons.zoom_out_map,
                          size: 16, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (post.hasMedia && post.isVideo) ...[
            const SizedBox(height: 10),
            VideoTile(post.media!),
          ],
          if (post.com.isNotEmpty) ...[
            const SizedBox(height: 10),
            SelectableText.rich(
              TextSpan(
                style: TextStyle(fontSize: 14.5, height: 1.4, color: cs.onSurface),
                children: _bodySpans(post.com),
              ),
            ),
          ],
          Row(
            children: [
              // Icon-only utilities (long-press the card also copies).
              IconButton(
                tooltip: 'Copy text',
                visualDensity: VisualDensity.compact,
                color: muted,
                iconSize: 18,
                onPressed: () => _copy(context),
                icon: const Icon(Icons.copy),
              ),
              if (!highlighted)
                IconButton(
                  // Full conversation around this post, in-app -- built from our
                  // own archive, so it works even if 4chan has since deleted it.
                  tooltip: 'View thread',
                  visualDensity: VisualDensity.compact,
                  color: muted,
                  iconSize: 18,
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ThreadScreen(post, archiveMode: archiveMode))),
                  icon: const Icon(Icons.forum_outlined),
                ),
              if (!archiveMode)
                IconButton(
                  // Full permanent thread on thebarchive.com (survives deletion).
                  tooltip: post.isEndchan ? 'Endchan thread' : 'Permanent archive',
                  visualDensity: VisualDensity.compact,
                  color: muted,
                  iconSize: 18,
                  onPressed: () => launchUrl(
                      Uri.parse(Config.archiveThread(post.thread, post.no, board: post.board)),
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.archive_outlined),
                ),
              if (archiveMode)
                IconButton(
                  // In the Archive the post is usually gone from 4chan, so the
                  // live thread becomes the secondary link instead.
                  tooltip: post.isEndchan ? 'Live Endchan thread' : 'Live 4chan thread',
                  visualDensity: VisualDensity.compact,
                  color: muted,
                  iconSize: 18,
                  onPressed: () => launchUrl(
                      Uri.parse(_liveUrl),
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.open_in_new),
                ),
              const Spacer(),
              // "Reply" opens the live thread with 4chan's quick-reply box already
              // quoting this post -- you post it yourself, in your own browser
              // session. The app never posts for you (captcha + 4chan's rules).
              Flexible(
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                      foregroundColor: muted,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 34)),
                  onPressed: () => _openReply(context),
                  onLongPress: () => _savedRepliesSheet(context),
                  icon: const Icon(Icons.reply, size: 16),
                  label: const Text('Reply', overflow: TextOverflow.ellipsis),
                ),
              ),
              // Main button: the live 4chan thread normally, but in the Archive
              // the post is usually deleted, so it opens thebarchive instead.
              Flexible(
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                      foregroundColor: _green,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 34)),
                  onPressed: () => launchUrl(
                      Uri.parse(archiveMode
                          ? Config.archiveThread(post.thread, post.no, board: post.board)
                          : _liveUrl),
                      mode: LaunchMode.externalApplication),
                  icon: Icon(
                      archiveMode ? Icons.archive_outlined : Icons.open_in_new,
                      size: 15),
                  label: Text(archiveMode ? 'Archive' : 'Open',
                      overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }
}

/// Fullscreen, pinch-to-zoom image view (tap image in a card to open).
class _FullscreenImage extends StatelessWidget {
  final String url;
  const _FullscreenImage(this.url);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.8,
          maxScale: 5,
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.contain,
            placeholder: (c, u) =>
                const Center(child: CircularProgressIndicator()),
            errorWidget: (c, u, e) =>
                const Icon(Icons.broken_image, color: Colors.white54, size: 64),
          ),
        ),
      ),
    );
  }
}

/// Tap-to-play video (ExoPlayer supports .webm natively on Android).
class VideoTile extends StatefulWidget {
  final String url;
  const VideoTile(this.url, {super.key});
  @override
  State<VideoTile> createState() => _VideoTileState();
}

class _VideoTileState extends State<VideoTile> {
  VideoPlayerController? _c;
  bool _loading = false;

  Future<void> _play() async {
    setState(() => _loading = true);
    final url = widget.url;
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    var adopted = false;
    try {
      await c.initialize();
      await c.setLooping(true);
      // The card may have scrolled away (or been reused for another post)
      // while the video was loading -- don't adopt a controller nobody shows.
      if (!mounted || widget.url != url) return;
      await c.play();
      if (!mounted || widget.url != url) return;
      final old = _c;
      setState(() => _c = c);
      adopted = true;
      old?.dispose();
    } catch (_) {
      // leave placeholder on failure
    } finally {
      if (!adopted) c.dispose();   // never leak an orphaned controller
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void didUpdateWidget(VideoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // List recycling can hand this state a different post: drop the old video.
    if (oldWidget.url != widget.url) {
      _c?.dispose();
      _c = null;
      _loading = false;
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    _c = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c != null && c.value.isInitialized) {
      return GestureDetector(
        onTap: () => setState(() => c.value.isPlaying ? c.pause() : c.play()),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)),
        ),
      );
    }
    return GestureDetector(
      onTap: _loading ? null : _play,
      child: Container(
        height: 160,
        decoration: BoxDecoration(
            color: Colors.black26, borderRadius: BorderRadius.circular(6)),
        child: Center(
          child: _loading
              ? const CircularProgressIndicator()
              : const Icon(Icons.play_circle_fill, size: 56),
        ),
      ),
    );
  }
}
