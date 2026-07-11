import 'package:common/model/file_type.dart';
import 'package:localsend_app/model/chat_message.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// State of all chat conversations.
///
/// Conversations are grouped by the peer's fingerprint. Because discovery and
/// prepare-upload can occasionally disagree on the fingerprint string (or one
/// side may briefly report an empty value), we also keep an IP → fingerprint
/// alias map so incoming traffic can still land in the open thread.
class ChatState {
  /// Messages per peer fingerprint, in chronological order.
  final Map<String, List<ChatMessage>> threads;

  /// Fingerprints of peers with a currently open chat window.
  final Set<String> activePeers;

  /// Secondary lookup: peer IP → fingerprint of the open / known thread.
  final Map<String, String> ipToFingerprint;

  const ChatState({
    required this.threads,
    required this.activePeers,
    required this.ipToFingerprint,
  });

  static const empty = ChatState(
    threads: <String, List<ChatMessage>>{},
    activePeers: <String>{},
    ipToFingerprint: <String, String>{},
  );

  List<ChatMessage> threadOf(String fingerprint) => threads[fingerprint] ?? const [];

  bool isActive(String fingerprint) => activePeers.contains(fingerprint);

  /// Resolve the canonical thread key for an incoming peer.
  String resolveKey({required String fingerprint, String? ip}) {
    if (fingerprint.isNotEmpty) {
      return fingerprint;
    }
    if (ip != null && ip.isNotEmpty) {
      final mapped = ipToFingerprint[ip];
      if (mapped != null && mapped.isNotEmpty) {
        return mapped;
      }
      // Last resort: use the IP itself as a temporary thread key.
      return 'ip:$ip';
    }
    return fingerprint;
  }

  bool isActivePeer({required String fingerprint, String? ip}) {
    if (fingerprint.isNotEmpty && activePeers.contains(fingerprint)) {
      return true;
    }
    if (ip != null && ip.isNotEmpty) {
      final mapped = ipToFingerprint[ip];
      if (mapped != null && activePeers.contains(mapped)) {
        return true;
      }
      // Open chat was keyed by IP fallback.
      if (activePeers.contains('ip:$ip')) {
        return true;
      }
    }
    return false;
  }

  ChatState copyWith({
    Map<String, List<ChatMessage>>? threads,
    Set<String>? activePeers,
    Map<String, String>? ipToFingerprint,
  }) {
    return ChatState(
      threads: threads ?? this.threads,
      activePeers: activePeers ?? this.activePeers,
      ipToFingerprint: ipToFingerprint ?? this.ipToFingerprint,
    );
  }
}

/// Manages chat conversations with peer devices.
final chatProvider = ReduxProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier();
});

class ChatNotifier extends ReduxNotifier<ChatState> {
  @override
  ChatState init() => ChatState.empty;
}

Map<String, List<ChatMessage>> _appendMessage(
  Map<String, List<ChatMessage>> threads,
  String fingerprint,
  ChatMessage message,
) {
  final existing = threads[fingerprint] ?? const <ChatMessage>[];
  return {
    ...threads,
    fingerprint: [...existing, message],
  };
}

/// Marks a peer's chat as open, enabling automatic acceptance of its messages.
class OpenChatAction extends ReduxAction<ChatNotifier, ChatState> {
  final String fingerprint;
  final String? ip;

  OpenChatAction({required this.fingerprint, this.ip});

  @override
  ChatState reduce() {
    final key = fingerprint.isNotEmpty ? fingerprint : (ip != null ? 'ip:$ip' : fingerprint);
    final ipMap = {...state.ipToFingerprint};
    if (ip != null && ip!.isNotEmpty && key.isNotEmpty) {
      ipMap[ip!] = key;
    }
    return state.copyWith(
      activePeers: {...state.activePeers, key},
      threads: state.threads.containsKey(key) ? state.threads : {...state.threads, key: const []},
      ipToFingerprint: ipMap,
    );
  }
}

/// Marks a peer's chat as closed.
class CloseChatAction extends ReduxAction<ChatNotifier, ChatState> {
  final String fingerprint;
  final String? ip;

  CloseChatAction({required this.fingerprint, this.ip});

  @override
  ChatState reduce() {
    final key = fingerprint.isNotEmpty ? fingerprint : (ip != null ? 'ip:$ip' : fingerprint);
    final next = {...state.activePeers}..remove(key);
    if (ip != null) {
      next.remove('ip:$ip');
    }
    return state.copyWith(activePeers: next);
  }
}

/// Appends a text message sent by this device.
class AddSentMessageAction extends ReduxAction<ChatNotifier, ChatState> {
  final String fingerprint;
  final String text;
  final String? ip;

  AddSentMessageAction({required this.fingerprint, required this.text, this.ip});

