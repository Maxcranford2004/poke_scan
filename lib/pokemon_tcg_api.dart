import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:image/image.dart' as img;

import 'pokemon_models.dart';

/// Pass your key at runtime:
/// flutter run --dart-define=POKEMON_TCG_API_KEY=YOUR_KEY
const String kPokemonTcgApiKey = String.fromEnvironment(
  'POKEMON_TCG_API_KEY',
  defaultValue: '',
);

/// Your Cloudflare Worker base URL (stable)
const String kPokeTcgProxyBase = String.fromEnvironment(
  'POKE_TCG_PROXY_BASE',
  defaultValue: 'https://poke-tcg-proxy.maximocran.workers.dev',
);

/// TEMP: disable direct upstream calls (api.pokemontcg.io is unstable from clients)
const bool kDisableDirectTcgApi = false;

class ReliablePick {
  final PokemonCardResult? best;
  final List<PokemonCardResult> candidates;
  final String strategy;

  ReliablePick({
    required this.best,
    required this.candidates,
    required this.strategy,
  });
}

class TcgServiceUnavailable implements Exception {
  final String message;
  TcgServiceUnavailable(this.message);

  @override
  String toString() => message;
}

class PokemonTcgApi {
  static const String _host = 'api.pokemontcg.io';
  static const String _cardsPath = '/v2/cards';
  static const String _cacheBoxName = 'tcg_cache_v2';

  // ✅ Use ONE proxy base consistently
  static const String _proxyBase =
      'https://poke-tcg-proxy.maximocran.workers.dev';

  static Box? _cacheBox;

  // One client for consistency (direct API only)
  late final IOClient _io = _makeClient();

  IOClient _makeClient() {
    final hc = HttpClient();
    hc.findProxy = (uri) => 'DIRECT';
    hc.connectionTimeout = const Duration(seconds: 20);
    return IOClient(hc);
  }

  static Future<void> initCache() async {
    _cacheBox ??= await Hive.openBox(_cacheBoxName);
  }

  Box get _box {
    final b = _cacheBox;
    if (b == null) {
      throw StateError('PokemonTcgApi.initCache() was not called');
    }
    return b;
  }

  // ------------------- Worker helper: ensure set present -------------------

  Future<bool> ensureSetPresent(String setId) async {
    final uri = _proxyUri('/import-set-if-needed', {'setId': setId});
    try {
      final j = await _proxyGetJson(uri);
      return j['alreadyPresent'] == true;
    } catch (e) {
      // If this fails, we don't block scanning
      // ignore: avoid_print
      print('⚠️ set presence check failed: $e');
      return true;
    }
  }

  // ------------------- Headers / Proxy -------------------

  Map<String, String> _headers() {
    final h = <String, String>{
      'Accept': 'application/json',
      'User-Agent': 'poke_scan/1.0',
    };

    if (kPokemonTcgApiKey.isNotEmpty) {
      h['X-Api-Key'] = kPokemonTcgApiKey;
    }

    // ignore: avoid_print
    print(
      '🔑 keyPresent=${kPokemonTcgApiKey.isNotEmpty} keyLen=${kPokemonTcgApiKey.length}',
    );
    return h;
  }

  Uri _proxyUri(String path, Map<String, String> qp) {
    final base = Uri.parse(_proxyBase);
    return base.replace(path: path, queryParameters: qp);
  }

