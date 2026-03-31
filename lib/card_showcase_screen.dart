import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

import 'pokemon_models.dart';
import 'collection_store.dart';
import 'pokemon_card_showcase.dart';

// If you still need to open the old detail screen anywhere, keep this import.
// But we are NOT going to show "Open Card Details" on the owned showcase anymore.

enum EbayMode { raw, graded }

enum EbayListingState { active, sold }

class EbayPreviewItem {
  final EbayListing listing;
  final EbayListingState state;

  const EbayPreviewItem({required this.listing, required this.state});
}

final Map<String, List<EbayPreviewItem>> _ebayPreviewCache =
    <String, List<EbayPreviewItem>>{};
final Map<String, Future<List<EbayPreviewItem>>> _ebayPreviewInFlight =
    <String, Future<List<EbayPreviewItem>>>{};

String _ebayPreviewCacheKey({
  required String query,
  required int maxListings,
}) => '$maxListings::$query';

/// ---------------------------- OWNED SHOWCASE ----------------------------
/// This is the "dark stage + spotlight + floating spinning card + tap-to-flip" screen.
class OwnedCardShowcaseScreen extends StatefulWidget {
  final PokemonCardResult card;

  const OwnedCardShowcaseScreen({super.key, required this.card});

  @override
  State<OwnedCardShowcaseScreen> createState() =>
      _OwnedCardShowcaseScreenState();
}

