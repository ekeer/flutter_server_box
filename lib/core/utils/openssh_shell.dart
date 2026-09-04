import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:server_box/core/utils/server.dart' show resolvePrivateKeys;
import 'package:server_box/core/utils/toolchain.dart';
import 'package:server_box/data/model/server/server_private_info.dart';
import 'package:server_box/data/model/server/shell_backend.dart';

/// [ShellBackend] that reaches a server with the bundled OpenSSH client
/// instead of dartssh2.
///
/// The terminal page cannot tell the difference: bytes come out of a pty the
/// same way they come out of an SSH channel. What is different underneath is
/// exactly what the page above was written not to assume — there is one
/// stream, so [supportsExec] is false (tmux and snippet double-channels stay
/// off, as they already do for a monitor agent's shell), and keep-alive is
/// the ssh client's `ServerAliveInterval`, which is what keeps a session that
/// sat in the background alive instead of silently freezing.
///
/// Credentials come from the server the way dartssh2 gets them: a stored key
/// is written out as an `IdentityFile`, and a stored password is entered by
/// ssh's own prompt in the terminal (Android will not exec a helper script
/// out of the app's data directory, so SSH_ASKPASS is off the table). A
/// private key that needs a passphrase is likewise asked for in the terminal,
/// exactly as it would be on a desktop.
class OpenSshShellBackend implements ShellBackend {
  OpenSshShellBackend({required this.spi});

  final Spi spi;

  static const _aliveInterval = 15;
  static const _aliveCountMax = 3;

  var _closed = false;
  final _sessions = <ShellSession>[];

  String? _keyFile;

  @override
  bool get isClosed => _closed;

  /// One pty, one stream. See the class docs.
  @override
  bool get supportsExec => false;

  @override
  Future<ShellSession> openShell({
    required int width,
    required int height,
    Map<String, String>? environment,
  }) async {
    if (_closed) {
      throw StateError('This OpenSSH shell backend is closed');
    }
    try {
      final args = await _prepare();
      return _start(
        args,
        width: width,
        height: height,
        environment: environment,
      );
    } catch (e, st) {
      // Whatever kept the pty from starting, say so in the terminal instead of
      // leaving the page silently blank (the page's connection path has no
      // error handler of its own).
      final native = Toolchain.isSupported;
      final message = [
        'OpenSSH shell failed to start: $e',
        if (native)
          'binDir: ${Toolchain.binDir}\n'
              'nativeDir: ${Toolchain.nativeDir}\n'
              'bash exists: ${File('${Toolchain.binDir}/bash').existsSync()}',
        'stack: $st',
      ].join('\n');
      Loggers.app.warning('OpenSSH shell start failed', e, st);
      return _FailingSession(message);
    }
  }

  @override
  Future<ShellSession> execute(
    String command, {
    required int width,
    required int height,
    Map<String, String>? environment,
  }) {
    throw UnsupportedError(
      'The OpenSSH shell has a single channel; run commands in its terminal.',
    );
  }

