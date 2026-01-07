import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';

import 'pokemon_models.dart';

/// Resilient client for https://api.pokemontcg.io/v2
///
/// Goals:
/// - Fast: return cached results instantly if we have them (even if stale)
/// - Stable: retry on transient errors, and never hang forever
/// - Accurate: use official query syntax and fetch tcgplayer prices when available
class PokemonTcgApi {
  final String? apiKey;
  PokemonTcgApi({this.apiKey});

  static const String _host = 'api.pokemontcg.io';
  static const String _cardsPath = '/v2/cards';

  // Persistent cache (Hive)
  static const String _boxName = 'poke_cache_v1';
  static const Duration _softTtl = Duration(days: 14);

  // Network behavior
  static const Duration _liveTimeout = Duration(seconds: 12);
  static const int _maxAttempts = 3;

  /// Call once at startup (in main()) after Hive.initFlutter()
  static Future<void> ensureCacheReady() async {
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.openBox(_boxName);
    }
  }

  static Future<Box> _box() async {
    if (Hive.isBoxOpen(_boxName)) return Hive.box(_boxName);
    return Hive.openBox(_boxName);
  }

  /// Instant: read cached search results (if any). Never throws.
  Future<List<PokemonCardResult>> getCachedSearch({
    required String name,
    String? set,
    String? number,
  }) async {
    final key = _searchKey(name: name, set: set, number: number);
    try {
      final box = await _box();
      final raw = box.get('search:$key');
      if (raw is Map) {
        final dataStr = raw['data'];
        if (dataStr is String && dataStr.isNotEmpty) {
          final decoded = jsonDecode(dataStr);
          if (decoded is List) {
            return decoded
                .whereType<Map>()
                .map(
                  (m) =>
                      PokemonCardResult.fromJson(Map<String, dynamic>.from(m)),
                )
                .toList();
          }
        }
      }
    } catch (_) {}
    return <PokemonCardResult>[];
  }

  /// Live refresh: hits the network and updates cache on success.
  /// Throws a friendly Exception on failure.
  Future<List<PokemonCardResult>> refreshSearch({
    required String name,
    String? set,
    String? number,
    int pageSize = 20,
  }) async {
    final safeName = _cleanName(name);
    final safeNumber = _cleanNumber(number);

    if (safeName.isEmpty) return <PokemonCardResult>[];

    // Try "specific" first, then relax if needed.
    final results = await _searchLive(
      name: safeName,
      set: set,
      number: safeNumber,
      pageSize: pageSize,
    );

    if (results.isEmpty && (set != null || safeNumber != null)) {
      // fallback: name-only, because OCR/inputs can be noisy
      final relaxed = await _searchLive(
        name: safeName,
        set: null,
        number: null,
        pageSize: pageSize,
      );
      return relaxed;
    }

    return results;
  }

  /// Convenience: returns cached results if available; otherwise does a live refresh.
  Future<List<PokemonCardResult>> searchCards({
    required String name,
    String? set,
    String? number,
    int pageSize = 20,
  }) async {
    final cached = await getCachedSearch(name: name, set: set, number: number);
    if (cached.isNotEmpty) return cached;
    return refreshSearch(
      name: name,
      set: set,
      number: number,
      pageSize: pageSize,
    );
  }

  /// Fetch one card by ID (for details screen).
  /// Returns null if not found.
  Future<PokemonCardResult?> fetchCardById(String id) async {
    final safeId = id.trim();
    if (safeId.isEmpty) return null;

    // 1) Cache first
    final cached = await _getCachedCard(safeId);
    if (cached != null) return cached;

    // 2) Live
    final uri = Uri.https(_host, '$_cardsPath/$safeId', {
      'select': 'id,name,number,set,images,tcgplayer',
    });

    final headers = _headers();
    final resp = await _getWithRetry(uri, headers);

    if (resp.statusCode == 200) {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final data = json['data'];
      if (data is Map<String, dynamic>) {
        final card = _parseCard(data);
        await _putCachedCard(card);
        return card;
      }
      return null;
    }

    if (resp.statusCode == 404) return null;

    throw Exception(
      'Live card details unavailable right now. Please try again.',
    );
  }

  Map<String, String> _headers() {
    final h = <String, String>{'Accept': 'application/json'};
    final k = apiKey?.trim();
    if (k != null && k.isNotEmpty) {
      h['X-Api-Key'] = k;
    }
    return h;
  }

  static String _searchKey({
    required String name,
    String? set,
    String? number,
  }) {
    return '${name.trim().toLowerCase()}|${(set ?? '').trim().toLowerCase()}|${(number ?? '').trim().toLowerCase()}';
  }

  static bool _isSoftFresh(DateTime savedAt) =>
      DateTime.now().difference(savedAt) < _softTtl;

  Future<List<PokemonCardResult>> _searchLive({
    required String name,
    String? set,
    String? number,
    int pageSize = 20,
  }) async {
    final q = _buildQuery(name: name, set: set, number: number);

    final uri = Uri.https(_host, _cardsPath, {
      'q': q,
      'pageSize': pageSize.toString(),
      'orderBy': '-set.releaseDate',
      'select': 'id,name,number,set,images,tcgplayer',
    });

    final headers = _headers();
    final resp = await _getWithRetry(uri, headers);

    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (data['data'] as List?) ?? const [];
      final results = list
          .whereType<Map>()
          .map((m) => _parseCard(Map<String, dynamic>.from(m)))
          .toList();

      // Write-through cache
      final key = _searchKey(name: name, set: set, number: number);
      await _putCachedSearch(key, results);

      return results;
    }

    if (resp.statusCode == 404) return <PokemonCardResult>[];

    throw Exception('Live results unavailable right now.');
  }

  Future<http.Response> _getWithRetry(
    Uri uri,
    Map<String, String> headers,
  ) async {
    var delayMs = 450;

    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        final resp = await http
            .get(uri, headers: headers)
            .timeout(_liveTimeout);

        if (resp.statusCode == 429 ||
            resp.statusCode == 502 ||
            resp.statusCode == 503 ||
            resp.statusCode == 504) {
          if (attempt == _maxAttempts) return resp;
          await Future.delayed(Duration(milliseconds: delayMs));
          delayMs *= 2;
          continue;
        }

        return resp;
      } on TimeoutException {
        if (attempt == _maxAttempts) {
          throw Exception(
            'Search timed out (Pokemon API). Try again in a moment.',
          );
        }
        await Future.delayed(Duration(milliseconds: delayMs));
        delayMs *= 2;
      } catch (_) {
        if (attempt == _maxAttempts) {
          throw Exception('Live results unavailable right now.');
        }
        await Future.delayed(Duration(milliseconds: delayMs));
        delayMs *= 2;
      }
    }

    return http.get(uri, headers: headers);
  }

  String _buildQuery({required String name, String? set, String? number}) {
    String esc(String s) => s.replaceAll('"', '\\"');

    final parts = <String>[];

    // Always quote name for reliability.
    parts.add('name:"${esc(name)}"');

    final setClean = set == null ? '' : _cleanName(set);
    if (setClean.trim().isNotEmpty) {
      parts.add('set.name:"${esc(setClean)}"');
    }

    if (number != null && number.trim().isNotEmpty) {
      parts.add('number:${number.trim()}');
    }

    return parts.join(' ');
  }

  String _cleanName(String raw) {
    var s = raw.replaceAll('’', "'");

    s = s.replaceAll(
      RegExp(
        r'\b(BASIC|BSIC|STAGE|TRAINER|ENERGY|POK[EÉ]MON)\b',
        caseSensitive: false,
      ),
      ' ',
    );

    // Keep letters, numbers, spaces, hyphen, apostrophe
    s = s.replaceAll(RegExp(r"[^A-Za-z0-9\s\-']"), ' ');

    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  String? _cleanNumber(String? raw) {
    if (raw == null) return null;
    final m = RegExp(r'\d{1,3}').firstMatch(raw);
    return m?.group(0);
  }

  PokemonCardResult _parseCard(Map<String, dynamic> c) {
    double? d(dynamic v) => v is num ? v.toDouble() : null;

    final images = c['images'] as Map<String, dynamic>?;
    final setObj = c['set'] as Map<String, dynamic>?;

    final tcg = c['tcgplayer'] as Map<String, dynamic>?;
    final prices = tcg?['prices'] as Map<String, dynamic>?;
    final url = tcg?['url']?.toString();

    final finishes = <String, PriceRow>{};
    if (prices != null) {
      for (final entry in prices.entries) {
        final finishName = entry.key;
        final m = entry.value;
        if (m is Map<String, dynamic>) {
          finishes[finishName] = PriceRow(
            market: d(m['market']),
            low: d(m['low']),
            mid: d(m['mid']),
            high: d(m['high']),
          );
        }
      }
    }

    return PokemonCardResult(
      id: (c['id'] ?? '').toString(),
      name: (c['name'] ?? '').toString(),
      setName: (setObj?['name'] ?? '').toString(),
      number: (c['number'] ?? '').toString(),
      imageSmall: (images?['small'] ?? '').toString(),
      imageLarge: (images?['large'] ?? '').toString(),
      tcgplayerUrl: url,
      finishes: finishes,
    );
  }

  Future<void> _putCachedSearch(
    String key,
    List<PokemonCardResult> results,
  ) async {
    try {
      final box = await _box();
      final payload = {
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'data': jsonEncode(results.map((e) => e.toJson()).toList()),
      };
      await box.put('search:$key', payload);
    } catch (_) {}
  }

  Future<PokemonCardResult?> _getCachedCard(String id) async {
    try {
      final box = await _box();
      final raw = box.get('card:$id');
      if (raw is Map) {
        final savedAtMs = raw['savedAt'];
        final dataStr = raw['data'];
        if (savedAtMs is int && dataStr is String) {
          final savedAt = DateTime.fromMillisecondsSinceEpoch(savedAtMs);
          if (_isSoftFresh(savedAt) || true) {
            final decoded = jsonDecode(dataStr);
            if (decoded is Map) {
              return PokemonCardResult.fromJson(
                Map<String, dynamic>.from(decoded),
              );
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _putCachedCard(PokemonCardResult card) async {
    try {
      final box = await _box();
      await box.put('card:${card.id}', {
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'data': jsonEncode(card.toJson()),
      });
    } catch (_) {}
  }
}