class _OwnedCardShowcaseScreenState extends State<OwnedCardShowcaseScreen>
    with TickerProviderStateMixin {
  late final AnimationController _idle = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  )..repeat();

  late final AnimationController _flip = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  bool _showBack = false;
  EbayMode _ebayMode = EbayMode.raw;

  @override
  void dispose() {
    _idle.dispose();
    _flip.dispose();
    super.dispose();
  }

  Future<void> _open(Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open link')));
    }
  }

  String _fmtDate(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final mm = months[(d.month - 1).clamp(0, 11)];
    return '$mm ${d.day}, ${d.year}';
  }

  String _addedAtLabel() {
    try {
      final dynamic maybe = collectionStore;
      final dynamic item = maybe.getItemByCardId?.call(widget.card.id);
      final DateTime? addedAt = item?.addedAt as DateTime?;
      if (addedAt == null) return 'Unknown';
      return _fmtDate(addedAt);
    } catch (_) {
      return 'Unknown';
    }
  }

  void _toggleFlip() {
    if (_flip.isAnimating) return;

    if (_showBack) {
      _flip.reverse();
    } else {
      _flip.forward();
    }
    setState(() => _showBack = !_showBack);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.card;
    final accentColor = cardAccentColor(c);

    final title = c.name.isEmpty ? 'Card' : c.name;
    final subtitle = '${c.setName} • #${c.number}';

    final ebayQuery = buildEbayQuery(
      name: c.name,
      setName: c.setName,
      number: c.number,
      printedTotal: c.setPrintedTotal,
      mode: _ebayMode,
    );

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 520,
            backgroundColor: const Color(0xFF0B1220),
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                tooltip: _showBack ? 'Show front' : 'Show details',
                icon: Icon(_showBack ? Icons.style : Icons.info_outline),
                onPressed: _toggleFlip,
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: _StageHero(
                accentColor: accentColor,
                idle: _idle,
                flip: _flip,
                card: c,
                title: title,
                subtitle: subtitle,
                onTapCard: _toggleFlip,
                backContent: _CardBackDetails(
                  card: c,
                  addedAt: _addedAtLabel(),
                ),
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(
                children: [
                  Text(
                    'eBay',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withOpacity(0.9),
                    ),
                  ),
                  const Spacer(),
                  SegmentedButton<EbayMode>(
                    segments: const [
                      ButtonSegment(value: EbayMode.raw, label: Text('Raw')),
                      ButtonSegment(
                        value: EbayMode.graded,
                        label: Text('Graded'),
                      ),
                    ],
                    selected: {_ebayMode},
                    onSelectionChanged: (s) =>
                        setState(() => _ebayMode = s.first),
                    showSelectedIcon: false,
                  ),
                ],
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: EbayListingPreviewSection(
                query: ebayQuery,
                accentColor: accentColor,
                title: 'eBay Preview',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ---------------------------- STAGE HERO (OWNED) ----------------------------

class _StageHero extends StatelessWidget {
  final Color accentColor;
  final AnimationController idle;
  final AnimationController flip;
  final PokemonCardResult card;
  final String title;
  final String subtitle;
  final VoidCallback onTapCard;
  final Widget backContent;

  const _StageHero({
    required this.accentColor,
    required this.idle,
    required this.flip,
    required this.card,
    required this.title,
    required this.subtitle,
    required this.onTapCard,
    required this.backContent,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: _StageBackground(accentColor: accentColor)),

        // Title strip (subtle)
        Positioned(
          left: 16,
          right: 16,
          bottom: 22,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.75),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),

        // Floating card + pedestal
        Center(
          child: GestureDetector(
            onTap: onTapCard,
            child: SizedBox(
              height: 420,
              child: AspectRatio(
                aspectRatio: 0.72,
                child: AnimatedBuilder(
                  animation: Listenable.merge([idle, flip]),
                  builder: (context, _) {
                    final t = idle.value * 2 * math.pi;

                    final floatY = math.sin(t) * 8.0;
                    final tiltX = math.sin(t) * 0.10; // subtle
                    final spinY = math.sin(t) * 0.18;

                    final m = Matrix4.identity()
                      ..setEntry(3, 2, 0.0017)
                      ..translate(0.0, floatY)
                      ..rotateX(tiltX)
                      ..rotateY(spinY);

                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        // Shadow + pedestal
                        Positioned(
                          bottom: 24,
                          child: Container(
                            width: 180,
                            height: 24,
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.45),
                              borderRadius: BorderRadius.circular(99),
                              boxShadow: [
                                BoxShadow(
                                  blurRadius: 50,
                                  spreadRadius: 8,
                                  color: Colors.black.withOpacity(0.55),
                                ),
                              ],
                            ),
                          ),
                        ),

                        Transform(
                          alignment: Alignment.center,
                          transform: m,
                          child: PokemonCardShowcase(
                            card: card,
                            animate: false,
                            flip: flip,
                            backContent: backContent,
                            fallbackLabel: title,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),

        // Tap hint
        Positioned(
          top: 96,
          left: 16,
          right: 16,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.25),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white.withOpacity(0.12)),
              ),
              child: Text(
                'Tap card to flip',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.85),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LockedStageHero extends StatefulWidget {
  final String title;
  final String subtitle;
  final String imageUrl;

  const _LockedStageHero({
    required this.title,
    required this.subtitle,
    required this.imageUrl,
  });

  @override
  State<_LockedStageHero> createState() => _LockedStageHeroState();
}

class _LockedStageHeroState extends State<_LockedStageHero>
    with SingleTickerProviderStateMixin {
  late final AnimationController _idle = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  )..repeat();

  @override
  void dispose() {
    _idle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = widget.imageUrl.isNotEmpty;

    return Stack(
      children: [
        const Positioned.fill(
          child: _StageBackground(accentColor: Colors.white),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 22,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.75),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        Center(
          child: SizedBox(
            height: 420,
            child: AspectRatio(
              aspectRatio: 0.72,
              child: AnimatedBuilder(
                animation: _idle,
                builder: (context, _) {
                  final t = _idle.value * 2 * math.pi;
                  final floatY = math.sin(t) * 7.0;
                  final tiltX = math.sin(t) * 0.10;

                  final m = Matrix4.identity()
                    ..setEntry(3, 2, 0.0017)
                    ..translate(0.0, floatY)
                    ..rotateX(tiltX);

                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned(
                        bottom: 24,
                        child: Container(
                          width: 180,
                          height: 24,
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.45),
                            borderRadius: BorderRadius.circular(99),
                            boxShadow: [
                              BoxShadow(
                                blurRadius: 50,
                                spreadRadius: 8,
                                color: Colors.black.withOpacity(0.55),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Transform(
                        alignment: Alignment.center,
                        transform: m,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Stack(
                            children: [
                              SizedBox(
                                width: double.infinity,
                                height: double.infinity,
                                child: hasImage
                                    ? ColorFiltered(
                                        colorFilter: const ColorFilter.matrix(
                                          _kGreyMatrix,
                                        ),
                                        child: Image.network(
                                          widget.imageUrl,
                                          fit: BoxFit.cover,
                                        ),
                                      )
                                    : _CardFallback(label: widget.title),
                              ),
                              Positioned.fill(
                                child: Container(
                                  color: Colors.black.withOpacity(0.25),
                                ),
                              ),
                              Positioned(
                                right: 12,
                                top: 12,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.55),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.14),
                                    ),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.lock, size: 16),
                                      SizedBox(width: 6),
                                      Text(
                                        'Locked',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CardBackDetails extends StatelessWidget {
  final PokemonCardResult card;
  final String addedAt;

  const _CardBackDetails({required this.card, required this.addedAt});

  @override
  Widget build(BuildContext context) {
    final saved = collectionStore.containsCardId(card.id);

    return Container(
      color: const Color(0xFF111A2E),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Details',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          _kv('Saved', saved ? 'Yes' : 'No'),
          _kv('Added', saved ? addedAt : '—'),
          _kv('Set', card.setName.isEmpty ? '—' : card.setName),
          _kv('Set ID', card.setId.isEmpty ? '—' : card.setId),
          _kv('Card #', card.number.isEmpty ? '—' : card.number),
          const Spacer(),
          Text(
            'Scroll down for eBay listings',
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              k,
              style: TextStyle(color: Colors.white.withOpacity(0.75)),
            ),
          ),
          const SizedBox(width: 12),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _CardFallback extends StatelessWidget {
  final String label;
  const _CardFallback({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1F1F1F),
      child: Center(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
      ),
    );
  }
}

/// A background that feels like "a stage":
/// - deep gradient
/// - spotlight cones
/// - soft bloom behind center
class _StageBackground extends StatelessWidget {
  final Color accentColor;

  const _StageBackground({required this.accentColor});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF050A14), Color(0xFF0B1220), Color(0xFF0B1220)],
            ),
          ),
        ),
        Positioned.fill(child: CustomPaint(painter: _SpotlightPainter())),
        Center(
          child: Container(
            width: 420,
            height: 420,
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [
                  accentColor.withOpacity(0.22),
                  Colors.white.withOpacity(0.05),
                  Colors.transparent,
                ],
                radius: 0.9,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint1 = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.white.withOpacity(0.12), Colors.transparent],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final paint2 = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.white.withOpacity(0.07), Colors.transparent],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    Path cone(
      double cx,
      double topY,
      double bottomY,
      double topW,
      double bottomW,
    ) {
      return Path()
        ..moveTo(cx - topW / 2, topY)
        ..lineTo(cx + topW / 2, topY)
        ..lineTo(cx + bottomW / 2, bottomY)
        ..lineTo(cx - bottomW / 2, bottomY)
        ..close();
    }

    final h = size.height;
    final w = size.width;

    // left beam
    canvas.drawPath(cone(w * 0.30, 0, h * 0.80, w * 0.10, w * 0.70), paint2);
    // right beam
    canvas.drawPath(cone(w * 0.70, 0, h * 0.80, w * 0.10, w * 0.70), paint2);
    // center beam
    canvas.drawPath(cone(w * 0.50, 0, h * 0.85, w * 0.12, w * 0.55), paint1);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// grayscale matrix for locked previews
const List<double> _kGreyMatrix = <double>[
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
];

/// ---------------------------- EBAY CODE (KEEP) ----------------------------

const String kProxyBase = 'https://poke-tcg-proxy.maximocran.workers.dev';

class EbayListing {
  final String title;
  final String url;
  final String imageUrl;
  final String condition;
  final double? priceValue;
  final String? priceCurrency;

  EbayListing({
    required this.title,
    required this.url,
    required this.imageUrl,
    required this.condition,
    required this.priceValue,
    required this.priceCurrency,
  });

  factory EbayListing.fromJson(Map<String, dynamic> j) {
    double? pv;
    final raw = j['priceValue'];
    if (raw is num) pv = raw.toDouble();
    if (raw is String) pv = double.tryParse(raw);

    return EbayListing(
      title: (j['title'] ?? '').toString(),
      url: (j['itemWebUrl'] ?? '').toString(),
      imageUrl: (j['imageUrl'] ?? '').toString(),
      condition: (j['condition'] ?? '').toString(),
      priceValue: pv,
      priceCurrency: (j['priceCurrency'] ?? '').toString(),
    );
  }
}

String _ebayMoney(EbayListing l) {
  if (l.priceValue == null) return '—';
  final cur = (l.priceCurrency == null || l.priceCurrency!.isEmpty)
      ? ''
      : '${l.priceCurrency} ';
  return '$cur${l.priceValue!.toStringAsFixed(2)}';
}

Future<List<EbayListing>> fetchEbayActiveListings({
  required String query,
  int limit = 2,
}) async {
  final uri = Uri.parse(
    '$kProxyBase/ebay-active',
  ).replace(queryParameters: {'q': query, 'limit': '$limit'});

  final res = await http.get(uri);
  final text = res.body;

  if (res.statusCode != 200) {
    final head = text.substring(0, text.length.clamp(0, 160));
    throw Exception('eBay fetch failed ${res.statusCode}: $head');
  }

  final data = jsonDecode(text) as Map<String, dynamic>;
  final items = (data['items'] as List<dynamic>? ?? const []);
  return items
      .map((e) => EbayListing.fromJson(e as Map<String, dynamic>))
      .where((e) => e.url.isNotEmpty)
      .toList();
}

Future<List<EbayListing>> fetchEbaySoldListings({
  required String query,
  int limit = 1,
}) async {
  final uri = Uri.parse(
    '$kProxyBase/ebay-sold',
  ).replace(queryParameters: {'q': query, 'limit': '$limit'});

  final res = await http.get(uri);
  final text = res.body;

  if (res.statusCode != 200) {
    final head = text.substring(0, text.length.clamp(0, 160));
    throw Exception('eBay sold fetch failed ${res.statusCode}: $head');
  }

  final data = jsonDecode(text) as Map<String, dynamic>;
  final items = (data['items'] as List<dynamic>? ?? const []);
  return items
      .map((e) => EbayListing.fromJson(e as Map<String, dynamic>))
      .where((e) => e.url.isNotEmpty)
      .toList();
}

double? averageEbayListingPrices(List<EbayListing> listings, {int take = 3}) {
  final prices = <double>[];
  for (final listing in listings) {
    final price = listing.priceValue;
    if (price != null && price > 0) {
      prices.add(price);
    }
    if (prices.length >= take) break;
  }

  if (prices.isEmpty) return null;

  final total = prices.reduce((a, b) => a + b);
  return total / prices.length;
}

double? averageEbayPreviewPrices(List<EbayPreviewItem> items, {int take = 3}) {
  final prices = <double>[];
  for (final item in items) {
    final price = item.listing.priceValue;
    if (price != null && price > 0) {
      prices.add(price);
    }
    if (prices.length >= take) break;
  }

  if (prices.isEmpty) return null;

  final total = prices.reduce((a, b) => a + b);
  return total / prices.length;
}

Future<double?> fetchEbayMarketValue({required String query}) async {
  try {
    final previewItems = await fetchEbayPreviewItems(
      query: query,
      maxListings: 3,
    ).timeout(const Duration(seconds: 4));
    return averageEbayPreviewPrices(previewItems, take: 3);
  } catch (_) {
    return null;
  }
}

Future<List<EbayPreviewItem>> fetchEbayPreviewItems({
  required String query,
  int maxListings = 3,
}) async {
  final cacheKey = _ebayPreviewCacheKey(query: query, maxListings: maxListings);
  final cached = _ebayPreviewCache[cacheKey];
  if (cached != null) {
    return List<EbayPreviewItem>.from(cached);
  }

  final inFlight = _ebayPreviewInFlight[cacheKey];
  if (inFlight != null) {
    final shared = await inFlight;
    return List<EbayPreviewItem>.from(shared);
  }

  final future = () async {
    final soldFuture = fetchEbaySoldListings(
      query: query,
      limit: 1,
    ).catchError((_) => <EbayListing>[]);
    final activeFuture = fetchEbayActiveListings(
      query: query,
      limit: maxListings,
    ).catchError((_) => <EbayListing>[]);

    final results = await Future.wait([soldFuture, activeFuture]);
    final soldListings = results[0];
    final activeListings = results[1];

    final previewItems = <EbayPreviewItem>[];
    final seenUrls = <String>{};

    for (final listing in soldListings) {
      if (listing.url.isEmpty || seenUrls.contains(listing.url)) continue;
      seenUrls.add(listing.url);
      previewItems.add(
        EbayPreviewItem(listing: listing, state: EbayListingState.sold),
      );
      if (previewItems.length >= maxListings) {
        final frozen = List<EbayPreviewItem>.unmodifiable(previewItems);
        _ebayPreviewCache[cacheKey] = frozen;
        return frozen;
      }
    }

    for (final listing in activeListings) {
      if (listing.url.isEmpty || seenUrls.contains(listing.url)) continue;
      seenUrls.add(listing.url);
      previewItems.add(
        EbayPreviewItem(listing: listing, state: EbayListingState.active),
      );
      if (previewItems.length >= maxListings) break;
    }

    final frozen = List<EbayPreviewItem>.unmodifiable(previewItems);
    _ebayPreviewCache[cacheKey] = frozen;
    return frozen;
  }();

  _ebayPreviewInFlight[cacheKey] = future;
  try {
    final items = await future;
    return List<EbayPreviewItem>.from(items);
  } finally {
    _ebayPreviewInFlight.remove(cacheKey);
  }
}

Color cardAccentColor(PokemonCardResult card) {
  final rarity = (card.rarity ?? '').toLowerCase();
  final supertype = (card.supertype ?? '').toLowerCase();

  if (rarity.contains('hyper') ||
      rarity.contains('secret') ||
      rarity.contains('rainbow')) {
    return const Color(0xFFF59E0B);
  }
  if (rarity.contains('illustration') || rarity.contains('ultra')) {
    return const Color(0xFFEC4899);
  }
  if (rarity.contains('holo')) {
    return const Color(0xFF38BDF8);
  }
  if (rarity.contains('promo')) {
    return const Color(0xFFEF4444);
  }
  if (rarity.contains('rare')) {
    return const Color(0xFF22C55E);
  }
  if (supertype.contains('trainer')) {
    return const Color(0xFFF97316);
  }
  if (supertype.contains('energy')) {
    return const Color(0xFFEAB308);
  }
  if (card.isStage2) return const Color(0xFFA78BFA);
  if (card.isStage1) return const Color(0xFF60A5FA);
  if (card.isBasic) return const Color(0xFF34D399);

  const fallback = <Color>[
    Color(0xFF38BDF8),
    Color(0xFF22C55E),
    Color(0xFFF59E0B),
    Color(0xFFA78BFA),
    Color(0xFFFB7185),
  ];
  final seed = '${card.id}${card.name}${card.setId}'.codeUnits.fold<int>(
    0,
    (sum, c) => sum + c,
  );
  return fallback[seed % fallback.length];
}

Future<void> _openExternal(String url) async {
  final uri = Uri.parse(url);
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

String buildEbayQuery({
  required String name,
  required String setName,
  required String number,
  int? printedTotal,
  required EbayMode mode,
}) {
  String clean(String s) => s
      .replaceAll(RegExp(r'[^A-Za-z0-9 ]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  final cleanName = clean(name);
  final cleanSet = clean(setName);

  final rawNum = number.trim();
  final numDigits = RegExp(r'^\d+$').hasMatch(rawNum)
      ? int.tryParse(rawNum)
      : null;

  String numberToken = clean(rawNum);

  if (numDigits != null && printedTotal != null && printedTotal > 0) {
    final padded = numDigits.toString().padLeft(3, '0');
    numberToken = '$padded/$printedTotal';
  }

  const sealedNegatives = [
    '-etb',
    '-"elite trainer"',
    '-booster',
    '-bundle',
    '-box',
    '-display',
    '-case',
    '-sealed',
    '-pack',
    '-packs',
    '-tin',
    '-lot',
    '-binder',
  ];

  const japaneseNegatives = ['-japanese', '-japan', '-jp'];

  const gradedPositive = ['psa', 'cgc', 'bgs', 'graded', 'slab'];
  const gradedNegatives = ['-psa', '-cgc', '-bgs', '-sgc', '-graded', '-slab'];

  final pieces = <String>[
    if (cleanName.isNotEmpty) cleanName,
    if (cleanSet.isNotEmpty) '"$cleanSet"',
    if (numberToken.isNotEmpty) '"$numberToken"',
    'pokemon card',
    ...sealedNegatives,
    ...japaneseNegatives,
    if (mode == EbayMode.graded) ...gradedPositive,
    if (mode == EbayMode.raw) ...gradedNegatives,
  ];

  return pieces.where((s) => s.trim().isNotEmpty).join(' ').trim();
}

class EbayActiveBlock extends StatelessWidget {
  final String query;
  const EbayActiveBlock({super.key, required this.query});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<EbayListing>>(
      future: fetchEbayActiveListings(query: query, limit: 2),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: LinearProgressIndicator(minHeight: 2),
          );
        }

        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Active listings unavailable right now.',
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withOpacity(0.75),
              ),
            ),
          );
        }

        final items = snap.data ?? const [];
        if (items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'No active listings found.',
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withOpacity(0.75),
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Active listings (eBay)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            ...items.map((l) {
              return Card(
                child: ListTile(
                  leading: (l.imageUrl.isEmpty)
                      ? const Icon(Icons.shopping_bag_outlined)
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.network(
                            l.imageUrl,
                            width: 54,
                            height: 54,
                            fit: BoxFit.cover,
                          ),
                        ),
                  title: Text(
                    _ebayMoney(l),
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text(
                    l.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => _openExternal(l.url),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}

class EbayListingPreviewSection extends StatelessWidget {
  final String query;
  final Color accentColor;
  final String title;
  final int maxListings;

  const EbayListingPreviewSection({
    super.key,
    required this.query,
    required this.accentColor,
    this.title = 'eBay Preview',
    this.maxListings = 3,
  });

  Uri _ebaySearchUrl() {
    return Uri.parse(
      'https://www.ebay.com/sch/i.html?_nkw=${Uri.encodeComponent(query)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<EbayPreviewItem>>(
      future: fetchEbayPreviewItems(query: query, maxListings: maxListings),
      builder: (context, snap) {
        final items = snap.data ?? const <EbayPreviewItem>[];

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                accentColor.withOpacity(0.10),
                Colors.white.withOpacity(0.02),
              ],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: accentColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (snap.connectionState != ConnectionState.done)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(minHeight: 2),
                )
              else if (items.isEmpty)
                Text(
                  'No eBay previews available right now.',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.72),
                    fontWeight: FontWeight.w600,
                  ),
                )
              else
                ...items
                    .take(maxListings)
                    .map(
                      (item) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _EbayPreviewCard(
                          item: item,
                          accentColor: accentColor,
                        ),
                      ),
                    ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: () => _openExternal(_ebaySearchUrl().toString()),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('View more on eBay'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EbayPreviewCard extends StatelessWidget {
  final EbayPreviewItem item;
  final Color accentColor;

  const _EbayPreviewCard({required this.item, required this.accentColor});

  @override
  Widget build(BuildContext context) {
    final listing = item.listing;
    final stateLabel = item.state == EbayListingState.sold ? 'SOLD' : 'ACTIVE';
    final imageUrl = listing.imageUrl;
    final title = listing.title.trim().isEmpty ? 'eBay listing' : listing.title;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: listing.url.isEmpty ? null : () => _openExternal(listing.url),
        child: Ink(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 58,
                  height: 58,
                  child: imageUrl.isEmpty
                      ? Container(
                          color: Colors.white.withOpacity(0.05),
                          child: const Icon(
                            Icons.shopping_bag_outlined,
                            color: Colors.white54,
                          ),
                        )
                      : Image.network(imageUrl, fit: BoxFit.cover),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _ebayMoney(listing),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: accentColor.withOpacity(0.18),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: accentColor.withOpacity(0.28),
                            ),
                          ),
                          child: Text(
                            stateLabel,
                            style: TextStyle(
                              color: accentColor,
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.82),
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
