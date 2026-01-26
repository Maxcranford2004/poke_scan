import 'dart:convert';
import 'dart:math';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import 'pokemon_models.dart';

/// Pass your key at run-time (don’t hardcode it):
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

  // ------------------- Cleaning / normalization -------------------

  String _cleanName(String s) {
    var t = s.trim();
    if (t.isEmpty) return '';

    t = t.replaceAll('’', "'");
    t = t.replaceAll(RegExp(r"[^A-Za-z0-9\s\-']"), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();

    // ✅ Fix common OCR confusion: lowercase 'l' mistaken for capital 'I'
    if (t.toLowerCase().startsWith('lvysaur')) t = 'ivysaur';
    if (t.toLowerCase().startsWith('snorlaz')) t = 'snorlax';

    // ✅ NEW: if OCR glues garbage letters before the real Pokémon name,
    // keep the last "wordy" chunk (common when Stage/labels get attached)
    // Example: "STAEEGengar" -> "Gengar"
    // Example: "STAGE Gengar" -> "Gengar"
    // If OCR glued garbage letters before the real name (e.g. "STAEEGengar"),
    // keep the trailing capitalized name chunk, BUT only when it looks like that pattern.
    if (!t.contains(' ')) {
      final m2 = RegExp(r'([A-Z][a-z]{2,})$').firstMatch(t);
      if (m2 != null) {
        final tail = m2.group(1)!;
        // Only apply if it actually shortens the string meaningfully (avoids harming legit names)
        if (tail.length >= 4 && tail.length <= 20 && tail.length < t.length) {
          t = tail;
        }
      }
    }

    // ✅ NEW: If it's one long token and contains a known name at the end,
    // keep the trailing capitalized run (helps "STAEEGengar" style)
    if (!t.contains(' ') && t.length > 8) {
      final m2 = RegExp(r'([A-Z][a-z]{2,})$').firstMatch(t);
      if (m2 != null) t = m2.group(1)!;
    }

    return t;
  }

  String _escapeLucene(String s) {
    // Escape quotes/backslashes for the API query syntax.
    return s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  }

  /// Returns something like:
  /// - "65"
  /// - "TG5"
  /// - "SWSH20"
  /// - "183/165"
  String? _cleanCollectorNumber(String? raw) {
    if (raw == null) return null;
    var t = raw.trim();
    if (t.isEmpty) return null;

    // If OCR gives "39/73" or "183/165", keep only the left side for searching.
    if (t.contains('/')) t = t.split('/').first.trim();

    // Promo / prefix+digits (SWSH127, TG05, etc.)
    final mPref = RegExp(r'^([A-Za-z]{1,8})\s*0*(\d{1,4})$').firstMatch(t);
    if (mPref != null) {
      final pref = mPref.group(1)!.toUpperCase();
      final num = int.parse(
        mPref.group(2)!,
      ).toString(); // removes leading zeros
      return '$pref$num';
    }

    // Digits only
    final digits = t.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;

    final normalized = digits.replaceFirst(RegExp(r'^0+'), '');
    if (normalized.isEmpty) return null;

    // common OCR artifact: extra leading digit on 3-digit numbers (2183 -> 183)
    if (normalized.length == 4) return normalized.substring(1);

    // clamp weird long digit strings to last 3 digits
    return normalized.length > 3
        ? normalized.substring(normalized.length - 3)
        : normalized;
  }

  List<String> _collectorVariants(String collector) {
    final t = collector.trim();
    if (t.isEmpty) return const [];

    final out = <String>{};

    // If fraction like 183/165, keep as is + also left side.
    if (t.contains('/')) {
      out.add(t);
      final left = t.split('/').first;
      if (left.isNotEmpty) out.add(left);
      return out.toList();
    }

    // Digits only: strip leading zeros.
    // Also: if OCR accidentally prepends a digit (e.g. 2183), try the tail (183).
    final mDigits = RegExp(r'^0*(\d{1,4})$').firstMatch(t);
    if (mDigits != null) {
      final normalized = int.parse(mDigits.group(1)!).toString();
      out.add(normalized);
      out.add(t);

      // Fix common OCR artifact: extra leading digit on 3-digit numbers (2183 -> 183)
      if (normalized.length == 4) {
        out.add(normalized.substring(1)); // last 3 digits
        out.add(normalized.substring(2)); // last 2 digits (backup)
      }

      return out.toList();
    }

    // Prefix+digits (TG05, SWSH020)
    final mPref = RegExp(r'^([A-Za-z]{1,6})0*(\d{1,4})$').firstMatch(t);
    if (mPref != null) {
      final pref = mPref.group(1)!.toUpperCase();
      final num = int.parse(mPref.group(2)!).toString();
      out.add('$pref$num');
      out.add('$pref${mPref.group(2)!}'); // keep original digits too
      out.add(t.toUpperCase());
      return out.toList();
    }

    out.add(t);
    out.add(t.toUpperCase());
    return out.toList();
  }

  int? _parseSetTotal(String? s) {
    if (s == null) return null;

    // keep digits only
    final digits = s.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;

    final n = int.tryParse(digits);
    if (n == null) return null;

    // sanity range (sets are usually < 400)
    if (n < 10 || n > 400) return null;

    return n;
  }

  // ------------------- HTTP / parsing -------------------

  Future<http.Response> _get(Uri uri) async {
    const maxAttempts = 3;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        // Print BEFORE request so timeouts still show which URL we tried.
        // ignore: avoid_print
        print('🛰️ TCG GET (attempt $attempt/$maxAttempts) → $uri');

        final resp = await http
            .get(uri, headers: _headers())
            .timeout(const Duration(seconds: 25));

        // Debug prints
        final body = resp.body;
        final previewLen = body.length < 200 ? body.length : 200;
        // ignore: avoid_print
        print('🛰️ TCG STATUS: ${resp.statusCode}');
        // ignore: avoid_print
        print('🛰️ TCG BODY (first 200): ${body.substring(0, previewLen)}');

        return resp;
      } catch (e) {
        // On last attempt, rethrow.
        if (attempt == maxAttempts) rethrow;

        // Small exponential-ish backoff (250ms, 500ms)
        await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
      }
    }

    // Unreachable, but Dart wants a return.
    throw StateError('unreachable');
  }

  List<PokemonCardResult> _parseCardList(String body) {
    final decoded = jsonDecode(body);
    final data = decoded is Map ? decoded['data'] : null;
    if (data is! List) return const [];

    return data
        .whereType<Map>()
        .map((e) => PokemonCardResult.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  PokemonCardResult? _parseSingleCard(String body) {
    final decoded = jsonDecode(body);
    final data = decoded is Map ? decoded['data'] : null;
    if (data is! Map) return null;
    return PokemonCardResult.fromJson(Map<String, dynamic>.from(data));
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

  /// BROAD search by name/number/setTotal. We intentionally do NOT include hp/stage
  /// in the query because they are often missing/inconsistent.
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

    // Allow number-only searches (OCR name may be wrong)
    final hasName = safeName.isNotEmpty;
    final hasNumber = cleanNum != null && cleanNum.isNotEmpty;
    if (!hasName && !hasNumber) return <PokemonCardResult>[];

    final parts = <String>[];

    if (hasName) {
      // token search is more forgiving than quoting the whole string
      final tokens = safeName
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .toList();
      for (final t in tokens.take(3)) {
        parts.add('name:${_escapeLucene(t)}');
      }
    }

    if (safeSet.isNotEmpty) {
      parts.add('set.name:"${_escapeLucene(_cleanName(safeSet))}"');
    }

    if (hasNumber) {
      var baseNum = cleanNum!.trim();

      // If it contains a slash, keep only the left side (e.g. 183/165 -> 183)
      if (baseNum.contains('/')) {
        baseNum = baseNum.split('/').first.trim();
      }

      final variants = <String>[];

      final hasLetters = RegExp(r'[A-Za-z]').hasMatch(baseNum);

      if (hasLetters) {
        // PROMO/PREFIX numbers (SWSH127, TG05, etc.)
        // Keep as-is (already cleaned by _cleanCollectorNumber)
        variants.add(baseNum.toUpperCase());

        // Also try digits-only as a fallback (sometimes OCR drops prefix)
        final digitsOnly = baseNum.replaceAll(RegExp(r'[^0-9]'), '');
        if (digitsOnly.isNotEmpty) variants.add(digitsOnly);
      } else {
        // DIGITS-only collector numbers
        var digits = baseNum.replaceAll(RegExp(r'[^0-9]'), '');
        if (digits.isNotEmpty) baseNum = digits;

        variants.add(baseNum);

        // If OCR made it 4 digits, also try the last 3 digits (2183 -> 183).
        if (baseNum.length == 4) {
          variants.add(baseNum.substring(1));
        }
      }

      // De-dupe + keep small
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
      // Key field to disambiguate 15/108 vs 16/181 etc
      parts.add('set.printedTotal:$printedTotal');
    }

    final q = parts.join(' ');
    final uri = Uri.https(_host, _cardsPath, {
      'q': q,
      'pageSize': pageSize.toString(),
      'orderBy': '-set.releaseDate',
    });

    final resp = await _get(uri);
    if (resp.statusCode != 200) {
      throw Exception('TCG API ${resp.statusCode}');
    }

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

    // Treat "label" OCR results as not-a-real-name (common on Trainer/Energy cards)
    final isLabel =
        lowerName == 'trainer' ||
        lowerName == 'traner' ||
        lowerName == 'pokemon' ||
        lowerName == 'energy' ||
        lowerName == 'traner'; // keep extra variant if OCR keeps doing this

    // If label-only, do number-only search and NEVER auto-pick a single card.
    if (isLabel) {
      if (wantNum == null || wantNum.isEmpty) {
        return ReliablePick(
          best: null,
          candidates: const [],
          strategy: 'label-empty',
        );
      }

      // IMPORTANT: ignore setTotal here (trainer banners hallucinate totals like 286)
      var live = await refreshSearch(
        name: '',
        set: null,
        number: wantNum,
        setTotal: null,
        pageSize: 50,
      );

      // Filter by supertype when possible to reduce junk
      if (lowerName == 'trainer' || lowerName == 'traner') {
        live = live
            .where((c) => (c.supertype ?? '').toLowerCase() == 'trainer')
            .toList();
      } else if (lowerName == 'energy') {
        // Energy cards are usually supertype = "Energy"
        live = live
            .where((c) => (c.supertype ?? '').toLowerCase() == 'energy')
            .toList();
      }

      // If filtering nukes everything, fall back to unfiltered list
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
        best: null, // <- key behavior change
        candidates: live.take(12).toList(),
        strategy: 'label-candidates',
      );
    }

    // ---------------- Normal Pokémon-style flow ----------------

    // Broad live search
    var live = await refreshSearch(
      name: name,
      set: null,
      number: number,
      setTotal: setTotal,
      pageSize: 50,
    );

    // If nothing, try name-only
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

    // Score results locally
    final wantTotal = _parseSetTotal(setTotal);
    final wantStage = (stage ?? '').trim().toLowerCase();

    int score(PokemonCardResult c) {
      var s = 0;

      // number match
      if (wantNum != null && wantNum.isNotEmpty) {
        final cn = (c.number).toUpperCase();

        if (cn == wantNum.toUpperCase()) s += 60;

        if (wantTotal != null && cn == '${wantNum.toUpperCase()}/$wantTotal') {
          s += 80;
        }

        if (cn.contains('/') && cn.split('/').first == wantNum.toUpperCase()) {
          s += 35;
        }
      }

      // set printed total match
      if (wantTotal != null && c.setPrintedTotal == wantTotal) s += 30;

      // hp match
      if (hp != null && c.hp == hp) s += 18;

      // stage match (only check if provided)
      if (wantStage.isNotEmpty) {
        for (final st in c.subtypes) {
          if (st.toLowerCase() == wantStage) {
            s += 14;
            break;
          }
        }
      }

      // name tokens match
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

    // Confidence rule: good score and clear separation
    final confident = bestScore >= 80 && (bestScore - secondScore) >= 12;

    return ReliablePick(
      best: confident ? best : null,
      candidates: live.take(6).toList(),
      strategy: confident ? 'confident' : 'candidates',
    );
  }
}
