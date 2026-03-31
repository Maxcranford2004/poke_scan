import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../pokemon_models.dart';

typedef UserIdProvider = String Function();

class FirestoreOwnedCardRecord {
  final PokemonCardResult card;
  final bool owned;
  final int quantity;
  final DateTime? dateAdded;

  const FirestoreOwnedCardRecord({
    required this.card,
    required this.owned,
    required this.quantity,
    required this.dateAdded,
  });
}

class FirestoreCollectionService {
  FirestoreCollectionService({
    FirebaseFirestore? firestore,
    UserIdProvider? userIdProvider,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _userIdProvider = userIdProvider ?? _defaultUserIdProvider;

  static String _defaultUserIdProvider() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return 'demo_user';
    return user.uid;
  }

  final FirebaseFirestore _firestore;
  final UserIdProvider _userIdProvider;

  String get _userId => _userIdProvider();

  CollectionReference<Map<String, dynamic>> _cardsCollectionForUser(
    String userId,
  ) => _firestore.collection('users').doc(userId).collection('cards');

  Future<void> upsertOwnedCard(PokemonCardResult card) async {
    final userId = _userId;
    debugPrint('Firestore WRITE userId=$userId cardId=${card.id}');
    final docRef = _cardsCollectionForUser(userId).doc(card.id);

    await _firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(docRef);
      final baseData = _cardDocumentData(card);

      if (snapshot.exists) {
        transaction.set(docRef, {
          ...baseData,
          'owned': true,
          'quantity': FieldValue.increment(1),
        }, SetOptions(merge: true));
        return;
      }

      transaction.set(docRef, {
        ...baseData,
        'owned': true,
        'quantity': 1,
        'dateAdded': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
  }

  Future<List<FirestoreOwnedCardRecord>> fetchOwnedCards() async {
    final userId = _userId;
    debugPrint('Firestore READ userId=$userId');
    final snapshot = await _cardsCollectionForUser(userId)
        .where('owned', isEqualTo: true)
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      return FirestoreOwnedCardRecord(
        card: _cardFromDocument(doc.id, data),
        owned: data['owned'] as bool? ?? true,
        quantity: (data['quantity'] as num?)?.toInt() ?? 1,
        dateAdded: _timestampToDateTime(data['dateAdded']),
      );
    }).toList();
  }

  Map<String, dynamic> _cardDocumentData(PokemonCardResult card) {
    return {
      'cardId': card.id,
      'name': card.name,
      'setId': card.setId,
      'setName': card.setName,
      'number': card.number,
      'imageSmall': card.imageSmall,
      'imageLarge': card.imageLarge,
      if (card.marketValue != null) 'marketValue': card.marketValue,
      if (card.hp != null) 'hp': card.hp,
      if (card.rarity != null && card.rarity!.trim().isNotEmpty)
        'rarity': card.rarity,
    };
  }

  PokemonCardResult _cardFromDocument(String docId, Map<String, dynamic> data) {
    return PokemonCardResult.fromJson({
      'id': data['cardId'] ?? docId,
      'name': data['name'],
      'setId': data['setId'],
      'setName': data['setName'],
      'number': data['number'],
      'imageSmall': data['imageSmall'],
      'imageLarge': data['imageLarge'],
      'marketValue': data['marketValue'],
      'hp': data['hp'],
      'rarity': data['rarity'],
      'finishes': const <String, dynamic>{},
    });
  }

  DateTime? _timestampToDateTime(dynamic value) {
    if (value is Timestamp) return value.toDate();
    return null;
  }
}

final firestoreCollectionServiceInstance = FirestoreCollectionService();
