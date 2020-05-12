// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';

import '../../dwds.dart';
import '../loaders/strategy.dart';
import '../version.dart';

/// File extension that build_web_compilers will place the
/// [entrypointExtensionMarker] in.
const bootstrapJsExtension = '.bootstrap.js';

/// Marker placed by build_web_compilers for where to put injected JS code.
const entrypointExtensionMarker = '/* ENTRYPOINT_EXTENTION_MARKER */';

/// Marker placed by build_web_compilers for where to put injected JS code.
const mainExtensionMarker = '/* MAIN_EXTENSION_MARKER */';

const _clientScript = 'dwds/src/injected/client';

/// Handles injecting the DWDS client and embedding debugging related
/// information.
class DwdsInjector {
  final LoadStrategy _loadStrategy;
  final String _extensionUri;
  final _devHandlerPathCompleter = Completer<String>();

  DwdsInjector(
    this._loadStrategy, {
    String extensionUri,
  }) : _extensionUri = extensionUri;

  /// Returns the embedded dev handler path.
  ///
  /// This will be next to the requested entrypoint.
  Future<String> get devHandlerPath => _devHandlerPathCompleter.future;

  Middleware get middleware => (innerHandler) {
        return (Request request) async {
          if (request.url.path.endsWith('$_clientScript.js')) {
            var uri = await Isolate.resolvePackageUri(
                Uri.parse('package:$_clientScript.js'));
            var result = await File(uri.toFilePath()).readAsString();
            return Response.ok(result, headers: {
              HttpHeaders.contentTypeHeader: 'application/javascript'
            });
          } else if (request.url.path.endsWith(bootstrapJsExtension)) {
            var ifNoneMatch = request.headers[HttpHeaders.ifNoneMatchHeader];
            if (ifNoneMatch != null) {
              // Disable caching of the inner hander by manually modifying the
              // if-none-match header before forwarding the request.
              request = request.change(headers: {
                HttpHeaders.ifNoneMatchHeader: '$ifNoneMatch\$injected',
              });
            }
            var response = await innerHandler(request);
            if (response.statusCode == HttpStatus.notFound) return response;
            var body = await response.readAsString();
            var etag = response.headers[HttpHeaders.etagHeader];
            var newHeaders = Map.of(response.headers);
            if (body.startsWith(entrypointExtensionMarker)) {
              // The requestedUri contains the hostname and port which guarantees
              // uniqueness.
              var requestedUri = request.requestedUri;
              var appId = base64
                  .encode(md5.convert(utf8.encode('$requestedUri')).bytes);
              var requestedUriBase = '${request.requestedUri.scheme}'
                  '://${request.requestedUri.authority}';
              var devHandlerPath = '\$dwdsSseHandler';
              var subPath = request.url.pathSegments.toList()..removeLast();
              if (subPath.isNotEmpty) {
                devHandlerPath = '${subPath.join('/')}/$devHandlerPath';
              }
              devHandlerPath = '$requestedUriBase/$devHandlerPath';
              if (!_devHandlerPathCompleter.isCompleted) {
                _devHandlerPathCompleter.complete(devHandlerPath);
              }
              body = _injectClientAndHoistMain(
                body,
                appId,
                devHandlerPath,
                _extensionUri,
                _loadStrategy,
              );
              body += await _loadStrategy.bootstrapFor(request.url.path);
              etag = base64.encode(md5.convert(body.codeUnits).bytes);
              newHeaders[HttpHeaders.etagHeader] = etag;
            }
            if (ifNoneMatch == etag) {
              return Response.notModified(headers: newHeaders);
            }
            return response.change(body: body, headers: newHeaders);
          } else {
            var loadResponse = await _loadStrategy.handler(request);
            if (loadResponse != null) return loadResponse;
            return innerHandler(request);
          }
        };
      };
}

/// Returns the provided body with the main function hoisted into a global
/// variable and a snippet of JS that loads the injected client.
String _injectClientAndHoistMain(
  String body,
  String appId,
  String devHandlerPath,
  String extensionUri,
  LoadStrategy loadStrategy,
) {
  var bodyLines = body.split('\n');
  var extensionIndex =
      bodyLines.indexWhere((line) => line.contains(mainExtensionMarker));
  var result = bodyLines.sublist(0, extensionIndex).join('\n');
  // The line after the marker calls `main`. We prevent `main` from
  // being called and make it runnable through a global variable.
  var mainFunction =
      bodyLines[extensionIndex + 1].replaceAll('main();', 'main').trim();
  // We inject the client in the entry point module as the client expects the
  // application to be in a ready state, that is the main function is hoisted
  // and the Dart SDK is loaded.
  var injectedClientSnippet = _injectedClientSnippet(
    appId,
    devHandlerPath,
    extensionUri,
    loadStrategy,
  );
  result += '''
  // Injected by dwds for debugging support.
  if(!window.\$dwdsInitialized) {
    window.\$dwdsInitialized = true;
    window.\$dartMainTearOffs = [$mainFunction];
    window.\$dartRunMain = function() {
      window.\$dartMainExecuted = true;
      window.\$dartMainTearOffs.forEach(function(main){
         main();
      });
    }
    $injectedClientSnippet
  } else {
    if(window.\$dartMainExecuted){
     $mainFunction();
    }else {
     window.\$dartMainTearOffs.push($mainFunction);
    }
  }
  ''';
  result += bodyLines.sublist(extensionIndex + 2).join('\n');
  return result;
}

/// JS snippet which includes global variables required for debugging.
String _injectedClientSnippet(
  String appId,
  String devHandlerPath,
  String extensionUri,
  LoadStrategy loadStrategy,
) {
  var injectedBody = 'window.\$dartAppId = "$appId";\n'
      'window.\$dartReloadConfiguration = "${loadStrategy.reloadConfiguration}";\n'
      'window.\$dartModuleStrategy = "${loadStrategy.id}";\n'
      'window.\$loadModuleConfig = ${loadStrategy.loadModuleSnippet};\n'
      'window.\$dwdsVersion = "$packageVersion";\n'
      'window.\$dwdsDevHandlerPath = "$devHandlerPath";\n'
      '${loadStrategy.loadClientSnippet(_clientScript)}';
  if (extensionUri != null) {
    injectedBody += 'window.\$dartExtensionUri = "$extensionUri";\n';
  }
  return injectedBody;
}