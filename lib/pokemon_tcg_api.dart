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
    final t = (raw ?? '').trim();
    if (t.isEmpty) return null;

    // Keep alnum and slash only.
    final cleaned = t.replaceAll(RegExp(r'[^A-Za-z0-9/]'), '').trim();
    if (cleaned.isEmpty) return null;
    return cleaned;
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
    final mDigits = RegExp(r'^0*(\d{1,4})$').firstMatch(t);
    if (mDigits != null) {
      out.add(int.parse(mDigits.group(1)!).toString());
      out.add(t);
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

  int? _parseSetTotal(String? raw) {
    final t = (raw ?? '').trim();
    if (t.isEmpty) return null;
    final m = RegExp(r'(\d{2,4})').firstMatch(t);
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  // ------------------- HTTP / parsing -------------------

  Future<http.Response> _get(Uri uri) async {
    final resp = await http
        .get(uri, headers: _headers())
        .timeout(const Duration(seconds: 10));

    // Debug prints (keep for now)
    final body = resp.body;
    final previewLen = body.length < 200 ? body.length : 200;
    // ignore: avoid_print
    print('🛰️ TCG URL: $uri');
    // ignore: avoid_print
    print('🛰️ TCG STATUS: ${resp.statusCode}');
    // ignore: avoid_print
    print('🛰️ TCG BODY (first 200): ${body.substring(0, previewLen)}');

    return resp;
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
      // Try a couple variants (helps with TG05/TG30, leading zeros, promos)
      final variants = _collectorVariants(cleanNum!).take(2).toList();
      for (final v in variants) {
        parts.add('number:"${_escapeLucene(v)}"');
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
  Future<ReliablePick> searchCardsReliable({
    required String name,
    String? number,
    String? setTotal,
    int? hp,
    String? stage,
  }) async {
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
        pageSize: 50,
      );
    }

    if (live.isEmpty) {
      return ReliablePick(best: null, candidates: const [], strategy: 'empty');
    }

    // Score results locally
    final wantNum = _cleanCollectorNumber(number);
    final wantTotal = _parseSetTotal(setTotal);
    final wantStage = (stage ?? '').trim().toLowerCase();

    int score(PokemonCardResult c) {
      var s = 0;

      // number match
      if (wantNum != null && wantNum.isNotEmpty) {
        final cn = c.number.toUpperCase();
        if (cn == wantNum.toUpperCase()) s += 60;
        if (wantTotal != null && cn == '${wantNum.toUpperCase()}/$wantTotal')
          s += 80;
        if (cn.contains('/') && cn.split('/').first == wantNum.toUpperCase())
          s += 35;
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
      final safeName = _cleanName(name).toLowerCase();
      if (safeName.isNotEmpty) {
        final tokens = safeName
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
