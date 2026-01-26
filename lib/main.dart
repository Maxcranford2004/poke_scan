import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:poke_scan/pokemon_tcg_api.dart';
import 'package:poke_scan/collection_store.dart';
import 'package:poke_scan/pokemon_ocr.dart';
import 'package:image_picker/image_picker.dart';
import 'pokemon_models.dart';
import 'package:hive_flutter/hive_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await PokemonTcgApi.initCache();

  final cameras = await availableCameras();
  runApp(CardScanApp(cameras: cameras));
}

enum CardType { pokemon, sports }

extension CardTypeLabel on CardType {
  String get label => this == CardType.pokemon ? 'Pokémon' : 'Sports';
}

class CardScanApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const CardScanApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0B1220),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B1220),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        cardTheme: const CardThemeData(color: Color(0xFF111A2E)),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF111A2E),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: AppShell(cameras: cameras),
    );
  }
}

class AppShell extends StatefulWidget {
  final List<CameraDescription> cameras;
  const AppShell({super.key, required this.cameras});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      HomeScreen(cameras: widget.cameras),
      const CollectionScreen(),
      const SettingsScreen(),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
          NavigationDestination(
            icon: Icon(Icons.collections_bookmark_outlined),
            label: 'Collection',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text(
          'Settings / Account (coming soon)',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  final List<CameraDescription> cameras;
  const HomeScreen({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top bar (Account placeholder)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'CardScan',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Account coming soon')),
                      );
                    },
                    icon: const Icon(Icons.person_outline),
                    label: const Text('Sign in'),
                  ),
                ],
              ),

              const SizedBox(height: 18),

              const Text(
                'Scan or search a card to get prices and save it to your collection.',
                style: TextStyle(fontSize: 14),
              ),

              const Spacer(),

              SizedBox(
                height: 58,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Scan your card'),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ScanScreen(cameras: cameras),
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 12),

              SizedBox(
                height: 58,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.search),
                  label: const Text('Search manually'),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ManualSearchScreen(),
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 18),

              const Text(
                'Tip: Manual search is best when scanning is blurry or the set/number is missing.',
                textAlign: TextAlign.center,
              ),

              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

/* --------------------------- SCAN FLOW (camera) --------------------------- */

class ScanScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const ScanScreen({super.key, required this.cameras});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  CameraController? _controller;
  Future<void>? _initFuture;
  XFile? _captured;

  @override
  void initState() {
    super.initState();
    if (widget.cameras.isEmpty) return;

    _controller = CameraController(
      widget.cameras.first,
      ResolutionPreset.high,
      enableAudio: false,
    );
    _initFuture = _controller!.initialize();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _takePhoto() async {
    final controller = _controller;
    if (controller == null) return;

    try {
      if (!controller.value.isInitialized) return;
      if (controller.value.isTakingPicture) return;

      final file = await controller.takePicture();
      if (!mounted) return;
      setState(() => _captured = file);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Capture failed: $e')));
    }
  }

  void _retake() => setState(() => _captured = null);

  void _usePhoto() {
    final file = _captured;
    if (file == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecognizingScreen(photoPath: file.path),
      ),
    );
  }

  Future<void> _pickFromGallery() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecognizingScreen(photoPath: file.path),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(title: const Text('Scan')),
      body: controller == null
          ? const Center(child: Text('No camera found on this device/emulator'))
          : FutureBuilder<void>(
              future: _initFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  if (snapshot.hasError) {
                    return Center(
                      child: Text('Camera error: ${snapshot.error}'),
                    );
                  }
                  return const Center(child: CircularProgressIndicator());
                }

                if (_captured != null) {
                  return _PreviewScreen(
                    path: _captured!.path,
                    onRetake: _retake,
                    onUse: _usePhoto,
                  );
                }

                return Stack(
                  children: [
                    Positioned.fill(child: CameraPreview(controller)),

                    Positioned(
                      top: 16,
                      right: 16,
                      child: ElevatedButton.icon(
                        onPressed: _pickFromGallery,
                        icon: const Icon(Icons.photo),
                        label: const Text('Pick'),
                      ),
                    ),

                    Center(
                      child: Container(
                        width: MediaQuery.of(context).size.width * 0.78,
                        height: MediaQuery.of(context).size.height * 0.55,
                        decoration: BoxDecoration(
                          border: Border.all(width: 3),
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),

                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 28,
                      child: Center(
                        child: GestureDetector(
                          onTap: _takePhoto,
                          child: Container(
                            width: 74,
                            height: 74,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(width: 5),
                              color: Colors.white.withOpacity(0.1),
                            ),
                            child: const Center(
                              child: Icon(Icons.camera_alt, size: 30),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _PreviewScreen extends StatelessWidget {
  final String path;
  final VoidCallback onRetake;
  final VoidCallback onUse;

  const _PreviewScreen({
    required this.path,
    required this.onRetake,
    required this.onUse,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Container(
            color: Colors.black,
            alignment: Alignment.center,
            child: Image.file(File(path), fit: BoxFit.contain),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onRetake,
                    child: const Text('Retake'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: onUse,
                    child: const Text('Use Photo'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/* -------------------------- MANUAL SEARCH FLOW --------------------------- */

class ManualSearchScreen extends StatefulWidget {
  const ManualSearchScreen({super.key});

  @override
  State<ManualSearchScreen> createState() => _ManualSearchScreenState();
}

class _ManualSearchScreenState extends State<ManualSearchScreen> {
  CardType _type = CardType.pokemon;

  final _nameController = TextEditingController();
  final _setController = TextEditingController();
  final _numberController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _setController.dispose();
    _numberController.dispose();
    super.dispose();
  }

  void _search() {
    final name = _nameController.text.trim();
    final set = _setController.text.trim();
    final number = _numberController.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a name/player/Pokémon to search.')),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SearchResultsScreen(
          type: _type,
          name: name,
          set: set.isEmpty ? null : set,
          number: (number?.isEmpty ?? true) ? null : number,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manual Search')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Search basics',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),

          DropdownButtonFormField<CardType>(
            value: _type,
            decoration: const InputDecoration(
              labelText: 'Card type',
              border: OutlineInputBorder(),
            ),
            items: CardType.values
                .map((t) => DropdownMenuItem(value: t, child: Text(t.label)))
                .toList(),
            onChanged: (val) => setState(() => _type = val ?? CardType.pokemon),
          ),

          const SizedBox(height: 12),

          TextField(
            controller: _nameController,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              labelText: 'Name / Player / Pokémon',
              border: OutlineInputBorder(),
              hintText: 'e.g., Charizard or Patrick Mahomes',
            ),
            onSubmitted: (_) => _search(),
          ),

          const SizedBox(height: 18),
          const Text(
            'Optional filters',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 10),

          TextField(
            controller: _setController,
            decoration: const InputDecoration(
              labelText: 'Set (optional)',
              border: OutlineInputBorder(),
              hintText: 'e.g., Base Set, Prizm, Topps Chrome',
            ),
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _numberController,
            decoration: const InputDecoration(
              labelText: 'Card number (optional)',
              border: OutlineInputBorder(),
              hintText: 'e.g., 4/102 or #210',
            ),
          ),

          const SizedBox(height: 16),

          SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _search,
              icon: const Icon(Icons.search),
              label: const Text('Search'),
            ),
          ),
        ],
      ),
    );
  }
}

class SearchResultsScreen extends StatefulWidget {
  final CardType type;
  final String name;
  final String? set;
  final String? number;

  const SearchResultsScreen({
    super.key,
    required this.type,
    required this.name,
    this.set,
    this.number,
  });

  @override
  State<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _EmptyFallbackPanel extends StatelessWidget {
  final String query;
  final VoidCallback onRetry;

  const _EmptyFallbackPanel({required this.query, required this.onRetry});

  Uri _ebaySoldUrl(String q) {
    final enc = Uri.encodeComponent(q);
    return Uri.parse(
      'https://www.ebay.com/sch/i.html?_nkw=$enc&LH_Sold=1&LH_Complete=1',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 44),
            const SizedBox(height: 10),
            const Text(
              'No results yet (and live results may be slow).',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                final ok = await launchUrl(
                  _ebaySoldUrl(query),
                  mode: LaunchMode.externalApplication,
                );
                if (!ok && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Could not open eBay')),
                  );
                }
              },
              icon: const Icon(Icons.shopping_bag_outlined),
              label: const Text('View sold listings on eBay'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchResultsScreenState extends State<SearchResultsScreen> {
  bool _loading = true; // first paint
  bool _updating = false; // cached shown, live refresh happening
  String? _error; // only shown if we have NOTHING to show
  List<PokemonCardResult> _results = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _updating = false;
      _error = null;
    });

    final api = PokemonTcgApi();

    // 1) Try cached first (fast)
    try {
      final cached = await api.getCachedSearch(
        name: widget.name,
        set: widget.set,
        number: widget.number,
      );

      if (!mounted) return;

      if (cached.isNotEmpty) {
        setState(() {
          _results = cached;
          _loading = false; // show instantly
          _updating = true; // but still try live refresh
        });
      }
    } catch (_) {
      // ignore cache read errors
    }

    // 2) Live refresh (may fail / timeout)
    try {
      final live = await api.refreshSearch(
        name: widget.name,
        set: widget.set,
        number: widget.number,
      );

      if (!mounted) return;

      setState(() {
        _results = live;
        _loading = false;
        _updating = false;
        _error = live.isEmpty ? 'No results found.' : null;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _updating = false;

        // Only show an error if we have NOTHING to show.
        if (_results.isEmpty) {
          _error = 'Live results are unavailable right now. Please try again.';
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.type == CardType.sports) {
      return Scaffold(
        appBar: AppBar(title: const Text('Results')),
        body: const Center(
          child: Text(
            'Sports results coming next.\n\nWe’ll likely use eBay sold listings or a paid data provider.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final results = _results;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Results'),
        actions: [
          IconButton(
            tooltip: 'Retry',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_updating) const LinearProgressIndicator(minHeight: 2),

          if (_loading && results.isEmpty)
            const Expanded(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Searching…', textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
            )
          else if (_error != null && results.isEmpty)
            Expanded(
              child: _EmptyFallbackPanel(
                query: '${widget.name} ${widget.number ?? ''}'.trim(),
                onRetry: _load,
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: results.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final c = results[i];
                  final saved = collectionStore.containsCardId(c.id);

                  return Card(
                    child: ListTile(
                      leading: c.imageSmall.isEmpty
                          ? const Icon(Icons.image_not_supported)
                          : Image.network(
                              c.imageSmall,
                              width: 56,
                              fit: BoxFit.cover,
                            ),
                      title: Text('${c.name} • ${c.setName}'),
                      subtitle: Text('#${c.number}\nTap for details'),
                      isThreeLine: true,
                      trailing: IconButton(
                        icon: Icon(
                          saved ? Icons.check_circle : Icons.add_circle,
                        ),
                        onPressed: () {
                          collectionStore.addCard(c);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Saved ${c.name}')),
                          );
                          setState(() {});
                        },
                      ),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PokemonCardDetailsScreen(card: c),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/* ---------------------------- COLLECTION SCREEN --------------------------- */
enum _CollectionSort { newest, valueHighToLow, nameAZ }

class CollectionScreen extends StatefulWidget {
  const CollectionScreen({super.key});

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  _CollectionSort _sort = _CollectionSort.newest;

  @override
  void initState() {
    super.initState();
    collectionStore.addListener(_onChanged);
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    collectionStore.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  String _moneyN(double? v) => v == null ? '—' : '\$${v.toStringAsFixed(2)}';

  bool _matchesQuery(CollectionItem item) {
    if (_query.isEmpty) return true;
    final c = item.card;
    final hay = '${c.name} ${c.setName} ${c.number}'.toLowerCase();
    return hay.contains(_query);
  }

  double _itemValue(CollectionItem item) {
    return item.estimatedMid ??
        item.marketAtSave ??
        item.card.bestMarket ??
        0.0;
  }

  List<CollectionItem> _filteredSorted(List<CollectionItem> items) {
    final filtered = items.where(_matchesQuery).toList();

    switch (_sort) {
      case _CollectionSort.newest:
        filtered.sort((a, b) => b.addedAt.compareTo(a.addedAt));
        break;
      case _CollectionSort.valueHighToLow:
        filtered.sort((a, b) => _itemValue(b).compareTo(_itemValue(a)));
        break;
      case _CollectionSort.nameAZ:
        filtered.sort(
          (a, b) =>
              a.card.name.toLowerCase().compareTo(b.card.name.toLowerCase()),
        );
        break;
    }
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final items = _filteredSorted(collectionStore.items);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Collection'),
        actions: [
          IconButton(
            tooltip: 'Clear (testing)',
            onPressed: items.isEmpty ? null : () => collectionStore.clear(),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: items.isEmpty
          ? const Center(
              child: Text(
                'No cards saved yet.\nSave cards from Pokémon search results.',
                textAlign: TextAlign.center,
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchCtrl,
                          decoration: InputDecoration(
                            hintText: 'Search your collection...',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.close),
                                    onPressed: () => _searchCtrl.clear(),
                                  ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      DropdownButton<_CollectionSort>(
                        value: _sort,
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _sort = v);
                        },
                        items: const [
                          DropdownMenuItem(
                            value: _CollectionSort.newest,
                            child: Text('Newest'),
                          ),
                          DropdownMenuItem(
                            value: _CollectionSort.valueHighToLow,
                            child: Text('Value'),
                          ),
                          DropdownMenuItem(
                            value: _CollectionSort.nameAZ,
                            child: Text('A–Z'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Cards: ${collectionStore.count}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'Estimated total: ${_moneyN(collectionStore.totalEstimatedValue)}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      final item = items[i];
                      final c = item.card;

                      final estLow = item.estLowAtSave;
                      final estHigh = item.estHighAtSave;
                      final market = item.marketAtSave ?? c.bestMarket;

                      final subtitleLines = <String>[
                        '#${c.number}',
                        if (item.finish != null && item.finish!.isNotEmpty)
                          'Finish: ${item.finish}   •   Grade: ${item.userGrade}'
                        else
                          'Grade: ${item.userGrade}',
                        if (estLow != null && estHigh != null)
                          'Estimate: ${_moneyN(estLow)} – ${_moneyN(estHigh)}'
                        else
                          'Market: ${_moneyN(market)}',
                      ];

                      return Card(
                        child: ListTile(
                          leading: c.imageSmall.isEmpty
                              ? const Icon(Icons.image_not_supported)
                              : Image.network(
                                  c.imageSmall,
                                  width: 56,
                                  fit: BoxFit.cover,
                                ),
                          title: Text('${c.name} • ${c.setName}'),
                          subtitle: Text(subtitleLines.join('\n')),
                          trailing: IconButton(
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () =>
                                collectionStore.removeCardById(c.id),
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    PokemonCardDetailsScreen(card: c),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

/* ---------------------------- DETAILS + GRADING --------------------------- */

class PokemonCardDetailsScreen extends StatefulWidget {
  final PokemonCardResult card;
  const PokemonCardDetailsScreen({super.key, required this.card});

  @override
  State<PokemonCardDetailsScreen> createState() =>
      _PokemonCardDetailsScreenState();
}

class _PokemonCardDetailsScreenState extends State<PokemonCardDetailsScreen> {
  String? _selectedFinish;
  int _grade = 8;

  late Future<PokemonCardResult?> _fullFuture;

  @override
  void initState() {
    super.initState();

    // Load full card (pricing) by ID
    _fullFuture = PokemonTcgApi().fetchCardById(widget.card.id);

    // Preferred finish (works if finishes exist on the lite card)
    if (widget.card.finishes.isNotEmpty) {
      const preferred = ['normal', 'holofoil', 'reverseHolofoil'];
      for (final p in preferred) {
        if (widget.card.finishes.containsKey(p)) {
          _selectedFinish = p;
          break;
        }
      }
      _selectedFinish ??= widget.card.finishes.keys.first;
    }
  }

  String _money(double? v) => v == null ? '—' : '\$${v.toStringAsFixed(2)}';

  String? _defaultFinishFor(Map<String, PriceRow> finishes) {
    if (finishes.isEmpty) return null;
    const preferred = ['normal', 'holofoil', 'reverseHolofoil'];
    for (final p in preferred) {
      if (finishes.containsKey(p)) return p;
    }
    return finishes.keys.first;
  }

  double? _baseMarket(PokemonCardResult card, String? finish) {
    if (finish == null) return card.bestMarket;
    return card.finishes[finish]?.market ?? card.bestMarket;
  }

  double? _estimatedValue(PokemonCardResult card, String? finish) {
    final base = _baseMarket(card, finish);
    if (base == null) return null;
    final multiplier = _grade / 10.0; // 1..10 => 0.1..1.0
    return base * multiplier;
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open link')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PokemonCardResult?>(
      future: _fullFuture,
      builder: (context, snap) {
        final loading = snap.connectionState != ConnectionState.done;
        final pricingError = snap.hasError;

        // ✅ FIXED: use "snap" (not "snapshot")
        final full = snap.data;
        final card = full ?? widget.card;

        final finish = _selectedFinish ?? _defaultFinishFor(card.finishes);
        final prices = (finish == null) ? null : card.finishes[finish];
        final base = _baseMarket(card, finish);
        final est = _estimatedValue(card, finish);

        final saved = collectionStore.containsCardId(card.id);

        return Scaffold(
          appBar: AppBar(title: const Text('Card Details')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (loading)
                const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: LinearProgressIndicator(),
                ),

              if (pricingError)
                const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: Text(
                    'Pricing temporarily unavailable. Showing card info only.',
                    textAlign: TextAlign.center,
                  ),
                ),

              Text(
                card.name.isEmpty ? '(Loading name…)' : card.name,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text('${card.setName} • #${card.number}'),
              const SizedBox(height: 14),

              if (card.imageLarge.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.network(card.imageLarge, fit: BoxFit.contain),
                )
              else
                const Center(child: Text('No image available')),

              const SizedBox(height: 14),

              SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: saved
                      ? null
                      : () {
                          collectionStore.addCard(card);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                'Saved ${card.name} to your collection',
                              ),
                            ),
                          );
                          setState(() {});
                        },
                  icon: Icon(saved ? Icons.check : Icons.add),
                  label: Text(saved ? 'Saved' : 'Save to My Collection'),
                ),
              ),

              const SizedBox(height: 16),

              if (card.finishes.isNotEmpty) ...[
                const Text(
                  'Finish',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: card.finishes.keys.map((k) {
                    return ChoiceChip(
                      label: Text(k),
                      selected: k == finish,
                      onSelected: (_) => setState(() => _selectedFinish = k),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
              ],

              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Pricing (TCGplayer)',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Market'),
                          Text(_money(prices?.market ?? card.bestMarket)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Low'),
                          Text(_money(prices?.low)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Mid'),
                          Text(_money(prices?.mid)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('High'),
                          Text(_money(prices?.high)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Condition (1–10)',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('Selected grade: $_grade'),
                      Slider(
                        value: _grade.toDouble(),
                        min: 1,
                        max: 10,
                        divisions: 9,
                        label: '$_grade',
                        onChanged: (v) => setState(() => _grade = v.round()),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        base == null
                            ? 'No market price available for estimate.'
                            : 'Estimated value @ grade $_grade: ${_money(est)} (based on market ${_money(base)})',
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  ConditionGuideScreen(initialGrade: _grade),
                            ),
                          );
                        },
                        icon: const Icon(Icons.info_outline),
                        label: const Text('How to grade (guide)'),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              if (card.tcgplayerUrl != null && card.tcgplayerUrl!.isNotEmpty)
                SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: () => _openLink(card.tcgplayerUrl!),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open listing'),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class RecognizingScreen extends StatefulWidget {
  final String photoPath;
  const RecognizingScreen({super.key, required this.photoPath});

  @override
  State<RecognizingScreen> createState() => _RecognizingScreenState();
}

class _RecognizingScreenState extends State<RecognizingScreen> {
  bool _loading = true;
  String? _error;

  final _nameCtrl = TextEditingController();
  final _numCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _runAll();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _numCtrl.dispose();
    super.dispose();
  }

  String _cleanOcrName(String raw) {
    var s = raw;

    // Keep only likely name characters
    s = s.replaceAll('’', "'").replaceAll(RegExp(r"[^A-Za-z0-9\s\-'']"), ' ');

    // Remove common labels that show on cards
    s = s.replaceAll(
      RegExp(r'\b(BASIC|BSIC|STAGE|TRAINER|ENERGY)\b', caseSensitive: false),
      ' ',
    );

    // Collapse whitespace
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  String _cleanNumber(String raw) {
    final m = RegExp(r'\d{1,3}').firstMatch(raw);
    return m?.group(0) ?? raw.trim();
  }

  Future<void> _runAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    String name = '';
    String? numOnly; // "183"
    String? setTotalStr; // "165"
    String? rawNumber; // might be "183/165"
    int? hp;
    String? stage;

    try {
      final guess = await PokemonOcr.recognizeFromImagePath(widget.photoPath);

      name = (guess.name ?? '').trim();
      rawNumber = (guess.number ?? '').trim();
      setTotalStr = (guess.setTotal ?? '').trim();
      hp = guess.hp;
      stage = guess.stage;

      // If OCR gave "183/165" in number, split it safely
      if (rawNumber.isNotEmpty) {
        final parts = rawNumber.split('/');
        numOnly = parts.first.trim();
        if ((setTotalStr ?? '').isEmpty && parts.length > 1) {
          setTotalStr = parts[1].trim();
        }
      } else {
        // fallback
        final n = (guess.number ?? '').trim();
        if (n.isNotEmpty) numOnly = n;
      }

      final hasSlashTotal =
          rawNumber.contains('/') && rawNumber.split('/').length > 1;

      // normalize empties to null
      if (numOnly != null && numOnly!.trim().isEmpty) numOnly = null;
      if (setTotalStr != null && setTotalStr!.trim().isEmpty)
        setTotalStr = null;

      // ignore: avoid_print
      print(
        '🔍 OCR DEBUG → name=$name, rawNumber=$rawNumber, numOnly=$numOnly, setTotal=$setTotalStr, hp=$hp, stage=$stage',
      );

      final lowerName = name.toLowerCase().trim();

      // If OCR "name" is just a label/category (common on Trainer/Energy cards), ignore it.
      final looksLikeLabel =
          lowerName == 'trainer' ||
          lowerName == 'traner' ||
          lowerName == 'energy' ||
          lowerName == 'pokemon';

      // If it looks like a label, don't use name at all.
      final usedName = looksLikeLabel ? '' : name;

      // ✅ Only trust setTotal if it came from a real "233/236" slash.
      final String? usedSetTotalStr = hasSlashTotal ? setTotalStr : null;

      // If we have literally nothing useful, go manual
      final hasSomeInput =
          usedName.trim().isNotEmpty ||
          (numOnly != null && numOnly!.isNotEmpty);

      if (!hasSomeInput) {
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ManualSearchScreen()),
        );
        return;
      }

      try {
        final api = PokemonTcgApi();

        final pick = await api.searchCardsReliable(
          name: usedName,
          number: numOnly,
          setTotal: usedSetTotalStr,
        );

        if (!mounted) return;

        // Label-only means: name is useless label, so we searched only by number.
        final isLabelOnlySearch =
            looksLikeLabel && usedName.trim().isEmpty && (numOnly != null);

        var results = pick.candidates;

        // If label-only, filter to Trainer/Energy where possible to reduce junk.
        if (isLabelOnlySearch) {
          // If the label was trainer-like, prefer Trainers.
          final wantsTrainer =
              (lowerName == 'trainer' || lowerName == 'traner');
          final wantsEnergy = (lowerName == 'energy');

          if (wantsTrainer) {
            final trainerOnly = results
                .where((c) => (c.supertype ?? '').toLowerCase() == 'trainer')
                .toList();
            if (trainerOnly.isNotEmpty) results = trainerOnly;
          } else if (wantsEnergy) {
            final energyOnly = results
                .where((c) => (c.supertype ?? '').toLowerCase() == 'energy')
                .toList();
            if (energyOnly.isNotEmpty) results = energyOnly;
          }

          // For label-only searches, NEVER auto-pick best (prevents wrong instant jump)
          if (results.isEmpty) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const ManualSearchScreen()),
            );
            return;
          }

          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => SearchResultsScreen(
                type: CardType.pokemon,
                name: '',
                set: null,
                number: numOnly,
              ),
            ),
          );
          return;
        }

        // Normal Pokémon scans: if we have a best match, go straight to details
        if (pick.best != null) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => PokemonCardDetailsScreen(card: pick.best!),
            ),
          );
          return;
        }

        if (results.isEmpty) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const ManualSearchScreen()),
          );
          return;
        }

        if (results.length == 1) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => PokemonCardDetailsScreen(card: results[0]),
            ),
          );
          return;
        }

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => SearchResultsScreen(
              type: CardType.pokemon,
              name: usedName,
              set: null,
              number: numOnly,
            ),
          ),
        );
      } catch (e, st) {
        // ignore: avoid_print
        print('❌ TCG search failed: $e');
        // ignore: avoid_print
        print(st);

        if (!mounted) return;

        final msg = e.toString();
        final isDns =
            msg.contains('Failed host lookup') ||
            msg.contains('No address associated with hostname');

        if (isDns) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'No internet/DNS on this device. Check Wi-Fi and try again.',
              ),
            ),
          );
        }

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ManualSearchScreen()),
        );
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('❌ OCR failed: $e');
      // ignore: avoid_print
      print(st);

      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = '$e';
      });

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ManualSearchScreen()),
      );
    }
  }

  void _manualSearch() {
    final name = _nameCtrl.text.trim();
    final number = _numCtrl.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Type the Pokémon name, then Search.')),
      );
      return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => SearchResultsScreen(
          type: CardType.pokemon,
          name: name,
          set: null,
          number: number.isEmpty ? null : number,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recognizing...')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _loading
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Reading card text...'),
                  ],
                ),
              )
            : Column(
                children: [
                  if (_error != null) ...[
                    Text('$_error', style: const TextStyle(color: Colors.red)),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _numCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Card number (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _runAll,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry OCR'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _manualSearch,
                          icon: const Icon(Icons.search),
                          label: const Text('Search'),
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

class ConditionGuideScreen extends StatelessWidget {
  final int initialGrade;
  const ConditionGuideScreen({super.key, required this.initialGrade});

  String _label(int g) {
    if (g >= 10) return "Gem Mint (PSA 10)";
    if (g == 9) return "Mint (PSA 9)";
    if (g == 8) return "Near Mint–Mint (PSA 8)";
    if (g == 7) return "Near Mint (PSA 7)";
    if (g == 6) return "Excellent–Mint (PSA 6)";
    if (g == 5) return "Excellent (PSA 5)";
    if (g == 4) return "Very Good–Excellent (PSA 4)";
    if (g == 3) return "Very Good (PSA 3)";
    if (g == 2) return "Good (PSA 2)";
    return "Poor (PSA 1)";
  }

  String _desc(int g) {
    if (g >= 10) return "Perfect corners, edges, surface, and centering.";
    if (g == 9) return "Almost flawless, tiny imperfections.";
    if (g == 8) return "Minor whitening or surface wear.";
    if (g == 7) return "Noticeable whitening, minor scratches/print lines.";
    if (g == 6)
      return "Moderate wear, small crease possible, still presentable.";
    if (g == 5)
      return "Clear wear, whitening, surface scratches, possible small crease.";
    if (g == 4) return "Heavy wear, corner rounding, surface damage.";
    if (g == 3)
      return "Major wear, creases, edge chipping, strong surface issues.";
    if (g == 2) return "Severe wear/damage, multiple creases.";
    return "Very damaged (tears, heavy creasing, ink, etc.).";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Grading Guide")),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: 10,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final g = 10 - i;
          final selected = g == initialGrade;

          return Card(
            child: ListTile(
              title: Text("Grade $g • ${_label(g)}"),
              subtitle: Text(_desc(g)),
              trailing: selected ? const Icon(Icons.check_circle) : null,
            ),
          );
        },
      ),
    );
  }
}
