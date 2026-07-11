import 'package:common/model/file_type.dart';

/// The direction of a [ChatMessage] relative to this device.
enum ChatMessageDirection {
  /// The message was sent by this device.
  sent,

  /// The message was received from the peer.
  received,
}

/// What kind of content a chat bubble holds.
enum ChatContentKind {
  text,
  image,
  file,
}

/// A single chat item exchanged with a peer device.
///
/// Text reuses LocalSend's prepare-upload preview mechanism.
/// Images / files reuse the normal file transfer pipeline and are then
/// surfaced in the conversation after save (receive) or after queue (send).
class ChatMessage {
  final ChatContentKind kind;
  final ChatMessageDirection direction;
  final DateTime timestamp;

  /// Plain text body (for [ChatContentKind.text]).
  final String? text;

  /// Local path of a saved/sent file (for image/file).
  final String? filePath;

  /// Original file name shown in the bubble.
  final String? fileName;

  final FileType? fileType;

  /// Optional in-memory preview bytes (e.g. outgoing image before path exists).
  final List<int>? previewBytes;

  const ChatMessage({
    required this.kind,
    required this.direction,
    required this.timestamp,
    this.text,
    this.filePath,
    this.fileName,
    this.fileType,
    this.previewBytes,
  });

  bool get isMine => direction == ChatMessageDirection.sent;

  bool get isImage => kind == ChatContentKind.image || fileType == FileType.image;

  factory ChatMessage.text({
    required String text,
    required ChatMessageDirection direction,
    DateTime? timestamp,
  }) {
    return ChatMessage(
      kind: ChatContentKind.text,
      direction: direction,
      timestamp: timestamp ?? DateTime.now(),
      text: text,
    );
  }

  factory ChatMessage.attachment({
    required ChatMessageDirection direction,
    required String fileName,
    required FileType fileType,
    String? filePath,
    List<int>? previewBytes,
    DateTime? timestamp,
  }) {
    final kind = fileType == FileType.image ? ChatContentKind.image : ChatContentKind.file;
    return ChatMessage(
      kind: kind,
      direction: direction,
      timestamp: timestamp ?? DateTime.now(),
      fileName: fileName,
      fileType: fileType,
      filePath: filePath,
      previewBytes: previewBytes,
    );
  }
}