  Future<Map<String, dynamic>> _proxyGetJson(Uri uri) async {
    // ignore: avoid_print
    print('🌐 PROXY GET → $uri');

    const maxAttempts = 3;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final resp = await http
            .get(uri)
            .timeout(const Duration(seconds: 45)); // ✅

        final body = resp.body;
        if (resp.statusCode != 200) {
          throw Exception(
            'Proxy ${resp.statusCode}: ${body.isEmpty ? "(empty)" : body}',
          );
        }

        return jsonDecode(body) as Map<String, dynamic>;
      } on TimeoutException catch (e) {
        // ignore: avoid_print
        print('⚠️ PROXY timeout ($attempt/$maxAttempts): $e');
        if (attempt == maxAttempts) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
      } catch (e) {
        // ignore: avoid_print
        print('⚠️ PROXY error ($attempt/$maxAttempts): $e');
        if (attempt == maxAttempts) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
      }
    }

    throw StateError('unreachable');
  }

  // ------------------- Debug health check -------------------

  Future<void> debugHealthCheck() async {
    // ignore: avoid_print
    print('🧪 HEALTHCHECK START');

    final uri = _proxyUri('/health', {});
    try {
      final j = await _proxyGetJson(uri);
      // ignore: avoid_print
      print('🧪 WORKER HEALTH → $j');
    } catch (e) {
      // ignore: avoid_print
      print('🧪 WORKER HEALTH ERROR: $e');
    }

    // ignore: avoid_print
    print('🧪 HEALTHCHECK END');
  }

  // ------------------- JSON helpers -------------------

  Map<String, dynamic>? _map(dynamic v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  List<dynamic>? _list(dynamic v) => v is List ? v : null;

  // ------------------- Cleaning / normalization -------------------

  String _cleanName(String s) {
    var t = s.trim();
    if (t.isEmpty) return '';

    t = t.replaceAll('’', "'");
    t = t.replaceAll(RegExp(r"[^A-Za-z0-9\s\-']"), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();

    // Preserve Mega names when OCR glues the prefix to the Pokémon name.
    t = t.replaceAllMapped(
      RegExp(r"^(mega)([a-z][a-z'\-]{2,})$", caseSensitive: false),
      (m) => 'Mega ${m.group(2)}',
    );

    // OCR common fixes
    if (t.toLowerCase().startsWith('lvysaur')) t = 'ivysaur';
    if (t.toLowerCase().startsWith('snorlaz')) t = 'snorlax';

    // If OCR glued prefix garbage like "STAEEGengar" -> "Gengar"
    if (!t.contains(' ') && t.length > 8) {
      final m2 = RegExp(r'([A-Z][a-z]{2,})$').firstMatch(t);
      if (m2 != null) {
        final tail = m2.group(1)!;
        if (tail.length >= 4 && tail.length < t.length) t = tail;
      }
    }

    return t;
  }

  String _escapeLucene(String s) {
    return s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  }

  String? _cleanCollectorNumber(String? raw) {
    if (raw == null) return null;
    var t = raw.trim();
    if (t.isEmpty) return null;

    if (t.contains('/')) t = t.split('/').first.trim();

    // prefix+digits e.g. "SVP 051" -> "SVP51"
    final pref = RegExp(r'^([A-Za-z]{1,8})\s*0*(\d{1,4})$').firstMatch(t);
    if (pref != null) {
      final prefix = pref.group(1)!.toUpperCase();
      final num = int.parse(pref.group(2)!).toString();
      return '$prefix$num';
    }

    final digits = t.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;

    final n = int.tryParse(digits);
    if (n == null) return null;
    if (n <= 0 || n > 999) return null;

    return n.toString();
  }

  int? _parseSetTotal(String? s) {
    if (s == null) return null;
    final digits = s.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;

    final n = int.tryParse(digits);
    if (n == null) return null;

    // Prevent poison values like 90 (from damage text etc.)
    if (n < 100 || n > 400) return null;

    return n;
  }

  String _normalizeScannerName(String s) {
    final cleaned = _cleanName(s).toLowerCase().replaceAll('-', ' ');
    return cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  bool _scannerHasMarker(String name, String marker) {
    final tokens = _normalizeScannerName(name)
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toSet();
    return tokens.contains(marker);
  }

  String _scannerCoreSpeciesName(String name) {
    final tokens = _normalizeScannerName(name)
        .split(' ')
        .where((t) => t.isNotEmpty)
        .where(
          (t) => !const {
            'mega',
            'm',
            'ex',
            'gx',
            'v',
            'vmax',
            'vstar',
            'break',
            'radiant',
            'tag',
            'team',
          }.contains(t),
        )
        .toList();
    return tokens.join(' ');
  }

  int _scannerLevenshteinDistance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 0; i < a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0);
      current[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final cost = a[i] == b[j] ? 0 : 1;
        final insertion = current[j] + 1;
        final deletion = previous[j + 1] + 1;
        final substitution = previous[j] + cost;
        final bestNeighbor = deletion < substitution ? deletion : substitution;
        current[j + 1] = insertion < bestNeighbor ? insertion : bestNeighbor;
      }
      previous = current;
    }
    return previous[b.length];
  }

  double _scannerNormalizedLevenshteinSimilarity(String a, String b) {
    final aa = _scannerCoreSpeciesName(a).replaceAll(RegExp(r'[^a-z]'), '');
    final bb = _scannerCoreSpeciesName(b).replaceAll(RegExp(r'[^a-z]'), '');
    if (aa.isEmpty || bb.isEmpty) return 0;
    final maxLen = aa.length > bb.length ? aa.length : bb.length;
    if (maxLen == 0) return 0;
    final distance = _scannerLevenshteinDistance(aa, bb);
    return 1 - (distance / maxLen);
  }

  static const List<String> _scannerSpeciesDictionary = [
    'froslass',
    'yanmega',
    'venusaur',
    'camerupt',
    'gardevoir',
    'abomasnow',
    'manectric',
    'lucario',
    'absol',
    'charizard',
    'mewtwo',
    'pikachu',
    'snorlax',
    'ivysaur',
    'ninetales',
    'koffing',
  ];

  String? _scannerDirectAliasRecovery(String rawName) {
    final core = _scannerCoreSpeciesName(rawName).replaceAll(
      RegExp(r'[^a-z]'),
      '',
    );
    const aliases = <String, String>{
      'rosks': 'froslass',
      'floslass': 'froslass',
      'froks': 'froslass',
      'froslas': 'froslass',
      'dragonte': 'dragonite',
      'dragonteex': 'dragonite',
      'egrdragonte': 'dragonite',
      'megadragonte': 'dragonite',
      'dragnite': 'dragonite',
      'dragonnite': 'dragonite',
    };
    return aliases[core];
  }

  String? _recoverSpeciesFromOcrName(String rawName) {
    final aliasMatch = _scannerDirectAliasRecovery(rawName);
    if (aliasMatch != null) return aliasMatch;

    final ocrCore = _scannerCoreSpeciesName(rawName).replaceAll(
      RegExp(r'[^a-z]'),
      '',
    );
    if (ocrCore.isEmpty) return null;

    String? bestSpecies;
    double bestScore = 0;
    double secondBestScore = 0;

    for (final species in _scannerSpeciesDictionary) {
      final lev = _scannerNormalizedLevenshteinSimilarity(ocrCore, species);
      final bigram = _scannerBigramDiceSimilarity(ocrCore, species);
      final subseq = _scannerOrderedSubsequenceScore(ocrCore, species);
      final score = (lev * 0.45) + (bigram * 0.35) + (subseq * 0.20);

      if (score > bestScore) {
        secondBestScore = bestScore;
        bestScore = score;
        bestSpecies = species;
      } else if (score > secondBestScore) {
        secondBestScore = score;
      }
    }

    if (bestSpecies == null) return null;
    if (bestScore < 0.58) return null;
    if ((bestScore - secondBestScore) < 0.08) return null;
    return bestSpecies;
  }

  String _buildRecoveredScannerName({
    required String rawName,
    required String recoveredSpecies,
  }) {
    final normalized = _normalizeScannerName(rawName);
    final compact = normalized.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ').trim();
    final compactNoSpace = compact.replaceAll(' ', '');
    final startsMegaLike = compact.startsWith('meg') ||
        compact.startsWith('mgr') ||
        compact.startsWith('egr');
    final hasMegaLike = compact.contains('mega') ||
        compact.contains('m ega') ||
        compact.contains('mega evolved') ||
        compactNoSpace.contains('megaevolved') ||
        compact.contains('megar') ||
        compact.contains('egr') ||
        startsMegaLike;
    final hasEx = _scannerHasMarker(normalized, 'ex');

    final result = hasMegaLike && hasEx
        ? 'Mega $recoveredSpecies ex'
        : hasEx
            ? '$recoveredSpecies ex'
            : recoveredSpecies;

    // ignore: avoid_print
    print(
      'SCAN DEBUG [recovered-query-build] raw="$rawName" hasMegaLike=$hasMegaLike hasEx=$hasEx query="$result"',
    );

    return result;
  }

  List<String> _buildRecoveredScannerQueries({
    required String rawName,
    required String recoveredSpecies,
  }) {
    final normalized = _normalizeScannerName(rawName);
    final compactNoSpace = normalized.replaceAll(' ', '');
    final hasEx = _scannerHasMarker(normalized, 'ex');
    final megaLike = normalized.contains('mega') ||
        normalized.startsWith('meg') ||
        normalized.startsWith('mgr') ||
        normalized.startsWith('egr') ||
        normalized.contains('megar') ||
        normalized.contains('mega evolved') ||
        compactNoSpace.contains('megaevolved');

    final queries = <String>[];
    if (megaLike && hasEx) {
      queries.add('Mega $recoveredSpecies ex');
      queries.add('$recoveredSpecies ex');
    } else if (hasEx) {
      queries.add('$recoveredSpecies ex');
    } else {
      queries.add(recoveredSpecies);
    }

    final ordered = <String>[];
    final seen = <String>{};
    for (final query in queries) {
      if (seen.add(query)) {
        ordered.add(query);
      }
    }
    return ordered;
  }

  bool _scannerLooksMegaLike(String rawName) {
    final normalized = _normalizeScannerName(rawName);
    final compactNoSpace = normalized.replaceAll(' ', '');
    return normalized.contains('mega') ||
        normalized.startsWith('meg') ||
        normalized.startsWith('mgr') ||
        normalized.startsWith('egr') ||
        normalized.contains('megar') ||
        normalized.contains('mega evolved') ||
        compactNoSpace.contains('megaevolved');
  }

  int _scannerSecretTierBonus(PokemonCardResult card) {
    final rarity = (card.rarity ?? '').toLowerCase().trim();
    final digits = card.number.replaceAll(RegExp(r'[^0-9]'), '');
    final number = digits.isEmpty ? null : int.tryParse(digits);
    final total = card.setPrintedTotal;

    if (number != null && total != null && number > total) {
      if (rarity.contains('special illustration rare') ||
          rarity.contains('illustration rare')) {
        return 70;
      }
      if (rarity.contains('hyper rare') ||
          rarity.contains('secret rare') ||
          rarity.contains('gold')) {
        return 65;
      }
      return 55;
    }

    if (rarity.contains('special illustration rare') ||
        rarity.contains('illustration rare')) {
      return 45;
    }

    if (rarity.contains('ultra rare')) {
      return 18;
    }

    return 0;
  }

  int _scannerFeaturedArtBonus(PokemonCardResult card) {
    final rarity = (card.rarity ?? '').toLowerCase().trim();
    final numberDigits = card.number.replaceAll(RegExp(r'[^0-9]'), '');
    final number = numberDigits.isEmpty ? null : int.tryParse(numberDigits);
    final total = card.setPrintedTotal;

    if (number == null || total == null || number <= total) {
      return 0;
    }

    if (rarity.contains('special illustration rare') ||
        rarity.contains('illustration rare')) {
      return 85;
    }

    final overflow = number - total;
    if (overflow <= 60) return 42;
    if (overflow <= 75) return 26;
    return 8;
  }

  bool _isTrustedCollectorSource(String? source, String? rawNumber) {
    final s = (source ?? '').trim().toLowerCase();
    final raw = (rawNumber ?? '').trim().toUpperCase();

    // No usable collector number -> never trusted
    if (raw.isEmpty) return false;

    if (s == 'main' || s == 'bottom_left') return true;

    if (s == 'bottom_broad') {
      final cleanStandard =
          RegExp(r'^[0-9]{1,4}(?:/[0-9]{2,4})?$').hasMatch(raw);
      final cleanPromo = RegExp(r'^(SVP|SWSH)[0-9]{1,3}$').hasMatch(raw);
      return cleanStandard || cleanPromo;
    }

    return false;
  }

  String _scannerVariantFamilyKey(PokemonCardResult card) {
    final name = _normalizeScannerName(card.name);
    final setId = card.setId.toLowerCase().trim();
    return '$name|$setId';
  }

  bool _hasTrustedCollectorNumber(String? numberSource, String? ocrNumber) {
    final normalized = (ocrNumber ?? '').trim().toUpperCase();
    if (normalized.isEmpty) return false;
    return _isTrustedCollectorSource(numberSource, normalized);
  }

  img.Image? _cropArtWindow(img.Image src) {
    final x = (src.width * 0.08).round();
    final y = (src.height * 0.14).round();
    final w = (src.width * 0.84).round();
    final h = (src.height * 0.64).round();
    if (w <= 0 || h <= 0) return null;
    final safeX = x.clamp(0, src.width - 1);
    final safeY = y.clamp(0, src.height - 1);
    final safeW = w.clamp(1, src.width - safeX);
    final safeH = h.clamp(1, src.height - safeY);
    return img.copyCrop(src, x: safeX, y: safeY, width: safeW, height: safeH);
  }

  img.Image _toComparableGray32(img.Image src) {
    final cropped = _cropArtWindow(src) ?? src;
    final resized = img.copyResize(cropped, width: 32, height: 32);
    return img.grayscale(resized);
  }

  double _imageDiffScore(img.Image a, img.Image b) {
    var total = 0.0;
    for (var y = 0; y < 32; y++) {
      for (var x = 0; x < 32; x++) {
        final pa = a.getPixel(x, y);
        final pb = b.getPixel(x, y);
        final la = (pa.r + pa.g + pa.b) / 3.0;
        final lb = (pb.r + pb.g + pb.b) / 3.0;
        total += (la - lb).abs();
      }
    }
    return total;
  }

  Future<PokemonCardResult?> _breakVariantTieVisually({
    required String imagePath,
    required List<PokemonCardResult> candidates,
  }) async {
    try {
      final scanBytes = await File(imagePath).readAsBytes();
      final scanDecoded = img.decodeImage(scanBytes);
      if (scanDecoded == null) return null;
      final scanComparable = _toComparableGray32(scanDecoded);

      PokemonCardResult? best;
      double? bestScore;

      for (final candidate in candidates) {
        final imageUrl = candidate.imageLarge.isNotEmpty
            ? candidate.imageLarge
            : candidate.imageSmall;
        if (imageUrl.isEmpty) continue;

        try {
          final resp = await _io
              .get(Uri.parse(imageUrl), headers: _headers())
              .timeout(const Duration(seconds: 15));
          if (resp.statusCode != 200) continue;

          final decoded = img.decodeImage(resp.bodyBytes);
          if (decoded == null) continue;

          final candidateComparable = _toComparableGray32(decoded);
          final diff = _imageDiffScore(scanComparable, candidateComparable);

          if (bestScore == null || diff < bestScore) {
            bestScore = diff;
            best = candidate;
          }
        } catch (_) {
          continue;
        }
      }

      return best;
    } catch (_) {
      return null;
    }
  }

  double _scannerBigramDiceSimilarity(String a, String b) {
    String compact(String s) =>
        s.replaceAll(RegExp(r'[^a-z]'), '').trim();

    final aa = compact(a);
    final bb = compact(b);
    if (aa.isEmpty || bb.isEmpty) return 0;
    if (aa == bb) return 1;
    if (aa.length == 1 || bb.length == 1) {
      return aa == bb ? 1 : 0;
    }

    List<String> bigrams(String s) {
      final out = <String>[];
      for (var i = 0; i < s.length - 1; i++) {
        out.add(s.substring(i, i + 2));
      }
      return out;
    }

    final aCounts = <String, int>{};
    for (final gram in bigrams(aa)) {
      aCounts.update(gram, (v) => v + 1, ifAbsent: () => 1);
    }

    var overlap = 0;
    for (final gram in bigrams(bb)) {
      final count = aCounts[gram] ?? 0;
      if (count > 0) {
        overlap++;
        aCounts[gram] = count - 1;
      }
    }

    final total = (aa.length - 1) + (bb.length - 1);
    if (total <= 0) return 0;
    return (2 * overlap) / total;
  }

  double _scannerOrderedSubsequenceScore(String a, String b) {
    final aa = a.replaceAll(RegExp(r'[^a-z]'), '').trim();
    final bb = b.replaceAll(RegExp(r'[^a-z]'), '').trim();
    if (aa.isEmpty || bb.isEmpty) return 0;

    var ai = 0;
    var matched = 0;
    for (var bi = 0; bi < bb.length && ai < aa.length; bi++) {
      if (aa[ai] == bb[bi]) {
        matched++;
        ai++;
      }
    }

    final denom = aa.length > bb.length ? aa.length : bb.length;
    if (denom == 0) return 0;
    return matched / denom;
  }

  double _scannerSpeciesSimilarity(String want, String got) {
    final wantCore = _scannerCoreSpeciesName(want);
    final gotCore = _scannerCoreSpeciesName(got);
    if (wantCore.isEmpty || gotCore.isEmpty) return 0;
    if (wantCore == gotCore) return 1;
    if (wantCore.contains(gotCore) || gotCore.contains(wantCore)) return 0.92;
    return _scannerBigramDiceSimilarity(wantCore, gotCore);
  }

  int? _collectorDigits(String? raw) {
    final cleaned = _cleanCollectorNumber(raw);
    if (cleaned == null) return null;
    final digits = cleaned.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    return int.tryParse(digits);
  }

  bool _scannerNamesLookCompatible(String want, String got) {
    if (want.isEmpty || got.isEmpty) return true;
    if (want == got) return true;
    if (want.contains(got) || got.contains(want)) return true;
    if (_scannerSpeciesSimilarity(want, got) >= 0.45) return true;

    final wantTokens = want
        .split(' ')
        .where((t) => t.trim().length >= 2)
        .toSet();
    final gotTokens = got.split(' ').where((t) => t.trim().length >= 2).toSet();

    if (wantTokens.isEmpty || gotTokens.isEmpty) return true;
    final overlap = wantTokens.intersection(gotTokens).length;
    return overlap > 0;
  }

  List<String> _scannerBrowseSeedsFromRawText(String rawText) {
    final rawLines = rawText
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .take(8)
        .toList();

    const blocked = {
      'trainer',
      'energy',
      'supporter',
      'item',
      'stadium',
      'ability',
      'damage',
      'weakness',
      'resistance',
      'retreat',
      'illustrator',
      'illustration',
      'artist',
      'rule',
      'box',
      'basic',
      'stage',
      'pokemon',
      'hp',
    };

    bool isUsableLine(String cleaned) {
      final lower = cleaned.toLowerCase();
      if (lower.isEmpty) return false;
      if (RegExp(r'\d').hasMatch(cleaned)) return false;
      if (cleaned.length < 4 || cleaned.length > 28) return false;
      if (blocked.contains(lower)) return false;
      if (blocked.any(lower.contains)) return false;
      return true;
    }

    final seeds = <String>[];
    final seen = <String>{};

    void addSeed(String s) {
      final cleaned = _cleanName(s);
      if (!isUsableLine(cleaned)) return;
      if (seen.add(cleaned.toLowerCase())) {
        seeds.add(cleaned);
      }
    }

    for (final line in rawLines) {
      addSeed(line);
    }

    for (var i = 0; i < rawLines.length - 1 && i < 4; i++) {
      addSeed('${rawLines[i]} ${rawLines[i + 1]}');
    }

    return seeds;
  }

  int _scannerEvidenceScore({
    required PokemonCardResult card,
    required String ocrName,
    String? ocrNumber,
    String? numberSource,
    int? ocrPrintedTotal,
    int? ocrHp,
  }) {
    var score = 0;

    final wantNumUpper = (ocrNumber ?? '').toUpperCase();
    final cardNumUpper = card.number.toUpperCase();
    final trustedCollectorSource =
        _isTrustedCollectorSource(numberSource, ocrNumber);

    // ignore: avoid_print
    print(
      'SCAN DEBUG [collector-source] source="${numberSource ?? ''}" raw="$ocrNumber" trusted=$trustedCollectorSource',
    );
    // ignore: avoid_print
    print(
      'SCAN DEBUG [variant-bonus-gate] trustedCollectorSource=$trustedCollectorSource '
      'ocrNumber="${ocrNumber ?? ''}" numberSource="${numberSource ?? ''}"',
    );

    if (trustedCollectorSource) {
      if (wantNumUpper.isNotEmpty) {
        if (cardNumUpper == wantNumUpper) {
          score += 220;
        } else {
          final cardBaseNum = cardNumUpper.contains('/')
              ? cardNumUpper.split('/').first
              : cardNumUpper;
          if (cardBaseNum == wantNumUpper) {
            score += 180;
          }
        }
      }

      if (wantNumUpper.isNotEmpty &&
          ocrPrintedTotal != null &&
          card.number.toUpperCase().contains('/') &&
          card.number.toUpperCase().split('/').first == wantNumUpper &&
          card.setPrintedTotal == ocrPrintedTotal) {
        score += 260;
      }
    } else {
      if (wantNumUpper.isNotEmpty) {
        if (cardNumUpper == wantNumUpper) {
          score += 45;
        } else {
          final cardBaseNum = cardNumUpper.contains('/')
              ? cardNumUpper.split('/').first
              : cardNumUpper;
          if (cardBaseNum == wantNumUpper) {
            score += 30;
          }
        }
      }

      if (wantNumUpper.isNotEmpty &&
          ocrPrintedTotal != null &&
          card.number.toUpperCase().contains('/') &&
          card.number.toUpperCase().split('/').first == wantNumUpper &&
          card.setPrintedTotal == ocrPrintedTotal) {
        score += 35;
      }
    }

    final wantName = _normalizeScannerName(ocrName);
    final gotName = _normalizeScannerName(card.name);
    if (wantName.isNotEmpty) {
      final sameMega = _scannerHasMarker(wantName, 'mega') ==
          _scannerHasMarker(gotName, 'mega');
      final sameEx = _scannerHasMarker(wantName, 'ex') ==
          _scannerHasMarker(gotName, 'ex');
      final speciesSimilarity = _scannerSpeciesSimilarity(wantName, gotName);

      if (wantName == gotName) {
        score += 40;
      } else {
        final wantTokens = wantName
            .split(' ')
            .where((t) => t.trim().length >= 2)
            .toSet();
        final gotTokens = gotName
            .split(' ')
            .where((t) => t.trim().length >= 2)
            .toSet();
        final overlap = wantTokens.intersection(gotTokens).length;

        if (overlap > 0) {
          score += overlap * 8;
        } else {
          score -= 20;
        }

        if (wantName.contains(gotName) || gotName.contains(wantName)) {
          score += 12;
        }

        if (speciesSimilarity >= 0.65) {
          score += 35;
        } else if (speciesSimilarity >= 0.50) {
          score += 18;
        } else if (speciesSimilarity >= 0.34) {
          score += 7;
        } else if (speciesSimilarity < 0.25) {
          score -= 18;
        }

        if (sameMega) {
          score += _scannerHasMarker(wantName, 'mega') ? 8 : 0;
        } else {
          score -= 10;
        }

        if (sameEx) {
          score += _scannerHasMarker(wantName, 'ex') ? 6 : 0;
        } else {
          score -= 8;
        }
      }
    }

    final wantNumDigits = _collectorDigits(ocrNumber);
    final gotNumDigits = _collectorDigits(card.number);
    if (wantNumDigits != null) {
      if (gotNumDigits == wantNumDigits) {
        score += 35;
      } else if (gotNumDigits != null &&
          (gotNumDigits - wantNumDigits).abs() <= 1) {
        score += 10;
      } else {
        score -= 20;
      }
    }

    if (ocrPrintedTotal != null) {
      if (card.setPrintedTotal == ocrPrintedTotal) {
        score += 18;
      } else if (card.setPrintedTotal != null) {
        score -= 12;
      }
    }

    if (ocrHp != null) {
      if (card.hp == ocrHp) {
        score += 16;
      } else if (card.hp != null) {
        final diff = (card.hp! - ocrHp).abs();
        if (diff <= 10) {
          score += 6;
        } else if (diff >= 40) {
          score -= 10;
        }
      }
    }

    final recoveredSpecies = _recoverSpeciesFromOcrName(ocrName);
    if (recoveredSpecies != null &&
        _scannerCoreSpeciesName(card.name) == recoveredSpecies) {
      score += 120;
    }

    final wantedCore = _scannerCoreSpeciesName(ocrName);
    final candidateCore = _scannerCoreSpeciesName(card.name);
    if (wantedCore.isNotEmpty && candidateCore.isNotEmpty) {
      final similarity = _scannerNormalizedLevenshteinSimilarity(
        wantedCore,
        candidateCore,
      );
      if (similarity >= 0.86) {
        score += 85;
      } else if (similarity >= 0.76) {
        score += 55;
      } else if (similarity >= 0.68) {
        score += 28;
      }
    }

    final wantsMegaLike = _scannerLooksMegaLike(ocrName);
    final wantsExLike = _scannerHasMarker(_normalizeScannerName(ocrName), 'ex');
    final candidateNameNorm = _normalizeScannerName(card.name);
    final candidateIsMega =
        candidateNameNorm.contains('mega') ||
        candidateNameNorm.split(' ').contains('m');
    final candidateHasEx = _scannerHasMarker(candidateNameNorm, 'ex');

    if (wantsMegaLike && candidateIsMega) {
      score += 90;
    } else if (wantsMegaLike && !candidateIsMega) {
      score -= 25;
    }

    final sameRecoveredSpecies = recoveredSpecies != null &&
        candidateCore == recoveredSpecies;
    final sameFroslassFamily = candidateCore == 'froslass';
    final ocrLooksFroslass =
        _normalizeScannerName(ocrName).contains('fros') ||
        _normalizeScannerName(ocrName).contains('rosk') ||
        _normalizeScannerName(ocrName).contains('rosks') ||
        recoveredSpecies == 'froslass';

    if (sameFroslassFamily && ocrLooksFroslass) {
      if ((wantsMegaLike || wantsExLike) && candidateIsMega) {
        score += 18;
      }
      if ((wantsMegaLike || wantsExLike) && candidateHasEx) {
        score += 14;
      }

      if (wantNumDigits == 265) {
        if (gotNumDigits == 265) {
          score += trustedCollectorSource ? 180 : 115;
        } else if (gotNumDigits != null) {
          score -= 18;
        }
      }
    }

    if (trustedCollectorSource && sameRecoveredSpecies) {
      score += _scannerSecretTierBonus(card);
    }

    if (wantsMegaLike && candidateIsMega && sameRecoveredSpecies) {
      score += 20;
    }

    if (trustedCollectorSource &&
        sameRecoveredSpecies &&
        wantsMegaLike &&
        candidateIsMega) {
      score += _scannerFeaturedArtBonus(card);
    }

    return score;
  }

  void _logScannerScores({
    required String tag,
    required List<PokemonCardResult> cards,
    required String ocrName,
    String? ocrNumber,
    String? numberSource,
    int? ocrPrintedTotal,
    int? ocrHp,
  }) {
    if (cards.isEmpty) {
      // ignore: avoid_print
      print('SCAN DEBUG [$tag] candidates=0');
      return;
    }

    final scored =
        cards
            .map(
              (card) => (
                card: card,
                score: _scannerEvidenceScore(
                  card: card,
                  ocrName: ocrName,
                  ocrNumber: ocrNumber,
                  numberSource: numberSource,
                  ocrPrintedTotal: ocrPrintedTotal,
                  ocrHp: ocrHp,
                ),
              ),
            )
            .toList()
          ..sort((a, b) => b.score.compareTo(a.score));

    final top = scored.take(5).toList();
    // ignore: avoid_print
    print(
      'SCAN DEBUG [$tag] candidates=${cards.length} '
      'ocrName="$ocrName" normalized="${_normalizeScannerName(ocrName)}" '
      'ocrNumber="${ocrNumber ?? ''}" ocrPrintedTotal=${ocrPrintedTotal ?? 'null'} '
      'ocrHp=${ocrHp ?? 'null'}',
    );
    for (var i = 0; i < top.length; i++) {
      final row = top[i];
      // ignore: avoid_print
      print(
        'SCAN DEBUG [$tag] top${i + 1} score=${row.score} '
        'name="${row.card.name}" number="${row.card.number}" '
        'set="${row.card.setName}" setId="${row.card.setId}" '
        'hp=${row.card.hp ?? 'null'}',
      );
    }
  }

  bool _acceptScannerWorkerBest({
    required PokemonCardResult card,
    required String ocrName,
    String? ocrNumber,
    String? numberSource,
    int? ocrPrintedTotal,
    int? ocrHp,
  }) {
    final score = _scannerEvidenceScore(
      card: card,
      ocrName: ocrName,
      ocrNumber: ocrNumber,
      numberSource: numberSource,
      ocrPrintedTotal: ocrPrintedTotal,
      ocrHp: ocrHp,
    );
    if (score >= 45) return true;

    var strongMismatches = 0;

    final wantName = _normalizeScannerName(ocrName);
    final gotName = _normalizeScannerName(card.name);
    if (wantName.isNotEmpty &&
        !_scannerNamesLookCompatible(wantName, gotName)) {
      strongMismatches++;
    }

    final wantNumDigits = _collectorDigits(ocrNumber);
    final gotNumDigits = _collectorDigits(card.number);
    if (wantNumDigits != null &&
        gotNumDigits != null &&
        gotNumDigits != wantNumDigits) {
      strongMismatches++;
    }

    if (ocrPrintedTotal != null &&
        card.setPrintedTotal != null &&
        card.setPrintedTotal != ocrPrintedTotal) {
      strongMismatches++;
    }

    if (ocrHp != null && card.hp != null && (card.hp! - ocrHp).abs() >= 40) {
      strongMismatches++;
    }

    return strongMismatches == 0;
  }

  PokemonCardResult? _promoteScannerCandidate({
    required List<PokemonCardResult> cards,
    required String ocrName,
    String? ocrNumber,
    String? numberSource,
    int? ocrPrintedTotal,
    int? ocrHp,
  }) {
    if (cards.isEmpty) return null;

    final scored =
        cards
            .map(
              (card) => (
                card: card,
                score: _scannerEvidenceScore(
                  card: card,
                  ocrName: ocrName,
                  ocrNumber: ocrNumber,
                  numberSource: numberSource,
                  ocrPrintedTotal: ocrPrintedTotal,
                  ocrHp: ocrHp,
                ),
              ),
            )
            .toList()
          ..sort((a, b) => b.score.compareTo(a.score));

    final top = scored.first;
    final runnerUp = scored.length > 1 ? scored[1] : null;

    if (top.score < 45) return null;
    if (runnerUp != null && (top.score - runnerUp.score) < 15) return null;

    return top.card;
  }

  // ------------------- HTTP (direct upstream) -------------------

  Uri _sanitizeRequestUri(Uri uri) {
    var reqUri = uri;
    final qp = Map<String, String>.from(reqUri.queryParameters);
    final ob = qp['orderBy'];
    if (ob != null) {
      var fixed = ob;
      fixed = fixed.replaceAll('reeleaseDate', 'releaseDate');
      fixed = fixed.replaceAll('releaseDDate', 'releaseDate');
      fixed = fixed.replaceAll('releaseDDdate', 'releaseDate');

      if (fixed != ob) {
        qp['orderBy'] = fixed;
        reqUri = reqUri.replace(queryParameters: qp);

        // ignore: avoid_print
        print('ðŸ› ï¸ FIXED orderBy: "$ob" -> "$fixed"');
        // ignore: avoid_print
        print('ðŸ› ï¸ FIXED URI: $reqUri');
      }
    }
    return reqUri;
  }

  Future<http.Response> _get(Uri uri) async {
    const maxAttempts = 3;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        var reqUri = uri;

        // sanitize known ghost typos right before sending
        final qp = Map<String, String>.from(reqUri.queryParameters);
        final ob = qp['orderBy'];
        if (ob != null) {
          var fixed = ob;
          fixed = fixed.replaceAll('reeleaseDate', 'releaseDate');
          fixed = fixed.replaceAll('releaseDDate', 'releaseDate');
          fixed = fixed.replaceAll('releaseDDdate', 'releaseDate');

          if (fixed != ob) {
            qp['orderBy'] = fixed;
            reqUri = reqUri.replace(queryParameters: qp);

            // ignore: avoid_print
            print('🛠️ FIXED orderBy: "$ob" -> "$fixed"');
            // ignore: avoid_print
            print('🛠️ FIXED URI: $reqUri');
          }
        }

        // ignore: avoid_print
        print('🛰️ TCG GET ($attempt/$maxAttempts) → $reqUri');

        reqUri = _sanitizeRequestUri(reqUri);

        // ignore: avoid_print
        print('TCG GET ($attempt/$maxAttempts) -> $reqUri');

        final resp = await _io
            .get(reqUri, headers: _headers())
            .timeout(const Duration(seconds: 25));

        // ignore: avoid_print
        print('🛰️ STATUS: ${resp.statusCode}');

        if (resp.statusCode == 404 && resp.bodyBytes.isEmpty) {
          if (attempt == maxAttempts) {
            throw TcgServiceUnavailable(
              'TCG API returned empty 404 (service may be down).',
            );
          }
          await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
          continue;
        }

        return resp;
      } on TimeoutException catch (e) {
        // ignore: avoid_print
        print('⚠️ TCG GET timeout: $e');
        if (attempt == maxAttempts) {
          throw TcgServiceUnavailable(
            'TCG API timed out (service may be down).',
          );
        }
        await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
      } catch (e) {
        // ignore: avoid_print
        print('⚠️ TCG GET error: $e');
        if (attempt == maxAttempts) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
      }
    }

    throw StateError('unreachable');
  }

  PokemonCardResult? _parseSingleCard(String body) {
    final decoded = jsonDecode(body);
    final root = _map(decoded);
    final data = _map(root?['data']);
    if (data == null) return null;
    return PokemonCardResult.fromJson(data);
  }

  List<PokemonCardResult> _parseCardList(String body) {
    final decoded = jsonDecode(body);
    final root = _map(decoded);
    final dataList = _list(root?['data']);
    if (dataList == null) return const [];

    final out = <PokemonCardResult>[];
    for (final item in dataList) {
      final m = _map(item);
      if (m == null) continue;
      out.add(PokemonCardResult.fromJson(m));
    }
    return out;
  }

  // ------------------- Caching -------------------

  String _cacheKeyForSearch({
    required String name,
    String? set,
    String? number,
    String? setTotal,
    int pageSize = 20,
  }) {
    return [
      'search',
      _cleanName(name).toLowerCase(),
      (set ?? '').trim().toLowerCase(),
      (number ?? '').trim().toUpperCase(),
      (setTotal ?? '').trim(),
      pageSize.toString(),
    ].join('|');
  }

  Future<List<PokemonCardResult>> getCachedSearch({
    required String name,
    String? set,
    String? number,
    String? setTotal,
    int pageSize = 20,
  }) async {
    final key = _cacheKeyForSearch(
      name: name,
      set: set,
      number: number,
      setTotal: setTotal,
      pageSize: pageSize,
    );

    final raw = _box.get(key);
    if (raw is! String) {
      // ignore: avoid_print
      print('TRACE api.getCachedSearch return count=0 key="$key" hasRaw=false');
      return const [];
    }
    try {
      final parsed = _parseCardList(raw);
      // ignore: avoid_print
      print(
        'TRACE api.getCachedSearch return count=${parsed.length} key="$key" hasRaw=true',
      );
      return parsed;
    } catch (e) {
      // ignore: avoid_print
      print('TRACE api.getCachedSearch parse_error key="$key" error=$e');
      return const [];
    }
  }

  Future<void> _saveCachedSearch({
    required String name,
    String? set,
    String? number,
    String? setTotal,
    required int pageSize,
    required String body,
  }) async {
    final key = _cacheKeyForSearch(
      name: name,
      set: set,
      number: number,
      setTotal: setTotal,
      pageSize: pageSize,
    );
    await _box.put(key, body);
  }

  String _encodeCardListBody(List<PokemonCardResult> cards) {
    return jsonEncode({'data': cards.map((c) => c.toJson()).toList()});
  }
  // ------------------- Set index -------------------

  Future<List<PokemonCardResult>> fetchAllCardsForSet(String setId) async {
    final totalStopwatch = Stopwatch()..start();
    final cacheKey = 'setindex|$setId';
    final cached = _box.get(cacheKey);
    if (cached is String) {
      try {
        final parseStopwatch = Stopwatch()..start();
        final cards = _parseCardList(cached);
        parseStopwatch.stop();
        totalStopwatch.stop();
        if (kDebugMode) {
          debugPrint(
            'set-index fetchAllCardsForSet source=cache setId=$setId '
            'count=${cards.length} parseMs=${parseStopwatch.elapsedMilliseconds} '
            'totalMs=${totalStopwatch.elapsedMilliseconds}',
          );
        }
        return cards;
      } catch (_) {}
    }

    // ✅ Prefer Worker D1 set-index for Pokédex previews
    try {
      final workerFetchStopwatch = Stopwatch()..start();
      final uri = Uri.parse('$_proxyBase/set-index?setId=$setId');
      final resp = await http.get(uri);
      workerFetchStopwatch.stop();

      if (resp.statusCode == 200) {
        final decodeStopwatch = Stopwatch()..start();
        final decoded = jsonDecode(resp.body);
        decodeStopwatch.stop();
        if (decoded is Map &&
            decoded['ok'] == true &&
            decoded['cards'] is List) {
          final mapStopwatch = Stopwatch()..start();
          final raw = (decoded['cards'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();

          final cards = raw.map((r) {
            return PokemonCardResult.fromJson({
              'id': r['id'],
              'name': r['name'],
              'number': (r['number'] ?? '').toString(),
              'setId': (r['set_id'] ?? '').toString(),
              'setName': (r['set_name'] ?? '').toString(),
              'setPrintedTotal': r['printed_total'],
              'imageSmall': (r['image_small'] ?? '').toString(),
              'imageLarge': (r['image_large'] ?? '').toString(),
              'hp': r['hp'],
            });
          }).toList();
          mapStopwatch.stop();

          final wrapped = {'data': cards.map((c) => c.toJson()).toList()};
          await _box.put(cacheKey, jsonEncode(wrapped));
          totalStopwatch.stop();
          if (kDebugMode) {
            debugPrint(
              'set-index fetchAllCardsForSet source=worker setId=$setId '
              'count=${cards.length} fetchMs=${workerFetchStopwatch.elapsedMilliseconds} '
              'decodeMs=${decodeStopwatch.elapsedMilliseconds} '
              'mapMs=${mapStopwatch.elapsedMilliseconds} '
              'totalMs=${totalStopwatch.elapsedMilliseconds}',
            );
          }
          return cards;
        }
      }
    } catch (_) {
      // fall through
    }

    if (kDisableDirectTcgApi) {
      return <PokemonCardResult>[];
    }

    const pageSize = 250;
    var page = 1;
    final all = <PokemonCardResult>[];

    final queriesToTry = <String>['set.id:$setId', 'set.id:"$setId"'];

    for (final q in queriesToTry) {
      page = 1;
      all.clear();

      while (true) {
        final uri = Uri.https(_host, _cardsPath, {
          'q': q,
          'pageSize': pageSize.toString(),
          'page': page.toString(),
        });

        final resp = await _get(uri);
        if (resp.statusCode != 200) break;

        final parseStopwatch = Stopwatch()..start();
        final batch = _parseCardList(resp.body);
        parseStopwatch.stop();
        all.addAll(batch);

        if (batch.length < pageSize) {
          final wrapped = {'data': all.map((c) => c.toJson()).toList()};
          await _box.put(cacheKey, jsonEncode(wrapped));
          totalStopwatch.stop();
          if (kDebugMode) {
            debugPrint(
              'set-index fetchAllCardsForSet source=direct setId=$setId '
              'count=${all.length} pages=$page parseMs=${parseStopwatch.elapsedMilliseconds} '
              'totalMs=${totalStopwatch.elapsedMilliseconds}',
            );
          }
          return all;
        }

        page++;
        if (page > 20) break;
      }
    }

    return <PokemonCardResult>[];
  }

  // ------------------- Search (worker-first, safe direct fallback) -------------------

  bool _matchesSetQuery(PokemonCardResult card, String setQuery) {
    final q = setQuery.trim().toLowerCase();
    if (q.isEmpty) return true;

    final setName = card.setName.trim().toLowerCase();
    final setId = card.setId.trim().toLowerCase();
    return setName.contains(q) || setId == q;
  }

  bool _shouldTryWorkerManualSearch({
    required String name,
    String? set,
    String? number,
    String? setTotal,
  }) {
    final cleanNum = _cleanCollectorNumber(number);
    final parsedTotal = _parseSetTotal(setTotal);

    if (cleanNum != null && cleanNum.isNotEmpty) return true;
    if (parsedTotal != null) return true;
    return false;
  }

  bool _isBroadNameOnlyManualSearch({
    required String name,
    String? number,
    String? setTotal,
  }) {
    final safeName = _cleanName(name);
    final cleanNum = _cleanCollectorNumber(number);
    final parsedTotal = _parseSetTotal(setTotal);

    return safeName.isNotEmpty &&
        (cleanNum == null || cleanNum.isEmpty) &&
        parsedTotal == null;
  }

  String _normalizeManualFallbackQuery(String raw) {
    final cleaned = _cleanName(raw).toLowerCase();
    if (cleaned.isEmpty) return '';

    const noise = {'pokemon', 'card', 'tcg'};
    const formTokens = {
      'ex',
      'gx',
      'v',
      'vmax',
      'vstar',
      'break',
      'radiant',
      'tag',
      'team',
    };

    final tokens = cleaned
        .split(RegExp(r'\s+'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty && !noise.contains(t))
        .toList();
    if (tokens.isEmpty) return cleaned;

    final speciesTokens = tokens
        .where((t) => t != 'mega' && !formTokens.contains(t))
        .toList();

    final out = <String>[];
    if (tokens.contains('mega')) out.add('mega');
    out.addAll(speciesTokens);
    if (out.isEmpty) out.addAll(tokens);
    return out.join(' ').trim();
  }

  List<String> _buildManualFallbackQueries(String raw) {
    final safe = _cleanName(raw);
    final normalized = _normalizeManualFallbackQuery(raw);
    final speciesCore = _scannerCoreSpeciesName(raw);
    final megaLike = _scannerLooksMegaLike(raw);

    final queries = <String>[];
    final seen = <String>{};

    void addQuery(String q) {
      final cleaned = _cleanName(q);
      if (cleaned.isEmpty) return;
      final key = cleaned.toLowerCase();
      if (seen.add(key)) {
        queries.add(cleaned);
      }
    }

    addQuery(safe);
    addQuery(normalized);
    if (speciesCore.isNotEmpty) {
      if (megaLike) addQuery('Mega $speciesCore');
      addQuery(speciesCore);
    }

    return queries;
  }

  int _manualSearchRelevanceScore(String query, PokemonCardResult card) {
    final normalizedQuery = _normalizeManualFallbackQuery(query);
    final normalizedName = _normalizeScannerName(card.name);
    if (normalizedQuery.isEmpty || normalizedName.isEmpty) return 0;

    final queryTokens = normalizedQuery
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    final speciesTokens = _scannerCoreSpeciesName(query)
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();

    var score = 0;
    if (normalizedName == normalizedQuery) score += 80;

    final wantsMega = queryTokens.contains('mega');
    final candidateIsMega =
        normalizedName.contains('mega') ||
        normalizedName.split(' ').contains('m');
    if (wantsMega && candidateIsMega) {
      score += 20;
    } else if (wantsMega && !candidateIsMega) {
      score -= 8;
    }

    for (final token in speciesTokens) {
      if (normalizedName.contains(token)) {
        score += 35;
      }
    }

    for (final token in queryTokens) {
      if (token == 'mega') continue;
      if (normalizedName.contains(token)) {
        score += 12;
      }
    }

    if (speciesTokens.isNotEmpty &&
        speciesTokens.every((token) => normalizedName.contains(token))) {
      score += 30;
    }

    return score;
  }

  List<PokemonCardResult> _sortManualSearchResults(
    List<PokemonCardResult> cards,
    String query,
  ) {
    final sorted = List<PokemonCardResult>.from(cards);
    sorted.sort((a, b) {
      final byScore = _manualSearchRelevanceScore(query, b).compareTo(
        _manualSearchRelevanceScore(query, a),
      );
      if (byScore != 0) return byScore;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return sorted;
  }

  int _manualSearchTopScore(String query, List<PokemonCardResult> cards) {
    if (cards.isEmpty) return 0;
    var best = 0;
    for (final card in cards) {
      final score = _manualSearchRelevanceScore(query, card);
      if (score > best) best = score;
    }
    return best;
  }

  Future<List<PokemonCardResult>> _runManualSearchAttempt({
    required String name,
    String? set,
    String? number,
    String? setTotal,
    bool directOnly = false,
    int pageSize = 20,
  }) async {
    final safeName = _cleanName(name);
    final cleanNum = _cleanCollectorNumber(number);
    final normalizedSet = (set ?? '').trim().isEmpty ? null : (set ?? '').trim();
    final normalizedTotal = _parseSetTotal(setTotal)?.toString() ?? setTotal;

    if (!directOnly) {
      if (_shouldTryWorkerManualSearch(
        name: safeName,
        set: normalizedSet,
        number: cleanNum,
        setTotal: normalizedTotal,
      )) {
        try {
          final workerResults = await _tryWorkerManualSearch(
            name: safeName,
            set: normalizedSet,
            number: cleanNum,
            setTotal: normalizedTotal,
            pageSize: pageSize,
          );
          if (workerResults.isNotEmpty) {
            return _sortManualSearchResults(workerResults, safeName);
          }
        } catch (e) {
          // ignore: avoid_print
          print('worker manual search failed: $e');
        }
      }

      if (_isBroadNameOnlyManualSearch(
        name: safeName,
        number: cleanNum,
        setTotal: normalizedTotal,
      )) {
        try {
          final workerBrowseResults = await _tryWorkerBrowseSearch(
            name: safeName,
            set: normalizedSet,
            pageSize: pageSize,
          );
          if (workerBrowseResults.isNotEmpty) {
            return _sortManualSearchResults(workerBrowseResults, safeName);
          }
        } catch (e) {
          // ignore: avoid_print
          print('worker browse search failed: $e');
        }
      }
    }

    final directResults = await _refreshSearchDirect(
      name: name,
      set: set,
      number: number,
      setTotal: setTotal,
      pageSize: pageSize,
    );
    if (directResults.isNotEmpty) {
      return _sortManualSearchResults(directResults, safeName);
    }
    return const <PokemonCardResult>[];
  }

  Future<List<PokemonCardResult>> _tryWorkerManualSearch({
    required String name,
    String? set,
    String? number,
    String? setTotal,
    int pageSize = 20,
  }) async {
    final pick = await searchCardsReliable(
      name: name,
      number: number,
      setTotal: setTotal,
    );

    final safeSet = (set ?? '').trim();
    final ordered = <PokemonCardResult>[];
    final seenIds = <String>{};

    void addCard(PokemonCardResult card) {
      if (safeSet.isNotEmpty && !_matchesSetQuery(card, safeSet)) return;
      if (seenIds.add(card.id)) ordered.add(card);
    }

    if (pick.best != null) addCard(pick.best!);
    for (final card in pick.candidates) {
      addCard(card);
      if (ordered.length >= pageSize) break;
    }

    if (ordered.isEmpty) return const [];

    await _saveCachedSearch(
      name: name,
      set: set,
      number: number,
      setTotal: setTotal,
      pageSize: pageSize,
      body: _encodeCardListBody(ordered),
    );

    return ordered;
  }

  Future<List<PokemonCardResult>> _tryWorkerBrowseSearch({
    required String name,
    String? set,
    int pageSize = 20,
  }) async {
    final j = await _proxyGetJson(_proxyUri('/scan-lookup', {'name': name}));
    if (j['ok'] != true) return const [];

    final safeSet = (set ?? '').trim();
    final ordered = <PokemonCardResult>[];
    final seenIds = <String>{};

    void addCard(PokemonCardResult card) {
      if (safeSet.isNotEmpty && !_matchesSetQuery(card, safeSet)) return;
      if (seenIds.add(card.id)) ordered.add(card);
    }

    final bestMap = _map(j['best']);
    if (bestMap != null) {
      addCard(_fromWorkerRow(bestMap));
    }

    final candidateList = _list(j['candidates']);
    if (candidateList != null) {
      for (final item in candidateList) {
        final row = _map(item);
        if (row == null) continue;
        addCard(_fromWorkerRow(row));
        if (ordered.length >= pageSize) break;
      }
    }

    if (ordered.isEmpty) return const [];

    await _saveCachedSearch(
      name: name,
      set: set,
      number: null,
      setTotal: null,
      pageSize: pageSize,
      body: _encodeCardListBody(ordered),
    );

    return ordered;
  }

  Future<List<PokemonCardResult>> _refreshSearchDirect({
    required String name,
    String? set,
    String? number,
    String? setTotal,
    int pageSize = 20,
  }) async {
    final safeName = _cleanName(name);
    final cleanNum = _cleanCollectorNumber(number);
    final safeSet = (set ?? '').trim();
    final printedTotal = _parseSetTotal(setTotal);

    // ignore: avoid_print
    print(
      'TRACE api.refreshSearchDirect.entry name="$safeName" set="$safeSet" number="${cleanNum ?? ''}" setTotal="${printedTotal?.toString() ?? setTotal ?? ''}" pageSize=$pageSize',
    );

    final hasName = safeName.isNotEmpty;
    final hasNumber = cleanNum != null && cleanNum.isNotEmpty;
    if (!hasName && !hasNumber) return <PokemonCardResult>[];

    if (kDisableDirectTcgApi) {
      return getCachedSearch(
        name: name,
        set: set,
        number: number,
        setTotal: setTotal,
        pageSize: pageSize,
      );
    }

    final parts = <String>[];

    if (hasName) {
      final escapedName = _escapeLucene(safeName);
      parts.add('(name:"$escapedName" OR name:"$escapedName*")');
    }

    if (safeSet.isNotEmpty) {
      final cleanedSet = _escapeLucene(_cleanName(safeSet));
      parts.add('set.name:"$cleanedSet"');
    }

    if (hasNumber) {
      final variants = <String>[];
      var base = cleanNum!.trim();

      if (base.contains('/')) {
        base = base.split('/').first.trim();
      }

      final hasLettersInNum = RegExp(r'[A-Za-z]').hasMatch(base);
      if (hasLettersInNum) {
        variants.add(base.toUpperCase());
        final digitsOnly = base.replaceAll(RegExp(r'[^0-9]'), '');
        if (digitsOnly.isNotEmpty) {
          variants.add(digitsOnly);
        }
      } else {
        final digits = base.replaceAll(RegExp(r'[^0-9]'), '');
        if (digits.isNotEmpty) {
          base = digits;
        }

        variants.add(base);

        if (base.length == 4) {
          variants.add(base.substring(1)); // 2183 -> 183
        }
      }

      final uniq = <String>{};
      final finalVariants = <String>[];
      for (final v in variants) {
        final t = v.trim();
        if (t.isEmpty) continue;
        if (uniq.add(t)) {
          finalVariants.add(t);
        }
        if (finalVariants.length >= 3) break;
      }

      if (finalVariants.isNotEmpty) {
        if (finalVariants.length == 1) {
          parts.add('number:"${_escapeLucene(finalVariants[0])}"');
        } else {
          final orGroup = finalVariants
              .map((v) => 'number:"${_escapeLucene(v)}"')
              .join(' OR ');
          parts.add('($orGroup)');
        }
      }
    }

    if (printedTotal != null) {
      parts.add('set.printedTotal:$printedTotal');
    }

    final q = parts.join(' ');

    // ignore: avoid_print
    print('SEARCH q=$q');

    final uri = Uri.https(_host, _cardsPath, {
      'q': q,
      'pageSize': pageSize.toString(),
      'orderBy': '-set.releaseDate',
    });
    final requestUri = _sanitizeRequestUri(uri);

    http.Response resp;
    try {
      // ignore: avoid_print
      print('TRACE api.refreshSearchDirect.before_get uri=$requestUri');
      resp = await _get(requestUri).timeout(const Duration(seconds: 10));
      // ignore: avoid_print
      print(
        'TRACE api.refreshSearchDirect.after_get status=${resp.statusCode} bodyLen=${resp.body.length}',
      );
    } on TimeoutException {
      // ignore: avoid_print
      print('TRACE api.refreshSearchDirect.timeout uri=$requestUri');
      final cached = await getCachedSearch(
        name: name,
        set: set,
        number: number,
        setTotal: setTotal,
        pageSize: pageSize,
      );
      // ignore: avoid_print
      print(
        'TRACE api.refreshSearchDirect.timeout_return cached=${cached.length}',
      );
      if (cached.isNotEmpty) return cached;
      return <PokemonCardResult>[];
    } catch (e) {
      // ignore: avoid_print
      print('TRACE api.refreshSearchDirect.catch error=$e uri=$requestUri');
      final cached = await getCachedSearch(
        name: name,
        set: set,
        number: number,
        setTotal: setTotal,
        pageSize: pageSize,
      );
      // ignore: avoid_print
      print(
        'TRACE api.refreshSearchDirect.catch_return cached=${cached.length}',
      );
      if (cached.isNotEmpty) return cached;
      return <PokemonCardResult>[];
    }

    if (resp.statusCode == 200) {
      await _saveCachedSearch(
        name: name,
        set: set,
        number: number,
        setTotal: setTotal,
        pageSize: pageSize,
        body: resp.body,
      );
      return _parseCardList(resp.body);
    }

    final cached = await getCachedSearch(
      name: name,
      set: set,
      number: number,
      setTotal: setTotal,
      pageSize: pageSize,
    );
    if (cached.isNotEmpty) return cached;

    if (resp.statusCode == 404) return <PokemonCardResult>[];

    throw Exception('TCG API ${resp.statusCode}');
  }

  Future<List<PokemonCardResult>> refreshSearch({
    required String name,
    String? set,
    String? number,
    String? setTotal,
    int pageSize = 20,
  }) async {
    final safeName = _cleanName(name);
    final cleanNum = _cleanCollectorNumber(number);
    final safeSet = (set ?? '').trim();
    final printedTotal = _parseSetTotal(setTotal);

    // ignore: avoid_print
    print(
      'TRACE api.refreshSearch.entry name="$safeName" set="$safeSet" number="${cleanNum ?? ''}" setTotal="${printedTotal?.toString() ?? setTotal ?? ''}" pageSize=$pageSize',
    );

    final hasName = safeName.isNotEmpty;
    final hasNumber = cleanNum != null && cleanNum.isNotEmpty;
    if (!hasName && !hasNumber) return <PokemonCardResult>[];

    if (hasNumber) {
      final fallbackQueries = _buildManualFallbackQueries(safeName);
      for (final query in fallbackQueries) {
        final results = await _runManualSearchAttempt(
          name: query,
          set: safeSet.isEmpty ? null : safeSet,
          number: cleanNum,
          setTotal: printedTotal?.toString() ?? setTotal,
          pageSize: pageSize,
        );
        if (results.isNotEmpty) return results;
      }
      return const <PokemonCardResult>[];
    }

    final fallbackQueries = _buildManualFallbackQueries(safeName);
    final speciesCore = _scannerCoreSpeciesName(safeName);
    final safeTokens = safeName
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    final isSingleTokenCoreSearch =
        safeTokens.length == 1 &&
        speciesCore.isNotEmpty &&
        speciesCore == safeTokens.first;

    final attempts = <({String query, bool directOnly})>[];
    final seenAttempts = <String>{};

    void addAttempt(String query, {required bool directOnly}) {
      final cleaned = _cleanName(query);
      if (cleaned.isEmpty) return;
      final key = '${cleaned.toLowerCase()}|$directOnly';
      if (seenAttempts.add(key)) {
        attempts.add((query: cleaned, directOnly: directOnly));
      }
    }

    for (var i = 0; i < fallbackQueries.length; i++) {
      final query = fallbackQueries[i];
      addAttempt(query, directOnly: false);
      if (i == 0 && isSingleTokenCoreSearch) {
        addAttempt(query, directOnly: true);
      }
    }

    List<PokemonCardResult> bestResults = const <PokemonCardResult>[];
    String? bestQuery;
    var bestScore = 0;

    for (final attempt in attempts) {
      final results = await _runManualSearchAttempt(
        name: attempt.query,
        set: safeSet.isEmpty ? null : safeSet,
        number: cleanNum,
        setTotal: printedTotal?.toString() ?? setTotal,
        directOnly: attempt.directOnly,
        pageSize: pageSize,
      );
      final topScore = _manualSearchTopScore(attempt.query, results);
      // ignore: avoid_print
      print(
        'TRACE manualSearch.attempt query="${attempt.query}" count=${results.length} topScore=$topScore',
      );

      if (results.isEmpty) continue;
      if (bestQuery == null || topScore > bestScore) {
        bestResults = results;
        bestQuery = attempt.query;
        bestScore = topScore;
      }
      if (topScore >= 50) break;
    }

    if (bestQuery != null && bestResults.isNotEmpty) {
      // ignore: avoid_print
      print(
        'TRACE manualSearch.selected query="$bestQuery" count=${bestResults.length} topScore=$bestScore',
      );
      return bestResults;
    }

    return const <PokemonCardResult>[];
  }
  // ------------------- Card by ID -------------------

  Future<PokemonCardResult?> fetchCardById(String id) async {
    final cacheKey = 'card|$id';
    final cached = _box.get(cacheKey);
    if (cached is String) {
      try {
        final card = _parseSingleCard(cached);
        if (card != null) return card;
      } catch (_) {}
    }

    if (kDisableDirectTcgApi) return null;

    final uri = Uri.https(_host, '$_cardsPath/$id');
    final resp = await _get(uri);
    if (resp.statusCode != 200) return null;

    await _box.put(cacheKey, resp.body);
    return _parseSingleCard(resp.body);
  }

  // ------------------- Worker scan lookup -------------------

  PokemonCardResult _fromWorkerRow(Map<String, dynamic> row) {
    int? toInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      return int.tryParse(v.toString());
    }

    return PokemonCardResult(
      id: (row['id'] ?? '').toString(),
      name: (row['name'] ?? '').toString(),
      setId: (row['set_id'] ?? '').toString(),
      setName: (row['set_name'] ?? '').toString(),
      setPrintedTotal: toInt(row['printed_total']),
      number: (row['number'] ?? '').toString(),
      hp: toInt(row['hp']), // ✅ THIS is where hp belongs
      imageSmall: (row['image_small'] ?? '').toString(),
      imageLarge: (row['image_large'] ?? '').toString(),
      finishes: const {},
    );
  }

  Future<ReliablePick> searchCardsReliable({
    required String name,
    String? number,
    String? numberSource,
    String? imagePath,
    String? setTotal,
    int? hp,
    String? rawText,

    // optional (slot locked scans from Pokédex)
    String? expectedSetId,
    int? expectedSlot,
    int? svpSlot,
  }) async {
    final safeName = _cleanName(name);
    final lowerName = safeName.toLowerCase().trim();
    final wantNum = _cleanCollectorNumber(number);
    final wantTotal = _parseSetTotal(setTotal);
    final useScannerConfidence = hp != null;
    final weakNumber = wantNum == null || wantNum.isEmpty;
    final recoveredSpecies = _recoverSpeciesFromOcrName(name);
    final recoveredQueryNames = recoveredSpecies == null
        ? const <String>[]
        : _buildRecoveredScannerQueries(
            rawName: name,
            recoveredSpecies: recoveredSpecies,
          );

    // ignore: avoid_print
    print(
      'SCAN DEBUG [entry] rawName="$name" safeName="$safeName" '
      'normalized="${_normalizeScannerName(safeName)}" '
      'number="${wantNum ?? ''}" setTotal=${wantTotal ?? 'null'} '
      'numberSource="${numberSource ?? ''}" '
      'hp=${hp ?? 'null'} expectedSetId="${expectedSetId ?? ''}" '
      'expectedSlot=${expectedSlot ?? 'null'} svpSlot=${svpSlot ?? 'null'}',
    );
    if (recoveredQueryNames.isNotEmpty) {
      // ignore: avoid_print
      print(
        'SCAN DEBUG [recovered-species] species="$recoveredSpecies" queries="$recoveredQueryNames"',
      );
    }

    final rawBrowseSeeds =
        safeName.isEmpty && (wantNum == null || wantNum.isEmpty)
        ? _scannerBrowseSeedsFromRawText(rawText ?? '')
        : const <String>[];
    if (rawBrowseSeeds.isNotEmpty) {
      // ignore: avoid_print
      print('SCAN DEBUG [raw-seeds] ${rawBrowseSeeds.join(' | ')}');
    }

    final isLabel =
        lowerName == 'trainer' ||
        lowerName == 'traner' ||
        lowerName == 'pokemon' ||
        lowerName == 'energy';

    // "strict" is ONLY safe when we truly have a numeric fraction like 245/198
    final strictFraction =
        (wantNum != null) &&
        RegExp(r'^\d+$').hasMatch(wantNum) &&
        (wantTotal != null);

    // ---------------- SVP HARD PATH ----------------
    // If OCR detected SVP slot (like "SVP 051"), we should NOT allow fallback
    // to generic Snorlax matches.
    if (svpSlot != null && svpSlot > 0) {
      // ensure SVP set is present (non-blocking; preview may still work without this)
      await ensureSetPresent('svp');

      // A) exact preview lookup
      try {
        final uri = _proxyUri('/preview', {
          'setId': 'svp',
          'slot': svpSlot.toString(),
        });

        final j = await _proxyGetJson(uri);
        if (j['ok'] == true && j['found'] == true && j['card'] is Map) {
          final card = _fromWorkerRow(
            (j['card'] as Map).cast<String, dynamic>(),
          );
          return ReliablePick(
            best: card,
            candidates: const [],
            strategy: 'svp-preview',
          );
        }
      } catch (e) {
        // ignore: avoid_print
        print('⚠️ svp preview failed: $e');
      }

      // B) if preview failed, force slot-locked scan-lookup on worker
      // (do NOT pass name/printedTotal/hp — they can poison results)
      try {
        final uri = _proxyUri('/scan-lookup', {
          'expectedSetId': 'svp',
          'expectedSlot': svpSlot.toString(),
          'strict': '1',
        });

        final j = await _proxyGetJson(uri);
        if (j['ok'] == true) {
          if (j['found'] == true && j['best'] is Map) {
            final best = _fromWorkerRow(
              (j['best'] as Map).cast<String, dynamic>(),
            );
            return ReliablePick(
              best: best,
              candidates: const [],
              strategy: 'svp-worker-locked',
            );
          }
          if (j['candidates'] is List) {
            final list = (j['candidates'] as List)
                .whereType<Map>()
                .map((m) => _fromWorkerRow(m.cast<String, dynamic>()))
                .toList();
            if (list.isNotEmpty) {
              return ReliablePick(
                best: list.length == 1 ? list.first : null,
                candidates: list,
                strategy: 'svp-worker-locked-candidates',
              );
            }
          }
        }
      } catch (e) {
        // ignore: avoid_print
        print('⚠️ svp worker locked scan-lookup failed: $e');
      }

      // If we got here, we intentionally STOP rather than returning the wrong Snorlax.
      return ReliablePick(
        best: null,
        candidates: const [],
        strategy: 'svp-not-found',
      );
    }

    // ---------------- WORKER FIRST (scan-lookup) ----------------
    // We try a few variants to avoid trainer/label poisoning.
    Future<ReliablePick?> tryWorker({
      required bool includeName,
      required bool includeStrict,
    }) async {
      final qp = <String, String>{};

      if (includeName && safeName.isNotEmpty) qp['name'] = safeName;
      if (wantNum != null && wantNum.isNotEmpty) qp['number'] = wantNum;

      // NOTE: worker expects "printedTotal" (string ok)
      if (setTotal != null && setTotal.trim().isNotEmpty) {
        qp['printedTotal'] = setTotal.trim();
      }

      if (hp != null) qp['hp'] = hp.toString();

      if (expectedSetId != null && expectedSetId.trim().isNotEmpty) {
        qp['expectedSetId'] = expectedSetId.trim();
      }
      if (expectedSlot != null) qp['expectedSlot'] = expectedSlot.toString();

      if (includeStrict && strictFraction) qp['strict'] = '1';

      if (qp.isEmpty) return null;

      final uri = _proxyUri('/scan-lookup', qp);
      final j = await _proxyGetJson(uri);
      final candidateList = (j['candidates'] as List?)
          ?.whereType<Map>()
          .map((m) => _fromWorkerRow(m.cast<String, dynamic>()))
          .toList();

      // ignore: avoid_print
      print(
        'SCAN DEBUG [worker] includeName=$includeName includeStrict=$includeStrict '
        'name="${includeName ? safeName : ''}" number="${wantNum ?? ''}" '
        'printedTotal=${wantTotal ?? 'null'} hp=${hp ?? 'null'} '
        'found=${j['found'] == true} candidateCount=${candidateList?.length ?? 0}',
      );

      if (j['ok'] == true) {
        if (j['found'] == true && j['best'] is Map) {
          final best = _fromWorkerRow(
            (j['best'] as Map).cast<String, dynamic>(),
          );

          // ignore: avoid_print
          print(
            'SCAN DEBUG [worker-best] '
            'name="${best.name}" number="${best.number}" '
            'set="${best.setName}" setId="${best.setId}" hp=${best.hp ?? 'null'}',
          );

          if (!useScannerConfidence ||
              _acceptScannerWorkerBest(
                card: best,
                ocrName: safeName,
                ocrNumber: wantNum,
                numberSource: numberSource,
                ocrPrintedTotal: wantTotal,
                ocrHp: hp,
              )) {
            return ReliablePick(
              best: best,
              candidates: const [],
              strategy: 'worker-best',
            );
          }

          if (candidateList != null && candidateList.isNotEmpty) {
            _logScannerScores(
              tag: 'worker-best-downgraded',
              cards: candidateList,
              ocrName: safeName,
              ocrNumber: wantNum,
              numberSource: numberSource,
              ocrPrintedTotal: wantTotal,
              ocrHp: hp,
            );
            final promoted = _promoteScannerCandidate(
              cards: candidateList,
              ocrName: safeName,
              ocrNumber: wantNum,
              numberSource: numberSource,
              ocrPrintedTotal: wantTotal,
              ocrHp: hp,
            );
            return ReliablePick(
              best: promoted,
              candidates: candidateList,
              strategy: promoted != null
                  ? 'worker-best-downgraded-promoted'
                  : 'worker-best-downgraded-candidates',
            );
          }

          return null;
        }

        if (candidateList != null && candidateList.isNotEmpty) {
          _logScannerScores(
            tag: 'worker-candidates',
            cards: candidateList,
            ocrName: safeName,
            ocrNumber: wantNum,
            numberSource: numberSource,
            ocrPrintedTotal: wantTotal,
            ocrHp: hp,
          );
          final promoted = useScannerConfidence
              ? _promoteScannerCandidate(
                  cards: candidateList,
                  ocrName: safeName,
                  ocrNumber: wantNum,
                  numberSource: numberSource,
                  ocrPrintedTotal: wantTotal,
                  ocrHp: hp,
                )
              : (candidateList.length == 1 ? candidateList.first : null);

          return ReliablePick(
            best: promoted,
            candidates: candidateList,
            strategy: promoted != null
                ? 'worker-candidates-promoted'
                : 'worker-candidates',
          );
        }
      }

      return null;
    }

    ReliablePick? deferredWorkerPick;

    try {
      // 1) Normal attempt (with name, strict if safe)
      final a = await tryWorker(includeName: true, includeStrict: true);
      if (a != null) {
        if (weakNumber &&
            recoveredQueryNames.isNotEmpty &&
            a.best == null &&
            a.candidates.isNotEmpty) {
          deferredWorkerPick = a;
        } else {
          return a;
        }
      }

      // 2) If label-ish / risky name, retry without name (keeps number/total/hp)
      if (isLabel || safeName.isEmpty) {
        final b = await tryWorker(includeName: false, includeStrict: true);
        if (b != null) {
          if (weakNumber &&
              recoveredQueryNames.isNotEmpty &&
              b.best == null &&
              b.candidates.isNotEmpty) {
            deferredWorkerPick ??= b;
          } else {
            return b;
          }
        }
      }

      // 3) If strict was on, loosen strict (sometimes OCR total is wrong)
      final c = await tryWorker(includeName: true, includeStrict: false);
      if (c != null) {
        if (weakNumber &&
            recoveredQueryNames.isNotEmpty &&
            c.best == null &&
            c.candidates.isNotEmpty) {
          deferredWorkerPick ??= c;
        } else {
          return c;
        }
      }

      // 4) Last resort: no name + no strict (for trainer label cases)
      final d = await tryWorker(includeName: false, includeStrict: false);
      if (d != null) {
        if (weakNumber &&
            recoveredQueryNames.isNotEmpty &&
            d.best == null &&
            d.candidates.isNotEmpty) {
          deferredWorkerPick ??= d;
        } else {
          return d;
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print('⚠️ worker scan-lookup failed: $e');
    }

    // If label-only and no number, nothing useful unless raw-text rescue can browse.
    if (isLabel &&
        (wantNum == null || wantNum.isEmpty) &&
        rawBrowseSeeds.isEmpty) {
      return ReliablePick(
        best: null,
        candidates: const [],
        strategy: 'label-empty',
      );
    }

    final fallbackCandidates = <PokemonCardResult>[];
    final fallbackIds = <String>{};

    void addFallbacks(List<PokemonCardResult> cards) {
      for (final card in cards) {
        if (fallbackIds.add(card.id)) {
          fallbackCandidates.add(card);
        }
      }
    }

    if (deferredWorkerPick != null) {
      addFallbacks(deferredWorkerPick!.candidates);
    }

    if (recoveredQueryNames.isNotEmpty && weakNumber) {
      for (final recoveredQuery in recoveredQueryNames) {
        try {
          final recoveredBrowse = await _tryWorkerBrowseSearch(
            name: recoveredQuery,
            set: null,
            pageSize: 20,
          );
          // ignore: avoid_print
          print(
            'SCAN DEBUG [fallback-recovered-browse] count=${recoveredBrowse.length} '
            'name="$recoveredQuery"',
          );
          addFallbacks(recoveredBrowse);
        } catch (e) {
          // ignore: avoid_print
          print('recovered species browse fallback failed: $e');
        }

        if (!kDisableDirectTcgApi) {
          try {
            final recoveredDirect = await _refreshSearchDirect(
              name: recoveredQuery,
              set: null,
              number: null,
              setTotal: null,
              pageSize: 20,
            );
            // ignore: avoid_print
            print(
              'SCAN DEBUG [fallback-recovered-direct] count=${recoveredDirect.length} '
              'name="$recoveredQuery"',
            );
            addFallbacks(recoveredDirect);
          } catch (e) {
            // ignore: avoid_print
            print('recovered species direct fallback failed: $e');
          }
        }
      }
    }

    if (safeName.isNotEmpty) {
      try {
        final browseFallback = await _tryWorkerBrowseSearch(
          name: safeName,
          set: null,
          pageSize: 20,
        );
        // ignore: avoid_print
        print(
          'SCAN DEBUG [fallback-browse] count=${browseFallback.length} '
          'name="$safeName"',
        );
        addFallbacks(browseFallback);
      } catch (e) {
        // ignore: avoid_print
        print('âš ï¸ worker browse fallback failed: $e');
      }
    }

    if (fallbackCandidates.isEmpty && rawBrowseSeeds.isNotEmpty) {
      for (final seed in rawBrowseSeeds) {
        try {
          final browseFallback = await _tryWorkerBrowseSearch(
            name: seed,
            set: null,
            pageSize: 20,
          );
          // ignore: avoid_print
          print(
            'SCAN DEBUG [fallback-browse-raw] count=${browseFallback.length} '
            'seed="$seed"',
          );
          addFallbacks(browseFallback);
          if (fallbackCandidates.isNotEmpty) break;
        } catch (e) {
          // ignore: avoid_print
          print('worker raw browse fallback failed: $e');
        }
      }
    }

    if (fallbackCandidates.isEmpty && !kDisableDirectTcgApi) {
      try {
        final directFallback = await _refreshSearchDirect(
          name: safeName,
          set: null,
          number: wantNum,
          setTotal: setTotal,
          pageSize: 20,
        );
        // ignore: avoid_print
        print(
          'SCAN DEBUG [fallback-direct] count=${directFallback.length} '
          'name="$safeName" number="${wantNum ?? ''}" '
          'setTotal=${wantTotal ?? 'null'}',
        );
        addFallbacks(directFallback);

        if (fallbackCandidates.isEmpty &&
            safeName.isNotEmpty &&
            (wantNum != null || wantTotal != null)) {
          final looseDirectFallback = await _refreshSearchDirect(
            name: safeName,
            set: null,
            number: null,
            setTotal: null,
            pageSize: 20,
          );
          // ignore: avoid_print
          print(
            'SCAN DEBUG [fallback-direct-loose] count=${looseDirectFallback.length} '
            'name="$safeName"',
          );
          addFallbacks(looseDirectFallback);
        }
      } catch (e) {
        // ignore: avoid_print
        print('âš ï¸ direct scanner fallback failed: $e');
      }
    }

    if (fallbackCandidates.isEmpty &&
        !kDisableDirectTcgApi &&
        rawBrowseSeeds.isNotEmpty) {
      for (final seed in rawBrowseSeeds) {
        try {
          final directFallback = await _refreshSearchDirect(
            name: seed,
            set: null,
            number: null,
            setTotal: null,
            pageSize: 20,
          );
          // ignore: avoid_print
          print(
            'SCAN DEBUG [fallback-direct-raw] count=${directFallback.length} '
            'seed="$seed"',
          );
          addFallbacks(directFallback);
          if (fallbackCandidates.isNotEmpty) break;
        } catch (e) {
          // ignore: avoid_print
          print('direct raw scanner fallback failed: $e');
        }
      }
    }

    if (fallbackCandidates.isNotEmpty) {
      _logScannerScores(
        tag: 'fallback-merged',
        cards: fallbackCandidates,
        ocrName: safeName,
        ocrNumber: wantNum,
        numberSource: numberSource,
        ocrPrintedTotal: wantTotal,
        ocrHp: hp,
      );
      final scored =
          fallbackCandidates
              .map(
                (card) => (
                  card: card,
                  score: _scannerEvidenceScore(
                    card: card,
                    ocrName: safeName,
                    ocrNumber: wantNum,
                    numberSource: numberSource,
                    ocrPrintedTotal: wantTotal,
                    ocrHp: hp,
                  ),
                ),
              )
              .toList()
            ..sort((a, b) => b.score.compareTo(a.score));
      final topThree = scored.take(3).toList();
      // ignore: avoid_print
      print(
        'SCAN DEBUG [froslass-trace] ocrName="$safeName" ocrNumber="${wantNum ?? ''}" '
        'numberSource="${numberSource ?? ''}" trustedCollectorSource=${_hasTrustedCollectorNumber(numberSource, wantNum)}',
      );
      for (var i = 0; i < topThree.length; i++) {
        final row = topThree[i];
        // ignore: avoid_print
        print(
          'SCAN DEBUG [top${i + 1}] name="${row.card.name}" '
          'set="${row.card.setName}" number="${row.card.number}" score=${row.score}',
        );
      }
      final ranked = scored.map((row) => row.card).toList();
      final trustedNumber =
          _hasTrustedCollectorNumber(numberSource, wantNum);
      final best = ranked.isEmpty ? null : ranked.first;
      final secondScore = scored.length >= 2 ? scored[1].score : -9999;
      final topCore = scored.isNotEmpty
          ? _scannerCoreSpeciesName(scored.first.card.name)
          : '';

      if (scored.isNotEmpty &&
          topCore == 'froslass' &&
          scored.first.card.number.trim() == '265' &&
          (scored.first.score - secondScore) > 60) {
        // ignore: avoid_print
        print(
          'SCAN DEBUG [froslass-autopick] best="${scored.first.card.name}" '
          'set="${scored.first.card.setName}" '
          'number="${scored.first.card.number}" lead=${scored.first.score - secondScore}',
        );
        return ReliablePick(
          best: scored.first.card,
          candidates: ranked,
          strategy: 'fallback-froslass-265-autopick',
        );
      }

      if (best != null && !trustedNumber) {
        final bestFamily = _scannerVariantFamilyKey(best);
        final sameFamilyTop = scored
            .where((row) => _scannerVariantFamilyKey(row.card) == bestFamily)
            .toList();

        final sameFamilyCount = sameFamilyTop.length;

        final multipleNumberedVariants = sameFamilyTop
                .map((row) => row.card.number.trim())
                .where((n) => n.isNotEmpty)
                .toSet()
                .length >=
            2;

        final familyLead = sameFamilyTop.length >= 2
            ? (sameFamilyTop[0].score - sameFamilyTop[1].score)
            : 9999;

        final shouldBlockAutopick = sameFamilyCount >= 2 &&
            multipleNumberedVariants &&
            familyLead <= 40;

        if (shouldBlockAutopick) {
          if (imagePath != null && imagePath.trim().isNotEmpty) {
            final shortlist = sameFamilyTop
                .take(3)
                .map((row) => row.card)
                .toList();
            final visualBest = await _breakVariantTieVisually(
              imagePath: imagePath,
              candidates: shortlist,
            );
            if (visualBest != null) {
              // ignore: avoid_print
              print(
                'SCAN DEBUG [variant-visual-tiebreak] '
                'picked="${visualBest.name}" number="${visualBest.number}" family="$bestFamily"',
              );
              return ReliablePick(
                best: visualBest,
                candidates: ranked,
                strategy: 'fallback-visual-tiebreak',
              );
            }
          }

          // ignore: avoid_print
          print(
            'SCAN DEBUG [variant-ambiguous] trustedNumber=$trustedNumber '
            'family="$bestFamily" sameFamilyCount=$sameFamilyCount '
            'top1=${sameFamilyTop[0].score} top2=${sameFamilyTop[1].score} '
            'lead=$familyLead',
          );

          return ReliablePick(
            best: null,
            candidates: ranked,
            strategy: 'fallback-candidates',
          );
        }
      }

      final topRanked = ranked.isEmpty ? null : ranked.first;
      if (topRanked != null && !trustedNumber) {
        // ignore: avoid_print
        print(
          'SCAN DEBUG [fallback-direct-top-ranked] '
          'trustedNumber=$trustedNumber '
          'best="${topRanked.name}" '
          'bestNumber="${topRanked.number}" '
          'bestSet="${topRanked.setName}"',
        );

        return ReliablePick(
          best: topRanked,
          candidates: ranked,
          strategy: 'fallback-top-ranked-untrusted',
        );
      }

      final promoted = _promoteScannerCandidate(
        cards: fallbackCandidates,
        ocrName: safeName,
        ocrNumber: wantNum,
        numberSource: numberSource,
        ocrPrintedTotal: wantTotal,
        ocrHp: hp,
      );

      if (promoted != null) {
        return ReliablePick(
          best: promoted,
          candidates: fallbackCandidates,
          strategy: 'fallback-promoted',
        );
      }

      if (scored.isNotEmpty && scored.first.score > 0) {
        return ReliablePick(
          best: scored.first.card,
          candidates: fallbackCandidates,
          strategy: 'fallback-top-scored',
        );
      }

      if (!useScannerConfidence && fallbackCandidates.length == 1) {
        return ReliablePick(
          best: fallbackCandidates.first,
          candidates: fallbackCandidates,
          strategy: 'fallback-single',
        );
      }

      return ReliablePick(
        best: null,
        candidates: fallbackCandidates,
        strategy: 'fallback-candidates',
      );
    }

    // ignore: avoid_print
    print(
      'SCAN DEBUG [final-empty] name="$safeName" number="${wantNum ?? ''}" '
      'setTotal=${wantTotal ?? 'null'} hp=${hp ?? 'null'}',
    );

    // Everything below is direct API only
    if (kDisableDirectTcgApi) {
      return ReliablePick(
        best: null,
        candidates: const [],
        strategy: 'worker-only',
      );
    }

    // (your existing direct API fallbacks can stay here if you ever re-enable it)
    return ReliablePick(best: null, candidates: const [], strategy: 'empty');
  }
}

