import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The caller owns and removes this decrypted file when the route closes.
class DocumentPreviewPage extends StatefulWidget {
  const DocumentPreviewPage({
    required this.file,
    required this.isPdf,
    super.key,
  });
  final File file;
  final bool isPdf;
  @override
  State<DocumentPreviewPage> createState() => _DocumentPreviewPageState();
}

class _DocumentPreviewPageState extends State<DocumentPreviewPage> {
  static const _channel = MethodChannel('com.jibi.jibi/document_preview');
  int _page = 0;
  int _pageCount = 1;
  late Future<Uint8List> _image = _load();
  Future<Uint8List> _load() async {
    if (!widget.isPdf) return widget.file.readAsBytes();
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'renderPdf',
      {'path': widget.file.path, 'page': _page},
    );
    _pageCount = result!['pageCount'] as int;
    return result['bytes'] as Uint8List;
  }

  void _changePage(int page) => setState(() {
    _page = page;
    _image = _load();
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('معاينة المستند')),
    body: FutureBuilder<Uint8List>(
      future: _image,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(
            child: Text(
              'تعذر عرض هذا الملف. قد يكون تالفاً أو محمياً بكلمة مرور.',
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return Column(
          children: [
            Expanded(
              child: Center(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 5,
                  child: Image.memory(
                    snapshot.data!,
                    gaplessPlayback: false,
                    errorBuilder: (_, error, stack) =>
                        const Text('صيغة الصورة غير مدعومة.'),
                  ),
                ),
              ),
            ),
            if (widget.isPdf)
              SafeArea(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: 'الصفحة السابقة',
                      onPressed: _page > 0
                          ? () => _changePage(_page - 1)
                          : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                    Text('${_page + 1} / $_pageCount'),
                    IconButton(
                      tooltip: 'الصفحة التالية',
                      onPressed: _page + 1 < _pageCount
                          ? () => _changePage(_page + 1)
                          : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );
}
