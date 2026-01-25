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
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final appDir = await getApplicationDocumentsDirectory();
  await Hive.initFlutter(appDir.path);
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
        brightness: Brightness.dark,

        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFEF4444),
          onPrimary: Color(0xFFFFFFFF),
          secondary: Color(0xFFF97316),
          onSecondary: Color(0xFFFFFFFF),
          background: Color(0xFF0B0B10),
          onBackground: Color(0xFFFFFFFF),
          surface: Color(0xFF15151D),
          onSurface: Color(0xFFFFFFFF),
          surfaceVariant: Color(0xFF1D1D27),
          onSurfaceVariant: Color(0xFFE5E7EB),
          outline: Color(0xFF2A2A35),
          outlineVariant: Color(0xFF23232D),
        ),

        scaffoldBackgroundColor: const Color(0xFF0B0B10),

        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B0B10),
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
        ),

        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFF0B0B10),
          elevation: 0,
          indicatorColor: const Color(0x33EF4444),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return TextStyle(
              color: selected ? Colors.white : const Color(0xFF9CA3AF),
              fontWeight: FontWeight.w600,
            );
          }),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return IconThemeData(
              color: selected ? Colors.white : const Color(0xFF9CA3AF),
            );
          }),
        ),

        cardTheme: CardThemeData(
          color: const Color(0xFF15151D),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFF23232D)),
          ),
        ),

        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF15151D),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
          labelStyle: const TextStyle(color: Color(0xFFE5E7EB)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(width: 2, color: Color(0xFFEF4444)),
          ),
        ),

        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFEF4444),
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),

        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: const BorderSide(color: Color(0xFF23232D)),
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
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
  late final PageController _pageCtrl;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      HomeScreen(cameras: widget.cameras),
      const CollectionScreen(),
      const SettingsScreen(),
    ];

    return Scaffold(
      body: PageView(
        controller: _pageCtrl,
        onPageChanged: (i) => setState(() => _index = i),
        children: tabs,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          setState(() => _index = i);
          _pageCtrl.animateToPage(
            i,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          );
        },
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
  final _setTotalController = TextEditingController();
  final _hpController = TextEditingController();

  String? _stage;

  @override
  void dispose() {
    _nameController.dispose();
    _setController.dispose();
    _numberController.dispose();
    _setTotalController.dispose();
    _hpController.dispose();
    super.dispose();
  }

  void _search() {
    final name = _nameController.text.trim();
    final setName = _setController.text.trim();
    final numberRaw = _numberController.text.trim();
    final setTotalRaw = _setTotalController.text.trim();
    final hp = int.tryParse(_hpController.text.trim());
    final stage = _stage;

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a name/player/Pokémon to search.')),
      );
      return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => SearchResultsScreen(
          type: _type,
          name: name,
          set: setName.isEmpty ? null : setName,
          number: numberRaw.isEmpty ? null : numberRaw,
          setTotal: setTotalRaw.isEmpty ? null : setTotalRaw,
          hp: hp,
          stage: stage,
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
          const Text('Search basics'),
          const SizedBox(height: 12),

          TextField(
            controller: _nameController,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              labelText: 'Name / Player / Pokémon',
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
              labelText: 'Set name (optional)',
              hintText: 'e.g., Scarlet & Violet, Base Set',
            ),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _numberController,
            decoration: const InputDecoration(
              labelText: 'Collector number (optional)',
              hintText: 'e.g. 65, 065, 65/202, TG05/TG30, SWSH020',
            ),
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _setTotalController,
            decoration: const InputDecoration(
              labelText: 'Set total (optional)',
              hintText: 'e.g. 202 (from 65/202)',
            ),
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
          ),

          const SizedBox(height: 12),

          TextField(
            controller: _hpController,
            decoration: const InputDecoration(
              labelText: 'HP (optional)',
              hintText: 'e.g. 60',
            ),
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
          ),

          const SizedBox(height: 12),

          DropdownButtonFormField<String?>(
            value: _stage,
            decoration: const InputDecoration(labelText: 'Stage (optional)'),
            items: const [
              DropdownMenuItem(value: null, child: Text('Unknown')),
              DropdownMenuItem(value: 'Basic', child: Text('Basic')),
              DropdownMenuItem(value: 'Stage 1', child: Text('Stage 1')),
              DropdownMenuItem(value: 'Stage 2', child: Text('Stage 2')),
            ],
            onChanged: (v) => setState(() => _stage = v),
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
  final String? setTotal;
  final int? hp;
  final String? stage;
  // Optional: path to the user's scan photo (used for thumbnails / details).
  final String? photoPath;

  // Optional: if provided, results are shown immediately without refetching.
  final List<PokemonCardResult>? initialResults;

  const SearchResultsScreen({
    super.key,
    required this.type,
    required this.name,
    this.set,
    this.number,
    this.setTotal,
    this.hp,
    this.stage,
    this.photoPath,
    this.initialResults,
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

  ({String? number, String? setTotal}) _normalizeNumberAndTotal({
    required String? numberRaw,
    required String? setTotalRaw,
  }) {
    String? number = numberRaw?.trim();
    String? setTotal = setTotalRaw?.trim();

    if (number != null && number.isEmpty) number = null;
    if (setTotal != null && setTotal.isEmpty) setTotal = null;

    if (number == null) return (number: null, setTotal: setTotal);

    // "65/202" -> number=65, setTotal=202
    final mNumeric = RegExp(
      r'^\s*0*(\d{1,4})\s*/\s*0*(\d{1,4})\s*$',
    ).firstMatch(number);
    if (mNumeric != null) {
      final left = int.parse(mNumeric.group(1)!).toString();
      final right = int.parse(mNumeric.group(2)!).toString();
      return (number: left, setTotal: setTotal ?? right);
    }

    // "TG05/TG30" -> "TG5" (keep left only)
    final mPref = RegExp(
      r'^\s*([A-Za-z]{1,6})\s*0*(\d{1,4})\s*/\s*([A-Za-z]{1,6})\s*0*(\d{1,4})\s*$',
    ).firstMatch(number);
    if (mPref != null) {
      final left =
          '${mPref.group(1)!.toUpperCase()}${int.parse(mPref.group(2)!)}';
      return (number: left, setTotal: setTotal);
    }

    // "SWSH020" -> "SWSH20"
    final mPromo = RegExp(
      r'^\s*([A-Za-z]{2,6})\s*0*(\d{1,4})\s*$',
    ).firstMatch(number);
    if (mPromo != null) {
      final n =
          '${mPromo.group(1)!.toUpperCase()}${int.parse(mPromo.group(2)!)}';
      return (number: n, setTotal: setTotal);
    }

    // Digits only "065" -> "65"
    final mDigits = RegExp(r'^\s*0*(\d{1,4})\s*$').firstMatch(number);
    if (mDigits != null) {
      return (
        number: int.parse(mDigits.group(1)!).toString(),
        setTotal: setTotal,
      );
    }

    return (number: number, setTotal: setTotal);
  }

  List<PokemonCardResult> _applyLocalFilters(List<PokemonCardResult> input) {
    if (input.isEmpty) return input;

    var out = input;

    // ---------- Number (soft) ----------
    final wantNumRaw = (widget.number ?? '').trim();
    final wantTotalRaw = (widget.setTotal ?? '').trim();

    if (wantNumRaw.isNotEmpty) {
      String norm(String s) => s.trim().toUpperCase();

      final wantNum = norm(wantNumRaw);
      final wantTotal = wantTotalRaw.isEmpty ? null : norm(wantTotalRaw);

      String? wantFraction;
      if (wantTotal != null && wantTotal.isNotEmpty && !wantNum.contains('/')) {
        wantFraction = '$wantNum/$wantTotal';
      }

      final filtered = out.where((c) {
        final cn = norm(c.number);
        if (cn == wantNum) return true;
        if (wantFraction != null && cn == wantFraction) return true;

        // If API stored fraction but we only have numerator
        if (!wantNum.contains('/') && cn.contains('/')) {
          final left = cn.split('/').first;
          if (left == wantNum) return true;
        }
        return false;
      }).toList();

      if (filtered.isNotEmpty) out = filtered;
    }

    // ---------- Set total (soft) ----------
    final st = int.tryParse((widget.setTotal ?? '').trim());
    if (st != null) {
      final filtered = out.where((c) => c.setPrintedTotal == st).toList();
      if (filtered.isNotEmpty) out = filtered;
    }

    // ---------- HP (soft) ----------
    if (widget.hp != null) {
      final wantHp = widget.hp!;
      final filtered = out.where((c) => c.hp == wantHp).toList();
      if (filtered.isNotEmpty) out = filtered;
    }

    // ---------- Stage (soft + GX-safe) ----------
    final stage = (widget.stage ?? '').trim();
    if (stage.isNotEmpty) {
      final want = stage.toLowerCase().replaceAll(' ', '');

      bool matchesStage(PokemonCardResult c) {
        for (final s in c.subtypes) {
          final norm = s.toLowerCase().replaceAll(' ', '');
          if (norm == want) return true;
        }
        return false;
      }

      final filtered = out.where(matchesStage).toList();
      if (filtered.isNotEmpty) out = filtered;
    }

    // Never wipe results if we had something
    return out.isEmpty ? input : out;
  }

  @override
  void initState() {
    super.initState();

    final initial = widget.initialResults;
    if (initial != null && initial.isNotEmpty) {
      _results = _applyLocalFilters(initial);
      _loading = false;
      _updating = false;
      _error = null;
      return;
    }

    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _updating = false;
      _error = null;
    });

    final api = PokemonTcgApi();
    final norm = _normalizeNumberAndTotal(
      numberRaw: widget.number,
      setTotalRaw: widget.setTotal,
    );

    final nNumber = norm.number;
    final nSetTotal = norm.setTotal;

    // 1) Cache first
    try {
      final cached = await api.getCachedSearch(
        name: widget.name,
        set: widget.set,
        number: nNumber,
        setTotal: nSetTotal,
      );

      if (!mounted) return;

      if (cached.isNotEmpty) {
        setState(() {
          _results = _applyLocalFilters(cached);
          _loading = false;
          _updating = true;
        });
      }
    } catch (_) {
      // ignore cache errors
    }

    // 2) Live search with fallbacks
    try {
      print(
        '🛰️ SEARCH → name="${widget.name}" set="${widget.set}" '
        'number="$nNumber" setTotal="$nSetTotal" hp=${widget.hp} stage=${widget.stage}',
      );

      // Pass 1: name + number (if any)
      var live = await api.refreshSearch(
        name: widget.name,
        set: widget.set,
        number: nNumber,
        setTotal: nSetTotal,
      );

      // Pass 2: if we have total and number is numeric, try "num/total"
      if (live.isEmpty &&
          nNumber != null &&
          nSetTotal != null &&
          nNumber.isNotEmpty &&
          nSetTotal.isNotEmpty &&
          !nNumber.contains('/') &&
          RegExp(r'^\d{1,4}$').hasMatch(nNumber)) {
        final frac = '$nNumber/$nSetTotal';
        print('🧪 fallback: number as fraction "$frac"');

        live = await api.refreshSearch(
          name: widget.name,
          set: widget.set,
          number: frac,
          setTotal: null,
        );
      }

      // Pass 3: strip "ex" and retry (helps Charizard ex)
      if (live.isEmpty &&
          RegExp(r'\bex\b', caseSensitive: false).hasMatch(widget.name)) {
        final baseName = widget.name
            .replaceAll(RegExp(r'\bex\b', caseSensitive: false), '')
            .trim();

        if (baseName.isNotEmpty) {
          print('🧪 fallback: base name "$baseName"');
          live = await api.refreshSearch(
            name: baseName,
            set: widget.set,
            number: nNumber,
            setTotal: nSetTotal,
          );
        }
      }

      // Pass 4: broad name-only (last resort)
      if (live.isEmpty) {
        final base = widget.name
            .replaceAll(RegExp(r'\bex\b', caseSensitive: false), '')
            .trim();
        final broad = base.isEmpty ? widget.name : base;

        print('🧪 fallback: broad name-only "$broad"');
        live = await api.refreshSearch(
          name: broad,
          set: widget.set,
          number: null,
          setTotal: null,
        );
      }

      print(
        '🧪 live=${live.length} filtered=${_applyLocalFilters(live).length} '
        'hp=${widget.hp} stage=${widget.stage}',
      );

      if (!mounted) return;

      setState(() {
        _results = _applyLocalFilters(live);
        _loading = false;
        _updating = false;
        _error = live.isEmpty ? 'No results found.' : null;
      });

      // Auto-open details if exactly one match
      if (_results.length == 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => PokemonCardDetailsScreen(card: _results.first),
            ),
          );
        });
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _updating = false;
        if (_results.isEmpty) {
          _error = e.toString();
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
                      leading:
                          (widget.photoPath != null &&
                              widget.photoPath!.isNotEmpty &&
                              File(widget.photoPath!).existsSync())
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: AspectRatio(
                                aspectRatio: 2.5 / 3.5,
                                child: Image.file(
                                  File(widget.photoPath!),
                                  fit: BoxFit.cover,
                                ),
                              ),
                            )
                          : (c.imageSmall.isEmpty
                                ? const Icon(Icons.image_not_supported)
                                : Image.network(
                                    c.imageSmall,
                                    width: 56,
                                    fit: BoxFit.cover,
                                  )),
                      title: Text('${c.name} • ${c.setName}'),
                      subtitle: Text('#${c.number}\nTap for details'),
                      isThreeLine: true,
                      trailing: IconButton(
                        icon: Icon(
                          saved ? Icons.check_circle : Icons.add_circle,
                        ),
                        onPressed: () {
                          collectionStore.addCard(
                            c,
                            localPhotoPath: widget.photoPath,
                          );
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
  final String? localPhotoPath;
  const PokemonCardDetailsScreen({
    super.key,
    required this.card,
    this.localPhotoPath,
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
                  child:
                      (widget.localPhotoPath != null &&
                          widget.localPhotoPath!.isNotEmpty &&
                          File(widget.localPhotoPath!).existsSync())
                      ? Image.file(
                          File(widget.localPhotoPath!),
                          fit: BoxFit.contain,
                        )
                      : Image.network(card.imageLarge, fit: BoxFit.contain),
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
                          collectionStore.addCard(
                            card,
                            localPhotoPath: widget.localPhotoPath,
                          );
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

  @override
  void initState() {
    super.initState();
    _runAll();
  }

  String _cleanOcrName(String raw) {
    var s = raw.replaceAll('’', "'");

    s = s.replaceAll(RegExp(r'\bB\s*S\s*I\s*C\b', caseSensitive: false), ' ');
    s = s.replaceAll(
      RegExp(
        r'\b(BASIC|BSIC|STAGE|TRAINER|ENERGY|POK[EÉ]MON)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    s = s.replaceAll(RegExp(r"[^A-Za-z0-9\s\-']"), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  String _salvageName(String s) {
    var t = s.trim();
    if (t.isEmpty) return t;

    // If OCR glued junk in front of a real name (e.g. CARYCCharizard V),
    // keep the last "CapitalizedName + optional suffix" segment.
    final m = RegExp(
      r'([A-Z][a-z]{2,}(?:\s+(?:[A-Z][a-z]{1,}|[A-Z]{1,3}|\d{1,3}))*(?:\s+(?:V|VMAX|VSTAR|EX|GX))?)$',
    ).firstMatch(t);

    if (m != null) {
      final picked = m.group(1)!.trim();
      if (picked.length >= 4) return picked;
    }
    return t;
  }

  List<PokemonCardResult> _filterCandidates({
    required List<PokemonCardResult> input,
    String? setTotal,
    int? hp,
    String? stage,
  }) {
    var out = input;

    // Filter by set total (printedTotal) if you have it
    final st = int.tryParse((setTotal ?? '').trim());
    if (st != null) {
      out = out.where((c) => c.setPrintedTotal == st).toList();
    }

    // Filter by HP if present
    if (hp != null) {
      out = out.where((c) => c.hp == hp).toList();
    }

    // Filter by stage if present (uses subtypes from API)
    if (stage != null && stage.isNotEmpty) {
      out = out
          .where(
            (c) => c.subtypes
                .map((s) => s.toLowerCase())
                .contains(stage.toLowerCase()),
          )
          .toList();
    }

    return out;
  }

  /// Keep the raw-ish number string so the confirm screen can parse:
  /// - "065/202"
  /// - "TG05/TG30"
  /// - "SWSH020"
  /// - "65"
  String? _keepCollectorString(String? raw) {
    if (raw == null) return null;
    final t = raw.trim();
    if (t.isEmpty) return null;

    // Keep only allowed characters (letters, numbers, slash)
    final cleaned = t
        .replaceAll(RegExp(r'[^A-Za-z0-9/ ]'), '')
        .replaceAll(' ', '');
    return cleaned.isEmpty ? null : cleaned;
  }

  Future<void> _runAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final guess = await PokemonOcr.recognizeFromImagePath(widget.photoPath);

      final name = _salvageName(_cleanOcrName(guess.name ?? ''));
      final numOnly = _keepCollectorString(guess.number); // String?
      final setTotalStr = (guess.setTotal ?? '').trim();
      final hp = guess.hp; // int?
      final stage = guess.stage; // String?  ("Basic", "Stage 1", "Stage 2")

      final hasNum = (numOnly != null && numOnly.isNotEmpty);
      final hasTotal = setTotalStr.isNotEmpty;

      final String? numberRaw = (hasNum && hasTotal)
          ? '${numOnly!}/$setTotalStr'
          : (hasNum ? numOnly : null);

      if (name.isEmpty) {
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) =>
                const ScanConfirmScreen(initialName: '', initialNumber: null),
          ),
        );
        return;
      }

      final api = PokemonTcgApi();
      List<PokemonCardResult> results = [];

      final pick = await api.searchCardsReliable(
        name: name,
        number: numOnly, // <-- important: use your cleaned collector string
        setTotal: setTotalStr.isEmpty ? null : setTotalStr,
        hp: hp,
        stage: stage,
      );

      results = (pick.best != null)
          ? <PokemonCardResult>[pick.best!]
          : pick.candidates;

      // If we got a confident auto-pick
      if (pick.best != null) {
        results = [pick.best!];
      } else {
        // Not confident — use top candidates (usually 3)
        results = pick.candidates;
      }

      // Optional: debug
      // print('Reliable strategy: ${pick.strategy} candidates: ${pick.candidates.length}');

      if (!mounted) return;

      // If nothing, go to confirm screen with best guess values
      if (results.isEmpty) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => ScanConfirmScreen(
              initialName: name,
              initialNumber: numberRaw,
              initialHp: guess.hp,
              initialStage: guess.stage,
            ),
          ),
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
            name: name,
            set: null,
            number: numOnly,
            setTotal: setTotalStr.isEmpty ? null : setTotalStr,
            hp: guess.hp,
            stage: guess.stage,
          ),
        ),
      );
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '$e';
      });

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => SearchResultsScreen(
            type: CardType.pokemon,
            name: '',
            set: null,
            number: null,
            setTotal: null,
            hp: null,
            stage: null,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recognizing...')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _loading
              ? const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Scanning card…'),
                  ],
                )
              : Text(_error ?? 'Done', textAlign: TextAlign.center),
        ),
      ),
    );
  }
}

