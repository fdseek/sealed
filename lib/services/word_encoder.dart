
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum TokenMode { persian, mixed }

extension TokenModeExt on TokenMode {
  String get label => switch (this) {
        TokenMode.persian => 'فارسی',
        TokenMode.mixed   => 'فارسی + ایموجی',
      };
  String get key => name;
}

/// WordEncoderService
/// bytes → Persian words (256 unique words, one per byte)
/// optional mixed: every 8th token replaced by emoji (less noisy)
/// gzip compression applied before encoding → shorter output
class WordEncoderService {
  static const _storage = FlutterSecureStorage();
  static const _kMode = 'word_encoder_mode';

  // ── 256 unique Persian words ──────────────────────────────────────────────
  // Must stay exactly 256, all unique
  static const List<String> _words = [
    'آب',       'آسمان',    'آتش',      'ابر',      'امید',     'انسان',    'ایران',    'باد',
    'باران',    'باغ',      'برف',      'بهار',     'پرواز',    'پنجره',    'پیام',     'تلاش',
    'توسعه',    'جاده',     'جهان',     'حقیقت',    'خورشید',   'دریا',     'درخت',     'دل',
    'دوست',     'راه',      'رود',      'رویا',     'روز',      'زمان',     'زمین',     'زیبا',
    'سفر',      'سلام',     'سنگ',      'سکوت',     'شادی',     'شب',       'صبح',      'صدا',
    'طبیعت',    'طلوع',     'عشق',      'علم',      'فردا',     'فرصت',     'فصل',      'فکر',
    'قلم',      'قلب',      'کار',      'کتاب',     'کوه',      'کودک',     'گل',       'لبخند',
    'لحظه',     'مردم',     'مهر',      'مهتاب',    'موج',      'نور',      'نگاه',     'هدف',
    'هوا',      'یاد',      'زندگی',    'آرامش',    'محبت',     'مهربانی',  'دوستی',    'امروز',
    'اکنون',    'آینده',    'باور',     'شوق',      'انگیزه',   'توان',     'حرکت',     'رشد',
    'پیشرفت',   'اندیشه',   'خرد',      'دانش',     'آگاهی',    'پیروزی',   'تجربه',    'تمرین',
    'توجه',     'امتحان',   'پایداری',  'یاری',     'همراه',    'همسفر',    'رهایی',    'آغاز',
    'پایان',    'خاطره',    'داستان',   'تصویر',    'نقش',      'راز',      'حس',       'احساس',
    'دیدار',    'گفتگو',    'پرسش',     'پاسخ',     'آواز',     'ترانه',    'نغمه',     'رنگ',
    'عطر',      'خانه',     'خانواده',  'دوام',     'مسیر',     'قدم',      'گام',      'ساحل',
    'افق',      'سپیده',    'پرتو',     'روشنایی',  'گرما',     'نسیم',     'سایه',     'پناه',
    'سپاس',     'بخشش',     'امانت',    'شکوفه',    'چشمه',     'جوی',      'آبشار',    'دشت',
    'پرنده',    'آهو',      'ماه',      'ستاره',    'صبحگاه',   'شامگاه',   'بارقه',    'رعد',
    'برق',      'بیداری',   'یادگار',   'خنده',     'چشم',      'دست',      'لب',       'نقره',
    'بلور',     'آبی',      'زرین',     'سپید',     'سبز',      'سرخ',      'کشتزار',   'گرداب',
    'نهر',      'تپه',      'بوستان',   'چمن',      'شاخه',     'ریشه',     'برگ',      'میوه',
    'دانه',     'بذر',      'خاک',      'گِل',      'طوفان',    'آفتاب',    'مه',       'شبنم',
    'قطره',     'رگبار',    'تگرگ',     'برکه',     'اقیانوس',  'خلیج',     'بندر',     'کشتی',
    'لنگر',     'موج‌شکن',  'صخره',     'غار',      'دره',      'قله',      'یخ',       'برکت',
    'نعمت',     'شکر',      'صبر',      'وفا',      'صداقت',    'شجاعت',    'غرور',     'افتخار',
    'آزادی',    'عدالت',    'صلح',      'وحدت',     'همبستگی',  'مقاومت',   'ایستادگی', 'پشتکار',
    'اراده',    'عزم',      'همت',      'کوشش',     'خلاقیت',   'نوآوری',   'اکتشاف',   'پژوهش',
    'آموزش',    'تدریس',    'یادگیری',  'مطالعه',   'نوشتن',    'خواندن',   'شنیدن',    'دیدن',
    'لمس',      'بوییدن',   'چشیدن',    'درک‌حس',   'اندیشیدن', 'آفریدن',   'ساختن',    'رویاپردازی',
    'امیدواری', 'شکوفایی',  'بالندگی',  'پویایی',   'حضور',     'غیبت',     'آغوش',     'دلتنگی',
    'شوق‌دیدار','وصل',      'هجران',    'انتظار',   'دلدادگی',  'پیوند',    'جدایی',    'بازگشت',
    'آشتی',     'گذشت',     'درک',      'همدلی',    'احترام',   'اعتماد',   'صمیمیت',   'دوستداری',
  ];

