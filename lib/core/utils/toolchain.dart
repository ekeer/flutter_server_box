import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:server_box/core/chan.dart';
import 'package:server_box/data/model/server/server_private_info.dart';

/// The bundled Linux userland (bash, GNU coreutils, OpenSSH, adb, curl, ...),
/// shipped in `jniLibs` so Android extracts it into the one directory an app
/// may execute from — see `android/app/src/main/jniLibs/`.
///
/// Two directories hide behind one abstraction:
///
///  * The native library directory (the only place an app may exec from, and
///    where AGP will only ship files named `*.so` — which is why every bundled
///    tool is stored with an appended `.so`).
///  * A writable home under the app's support directory, where this class
///    recreates each tool under its *real* name as a symlink to the `.so`
///    file. The dynamic linker and the shell never see the disguise: `ssh`
///    is found as `ssh`, `libcrypto.so.3` loads as `libcrypto.so.3`.
abstract final class Toolchain {
  static String? _nativeDir;
  static String? _homeDir;
  static String? _binDir;
  static String? _libDir;

  static bool get isAndroid => Platform.isAndroid;

  /// Whether this build carries the toolchain at all. Null until [prepare].
  static bool get isSupported => isAndroid && _nativeDir != null;

  /// Locates the native library directory and lays down the symlink layers
  /// that give the tools their real names. Call once at startup, beside
  /// `Rootfs.prepare`.
  static Future<void> prepare() async {
    if (!isAndroid) return;
    _nativeDir = await MethodChans.nativeLibDir();
    if (_nativeDir == null) return;
    final support = await getApplicationSupportDirectory();
    _homeDir = '${support.path}/termex';
    _binDir = '$_homeDir/bin';
    _libDir = '$_homeDir/lib';
    _rebuildLinks();
  }

  static void _rebuildLinks() {
    final home = _homeDir!;
    Directory(home).createSync(recursive: true);
    // A session home for the bundled ssh; ssh insists on a 0700 dir and
    // refuses a world-writable one outright.
    final sshDir = '$home/.ssh';
    Directory(sshDir).createSync(recursive: true);
    Process.runSync('/system/bin/chmod', ['700', sshDir]);

    final binDir = _binDir!;
    final libDir = _libDir!;
    // A stale layer from an older build must not shadow a current one: drop
    // the two directories and rebuild them from what is actually extracted.
    if (Directory(binDir).existsSync()) {
      Directory(binDir).deleteSync(recursive: true);
    }
    if (Directory(libDir).existsSync()) {
      Directory(libDir).deleteSync(recursive: true);
    }
    Directory(binDir).createSync(recursive: true);
    Directory(libDir).createSync(recursive: true);

    // Executables: <native>/bash.so -> <home>/bin/bash
    final nativeDir = _nativeDir!;
    for (final entry in Directory(nativeDir).listSync()) {
      final name = entry.uri.pathSegments.last;
      if (entry is! File || !name.endsWith('.so')) continue;
      _link('$binDir/${_realName(name)}', entry.path);
    }
    // Libraries, keeping the subdirectory shape (engines-3, ossl-modules):
    // <native>/lib/libcrypto.so.3.so -> <home>/lib/libcrypto.so.3
    final nativeLib = '$nativeDir/lib';
    if (Directory(nativeLib).existsSync()) {
      for (final entry in Directory(nativeLib).listSync(recursive: true)) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        if (!name.endsWith('.so')) continue;
        final rel = entry.path.substring(nativeLib.length + 1);
        final slash = rel.lastIndexOf('/');
        final dirPart = slash < 0 ? '' : rel.substring(0, slash);
        final linkDir = dirPart.isEmpty ? libDir : '$libDir/$dirPart';
        Directory(linkDir).createSync(recursive: true);
        _link('$linkDir/${_realName(name)}', entry.path);
      }
    }
  }

  /// The name a stored `*.so` file answers to: the appended `.so` is the
  /// packaging disguise, nothing more.
  static String _realName(String stored) =>
      stored.substring(0, stored.length - '.so'.length);

  static void _link(String linkPath, String target) {
    try {
      Link(linkPath).createSync(target);
    } catch (e) {
      // A leftover regular file (or a link already there) — replace it.
      try {
        File(linkPath).deleteSync();
      } catch (_) {}
      try {
        Link(linkPath).createSync(target);
      } catch (_) {}
    }
  }

  /// Where the extracted `*.so` files actually live.
  static String get nativeDir => _nativeDir!;

  /// Where the tools are reachable under their real names (symlinks).
  static String get binDir => _binDir!;

  /// Where the libraries are reachable under their load names (symlinks).
  static String get libDir => _libDir!;

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
