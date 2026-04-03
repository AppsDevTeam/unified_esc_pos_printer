import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:unified_esc_pos_printer/unified_esc_pos_printer.dart';

/// Labels for the selectable test ticket sections.
const Map<int, String> kTestPartLabels = {
  1: 'Image & Text',
  2: 'Row & Columns',
  3: 'Multilingual',
  4: 'Text Raster',
  5: 'Barcodes',
  6: 'QR, Beep & Cashdrawer',
};

/// Builds a test ticket containing only the [selectedParts].
Future<Ticket> buildTestTicket(Set<int> selectedParts) async {
  final Ticket ticket = await Ticket.create(PaperSize.mm80);

  if (selectedParts.contains(1)) await _addPart1(ticket);
  if (selectedParts.contains(2)) _addPart2(ticket);
  if (selectedParts.contains(3)) await _addPart3(ticket);
  if (selectedParts.contains(4)) await _addPart4(ticket);
  if (selectedParts.contains(5)) _addPart5(ticket);
  if (selectedParts.contains(6)) _addPart6(ticket);

  _addFooter(ticket);
  ticket.cut();

  return ticket;
}

// ── PART 1: Image, Title, Text Styles, Sizes, Alignment, Fonts ──────────

Future<void> _addPart1(Ticket ticket) async {
  final ByteData byteData = await rootBundle.load('assets/flutter_bnw.png');
  final img.Image banner = img.decodeImage(byteData.buffer.asUint8List())!;
  ticket.imageRaster(
    banner,
    align: PrintAlign.center,
    maxWidth: 400,
    maxHeight: 200,
  );

  ticket.emptyLines();

  ticket.text(
    'CAPABILITY DEMO',
    align: PrintAlign.center,
    style: const PrintTextStyle(
      bold: true,
      height: TextSize.size2,
      width: TextSize.size2,
    ),
  );
  ticket.text(
    'unified_esc_pos_printer',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true),
  );

  ticket.separator(char: '=');

  ticket.text(
    'TEXT STYLES',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true, underline: true),
  );

  ticket.emptyLines();

  ticket.text('Normal text');
  ticket.text('Bold text', style: const PrintTextStyle(bold: true));
  ticket.text('Underline text', style: const PrintTextStyle(underline: true));
  ticket.text('Reverse text', style: const PrintTextStyle(reverse: true));
  ticket.text(
    'Bold + Underline',
    style: const PrintTextStyle(bold: true, underline: true),
  );

  ticket.emptyLines();

  ticket.text(
    'SIZE VARIATIONS',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true),
  );
  ticket.text(
    'Size 1 (default)',
    style: const PrintTextStyle(height: TextSize.size1, width: TextSize.size1),
  );
  ticket.text(
    'Size 2',
    style: const PrintTextStyle(height: TextSize.size2, width: TextSize.size2),
  );
  ticket.text(
    'Size 3',
    style: const PrintTextStyle(height: TextSize.size3, width: TextSize.size3),
  );
  ticket.text(
    'Tall only',
    style: const PrintTextStyle(height: TextSize.size3, width: TextSize.size1),
  );
  ticket.text(
    'Wide only',
    style: const PrintTextStyle(height: TextSize.size1, width: TextSize.size3),
  );

  ticket.emptyLines();

  ticket.text(
    'ALIGNMENT',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true),
  );
  ticket.text('Left aligned', align: PrintAlign.left);
  ticket.text('Center aligned', align: PrintAlign.center);
  ticket.text('Right aligned', align: PrintAlign.right);
  ticket.emptyLines();

  ticket.text(
    'FONT TYPES',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true),
  );
  ticket.text(
    'Font A (default)',
    style: const PrintTextStyle(fontType: FontType.fontA),
  );
  ticket.text(
    'Font B (smaller)',
    style: const PrintTextStyle(fontType: FontType.fontB),
  );

  ticket.emptyLines();
}

