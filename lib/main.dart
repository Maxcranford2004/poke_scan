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
import 'card_showcase_screen.dart';
import 'package:flutter/services.dart';

List<CameraDescription> gCameras = const [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await PokemonTcgApi.initCache();
  collectionStore.seedDemoIfEmpty();

  final api = PokemonTcgApi();
  await api.debugHealthCheck();

  final cameras = await availableCameras();
  gCameras = cameras;
  runApp(CardScanApp(cameras: cameras));
}

enum CardType { pokemon, sports }

extension CardTypeLabel on CardType {
  String get label => this == CardType.pokemon ? 'Pokémon' : 'Sports';
}

// Shared grayscale matrix (keep for Pokédex + missing tiles ONLY)
const List<double> kGreyMatrix = <double>[
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
  final String? expectedSetId;
  final int? expectedSlot;

  const ScanScreen({
    super.key,
    required this.cameras,
    this.expectedSetId,
    this.expectedSlot,
  });

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
        builder: (_) => RecognizingScreen(
          photoPath: file.path,
          expectedSetId: widget.expectedSetId,
          expectedSlot: widget.expectedSlot,
        ),
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
        builder: (_) => RecognizingScreen(
          photoPath: file.path,
          expectedSetId: widget.expectedSetId,
          expectedSlot: widget.expectedSlot,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.expectedSetId != null && widget.expectedSlot != null
              ? 'Scan #${widget.expectedSlot} (${widget.expectedSetId})'
              : 'Scan',
        ),
      ),
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
          number: number.isEmpty ? null : number,
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

/* ---------------------------- SEARCH RESULTS ---------------------------- */

class SearchResultsScreen extends StatefulWidget {
  final CardType type;
  final String name;
  final String? set;
  final String? number;

  // prefetched from scanner (worker candidates)
  final List<PokemonCardResult>? prefetched;

  const SearchResultsScreen({
    super.key,
    required this.type,
    required this.name,
    this.set,
    this.number,
    this.prefetched,
  });

