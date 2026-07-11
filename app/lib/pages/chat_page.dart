import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:common/model/device.dart';
import 'package:common/model/file_type.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/model/chat_message.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/chat_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/util/device_type_ext.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// A persistent chat conversation with a single peer device.
///
/// Supports text, images and arbitrary files. Incoming items from the same
/// peer appear inline when the chat is open.
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
  String? get _ip => widget.device.ip;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.redux(chatProvider).dispatch(OpenChatAction(fingerprint: _fingerprint, ip: _ip));
    });
  }

  @override
  void dispose() {
    try {
      ref.redux(chatProvider).dispatch(CloseChatAction(fingerprint: _fingerprint, ip: _ip));
    } catch (_) {
      // container may already be disposed during app shutdown
    }
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _sendText() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) {
      return;
    }
    _controller.clear();
    ref.redux(chatProvider).dispatch(
          AddSentMessageAction(fingerprint: _fingerprint, text: text, ip: _ip),
        );
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

    await _startTransfer([file]);
  }

  Future<void> _pickAndSendFiles() async {
    if (_sending) {
      return;
    }
    try {
      final List<CrossFile> files;
      if (defaultTargetPlatform == TargetPlatform.android) {
        final result = await android_channel.pickFilesAndroid();
        if (result == null || result.isEmpty) {
          return;
        }
        files = await Future.wait(result.map(CrossFileConverters.convertFileInfo));
      } else {
        final result = await openFiles();
        if (result.isEmpty) {
          return;
        }
        files = await Future.wait(result.map(CrossFileConverters.convertXFile));
      }
      if (files.isEmpty) {
        return;
      }

      for (final f in files) {
        List<int>? preview;
        if (f.fileType == FileType.image) {
          try {
            if (f.bytes != null) {
              preview = f.bytes;
            } else if (f.path != null && !f.path!.startsWith('content://')) {
              final bytes = await File(f.path!).readAsBytes();
              // Cap preview to ~2MB so the chat state stays light.
              if (bytes.lengthInBytes <= 2 * 1024 * 1024) {
                preview = bytes;
              }
            }
          } catch (_) {
            // preview is optional
          }
        }
        ref.redux(chatProvider).dispatch(
              AddSentAttachmentAction(
                fingerprint: _fingerprint,
                fileName: f.name,
                fileType: f.fileType,
                filePath: f.path,
                previewBytes: preview,
                ip: _ip,
              ),
            );
      }

      await _startTransfer(files);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not pick files: $e')),
        );
      }
    }
  }

  Future<void> _startTransfer(List<CrossFile> files) async {
    setState(() => _sending = true);
    try {
      await ref.notifier(sendProvider).startSession(
            target: widget.device,
            files: files,
            background: true,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send: $e')),
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

  List<ChatMessage> _messagesForPeer(ChatState chat) {
    final key = chat.resolveKey(fingerprint: _fingerprint, ip: _ip);
    final primary = chat.threadOf(key);
    // Merge any stray thread that was keyed only by IP fallback.
    if (_ip != null && key != 'ip:$_ip') {
      final alt = chat.threadOf('ip:$_ip');
      if (alt.isNotEmpty) {
        final merged = [...primary, ...alt]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        return merged;
      }
    }
    if (_fingerprint.isNotEmpty && key != _fingerprint) {
      final alt = chat.threadOf(_fingerprint);
      if (alt.isNotEmpty && !identical(alt, primary)) {
        final merged = [...primary, ...alt]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        return merged;
      }
    }
    return primary;
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    final messages = _messagesForPeer(chat);
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
                          'No messages yet.\nType below or tap + to send a file/image.',
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
              onSend: _sendText,
              onAttach: _pickAndSendFiles,
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
        padding: message.kind == ChatContentKind.text
            ? const EdgeInsets.symmetric(horizontal: 14, vertical: 10)
            : const EdgeInsets.all(8),
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
            if (message.kind == ChatContentKind.text)
              SelectableText(
                message.text ?? '',
                style: TextStyle(color: textColor),
              )
            else if (message.isImage)
              _ImageContent(message: message, textColor: textColor)
            else
              _FileContent(message: message, textColor: textColor),
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

class _ImageContent extends StatelessWidget {
  final ChatMessage message;
  final Color textColor;

  const _ImageContent({required this.message, required this.textColor});

  @override
  Widget build(BuildContext context) {
    Widget? image;
    if (message.previewBytes != null) {
      image = Image.memory(
        Uint8List.fromList(message.previewBytes!),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _fallback(textColor),
      );
    } else if (message.filePath != null &&
        message.filePath!.isNotEmpty &&
        !message.filePath!.startsWith('content://') &&
        !kIsWeb) {
      final file = File(message.filePath!);
      if (file.existsSync()) {
        image = Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallback(textColor),
        );
      }
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240, minWidth: 120),
        child: image ?? _fallback(textColor),
      ),
    );
  }

  Widget _fallback(Color textColor) {
    return Container(
      width: 160,
      height: 120,
      color: Colors.black12,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image, color: textColor, size: 36),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              message.fileName ?? 'image',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(color: textColor, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileContent extends StatelessWidget {
  final ChatMessage message;
  final Color textColor;

  const _FileContent({required this.message, required this.textColor});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.insert_drive_file, color: textColor),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            message.fileName ?? 'file',
            style: TextStyle(color: textColor),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final Future<void> Function() onSend;
  final Future<void> Function() onAttach;

  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.onSend,
    required this.onAttach,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: 'Attach file or image',
              onPressed: sending ? null : () => onAttach(),
              icon: const Icon(Icons.add_circle_outline),
            ),
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