// ── PART 2: Separators, 2-col, 3-col, 4-col Tables ─────────────────────

void _addPart2(Ticket ticket) {
  ticket.text(
    'SEPARATORS',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true),
  );
  ticket.separator();
  ticket.separator(char: '=');
  ticket.separator(char: '*');
  ticket.separator(char: '~');

  ticket.emptyLines();

  ticket.text(
    '2-COLUMN TABLE',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true),
  );
  ticket.separator();
  ticket.row([
    PrintColumn(text: 'Item', flex: 2, style: const PrintTextStyle(bold: true)),
    PrintColumn(
      text: 'Price',
      flex: 1,
      align: PrintAlign.right,
      style: const PrintTextStyle(bold: true),
    ),
  ]);
  ticket.separator();
  ticket.row([
    PrintColumn(text: 'Espresso', flex: 2),
    PrintColumn(text: '\$3.50', flex: 1, align: PrintAlign.right),
  ]);
  ticket.row([
    PrintColumn(text: 'Cappuccino', flex: 2),
    PrintColumn(text: '\$4.25', flex: 1, align: PrintAlign.right),
  ]);
  ticket.row([
    PrintColumn(text: 'Latte Macchiato', flex: 2),
    PrintColumn(text: '\$4.75', flex: 1, align: PrintAlign.right),
  ]);
  ticket.separator();
  ticket.row([
    PrintColumn(
      text: 'TOTAL',
      flex: 2,
      style: const PrintTextStyle(bold: true),
    ),
    PrintColumn(
      text: '\$12.50',
      flex: 1,
      align: PrintAlign.right,
      style: const PrintTextStyle(bold: true),
    ),
  ]);

  ticket.emptyLines();

  ticket.text(
    '3-COLUMN TABLE',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true),
  );
  ticket.separator();
  ticket.row([
    PrintColumn(
      text: 'Item',
      flex: 5,
      style: const PrintTextStyle(bold: true),
    ),
    PrintColumn(
      text: 'Qty',
      flex: 3,
      align: PrintAlign.center,
      style: const PrintTextStyle(bold: true),
    ),
    PrintColumn(
      text: 'Total',
      flex: 4,
      align: PrintAlign.right,
      style: const PrintTextStyle(bold: true),
    ),
  ]);
  ticket.separator();
  ticket.row([
    PrintColumn(text: 'Apple', flex: 5),
    PrintColumn(text: 'x3', flex: 3, align: PrintAlign.center),
    PrintColumn(text: '\$2.97', flex: 4, align: PrintAlign.right),
  ]);
  ticket.row([
    PrintColumn(text: 'Banana', flex: 5),
    PrintColumn(text: 'x6', flex: 3, align: PrintAlign.center),
    PrintColumn(text: '\$1.50', flex: 4, align: PrintAlign.right),
  ]);
  ticket.row([
    PrintColumn(text: 'Orange', flex: 5),
    PrintColumn(text: 'x2', flex: 3, align: PrintAlign.center),
    PrintColumn(text: '\$3.98', flex: 4, align: PrintAlign.right),
  ]);
  ticket.separator();
  ticket.row([
    PrintColumn(
      text: 'Grand Total',
      flex: 2,
      style: const PrintTextStyle(bold: true),
    ),
    PrintColumn(
      text: '\$8.45',
      flex: 1,
      align: PrintAlign.right,
      style: const PrintTextStyle(bold: true),
    ),
  ]);

  ticket.emptyLines();

  ticket.text(
    '4-COLUMN TABLE',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true),
  );
  ticket.separator();
  ticket.row([
    PrintColumn(text: '#', flex: 1, style: const PrintTextStyle(bold: true)),
    PrintColumn(
      text: 'Name',
      flex: 5,
      style: const PrintTextStyle(bold: true),
    ),
    PrintColumn(
      text: 'Qty',
      flex: 2,
      align: PrintAlign.center,
      style: const PrintTextStyle(bold: true),
    ),
    PrintColumn(
      text: 'Price',
      flex: 4,
      align: PrintAlign.right,
      style: const PrintTextStyle(bold: true),
    ),
  ]);
  ticket.separator();
  ticket.row([
    PrintColumn(text: '1', flex: 1),
    PrintColumn(text: 'Widget', flex: 5),
    PrintColumn(text: '10', flex: 2, align: PrintAlign.center),
    PrintColumn(text: '\$99.90', flex: 4, align: PrintAlign.right),
  ]);
  ticket.row([
    PrintColumn(text: '2', flex: 1),
    PrintColumn(
      text: 'Lorem ipsum dolor sit amet, consectetur adipiscing elit.',
      flex: 5,
    ),
    PrintColumn(text: '5', flex: 2, align: PrintAlign.center),
    PrintColumn(text: '\$74.95', flex: 4, align: PrintAlign.right),
  ]);
  ticket.row([
    PrintColumn(text: '3', flex: 1),
    PrintColumn(text: 'Fidget', flex: 5),
    PrintColumn(text: '5', flex: 2, align: PrintAlign.center),
    PrintColumn(text: '\$74.95', flex: 4, align: PrintAlign.right),
  ]);
  ticket.separator();

  ticket.emptyLines();
}

