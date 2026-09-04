import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:server_box/core/chan.dart';
import 'package:server_box/data/model/server/server_private_info.dart';

/// The bundled Linux userland (bash, GNU coreutils, OpenSSH, adb, curl, ...),
/// shipped in `jniLibs` so Android extracts it into the one directory an app
/// may execute from — see `android/app/src/main/jniLibs/`.
///
/// Everything here is a question about that directory and the binaries in it,
/// asked once and answered from then on. Callers that can reach a server with
/// the bundled `ssh` client go through [canServe]; anything that does not fit
/// (jump hosts, ProxyCommand) keeps dartssh2.
abstract final class Toolchain {
  static String? _binDir;
  static String? _homeDir;

  static bool get isAndroid => Platform.isAndroid;

  /// Whether this build carries the toolchain at all. Null until [prepare].
  static bool get isSupported => isAndroid && _binDir != null;

  /// Locates the native library directory and prepares a writable home for
  /// the toolchain (SSH known_hosts, keys, askpass). Call once at startup,
  /// beside `Rootfs.prepare`.
  static Future<void> prepare() async {
    if (!isAndroid) return;
    _binDir = await MethodChans.nativeLibDir();
    if (_binDir == null) return;
    final support = await getApplicationSupportDirectory();
    _homeDir = '${support.path}/termex';
    await Directory(_homeDir!).create(recursive: true);
    // A session home for the bundled ssh; ssh insists on a 0700 dir and
    // refuses a world-writable one outright.
    final sshDir = '$_homeDir/.ssh';
    await Directory(sshDir).create(recursive: true);
    await Process.run('/system/bin/chmod', ['700', sshDir]);
  }

  /// Where the executables were extracted (the native library directory).
  static String get binDir => _binDir!;

  /// Where the private shared libraries live.
  static String get libDir => '$binDir/lib';

  /// Writable home for the toolchain.
  static String get homeDir => _homeDir!;

  static String get bashPath => '$binDir/bash';
  static String get sshPath => '$binDir/ssh';
  static String get sshDir => '$_homeDir/.ssh';

  /// Environment a toolchain process needs: its binaries and libraries on the
  /// paths the dynamic linker will look at, plus a writable HOME.
  static Map<String, String> environment([Map<String, String>? extra]) {
    final hostPath = Platform.environment['PATH'] ?? '';
    return {
      'PATH': '$binDir:$hostPath',
      if (isSupported) 'LD_LIBRARY_PATH': libDir,
      'HOME': homeDir,
      'TERM': 'xterm-256color',
      ...?extra,
    };
  }

  /// Whether [spi] can be reached with the bundled OpenSSH client.
  ///
  /// Direct connections only for now: jump servers and ProxyCommand keep the
  /// dartssh2 path, which already knows how to thread those. Authentication is
  /// fully supported either way — stored key or stored password.
  static bool canServe(Spi spi) {
    if (!isSupported) return false;
    final ssh = spi.ssh;
    if (ssh == null) return false;
    if (ssh.resolvedJumpIds.isNotEmpty) return false;
    if (ssh.proxyCommand != null) return false;
    return true;
  }
}
