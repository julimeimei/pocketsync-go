import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum NetworkStatus {
  online,
  offline;

  bool get isOnline => this == NetworkStatus.online;
}

abstract interface class ConnectivitySource {
  Future<List<ConnectivityResult>> checkConnectivity();

  Stream<List<ConnectivityResult>> get onConnectivityChanged;
}

class ConnectivityPlusSource implements ConnectivitySource {
  ConnectivityPlusSource(this._connectivity);

  final Connectivity _connectivity;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() {
    return _connectivity.checkConnectivity();
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged {
    return _connectivity.onConnectivityChanged;
  }
}

final Provider<ConnectivitySource> connectivitySourceProvider =
    Provider<ConnectivitySource>((ref) {
      return ConnectivityPlusSource(Connectivity());
    });

final StreamProvider<NetworkStatus> networkStatusProvider =
    StreamProvider<NetworkStatus>((ref) async* {
      final ConnectivitySource source = ref.watch(connectivitySourceProvider);

      yield networkStatusFromConnectivityResults(
        await source.checkConnectivity(),
      );

      yield* source.onConnectivityChanged
          .map(networkStatusFromConnectivityResults)
          .distinct();
    });

NetworkStatus networkStatusFromConnectivityResults(
  List<ConnectivityResult> results,
) {
  if (results.isEmpty ||
      results.every((ConnectivityResult result) {
        return result == ConnectivityResult.none;
      })) {
    return NetworkStatus.offline;
  }

  return NetworkStatus.online;
}