  // ── 32 emojis for mixed mode (replace every 8th word) ────────────────────
  static const List<String> _mixedEmojis = [
    '🌸', '⭐', '🔥', '💧', '🌈', '🌙', '🌿', '🎵',
    '💡', '🔑', '🌊', '🏔', '🎯', '✨', '🌺', '🍀',
    '🌱', '🌳', '💛', '💙', '🌞', '🌍', '🎈', '🏆',
    '📚', '🧠', '🌷', '🍁', '⚡', '🌟', '💎', '🕊',
  ];

  // ── Build 256-token list ──────────────────────────────────────────────────

  static List<String> _buildTokens(TokenMode mode) {
    assert(_words.length == 256, 'Must have exactly 256 words');
    if (mode == TokenMode.persian) return _words;

    // mixed: replace index 8,16,24...248 (32 slots) with emojis
    final tokens = List<String>.from(_words);
    for (int i = 0; i < 32; i++) {
      tokens[(i + 1) * 8 - 1] = _mixedEmojis[i];
    }
    return tokens;
  }

  // ── Persist mode ──────────────────────────────────────────────────────────

  static Future<void> saveMode(TokenMode mode) =>
      _storage.write(key: _kMode, value: mode.key);

  static Future<TokenMode> loadMode() async {
    final v = await _storage.read(key: _kMode);
    return TokenMode.values.firstWhere(
      (m) => m.key == v,
      orElse: () => TokenMode.persian,
    );
  }

  // ── Encode: bytes → gzip → tokens ────────────────────────────────────────

  static String encode(Uint8List bytes, TokenMode mode) {
    final tokens = _buildTokens(mode);

    // gzip compress
    final compressed = Uint8List.fromList(GZipCodec().encode(bytes));

    // 1-byte flag: bit0=compressed, bit1=mode(0=persian,1=mixed)
    final modeFlag = mode == TokenMode.mixed ? 2 : 0;
    final flags = 1 | modeFlag; // bit0 always 1 = compressed

    // 4-byte length of original
    final len = bytes.length;
    final data = Uint8List(1 + 4 + compressed.length);
    data[0] = flags;
    data[1] = (len >> 24) & 0xFF;
    data[2] = (len >> 16) & 0xFF;
    data[3] = (len >> 8)  & 0xFF;
    data[4] =  len        & 0xFF;
    data.setRange(5, data.length, compressed);

    return data.map((b) => tokens[b]).join(' ');
  }

  // ── Decode: tokens → bytes → gunzip ──────────────────────────────────────

  static Uint8List decode(String text, TokenMode mode) {
    final tokens = _buildTokens(mode);
    final tokenToIndex = <String, int>{
      for (int i = 0; i < tokens.length; i++) tokens[i]: i,
    };

    final parts = text.trim().split(' ').where((t) => t.isNotEmpty).toList();
    if (parts.length < 5) throw WordEncoderException('داده ناقص است');

    final raw = Uint8List(parts.length);
    for (int i = 0; i < parts.length; i++) {
      final idx = tokenToIndex[parts[i]];
      if (idx == null) throw WordEncoderException('توکن نامعتبر: ${parts[i]}');
      raw[i] = idx;
    }

    final flags = raw[0];
    final compressed = (flags & 1) == 1;
    final len = ((raw[1] << 24) | (raw[2] << 16) | (raw[3] << 8) | raw[4]);
    final payload = raw.sublist(5);

    final result = compressed
        ? Uint8List.fromList(GZipCodec().decode(payload))
        : payload;

    if (result.length != len) throw WordEncoderException('داده خراب است');
    return result;
  }
}

class WordEncoderException implements Exception {
  final String message;
  WordEncoderException(this.message);
  @override
  String toString() => message;
}