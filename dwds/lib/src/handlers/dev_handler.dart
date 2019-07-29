// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:build_daemon/data/build_status.dart';
import 'package:build_daemon/data/serializers.dart' as build_daemon;
import 'package:logging/logging.dart';
import 'package:pedantic/pedantic.dart';
import 'package:shelf/shelf.dart';
import 'package:sse/server/sse_handler.dart';
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart';

import '../../data/connect_request.dart';
import '../../data/devtools_request.dart';
import '../../data/isolate_events.dart';
import '../../data/serializers.dart';
import '../connections/app_connection.dart';
import '../dwds_vm_client.dart';
import '../handlers/asset_handler.dart';
import '../servers/devtools.dart';
import '../services/app_debug_services.dart';
import '../services/debug_service.dart';

/// SSE handler to enable development features like hot reload and
/// opening DevTools.
class DevHandler {
  StreamSubscription _sub;
  final SseHandler _sseHandler = SseHandler(Uri.parse(r'/$sseHandler'));
  final _injectedConnections = Set<SseConnection>();
  final DevTools _devTools;
  final AssetHandler _assetHandler;
  final String _hostname;
  final _connectedApps = StreamController<AppConnection>.broadcast();
  final _servicesByAppId = <String, Future<AppDebugServices>>{};
  final Stream<BuildResult> buildResults;
  final bool _verbose;
  final void Function(Level, String) _logWriter;
  final Future<ChromeConnection> Function() _chromeConnection;

  Stream<AppConnection> get connectedApps => _connectedApps.stream;

  DevHandler(
    this._chromeConnection,
    this.buildResults,
    this._devTools,
    this._assetHandler,
    this._hostname,
    this._verbose,
    this._logWriter,
  ) {
    _sub = buildResults.listen(_emitBuildResults);
    _listen();
  }

  Handler get handler => _sseHandler.handler;

  Future<void> close() async {
    await _sub.cancel();
    // We listen for connections to close and remove them from the connections
    // set. Therefore we shouldn't asynchronously iterate through the
    // connections.
    await Future.wait(_injectedConnections
        .map((injectedConnection) => injectedConnection.sink.close()));
    await Future.wait(_servicesByAppId.values.map((futureServices) async {
      await (await futureServices).close();
    }));
    _servicesByAppId.clear();
  }

  void _emitBuildResults(BuildResult result) {
    if (result.status != BuildStatus.succeeded) return;
    for (var injectedConnection in _injectedConnections) {
      injectedConnection.sink
          .add(jsonEncode(build_daemon.serializers.serialize(result)));
    }
  }

  // TODO(https://github.com/dart-lang/webdev/issues/202) - Refactor so this is
  // a getter and is created immediately.
  Future<DebugService> startDebugService(
      ChromeConnection chromeConnection, String appInstanceId) async {
    return DebugService.start(
      _hostname,
      chromeConnection,
      _assetHandler.getRelativeAsset,
      appInstanceId,
      onResponse: _verbose
          ? (response) {
              if (response['error'] == null) return;
              _logWriter(Level.WARNING,
                  'VmService proxy responded with an error:\n$response');
            }
          : null,
    );
  }

  Future<AppDebugServices> loadAppServices(String appId, String instanceId) =>
      _servicesByAppId.putIfAbsent(
          appId, () => _createAppDebugServices(appId, instanceId));

