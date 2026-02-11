import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

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
const bool kDisableDirectTcgApi = true;

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

  // ------------------- HTTP (direct upstream) -------------------

  Future<http.Response> _get(Uri uri) async {
    const maxAttempts = 3;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        var reqUri = uri;

        // sanitize known ghost typos right before sending
        final qp = Map<String, String>.from(reqUri.queryParameters);
        final ob = qp['orderBy'];
        if (ob != null) {
          final fixed = ob.replaceAll('reeleaseDate', 'releaseDate');
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

  // ------------------- Set index -------------------

  Future<List<PokemonCardResult>> fetchAllCardsForSet(String setId) async {
    final cacheKey = 'setindex|$setId';
    final cached = _box.get(cacheKey);
    if (cached is String) {
      try {
        return _parseCardList(cached);
      } catch (_) {}
    }

    // ✅ Prefer Worker D1 set-index for Pokédex previews
    try {
      final uri = Uri.parse('$_proxyBase/set-index?setId=$setId');
      final resp = await http.get(uri);

      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map &&
            decoded['ok'] == true &&
            decoded['cards'] is List) {
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

          final wrapped = {'data': cards.map((c) => c.toJson()).toList()};
          await _box.put(cacheKey, jsonEncode(wrapped));
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

        final batch = _parseCardList(resp.body);
        all.addAll(batch);

        if (batch.length < pageSize) {
          final wrapped = {'data': all.map((c) => c.toJson()).toList()};
          await _box.put(cacheKey, jsonEncode(wrapped));
          return all;
        }

        page++;
        if (page > 20) break;
      }
    }

    return <PokemonCardResult>[];
  }

  // ------------------- Search (direct upstream) -------------------

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
      final variants = <String>[];
      var base = cleanNum!.trim();
      if (base.contains('/')) base = base.split('/').first.trim();

      final hasLetters = RegExp(r'[A-Za-z]').hasMatch(base);
      if (hasLetters) {
        variants.add(base.toUpperCase());
        final digitsOnly = base.replaceAll(RegExp(r'[^0-9]'), '');
        if (digitsOnly.isNotEmpty) variants.add(digitsOnly);
      } else {
        final digits = base.replaceAll(RegExp(r'[^0-9]'), '');
        if (digits.isNotEmpty) base = digits;

        variants.add(base);
        if (base.length == 4) variants.add(base.substring(1)); // 2183 -> 183
      }

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

    // ignore: avoid_print
    print('✅ USING RELEASEDATE orderBy=-set.releaseDate');

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
    String? setTotal,
    int? hp,

    // optional (slot locked scans from Pokédex)
    String? expectedSetId,
    int? expectedSlot,
    int? svpSlot,
  }) async {
    final safeName = _cleanName(name);
    final lowerName = safeName.toLowerCase().trim();
    final wantNum = _cleanCollectorNumber(number);
    final wantTotal = _parseSetTotal(setTotal);

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

      final uri = _proxyUri('/scan-lookup', qp);
      final j = await _proxyGetJson(uri);

      if (j['ok'] == true) {
        if (j['found'] == true && j['best'] is Map) {
          final best = _fromWorkerRow(
            (j['best'] as Map).cast<String, dynamic>(),
          );
          return ReliablePick(
            best: best,
            candidates: const [],
            strategy: 'worker-best',
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
              strategy: 'worker-candidates',
            );
          }
        }
      }

      return null;
    }

    try {
      // 1) Normal attempt (with name, strict if safe)
      final a = await tryWorker(includeName: true, includeStrict: true);
      if (a != null) return a;

      // 2) If label-ish / risky name, retry without name (keeps number/total/hp)
      if (isLabel || safeName.isEmpty) {
        final b = await tryWorker(includeName: false, includeStrict: true);
        if (b != null) return b;
      }

      // 3) If strict was on, loosen strict (sometimes OCR total is wrong)
      final c = await tryWorker(includeName: true, includeStrict: false);
      if (c != null) return c;

      // 4) Last resort: no name + no strict (for trainer label cases)
      final d = await tryWorker(includeName: false, includeStrict: false);
      if (d != null) return d;
    } catch (e) {
      // ignore: avoid_print
      print('⚠️ worker scan-lookup failed: $e');
    }

    // If label-only and no number, nothing useful (worker-only mode)
    if (isLabel && (wantNum == null || wantNum.isEmpty)) {
      return ReliablePick(
        best: null,
        candidates: const [],
        strategy: 'label-empty',
      );
    }

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
