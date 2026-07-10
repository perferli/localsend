import 'dart:convert';

import 'package:common/model/device.dart';
import 'package:common/model/file_type.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/model/chat_message.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/chat_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/util/device_type_ext.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// A persistent chat conversation with a single peer device.
///
/// Unlike the one-shot "send message" flow, this page lets you send an
/// arbitrary number of text messages in a row without re-picking the
/// clipboard/text each time. Incoming messages from the same peer are shown
/// inline in the same conversation.
class ChatPage extends StatefulWidget {
  final Device device;
  final String? nameOverride;

  const ChatPage({
    required this.device,
    this.nameOverride,
    super.key,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with Refena {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  bool _sending = false;
  int _lastCount = 0;

  String get _fingerprint => widget.device.fingerprint;

  @override
  void initState() {
    super.initState();
    // Mark the chat as open once mounted, so incoming messages from this peer
    // are accepted automatically instead of showing a confirmation popup.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.redux(chatProvider).dispatch(OpenChatAction(fingerprint: _fingerprint));
    });
  }

  @override
  void dispose() {
    try {
      ref.redux(chatProvider).dispatch(CloseChatAction(fingerprint: _fingerprint));
    } catch (_) {
      // ignore: the container may already be disposed during app shutdown
    }
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) {
      return;
    }
    _controller.clear();
    ref.redux(chatProvider).dispatch(AddSentMessageAction(fingerprint: _fingerprint, text: text));
    _focusNode.requestFocus();

    final List<int> bytes = utf8.encode(text);
    final file = CrossFile(
      name: '${_uuid.v4()}.txt',
      fileType: FileType.text,
      size: bytes.length,
      thumbnail: null,
      asset: null,
      path: null,
      bytes: bytes,
      lastModified: null,
      lastAccessed: null,
    );

    setState(() => _sending = true);
    try {
      await ref.notifier(sendProvider).startSession(
            target: widget.device,
            files: [file],
            background: true,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send message: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(chatProvider).threadOf(_fingerprint);
    if (messages.length != _lastCount) {
      _lastCount = messages.length;
      _scrollToBottom();
    }

    final title = widget.nameOverride ?? widget.device.alias;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(widget.device.deviceType.icon),
            const SizedBox(width: 10),
            Expanded(
              child: Text(title, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: messages.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No messages yet.\nType below to start the conversation.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      itemCount: messages.length,
                      itemBuilder: (context, index) => _MessageBubble(message: messages[index]),
                    ),
            ),
            _InputBar(
              controller: _controller,
              focusNode: _focusNode,
              sending: _sending,
              onSend: _send,
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const _MessageBubble({required this.message});

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final mine = message.isMine;
    final bubbleColor = mine ? colorScheme.primary : colorScheme.surfaceContainerHighest;
    final textColor = mine ? colorScheme.onPrimary : colorScheme.onSurface;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.75),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              message.text,
              style: TextStyle(color: textColor),
            ),
            const SizedBox(height: 3),
            Text(
              _formatTime(message.timestamp),
              style: TextStyle(color: textColor.withValues(alpha: 0.6), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final Future<void> Function() onSend;

  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: 'Type a message',
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              onPressed: sending ? null : () => onSend(),
              icon: sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
