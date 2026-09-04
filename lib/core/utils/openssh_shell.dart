import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
/// is written out as an `IdentityFile`, a stored password is answered through
/// `SSH_ASKPASS`. A private key that needs a passphrase is left to ssh to ask
/// for in the terminal, exactly as it would on a desktop.
class OpenSshShellBackend implements ShellBackend {
  OpenSshShellBackend({required this.spi});

  final Spi spi;

  static const _aliveInterval = 15;
  static const _aliveCountMax = 3;

  var _closed = false;
  final _sessions = <ShellSession>[];

  String? _keyFile;
  String? _passwordFile;

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
    final args = await _prepare();
    return _start(args, width: width, height: height, environment: environment);
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
    final passwordFile = _passwordFile;
    if (passwordFile != null) {
      try {
        File(passwordFile).deleteSync();
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

    final pwd = ssh.pwd;
    if (pwd != null && pwd.isNotEmpty) {
      final passwordFile = '$home/.pw';
      await File(passwordFile).writeAsString(pwd, flush: true);
      await Process.run('/system/bin/chmod', ['600', passwordFile]);
      final askpass = '$home/askpass.sh';
      await File(askpass).writeAsString(
        '#!/system/bin/sh\ncat $passwordFile\n',
        flush: true,
      );
      await Process.run('/system/bin/chmod', ['700', askpass]);
      _passwordFile = passwordFile;
    }

    args.add('${ssh.user}@${ssh.ip}');
    return args;
  }

  _OpenSshSession _start(
    List<String> args, {
    required int width,
    required int height,
    Map<String, String>? environment,
  }) {
    final session = _OpenSshSession(
      Pty.start(
        Toolchain.sshPath,
        arguments: args,
        environment: Toolchain.environment({
          // Force the askpass route so a stored password never waits on a
          // prompt nobody is looking at. OpenSSH >= 8.4 understands this; the
          // bundled client is far newer.
          if (_passwordFile != null) 'SSH_ASKPASS_REQUIRE': 'force',
        }),
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