class ScanConfirmScreen extends StatefulWidget {
  final String initialName;
  final String? initialNumber;
  final int? initialHp;
  final String? initialStage;

  const ScanConfirmScreen({
    super.key,
    required this.initialName,
    required this.initialNumber,
    this.initialHp,
    this.initialStage,
  });

  @override
  State<ScanConfirmScreen> createState() => _ScanConfirmScreenState();
}

class _ScanConfirmScreenState extends State<ScanConfirmScreen> {
  final _nameCtrl = TextEditingController();
  final _numCtrl = TextEditingController(); // collector number (left side)
  final _totalCtrl = TextEditingController(); // set total (right side)
  final _setCtrl = TextEditingController(); // set name
  final _hpCtrl = TextEditingController(); // HP (optional)

  String? _stage; // Basic / Stage 1 / Stage 2

  CardType _type = CardType.pokemon;

  @override
  void initState() {
    super.initState();
    _nameCtrl.text = widget.initialName;
    _applyParsedNumber(widget.initialNumber ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _numCtrl.dispose();
    _totalCtrl.dispose();
    _setCtrl.dispose();
    _hpCtrl.dispose();
    super.dispose();
  }

  /// Parses common collector formats and fills controllers.
  void _applyParsedNumber(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return;

    // 065/202 or 10/102
    final numericFraction = RegExp(r'^0*(\d{1,4})\s*/\s*0*(\d{1,4})$');
    final nf = numericFraction.firstMatch(t);
    if (nf != null) {
      _numCtrl.text = int.parse(nf.group(1)!).toString(); // 65
      _totalCtrl.text = int.parse(nf.group(2)!).toString(); // 202
      return;
    }

    // TG05/TG30, GG12/GG70 -> treat as collector number, don't force setTotal
    final prefFraction = RegExp(
      r'^([A-Za-z]{1,6})\s*0*(\d{1,4})\s*/\s*([A-Za-z]{1,6})\s*0*(\d{1,4})$',
    );
    final pf = prefFraction.firstMatch(t);
    if (pf != null) {
      _numCtrl.text =
          '${pf.group(1)!.toUpperCase()}${int.parse(pf.group(2)!)}'; // TG5
      _totalCtrl.clear();
      return;
    }

    // SWSH020, XY123
    final promo = RegExp(r'^([A-Za-z]{2,6})\s*0*(\d{1,4})$');
    final pm = promo.firstMatch(t);
    if (pm != null) {
      _numCtrl.text = '${pm.group(1)!.toUpperCase()}${int.parse(pm.group(2)!)}';
      _totalCtrl.clear();
      return;
    }

    // fallback: keep digits
    _numCtrl.text = t.replaceAll(RegExp(r'[^0-9]'), '');
  }

  /// Extracts a "collector number" string:
  /// - "65" from "065" or "065/202"
  /// - "TG5" from "TG05"
  /// - "SWSH20" from "SWSH020"
  String? _normalizeCollector(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;

    // If user typed 65/202, take left side
    final numericFraction = RegExp(r'^\s*0*(\d{1,4})\s*/\s*0*(\d{1,4})\s*$');
    final nf = numericFraction.firstMatch(t);
    if (nf != null) return int.parse(nf.group(1)!).toString();

    // Prefix + digits (TG05, SWSH020)
    final pref = RegExp(r'^\s*([A-Za-z]{1,6})\s*0*(\d{1,4})\s*$');
    final pm = pref.firstMatch(t);
    if (pm != null) {
      return '${pm.group(1)!.toUpperCase()}${int.parse(pm.group(2)!)}';
    }

    // Digits anywhere
    final d = RegExp(r'(\d{1,4})').firstMatch(t);
    return d == null ? null : int.parse(d.group(1)!).toString();
  }

  String? _normalizeSetTotal(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final m = RegExp(r'(\d{2,4})').firstMatch(t);
    return m?.group(1);
  }

  int? _normalizeHp(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final m = RegExp(r'(\d{2,3})').firstMatch(t);
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  void _search() {
    final name = _nameCtrl.text.trim();
    final collector = _normalizeCollector(_numCtrl.text);
    final setTotal = _normalizeSetTotal(_totalCtrl.text);
    final setName = _setCtrl.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a card name to search.')),
      );
      return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => SearchResultsScreen(
          type: _type,
          name: name,
          set: setName.isEmpty ? null : setName,
          number: collector,
          setTotal: setTotal,
          hp: _normalizeHp(_hpCtrl.text),
          stage: _stage,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Confirm Scan')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'We couldn’t confidently match this card.\nConfirm/edit details to search:',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),

          DropdownButtonFormField<CardType>(
            value: _type,
            decoration: const InputDecoration(labelText: 'Category'),
            items: CardType.values
                .map((t) => DropdownMenuItem(value: t, child: Text(t.label)))
                .toList(),
            onChanged: (v) => setState(() => _type = v ?? CardType.pokemon),
          ),

          const SizedBox(height: 12),

          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Name (Pokémon / Player)',
            ),
            textInputAction: TextInputAction.next,
          ),

          const SizedBox(height: 12),

          TextField(
            controller: _numCtrl,
            decoration: const InputDecoration(
              labelText: 'Collector number (optional)',
              hintText: 'e.g. 65, 065, 65/202, TG05, SWSH020',
            ),
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.next,
          ),

          const SizedBox(height: 12),

          TextField(
            controller: _totalCtrl,
            decoration: const InputDecoration(
              labelText: 'Set total (optional)',
              hintText: 'e.g. 202 (from 65/202)',
            ),
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
          ),

          const SizedBox(height: 12),

          TextField(
            controller: _hpCtrl,
            decoration: const InputDecoration(
              labelText: 'HP (optional)',
              hintText: 'e.g. 60',
            ),
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
          ),

          const SizedBox(height: 12),

          DropdownButtonFormField<String?>(
            value: _stage,
            decoration: const InputDecoration(labelText: 'Stage (optional)'),
            items: const [
              DropdownMenuItem(value: null, child: Text('Unknown')),
              DropdownMenuItem(value: 'Basic', child: Text('Basic')),
              DropdownMenuItem(value: 'Stage 1', child: Text('Stage 1')),
              DropdownMenuItem(value: 'Stage 2', child: Text('Stage 2')),
            ],
            onChanged: (v) => setState(() => _stage = v),
          ),

          const SizedBox(height: 12),

          TextField(
            controller: _setCtrl,
            decoration: const InputDecoration(
              labelText: 'Set name (optional)',
              hintText: 'e.g. Scarlet & Violet',
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _search(),
          ),

          const SizedBox(height: 18),

          SizedBox(
            height: 54,
            child: ElevatedButton.icon(
              onPressed: _search,
              icon: const Icon(Icons.search),
              label: const Text('Search'),
            ),
          ),

          const SizedBox(height: 10),

          SizedBox(
            height: 54,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.camera_alt),
              label: const Text('Rescan'),
            ),
          ),
        ],
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
