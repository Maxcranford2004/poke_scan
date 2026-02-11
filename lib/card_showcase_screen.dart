import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

import 'pokemon_models.dart';
import 'collection_store.dart';
import 'main.dart' show PokemonCardDetailsScreen; // reuse safely

enum EbayMode { raw, graded }

class CardShowcaseScreen extends StatefulWidget {
  final PokemonCardResult card;

  const CardShowcaseScreen({super.key, required this.card});

  @override
  State<CardShowcaseScreen> createState() => _CardShowcaseScreenState();
}

class _CardShowcaseScreenState extends State<CardShowcaseScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  bool _showDetails = true;

  // ✅ Raw / Graded toggle state
  EbayMode _ebayMode = EbayMode.raw;

  @override
  void dispose() {
    _spin.dispose();
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

  // Safe attempt: if your CollectionStore has a way to get per-card addedAt, use it.
  // If not, we fall back to "Unknown".
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

  @override
  Widget build(BuildContext context) {
    final c = widget.card;
    final saved = collectionStore.containsCardId(c.id);

    final title = c.name.isEmpty ? 'Card' : c.name;
    final subtitle = '${c.setName} • #${c.number}';

    // ✅ Query depends on Raw vs Graded toggle
    final ebayQuery = buildEbayQuery(
      name: c.name,
      setName: c.setName,
      number: c.number,
      printedTotal: c.setPrintedTotal,
      mode: _ebayMode,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Showcase'),
        actions: [
          IconButton(
            tooltip: _showDetails ? 'Hide details' : 'Show details',
            icon: Icon(_showDetails ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _showDetails = !_showDetails),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---------- Hero card image ----------
          if (c.imageLarge.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.network(c.imageLarge, fit: BoxFit.contain),
            )
          else
            const Center(child: Text('No image available')),

          const SizedBox(height: 12),

          // ---------- Quick facts ----------
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Quick facts',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  _kv('Saved to collection', saved ? 'Yes' : 'No'),
                  _kv('Added', saved ? _addedAtLabel() : '—'),
                  _kv('Set', c.setName.isEmpty ? '—' : c.setName),
                  _kv('Set ID', c.setId.isEmpty ? '—' : c.setId),
                  _kv('Card #', c.number.isEmpty ? '—' : c.number),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // ---------- Active listings ----------
          Row(
            children: [
              Text(
                'eBay',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withOpacity(0.85),
                ),
              ),
              const Spacer(),
              SegmentedButton<EbayMode>(
                segments: const [
                  ButtonSegment(value: EbayMode.raw, label: Text('Raw')),
                  ButtonSegment(value: EbayMode.graded, label: Text('Graded')),
                ],
                selected: {_ebayMode},
                onSelectionChanged: (s) => setState(() => _ebayMode = s.first),
                showSelectedIcon: false,
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ✅ ACTIVE LISTINGS block
          EbayActiveBlock(query: ebayQuery),

          const SizedBox(height: 12),

          // ---------- Links ----------
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Links',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 46,
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        final url =
                            'https://www.ebay.com/sch/i.html?_nkw=${Uri.encodeComponent(ebayQuery)}';
                        _open(Uri.parse(url));
                      },
                      icon: const Icon(Icons.shopping_bag_outlined),
                      label: const Text('View on eBay'),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // ---------- Details (optional) ----------
          if (_showDetails) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Details',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(subtitle),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 46,
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => PokemonCardDetailsScreen(card: c),
                            ),
                          );
                        },
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Open Card Details'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // (Optional) keep your embedded details block if you want it visible:
          // _EmbeddedDetails(card: c),
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
          Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _EmbeddedDetails extends StatelessWidget {
  final PokemonCardResult card;
  const _EmbeddedDetails({required this.card});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'More',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.9),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Open the full details view (your existing screen).',
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withOpacity(0.75),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              icon: const Icon(Icons.receipt_long),
              label: const Text('Open full details'),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PokemonCardDetailsScreen(card: card),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _FloatingCard extends StatelessWidget {
  final AnimationController controller;
  final String imageUrl;
  final String fallbackLabel;

  const _FloatingCard({
    required this.controller,
    required this.imageUrl,
    required this.fallbackLabel,
  });

  @override
  Widget build(BuildContext context) {
    final hasImage = imageUrl.isNotEmpty;

    return Center(
      child: SizedBox(
        height: 420,
        child: AspectRatio(
          aspectRatio: 0.72,
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, child) {
              final t = controller.value * 2 * math.pi;
              final rotX = math.sin(t) * 0.22; // ~ +/- 12.6°
              final floatY = math.sin(t) * 6.0;

              return Transform.translate(
                offset: Offset(0, floatY),
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.0016)
                    ..rotateX(rotX),
                  child: child,
                ),
              );
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: hasImage
                  ? Image.network(imageUrl, fit: BoxFit.cover)
                  : Container(
                      color: const Color(0xFF1F1F1F),
                      child: Center(
                        child: Text(
                          fallbackLabel,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

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

  // number may be "1", "001", "TG05", "SWSH127", etc.
  final rawNum = number.trim();
  final numDigits = RegExp(r'^\d+$').hasMatch(rawNum)
      ? int.tryParse(rawNum)
      : null;

  String numberToken = clean(rawNum);

  // If numeric number + printedTotal, build "001/165"
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

  // For graded mode, bias toward slabs.
  // For raw mode, exclude slabs.
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
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
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