  /// Nothing to reach out and touch: ssh's own keep-alive probes the link, and
  /// a link that dies exits the process, which the page reports as a
  /// disconnect through [ShellSession.done].
  @override
  Future<void> ping() async {}

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final session in [..._sessions]) {
      session.close();
    }
    final keyFile = _keyFile;
    if (keyFile != null) {
      try {
        File(keyFile).deleteSync();
      } catch (_) {}
    }
  }

  /// Writes whatever credential the server holds into files ssh can read, and
  /// returns the ssh argument vector.
  Future<List<String>> _prepare() async {
    final ssh = spi.ssh;
    if (ssh == null) {
      throw StateError('No SSH credential configured for ${spi.name}');
    }
    final sshDir = Toolchain.sshDir;
    final home = Toolchain.homeDir;

    final args = <String>[
      '-p',
      '${ssh.port}',
      '-o',
      'ServerAliveInterval=$_aliveInterval',
      '-o',
      'ServerAliveCountMax=$_aliveCountMax',
      '-o',
      'StrictHostKeyChecking=accept-new',
      '-o',
      'UserKnownHostsFile=$sshDir/known_hosts',
      '-o',
      'LogLevel=ERROR',
    ];

    // Key first: when the server authenticates with one, a stored password is
    // a fallback at best and ssh tries them in order anyway.
    final keys = resolvePrivateKeys(ssh);
    if (keys.isNotEmpty) {
      final pem = keys.values.first;
      final keyFile = '$home/identity.pem';
      await File(keyFile).writeAsString(pem, flush: true);
      await Process.run('/system/bin/chmod', ['600', keyFile]);
      args
        ..add('-i')
        ..add(keyFile);
      _keyFile = keyFile;
    }
    // A stored password is answered interactively by ssh in the terminal.
    // Feeding it through SSH_ASKPASS is tempting but the askpass helper would
    // have to live in the app's data directory — which Android will not exec —
    // and ssh would die the moment the helper did.

    args.add('${ssh.user}@${ssh.ip}');
    return args;
  }

  _OpenSshSession _start(
    List<String> args, {
    required int width,
    required int height,
    Map<String, String>? environment,
  }) {
    // Run ssh through bash so its diagnostics reach the terminal either way:
    // `exec` hands the pty to ssh unchanged, and if ssh cannot even start,
    // bash prints where it looked and what it found instead of the page going
    // silently blank. ssh runs with -v for now so the handshake is visible on
    // screen until the blank-session problem is pinned down.
    const probe = r'''
echo "== bundled ssh =="
if ! command -v ssh >/dev/null 2>&1; then
  echo "ERROR: bundled ssh not found"
  echo "PATH=$PATH"
  echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
  echo "-- bin --"; ls -la "$HOME/bin" 2>&1 | head -20
  echo "-- lib --"; ls -la "$HOME/lib" 2>&1 | head -20
  exit 127
fi
exec ssh -v "$@"
''';
    final session = _OpenSshSession(
      Pty.start(
        Toolchain.bashPath,
        arguments: ['-c', probe, 'bash', ...args],
        environment: Toolchain.environment(),
        workingDirectory: Toolchain.homeDir,
        rows: height > 0 ? height : 25,
        columns: width > 0 ? width : 80,
      ),
    );
    _sessions.add(session);
    unawaited(
      session.done.whenComplete(() => _sessions.remove(session)),
    );
    return session;
  }
}

/// [ShellSession] on the pty an ssh process is attached to.
///
/// A mirror of the local shell's session: the pty merges stdout and stderr,
/// resizing sends SIGWINCH through the pty to the far shell, and closing hangs
/// up the process group — ssh included, and whatever it spawned.
class _OpenSshSession implements ShellSession {
  _OpenSshSession(this._pty) {
    unawaited(_pty.exitCode.then((_) => _exited = true));
  }

  final Pty _pty;
  var _exited = false;

  @override
  Stream<Uint8List>? get stdout => _pty.output;

  @override
  Stream<Uint8List>? get stderr => null;

  @override
  void write(List<int> data) =>
      _pty.write(data is Uint8List ? data : Uint8List.fromList(data));

  @override
  void resizeTerminal(int width, int height) => _pty.resize(height, width);

  @override
  Future<void> get done => _pty.exitCode;

  @override
  void close() {
    if (_exited) return;
    _signal(ProcessSignal.sighup);
    Timer(const Duration(seconds: 3), () {
      if (_exited) return;
      _signal(ProcessSignal.sigkill);
    });
  }

  void _signal(ProcessSignal signal) {
    if (Platform.isWindows) {
      try {
        _pty.kill(signal);
      } catch (_) {}
      return;
    }
    try {
      Process.killPid(-_pty.pid, signal);
    } catch (_) {}
    try {
      _pty.kill(signal);
    } catch (_) {}
  }
}

/// A [ShellSession] that has nothing to run: pty startup failed, and the page
/// must see why. Renders [message] once, then sits open — closing is up to
/// whoever owns the page — so the reason never flashes by and vanishes.
class _FailingSession implements ShellSession {
  _FailingSession(this.message);

  final String message;
  final _out = StreamController<Uint8List>();
  final _done = Completer<void>();
  var _emitted = false;

  @override
  Stream<Uint8List>? get stdout {
    if (!_emitted) {
      _emitted = true;
      _out.add(Uint8List.fromList('$message\r\n'.codeUnits));
      // Close the stream once the message is out; done stays open.
      _out.close();
    }
    return _out.stream;
  }

  @override
  Stream<Uint8List>? get stderr => null;

  @override
  void write(List<int> data) {}

  @override
  void resizeTerminal(int width, int height) {}

  @override
  Future<void> get done => _done.future;

  @override
  void close() {
    if (!_done.isCompleted) _done.complete();
  }
}
