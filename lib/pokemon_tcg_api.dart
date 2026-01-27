import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import 'pokemon_models.dart';

/// flutter run --dart-define=POKEMON_TCG_API_KEY=YOUR_KEY
const String kPokemonTcgApiKey = String.fromEnvironment(
  'POKEMON_TCG_API_KEY',
  defaultValue: '',
);

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

class PokemonTcgApi {
  static const String _host = 'api.pokemontcg.io';
  static const String _cardsPath = '/v2/cards';
  static const String _cacheBoxName = 'tcg_cache_v2';

  static Box? _cacheBox;

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

  Map<String, String> _headers() {
    final h = <String, String>{'Accept': 'application/json'};
    if (kPokemonTcgApiKey.isNotEmpty) {
      h['X-Api-Key'] = kPokemonTcgApiKey;
    }
    return h;
  }

  // ------------------- Small JSON helpers -------------------

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

    // common OCR confusion
    if (t.toLowerCase().startsWith('lvysaur')) t = 'ivysaur';
    if (t.toLowerCase().startsWith('snorlaz')) t = 'snorlax';

    // glued prefix garbage like "STAEEGengar" -> "Gengar"
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

  /// Returns cleaned collector number:
  /// - digits-only => "183"
  /// - prefix+digits => "SWSH127", "TG5"
  String? _cleanCollectorNumber(String? raw) {
    if (raw == null) return null;
    var t = raw.trim();
    if (t.isEmpty) return null;

    // If OCR gives "183/165", keep only left side
    if (t.contains('/')) t = t.split('/').first.trim();

    // Prefix+digits
    final pref = RegExp(r'^([A-Za-z]{1,8})\s*0*(\d{1,4})$').firstMatch(t);
    if (pref != null) {
      final prefix = pref.group(1)!.toUpperCase();
      final num = int.parse(pref.group(2)!).toString();
      return '$prefix$num';
    }

    // Digits only
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
    if (n < 10 || n > 400) return null;
    return n;
  }

  // ------------------- HTTP / parsing -------------------

