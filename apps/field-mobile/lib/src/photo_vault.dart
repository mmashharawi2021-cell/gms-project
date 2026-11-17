import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

/// Meter photos are stored ENCRYPTED (AES-256-GCM) in app-private storage. The SHA-256 is computed over the
/// original bytes at capture time and is what the server verifies after upload.
class PhotoVault {
  final Directory dir;
  final List<int> key;
  PhotoVault(this.dir, this.key);
  final _aes = AesGcm.with256bits();

  Future<({String path, String sha256, int size})> store(String photoId, Uint8List bytes) async {
    final box = await _aes.encrypt(bytes, secretKey: SecretKey(key));
    final path = p.join(dir.path, '$photoId.bin');
    final tmp = File('$path.part');
    await tmp.writeAsBytes(box.concatenation(), flush: true);
    await tmp.rename(path); // atomic: never a half-written photo
    return (path: path, sha256: c.sha256.convert(bytes).toString(), size: bytes.length);
  }

  Future<Uint8List> read(String path) async {
    final data = await File(path).readAsBytes();
    final box = SecretBox.fromConcatenation(data, nonceLength: _aes.nonceLength, macLength: _aes.macAlgorithm.macLength);
    return Uint8List.fromList(await _aes.decrypt(box, secretKey: SecretKey(key)));
  }

  Future<void> delete(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }
}