// ── PART 3: Multilingual Text ───────────────────────────────────────────

Future<void> _addPart3(Ticket ticket) async {
  ticket.text(
    'MULTILINGUAL TEXT',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true),
  );
  ticket.separator();

  ticket.text('Chinese:', style: const PrintTextStyle(bold: true));
  await ticket.textRaster('欢迎光临，谢谢惠顾！');
  await ticket.textRaster('恭喜发财');
  ticket.emptyLines();

  ticket.text('Japanese:', style: const PrintTextStyle(bold: true));
  await ticket.textRaster('ようこそ、ありがとう！');
  await ticket.textRaster('東山奈央はこの世界で一番かわいい');
  ticket.emptyLines();

  ticket.text('Javanese:', style: const PrintTextStyle(bold: true));
  await ticket.textRaster('Sꦈꦒꦺꦤ꧀ꦒ꧀ ꦫwꦈꦲ꧀, ꦩꦠꦸꦂ ꦤꦸwꦈꦤ꧀!');
  await ticket.textRaster('ꦗwꦄ ꦄꦢꦭꦲ꧀ ꦏꦺꦴꦌꦤ꧀ꦠ꧀ꦗꦶ');
  ticket.emptyLines();

  ticket.text('Korean:', style: const PrintTextStyle(bold: true));
  await ticket.textRaster('환영합니다, 감사합니다!');
  await ticket.textRaster('최신 한국 드라마를 알려주세요');
  ticket.emptyLines();

  ticket.text('Arabic:', style: const PrintTextStyle(bold: true));
  await ticket.textRaster(
    'سلامت داتڠ، تريما کاسيه!',
    textDirection: TextDirection.rtl,
  );
  await ticket.textRaster(
    'ستي حلال براذر',
    textDirection: TextDirection.rtl,
  );
  ticket.emptyLines();

  ticket.text('Hindi:', style: const PrintTextStyle(bold: true));
  await ticket.textRaster('स्वागत है, धन्यवाद!');
  await ticket.textRaster('चला छैया छैया छैया');
  ticket.emptyLines();

  ticket.text('Thai:', style: const PrintTextStyle(bold: true));
  await ticket.textRaster('ยินดีต้อนรับ ขอบคุณ!');
  await ticket.textRaster('เช็กว่ายังออริและไม่แก้ไข');
  ticket.emptyLines();

  ticket.text('Russian:', style: const PrintTextStyle(bold: true));
  await ticket.textRaster('Добро пожаловать, спасибо!');
  await ticket.textRaster('За Родину Урааааа!');
  ticket.emptyLines();

  ticket.text('European:', style: const PrintTextStyle(bold: true));
  await ticket.textRaster('French: Bienvenue, merci à bientôt !');
  await ticket.textRaster('German: Willkommen, vielen Dank!');
  await ticket.textRaster('Spanish: ¡Bienvenidos, muchas gracias señor!');
  await ticket.textRaster('Portuguese: Bem-vindos, muito obrigado a você!');

  ticket.emptyLines();
}

