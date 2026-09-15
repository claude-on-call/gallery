import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/server/person.dart';
import 'package:immich_mobile/data/store/util/cache.dart';
import 'package:immich_mobile/domain/models/person.model.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
// TODO(rewrite): Remove once user metadata is a store entry of its own
import 'package:immich_mobile/providers/infrastructure/user_metadata.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:logging/logging.dart';

/// People representing collections of faces and assets
///
/// State is stored in the local DB, while mutations are pushed to both HTTP and DB
extension type const PersonStore._(Provider<PersonMutations> _provider) implements Provider<PersonMutations> {
  /// Internal: access through `Store.people`
  static final PersonStore instance = PersonStore._(Provider((ref) => PersonMutations._(ref)));

  /// Get the person specified by [personId]
  ///
  /// **NOTE:** This is not reactive to changes, and only hits the local DB
  AutoDisposeFutureProvider<Person?> byId(String personId) => _byIdProvider(personId);

  /// Get the people present in the asset keyed by [key.id], honoring [key.ownerId].
  ///
  /// The local sync DB only ever receives faces for assets the viewer owns (see
  /// AGENTS.md), so for an asset owned by someone else this routes to the server's
  /// asset-info endpoint instead, matching web's on-demand resolution. See issue #727.
  ///
  /// **NOTE:** This is not reactive to changes
  AutoDisposeFutureProvider<List<Person>> forAsset(({String id, String ownerId}) key) => _forAssetProvider(key);

  /// Get all known people, honoring the user's minimum detected face count preference
  ///
  /// **NOTE:** This only hits the local DB
  AutoDisposeStreamProvider<List<Person>> all() => _allProvider;
}

final _peopleDb = driftProvider.select((db) => db.peopleDatabaseRepository);

// We have to map from non-reactive existing Drift queries to Riverpod reactivity, so we wrap each call in a provider family
// Note that the only reactivity here is in going from no data (fetch start) to data (fetch completed), and the DB swapping (basically never)
final _byIdProvider = FutureProvider.autoDispose.family<Person?, String>(
  (ref, personId) => ref.watch(_peopleDb).get(personId),
);

final _log = Logger('PersonStore');

final _forAssetProvider = FutureProvider.autoDispose.family<List<Person>, ({String id, String ownerId})>((
  ref,
  key,
) async {
  final currentUserId = ref.watch(currentUserProvider.select((user) => user?.id));
  if (key.ownerId != currentUserId) {
    // The supplementary people strip is best-effort for non-owned assets: a transient
    // network/server failure should silently hide it (as the prior local-Drift lookup did)
    // rather than surface a visible error, so swallow the failure and return no people.
    try {
      return await ref.watch(personApiRepositoryProvider).getAssetPeople(key.id);
    } catch (error, stackTrace) {
      _log.warning('Failed to fetch people for non-owned asset ${key.id}', error, stackTrace);
      return const [];
    }
  }
  return ref.watch(_peopleDb).getAssetPeople(key.id);
});

final _allProvider = StreamProvider.autoDispose<List<Person>>((ref) async* {
  final prefs = await ref.watch(userMetadataPreferencesProvider.future);
  yield* ref.watch(_peopleDb).watch(minFaces: prefs?.minimumFaces ?? 3);
});

class PersonMutations extends StoreMutations {
  const PersonMutations._(super.ref);

  // TODO(rewrite): these route unconditionally to the owner-only PATCH /people/{id}; a
  // space-scoped person has no row there and would 404. Needs a spaceId branch (see
  // DriftPeopleService.updateName/updateBirthday -> SharedSpaceApiRepository.updateSpacePerson)
  // before any caller adopts Store.people for edits. Unused today, so this is latent.

  /// Update a person's name
  Future<int> updateName(String personId, String name) async {
    await read(personApiRepositoryProvider).update(personId, name: name);
    return read(_peopleDb).updateName(personId, name);
  }

  /// Update a person's birthday
  Future<int> updateBirthday(String personId, DateTime birthday) async {
    await read(personApiRepositoryProvider).update(personId, birthday: birthday);
    return read(_peopleDb).updateBirthday(personId, birthday);
  }
}
