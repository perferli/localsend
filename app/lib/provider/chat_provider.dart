import 'package:localsend_app/model/chat_message.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// State of all chat conversations.
///
/// Conversations are grouped by the peer's fingerprint so a device keeps its
/// history even if its IP address changes between sessions.
class ChatState {
  /// Messages per peer fingerprint, in chronological order.
  final Map<String, List<ChatMessage>> threads;

  /// Fingerprints of peers with a currently open chat window.
  ///
  /// Incoming messages from these peers are accepted automatically (without the
  /// usual confirmation popup) so a real back-and-forth conversation is possible.
  /// Peers you never opened a chat with keep the normal confirmation flow, so
  /// this does not weaken LocalSend's consent model for strangers.
  final Set<String> activePeers;

  const ChatState({
    required this.threads,
    required this.activePeers,
  });

  static const empty = ChatState(threads: <String, List<ChatMessage>>{}, activePeers: <String>{});

  List<ChatMessage> threadOf(String fingerprint) => threads[fingerprint] ?? const [];

  bool isActive(String fingerprint) => activePeers.contains(fingerprint);

  ChatState copyWith({
    Map<String, List<ChatMessage>>? threads,
    Set<String>? activePeers,
  }) {
    return ChatState(
      threads: threads ?? this.threads,
      activePeers: activePeers ?? this.activePeers,
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

  OpenChatAction({required this.fingerprint});

  @override
  ChatState reduce() {
    return state.copyWith(
      activePeers: {...state.activePeers, fingerprint},
      threads: state.threads.containsKey(fingerprint) ? state.threads : {...state.threads, fingerprint: const []},
    );
  }
}

/// Marks a peer's chat as closed.
class CloseChatAction extends ReduxAction<ChatNotifier, ChatState> {
  final String fingerprint;

  CloseChatAction({required this.fingerprint});

  @override
  ChatState reduce() {
    return state.copyWith(
      activePeers: {...state.activePeers}..remove(fingerprint),
    );
  }
}

/// Appends a message sent by this device.
class AddSentMessageAction extends ReduxAction<ChatNotifier, ChatState> {
  final String fingerprint;
  final String text;

  AddSentMessageAction({required this.fingerprint, required this.text});

  @override
  ChatState reduce() {
    return state.copyWith(
      threads: _appendMessage(
        state.threads,
        fingerprint,
        ChatMessage(text: text, direction: ChatMessageDirection.sent, timestamp: DateTime.now()),
      ),
    );
  }
}

/// Appends a message received from a peer.
class AddReceivedMessageAction extends ReduxAction<ChatNotifier, ChatState> {
  final String fingerprint;
  final String text;

  AddReceivedMessageAction({required this.fingerprint, required this.text});

  @override
  ChatState reduce() {
    return state.copyWith(
      threads: _appendMessage(
        state.threads,
        fingerprint,
        ChatMessage(text: text, direction: ChatMessageDirection.received, timestamp: DateTime.now()),
      ),
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