// ── PART 4: Text Raster Styles ──────────────────────────────────────────

Future<void> _addPart4(Ticket ticket) async {
  ticket.text(
    'TEXT RASTER STYLES',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true),
  );
  ticket.separator();

  ticket.text('Default (24 pt):', style: const PrintTextStyle(bold: true));
  await ticket.textRaster('欢迎光临 · Welcome · Bienvenido');
  ticket.emptyLines();

  ticket.text('Large (36 pt):', style: const PrintTextStyle(bold: true));
  await ticket.textRaster(
    '大きな文字 · 큰 글꼴',
    style: const TextStyle(fontSize: 36),
  );
  ticket.emptyLines();

  ticket.text('Bold:', style: const PrintTextStyle(bold: true));
  await ticket.textRaster(
    'Bold — Gras — Negrita — 굵게',
    style: const TextStyle(fontWeight: FontWeight.bold),
  );
  ticket.emptyLines();

  ticket.text('Italic:', style: const PrintTextStyle(bold: true));
  await ticket.textRaster(
    'Italic — Cursiva — 이탤릭',
    style: const TextStyle(fontStyle: FontStyle.italic),
  );
  ticket.emptyLines();

  ticket.text('Bold + Italic:', style: const PrintTextStyle(bold: true));
  await ticket.textRaster(
    'Bold Italic — بولد إيطاليك',
    style: const TextStyle(
      fontWeight: FontWeight.bold,
      fontStyle: FontStyle.italic,
    ),
  );
  ticket.emptyLines();

  ticket.text('Underline:', style: const PrintTextStyle(bold: true));
  await ticket.textRaster(
    'Underline · 밑줄 · 下線',
    style: const TextStyle(decoration: TextDecoration.underline),
  );
  ticket.emptyLines();

  ticket.text('Small (18 pt):', style: const PrintTextStyle(bold: true));
  await ticket.textRaster(
    'Small text — Petit texte — 소문자',
    style: const TextStyle(fontSize: 18),
  );
  ticket.emptyLines();

  ticket.text('Letter spacing:', style: const PrintTextStyle(bold: true));
  await ticket.textRaster(
    'S P A C E D',
    style: const TextStyle(letterSpacing: 6),
  );
  ticket.emptyLines();

  ticket.text('Center aligned:', style: const PrintTextStyle(bold: true));
  await ticket.textRaster(
    '가운데 정렬 · Centré · 居中',
    align: PrintAlign.center,
  );
  ticket.emptyLines();

  ticket.text('Right aligned:', style: const PrintTextStyle(bold: true));
  await ticket.textRaster(
    'Right · Droite · 右揃え',
    align: PrintAlign.right,
  );
  ticket.emptyLines();

  ticket.text('RTL bold (Arabic):', style: const PrintTextStyle(bold: true));
  await ticket.textRaster(
    'مرحبا — نص عريض كبير',
    style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
    textDirection: TextDirection.rtl,
    align: PrintAlign.right,
  );
  ticket.emptyLines();
}

// ── PART 5: Barcodes ────────────────────────────────────────────────────