  Future<http.Response> _get(Uri uri) async {
    const maxAttempts = 3;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        // keep logs readable
        // ignore: avoid_print
        print('🛰️ TCG GET ($attempt/$maxAttempts) → $uri');

        final resp = await http
            .get(uri, headers: _headers())
            .timeout(const Duration(seconds: 25));

        // ignore: avoid_print
        print('🛰️ STATUS: ${resp.statusCode}');

        return resp;
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

  // ------------------- Set index (Step 2 / grayscale previews) -------------------

  /// Fetches ALL cards for a set (used for “what card goes in this slot?” previews).
  /// Cached under: setindex|<setId>
  Future<List<PokemonCardResult>> fetchAllCardsForSet(String setId) async {
    final cacheKey = 'setindex|$setId';
    final cached = _box.get(cacheKey);
    if (cached is String) {
      try {
        return _parseCardList(cached);
      } catch (_) {}
    }

    const pageSize = 250;
    var page = 1;
    final all = <PokemonCardResult>[];

    while (true) {
      final uri = Uri.https(_host, _cardsPath, {
        'q': 'set.id:$setId',
        'pageSize': pageSize.toString(),
        'page': page.toString(),
        'orderBy': 'number',
      });

      final resp = await _get(uri);

      // API has been flaky for you. Don’t crash the app.
      if (resp.statusCode != 200) {
        break;
      }

      final batch = _parseCardList(resp.body);
      all.addAll(batch);

      if (batch.length < pageSize) break; // last page
      page++;

      // safety cap
      if (page > 25) break;
    }

    // Cache combined list as a wrapped JSON that _parseCardList understands.
    final wrapped = {'data': all.map((c) => c.toJson()).toList()};
    await _box.put(cacheKey, jsonEncode(wrapped));

    return all;
  }

  // ------------------- Public API used by your app -------------------

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
    if (raw is! String) return const [];
    try {
      return _parseCardList(raw);
    } catch (_) {
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

  /// BROAD search by name/number/setTotal.
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

    final hasName = safeName.isNotEmpty;
    final hasNumber = cleanNum != null && cleanNum.isNotEmpty;
    if (!hasName && !hasNumber) return <PokemonCardResult>[];

    final parts = <String>[];

    // include name tokens only if we do NOT have a collector number
    if (hasName && !hasNumber) {
      final tokens = safeName
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .take(3);
      for (final t in tokens) {
        parts.add('name:${_escapeLucene(t)}');
      }
    }

    if (safeSet.isNotEmpty) {
      parts.add('set.name:"${_escapeLucene(_cleanName(safeSet))}"');
    }

    if (hasNumber) {
      // Try 1–2 safe variants (handles common OCR artifacts like 2183 -> 183)
      final variants = <String>[];

      var base = cleanNum!.trim();

      // If OCR gives "183/165", keep only left side
      if (base.contains('/')) base = base.split('/').first.trim();

      final hasLetters = RegExp(r'[A-Za-z]').hasMatch(base);

      if (hasLetters) {
        // Promo/prefix numbers (TG05, SWSH127...)
        variants.add(base.toUpperCase());

        // Also try digits-only fallback
        final digitsOnly = base.replaceAll(RegExp(r'[^0-9]'), '');
        if (digitsOnly.isNotEmpty) variants.add(digitsOnly);
      } else {
        // Digits-only
        var digits = base.replaceAll(RegExp(r'[^0-9]'), '');
        if (digits.isNotEmpty) base = digits;

        variants.add(base);

        // Common OCR artifact: extra leading digit on a 3-digit number (2183 -> 183)
        if (base.length == 4) variants.add(base.substring(1));
      }

      // de-dupe and keep small (max 2)
      final uniq = <String>{};
      final finalVariants = <String>[];
      for (final v in variants) {
        final t = v.trim();
        if (t.isEmpty) continue;
        if (uniq.add(t)) finalVariants.add(t);
        if (finalVariants.length >= 2) break;
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
    final uri = Uri.https(_host, _cardsPath, {
      'q': q,
      'pageSize': pageSize.toString(),
      'orderBy': '-set.releaseDate',
    });

    final resp = await _get(uri);

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

    // IMPORTANT: if live fetch fails, DO NOT wipe the UI.
    // Return cached results instead (if any). This prevents the “flash then no results” bug.
    final cached = await getCachedSearch(
      name: name,
      set: set,
      number: number,
      setTotal: setTotal,
      pageSize: pageSize,
    );

    if (cached.isNotEmpty) {
      // ignore: avoid_print
      print(
        '⚠️ Live search failed (${resp.statusCode}). Keeping cached results (${cached.length}).',
      );
      return cached;
    }

    // If there was no cache to fall back to:
    if (resp.statusCode == 404) return <PokemonCardResult>[];

    throw Exception('TCG API ${resp.statusCode}');
  }

  Future<PokemonCardResult?> fetchCardById(String id) async {
    final cacheKey = 'card|$id';
    final cached = _box.get(cacheKey);
    if (cached is String) {
      try {
        final card = _parseSingleCard(cached);
        if (card != null) return card;
      } catch (_) {}
    }

    final uri = Uri.https(_host, '$_cardsPath/$id');
    final resp = await _get(uri);
    if (resp.statusCode != 200) return null;

    await _box.put(cacheKey, resp.body);
    return _parseSingleCard(resp.body);
  }

  /// Reliable scan strategy for RecognizingScreen.
  /// Returns best card if confident, else candidates list.
  Future<ReliablePick> searchCardsReliable({
    required String name,
    String? number,
    String? setTotal,
    int? hp,
    String? stage,
  }) async {
    final safeName = _cleanName(name);
    final lowerName = safeName.toLowerCase().trim();
    final wantNum = _cleanCollectorNumber(number);

    final isLabel =
        lowerName == 'trainer' ||
        lowerName == 'traner' ||
        lowerName == 'pokemon' ||
        lowerName == 'energy';

    if (isLabel) {
      if (wantNum == null || wantNum.isEmpty) {
        return ReliablePick(
          best: null,
          candidates: const [],
          strategy: 'label-empty',
        );
      }

      var live = await refreshSearch(
        name: '',
        set: null,
        number: wantNum,
        setTotal: null,
        pageSize: 50,
      );

      // Filter by supertype if possible
      if (lowerName == 'trainer' || lowerName == 'traner') {
        live = live
            .where((c) => (c.supertype ?? '').toLowerCase() == 'trainer')
            .toList();
      } else if (lowerName == 'energy') {
        live = live
            .where((c) => (c.supertype ?? '').toLowerCase() == 'energy')
            .toList();
      }

      if (live.isEmpty) {
        live = await refreshSearch(
          name: '',
          set: null,
          number: wantNum,
          setTotal: null,
          pageSize: 50,
        );
      }

      return ReliablePick(
        best: null,
        candidates: live.take(12).toList(),
        strategy: 'label-candidates',
      );
    }

    // Normal flow
    var live = await refreshSearch(
      name: name,
      set: null,
      number: number,
      setTotal: setTotal,
      pageSize: 50,
    );

    if (live.isEmpty) {
      live = await refreshSearch(
        name: name,
        set: null,
        number: null,
        setTotal: null,
        pageSize: 250,
      );
    }

    if (live.isEmpty) {
      return ReliablePick(best: null, candidates: const [], strategy: 'empty');
    }

    final wantTotal = _parseSetTotal(setTotal);
    final wantStage = (stage ?? '').trim().toLowerCase();

    int score(PokemonCardResult c) {
      var s = 0;

      // number match
      if (wantNum != null && wantNum.isNotEmpty) {
        final cn = c.number.toUpperCase();
        if (cn == wantNum.toUpperCase()) s += 60;

        if (wantTotal != null &&
            cn.contains('/') &&
            cn.split('/').first == wantNum.toUpperCase()) {
          s += 35;
        }
      }

      if (wantTotal != null && c.setPrintedTotal == wantTotal) s += 30;
      if (hp != null && c.hp == hp) s += 18;

      if (wantStage.isNotEmpty) {
        for (final st in c.subtypes) {
          if (st.toLowerCase() == wantStage) {
            s += 14;
            break;
          }
        }
      }

      final safe = _cleanName(name).toLowerCase();
      if (safe.isNotEmpty) {
        final tokens = safe
            .split(RegExp(r'\s+'))
            .where((t) => t.isNotEmpty)
            .take(3);
        final hay = c.name.toLowerCase();
        for (final t in tokens) {
          if (hay.contains(t)) s += 6;
        }
      }

      return s;
    }

    live.sort((a, b) => score(b).compareTo(score(a)));

    final best = live.first;
    final bestScore = score(best);
    final secondScore = live.length > 1 ? score(live[1]) : -999;

    final confident = bestScore >= 80 && (bestScore - secondScore) >= 12;

    return ReliablePick(
      best: confident ? best : null,
      candidates: live.take(6).toList(),
      strategy: confident ? 'confident' : 'candidates',
    );
  }
}
