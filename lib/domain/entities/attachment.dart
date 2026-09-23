/// Medora - A photo or PDF kept with a prescription (later also with a
/// treatment or a person).
///
/// The row is metadata; the bytes live in a file named after the id, and on
/// the server in the private storage bucket once uploaded. A changed file is
/// a new attachment: the bytes of an attachment never change.
library;

enum AttachmentKind {
  photo('photo', 'jpg'),
  pdf('pdf', 'pdf');

  const AttachmentKind(this.wire, this.extension);
  final String wire;
  final String extension;

  static AttachmentKind fromWire(String? raw) =>
      values.firstWhere((k) => k.wire == raw, orElse: () => photo);
}

enum AttachmentOwnerKind {
  rx('rx'),
  treatment('treatment'),
  person('person');

  const AttachmentOwnerKind(this.wire);
  final String wire;

  static AttachmentOwnerKind fromWire(String? raw) =>
      values.firstWhere((k) => k.wire == raw, orElse: () => rx);
}

class Attachment {
  const Attachment({
    required this.id,
    this.userId,
    required this.ownerKind,
    required this.ownerId,
    required this.kind,
    required this.mime,
    required this.sizeBytes,
    required this.sha256,
    this.originalName,
    this.remotePath,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? userId;
  final AttachmentOwnerKind ownerKind;

  /// Soft reference: the owner may be gone.
  final String ownerId;
  final AttachmentKind kind;
  final String mime;
  final int sizeBytes;

  /// Hex sha256 of the stored bytes.
  final String sha256;
  final String? originalName;

  /// Object path in the storage bucket; null until uploaded.
  final String? remotePath;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  String get fileName => '$id.${kind.extension}';
}
