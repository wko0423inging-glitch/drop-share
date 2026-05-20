import 'package:flutter/material.dart';
import 'package:mime/mime.dart';

class FileTypeHelper {
  static String? mimeOf(String fileName) => lookupMimeType(fileName);

  static IconData iconForFileName(String fileName) =>
      _iconForMime(lookupMimeType(fileName));

  static Color colorForFileName(String fileName) =>
      _colorForMime(lookupMimeType(fileName));

  static IconData _iconForMime(String? mime) {
    if (mime == null) return Icons.insert_drive_file;
    if (mime.startsWith('image/')) return Icons.image;
    if (mime.startsWith('video/')) return Icons.video_file;
    if (mime.startsWith('audio/')) return Icons.audio_file;
    if (mime.startsWith('text/')) return Icons.article;
    switch (mime) {
      case 'application/pdf':
        return Icons.picture_as_pdf;
      case 'application/zip':
      case 'application/x-zip-compressed':
      case 'application/x-rar-compressed':
      case 'application/x-7z-compressed':
      case 'application/gzip':
        return Icons.folder_zip;
      case 'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
      case 'application/msword':
        return Icons.description;
      case 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':
      case 'application/vnd.ms-excel':
        return Icons.table_chart;
      case 'application/vnd.openxmlformats-officedocument.presentationml.presentation':
      case 'application/vnd.ms-powerpoint':
        return Icons.slideshow;
    }
    return Icons.insert_drive_file;
  }

  static Color _colorForMime(String? mime) {
    if (mime == null) return Colors.white54;
    if (mime.startsWith('image/')) return const Color(0xFF34C759);
    if (mime.startsWith('video/')) return const Color(0xFFFF9F0A);
    if (mime.startsWith('audio/')) return const Color(0xFFFF375F);
    if (mime.startsWith('text/')) return const Color(0xFF007AFF);
    if (mime == 'application/pdf') return const Color(0xFFFF453A);
    if (mime.contains('zip') || mime.contains('rar') || mime.contains('7z') || mime.contains('gzip')) {
      return const Color(0xFFFF9F0A);
    }
    if (mime.startsWith('application/')) return const Color(0xFF007AFF);
    return Colors.white54;
  }
}