void _addPart5(Ticket ticket) {
  ticket.text(
    'BARCODES',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true),
  );
  ticket.separator();

  ticket.text('EAN-13:', style: const PrintTextStyle(bold: true));
  ticket.barcode(
    '590123412345',
    type: BarcodeType.ean13,
    textPosition: BarcodeTextPosition.below,
  );
  ticket.emptyLines();

  ticket.text('EAN-8:', style: const PrintTextStyle(bold: true));
  ticket.barcode(
    '9031101',
    type: BarcodeType.ean8,
    textPosition: BarcodeTextPosition.below,
  );
  ticket.emptyLines();

  ticket.text('UPC-A:', style: const PrintTextStyle(bold: true));
  ticket.barcode(
    '01234567890',
    type: BarcodeType.upcA,
    textPosition: BarcodeTextPosition.below,
  );
  ticket.emptyLines();

  ticket.text('CODE 128:', style: const PrintTextStyle(bold: true));
  ticket.barcode(
    '{BABCDEF12345',
    type: BarcodeType.code128,
    textPosition: BarcodeTextPosition.below,
  );
  ticket.emptyLines();

  ticket.text('CODE 39:', style: const PrintTextStyle(bold: true));
  ticket.barcode(
    'HELLO123',
    type: BarcodeType.code39,
    textPosition: BarcodeTextPosition.below,
  );
  ticket.emptyLines();
}

// ── PART 6: QR Codes, Raster Images, Beep ──────────────────────────────

void _addPart6(Ticket ticket) {
  ticket.text(
    'QR CODES',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true),
  );
  ticket.separator();

  ticket.text('Small (size 3):', style: const PrintTextStyle(bold: true));
  ticket.qrcode('https://pub.dev', size: QRSize.size3);
  ticket.emptyLines();

  ticket.text('Medium (size 5):', style: const PrintTextStyle(bold: true));
  ticket.qrcode('https://pub.dev', size: QRSize.size5);
  ticket.emptyLines();

  ticket.text('Large (size 8):', style: const PrintTextStyle(bold: true));
  ticket.qrcode('https://pub.dev', size: QRSize.size8, cor: QRCorrection.H);
  ticket.emptyLines();

  ticket.text(
    'RASTER IMAGE',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true),
  );
  ticket.separator();

  final img.Image checker = img.Image(width: 160, height: 40);
  img.fill(checker, color: img.ColorRgb8(255, 255, 255));
  for (int y = 0; y < 40; y += 8) {
    for (int x = 0; x < 160; x += 8) {
      if ((x ~/ 8 + y ~/ 8) % 2 == 0) {
        img.fillRect(checker,
            x1: x, y1: y, x2: x + 7, y2: y + 7, color: img.ColorRgb8(0, 0, 0));
      }
    }
  }
  ticket.imageRaster(checker, align: PrintAlign.center);
  ticket.emptyLines();

  final img.Image gradient = img.Image(width: 200, height: 20);
  for (int x = 0; x < 200; x++) {
    final int v = (x * 255 ~/ 199).clamp(0, 255);
    for (int y = 0; y < 20; y++) {
      gradient.setPixelRgb(x, y, v, v, v);
    }
  }
  ticket.text('Gradient (dithered):', align: PrintAlign.center);
  ticket.imageRaster(gradient, align: PrintAlign.center);
  ticket.emptyLines();

  ticket.text(
    'BEEP TEST',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true),
  );
  ticket.beep(n: 5, duration: BeepDuration.beep100ms);
  ticket.emptyLines();

  ticket.text(
    'OPEN CASH DRAWER TEST',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true),
  );
  ticket.openCashDrawer();
  ticket.emptyLines();
}

// ── Footer ──────────────────────────────────────────────────────────────

void _addFooter(Ticket ticket) {
  ticket.separator(char: '=');
  ticket.text(
    'unified_esc_pos_printer',
    align: PrintAlign.center,
    style: const PrintTextStyle(bold: true),
  );
  ticket.text('Capabilities Demonstrated!', align: PrintAlign.center);
  ticket.text(
    DateTime.now().toString().substring(0, 19),
    align: PrintAlign.center,
  );
  ticket.separator(char: '=');
}
