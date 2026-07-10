/// The direction of a [ChatMessage] relative to this device.
enum ChatMessageDirection {
  /// The message was sent by this device.
  sent,

  /// The message was received from the peer.
  received,
}

/// A single chat message exchanged with a peer device.
///
/// Chat messages reuse the existing "send message" mechanism of LocalSend
/// (the text is embedded into the prepare-upload preview field), but instead of
/// being a one-shot action they are kept in a per-peer conversation so multiple
/// messages can be exchanged without re-selecting the clipboard/text each time.
class ChatMessage {
  final String text;
  final ChatMessageDirection direction;
  final DateTime timestamp;

  const ChatMessage({
    required this.text,
    required this.direction,
    required this.timestamp,
  });

  bool get isMine => direction == ChatMessageDirection.sent;
}