  @override
  State<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _SearchResultsScreenState extends State<SearchResultsScreen> {
  bool _loading = true;
  bool _updating = false;
  String? _error;
  List<PokemonCardResult> _results = const [];

  @override
  void initState() {
    super.initState();

    final pre = widget.prefetched;
    if (pre != null && pre.isNotEmpty) {
      _results = pre;
      _loading = false;
      _updating = false;
      _error = null;

      // If scanner only found one, auto-open details.
      if (pre.length == 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final c = pre.first;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => PokemonCardDetailsScreen(card: c),
            ),
          );
        });
      }
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _updating = false;
      _error = null;
    });

    final api = PokemonTcgApi();

    // cached first
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
          _loading = false;
          _updating = true;
        });
      }
    } catch (_) {}

    // live refresh
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

                  // ✅ IMPORTANT: Search results thumbnails are ALWAYS FULL COLOR.
                  // (Greyscale is only for Pokédex/missing slots.)
                  return Card(
                    child: ListTile(
                      leading: c.imageSmall.isEmpty
                          ? const Icon(Icons.image_not_supported)
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(
                                c.imageSmall,
                                width: 56,
                                height: 56,
                                fit: BoxFit.cover,
                              ),
                            ),
                      title: Text('${c.name} • ${c.setName}'),
                      subtitle: Text('#${c.number}\nTap for details'),
                      isThreeLine: true,
                      trailing: IconButton(
                        icon: Icon(
                          saved ? Icons.check_circle : Icons.add_circle,
                        ),
                        onPressed: () async {
                          final already = collectionStore.containsCardId(c.id);
                          if (already) return;

                          collectionStore.addCard(c);
                          setState(() {});

                          await showPokedexRegistered(context, card: c);
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

  List<SetSummary> _filteredSets(List<SetSummary> sets) {
    if (_query.isEmpty) return sets;
    return sets.where((s) {
      final hay = '${s.setName} ${s.setId ?? ''}'.toLowerCase();
      return hay.contains(_query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final sets = _filteredSets(collectionStore.getSetSummaries());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Collection'),
        actions: [
          IconButton(
            tooltip: 'Clear (testing)',
            onPressed: collectionStore.count == 0
                ? null
                : () => collectionStore.clear(),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search sets...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => _searchCtrl.clear(),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          if (collectionStore.count == 0)
            const Expanded(
              child: Center(
                child: Text(
                  'No cards saved yet.\nScan a card to start your first set.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                itemCount: sets.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final s = sets[i];
                  final total = s.printedTotal ?? 0;
                  final progressText = (total > 0)
                      ? '${s.ownedUniqueSlots} / $total'
                      : '${s.ownedInstances} cards';

                  return Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            settings: const RouteSettings(name: 'set_pokedex'),
                            builder: (_) => SetPokedexScreen(
                              setKey: s.setKey,
                              setName: s.setName,
                              printedTotal: s.printedTotal,
                            ),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    s.setName,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Text(
                                  progressText,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(99),
                                    child: LinearProgressIndicator(
                                      value:
                                          (s.printedTotal == null ||
                                              s.printedTotal == 0)
                                          ? null
                                          : s.progress,
                                      minHeight: 10,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              (s.printedTotal == null || s.printedTotal == 0)
                                  ? 'Tap to view your cards'
                                  : 'Tap to fill your Pokédex',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withOpacity(0.7),
                              ),
                            ),
                          ],
                        ),
                      ),
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

/// ------------------------- SET POKEDEX SCREEN -------------------------

class SetPokedexScreen extends StatefulWidget {
  final String setKey;
  final String setName;
  final int? printedTotal;

  const SetPokedexScreen({
    super.key,
    required this.setKey,
    required this.setName,
    required this.printedTotal,
  });

  @override
  State<SetPokedexScreen> createState() => _SetPokedexScreenState();
}

class _SetPokedexScreenState extends State<SetPokedexScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  CollectedEvent? _celebrate;
  bool _showCelebrate = false;

  void _onCollectedEvent() {
    final e = collectionStore.lastCollected.value;
    if (e == null) return;
    if (e.setKey != widget.setKey) return;

    setState(() {
      _celebrate = e;
      _showCelebrate = true;
    });

    Future.delayed(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _showCelebrate = false);
    });
  }

  @override
  void initState() {
    super.initState();

    collectionStore.addListener(_onChanged);
    collectionStore.lastCollected.addListener(_onCollectedEvent);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      collectionStore.ensureSetIndexLoaded(
        setKey: widget.setKey,
        setId: widget.setKey,
      );
    });

    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    collectionStore.removeListener(_onChanged);
    collectionStore.lastCollected.removeListener(_onCollectedEvent);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  int? _parseInt(String s) => int.tryParse(s);

  @override
  Widget build(BuildContext context) {
    final ownedMap = collectionStore.getOwnedSlotMapForSet(widget.setKey);
    final previewMap = collectionStore.getPreviewSlotMapForSet(widget.setKey);

    final maxOwned = ownedMap.isEmpty
        ? 0
        : ownedMap.keys.reduce((a, b) => a > b ? a : b);

    final total = (() {
      final printed = widget.printedTotal ?? 0;
      final computed = printed > maxOwned ? printed : maxOwned;
      if (computed > 500) return 500;
      return computed;
    })();

    final progressTotal = widget.printedTotal ?? total;
    final ownedCount = collectionStore.registeredCountForSet(widget.setKey);
    final showGrid = total >= 10 && total <= 500;

    return Scaffold(
      appBar: AppBar(title: Text(widget.setName)),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                child: TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: showGrid
                        ? 'Search # or card name...'
                        : 'Search your cards...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => _searchCtrl.clear(),
                          ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        showGrid
                            ? 'Progress: $ownedCount / $progressTotal'
                            : 'Cards in set: ${ownedMap.length}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (showGrid)
                      SizedBox(
                        width: 140,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            value: progressTotal == 0
                                ? 0
                                : (ownedCount / progressTotal).clamp(0.0, 1.0),
                            minHeight: 10,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: showGrid
                    ? _buildPokedexGrid(context, total, ownedMap, previewMap)
                    : _buildOwnedList(context, ownedMap),
              ),
            ],
          ),
          if (_showCelebrate && _celebrate != null)
            Positioned.fill(child: _CollectedOverlay(event: _celebrate!)),
        ],
      ),
    );
  }

  Widget _buildPokedexGrid(
    BuildContext context,
    int total,
    Map<int, PokemonCardResult> ownedMap,
    Map<int, PreviewCard> previewMap,
  ) {
    final qNum = _parseInt(_query);

    final slots = (qNum != null && qNum >= 1 && qNum <= total)
        ? <int>[qNum]
        : List<int>.generate(total, (i) => i + 1);

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.72,
      ),
      itemCount: slots.length,
      itemBuilder: (context, idx) {
        final slot = slots[idx];
        final owned = ownedMap[slot];
        final preview = previewMap[slot];

        if (owned != null) {
          return _OwnedSlotTile(
            slot: slot,
            card: owned,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CardShowcaseScreen(card: owned),
                ),
              );
            },
          );
        }

        return _MissingSlotTile(
          slot: slot,
          previewImageUrl: preview?.imageSmall,
          previewName: preview?.name,
          onTap: () => _showSlotSheet(slot: slot, preview: preview),
        );
      },
    );
  }

  void _showSlotSheet({required int slot, required PreviewCard? preview}) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final title = preview == null
            ? 'Card #$slot not registered yet'
            : '${preview.name}  •  #$slot';

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Center(
                child: SizedBox(
                  height: 150,
                  child: AspectRatio(
                    aspectRatio: 0.72,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: preview != null && preview.imageSmall.isNotEmpty
                          ? ColorFiltered(
                              colorFilter: const ColorFilter.matrix(
                                kGreyMatrix,
                              ),
                              child: Image.network(
                                preview.imageSmall,
                                fit: BoxFit.cover,
                              ),
                            )
                          : Container(
                              color: const Color(0xFF1F1F1F),
                              child: Stack(
                                children: [
                                  const Center(
                                    child: Icon(Icons.style, size: 46),
                                  ),
                                  Positioned(
                                    left: 10,
                                    top: 10,
                                    child: Text(
                                      '#$slot',
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                preview == null
                    ? "Unknown card (preview not loaded yet)."
                    : "This is the correct card for slot #$slot. Scan it to register this slot.",
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Scan this card'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ScanScreen(
                          cameras: gCameras,
                          expectedSetId: widget.setKey,
                          expectedSlot: slot,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildOwnedList(
    BuildContext context,
    Map<int, PokemonCardResult> ownedMap,
  ) {
    final cards = ownedMap.values.toList();
    final q = _query;

    if (q.isNotEmpty) {
      cards.removeWhere(
        (c) => !('${c.name} ${c.number}'.toLowerCase().contains(q)),
      );
    }

    if (cards.isEmpty) {
      return const Center(child: Text('No cards match your search.'));
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: cards.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final c = cards[i];
        return Card(
          child: ListTile(
            leading: c.imageSmall.isEmpty
                ? const Icon(Icons.image_not_supported)
                : Image.network(c.imageSmall, width: 56, fit: BoxFit.cover),
            title: Text(c.name),
            subtitle: Text('#${c.number}'),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => CardShowcaseScreen(card: c)),
              );
            },
          ),
        );
      },
    );
  }
}

class _CollectedOverlay extends StatefulWidget {
  final CollectedEvent event;
  const _CollectedOverlay({required this.event});

  @override
  State<_CollectedOverlay> createState() => _CollectedOverlayState();
}

class _CollectedOverlayState extends State<_CollectedOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOut,
  );
  late final Animation<double> _scale = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutBack,
  );
  late final Animation<double> _registeredIn = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.35, 1.0, curve: Curves.easeOutBack),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.event;

    return IgnorePointer(
      child: Container(
        color: Colors.black.withOpacity(0.55),
        child: Center(
          child: FadeTransition(
            opacity: _fade,
            child: ScaleTransition(
              scale: _scale,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.network(
                      e.imageUrl,
                      height: 260,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 14),
                  FadeTransition(
                    opacity: _registeredIn,
                    child: ScaleTransition(
                      scale: _registeredIn,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.25),
                          ),
                        ),
                        child: const Text(
                          'POKÉDEX UPDATED!',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.4,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'CARD #${e.slot} COLLECTED!',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    e.cardName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Missing tile supports optional grayscale preview (Pokédex only)
class _MissingSlotTile extends StatelessWidget {
  final int slot;
  final String? previewImageUrl;
  final String? previewName;
  final VoidCallback onTap;

  const _MissingSlotTile({
    required this.slot,
    required this.onTap,
    this.previewImageUrl,
    this.previewName,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final hasPreview = previewImageUrl != null && previewImageUrl!.isNotEmpty;

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Ink(
        decoration: BoxDecoration(
          color: const Color(0xFF1C1F26),
          borderRadius: BorderRadius.circular(14),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            children: [
              if (hasPreview)
                Positioned.fill(
                  child: Opacity(
                    opacity: 0.75,
                    child: ColorFiltered(
                      colorFilter: const ColorFilter.matrix(kGreyMatrix),
                      child: Image.network(previewImageUrl!, fit: BoxFit.cover),
                    ),
                  ),
                )
              else
                const Center(
                  child: Icon(Icons.style, size: 40, color: Colors.white24),
                ),
              Positioned(
                left: 8,
                top: 8,
                child: Text(
                  '$slot',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
              if (!hasPreview)
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  child: Text(
                    'Missing',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.85),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OwnedSlotTile extends StatelessWidget {
  final int slot;
  final PokemonCardResult card;
  final VoidCallback onTap;

  const _OwnedSlotTile({
    required this.slot,
    required this.card,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: card.imageSmall.isEmpty
                  ? Container(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.image_not_supported),
                    )
                  : Image.network(card.imageSmall, fit: BoxFit.cover),
            ),
          ),
          Positioned(
            left: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$slot',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
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
  final String? expectedSetId;
  final int? expectedSlot;

  const PokemonCardDetailsScreen({
    super.key,
    required this.card,
    this.expectedSetId,
    this.expectedSlot,
  });

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
    _fullFuture = PokemonTcgApi().fetchCardById(widget.card.id);

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
    final multiplier = _grade / 10.0;
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

  bool _slotAcceptsCard({
    required PokemonCardResult card,
    required String expectedSetId,
    required int expectedSlot,
  }) {
    final cardSet = card.setId.trim();
    final cardNum = int.tryParse(card.number.replaceAll(RegExp(r'[^0-9]'), ''));
    return cardSet == expectedSetId && cardNum == expectedSlot;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PokemonCardResult?>(
      future: _fullFuture,
      builder: (context, snap) {
        final loading = snap.connectionState != ConnectionState.done;
        final pricingError = snap.hasError;

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
                  icon: Icon(saved ? Icons.check : Icons.add),
                  label: Text(saved ? 'Saved' : 'Save to My Collection'),
                  onPressed: saved
                      ? null
                      : () async {
                          final expectedSetId = widget.expectedSetId;
                          final expectedSlot = widget.expectedSlot;

                          if (expectedSetId != null && expectedSlot != null) {
                            final ok = _slotAcceptsCard(
                              card: card,
                              expectedSetId: expectedSetId,
                              expectedSlot: expectedSlot,
                            );
                            if (!ok) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Wrong card for this Pokédex slot. Please rescan.',
                                  ),
                                ),
                              );
                              return;
                            }
                          }

                          collectionStore.addCard(card);

                          if (expectedSetId != null && expectedSlot != null) {
                            collectionStore.emitCollected(
                              CollectedEvent(
                                setKey: expectedSetId,
                                slot: expectedSlot,
                                cardName: card.name,
                                imageUrl: card.imageLarge.isNotEmpty
                                    ? card.imageLarge
                                    : card.imageSmall,
                              ),
                            );
                          }

                          if (mounted) setState(() {});

                          if (mounted) {
                            await showPokedexRegistered(
                              context,
                              card: card,
                              slot: expectedSlot,
                              setNameOverride: card.setName,
                            );
                          }

                          final fromPokedex =
                              widget.expectedSetId != null &&
                              widget.expectedSlot != null;
                          if (fromPokedex && mounted) {
                            Navigator.popUntil(
                              context,
                              (route) => route.settings.name == 'set_pokedex',
                            );
                          }
                        },
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
                  children: card.finishes.keys
                      .map(
                        (k) => ChoiceChip(
                          onSelected: saved
                              ? null
                              : (_) => setState(() => _selectedFinish = k),
                          label: Text(k),
                          selected: k == finish,
                        ),
                      )
                      .toList()
                      .cast<Widget>(),
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

/* ----------------------------- RECOGNIZING ----------------------------- */

class RecognizingScreen extends StatefulWidget {
  final String photoPath;

  /// If provided, this scan is "slot-locked" (Pokédex flow)
  final String? expectedSetId;
  final int? expectedSlot;

  const RecognizingScreen({
    super.key,
    required this.photoPath,
    this.expectedSetId,
    this.expectedSlot,
  });

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

  /* ----------------------------- helpers ----------------------------- */

  bool _isLabelOnlyName(String name) {
    final l = name.trim().toLowerCase();
    return l == 'trainer' || l == 'traner' || l == 'pokemon' || l == 'energy';
  }

  bool _matchesExpected(PokemonCardResult card) {
    final expectedSetId = widget.expectedSetId;
    final expectedSlot = widget.expectedSlot;
    if (expectedSetId == null || expectedSlot == null) return true;

    final cardSet = card.setId.trim();
    final cardNum = int.tryParse(card.number.replaceAll(RegExp(r'[^0-9]'), ''));
    return cardSet == expectedSetId && cardNum == expectedSlot;
  }

  bool _hasLetters(String s) => RegExp(r'[A-Za-z]').hasMatch(s);

  String _flattenRaw(String raw) {
    return raw
        .replaceAll('\n', ' ')
        .replaceAll(RegExp(r'[Il]'), '1')
        .replaceAll('O', '0');
  }

  ({String num, String total})? _extractCollectorFraction(String flat) {
    final m = RegExp(
      r'(?<!\d)(\d{1,4})\s*[/\|\-–—]\s*(\d{2,4})(?!\d)',
    ).firstMatch(flat);
    if (m == null) return null;

    final n = (m.group(1) ?? '').trim();
    final t = (m.group(2) ?? '').trim();
    if (n.isEmpty || t.isEmpty) return null;
    return (num: n, total: t);
  }

  /* ----------------------------- main flow ----------------------------- */

  Future<void> _runAll() async {
    if (!mounted) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final guess = await PokemonOcr.recognizeFromImagePath(widget.photoPath);

      final rawText = guess.rawText ?? '';
      final flat = _flattenRaw(rawText);
      final hp = guess.hp;

      // ---------- NAME ----------
      final rawName = (guess.name ?? '').trim();
      final usedName = _isLabelOnlyName(rawName)
          ? (PokemonOcr.extractTrainerTitleFromRaw(rawText) ?? '')
          : rawName;

      // ---------- NUMBER / TOTAL ----------
      final rawNumber = (guess.number ?? '').trim();
      String? numOnly;
      String setTotalStr = (guess.setTotal ?? '').trim();

      // Prefer OCR-provided number first
      if (rawNumber.isNotEmpty) {
        if (rawNumber.contains('/')) {
          final parts = rawNumber.split('/');
          numOnly = parts.first.trim();
          if (setTotalStr.isEmpty && parts.length > 1) {
            setTotalStr = parts[1].trim();
          }
        } else {
          numOnly = rawNumber.trim();
        }
      }

      if (numOnly != null && numOnly!.trim().isEmpty) numOnly = null;
      if (setTotalStr.trim().isEmpty) setTotalStr = '';

      // Prefer explicit collector fraction from raw (e.g., 245/198)
      final frac = flat.isNotEmpty ? _extractCollectorFraction(flat) : null;
      if (frac != null) {
        final current = (numOnly ?? '').trim();
        if (current.isEmpty || _hasLetters(current)) {
          numOnly = frac.num;
        }
        if (setTotalStr.trim().isEmpty) setTotalStr = frac.total;
      }

      if (numOnly != null && numOnly!.trim().isEmpty) numOnly = null;
      if (setTotalStr.trim().isEmpty) setTotalStr = '';

      // ---------- SVP PROMO DETECTION ----------
      final svpDigitsFromNumber = PokemonOcr.extractSvpNumberFromRaw(rawText);
      // This method must exist in pokemon_ocr.dart. If you haven't added it yet,
      // temporarily change the next line to: `final int? svpDigitsFromSignature = null;`
      final svpDigitsFromSignature = PokemonOcr.detectSvpSlotBySignature(
        rawText,
      );
      final int? svpDigits = svpDigitsFromNumber ?? svpDigitsFromSignature;

      // ignore: avoid_print
      print(
        '🧷 SVP DEBUG → fromNumber=$svpDigitsFromNumber fromSignature=$svpDigitsFromSignature chosen=$svpDigits',
      );

      final bool isSvpDetected = svpDigits != null;
      final bool isSvpFlow = widget.expectedSetId == 'svp' || isSvpDetected;

      if (isSvpFlow && svpDigits != null) {
        numOnly = 'SVP$svpDigits'; // -> cleaned later in API to "SVP51"
        if (setTotalStr.isEmpty) setTotalStr = '102';
      }

      // ---------- PROMO CODE GUARD (non-SVP) ----------
      // Drop alphanumeric numbers (like SWSH105) unless SVP flow.
      if (!isSvpFlow && numOnly != null && _hasLetters(numOnly!)) {
        numOnly = null;
      }

      // ---------- SLOT LOCKING ----------
      final bool isSlotLocked =
          widget.expectedSetId != null && widget.expectedSlot != null;

      final String? expectedSetId =
          (widget.expectedSetId != null &&
              widget.expectedSetId!.trim().isNotEmpty)
          ? widget.expectedSetId!.trim()
          : null;

      // IMPORTANT:
      // If slot-locked, do NOT pass expectedSlot into the worker search.
      // We validate exact slot AFTER we get a best match back.
      final int? expectedSlot = isSlotLocked ? null : widget.expectedSlot;

      // ignore: avoid_print
      print(
        '🔍 OCR DEBUG → name=$usedName, number=$numOnly, setTotal=${setTotalStr.isEmpty ? "null" : setTotalStr}, hp=$hp, expectedSetId=$expectedSetId, expectedSlot=$expectedSlot, svpDigits=$svpDigits',
      );

      // ---------- SEARCH ----------
      final api = PokemonTcgApi();
      final pick = await api.searchCardsReliable(
        name: usedName,
        number: numOnly,
        setTotal: setTotalStr,
        hp: hp,
        expectedSetId: expectedSetId,
        expectedSlot: expectedSlot,
        svpSlot: svpDigits,
      );

      if (!mounted) return;

      // ---------- BEST MATCH ----------
      if (pick.best != null) {
        if (!_matchesExpected(pick.best!)) {
          await _showWrongCardDialog(pick.best!);
          return;
        }

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => PokemonCardDetailsScreen(
              card: pick.best!,
              expectedSetId: widget.expectedSetId,
              expectedSlot: widget.expectedSlot,
            ),
          ),
        );
        return;
      }

      // ---------- SLOT-LOCK FAILURE ----------
      if (isSlotLocked) {
        setState(() {
          _error =
              'Could not confirm this is the correct card for slot #${widget.expectedSlot}. Try again.';
        });
        return;
      }

      // ---------- FALLBACK LIST ----------
      _goToResults(
        name: usedName,
        number: numOnly,
        prefetched: pick.candidates,
      );
    } catch (e, st) {
      // ignore: avoid_print
      print('❌ Recognizing failed: $e');
      // ignore: avoid_print
      print(st);

      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /* ----------------------------- navigation ----------------------------- */

  void _goToResults({
    required String name,
    String? number,
    List<PokemonCardResult>? prefetched,
  }) {
    final hasSomething =
        name.trim().isNotEmpty || (number != null && number.trim().isNotEmpty);

    if (!hasSomething) {
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
          name: name.trim(),
          set: null,
          number: (number != null && number.trim().isNotEmpty)
              ? number.trim()
              : null,
          prefetched: prefetched,
        ),
      ),
    );
  }

  Future<void> _showWrongCardDialog(PokemonCardResult found) async {
    final expectedSetId = widget.expectedSetId;
    final expectedSlot = widget.expectedSlot;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wrong card scanned'),
        content: Text(
          'You started a slot-locked scan.\n\n'
          'Expected: #$expectedSlot ($expectedSetId)\n'
          'Found: #${found.number} (${found.setId})\n'
          '${found.name}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Try again'),
          ),
        ],
      ),
    );

    if (mounted) Navigator.pop(context);
  }

  void _manualSearch() {
    final name = _nameCtrl.text.trim();
    final number = _numCtrl.text.trim();

    if (name.isEmpty && number.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Type a name or number to search.')),
      );
      return;
    }

    _goToResults(name: name, number: number);
  }

  /* ----------------------------- UI ----------------------------- */

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recognizing…')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _loading
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Reading card text…'),
                  ],
                ),
              )
            : Column(
                children: [
                  if (_error != null) ...[
                    Text(_error!, style: const TextStyle(color: Colors.red)),
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

/* ------------------------- POKEDEX REGISTERED POPUP ------------------------- */

Future<void> showPokedexRegistered(
  BuildContext context, {
  required PokemonCardResult card,
  int? slot,
  String? setNameOverride,
}) async {
  HapticFeedback.mediumImpact();

  final rootNav = Navigator.of(context, rootNavigator: true);

  Future.delayed(const Duration(milliseconds: 1150), () {
    if (rootNav.canPop()) rootNav.pop();
  });

  await showGeneralDialog(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'registered',
    barrierColor: Colors.black.withOpacity(0.55),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, __, ___) {
      final number =
          slot ?? int.tryParse(card.number.replaceAll(RegExp(r'[^0-9]'), ''));
      final subtitle =
          setNameOverride ?? (card.setName.isNotEmpty ? card.setName : '—');

      return SafeArea(
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 320,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              decoration: BoxDecoration(
                color: const Color(0xFF121826),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 30,
                    color: Colors.black.withOpacity(0.45),
                    offset: const Offset(0, 18),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      'Pokédex Registered',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: 64,
                          height: 88,
                          color: Colors.white.withOpacity(0.06),
                          child:
                              (card.imageSmall.isEmpty &&
                                  card.imageLarge.isEmpty)
                              ? const Icon(Icons.style)
                              : Image.network(
                                  card.imageSmall.isNotEmpty
                                      ? card.imageSmall
                                      : card.imageLarge,
                                  fit: BoxFit.cover,
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              card.name.isEmpty ? 'Registered' : card.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              number == null
                                  ? subtitle
                                  : '$subtitle • #$number',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.78),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.check_circle, size: 28),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (_, anim, __, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
      return FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween(begin: 0.92, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}