  void _handleConnection(SseConnection injectedConnection) {
    _injectedConnections.add(injectedConnection);
    String appId;
    injectedConnection.stream.listen((data) async {
      var message = serializers.deserialize(jsonDecode(data));
      if (message is DevToolsRequest) {
        if (_devTools == null) {
          injectedConnection.sink
              .add(jsonEncode(serializers.serialize(DevToolsResponse((b) => b
                ..success = false
                ..error = 'Debugging is not enabled.\n\n'
                    'If you are using webdev please pass the --debug flag.\n'
                    'Otherwise check the docs for the tool you are using.'))));
          return;
        }

        if (appId != message.appId) {
          injectedConnection.sink.add(jsonEncode(serializers.serialize(
              DevToolsResponse((b) => b
                ..success = false
                ..error =
                    'App ID has changed since the connection was established. '
                        'Please file an issue at '
                        'https://github.com/dart-lang/webdev/issues/new.'))));
          return;
        }

        AppDebugServices appServices;
        try {
          appServices =
              await loadAppServices(message.appId, message.instanceId);
        } catch (_) {
          injectedConnection.sink
              .add(jsonEncode(serializers.serialize(DevToolsResponse((b) => b
                ..success = false
                ..error = 'Unable to connect debug services to your '
                    'application. Most likely this means you are trying to '
                    'load in a different Chrome window than was launched by '
                    'your development tool.'))));
          return;
        }

        // Check if we are already running debug services for a different
        // instance of this app.
        if (appServices.connectedInstanceId != null &&
            appServices.connectedInstanceId != message.instanceId) {
          injectedConnection.sink.add(jsonEncode(serializers.serialize(
              DevToolsResponse((b) => b
                ..success = false
                ..error =
                    'This app is already being debugged in a different tab. '
                        'Please close that tab or switch to it.'))));
          return;
        }

        // If you load the same app in a different tab then we need to throw
        // away our old services and start new ones.
        if (!(await _isCorrectTab(message.instanceId,
            appServices.chromeProxyService.wipDebugger.connection))) {
          unawaited(appServices.close());
          unawaited(_servicesByAppId.remove(message.appId));
          appServices =
              await loadAppServices(message.appId, message.instanceId);
        }

        injectedConnection.sink.add(jsonEncode(
            serializers.serialize(DevToolsResponse((b) => b..success = true))));

        appServices.connectedInstanceId = message.instanceId;
        await appServices.chromeProxyService.wipDebugger
            .sendCommand('Target.createTarget', params: {
          'newWindow': true,
          'url': 'http://${_devTools.hostname}:${_devTools.port}'
              '/?hide=none&uri=${appServices.debugService.wsUri}',
        });
      } else if (message is ConnectRequest) {
        if (appId != null) {
          throw StateError('Duplicate connection request from the same app. '
              'Please file an issue at '
              'https://github.com/dart-lang/webdev/issues/new.');
        }
        appId = message.appId;

        // After a page refresh, reconnect to the same app services if they
        // were previously launched and create the new isolate.
        var services = await _servicesByAppId[message.appId];
        if (services != null && services.connectedInstanceId == null) {
          // Re-connect to the previous instance if its in the same tab,
          // otherwise do nothing for now.
          if (await _isCorrectTab(message.instanceId,
              services.chromeProxyService.wipDebugger.connection)) {
            services.connectedInstanceId = message.instanceId;
            await services.chromeProxyService.createIsolate();
          }
        }

        _connectedApps.add(AppConnection(message, injectedConnection));
      } else if (message is IsolateExit) {
        (await loadAppServices(message.appId, message.instanceId))
            ?.chromeProxyService
            ?.destroyIsolate();
      } else if (message is IsolateStart) {
        await (await loadAppServices(message.appId, message.instanceId))
            ?.chromeProxyService
            ?.createIsolate();
      }
    });

    unawaited(injectedConnection.sink.done.then((_) async {
      _injectedConnections.remove(injectedConnection);
      if (appId != null) {
        var services = await _servicesByAppId[appId];
        services?.connectedInstanceId = null;
        services?.chromeProxyService?.destroyIsolate();
      }
    }));
  }

  void _listen() async {
    var injectedConnections = _sseHandler.connections;
    while (await injectedConnections.hasNext) {
      _handleConnection(await injectedConnections.next);
    }
  }

  Future<AppDebugServices> _createAppDebugServices(
      String appId, String instanceId) async {
    var debugService =
        await startDebugService(await _chromeConnection(), instanceId);
    _logWriter(
        Level.INFO,
        'Debug service listening on '
        '${debugService.wsUri}\n');

    var webdevClient = await DwdsVmClient.create(debugService);
    var appServices = AppDebugServices(debugService, webdevClient);

    unawaited(appServices
        .chromeProxyService.wipDebugger.connection.onClose.first
        .then((_) {
      appServices.close();
      _servicesByAppId.remove(appId);
      _logWriter(
          Level.INFO,
          'Stopped debug service on '
          'ws://${debugService.hostname}:${debugService.port}\n');
    }));

    return appServices;
  }
}

/// Checks if [tabConnection] is running the app with [instanceId].
Future<bool> _isCorrectTab(
    String instanceId, WipConnection tabConnection) async {
  var result =
      await tabConnection.runtime.evaluate(r'window["$dartAppInstanceId"];');
  return result.value == instanceId;
}