  @override
  ChatState reduce() {
    final key = state.resolveKey(fingerprint: fingerprint, ip: ip);
    return state.copyWith(
      threads: _appendMessage(
        state.threads,
        key,
        ChatMessage.text(text: text, direction: ChatMessageDirection.sent),
      ),
    );
  }
}

/// Appends a text message received from a peer.
class AddReceivedMessageAction extends ReduxAction<ChatNotifier, ChatState> {
  final String fingerprint;
  final String text;
  final String? ip;

  AddReceivedMessageAction({required this.fingerprint, required this.text, this.ip});

  @override
  ChatState reduce() {
    final key = state.resolveKey(fingerprint: fingerprint, ip: ip);
    final ipMap = {...state.ipToFingerprint};
    if (ip != null && ip!.isNotEmpty && fingerprint.isNotEmpty) {
      ipMap[ip!] = fingerprint;
    } else if (ip != null && ip!.isNotEmpty && key.isNotEmpty) {
      ipMap[ip!] = key;
    }
    // Prefer writing into an already-open thread key so the ChatPage, which
    // was opened under fingerprint X, keeps seeing new messages even if the
    // prepare-upload payload reported a slightly different id.
    String target = key;
    if (ip != null && ip!.isNotEmpty) {
      final openKey = state.ipToFingerprint[ip!];
      if (openKey != null && state.activePeers.contains(openKey)) {
        target = openKey;
      } else if (state.activePeers.contains('ip:$ip')) {
        target = 'ip:$ip';
      }
    }
    if (fingerprint.isNotEmpty && state.activePeers.contains(fingerprint)) {
      target = fingerprint;
    }
    final msg = ChatMessage.text(text: text, direction: ChatMessageDirection.received);
    return state.copyWith(
      threads: _appendMessage(state.threads, target, msg),
      ipToFingerprint: ipMap,
    );
  }
}

/// Appends a sent attachment (image/file) bubble.
class AddSentAttachmentAction extends ReduxAction<ChatNotifier, ChatState> {
  final String fingerprint;
  final String fileName;
  final FileType fileType;
  final String? filePath;
  final List<int>? previewBytes;
  final String? ip;

  AddSentAttachmentAction({
    required this.fingerprint,
    required this.fileName,
    required this.fileType,
    this.filePath,
    this.previewBytes,
    this.ip,
  });

  @override
  ChatState reduce() {
    final key = state.resolveKey(fingerprint: fingerprint, ip: ip);
    return state.copyWith(
      threads: _appendMessage(
        state.threads,
        key,
        ChatMessage.attachment(
          direction: ChatMessageDirection.sent,
          fileName: fileName,
          fileType: fileType,
          filePath: filePath,
          previewBytes: previewBytes,
        ),
      ),
    );
  }
}

/// Appends a received attachment (image/file) bubble after it was saved.
class AddReceivedAttachmentAction extends ReduxAction<ChatNotifier, ChatState> {
  final String fingerprint;
  final String fileName;
  final FileType fileType;
  final String? filePath;
  final String? ip;

  AddReceivedAttachmentAction({
    required this.fingerprint,
    required this.fileName,
    required this.fileType,
    this.filePath,
    this.ip,
  });

  @override
  ChatState reduce() {
    final key = state.resolveKey(fingerprint: fingerprint, ip: ip);
    final ipMap = {...state.ipToFingerprint};
    if (ip != null && ip!.isNotEmpty && fingerprint.isNotEmpty) {
      ipMap[ip!] = fingerprint;
    } else if (ip != null && ip!.isNotEmpty && key.isNotEmpty) {
      ipMap[ip!] = key;
    }
    String target = key;
    if (ip != null && ip!.isNotEmpty) {
      final openKey = state.ipToFingerprint[ip!];
      if (openKey != null && state.activePeers.contains(openKey)) {
        target = openKey;
      } else if (state.activePeers.contains('ip:$ip')) {
        target = 'ip:$ip';
      }
    }
    if (fingerprint.isNotEmpty && state.activePeers.contains(fingerprint)) {
      target = fingerprint;
    }
    return state.copyWith(
      threads: _appendMessage(
        state.threads,
        target,
        ChatMessage.attachment(
          direction: ChatMessageDirection.received,
          fileName: fileName,
          fileType: fileType,
          filePath: filePath,
        ),
      ),
      ipToFingerprint: ipMap,
    );
  }
}

/// Clears the conversation with a peer.
class ClearChatAction extends ReduxAction<ChatNotifier, ChatState> {
  final String fingerprint;

  ClearChatAction({required this.fingerprint});

  @override
  ChatState reduce() {
    final newThreads = {...state.threads}..remove(fingerprint);
    return state.copyWith(threads: newThreads);
  }
}
