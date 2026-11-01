import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:home_widget/home_widget.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:local_auth/local_auth.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

// Tarih seçicilerde seçilebilecek en eski ve en yeni tarih
final DateTime enEskiTarih = DateTime(1990);
final DateTime enYeniTarih = DateTime(2060);

// ---- Uygulamanın renkleri ----
// Koyu mod bilgisi: MaterialApp.builder her temada günceller (bkz. KisiselAsistanApp)
bool koyuMod = false;
// 'sistem' | 'acik' | 'koyu'
final ValueNotifier<String> temaModu = ValueNotifier<String>('sistem');

Color get anaRenk => koyuMod ? const Color(0xFF7078F2) : const Color(0xFF4F46E5);
Color get koyuYazi => koyuMod ? const Color(0xFFE5E7EB) : const Color(0xFF1E293B);
Color get acikZemin => koyuMod ? const Color(0xFF2A2F55) : const Color(0xFFEEF2FF);
Color get griDugme => koyuMod ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
Color get zemin => koyuMod ? const Color(0xFF0F141C) : const Color(0xFFF8FAFC); // sayfa zemini
Color get yuzey => koyuMod ? const Color(0xFF1A2130) : Colors.white; // kart / kutu yüzeyi
Color get yaziRengi => koyuMod ? const Color(0xFFE5E7EB) : Colors.black87;
Color get yaziSoluk => koyuMod ? const Color(0xFF9CA3AF) : Colors.black54;
Color get ikonGri => koyuMod ? const Color(0xFFA9B4C6) : const Color(0xFF475569);
Color get hucreZemin => koyuMod ? const Color(0xFF232B3A) : const Color(0xFFF1F5F9);
Color get hucreSecili => koyuMod ? const Color(0xFF1E3A5F) : const Color(0xFFDBEAFE);
Color get hapGri => koyuMod ? const Color(0xFF475569) : const Color(0xFFCBD5E1);

// Açık temadaki gri tonlarının koyu temadaki karşılıkları
Color gri(int n) {
  if (!koyuMod) return Colors.grey[n]!;
  switch (n) {
    case 50:
      return const Color(0xFF1E2531);
    case 100:
      return const Color(0xFF232B38);
    case 200:
      return const Color(0xFF2D3646);
    case 300:
      return const Color(0xFF3A4455);
    case 400:
      return const Color(0xFF7A8496);
    case 500:
      return const Color(0xFF8D97A8);
    case 600:
      return const Color(0xFFA3ACBB);
    case 700:
      return const Color(0xFFB9C0CC);
    case 800:
      return const Color(0xFFD1D5DB);
    default:
      return const Color(0xFFE5E7EB);
  }
}

// Para renkleri: her yerde aynı anlamda kullanılır (koyu temada biraz daha açık)
Color get gelirRengi => koyuMod ? const Color(0xFF34D399) : const Color(0xFF059669); // gelen para: yeşil
Color get giderRengi => koyuMod ? const Color(0xFFF87171) : const Color(0xFFDC2626); // borç / gider: kırmızı
Color get kalanBorcRengi => koyuMod ? const Color(0xFFFB923C) : const Color(0xFFEA580C); // henüz ödenmemiş borç: turuncu
Color get odenenRengi => koyuMod ? const Color(0xFF60A5FA) : const Color(0xFF2563EB); // ödenen: mavi

// Bildirime dokunulduğunda bildirimin bilgisini ekrana taşır
class BildirimTiklamasi {
  final String payload;
  final String? eylem; // 'ertele' ise bildirimdeki Ertele düğmesine basılmıştır
  final int? bildirimNo;
  const BildirimTiklamasi(this.payload, {this.eylem, this.bildirimNo});
}

final ValueNotifier<BildirimTiklamasi?> bildirimTiklamasi = ValueNotifier<BildirimTiklamasi?>(null);

// ============================== UYGULAMA KİLİDİ ==============================

bool uygulamaKilidiAcik = false;
int kilitBeklemeDk = 0; // 0 = uygulamadan her çıkışta tekrar kilitlenir
bool ekranGizle = false; // son uygulamalarda önizlemeyi gizler, ekran görüntüsünü engeller
final ValueNotifier<bool> kilitli = ValueNotifier<bool>(false);
const MethodChannel _guvenlikKanali = MethodChannel('alfred/guvenlik');
final LocalAuthentication _yerelDogrulama = LocalAuthentication();
bool _kilitDogrulaniyor = false;
int _kilitMuafSayaci = 0;
DateTime? _kilitSonDogrulama;

// Telefonun kendi pencerelerini (galeri, dosya seçici, izin penceresi) açarken uygulama kısa süre arka plana geçer;
// bu sırada kilit devreye girmesin diye bu işlemler buradan çalıştırılır
Future<T> kilitsizCalistir<T>(Future<T> Function() islem) async {
  _kilitMuafSayaci++;
  try {
    return await islem();
  } finally {
    Future<void>.delayed(const Duration(seconds: 1), () {
      if (_kilitMuafSayaci > 0) _kilitMuafSayaci--;
    });
  }
}

// true: doğrulandı • false: doğrulanamadı • null: başka bir doğrulama zaten sürüyor
Future<bool?> kilitDogrula(String neden) async {
  if (_kilitDogrulaniyor) return null;
  _kilitDogrulaniyor = true;
  _kilitSonDogrulama = DateTime.now();
  try {
    final bool destek = await _yerelDogrulama.isDeviceSupported();
    if (!destek) return true; // telefonda ekran kilidi yoksa kullanıcı dışarıda kalmasın
    return await _yerelDogrulama.authenticate(
      localizedReason: neden,
      options: const AuthenticationOptions(stickyAuth: true, biometricOnly: false),
    );
  } on MissingPluginException {
    return true; // eklenti kurulu değilse (ör. tam derleme yapılmadıysa) kilitli kalma
  } on PlatformException catch (e) {
    debugPrint('Kilit doğrulaması: ${e.code} ${e.message}');
    if (e.code == 'NotAvailable' || e.code == 'NotEnrolled' || e.code == 'PasscodeNotSet') return true;
    return false;
  } catch (e) {
    debugPrint('Kilit doğrulaması hatası: $e');
    return false;
  } finally {
    _kilitDogrulaniyor = false;
    _kilitSonDogrulama = DateTime.now();
  }
}

Future<void> ekranGizleUygula(bool gizle) async {
  try {
    await _guvenlikKanali.invokeMethod<void>('ekranGizle', {'acik': gizle});
  } catch (e) {
    debugPrint('Ekran gizleme uygulanamadı: $e');
  }
}

class KilitEkrani extends StatefulWidget {
  const KilitEkrani({super.key});

  @override
  State<KilitEkrani> createState() => _KilitEkraniState();
}

class _KilitEkraniState extends State<KilitEkrani> with WidgetsBindingObserver {
  bool _gidildi = false;
  String? _mesaj;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _dene());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Kilit ekranı açıkken uygulamadan çıkıp dönülürse doğrulama kendiliğinden yeniden sorulur
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && !_kilitDogrulaniyor) {
      _gidildi = true;
    } else if (state == AppLifecycleState.resumed && _gidildi && !_kilitDogrulaniyor && _kilitMuafSayaci == 0) {
      _gidildi = false;
      _dene();
    }
  }

  Future<void> _dene() async {
    if (!mounted) return;
    final bool? sonuc = await kilitDogrula('Alfred\'i açmak için doğrulayın');
    if (sonuc == null) return;
    if (sonuc) {
      kilitli.value = false;
    } else if (mounted) {
      setState(() => _mesaj = 'Doğrulama yapılamadı. Tekrar deneyebilirsin.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: zemin,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(color: acikZemin, shape: BoxShape.circle),
                  child: Icon(Icons.lock_outline_rounded, size: 40, color: anaRenk),
                ),
                const SizedBox(height: 20),
                Text('Alfred kilitli', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: koyuYazi)),
                const SizedBox(height: 8),
                Text(_mesaj ?? 'Devam etmek için kimliğini doğrula', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: gri(600))),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: anaRenk,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _dene,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Kilidi aç', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Konuşmayı yazıya çevirir ve seçilen metin alanının sonuna ekler. Aynı anda tek alan dinlenir.
// Telefonun konuşma servisi kısa bir duraksamada oturumu kendiliğinden kapatır; konuşma sürdüğü
// sürece (en çok 5 dakika) oturum otomatik yeniden başlatılır, yazılan metin korunur.
class SesliYazi {
  final stt.SpeechToText _stt = stt.SpeechToText();
  bool dinliyor = false;
  bool _hazir = false;
  bool _kapandi = false;
  bool _istenen = false; // kullanıcı dinlemeyi açık tuttu mu
  bool _sonucGeldi = false; // bu oturumda en az bir kelime duyuldu mu
  bool _yenidenPlanli = false;
  String? hata;
  String? _yerel;
  TextEditingController? _hedef;
  VoidCallback? _yenile;
  DateTime _son = DateTime.now();
  int _oturum = 0; // her dinleme oturumunun numarası; durdurulan oturumdan gelen geç sonuçlar yok sayılır

  void _guncelle() {
    if (!_kapandi) _yenile?.call();
  }

  // Dinlemeyi hemen keser (örn. madde eklenince). Alana artık hiçbir şey yazılmaz.
  void durdur() {
    _oturum++;
    _istenen = false;
    dinliyor = false;
    _hedef = null;
    unawaited(_stt.cancel().catchError((_) {}));
  }

  // Oturum kendiliğinden bittiğinde: konuşma sürüyorsa yeniden başlat, sürmüyorsa kapat
  void _oturumBitti() {
    if (_kapandi || !_istenen) return;
    final TextEditingController? hedef = _hedef;
    if (hedef != null && _sonucGeldi && DateTime.now().isBefore(_son)) {
      if (_yenidenPlanli) return;
      _yenidenPlanli = true;
      Future<void>.delayed(const Duration(milliseconds: 300), () async {
        _yenidenPlanli = false;
        if (_kapandi || !_istenen || _hedef == null) return;
        if (_stt.isListening) return;
        await _baslat(_hedef!);
      });
      return;
    }
    _istenen = false;
    dinliyor = false;
    _hedef = null;
    _guncelle();
  }

  Future<void> degistir(TextEditingController hedef, VoidCallback yenile) async {
    _yenile = yenile;
    final TextEditingController? onceki = _hedef;
    if (dinliyor) {
      _oturum++;
      _istenen = false;
      try {
        await _stt.stop();
      } catch (_) {}
      dinliyor = false;
      _hedef = null;
      _guncelle();
      if (identical(onceki, hedef)) return;
    }
    hata = null;
    try {
      if (!_hazir) {
        _hazir = await kilitsizCalistir(() => _stt.initialize(
              onError: (e) => _oturumBitti(),
              onStatus: (d) {
                if (d == 'done' || d == 'notListening') _oturumBitti();
              },
            ));
      }
      if (!_hazir) {
        hata = 'Konuşma tanıma kullanılamıyor ya da mikrofon izni verilmedi.';
        _guncelle();
        return;
      }
      for (final l in await _stt.locales()) {
        if (l.localeId.toLowerCase().startsWith('tr')) {
          _yerel = l.localeId;
          break;
        }
      }
      _istenen = true;
      _hedef = hedef;
      _son = DateTime.now().add(const Duration(minutes: 5));
      await _baslat(hedef);
    } catch (e) {
      _istenen = false;
      dinliyor = false;
      hata = 'Konuşma başlatılamadı: $e';
      _guncelle();
    }
  }

  // Tek bir dinleme oturumu başlatır; alandaki mevcut yazının sonuna ekler
  Future<void> _baslat(TextEditingController hedef) async {
    try {
      dinliyor = true;
      _sonucGeldi = false;
      _guncelle();
      // Konuşmada duraksayınca telefon yeni bir parça başlatır ve önceki kelimeleri tekrar göndermez.
      // Bu yüzden biten parçayı yazıya "sabitleyip" yenisini onun sonuna ekliyoruz.
      String taban = hedef.text;
      String sonParca = '';
      // Parçaları tek boşlukla birleştirir (başta/sonda fazladan boşluk bırakmaz)
      // Cümle başındaysa (alan boşsa ya da önceki cümle . ! ? ile bitmişse) ilk harfi büyütür
      String buyut(String t) {
        if (t.isEmpty) return t;
        final String ilk = t.substring(0, 1);
        final String buyuk = ilk == 'i' ? 'İ' : (ilk == 'ı' ? 'I' : ilk.toUpperCase());
        return '$buyuk${t.substring(1)}';
      }

      String birlestir(String a, String b) {
        final String oncekiSon = a.trimRight();
        final bool cumleBasi = oncekiSon.isEmpty || oncekiSon.endsWith('.') || oncekiSon.endsWith('!') || oncekiSon.endsWith('?');
        final String ekle = cumleBasi ? buyut(b) : b;
        return (a.isEmpty || a.endsWith(' ') || a.endsWith('\n')) ? '$a$ekle' : '$a $ekle';
      }

      final int oturum = ++_oturum;
      await _stt.listen(
        onResult: (r) {
          if (_kapandi || oturum != _oturum) return;
          final String yeni = r.recognizedWords.trim();
          // Yeni parça başlarken telefon bazen boş sonuç gönderir; bu, yazılanı silmemeli
          if (yeni.isEmpty) return;
          _sonucGeldi = true;
          if (sonParca.length >= 3 && yeni.length >= 3 && sonParca.toLowerCase().substring(0, 3) != yeni.toLowerCase().substring(0, 3)) {
            taban = birlestir(taban, sonParca);
          } else if (sonParca.isNotEmpty && yeni.length < sonParca.length && !sonParca.toLowerCase().startsWith(yeni.toLowerCase())) {
            taban = birlestir(taban, sonParca);
          }
          sonParca = yeni;
          hedef.text = birlestir(taban, yeni);
          hedef.selection = TextSelection.collapsed(offset: hedef.text.length);
          if (r.finalResult) {
            taban = birlestir(taban, yeni);
            sonParca = '';
          }
          _guncelle();
        },
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenMode: stt.ListenMode.dictation,
          localeId: _yerel,
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      _istenen = false;
      dinliyor = false;
      hata = 'Konuşma başlatılamadı: $e';
      _guncelle();
    }
  }

  Widget dugme(TextEditingController hedef, VoidCallback yenile) {
    final bool bu = dinliyor && identical(_hedef, hedef);
    return IconButton(
      tooltip: bu ? 'Dinlemeyi durdur' : 'Sesle yaz',
      icon: Icon(bu ? Icons.mic : Icons.mic_none, color: bu ? Colors.red : anaRenk),
      onPressed: () => degistir(hedef, yenile),
    );
  }

  Future<void> kapat() async {
    _kapandi = true;
    _istenen = false;
    try {
      await _stt.cancel();
    } catch (_) {}
  }
}

// ============================== BİLDİRİM ERTELEME (arka planda çalışır) ==============================

bool _anaIzolatta = false; // true: uygulamanın ana ortamı • false: bildirim düğmesinin açtığı arka plan ortamı

String ertelemeEtiketi(int dk) => (dk >= 60 && dk % 60 == 0) ? '${dk ~/ 60} saat' : '$dk dk';

List<Map<String, dynamic>> _ertelenenleriOku(SharedPreferences prefs) {
  try {
    final dynamic d = jsonDecode(prefs.getString('ertelenenler') ?? '[]');
    if (d is List) return d.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
  } catch (_) {}
  return [];
}

@pragma('vm:entry-point')
Future<void> bildirimArkaPlanYaniti(NotificationResponse yanit) async {
  if (yanit.actionId == 'ertele') {
    await bildirimiHemenErtele(yanit.id, yanit.payload);
  } else if (yanit.actionId == 'yapildi') {
    await bildirimdenYapildiKaydet(yanit.id, yanit.payload);
  }
}

// Ana ortam yapıldı kaydını işlesin diye sinyal (bildirim düğmesi uygulama açıkken basıldıysa)
final ValueNotifier<int> bildirimYapildiSinyali = ValueNotifier<int>(0);

// Bildirimdeki "Yapıldı" düğmesi: uygulamayı açmadan çalışır. Veriyi burada değiştirmeyiz (ana ortamdaki kopyayı
// ezmemek için); kaydı kuyruğa yazarız, uygulama açılınca/öne gelince işlenir. Bildirim ve ertelenmişleri hemen kalkar.
Future<void> bildirimdenYapildiKaydet(int? bildirimNo, String? payload) async {
  try {
    if (!_anaIzolatta) {
      await flutterLocalNotificationsPlugin.initialize(const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    }
    final List<String> p = (payload ?? '').split('|');
    if (p.length < 4 || p[0] != 'etkinlik') return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    dynamic ham;
    try {
      ham = jsonDecode(prefs.getString('yapildi_bekleyen') ?? '[]');
    } catch (_) {
      ham = [];
    }
    final List<Map<String, dynamic>> kuyruk = ham is List ? ham.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList() : [];
    kuyruk.add({'e': p[1], 'a': '${p[2]}|${p[3]}', 'pr': p.length > 4 ? p[4] : ''});
    await prefs.setString('yapildi_bekleyen', jsonEncode(kuyruk));
    if (bildirimNo != null) await flutterLocalNotificationsPlugin.cancel(bildirimNo);
    await ertelenenleriIptalEt(etkinlikId: p[1], anahtar: '${p[2]}|${p[3]}');
    if (_anaIzolatta) bildirimYapildiSinyali.value++;
  } catch (e) {
    debugPrint('Yapıldı kaydedilemedi: $e');
  }
}

// Bildirimi uygulamayı açmadan erteler: aynı başlık ve metinle, ayarlardaki süre sonrasına yeni bir alarm kurar.
// Dönen değer: yeni hatırlatma zamanı (başarısızsa null).
Future<DateTime?> bildirimiHemenErtele(int? bildirimNo, String? payload) async {
  try {
    if (!_anaIzolatta) {
      await flutterLocalNotificationsPlugin.initialize(const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final int dk = prefs.getInt('erteleme_dk') ?? 10;
    final bool guvenilir = prefs.getBool('guvenilir_mod') ?? true;
    final AndroidFlutterLocalNotificationsPlugin? android = flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return null;

    String baslik = 'Alfred';
    String metin = 'Hatırlatma';
    String? kanal;
    try {
      for (final a in await android.getActiveNotifications()) {
        if (a.id == bildirimNo) {
          baslik = a.title ?? baslik;
          metin = a.body ?? metin;
          kanal = a.channelId;
          break;
        }
      }
    } catch (e) {
      debugPrint('Aktif bildirim okunamadı: $e');
    }
    if (kanal == null) {
      try {
        final kanallar = await android.getNotificationChannels() ?? [];
        if (kanallar.isNotEmpty) kanal = kanallar.first.id;
      } catch (_) {}
    }
    if (kanal == null) return null;
    // "10 dk sonra" gibi göreli ifade ertelemeden sonra yanlış olur; yerine "Ertelendi" yazılır
    metin = metin.replaceFirst(RegExp(r' • (\d+ (dk|saat|gün|hafta) sonra|Şimdi|Bugün|Yarın|Yaklaşıyor)(?= • |$)'), ' • Ertelendi');

    AndroidScheduleMode mod = AndroidScheduleMode.inexactAllowWhileIdle;
    if (guvenilir) {
      mod = AndroidScheduleMode.alarmClock;
    } else {
      try {
        final dynamic tam = await (android as dynamic).canScheduleExactNotifications();
        if (tam == true) mod = AndroidScheduleMode.exactAllowWhileIdle;
      } catch (_) {}
    }

    final DateTime zaman = DateTime.now().add(Duration(minutes: dk));
    final int yeniNo = 910000 + (DateTime.now().millisecondsSinceEpoch ~/ 1000) % 80000;
    final AndroidNotificationDetails detay = AndroidNotificationDetails(
      kanal,
      'Hatırlatıcılar',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
      visibility: NotificationVisibility.public,
      styleInformation: BigTextStyleInformation(metin),
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction('ertele', 'Ertele (${ertelemeEtiketi(dk)})', showsUserInterface: false, cancelNotification: false),
        if ((payload ?? '').startsWith('etkinlik|')) const AndroidNotificationAction('yapildi', 'Yapıldı olarak işaretle', showsUserInterface: false, cancelNotification: true),
      ],
    );
    await (android as dynamic).zonedSchedule(yeniNo, baslik, metin, tz.TZDateTime.from(zaman, tz.UTC), detay, scheduleMode: mod, payload: payload);
    if (bildirimNo != null) await flutterLocalNotificationsPlugin.cancel(bildirimNo);

    // İleride "yapıldı" işaretlenirse bu ertelenmiş bildirim de iptal edilebilsin diye kaydı tut
    final List<Map<String, dynamic>> liste = _ertelenenleriOku(prefs);
    final int simdiMs = DateTime.now().millisecondsSinceEpoch;
    liste.removeWhere((k) => k['id'] == bildirimNo || (k['t'] is int && (k['t'] as int) < simdiMs - 86400000));
    liste.add({'id': yeniNo, 'p': payload ?? '', 't': zaman.millisecondsSinceEpoch});
    await prefs.setString('ertelenenler', jsonEncode(liste));
    return zaman;
  } catch (e) {
    debugPrint('Bildirim ertelenemedi: $e');
    return null;
  }
}

// Bir etkinlik "yapıldı" işaretlenince ya da silinince, ertelenmiş bildirimleri de iptal eder.
// anahtar verilirse yalnızca o günün/saatin bildirimi, verilmezse etkinliğin tümü iptal edilir.
Future<void> ertelenenleriIptalEt({required String etkinlikId, String? anahtar}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final List<Map<String, dynamic>> liste = _ertelenenleriOku(prefs);
    if (liste.isEmpty) return;
    final List<Map<String, dynamic>> kalan = [];
    for (final k in liste) {
      final List<String> p = ((k['p'] as String?) ?? '').split('|');
      final bool eslesir = p.length >= 4 && p[0] == 'etkinlik' && p[1] == etkinlikId && (anahtar == null || '${p[2]}|${p[3]}' == anahtar);
      if (eslesir && k['id'] is int) {
        await flutterLocalNotificationsPlugin.cancel(k['id'] as int);
      } else {
        kalan.add(k);
      }
    }
    await prefs.setString('ertelenenler', jsonEncode(kalan));
  } catch (e) {
    debugPrint('Ertelenmiş bildirim iptal edilemedi: $e');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _anaIzolatta = true;
  await initializeDateFormatting('tr_TR', null);
  try {
    final prefs = await SharedPreferences.getInstance();
    final String? kayitli = prefs.getString('tema_modu');
    if (kayitli == 'acik' || kayitli == 'koyu' || kayitli == 'sistem') temaModu.value = kayitli!;
    uygulamaKilidiAcik = prefs.getBool('uygulama_kilidi') ?? false;
    kilitBeklemeDk = prefs.getInt('kilit_bekleme_dk') ?? 0;
    ekranGizle = prefs.getBool('ekran_gizle') ?? false;
  } catch (e) {
    debugPrint('Tema veya kilit tercihi okunamadı: $e');
  }
  kilitli.value = uygulamaKilidiAcik; // kilit açıksa uygulama kilitli başlar
  if (ekranGizle) await ekranGizleUygula(true);

  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: (NotificationResponse yanit) {
      final String? yuk = yanit.payload;
      if (yanit.actionId == 'ertele') {
        unawaited(bildirimiHemenErtele(yanit.id, yuk));
      } else if (yanit.actionId == 'yapildi') {
        unawaited(bildirimdenYapildiKaydet(yanit.id, yuk));
      } else if (yuk != null && yuk.isNotEmpty) {
        bildirimTiklamasi.value = BildirimTiklamasi(yuk);
      }
    },
    onDidReceiveBackgroundNotificationResponse: bildirimArkaPlanYaniti,
  );

  runApp(const KisiselAsistanApp());
}

final GlobalKey<NavigatorState> _gezginAnahtari = GlobalKey<NavigatorState>();

class KisiselAsistanApp extends StatefulWidget {
  const KisiselAsistanApp({super.key});

  @override
  State<KisiselAsistanApp> createState() => _KisiselAsistanAppState();
}

class _KisiselAsistanAppState extends State<KisiselAsistanApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    temaModu.addListener(_temaDegisti);
  }

  @override
  void dispose() {
    temaModu.removeListener(_temaDegisti);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _temaDegisti() {
    if (mounted) setState(() {});
  }

  // Arka plana geçildiği an kaydedilir; geri dönüşte bekleme süresi dolduysa uygulama kilitlenir
  DateTime? _arkaPlanZamani;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!uygulamaKilidiAcik) {
      _arkaPlanZamani = null;
      return;
    }
    if (state == AppLifecycleState.paused) {
      if (_kilitDogrulaniyor || kilitli.value) return;
      _arkaPlanZamani ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final DateTime? z = _arkaPlanZamani;
      _arkaPlanZamani = null;
      if (z == null || _kilitDogrulaniyor || _kilitMuafSayaci > 0) return;
      final DateTime? son = _kilitSonDogrulama;
      if (son != null && DateTime.now().difference(son).inSeconds < 2) return;
      if (DateTime.now().difference(z).inSeconds >= kilitBeklemeDk * 60) {
        FocusManager.instance.primaryFocus?.unfocus();
        kilitli.value = true;
      }
    }
  }

  // Telefonun açık/koyu ayarı değişince ("Sistem" modunda) uygulama da değişir
  @override
  void didChangePlatformBrightness() {
    if (mounted && temaModu.value == 'sistem') setState(() {});
  }

  // Renkler genel tanımlardan okunduğu için tema değişince açık olan tüm sayfalar yeniden çizilir
  void _hepsiniYenile() {
    final BuildContext? c = _gezginAnahtari.currentContext;
    if (c == null) return;
    void yenile(Element e) {
      e.markNeedsBuild();
      e.visitChildren(yenile);
    }

    (c as Element).visitChildren(yenile);
  }

  ThemeData _temaOlustur(bool koyu) {
    final ColorScheme sema = ColorScheme.fromSeed(
      seedColor: const Color(0xFF4F46E5),
      brightness: koyu ? Brightness.dark : Brightness.light,
      surface: zemin,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: koyu ? Brightness.dark : Brightness.light,
      fontFamily: 'Roboto',
      colorScheme: sema,
      scaffoldBackgroundColor: zemin,
      canvasColor: zemin,
      dialogTheme: koyu ? DialogThemeData(backgroundColor: yuzey, surfaceTintColor: Colors.transparent) : null,
      bottomSheetTheme: koyu ? BottomSheetThemeData(backgroundColor: yuzey, surfaceTintColor: Colors.transparent, modalBackgroundColor: yuzey) : null,
      popupMenuTheme: koyu ? PopupMenuThemeData(color: yuzey, surfaceTintColor: Colors.transparent) : null,
      dividerTheme: koyu ? DividerThemeData(color: gri(200)) : null,
      cardTheme: koyu ? CardThemeData(color: yuzey, surfaceTintColor: Colors.transparent) : null,
      inputDecorationTheme: koyu ? InputDecorationTheme(hintStyle: TextStyle(color: gri(500))) : null,
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: yuzey,
        surfaceTintColor: Colors.transparent,
        indicatorColor: acikZemin,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: anaRenk);
          }
          return const TextStyle(fontSize: 12, fontWeight: FontWeight.normal, color: Colors.grey);
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String mod = temaModu.value;
    final bool sistemKoyu = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    final bool koyu = mod == 'koyu' || (mod == 'sistem' && sistemKoyu);
    final bool degisti = koyu != koyuMod;
    koyuMod = koyu;
    final ThemeData tema = _temaOlustur(koyu);
    if (degisti) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _hepsiniYenile();
      });
    }
    return MaterialApp(
      title: 'Alfred',
      navigatorKey: _gezginAnahtari,
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('tr', 'TR')],
      theme: tema,
      themeAnimationDuration: Duration.zero,
      builder: (context, cocuk) {
        return ValueListenableBuilder<bool>(
          valueListenable: kilitli,
          builder: (c, kilitDurumu, _) => Stack(
            children: [
              ?cocuk,
              if (kilitDurumu) const Positioned.fill(child: KilitEkrani()),
            ],
          ),
        );
      },
      home: const AnaEkran(),
    );
  }
}

// ============================== HIZLI EKLE (DOĞAL DİL) ==============================

// "yarın 15:00 diş randevusu" gibi bir cümleden etkinlik taslağı çıkarır (kural tabanlı, Türkçe)
class HizliCozum {
  String baslik = '';
  DateTime? tarih;
  int? dakika; // günün kaçıncı dakikası (saat verilmediyse null)
  String tekrar = 'yok';
  List<int> haftaGunleri = [];
  Hatirlatma? hatirlatma;
  String turIpucu = 'gorev';
  bool anlasildi = false; // tarih, saat veya tekrardan en az biri bulundu
}

String _hizliNormal(String s) => s.replaceAll('İ', 'i').replaceAll('I', 'ı').toLowerCase();

const Map<String, int> _hizliGunler = {
  'pazartesi': 1,
  'salı': 2,
  'sali': 2,
  'çarşamba': 3,
  'carsamba': 3,
  'perşembe': 4,
  'persembe': 4,
  'cumartesi': 6,
  'cuma': 5,
  'pazar': 7,
};

const List<String> _hizliAylar = ['ocak', 'şubat', 'mart', 'nisan', 'mayıs', 'haziran', 'temmuz', 'ağustos', 'eylül', 'ekim', 'kasım', 'aralık'];

int? _hizliGunNo(String t) {
  // En uzun ad önce denenir; ek en fazla 3 harf (cumaya, salıya, pazartesiye)
  final List<String> adlar = _hizliGunler.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final String ad in adlar) {
    if (t.startsWith(ad) && t.length <= ad.length + 3) return _hizliGunler[ad];
  }
  return null;
}

int? _hizliAyNo(String t) {
  for (int i = 0; i < _hizliAylar.length; i++) {
    final String ad = _hizliAylar[i];
    if (t.startsWith(ad) && t.length <= ad.length + 3) return i + 1;
  }
  return null;
}

int? _hizliSayi(String t) => RegExp(r'^\d{1,3}$').hasMatch(t) ? int.parse(t) : null;

// "15", "15:30", "3'te", "15.30" -> [saat, dakika]; olmazsa null
List<int>? _hizliSaatCoz(String t) {
  final RegExp r = RegExp(r"^(\d{1,2})(?:[:.](\d{2}))?(?:['’]?(?:te|ta|de|da|e|a|ye|ya))?$");
  final Match? m = r.firstMatch(t);
  if (m == null) return null;
  final int h = int.parse(m.group(1)!);
  final int dk = m.group(2) == null ? 0 : int.parse(m.group(2)!);
  if (h > 23 || dk > 59) return null;
  return [h, dk];
}

HizliCozum hizliCoz(String girdi, DateTime simdi) {
  final HizliCozum sonuc = HizliCozum();
  final List<String> asil = girdi.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
  final List<String> t = asil.map(_hizliNormal).toList();
  final List<bool> yenen = List<bool>.filled(asil.length, false);
  final DateTime bugun = DateTime(simdi.year, simdi.month, simdi.day);

  DateTime? tarih;
  int? saat;
  int? dakika;
  String? gunParcasi; // sabah | oglen | aksam
  bool haftayaMi = false;
  int? tekrarGunu;
  bool belirsizSaat = false; // 'saat 3'te' gibi: 1-6 arası ise öğleden sonra sayılır

  void yut(int i, [int adet = 1]) {
    for (int k = 0; k < adet && i + k < yenen.length; k++) {
      yenen[i + k] = true;
    }
  }

  for (int i = 0; i < t.length; i++) {
    if (yenen[i]) continue;
    final String w = t[i];
    final String? sonraki = i + 1 < t.length ? t[i + 1] : null;
    final String? sonraki2 = i + 2 < t.length ? t[i + 2] : null;

    // Hatırlatma: "10 dk önce hatırlat", "1 saat önce"
    final int? n0 = _hizliSayi(w);
    if (n0 != null && sonraki != null && sonraki2 != null && (sonraki2 == 'önce' || sonraki2 == 'once')) {
      String? birim;
      if (sonraki == 'dk' || sonraki.startsWith('dakika')) birim = 'dakika';
      if (sonraki == 'sa' || sonraki.startsWith('saat')) birim = 'saat';
      if (sonraki.startsWith('gün') || sonraki.startsWith('gun')) birim = 'gun';
      if (sonraki.startsWith('hafta')) birim = 'hafta';
      if (birim != null) {
        sonuc.hatirlatma = Hatirlatma(n0, birim);
        yut(i, 3);
        if (i + 3 < t.length && t[i + 3].startsWith('hatırlat')) yut(i + 3);
        continue;
      }
    }

    // Süre sonra: "2 saat sonra", "30 dk sonra", "3 gün sonra", "2 hafta sonra"
    if (n0 != null && sonraki != null && sonraki2 == 'sonra') {
      if (sonraki == 'dk' || sonraki.startsWith('dakika')) {
        final DateTime z = simdi.add(Duration(minutes: n0));
        tarih = DateTime(z.year, z.month, z.day);
        saat = z.hour;
        dakika = z.minute;
        yut(i, 3);
        continue;
      }
      if (sonraki == 'sa' || sonraki.startsWith('saat')) {
        final DateTime z = simdi.add(Duration(hours: n0));
        tarih = DateTime(z.year, z.month, z.day);
        saat = z.hour;
        dakika = z.minute;
        yut(i, 3);
        continue;
      }
      if (sonraki.startsWith('gün') || sonraki.startsWith('gun')) {
        tarih = DateTime(bugun.year, bugun.month, bugun.day + n0);
        yut(i, 3);
        continue;
      }
      if (sonraki.startsWith('hafta')) {
        tarih = DateTime(bugun.year, bugun.month, bugun.day + 7 * n0);
        yut(i, 3);
        continue;
      }
      if (sonraki == 'ay' || sonraki.startsWith('ay')) {
        tarih = DateTime(bugun.year, bugun.month + n0, bugun.day);
        yut(i, 3);
        continue;
      }
    }

    // Tekrar: "her gün", "her hafta", "her pazartesi", "her ay", "her yıl"
    if (w == 'her' && sonraki != null) {
      final int? hg = _hizliGunNo(sonraki);
      if (sonraki.startsWith('gün') || sonraki.startsWith('gun')) {
        sonuc.tekrar = 'gun';
        yut(i, 2);
        continue;
      } else if (hg != null) {
        sonuc.tekrar = 'hafta';
        tekrarGunu = hg;
        yut(i, 2);
        continue;
      } else if (sonraki.startsWith('hafta')) {
        sonuc.tekrar = 'hafta';
        yut(i, 2);
        continue;
      } else if (sonraki == 'ay') {
        sonuc.tekrar = 'ay';
        yut(i, 2);
        continue;
      } else if (sonraki.startsWith('yıl') || sonraki.startsWith('sene')) {
        sonuc.tekrar = 'yil';
        yut(i, 2);
        continue;
      }
    }
    if (w == 'hergün' || w == 'hergun') {
      sonuc.tekrar = 'gun';
      yut(i);
      continue;
    }

    // Göreli günler
    if (w.startsWith('bugün') || w.startsWith('bugun')) {
      tarih = bugun;
      yut(i);
      continue;
    }
    if (w.startsWith('yarın') || w.startsWith('yarin')) {
      tarih = DateTime(bugun.year, bugun.month, bugun.day + 1);
      yut(i);
      continue;
    }
    if ((w.startsWith('öbür') || w.startsWith('obur')) && sonraki != null && sonraki.startsWith('gün')) {
      tarih = DateTime(bugun.year, bugun.month, bugun.day + 2);
      yut(i, 2);
      continue;
    }
    if (w.startsWith('ertesi') && sonraki != null && sonraki.startsWith('gün')) {
      tarih = DateTime(bugun.year, bugun.month, bugun.day + 2);
      yut(i, 2);
      continue;
    }
    if (w == 'haftaya') {
      haftayaMi = true;
      yut(i);
      continue;
    }

    // Hafta günü: "cuma", "haftaya salı"
    final int? gno = _hizliGunNo(w);
    if (gno != null && tarih == null) {
      final int fark = (gno - bugun.weekday + 7) % 7;
      tarih = DateTime(bugun.year, bugun.month, bugun.day + (fark == 0 ? 7 : fark));
      yut(i);
      continue;
    }

    // "15 ekim", "15 ekim 2027"
    if (n0 != null && sonraki != null && n0 >= 1 && n0 <= 31) {
      final int? ay = _hizliAyNo(sonraki);
      if (ay != null) {
        int yil = bugun.year;
        int adet = 2;
        if (sonraki2 != null && RegExp(r'^\d{4}$').hasMatch(sonraki2)) {
          yil = int.parse(sonraki2);
          adet = 3;
        } else if (DateTime(yil, ay, n0).isBefore(bugun)) {
          yil++;
        }
        tarih = DateTime(yil, ay, n0);
        yut(i, adet);
        continue;
      }
    }

    // "15.10", "15/10", "15.10.2027"
    final Match? dm = RegExp(r'^(\d{1,2})[./](\d{1,2})(?:[./](\d{2,4}))?$').firstMatch(w);
    if (dm != null && !w.contains(':')) {
      final int g = int.parse(dm.group(1)!);
      final int a = int.parse(dm.group(2)!);
      if (g >= 1 && g <= 31 && a >= 1 && a <= 12) {
        int yil = bugun.year;
        if (dm.group(3) != null) {
          yil = int.parse(dm.group(3)!);
          if (yil < 100) yil += 2000;
        } else if (DateTime(yil, a, g).isBefore(bugun)) {
          yil++;
        }
        tarih = DateTime(yil, a, g);
        yut(i);
        continue;
      }
    }

    // Saat: "15:00", "15.30" (gün biçimine uymayan), "saat 3'te", "saat 15"
    if (w == 'saat' && sonraki != null) {
      final List<int>? s = _hizliSaatCoz(sonraki);
      if (s != null) {
        saat = s[0];
        dakika = s[1];
        belirsizSaat = !sonraki.contains(':');
        yut(i, 2);
        continue;
      }
    }
    if (w.contains(':') || RegExp(r'^\d{1,2}\.\d{2}$').hasMatch(w) || RegExp(r"^\d{1,2}['’](te|ta|de|da)$").hasMatch(w)) {
      final List<int>? s = _hizliSaatCoz(w);
      if (s != null) {
        saat = s[0];
        dakika = s[1];
        belirsizSaat = RegExp(r"^\d{1,2}['’]").hasMatch(w);
        yut(i);
        continue;
      }
    }

    // Günün bölümü: "sabah", "öğleden sonra", "akşam" (sonrasında sayı gelirse saat olur)
    if (w == 'akşam' || w == 'aksam' || w == 'sabah' || w == 'öğle' || w == 'öğlen' || w == 'ogle' || w == 'öğleden') {
      gunParcasi = (w.startsWith('ak')) ? 'aksam' : (w == 'sabah' ? 'sabah' : 'oglen');
      int kac = 1;
      if (w == 'öğleden' && sonraki == 'sonra') {
        gunParcasi = 'ogledensonra';
        kac = 2;
      }
      yut(i, kac);
      final int ileri = i + kac;
      if (ileri < t.length) {
        final List<int>? s = _hizliSaatCoz(t[ileri]);
        if (s != null && saat == null) {
          saat = s[0];
          dakika = s[1];
          yut(ileri);
        }
      }
      continue;
    }
  }

  // Gün parçası saati düzeltir
  if (saat != null && saat < 12 && (gunParcasi == 'aksam' || gunParcasi == 'ogledensonra')) saat += 12;
  if (saat != null && gunParcasi == null && belirsizSaat && saat >= 1 && saat <= 6) saat += 12;
  if (saat == null && gunParcasi != null) {
    switch (gunParcasi) {
      case 'sabah':
        saat = 8;
        break;
      case 'oglen':
        saat = 12;
        break;
      case 'ogledensonra':
        saat = 14;
        break;
      default:
        saat = 19;
    }
    dakika = 0;
  }

  // "haftaya" : bir sonraki haftanın aynı günü (gün adı varsa o gün)
  if (haftayaMi) {
    if (tarih == null) {
      tarih = DateTime(bugun.year, bugun.month, bugun.day + 7);
    } else {
      final DateTime pazartesi = DateTime(bugun.year, bugun.month, bugun.day - (bugun.weekday - 1) + 7);
      tarih = DateTime(pazartesi.year, pazartesi.month, pazartesi.day + (tarih.weekday - 1));
    }
  }

  // Her <gün>: ilk tekrar o günde başlar
  if (tekrarGunu != null) {
    sonuc.haftaGunleri = [tekrarGunu];
    if (tarih == null) {
      final int fark = (tekrarGunu - bugun.weekday + 7) % 7;
      tarih = DateTime(bugun.year, bugun.month, bugun.day + fark);
    }
  }

  // Tarih verilmedi: saat bugün hâlâ gelecekteyse bugün, değilse yarın
  if (tarih == null && saat != null) {
    final DateTime bugunSaat = DateTime(bugun.year, bugun.month, bugun.day, saat, dakika ?? 0);
    tarih = bugunSaat.isAfter(simdi) ? bugun : DateTime(bugun.year, bugun.month, bugun.day + 1);
  }
  tarih ??= bugun;

  sonuc.tarih = tarih;
  sonuc.dakika = saat == null ? null : saat * 60 + (dakika ?? 0);
  sonuc.anlasildi = yenen.any((x) => x);

  // Başlık: yenmeyen kelimeler
  final List<String> kalan = [];
  for (int i = 0; i < asil.length; i++) {
    if (!yenen[i]) kalan.add(asil[i]);
  }
  while (kalan.isNotEmpty && const ['ekle', 'hatırlat', 'hatırlatır', 'bana', 'lütfen'].contains(_hizliNormal(kalan.last))) {
    kalan.removeLast();
  }
  String b = kalan.join(' ').trim();
  if (b.isNotEmpty) b = b[0].toUpperCase() + b.substring(1);
  sonuc.baslik = b;

  final String kucuk = _hizliNormal(b);
  if (kucuk.contains('doğum günü') || kucuk.contains('dogum gunu')) {
    sonuc.turIpucu = 'dogum';
  } else if (kucuk.contains('ilaç') || kucuk.contains('ilac')) {
    sonuc.turIpucu = 'ilac';
  } else if (kucuk.contains('randevu') || kucuk.contains('doktor') || kucuk.contains('toplantı') || kucuk.contains('toplanti')) {
    sonuc.turIpucu = 'randevu';
  }
  return sonuc;
}

// ============================== MODELLER ==============================

class KrediKarti {
  String id;
  String kartAdi;
  double limit;
  String sonOdemeGunu;

  KrediKarti({
    required this.id,
    required this.kartAdi,
    required this.limit,
    this.sonOdemeGunu = '25',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'kartAdi': kartAdi,
        'limit': limit,
        'sonOdemeGunu': sonOdemeGunu,
      };

  factory KrediKarti.fromJson(Map<String, dynamic> j) => KrediKarti(
        id: j['id'],
        kartAdi: j['kartAdi'],
        limit: (j['limit'] as num).toDouble(),
        sonOdemeGunu: j['sonOdemeGunu'] ?? '25',
      );
}

class KrediBorcu {
  String id;
  String krediAdi;
  String krediTuru;
  double aylikTutar;
  int toplamTaksit;
  DateTime baslangicTarihi;
  String sonOdemeGunu;
  Map<String, bool> odenenAylar;

  KrediBorcu({
    required this.id,
    required this.krediAdi,
    this.krediTuru = 'İhtiyaç',
    required this.aylikTutar,
    required this.toplamTaksit,
    required this.baslangicTarihi,
    this.sonOdemeGunu = '25',
    Map<String, bool>? odenenAylar,
  }) : odenenAylar = odenenAylar ?? {};

  Map<String, dynamic> toJson() => {
        'id': id,
        'krediAdi': krediAdi,
        'krediTuru': krediTuru,
        'aylikTutar': aylikTutar,
        'toplamTaksit': toplamTaksit,
        'baslangicTarihi': baslangicTarihi.toIso8601String(),
        'sonOdemeGunu': sonOdemeGunu,
        'odenenAylar': odenenAylar,
      };

  factory KrediBorcu.fromJson(Map<String, dynamic> j) => KrediBorcu(
        id: j['id'],
        krediAdi: j['krediAdi'],
        krediTuru: j['krediTuru'] ?? 'İhtiyaç',
        aylikTutar: (j['aylikTutar'] as num).toDouble(),
        toplamTaksit: j['toplamTaksit'],
        baslangicTarihi: DateTime.parse(j['baslangicTarihi']),
        sonOdemeGunu: j['sonOdemeGunu'] ?? '25',
        odenenAylar: Map<String, bool>.from(j['odenenAylar'] ?? {}),
      );
}

// Bir giderin bir kısmının (veya tamamının) ödenmesi
class KismiOdeme {
  String ay; // ödemenin yapıldığı ay (yyyy-MM)
  double tutar;
  DateTime tarih;

  KismiOdeme({required this.ay, required this.tutar, required this.tarih});

  Map<String, dynamic> toJson() => {
        'ay': ay,
        'tutar': tutar,
        'tarih': tarih.toIso8601String(),
      };

  factory KismiOdeme.fromJson(Map<String, dynamic> j) => KismiOdeme(
        ay: j['ay'],
        tutar: (j['tutar'] as num).toDouble(),
        tarih: DateTime.tryParse(j['tarih'] ?? '') ?? DateTime.now(),
      );
}

class FinansKalemi {
  String id;
  String baslik;
  double tutar;
  String kategori;
  bool isGelir;
  bool odendiMi; // sadece kredi kartı ekstresi için kullanılır
  DateTime tarih; // giderlerde son ödeme tarihi
  String? kartId;
  String ayYilAnahtari;
  String? sabitId; // her ay tekrarlanan bir sabit ödemeden geldiyse
  List<KismiOdeme> odemeler; // normal giderlerin ödemeleri

  FinansKalemi({
    required this.id,
    required this.baslik,
    required this.tutar,
    required this.kategori,
    required this.isGelir,
    this.odendiMi = false,
    required this.tarih,
    this.kartId,
    required this.ayYilAnahtari,
    this.sabitId,
    List<KismiOdeme>? odemeler,
  }) : odemeler = odemeler ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'baslik': baslik,
        'tutar': tutar,
        'kategori': kategori,
        'isGelir': isGelir,
        'odendiMi': odendiMi,
        'tarih': tarih.toIso8601String(),
        'kartId': kartId,
        'ayYilAnahtari': ayYilAnahtari,
        'sabitId': sabitId,
        'odemeler': odemeler.map((o) => o.toJson()).toList(),
      };

  factory FinansKalemi.fromJson(Map<String, dynamic> j) => FinansKalemi(
        id: j['id'],
        baslik: j['baslik'],
        tutar: (j['tutar'] as num).toDouble(),
        kategori: j['kategori'],
        isGelir: j['isGelir'],
        odendiMi: j['odendiMi'] ?? false,
        tarih: DateTime.parse(j['tarih']),
        kartId: j['kartId'],
        ayYilAnahtari: j['ayYilAnahtari'],
        sabitId: j['sabitId'],
        odemeler: (j['odemeler'] as List? ?? []).map((e) => KismiOdeme.fromJson(Map<String, dynamic>.from(e))).toList(),
      );
}

// Her ay otomatik eklenen sabit ödeme veya gelir (kira, telefon faturası, maaş...)
class SabitOdeme {
  String id;
  String baslik;
  String kategori;
  bool isGelir;
  String gun; // ayın kaçında
  String baslangicAyYil;
  String? bitisAyYil; // null ise devam ediyor
  Map<String, double> tutarlar; // hangi aydan itibaren hangi tutar
  List<String> atlananAylar; // elle silinen aylar

  SabitOdeme({
    required this.id,
    required this.baslik,
    required this.kategori,
    required this.isGelir,
    required this.gun,
    required this.baslangicAyYil,
    this.bitisAyYil,
    required this.tutarlar,
    List<String>? atlananAylar,
  }) : atlananAylar = atlananAylar ?? [];

  // Verilen ayda geçerli olan tutar
  double tutarAy(String ay) {
    final anahtarlar = tutarlar.keys.toList()..sort();
    if (anahtarlar.isEmpty) return 0;
    double sonuc = tutarlar[anahtarlar.first] ?? 0;
    for (final k in anahtarlar) {
      if (k.compareTo(ay) <= 0) sonuc = tutarlar[k] ?? sonuc;
    }
    return sonuc;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'baslik': baslik,
        'kategori': kategori,
        'isGelir': isGelir,
        'gun': gun,
        'baslangicAyYil': baslangicAyYil,
        'bitisAyYil': bitisAyYil,
        'tutarlar': tutarlar,
        'atlananAylar': atlananAylar,
      };

  factory SabitOdeme.fromJson(Map<String, dynamic> j) => SabitOdeme(
        id: j['id'],
        baslik: j['baslik'],
        kategori: j['kategori'],
        isGelir: j['isGelir'] ?? false,
        gun: j['gun'] ?? '1',
        baslangicAyYil: j['baslangicAyYil'],
        bitisAyYil: j['bitisAyYil'],
        tutarlar: (j['tutarlar'] as Map? ?? {}).map((k, v) => MapEntry(k as String, (v as num).toDouble())),
        atlananAylar: List<String>.from(j['atlananAylar'] ?? []),
      );
}

class KartTaksiti {
  String id;
  String kartId;
  String baslik;
  double aylikTutar;
  int toplamTaksit;
  String baslangicAyYil;
  Map<String, bool> odenenAylar;

  KartTaksiti({
    required this.id,
    required this.kartId,
    required this.baslik,
    required this.aylikTutar,
    required this.toplamTaksit,
    required this.baslangicAyYil,
    Map<String, bool>? odenenAylar,
  }) : odenenAylar = odenenAylar ?? {};

  Map<String, dynamic> toJson() => {
        'id': id,
        'kartId': kartId,
        'baslik': baslik,
        'aylikTutar': aylikTutar,
        'toplamTaksit': toplamTaksit,
        'baslangicAyYil': baslangicAyYil,
        'odenenAylar': odenenAylar,
      };

  factory KartTaksiti.fromJson(Map<String, dynamic> j) => KartTaksiti(
        id: j['id'],
        kartId: j['kartId'],
        baslik: j['baslik'],
        aylikTutar: (j['aylikTutar'] as num).toDouble(),
        toplamTaksit: j['toplamTaksit'],
        baslangicAyYil: j['baslangicAyYil'],
        odenenAylar: Map<String, bool>.from(j['odenenAylar'] ?? {}),
      );
}

class Hatirlatici {
  String id;
  String baslik;
  String tip;
  List<String> zamanlamaSecenekleri;
  String ozelSecilenSaat;
  String acTok;
  String hatirlatmaSuresi;
  DateTime tarihSaat;
  bool tamamlandi;
  String ayYilAnahtari;

  Hatirlatici({
    required this.id,
    required this.baslik,
    required this.tip,
    this.zamanlamaSecenekleri = const [],
    this.ozelSecilenSaat = '',
    this.acTok = '',
    this.hatirlatmaSuresi = '1 saat önce',
    required this.tarihSaat,
    this.tamamlandi = false,
    required this.ayYilAnahtari,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'baslik': baslik,
        'tip': tip,
        'zamanlamaSecenekleri': zamanlamaSecenekleri,
        'ozelSecilenSaat': ozelSecilenSaat,
        'acTok': acTok,
        'hatirlatmaSuresi': hatirlatmaSuresi,
        'tarihSaat': tarihSaat.toIso8601String(),
        'tamamlandi': tamamlandi,
        'ayYilAnahtari': ayYilAnahtari,
      };

  factory Hatirlatici.fromJson(Map<String, dynamic> j) => Hatirlatici(
        id: j['id'],
        baslik: j['baslik'],
        tip: j['tip'],
        zamanlamaSecenekleri: List<String>.from(j['zamanlamaSecenekleri'] ?? []),
        ozelSecilenSaat: j['ozelSecilenSaat'] ?? '',
        acTok: j['acTok'] ?? '',
        hatirlatmaSuresi: j['hatirlatmaSuresi'] ?? '1 saat önce',
        tarihSaat: DateTime.parse(j['tarihSaat']),
        tamamlandi: j['tamamlandi'] ?? false,
        ayYilAnahtari: j['ayYilAnahtari'],
      );
}

// ============================== AJANDA MODELLERİ ==============================

// Etkinlik türlerinde seçilebilecek ikonlar (ilk dördü varsayılan türlerin ikonları)
final List<IconData> ajandaIkonlari = [
  Icons.medication,
  Icons.cake,
  Icons.local_hospital,
  Icons.task_alt,
  Icons.event,
  Icons.favorite,
  Icons.school,
  Icons.work,
  Icons.flight,
  Icons.directions_car,
  Icons.fitness_center,
  Icons.pets,
  Icons.shopping_bag,
  Icons.restaurant,
  Icons.call,
  Icons.groups,
  Icons.celebration,
  Icons.child_care,
  Icons.water_drop,
  Icons.bedtime,
  Icons.wb_sunny,
  Icons.build,
  Icons.sports_soccer,
  Icons.vaccines,
  Icons.sticky_note_2_outlined,
  Icons.shopping_cart_outlined,
  Icons.bookmark_outline,
  Icons.home_outlined,
  Icons.star_outline,
  Icons.lightbulb_outline,
  Icons.folder_outlined,
];

// Etkinlik türlerinde seçilebilecek renkler (ilk dördü varsayılan türlerin renkleri)
const List<Color> ajandaRenkleri = [
  Color(0xFF8B5CF6),
  Color(0xFFEC4899),
  Color(0xFFF97316),
  Color(0xFF3B82F6),
  Color(0xFF14B8A6),
  Color(0xFF22C55E),
  Color(0xFFEAB308),
  Color(0xFFEF4444),
  Color(0xFF06B6D4),
  Color(0xFF64748B),
  Color(0xFF6366F1),
  Color(0xFF92400E),
  Color(0xFF84CC16),
];

// Hazır gün içi zamanlar: sabah, öğle, akşam, uyanınca, yatmadan
const Map<String, List<int>> hazirZamanlar = {
  'Sabah': [8, 0],
  'Öğle': [13, 0],
  'Akşam': [19, 0],
  'Uyanınca': [7, 0],
  'Yatmadan önce': [23, 0],
};

// Türe özel hazır zamanlar ("+ Saat ekle" menüsündeki kısayollar).
// Burada olmayan (kendi eklediğin) türlerde menü açılmaz, doğrudan saat seçici açılır.
const Map<String, Map<String, List<int>>> turZamanlari = {
  'ilac': hazirZamanlar,
  'dogum': {
    'Sabah tebriği': [9, 0],
    'Akşam kutlaması': [20, 0],
    'Gece yarısı': [0, 0],
  },
  'randevu': {
    'Randevu saati': [9, 0],
    'Yola çıkış': [8, 0],
  },
  'gorev': {
    'Başlangıç': [9, 0],
    'Teslim saati': [17, 0],
  },
};

class EtkinlikTuru {
  String id;
  String ad;
  int ikon; // ajandaIkonlari içindeki sıra
  int renk; // ajandaRenkleri içindeki sıra

  EtkinlikTuru({required this.id, required this.ad, required this.ikon, required this.renk});

  IconData get ikonVerisi => ajandaIkonlari[ikon % ajandaIkonlari.length];
  Color get renkVerisi {
    final Color c = ajandaRenkleri[renk % ajandaRenkleri.length];
    return koyuMod ? Color.lerp(c, Colors.white, 0.28)! : c;
  }

  Map<String, dynamic> toJson() => {'id': id, 'ad': ad, 'ikon': ikon, 'renk': renk};

  factory EtkinlikTuru.fromJson(Map<String, dynamic> j) => EtkinlikTuru(
        id: j['id'],
        ad: j['ad'],
        ikon: j['ikon'] ?? 4,
        renk: j['renk'] ?? 4,
      );
}

List<EtkinlikTuru> varsayilanEtkinlikTurleri() => [
      EtkinlikTuru(id: 'gorev', ad: 'Görev', ikon: 3, renk: 3),
      EtkinlikTuru(id: 'randevu', ad: 'Randevu', ikon: 2, renk: 2),
      EtkinlikTuru(id: 'ilac', ad: 'İlaç', ikon: 0, renk: 0),
      EtkinlikTuru(id: 'dogum', ad: 'Doğum Günü', ikon: 1, renk: 1),
    ];

// Yerleşik türler Görev, Randevu, İlaç, Doğum Günü sırasıyla; kendi eklediklerin arkadan gelir
List<EtkinlikTuru> turSirasiniDuzenle(List<EtkinlikTuru> liste) {
  const sira = ['gorev', 'randevu', 'ilac', 'dogum'];
  final List<EtkinlikTuru> yerlesik = [];
  for (final id in sira) {
    final EtkinlikTuru? t = liste.where((x) => x.id == id).firstOrNull;
    if (t != null) yerlesik.add(t);
  }
  return [...yerlesik, ...liste.where((x) => !sira.contains(x.id))];
}

// Notlarda varsayılan kategoriler (sonradan değiştirilebilir)
List<EtkinlikTuru> varsayilanNotKategorileri() => [
      EtkinlikTuru(id: 'genel', ad: 'Genel', ikon: 26, renk: 3),
      EtkinlikTuru(id: 'notlar', ad: 'Notlar', ikon: 24, renk: 6),
      EtkinlikTuru(id: 'market', ad: 'Market', ikon: 25, renk: 5),
    ];

// Bir günün içindeki saat (ör. Sabah 08:00 veya özel 14:30)
class ZamanDilimi {
  String etiket;
  int saat;
  int dakika;

  ZamanDilimi({this.etiket = '', required this.saat, required this.dakika});

  int get gundekiDakika => saat * 60 + dakika;

  String get saatMetni => '${saat.toString().padLeft(2, '0')}:${dakika.toString().padLeft(2, '0')}';

  ZamanDilimi kopya() => ZamanDilimi(etiket: etiket, saat: saat, dakika: dakika);

  Map<String, dynamic> toJson() => {'etiket': etiket, 'saat': saat, 'dakika': dakika};

  factory ZamanDilimi.fromJson(Map<String, dynamic> j) => ZamanDilimi(
        etiket: j['etiket'] ?? '',
        saat: j['saat'] ?? 9,
        dakika: j['dakika'] ?? 0,
      );
}

// "Ne kadar önce hatırlatsın": deger + birim (dakika, saat, gun, hafta)
class Hatirlatma {
  int deger;
  String birim;
  int? gunSaati; // gün/hafta önce hatırlatmalarda bildirimin çalacağı saat (günün kaçıncı dakikası)

  Hatirlatma(this.deger, this.birim, {this.gunSaati});

  bool ayni(Hatirlatma o) => deger == o.deger && birim == o.birim;

  Hatirlatma kopya() => Hatirlatma(deger, birim, gunSaati: gunSaati);

  String get saatMetni {
    final int dk = gunSaati ?? 540;
    return '${(dk ~/ 60).toString().padLeft(2, '0')}:${(dk % 60).toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {'deger': deger, 'birim': birim, 'gunSaati': gunSaati};

  factory Hatirlatma.fromJson(Map<String, dynamic> j) => Hatirlatma(j['deger'] ?? 0, j['birim'] ?? 'dakika', gunSaati: j['gunSaati']);
}

class Etkinlik {
  String id;
  String baslik;
  String turId;
  String notlar;
  DateTime baslangic;
  bool tumGun;
  List<ZamanDilimi> zamanlar;
  String tekrar; // yok, gun, hafta, ay, yil
  int aralik; // "her N günde bir"
  List<int> haftaGunleri; // 1 = pazartesi ... 7 = pazar
  DateTime? bitis; // null ise süresiz
  List<Hatirlatma> hatirlatmalar;
  int hatirlatmaGunSaati; // tüm gün etkinliklerde hatırlatma saati (günün kaçıncı dakikası)
  List<String> yapilanlar; // "yyyy-MM-dd|zamanSırası" biçiminde tamamlananlar
  List<String> fotolar; // etkinliğe eklenen fotoğrafların dosya adları
  DateTime? silinme; // çöp kutusuna atıldığı an (çöp kutusu dışında null)

  Etkinlik({
    required this.id,
    required this.baslik,
    required this.turId,
    this.notlar = '',
    required this.baslangic,
    this.tumGun = false,
    List<ZamanDilimi>? zamanlar,
    this.tekrar = 'yok',
    this.aralik = 1,
    List<int>? haftaGunleri,
    this.bitis,
    List<Hatirlatma>? hatirlatmalar,
    this.hatirlatmaGunSaati = 540,
    List<String>? yapilanlar,
    List<String>? fotolar,
    this.silinme,
  })  : zamanlar = zamanlar ?? [],
        haftaGunleri = haftaGunleri ?? [],
        hatirlatmalar = hatirlatmalar ?? [],
        yapilanlar = yapilanlar ?? [],
        fotolar = fotolar ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'baslik': baslik,
        'turId': turId,
        'notlar': notlar,
        'baslangic': baslangic.toIso8601String(),
        'tumGun': tumGun,
        'zamanlar': zamanlar.map((z) => z.toJson()).toList(),
        'tekrar': tekrar,
        'aralik': aralik,
        'haftaGunleri': haftaGunleri,
        'bitis': bitis?.toIso8601String(),
        'hatirlatmalar': hatirlatmalar.map((h) => h.toJson()).toList(),
        'hatirlatmaGunSaati': hatirlatmaGunSaati,
        'yapilanlar': yapilanlar,
        'fotolar': fotolar,
        if (silinme != null) 'silinme': silinme!.toIso8601String(),
      };

  factory Etkinlik.fromJson(Map<String, dynamic> j) => Etkinlik(
        id: j['id'],
        baslik: j['baslik'] ?? '',
        turId: j['turId'] ?? 'gorev',
        notlar: j['notlar'] ?? '',
        baslangic: DateTime.parse(j['baslangic']),
        tumGun: j['tumGun'] ?? false,
        zamanlar: (j['zamanlar'] as List? ?? []).map((e) => ZamanDilimi.fromJson(Map<String, dynamic>.from(e))).toList(),
        tekrar: j['tekrar'] ?? 'yok',
        aralik: j['aralik'] ?? 1,
        haftaGunleri: List<int>.from(j['haftaGunleri'] ?? []),
        bitis: j['bitis'] == null ? null : DateTime.parse(j['bitis']),
        hatirlatmalar: (j['hatirlatmalar'] as List? ?? []).map((e) => Hatirlatma.fromJson(Map<String, dynamic>.from(e))).toList(),
        hatirlatmaGunSaati: j['hatirlatmaGunSaati'] ?? 540,
        yapilanlar: List<String>.from(j['yapilanlar'] ?? []),
        fotolar: List<String>.from(j['fotolar'] ?? []),
        silinme: j['silinme'] == null ? null : DateTime.tryParse(j['silinme'].toString()),
      );
}

// Bir günün sabah özeti için sayımlar
class _GunOzeti {
  int etkinlik = 0;
  int odeme = 0;
  double odemeTutar = 0;
  final List<_OzetOgesi> ogeler = []; // günün etkinlik ve ödemeleri (bildirim metnini yazmak için)
}

// Özet bildiriminde tek satır olarak görünecek öğe
class _OzetOgesi {
  final int sira; // saatli: günün dakikası • tüm gün: 1500 • ödeme: 3000
  final String metin;
  const _OzetOgesi(this.sira, this.metin);
}

// Telefonun alarm sistemine kaydedilecek tek bir bildirim
class _PlanliBildirim {
  final DateTime zaman;
  final String baslik;
  final String metin;
  final String payload; // dokununca hangi etkinliğin / ödemenin açılacağı
  final bool finans; // ödeme hatırlatması mı (ayrı bildirim kanalı)
  final bool ozet; // sabah özeti mi (Ertele düğmesi olmaz)

  const _PlanliBildirim(this.zaman, this.baslik, this.metin, this.payload, {this.finans = false, this.ozet = false});
}

// Bir etkinliğin belirli bir günde, belirli bir saatteki tek bir gerçekleşmesi
class _AjandaOlay {
  final Etkinlik etkinlik;
  final DateTime gun;
  final int zamanIndex;

  const _AjandaOlay(this.etkinlik, this.gun, this.zamanIndex);

  bool get gunBoyu => etkinlik.tumGun || etkinlik.zamanlar.isEmpty;

  String get anahtar => '${DateFormat('yyyy-MM-dd').format(gun)}|$zamanIndex';

  int get siraDakika => gunBoyu ? -1 : etkinlik.zamanlar[zamanIndex].gundekiDakika;

  DateTime get zaman {
    if (gunBoyu) return DateTime(gun.year, gun.month, gun.day);
    final z = etkinlik.zamanlar[zamanIndex];
    return DateTime(gun.year, gun.month, gun.day, z.saat, z.dakika);
  }
}

// ============================== PROFİL, HATIRLATMA, KAYDIRMA, FOTOĞRAF ==============================

// Her profil kendi finans, ajanda ve ayarlarıyla bağımsız bir veri kümesidir
class Profil {
  String id;
  String ad;
  // İsteğe bağlı bilgiler (boş bırakılabilir)
  String dogum; // 'yyyy-MM-dd' ya da boş
  String telefon;
  String eposta;
  String sehir;

  Profil({required this.id, required this.ad, this.dogum = '', this.telefon = '', this.eposta = '', this.sehir = ''});

  DateTime? get dogumTarihi => dogum.isEmpty ? null : DateTime.tryParse(dogum);

  Map<String, dynamic> toJson() => {
        'id': id,
        'ad': ad,
        if (dogum.isNotEmpty) 'dogum': dogum,
        if (telefon.isNotEmpty) 'telefon': telefon,
        if (eposta.isNotEmpty) 'eposta': eposta,
        if (sehir.isNotEmpty) 'sehir': sehir,
      };

  factory Profil.fromJson(Map<String, dynamic> j) => Profil(
        id: j['id'],
        ad: j['ad'] ?? 'Profil',
        dogum: (j['dogum'] ?? '') as String,
        telefon: (j['telefon'] ?? '') as String,
        eposta: (j['eposta'] ?? '') as String,
        sehir: (j['sehir'] ?? '') as String,
      );
}

// Ödeme hatırlatması: son ödeme tarihinden kaç gün önce, günün hangi saatinde (0 gün = son gün)
class FinansHatirlatma {
  int gun;
  int saat; // günün kaçıncı dakikası

  FinansHatirlatma(this.gun, this.saat);

  Map<String, dynamic> toJson() => {'gun': gun, 'saat': saat};

  factory FinansHatirlatma.fromJson(Map<String, dynamic> j) => FinansHatirlatma(j['gun'] ?? 0, j['saat'] ?? 540);
}

// Sekmeler arasında kaydırırken yanlışlıkla geçişi önler: sayfanın yarısından fazlası sürüklenmeden
// veya çok hızlı ve kararlı bir hamle yapılmadan sayfa değişmez, bırakınca yerine geri döner.
class SertSayfaFizigi extends PageScrollPhysics {
  const SertSayfaFizigi({super.parent});

  @override
  SertSayfaFizigi applyTo(ScrollPhysics? ancestor) => SertSayfaFizigi(parent: buildParent(ancestor));

  @override
  Tolerance toleranceFor(ScrollMetrics metrics) => const Tolerance(velocity: 1800.0, distance: 0.5);
}

// Sekme sayfalarının kaydırma konumunu ve durumunu korur
class KalanSayfa extends StatefulWidget {
  final Widget child;

  const KalanSayfa({super.key, required this.child});

  @override
  State<KalanSayfa> createState() => _KalanSayfaState();
}

class _KalanSayfaState extends State<KalanSayfa> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

// Tam ekran fotoğraf görüntüleyici: parmakla yakınlaştırma, çift dokunuşla büyütme, sağa sola kaydırma, silme
class FotoGoruntuleyici extends StatefulWidget {
  final String klasor;
  final List<String> fotolar;
  final int baslangic;
  final Future<bool> Function(String ad)? sil;

  const FotoGoruntuleyici({super.key, required this.klasor, required this.fotolar, this.baslangic = 0, this.sil});

  @override
  State<FotoGoruntuleyici> createState() => _FotoGoruntuleyiciState();
}

class _FotoGoruntuleyiciState extends State<FotoGoruntuleyici> {
  late final PageController _sayfa;
  late List<String> _liste;
  int _sira = 0;
  bool _yakin = false;
  int _parmak = 0; // ekrana değen parmak sayısı: iki parmak varken sayfa kaydırması kapanır, yakınlaştırma çalışır
  // Yukarı/aşağı sürükleyip kapatma (yalnızca yakınlaştırılmamışken, tek parmakla)
  Offset? _surukBas;
  bool? _dikey; // null: henüz karar verilmedi
  double _surukDy = 0;
  bool _surukuyor = false;
  final Map<String, TransformationController> _donusumler = {};

  @override
  void initState() {
    super.initState();
    _liste = List<String>.from(widget.fotolar);
    _sira = math.max(0, math.min(widget.baslangic, _liste.length - 1));
    _sayfa = PageController(initialPage: _sira);
  }

  @override
  void dispose() {
    _sayfa.dispose();
    for (final c in _donusumler.values) {
      c.dispose();
    }
    super.dispose();
  }

  TransformationController _donusum(String ad) {
    return _donusumler.putIfAbsent(ad, () {
      final c = TransformationController();
      c.addListener(() {
        if (!mounted || _liste.isEmpty || _sira >= _liste.length) return;
        if (_liste[_sira] != ad) return;
        final bool yakin = c.value.getMaxScaleOnAxis() > 1.02;
        if (yakin != _yakin) setState(() => _yakin = yakin);
      });
      return c;
    });
  }

  void _cifteDokunma(String ad) {
    final TransformationController c = _donusum(ad);
    if (c.value.getMaxScaleOnAxis() > 1.02) {
      c.value = Matrix4.identity();
      return;
    }
    final Size boyut = MediaQuery.of(context).size;
    const double olcek = 2.5;
    final Matrix4 m = Matrix4.identity();
    m.setEntry(0, 0, olcek);
    m.setEntry(1, 1, olcek);
    m.setEntry(0, 3, -(boyut.width / 2) * (olcek - 1));
    m.setEntry(1, 3, -(boyut.height / 2) * (olcek - 1));
    c.value = m;
  }

  Future<void> _sil() async {
    final Future<bool> Function(String ad)? silici = widget.sil;
    if (silici == null || _liste.isEmpty) return;
    final String ad = _liste[_sira];
    final bool onay = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Fotoğraf silinsin mi?'),
            content: const Text('Bu fotoğraf etkinlikten kaldırılacak.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Sil'),
              ),
            ],
          ),
        ) ??
        false;
    if (!onay || !mounted) return;
    final bool silindi = await silici(ad);
    if (!silindi || !mounted) return;
    setState(() {
      _liste.removeAt(_sira);
      _donusumler.remove(ad)?.dispose();
      if (_sira >= _liste.length) _sira = _liste.length - 1;
      _yakin = false;
    });
    if (_liste.isEmpty) {
      Navigator.pop(context);
    } else {
      _sayfa.jumpToPage(_sira);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_liste.isEmpty) return const Scaffold(backgroundColor: Colors.black);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text('${_sira + 1} / ${_liste.length}', style: const TextStyle(fontSize: 15)),
        actions: [
          if (widget.sil != null) IconButton(tooltip: 'Fotoğrafı sil', icon: const Icon(Icons.delete_outline), onPressed: _sil),
        ],
      ),
      body: Listener(
        onPointerDown: (o) => setState(() {
          _parmak++;
          if (_parmak == 1) {
            _surukBas = o.position;
            _dikey = null;
          } else {
            // İkinci parmak: sürükleyip kapatma iptal, yakınlaştırma devreye girer
            _surukBas = null;
            _dikey = false;
            _surukDy = 0;
            _surukuyor = false;
          }
        }),
        onPointerMove: (o) {
          final Offset? bas = _surukBas;
          if (bas == null || _parmak != 1 || _yakin) return;
          final Offset fark = o.position - bas;
          if (_dikey == null && fark.distance > 14) _dikey = fark.dy.abs() > fark.dx.abs() * 1.3;
          if (_dikey == true) {
            setState(() {
              _surukDy = fark.dy;
              _surukuyor = true;
            });
          }
        },
        onPointerUp: (_) {
          final bool kapat = _dikey == true && _surukDy.abs() > 110;
          setState(() {
            _parmak = math.max(0, _parmak - 1);
            if (_parmak == 0) {
              _surukBas = null;
              _dikey = null;
              _surukuyor = false;
              if (!kapat) _surukDy = 0;
            }
          });
          if (kapat) Navigator.pop(context);
        },
        onPointerCancel: (_) => setState(() {
          _parmak = math.max(0, _parmak - 1);
          _surukBas = null;
          _dikey = null;
          _surukuyor = false;
          _surukDy = 0;
        }),
        child: AnimatedContainer(
        duration: _surukuyor ? Duration.zero : const Duration(milliseconds: 180),
        transform: Matrix4.translationValues(0, _surukDy, 0),
        child: Opacity(
        opacity: (1 - _surukDy.abs() / 500).clamp(0.4, 1.0),
        child: PageView.builder(
        controller: _sayfa,
        physics: (_yakin || _parmak >= 2) ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
        itemCount: _liste.length,
        onPageChanged: (i) => setState(() {
          _sira = i;
          _yakin = false;
        }),
        itemBuilder: (ctx, i) {
          final String ad = _liste[i];
          return GestureDetector(
            onDoubleTap: () => _cifteDokunma(ad),
            child: InteractiveViewer(
              transformationController: _donusum(ad),
              minScale: 1.0,
              maxScale: 5.0,
              child: Center(
                child: Image.file(
                  File('${widget.klasor}/$ad'),
                  fit: BoxFit.contain,
                  cacheWidth: 2400,
                  errorBuilder: (c, e, s) => const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.broken_image_outlined, color: Colors.white54, size: 56),
                        SizedBox(height: 8),
                        Text('Fotoğraf açılamadı', style: TextStyle(color: Colors.white54)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
        ),
        ),
        ),
      ),
    );
  }
}

// ============================== NOTLAR VE BİLDİRİM SESLERİ ==============================

class NotMaddesi {
  String id;
  String metin;
  bool tamam;
  String not; // maddenin altında görünen küçük not

  NotMaddesi({required this.id, required this.metin, this.tamam = false, this.not = ''});

  Map<String, dynamic> toJson() => {'id': id, 'metin': metin, 'tamam': tamam, 'not': not};

  factory NotMaddesi.fromJson(Map<String, dynamic> j) => NotMaddesi(id: j['id'].toString(), metin: j['metin'] ?? '', tamam: j['tamam'] ?? false, not: j['not']?.toString() ?? '');
}

// Bir liste (maddeli) veya serbest not. İstenirse tarih/saat hatırlatması da taşır;
// hatırlatması olan notlar Ajanda'da ve bildirimlerde bir etkinlik gibi görünür.
class NotKaydi {
  String id;
  String baslik;
  bool liste; // true: maddeli liste, false: serbest not
  String metin;
  List<NotMaddesi> maddeler;
  String kategori; // boş = kategorisiz
  int renk; // ajandaRenkleri içindeki sıra
  bool sabit;
  bool tamamlandi; // hatırlatmalı notlar için "yapıldı" işareti
  List<String> fotolar;
  DateTime olusturma;
  DateTime duzenleme; // son değişiklik anı (sıralama bununla yapılır)
  DateTime? hatirlatmaTarihi;
  int? hatirlatmaSaati; // günün kaçıncı dakikası; boşsa tüm gün
  List<Hatirlatma> hatirlatmalar;
  DateTime? silinme; // çöp kutusuna atıldığı an (çöp kutusu dışında null)

  NotKaydi({
    required this.id,
    this.baslik = '',
    this.liste = true,
    this.metin = '',
    List<NotMaddesi>? maddeler,
    this.kategori = '',
    this.renk = 6,
    this.sabit = false,
    this.tamamlandi = false,
    List<String>? fotolar,
    DateTime? olusturma,
    DateTime? duzenleme,
    this.hatirlatmaTarihi,
    this.hatirlatmaSaati,
    List<Hatirlatma>? hatirlatmalar,
    this.silinme,
  })  : maddeler = maddeler ?? [],
        fotolar = fotolar ?? [],
        olusturma = olusturma ?? DateTime.now(),
        duzenleme = duzenleme ?? olusturma ?? DateTime.now(),
        hatirlatmalar = hatirlatmalar ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'baslik': baslik,
        'liste': liste,
        'metin': metin,
        'maddeler': maddeler.map((m) => m.toJson()).toList(),
        'kategori': kategori,
        'renk': renk,
        'sabit': sabit,
        'tamamlandi': tamamlandi,
        'fotolar': fotolar,
        'olusturma': olusturma.toIso8601String(),
        'duzenleme': duzenleme.toIso8601String(),
        'hatirlatmaTarihi': hatirlatmaTarihi?.toIso8601String(),
        'hatirlatmaSaati': hatirlatmaSaati,
        'hatirlatmalar': hatirlatmalar.map((h) => h.toJson()).toList(),
        if (silinme != null) 'silinme': silinme!.toIso8601String(),
      };

  factory NotKaydi.fromJson(Map<String, dynamic> j) => NotKaydi(
        id: j['id'].toString(),
        baslik: j['baslik'] ?? '',
        liste: j['liste'] ?? true,
        metin: j['metin'] ?? '',
        maddeler: (j['maddeler'] as List? ?? []).map((e) => NotMaddesi.fromJson(Map<String, dynamic>.from(e))).toList(),
        kategori: j['kategori'] ?? '',
        renk: (j['renk'] as num?)?.toInt() ?? 6,
        sabit: j['sabit'] ?? false,
        tamamlandi: j['tamamlandi'] ?? false,
        fotolar: List<String>.from(j['fotolar'] ?? []),
        olusturma: DateTime.tryParse(j['olusturma']?.toString() ?? ''),
        duzenleme: DateTime.tryParse(j['duzenleme']?.toString() ?? ''),
        hatirlatmaTarihi: j['hatirlatmaTarihi'] == null ? null : DateTime.tryParse(j['hatirlatmaTarihi'].toString()),
        hatirlatmaSaati: (j['hatirlatmaSaati'] as num?)?.toInt(),
        hatirlatmalar: (j['hatirlatmalar'] as List? ?? []).map((e) => Hatirlatma.fromJson(Map<String, dynamic>.from(e))).toList(),
        silinme: j['silinme'] == null ? null : DateTime.tryParse(j['silinme'].toString()),
      );
}

// Bildirim sesleri: kısa isim → [ad, açıklama]. 'sistem' dışındakiler uygulamanın raw klasöründeki alfred_<isim>.wav dosyalarıdır.
const Map<String, List<String>> bildirimSesleri = {
  'sistem': ['Telefonun varsayılan sesi', 'Telefonunun kendi bildirim sesi'],
  'zil': ['Zil', 'Berrak, kısa bir masa zili'],
  'can': ['Çan', 'Derin ve yumuşak bir çan'],
  'tinlama': ['Tınlama', 'İki notalı hafif bir tınlama'],
  'kristal': ['Kristal', 'İnce ve parlak bir çınlama'],
  'melodi': ['Melodi', 'Üç notalı sakin bir melodi'],
  'cift': ['Çift zil', 'Dikkat çeken iki kısa zil'],
};

// Seçilen ayın toplamlarını tutan yardımcı sınıf
class _Ozet {
  final double toplamGelir;
  final double toplamGider;
  final double odenenGider;

  const _Ozet({
    required this.toplamGelir,
    required this.toplamGider,
    required this.odenenGider,
  });
}

typedef AsyncTiklama = Future<void> Function();

// Listede ve takvimde gösterilen tek bir satır (ödeme, gelir veya plan)
class _Odeme {
  final String baslik;
  final String alt;
  final double tutar;
  final Color renk; // ikon rengi
  final Color nokta; // kategori rengi (takvim noktaları)
  final IconData ikon;
  final int gun; // seçili ayda hangi gün gösterilecek
  final DateTime vade; // gerçek son ödeme tarihi
  final bool odendi;
  final bool kismi;
  final bool gelir;
  final bool gecikmeGoster;
  final bool tarihGoster;
  final String? rozet;
  final String? sagMetin;
  final double? kalanTutar;
  final AsyncTiklama? onToggle;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  const _Odeme({
    required this.baslik,
    required this.alt,
    required this.tutar,
    required this.renk,
    required this.nokta,
    required this.ikon,
    required this.gun,
    required this.vade,
    required this.odendi,
    this.kismi = false,
    this.gelir = false,
    this.gecikmeGoster = true,
    this.tarihGoster = true,
    this.rozet,
    this.sagMetin,
    this.kalanTutar,
    this.onToggle,
    this.onTap,
    this.onDelete,
  });

  double get kalan => kalanTutar ?? ((odendi || gelir) ? 0 : tutar);

  // Takvim içinde kullanılırken: işaretleyince takvim de yenilensin, düzenle/sil kapalı
  _Odeme takvimIcin(VoidCallback yenile) {
    final AsyncTiklama? t = onToggle;
    return _Odeme(
      baslik: baslik,
      alt: alt,
      tutar: tutar,
      renk: renk,
      nokta: nokta,
      ikon: ikon,
      gun: gun,
      vade: vade,
      odendi: odendi,
      kismi: kismi,
      gelir: gelir,
      gecikmeGoster: gecikmeGoster,
      tarihGoster: tarihGoster,
      rozet: rozet,
      sagMetin: sagMetin,
      kalanTutar: kalanTutar,
      onToggle: t == null
          ? null
          : () async {
              await t();
              yenile();
            },
    );
  }
}

// Sıralanabilir bir birim: tek bir gider/gelir satırı veya bir kart (ekstre + taksitleri)
class _Birim {
  final String anahtar; // bildirimden gelince bulunabilmesi için ('kalem:ID', 'kart:ID', 'kredi:ID')
  final String kategori;
  final int gun;
  final double tutar;
  final double odenen;
  final String ad;
  final List<Widget> widgetlar;

  const _Birim({
    required this.anahtar,
    required this.kategori,
    required this.gun,
    required this.tutar,
    required this.odenen,
    required this.ad,
    required this.widgetlar,
  });
}

// Borç takip kartı için yardımcı sınıf
class _BorcOgesi {
  final String ad;
  final String alt;
  final Color renk;
  final IconData ikon;
  final double aylik;
  final int toplamAy;
  final int odenenAy;
  final DateTime baslangic;
  final String bitisMetni;

  const _BorcOgesi({
    required this.ad,
    required this.alt,
    required this.renk,
    required this.ikon,
    required this.aylik,
    required this.toplamAy,
    required this.odenenAy,
    required this.baslangic,
    required this.bitisMetni,
  });

  double get toplam => aylik * toplamAy;
  double get odenen => aylik * odenenAy;
  double get kalan => math.max(0.0, toplam - odenen);
  int get kalanAy => math.max(0, toplamAy - odenenAy);
  double get oran => toplamAy > 0 ? (odenenAy / toplamAy).clamp(0.0, 1.0) : 0.0;
}

// ============================== ANA EKRAN ==============================

class AnaEkran extends StatefulWidget {
  const AnaEkran({super.key});

  @override
  State<AnaEkran> createState() => _AnaEkranState();
}

class _AnaEkranState extends State<AnaEkran> with WidgetsBindingObserver {
  int _seciliSekme = 0;
  // Alt menünün seçili sekmesi; değişince tüm sayfalar değil yalnızca menü yeniden çizilir (kaydırma akıcı kalsın)
  final ValueNotifier<int> _sekmeBildirici = ValueNotifier<int>(0);
  bool gizlilikModu = false;
  bool gelecekGiderlerAcik = true;
  bool gelirlerAcik = true;

  // Sıralama: 'tur', 'tarih' veya 'fiyat'
  String _siralama = 'tur';
  bool _siralamaArtan = true;

  // Analiz sekmesindeki dağılım kartı: false = gider, true = gelir
  bool _dagilimGelir = false;

  String _ayDegeri = DateFormat('yyyy-MM').format(DateTime.now());

  // Seçili ay değişince o aya kadarki sabit ödeme kayıtları hazırlanır (build içinde veri değiştirmemek için burada)
  String get _secilenAyYil => _ayDegeri;
  set _secilenAyYil(String deger) {
    _ayDegeri = deger;
    _sabitleriUret();
  }

  List<KrediKarti> krediKartiListesi = [
    KrediKarti(id: '1', kartAdi: 'Bonus Kart', limit: 50000, sonOdemeGunu: '25'),
    KrediKarti(id: '2', kartAdi: 'Akbank', limit: 40000, sonOdemeGunu: '28'),
  ];
  List<KrediBorcu> krediListesi = [];
  List<FinansKalemi> finansListesi = [];
  List<KartTaksiti> kartTaksitListesi = [];
  List<Etkinlik> etkinlikListesi = [];
  List<EtkinlikTuru> etkinlikTurleri = varsayilanEtkinlikTurleri();
  bool _ajandaListeGorunumu = false;
  int? _ajandaGunSecimi;
  String _ajandaGunAyi = '';
  List<SabitOdeme> sabitListesi = [];

  bool _yuklendi = false;

  // Bildirim durumu
  Timer? _bildirimZamanlayici;
  bool _bildirimPlanCalisiyor = false;
  bool _bildirimPlanBekliyor = false;
  String _bildirimHatasi = '';
  bool? _bildirimIzniVar;

  // Ödeme hatırlatma ayarları (profile özel; Ayarlar'dan değiştirilir)
  bool finansBildirimAcik = true;
  List<FinansHatirlatma> finansHatirlatmalari = [FinansHatirlatma(3, 540), FinansHatirlatma(0, 540)];
  bool finansGecikmeBildirimi = true;
  int finansGecikmeSaati = 540; // günün kaçıncı dakikası (09:00)
  List<Hatirlatma> ozelHatirlatmalar = []; // etkinliklerde kendi eklediğin hatırlatma süreleri
  String _sonPlanImzasi = '';

  // Genel ayarlar (profilden bağımsız)
  bool bildirimGuvenilirMod = true;
  int yedekHatirlatmaGunu = 14; // 0 = kapalı
  bool otoYedekFoto = false; // otomatik yedeklere fotoğraflar da eklensin mi
  bool otoYedekAcik = true; // otomatik yedekleme açık mı
  int otoYedekGunu = 1; // kaç günde bir otomatik yedek alınsın (1, 2, 3, 7)
  DateTime? _sonOtoYedek; // son başarılı otomatik yedeğin zamanı
  String? _sonOtoYedekHata; // son denemede hata olduysa nedeni
  int ertelemeDk = 10; // bildirimdeki Ertele düğmesinin süresi (dakika)
  bool haftaOzetiAcik = true; // "önümüzdeki hafta" özeti
  int haftaOzetiGunu = 7; // 1 = pazartesi ... 7 = pazar
  int haftaOzetiSaati = 960; // günün kaçıncı dakikası (16:00)
  Map<String, String> _kategoriHafizasi = {}; // başlıktaki kelime -> son seçilen kategori ('g:Market' / 'i:Maaş')
  bool elleYedekFoto = true; // "Yedek al" penceresinde fotoğraf anahtarının son hali
  DateTime? _ilkKullanim;

  // Bildirimden açılan ödemenin vurgulanması
  String? _vurguluFinansAnahtari;
  String? _vurguluFinansAyi;

  // Bildirimden açılan etkinliğin vurgulanması
  String? _vurguluEtkinlikId;
  DateTime? _vurguluGun;
  Timer? _vurguZamanlayici;
  final GlobalKey _vurguAnahtari = GlobalKey();
  final GlobalKey _ajandaGunKartiAnahtari = GlobalKey(); // seçili günün etkinlik kartı (özet bildiriminden gelince kaydırılır)

  // Gecikmeli kayıt
  Timer? _kayitZamanlayici;
  String _sonKaydedilenJson = '';

  // Profiller (her profil bağımsız bir veri kümesidir)
  List<Profil> profiller = [Profil(id: 'p1', ad: 'Profilim')];
  String aktifProfilId = 'p1';
  final Map<String, Uint8List> _profilFotolari = {};
  String _sonProfilJson = '';
  String _sonAktifProfil = '';

  Profil get _aktifProfil => profiller.firstWhere((p) => p.id == aktifProfilId, orElse: () => profiller.first);

  String get aktifHesapAdi => _aktifProfil.ad;
  set aktifHesapAdi(String deger) {
    _aktifProfil.ad = deger;
  }

  Uint8List? get _profilFoto => _profilFotolari[aktifProfilId];
  set _profilFoto(Uint8List? deger) {
    if (deger == null) {
      _profilFotolari.remove(aktifProfilId);
    } else {
      _profilFotolari[aktifProfilId] = deger;
    }
  }

  DateTime? _sonYedekTarihi;

  // Etkinlik fotoğrafları, ajanda sekmelerinin açık/kapalı durumu, ayar sayfalarının yenilenmesi, sekme kaydırma
  Directory? _fotoKlasoru;
  final Map<String, bool> _ajandaAcikDurum = {};
  final ValueNotifier<int> _arayuzSurumu = ValueNotifier<int>(0);
  final PageController _sayfaKontrol = PageController();

  // Notlar
  List<NotKaydi> notListesi = [];
  List<NotKaydi> notArsivi = []; // arşivlenen notlar: listelerde, aramada, bildirimde görünmez
  List<NotKaydi> copNotlari = []; // çöp kutusundaki notlar ($copSuresiGun gün sonra kalıcı silinir)
  List<Etkinlik> copEtkinlikleri = [];
  List<EtkinlikTuru> notKategorileri = varsayilanNotKategorileri();
  String _notFiltre = '';
  String _notTurFiltresi = 'hepsi'; // hepsi | liste | not
  final TextEditingController _notAramaCtrl = TextEditingController();
  bool _ajandaAramaAcik = false;
  String _ajandaArama = '';
  final TextEditingController _ajandaAramaCtrl = TextEditingController();
  String _notArama = '';
  bool _notAramaAcik = false;
  final GlobalKey _notAramaAlani = GlobalKey();
  final GlobalKey _ajandaAramaAlani = GlobalKey();
  String _notSiralama = 'tarih'; // tarih | kategori
  bool _notSiralamaArtan = false; // false: yeniden eskiye
  String _notGorunum = 'notlar'; // notlar | kategoriler

  // Ajanda sıralaması ve bildirim ses ayarları
  String _ajandaSiralama = 'tur'; // tur | saat
  bool _ajandaSiralamaArtan = true;
  String sesEtkinlik = 'sistem';
  String sesOdeme = 'sistem';
  bool sessizdaCal = false;
  bool titresimAcik = true;
  bool sabahOzetiAcik = true;
  int sabahOzetiSaati = 480; // günün kaçıncı dakikası (08:00)
  int copSuresiGun = 14; // çöp kutusunda saklama süresi (7, 14 veya 30)

  // Test bildirimi
  DateTime? _testZamani;
  Timer? _testZamanlayici;
  bool _testIsleniyor = false;

  // ---------- Kaydet / Yükle ----------

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _yuksekYenilemeHiziniIste();
    _kisayollariKur();
    _widgetTiklamasiniKur();
    bildirimTiklamasi.addListener(_bildirimDinleyicisi);
    bildirimYapildiSinyali.addListener(_bildirimYapildilariUygula);
    _yukle();
  }

  // Her değişiklikten kısa süre sonra, toplu olarak kaydedilir (disk yazması gereksiz sık olmaz)
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _arayuzSurumu.value++;
    _kaydetPlanla();
  }

  // Aktif profilin verisi (her profilin verisi birbirinden bağımsızdır)
  Map<String, dynamic> _veriHaritasi() => {
        'gizlilikModu': gizlilikModu,
        'siralama': _siralama,
        'siralamaArtan': _siralamaArtan,
        'kartlar': krediKartiListesi.map((e) => e.toJson()).toList(),
        'krediler': krediListesi.map((e) => e.toJson()).toList(),
        'finans': finansListesi.map((e) => e.toJson()).toList(),
        'taksitler': kartTaksitListesi.map((e) => e.toJson()).toList(),
        'etkinlikler': etkinlikListesi.map((e) => e.toJson()).toList(),
        'etkinlikTurleri': etkinlikTurleri.map((e) => e.toJson()).toList(),
        'sabitler': sabitListesi.map((e) => e.toJson()).toList(),
        'finansBildirimAcik': finansBildirimAcik,
        'finansHatirlatmalari': finansHatirlatmalari.map((h) => h.toJson()).toList(),
        'finansGecikmeBildirimi': finansGecikmeBildirimi,
        'finansGecikmeSaati': finansGecikmeSaati,
        'ozelHatirlatmalar': ozelHatirlatmalar.map((h) => h.toJson()).toList(),
        'notlar': notListesi.map((n) => n.toJson()).toList(),
        'notArsivi': notArsivi.map((n) => n.toJson()).toList(),
        'copNotlari': copNotlari.map((n) => n.toJson()).toList(),
        'copEtkinlikleri': copEtkinlikleri.map((e) => e.toJson()).toList(),
        'notKategorileri': notKategorileri.map((k) => k.toJson()).toList(),
        'notSiralama': _notSiralama,
        'notSiralamaArtan': _notSiralamaArtan,
        'notGorunum': _notGorunum,
        'ajandaSiralama': _ajandaSiralama,
        'ajandaSiralamaArtan': _ajandaSiralamaArtan,
      };

  void _kaydetPlanla() {
    if (!_yuklendi) return; // Yükleme bitmeden kaydetme, yoksa veriler silinir
    _kayitZamanlayici?.cancel();
    _kayitZamanlayici = Timer(const Duration(milliseconds: 600), _kaydetHemen);
  }

  // Notların içerik imzaları: kayıttan önce değişen notun "son düzenleme" zamanı güncellenir
  final Map<String, String> _notImzalari = {};

  String _notImzasi(NotKaydi n) {
    final Map<String, dynamic> j = n.toJson()
      ..remove('duzenleme')
      ..remove('sabit');
    return jsonEncode(j);
  }

  void _notDuzenlemeleriniGuncelle() {
    final DateTime simdi = DateTime.now();
    final Set<String> gorulen = {};
    for (final n in [...notListesi, ...notArsivi]) {
      final String anahtar = '$aktifProfilId|${n.id}';
      gorulen.add(anahtar);
      final String imza = _notImzasi(n);
      final String? eski = _notImzalari[anahtar];
      if (eski != null && eski != imza) n.duzenleme = simdi;
      _notImzalari[anahtar] = eski != null && eski != imza ? _notImzasi(n) : imza;
    }
    _notImzalari.removeWhere((k, _) => k.startsWith('$aktifProfilId|') && !gorulen.contains(k));
  }

  Future<void> _kaydetHemen() async {
    _kayitZamanlayici?.cancel();
    if (!_yuklendi || _veriYuklemeHatasi) return;
    _notDuzenlemeleriniGuncelle();
    final String profilId = aktifProfilId;
    final String veriJson = jsonEncode(_veriHaritasi());
    final String profilJson = jsonEncode(profiller.map((p) => p.toJson()).toList());
    final String imza = '$profilId|$veriJson';
    final bool veriDegisti = imza != _sonKaydedilenJson;
    final bool profilDegisti = profilJson != _sonProfilJson || profilId != _sonAktifProfil;
    if (!veriDegisti && !profilDegisti) return; // hiçbir şey değişmediyse diske yazma
    _sonKaydedilenJson = imza;
    _sonProfilJson = profilJson;
    _sonAktifProfil = profilId;
    final prefs = await SharedPreferences.getInstance();
    if (veriDegisti) await prefs.setString('veri_$profilId', veriJson);
    if (profilDegisti) {
      await prefs.setString('profiller', profilJson);
      await prefs.setString('aktif_profil', profilId);
    }
    unawaited(_widgetVerisiniGuncelle());
  }

  // ---------- Uygulama kısayolları (simgeye basılı tutunca) ----------

  String? _bekleyenKisayol;
  // Açık "yeni not / yeni liste / yeni etkinlik" penceresi (widget kısayolları üst üste açmasın)
  String? _acikEditorTuru;
  bool Function()? _editorBosMu;
  Object? _editorJetonu;

  // Kısayoldan yeni bir düzenleme penceresi açılmadan önce: aynısı açıksa dokunma, doluysa koru, değilse temizle
  void _kisayolEditoruAc(String tur, VoidCallback ac) {
    if (_acikEditorTuru != null) {
      if (_acikEditorTuru == tur) return; // zaten açık
      if (!(_editorBosMu?.call() ?? true)) {
        _snack('Açık olan taslağı önce kaydet veya kapat.');
        return;
      }
    }
    final NavigatorState nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.popUntil((r) => r.isFirst);
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        if (mounted) ac();
      });
    } else {
      ac();
    }
  }

  void _kisayollariKur() {
    if (kIsWeb) return;
    try {
      const QuickActions kisayollar = QuickActions();
      kisayollar.initialize(_kisayoluIsle);
      kisayollar.setShortcutItems(const <ShortcutItem>[
        ShortcutItem(type: 'yeni_not', localizedTitle: 'Yeni not', icon: 'ic_kisayol_not'),
        ShortcutItem(type: 'yeni_liste', localizedTitle: 'Yeni liste', icon: 'ic_kisayol_liste'),
        ShortcutItem(type: 'yeni_etkinlik', localizedTitle: 'Yeni etkinlik', icon: 'ic_kisayol_etkinlik'),
      ]);
    } catch (e) {
      debugPrint('Kısayollar kurulamadı: $e');
    }
  }

  // Uygulama henüz yüklenmediyse (soğuk açılış) kısayol bekletilir, yüklenince çalıştırılır
  void _kisayoluIsle(String tur) {
    if (!_yuklendi || !mounted) {
      _bekleyenKisayol = tur;
      return;
    }
    final DateTime simdi = DateTime.now();
    switch (tur) {
      case 'yeni_not':
        _sekmeyeGit(1, animasyon: false);
        _kisayolEditoruAc('not', () => _notDuzenle(liste: false));
        break;
      case 'yeni_liste':
        _sekmeyeGit(1, animasyon: false);
        _kisayolEditoruAc('liste', () => _notDuzenle(liste: true));
        break;
      case 'yeni_etkinlik':
        _sekmeyeGit(0, animasyon: false);
        _kisayolEditoruAc('etkinlik', () => _etkinlikDialogGoster(varsayilanGun: DateTime(simdi.year, simdi.month, simdi.day)));
        break;
      case 'ajanda':
        _sekmeyeGit(0, animasyon: false);
        break;
      case 'notlar':
        _sekmeyeGit(1, animasyon: false);
        break;
      case 'finans':
        _sekmeyeGit(2, animasyon: false);
        break;
      default:
        // Widget'tan bir etkinliğe dokunuldu: "etkinlik:<yyyy-MM-dd>:<id>" -> Ajanda'da o gün ve etkinlik
        if (tur.startsWith('etkinlik:') && tur.length > 20) {
          final String gun = tur.substring(9, 19);
          final String id = tur.substring(20);
          _bildirimTiklamasiniIsle('etkinlik|$id|$gun|0');
          return;
        }
        // Widget'tan bir nota dokunuldu: "not:<id>"
        if (tur.startsWith('not:')) {
          final String id = tur.substring(4);
          if (_notBul(id) != null) {
            _sekmeyeGit(1, animasyon: false);
            if (_acikEditorTuru != null && !(_editorBosMu?.call() ?? true)) {
              _snack('Açık olan taslağı önce kaydet veya kapat.');
              return;
            }
            final NavigatorState nav = Navigator.of(context);
            if (nav.canPop()) {
              nav.popUntil((r) => r.isFirst);
              Future<void>.delayed(const Duration(milliseconds: 300), () {
                if (mounted) _notGoruntule(id);
              });
            } else {
              _notGoruntule(id);
            }
          }
        }
    }
  }

  // ---------- Ana ekran widget'ı ----------

  StreamSubscription<Uri?>? _widgetAbonelik;
  String _sonWidgetJson = '';
  static const String _widgetSinifi = 'com.example.kisisel_asistan.AlfredWidget';

  // Widget'a dokunulunca ("alfred://widget/<tur>[/<id>]") ilgili yere gider
  void _widgetTiklamasiniKur() {
    if (kIsWeb) return;
    try {
      HomeWidget.initiallyLaunchedFromHomeWidget().then(_widgetAdresiniIsle);
      _widgetAbonelik = HomeWidget.widgetClicked.listen(_widgetAdresiniIsle);
    } catch (e) {
      debugPrint('Widget dinleyicisi kurulamadı: $e');
    }
  }

  void _widgetAdresiniIsle(Uri? uri) {
    if (uri == null || uri.scheme != 'alfred') return;
    final List<String> parca = uri.pathSegments;
    if (parca.isEmpty) return;
    if (parca.first == 'not' && parca.length > 1) {
      _kisayoluIsle('not:${parca[1]}');
    } else if (parca.first == 'etkinlik' && parca.length > 2) {
      _kisayoluIsle('etkinlik:${parca[1]}:${parca[2]}');
    } else {
      _kisayoluIsle(parca.first);
    }
  }

  // Widget'tan atılan tikler (uygulama kapalıyken kuyruğa yazılır) uygulama açılınca işlenir
  // Bildirimdeki "Yapıldı" düğmesiyle kuyruğa yazılan işaretlemeleri ajandaya uygular
  Future<void> _bildirimYapildilariUygula() async {
    if (kIsWeb || !_yuklendi || !mounted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final dynamic ham = jsonDecode(prefs.getString('yapildi_bekleyen') ?? '[]');
      if (ham is! List || ham.isEmpty) return;
      final List<Map<String, dynamic>> kalan = [];
      bool degisti = false;
      for (final dynamic o in ham) {
        if (o is! Map) continue;
        final Map<String, dynamic> oge = Map<String, dynamic>.from(o);
        final String pr = (oge['pr'] as String?) ?? '';
        if (pr.isNotEmpty && pr != aktifProfilId) {
          kalan.add(oge); // başka profile ait; o profil açılınca uygulanır
          continue;
        }
        final Etkinlik? e = etkinlikListesi.where((x) => x.id == oge['e']).firstOrNull;
        final String anahtar = (oge['a'] as String?) ?? '';
        if (e != null && anahtar.isNotEmpty && !e.yapilanlar.contains(anahtar)) {
          e.yapilanlar.add(anahtar);
          degisti = true;
        }
      }
      await prefs.setString('yapildi_bekleyen', jsonEncode(kalan));
      if (degisti && mounted) {
        setState(() {});
        _bildirimleriYenile();
      }
    } catch (e) {
      debugPrint('Bildirimden yapıldı uygulanamadı: $e');
    }
  }

  Future<void> _widgetBekleyenleriUygula() async {
    if (kIsWeb || !_yuklendi) return;
    try {
      final String? ham = await HomeWidget.getWidgetData<String>('w_bekleyen');
      if (ham == null || ham.length < 3) return;
      final List<dynamic> kuyruk = jsonDecode(ham) as List<dynamic>;
      if (kuyruk.isEmpty) return;
      bool notDegisti = false;
      setState(() {
        for (final dynamic ogeHam in kuyruk) {
          final Map<String, dynamic> oge = Map<String, dynamic>.from(ogeHam as Map);
          final List<String> p = (oge['k'] as String).split('|');
          if (p.length < 3) continue;
          final bool yapildi = oge['d'] == true;
          final String id = p[1];
          final String geri = p.sublist(2).join('|');
          if (p[0] == 'e') {
            if (id.startsWith('not_')) {
              final NotKaydi? n = _notBul(id.substring(4));
              if (n != null) {
                n.tamamlandi = yapildi;
                if (n.liste) {
                  for (final m in n.maddeler) {
                    m.tamam = yapildi;
                  }
                }
                notDegisti = true;
              }
            } else {
              final Etkinlik? e = etkinlikListesi.where((x) => x.id == id).firstOrNull;
              if (e != null) {
                if (yapildi) {
                  if (!e.yapilanlar.contains(geri)) e.yapilanlar.add(geri);
                } else {
                  e.yapilanlar.remove(geri);
                }
                notDegisti = true;
              }
            }
          } else if (p[0] == 'm') {
            final NotKaydi? n = _notBul(id);
            final NotMaddesi? m = n?.maddeler.where((x) => x.id == geri).firstOrNull;
            if (n != null && m != null) {
              m.tamam = yapildi;
              if (n.maddeler.isNotEmpty) n.tamamlandi = n.maddeler.every((x) => x.tamam);
              notDegisti = true;
            }
          }
        }
      });
      await HomeWidget.saveWidgetData<String>('w_bekleyen', '[]');
      if (notDegisti) _bildirimleriYenile();
      _sonWidgetJson = ''; // kuyruk boşaldı; widget'ı kesin yenile
      await _kaydetHemen();
      await _widgetVerisiniGuncelle();
    } catch (e) {
      debugPrint('Widget kuyruğu işlenemedi: $e');
    }
  }

  // Widget'ın göstereceği veriyi (önümüzdeki 8 günün etkinlikleri, notlar, bu ayın giderleri) yollar
  Future<void> _widgetVerisiniGuncelle() async {
    if (kIsWeb || !_yuklendi) return;
    try {
      final DateTime simdi = DateTime.now();
      final DateFormat tf = DateFormat('yyyy-MM-dd');
      final List<Map<String, dynamic>> gunler = [];
      for (int i = 0; i < 8; i++) {
        final DateTime gun = DateTime(simdi.year, simdi.month, simdi.day + i);
        gunler.add({
          'd': tf.format(gun),
          'e': _gunOlaylari(gun)
              .map((o) => {
                    'i': o.etkinlik.id,
                    'a': o.anahtar,
                    't': o.gunBoyu ? 'Tüm gün' : o.etkinlik.zamanlar[o.zamanIndex].saatMetni,
                    'b': o.etkinlik.baslik,
                    'x': o.etkinlik.yapilanlar.contains(o.anahtar),
                  })
              .toList(),
        });
      }

      // Widget'ta en yeni not en üstte görünür (sabitlenenler Kotlin tarafında başa alınır)
      final List<NotKaydi> yeniUstte = List<NotKaydi>.from(notListesi)..sort((a, b) => b.duzenleme.compareTo(a.duzenleme));
      final List<Map<String, dynamic>> notlar = yeniUstte
          .take(200)
          .map((n) => {
                'i': n.id,
                'b': _notBasligi(n),
                'l': n.liste,
                's': n.sabit,
                'm': n.liste ? n.maddeler.take(150).map((m) => {'i': m.id, 't': m.metin, 'x': m.tamam}).toList() : <Map<String, dynamic>>[],
                'y': n.liste ? '' : (n.metin.length > 3000 ? n.metin.substring(0, 3000) : n.metin),
              })
          .toList();

      final String ay = DateFormat('yyyy-MM').format(simdi);
      double kalanToplam = 0;
      double odenenToplam = 0;
      final List<Map<String, dynamic>> giderler = [];
      for (final k in _ayKalemleri(ay)) {
        if (k.isGelir) continue;
        bool odendi;
        double tutar;
        if (_normalGider(k)) {
          final double kalan = _kalemKalani(k, ay);
          odendi = kalan <= 0.009;
          tutar = odendi ? _kalemBorcu(k, ay) : kalan;
          if (odendi) {
            odenenToplam += tutar;
          } else {
            kalanToplam += tutar;
          }
        } else {
          odendi = k.odendiMi;
          tutar = k.tutar;
          if (odendi) {
            odenenToplam += tutar;
          } else {
            kalanToplam += tutar;
          }
        }
        giderler.add({'b': k.baslik.isEmpty ? k.kategori : k.baslik, 't': _tl(tutar), 'x': odendi, 'z': k.tarih.millisecondsSinceEpoch});
      }
      giderler.sort((a, b) {
        final int c = (a['x'] == true ? 1 : 0).compareTo(b['x'] == true ? 1 : 0);
        return c != 0 ? c : (a['z'] as int).compareTo(b['z'] as int);
      });
      for (final g in giderler) {
        g.remove('z');
      }

      final String json = jsonEncode({
        'g': gunler,
        'n': notlar,
        'f': {
          'ay': _ayAdi(ay),
          'kalan': _tl(kalanToplam),
          'odenen': _tl(odenenToplam),
          'k': giderler.take(60).toList(),
        },
      });
      if (json == _sonWidgetJson) return;
      await HomeWidget.saveWidgetData<String>('w_veri', json);
      _sonWidgetJson = json;
      debugPrint('Widget verisi yollandı (${json.length} karakter)');
      await HomeWidget.updateWidget(qualifiedAndroidName: _widgetSinifi);
    } catch (e) {
      debugPrint('Widget verisi yollanamadı: $e');
    }
  }

  // Ekranın desteklediği en yüksek yenileme hızını (ör. 120 Hz) ister; sistem isteği yok sayabilir
  Future<void> _yuksekYenilemeHiziniIste() async {
    if (kIsWeb) return;
    try {
      await FlutterDisplayMode.setHighRefreshRate();
      final DisplayMode aktif = await FlutterDisplayMode.active;
      debugPrint('Ekran modu: $aktif');
    } catch (e) {
      debugPrint('Yenileme hızı ayarlanamadı: $e');
    }
  }

  // Uygulama genelindeki (profilden bağımsız) ayarlar
  Future<void> _globalAyarlariKaydet() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('guvenilir_mod', bildirimGuvenilirMod);
    await prefs.setInt('yedek_hatirlatma_gun', yedekHatirlatmaGunu);
    await prefs.setBool('oto_yedek_foto', otoYedekFoto);
    await prefs.setBool('oto_yedek_acik', otoYedekAcik);
    await prefs.setInt('oto_yedek_gunu', otoYedekGunu);
    await prefs.setBool('hafta_ozeti_acik', haftaOzetiAcik);
    await prefs.setInt('erteleme_dk', ertelemeDk);
    await prefs.setInt('hafta_ozeti_gunu', haftaOzetiGunu);
    await prefs.setInt('hafta_ozeti_saati', haftaOzetiSaati);
    await prefs.setString('kategori_hafiza', jsonEncode(_kategoriHafizasi));
    await prefs.setBool('elle_yedek_foto', elleYedekFoto);
    await prefs.setString('ses_etkinlik', sesEtkinlik);
    await prefs.setString('ses_odeme', sesOdeme);
    await prefs.setBool('sessizda_cal', sessizdaCal);
    await prefs.setBool('titresim_acik', titresimAcik);
    await prefs.setBool('sabah_ozeti_acik', sabahOzetiAcik);
    await prefs.setInt('sabah_ozeti_saati', sabahOzetiSaati);
    await prefs.setInt('cop_suresi_gun', copSuresiGun);
    await prefs.setBool('uygulama_kilidi', uygulamaKilidiAcik);
    await prefs.setInt('kilit_bekleme_dk', kilitBeklemeDk);
    await prefs.setBool('ekran_gizle', ekranGizle);
  }

  // Yükleme hatası: true iken kayıt durdurulur, böylece okunamayan asıl veri üzerine yazılmaz
  bool _veriYuklemeHatasi = false;
  String? _yuklemeUyarisi;

  Future<void> _yuklemeUyarisiniGoster() async {
    final String? mesaj = _yuklemeUyarisi;
    if (mesaj == null || !mounted) return;
    _yuklemeUyarisi = null;
    final bool hata = _veriYuklemeHatasi;
    await showDialog(
      context: context,
      barrierDismissible: !hata,
      builder: (ctx) => AlertDialog(
        title: Text(hata ? 'Veri okunamadı' : 'Bazı kayıtlar okunamadı'),
        content: Text(mesaj),
        actions: [
          if (hata)
            TextButton(
              onPressed: () {
                _veriYuklemeHatasi = false;
                Navigator.pop(ctx);
              },
              child: const Text('Boş başla'),
            ),
          ElevatedButton(style: _anaDugmeStili, onPressed: () => Navigator.pop(ctx), child: Text(hata ? 'Şimdilik böyle kalsın' : 'Tamam')),
        ],
      ),
    );
  }

  // Okunamayan kayıt sayısı: veri yüklenirken bozuk kayıtlar tek tek atlanır ve sayılır
  int _okunamayanKayit = 0;

  List<T> _kayitlariOku<T>(dynamic ham, T Function(Map<String, dynamic> j) cevir) {
    final List<T> sonuc = [];
    if (ham is! List) return sonuc;
    for (final e in ham) {
      try {
        sonuc.add(cevir(Map<String, dynamic>.from(e as Map)));
      } catch (err) {
        _okunamayanKayit++;
        debugPrint('Bir kayıt okunamadı: $err');
      }
    }
    return sonuc;
  }

  // Kayıtlı (veya yedekteki) bir profil verisini uygulamaya yükler.
  // Önce her şey geçici değişkenlere okunur, en sonda uygulanır; yarım kalmış bir yükleme olmaz.
  void _veriyiUygula(Map<String, dynamic> veri, {Profil? profil}) {
    if (profil == null) _notImzalari.clear();
    final bool gizlilik = veri['gizlilikModu'] ?? false;
    final String siralama = veri['siralama'] ?? 'tur';
    final bool siralamaArtan = veri['siralamaArtan'] ?? true;
    final List<KrediKarti> kartlar = _kayitlariOku<KrediKarti>(veri['kartlar'], (j) => KrediKarti.fromJson(j));
    final List<KrediBorcu> krediler = _kayitlariOku<KrediBorcu>(veri['krediler'], (j) => KrediBorcu.fromJson(j));
    final List<FinansKalemi> finans = _kayitlariOku<FinansKalemi>(veri['finans'], (j) => FinansKalemi.fromJson(j));
    final List<KartTaksiti> taksitler = _kayitlariOku<KartTaksiti>(veri['taksitler'], (j) => KartTaksiti.fromJson(j));
    List<EtkinlikTuru> turler = _kayitlariOku<EtkinlikTuru>(veri['etkinlikTurleri'], (j) => EtkinlikTuru.fromJson(j));
    if (turler.isEmpty) turler = varsayilanEtkinlikTurleri();
    turler = turSirasiniDuzenle(turler);
    final List<Etkinlik> etkinlikler = veri['etkinlikler'] != null
        ? _kayitlariOku<Etkinlik>(veri['etkinlikler'], (j) => Etkinlik.fromJson(j))
        : _kayitlariOku<Etkinlik>(veri['ajanda'], (j) => _eskiHatirlaticiyiCevir(Hatirlatici.fromJson(j))); // eski sürümdeki hatırlatıcılar
    final List<SabitOdeme> sabitler = _kayitlariOku<SabitOdeme>(veri['sabitler'], (j) => SabitOdeme.fromJson(j));

    // Notlar ve not kategorileri
    final List<NotKaydi> notlar = _kayitlariOku<NotKaydi>(veri['notlar'], (j) => NotKaydi.fromJson(j));
    final List<NotKaydi> arsivNotlari = _kayitlariOku<NotKaydi>(veri['notArsivi'], (j) => NotKaydi.fromJson(j));
    final List<NotKaydi> copN = _kayitlariOku<NotKaydi>(veri['copNotlari'], (j) => NotKaydi.fromJson(j));
    final List<Etkinlik> copE = _kayitlariOku<Etkinlik>(veri['copEtkinlikleri'], (j) => Etkinlik.fromJson(j));
    final DateTime copZamani = DateTime.now();
    for (final n in copN) {
      n.silinme ??= copZamani;
    }
    for (final e in copE) {
      e.silinme ??= copZamani;
    }
    final dynamic hamKategoriler = veri['notKategorileri'];
    final Map<String, String> eskiAdlar = {};
    List<EtkinlikTuru> kategoriler;
    if (hamKategoriler is List && hamKategoriler.isNotEmpty && hamKategoriler.first is Map) {
      kategoriler = _kayitlariOku<EtkinlikTuru>(hamKategoriler, (j) => EtkinlikTuru.fromJson(j));
    } else if (hamKategoriler is List && hamKategoriler.isNotEmpty) {
      // Eski sürümde kategoriler sadece isimdi
      final List<String> adlar = hamKategoriler.map((e) => e.toString()).toList();
      if (adlar.length == 3 && adlar[0] == 'Market' && adlar[1] == 'Ders' && adlar[2] == 'Genel') {
        kategoriler = varsayilanNotKategorileri();
        eskiAdlar['Market'] = 'market';
        eskiAdlar['Genel'] = 'genel';
      } else {
        kategoriler = adlar.map((a) => EtkinlikTuru(id: a, ad: a, ikon: 26, renk: 3)).toList();
      }
    } else if (hamKategoriler == null) {
      kategoriler = varsayilanNotKategorileri();
    } else {
      kategoriler = <EtkinlikTuru>[];
    }
    for (final n in notlar) {
      n.kategori = eskiAdlar[n.kategori] ?? n.kategori;
      if (!kategoriler.any((k) => k.id == n.kategori)) n.kategori = '';
    }

    // Ödeme hatırlatmaları (eski sürümde tek saat + gün listesi vardı)
    final bool finansBildirim = veri['finansBildirimAcik'] ?? true;
    List<FinansHatirlatma> finansHatirlatma;
    if (veri['finansHatirlatmalari'] != null) {
      finansHatirlatma = _kayitlariOku<FinansHatirlatma>(veri['finansHatirlatmalari'], (j) => FinansHatirlatma.fromJson(j));
    } else {
      final int eskiSaat = veri['finansBildirimSaati'] ?? 540;
      final List<int> eskiGunler = veri['finansBildirimGunleri'] == null ? [3, 0] : List<int>.from(veri['finansBildirimGunleri']);
      finansHatirlatma = eskiGunler.map((g) => FinansHatirlatma(g, eskiSaat)).toList();
    }
    final bool finansGecikme = veri['finansGecikmeBildirimi'] ?? true;
    final int finansGecikmeSaat = veri['finansGecikmeSaati'] ?? (veri['finansBildirimSaati'] ?? 540);
    final List<Hatirlatma> ozel = _kayitlariOku<Hatirlatma>(veri['ozelHatirlatmalar'], (j) => Hatirlatma.fromJson(j));

    final String notSiralama = veri['notSiralama'] ?? 'tarih';
    final bool notSiralamaArtan = veri['notSiralamaArtan'] ?? false;
    final String notGorunum = veri['notGorunum'] ?? 'notlar';
    final String ajandaSiralama = veri['ajandaSiralama'] ?? 'tur';
    final bool ajandaSiralamaArtan = veri['ajandaSiralamaArtan'] ?? true;

    // Hepsi okundu: şimdi uygula
    gizlilikModu = gizlilik;
    _siralama = siralama;
    _siralamaArtan = siralamaArtan;
    krediKartiListesi = kartlar;
    krediListesi = krediler;
    finansListesi = finans;
    kartTaksitListesi = taksitler;
    etkinlikTurleri = turler;
    etkinlikListesi = etkinlikler;
    sabitListesi = sabitler;
    notListesi = notlar;
    notArsivi = arsivNotlari;
    copNotlari = copN;
    copEtkinlikleri = copE;
    notKategorileri = kategoriler;
    _notSiralama = notSiralama;
    _notSiralamaArtan = notSiralamaArtan;
    _notGorunum = notGorunum;
    _ajandaSiralama = ajandaSiralama;
    _ajandaSiralamaArtan = ajandaSiralamaArtan;
    finansBildirimAcik = finansBildirim;
    finansHatirlatmalari = finansHatirlatma;
    finansGecikmeBildirimi = finansGecikme;
    finansGecikmeSaati = finansGecikmeSaat;
    ozelHatirlatmalar = ozel;

    // Eski sürümden kalan "ödendi" işaretlerini ödeme kaydına çevir
    for (final k in finansListesi) {
      if (_normalGider(k) && k.odendiMi && k.odemeler.isEmpty) {
        k.odemeler.add(KismiOdeme(ay: k.ayYilAnahtari, tutar: k.tutar, tarih: k.tarih));
      }
    }
    _dogumSenkron(profil);
  }

  // Profilde doğum günü girildiyse Ajanda'ya her yıl tekrarlanan bir etkinlik olarak eklenir (girilmediyse hiçbir şey eklenmez)
  void _dogumSenkron([Profil? profil]) {
    if (profiller.isEmpty) return;
    final Profil p = profil ?? _aktifProfil;
    final String id = 'dogum_${p.id}';
    final int i = etkinlikListesi.indexWhere((e) => e.id == id);
    final DateTime? d = p.dogumTarihi;
    if (d == null) {
      if (i >= 0) etkinlikListesi.removeAt(i);
      return;
    }
    final String baslik = 'Doğum günün kutlu olsun ${p.ad}!';
    final DateTime gun = DateTime(d.year, d.month, d.day);
    if (i >= 0) {
      final Etkinlik e = etkinlikListesi[i];
      e.baslik = baslik;
      if (!etkinlikTurleri.any((t) => t.id == e.turId)) e.turId = etkinlikTurleri.any((t) => t.id == 'dogum') ? 'dogum' : (etkinlikTurleri.isNotEmpty ? etkinlikTurleri.first.id : e.turId);
      e.baslangic = gun;
      e.tekrar = 'yil';
      e.tumGun = true;
    } else {
      etkinlikListesi.add(Etkinlik(
        id: id,
        baslik: baslik,
        turId: etkinlikTurleri.any((t) => t.id == 'dogum') ? 'dogum' : (etkinlikTurleri.any((t) => t.id == 'gorev') ? 'gorev' : (etkinlikTurleri.isNotEmpty ? etkinlikTurleri.first.id : 'gorev')),
        baslangic: gun,
        tumGun: true,
        tekrar: 'yil',
        hatirlatmalar: [Hatirlatma(0, 'gun', gunSaati: 540)],
        hatirlatmaGunSaati: 540,
      ));
    }
  }

  Future<void> _yukle() async {
    final prefs = await SharedPreferences.getInstance();

    // Profiller
    final String? profilMetni = prefs.getString('profiller');
    if (profilMetni != null) {
      try {
        profiller = (jsonDecode(profilMetni) as List).map((e) => Profil.fromJson(Map<String, dynamic>.from(e))).toList();
      } catch (e) {
      debugPrint('Profil listesi okunamadı: $e');
    }
    }
    if (profiller.isEmpty) profiller = [Profil(id: 'p1', ad: 'Profilim')];
    // Eski varsayılan ad "Şahsi Cüzdanım" artık "Profilim" (elle verilmiş diğer adlara dokunulmaz)
    for (final Profil pr in profiller) {
      if (pr.ad == 'Şahsi Cüzdanım') pr.ad = 'Profilim';
    }
    aktifProfilId = prefs.getString('aktif_profil') ?? profiller.first.id;
    if (!profiller.any((p) => p.id == aktifProfilId)) aktifProfilId = profiller.first.id;

    // Eski sürümden geçiş: tek profilli veriyi ilk profile taşı
    String? veriMetni = prefs.getString('veri_$aktifProfilId');
    if (veriMetni == null && profilMetni == null) {
      final String? eski = prefs.getString('uygulama_verisi');
      if (eski != null) {
        veriMetni = eski;
        try {
          final eskiVeri = jsonDecode(eski) as Map<String, dynamic>;
          final String? eskiAd = eskiVeri['hesapAdi'];
          if (eskiAd != null && eskiAd.isNotEmpty) profiller.first.ad = eskiAd;
        } catch (e) {
      debugPrint('Eski profil adı okunamadı: $e');
    }
        await prefs.setString('veri_${profiller.first.id}', eski);
        final String? eskiFoto = prefs.getString('profil_foto');
        if (eskiFoto != null) await prefs.setString('profil_foto_${profiller.first.id}', eskiFoto);
      }
    }
    if (veriMetni != null) {
      _okunamayanKayit = 0;
      try {
        _veriyiUygula(jsonDecode(veriMetni) as Map<String, dynamic>);
        if (_okunamayanKayit > 0) {
          await prefs.setString('veri_${aktifProfilId}_kurtarma', veriMetni);
          _yuklemeUyarisi = '$_okunamayanKayit kayıt okunamadı ve atlandı; diğer kayıtların yüklendi. Okunamayan verinin ham bir kopyası telefonda ayrıca saklandı.';
        }
      } catch (e) {
        debugPrint('Veri yüklenemedi: $e');
        await prefs.setString('veri_${aktifProfilId}_kurtarma', veriMetni);
        _veriYuklemeHatasi = true;
        _yuklemeUyarisi = 'Kayıtlı verin okunamadı. Verilerin korunması için kaydetme durduruldu ve ham bir kopya ayrıca saklandı. Bir yedekten geri yükleyebilir ya da "Boş başla" ile devam edebilirsin (boş başlarsan eski veri bu oturumda üzerine yazılır).';
      }
    }

    // Profil fotoğrafları
    for (final p in profiller) {
      final String? fotoMetni = prefs.getString('profil_foto_${p.id}');
      if (fotoMetni != null) {
        try {
          _profilFotolari[p.id] = base64Decode(fotoMetni);
        } catch (e) {
      debugPrint('Profil fotoğrafı okunamadı: $e');
    }
      }
    }

    // Genel ayarlar
    bildirimGuvenilirMod = prefs.getBool('guvenilir_mod') ?? true;
    yedekHatirlatmaGunu = prefs.getInt('yedek_hatirlatma_gun') ?? 14;
    otoYedekFoto = prefs.getBool('oto_yedek_foto') ?? false;
    otoYedekAcik = prefs.getBool('oto_yedek_acik') ?? true;
    final int kayitliOtoGun = prefs.getInt('oto_yedek_gunu') ?? 1;
    otoYedekGunu = (kayitliOtoGun == 2 || kayitliOtoGun == 3 || kayitliOtoGun == 7) ? kayitliOtoGun : 1;
    haftaOzetiAcik = prefs.getBool('hafta_ozeti_acik') ?? true;
    final int kayitliErteleme = prefs.getInt('erteleme_dk') ?? 10;
    ertelemeDk = const [5, 10, 15, 30, 60].contains(kayitliErteleme) ? kayitliErteleme : 10;
    final int kayitliHaftaGunu = prefs.getInt('hafta_ozeti_gunu') ?? 7;
    haftaOzetiGunu = (kayitliHaftaGunu >= 1 && kayitliHaftaGunu <= 7) ? kayitliHaftaGunu : 7;
    haftaOzetiSaati = prefs.getInt('hafta_ozeti_saati') ?? 960;
    _sonOtoYedek = DateTime.tryParse(prefs.getString('son_oto_yedek') ?? '');
    _sonOtoYedekHata = prefs.getString('son_oto_yedek_hata');
    try {
      final dynamic hafiza = jsonDecode(prefs.getString('kategori_hafiza') ?? '{}');
      if (hafiza is Map) _kategoriHafizasi = hafiza.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      _kategoriHafizasi = {};
    }
    elleYedekFoto = prefs.getBool('elle_yedek_foto') ?? true;
    final String? sesE = prefs.getString('ses_etkinlik');
    final String? sesO = prefs.getString('ses_odeme');
    if (sesE != null && bildirimSesleri.containsKey(sesE)) sesEtkinlik = sesE;
    if (sesO != null && bildirimSesleri.containsKey(sesO)) sesOdeme = sesO;
    sessizdaCal = prefs.getBool('sessizda_cal') ?? false;
    titresimAcik = prefs.getBool('titresim_acik') ?? true;
    sabahOzetiAcik = prefs.getBool('sabah_ozeti_acik') ?? true;
    sabahOzetiSaati = prefs.getInt('sabah_ozeti_saati') ?? 480;
    final int kayitliCop = prefs.getInt('cop_suresi_gun') ?? 14;
    copSuresiGun = (kayitliCop == 7 || kayitliCop == 30) ? kayitliCop : 14;
    final String? yedekMetni = prefs.getString('son_yedek');
    if (yedekMetni != null) _sonYedekTarihi = DateTime.tryParse(yedekMetni);
    final String? ilkMetni = prefs.getString('ilk_kullanim');
    if (ilkMetni != null) {
      _ilkKullanim = DateTime.tryParse(ilkMetni);
    } else {
      _ilkKullanim = DateTime.now();
      await prefs.setString('ilk_kullanim', _ilkKullanim!.toIso8601String());
    }

    // Etkinlik fotoğraflarının klasörü
    try {
      await _fotoDizini();
    } catch (e) {
      debugPrint('Fotoğraf klasörü hazırlanamadı: $e');
    }

    // Sabit ödemelerin bu aya kadarki kayıtlarını hazırla
    _sabitleriUret();

    if (!mounted) return;
    setState(() {
      _yuklendi = true;
    });
    _copuTemizle();
    // İlk açılışta: bildirimden açıldıysa ilgili yere git, izinleri iste, bildirimleri planla, gerekirse yedek öner
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _widgetVerisiniGuncelle(); // en başta: sonraki adımlar beklese bile widget verisi gitsin
      await _acilisBildiriminiIsle();
      await _bildirimIzinleriniKontrolEt(bildirimIste: true);
      _bildirimleriYenile();
      await _yuklemeUyarisiniGoster();
      await _yedekOnerisiniKontrolEt();
      _otomatikYedekAl();
      await _widgetBekleyenleriUygula();
      await _bildirimYapildilariUygula();
      _widgetVerisiniGuncelle();
      final String? bekleyen = _bekleyenKisayol;
      if (bekleyen != null && mounted) {
        _bekleyenKisayol = null;
        _kisayoluIsle(bekleyen);
      }
    });
  }

  // ---------- Renkler ve ikonlar ----------

  Color _turRengi(String anahtar) {
    final Color c = _turRengiTemel(anahtar);
    return koyuMod ? Color.lerp(c, Colors.white, 0.2)! : c;
  }

  Color _turRengiTemel(String anahtar) {
    switch (anahtar) {
      case 'Kredi Kartı':
      case 'Kredi Kartı Ekstresi':
      case 'Kredi Kartı Taksiti':
        return const Color(0xFFEF4444);
      case 'Market':
        return const Color(0xFF22C55E);
      case 'Fatura':
        return const Color(0xFFF97316);
      case 'Kira & Ev':
        return const Color(0xFF14B8A6);
      case 'Kredi':
        return const Color(0xFFF59E0B);
      case 'Konut':
        return const Color(0xFF3B82F6);
      case 'Taşıt':
        return const Color(0xFF8B5CF6);
      case 'İhtiyaç':
        return const Color(0xFFEAB308);
      case 'Ticari':
        return const Color(0xFF06B6D4);
      case 'Maaş':
        return const Color(0xFF10B981);
      case 'Ek Gelir':
        return const Color(0xFF34D399);
      case 'Yatırım':
        return const Color(0xFF059669);
      case 'Kira Geliri':
        return const Color(0xFF2DD4BF);
      default:
        const List<Color> palet = [
          Color(0xFFEC4899),
          Color(0xFF6366F1),
          Color(0xFF84CC16),
          Color(0xFF0EA5E9),
          Color(0xFFA855F7),
          Color(0xFFF43F5E),
        ];
        int toplam = 0;
        for (final kod in anahtar.codeUnits) {
          toplam += kod;
        }
        return palet[toplam % palet.length];
    }
  }

  // Gelir kategorileri her zaman yeşil tonlarında: özel gelir kategorileri de bu ailede kalır
  Color _gelirKategoriRengi(String kategori) {
    switch (kategori) {
      case 'Maaş':
      case 'Ek Gelir':
      case 'Yatırım':
      case 'Kira Geliri':
        return _turRengi(kategori);
      default:
        const List<Color> yesilPalet = [
          Color(0xFF16A34A),
          Color(0xFF0D9488),
          Color(0xFF65A30D),
          Color(0xFF0891B2),
        ];
        int toplam = 0;
        for (final kod in kategori.codeUnits) {
          toplam += kod;
        }
        return yesilPalet[toplam % yesilPalet.length];
    }
  }

  // Kategori rengi: gelirse yeşil aile, giderse tür rengi
  Color _renk(String kategori, {bool gelir = false}) => gelir ? _gelirKategoriRengi(kategori) : _turRengi(kategori);

  Color _pastel(Color c) => Color.alphaBlend(c.withValues(alpha: koyuMod ? 0.24 : 0.13), yuzey);

  Color _koyu(Color c) => (koyuMod ? Color.lerp(c, Colors.white, 0.45) : Color.lerp(c, Colors.black, 0.4)) ?? c;

  Color _netRengi(double v) => v < 0 ? giderRengi : anaRenk;

  IconData _kategoriIkonuGetir(String kategoriAdi) {
    switch (kategoriAdi) {
      case 'Kredi Kartı':
      case 'Kredi Kartı Ekstresi':
        return Icons.credit_card;
      case 'Kredi':
        return Icons.account_balance;
      case 'Market':
        return Icons.shopping_cart;
      case 'Fatura':
        return Icons.receipt_long;
      case 'Kira & Ev':
        return Icons.home;
      default:
        return Icons.category;
    }
  }

  IconData _gelirIkonu(String kategori) {
    switch (kategori) {
      case 'Maaş':
        return Icons.work_outline;
      case 'Ek Gelir':
        return Icons.add_circle_outline;
      case 'Yatırım':
        return Icons.trending_up;
      case 'Kira Geliri':
        return Icons.house_outlined;
      default:
        return Icons.payments_outlined;
    }
  }

  IconData _krediIkonuGetir(String tur) {
    switch (tur) {
      case 'Konut':
        return Icons.home;
      case 'Taşıt':
        return Icons.directions_car;
      case 'İhtiyaç':
        return Icons.account_balance_wallet;
      case 'Ticari':
        return Icons.business;
      default:
        return Icons.account_balance;
    }
  }

  // ---------- Genel yardımcılar ----------

  String _tl(double v) => '${NumberFormat('#,##0.00', 'tr_TR').format(v)}₺';

  String _para(double v) => gizlilikModu ? '***' : _tl(v);

  // Metin kutusuna yazılacak sade sayı (5000 veya 5000,50)
  String _sayiMetni(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2).replaceAll('.', ',');

  String _ayAnahtari(DateTime d) => DateFormat('yyyy-MM').format(d);

  String _ayAdi(String ay, {bool kisa = false}) => DateFormat(kisa ? 'MMM yyyy' : 'MMMM yyyy', 'tr_TR').format(DateTime.parse('$ay-01'));

  Map<String, bool> _gecmisAylariOtomatikIsaretle(DateTime baslangicTarihi, int toplamTaksit) {
    Map<String, bool> harita = {};
    DateTime simdi = DateTime.now();
    DateTime simdikiAyBasi = DateTime(simdi.year, simdi.month, 1);

    for (int i = 0; i < toplamTaksit; i++) {
      DateTime taksitAyi = DateTime(baslangicTarihi.year, baslangicTarihi.month + i, 1);
      // Geçmiş aylar ödenmiş sayılır, bu ay ve sonrası ödenmemiş kalır
      harita[_ayAnahtari(taksitAyi)] = taksitAyi.isBefore(simdikiAyBasi);
    }
    return harita;
  }

  // Başlangıç tarihi veya taksit sayısı değişince ödeme haritasını yeniden kurar.
  // Daha önce işaretlenen aylar korunur, yeni eklenen geçmiş aylar ödenmiş sayılır.
  Map<String, bool> _odenenAylariYenidenHesapla(Map<String, bool> eski, DateTime baslangic, int toplam) {
    final yeni = _gecmisAylariOtomatikIsaretle(baslangic, toplam);
    for (final anahtar in yeni.keys.toList()) {
      if (eski.containsKey(anahtar)) {
        yeni[anahtar] = eski[anahtar] ?? false;
      }
    }
    return yeni;
  }

  // Sadece borcun geçerli aralığındaki ödenmiş ayları sayar
  int _odenenSayisi(Map<String, bool> harita, DateTime baslangic, int toplam) {
    int sayi = 0;
    for (int i = 0; i < toplam; i++) {
      final anahtar = _ayAnahtari(DateTime(baslangic.year, baslangic.month + i, 1));
      if (harita[anahtar] == true) sayi++;
    }
    return sayi;
  }

  int _ayFarki(DateTime baslangic, [String? ay]) {
    DateTime secilen = DateTime.parse('${ay ?? _secilenAyYil}-01');
    return (secilen.year - baslangic.year) * 12 + secilen.month - baslangic.month;
  }

  // Gün sayısını ayın son gününe sınırlar (ör. 31 seçilip ay 30 çekiyorsa)
  int _gunSinirla(String gunStr, int aySonu) {
    int gun = int.tryParse(gunStr) ?? 1;
    if (gun < 1) gun = 1;
    if (gun > aySonu) gun = aySonu;
    return gun;
  }

  String _bitisAyiHesapla(DateTime baslangicTarihi, int toplamTaksit, {bool kisa = false}) {
    try {
      DateTime bitis = DateTime(baslangicTarihi.year, baslangicTarihi.month + toplamTaksit - 1, 1);
      return DateFormat(kisa ? 'MMM yyyy' : 'MMMM yyyy', 'tr_TR').format(bitis);
    } catch (e) {
      return '';
    }
  }

  String _formatliSonOdemeMetni(String gunStr) {
    try {
      DateTime dt = DateTime.parse('$_secilenAyYil-01');
      String ayAdi = DateFormat('MMMM', 'tr_TR').format(dt);
      String yil = DateFormat('yyyy', 'tr_TR').format(dt);
      return 'Son Ödeme: $gunStr $ayAdi $yil';
    } catch (e) {
      return 'Son Ödeme: Her ayın $gunStr\'i';
    }
  }

  List<KartTaksiti> _kartaAitTaksitleriGetir(String kartId, [String? ay]) {
    return kartTaksitListesi.where((t) {
      if (t.kartId != kartId) return false;
      DateTime baslangic = DateTime.parse('${t.baslangicAyYil}-01');
      int fark = _ayFarki(baslangic, ay);
      return fark >= 0 && fark < t.toplamTaksit;
    }).toList();
  }

  // Taksitlerin toplamı o ayın ekstresini aşamaz. Sorun varsa kullanıcıya gösterilecek mesajı döndürür.
  String? _taksitEkstreHatasi({required String kartId, required String baslangicAy, required int toplam, required double aylik, String? haricTaksitId}) {
    final DateTime bas = DateTime.parse('$baslangicAy-01');
    for (int i = 0; i < toplam; i++) {
      final String ay = _ayAnahtari(DateTime(bas.year, bas.month + i, 1));
      final FinansKalemi? ekstre = finansListesi.where((k) => !k.isGelir && k.kategori == 'Kredi Kartı Ekstresi' && k.kartId == kartId && k.ayYilAnahtari == ay).firstOrNull;
      if (ekstre == null) continue;
      final double diger = _kartaAitTaksitleriGetir(kartId, ay).where((t) => t.id != haricTaksitId).fold(0.0, (s, t) => s + t.aylikTutar);
      if (diger + aylik > ekstre.tutar + 0.009) {
        final String kartAdi = krediKartiListesi.where((k) => k.id == kartId).firstOrNull?.kartAdi ?? 'kart';
        return '${_ayAdi(ay)} ayında $kartAdi ekstresi ${_tl(ekstre.tutar)}. Bu taksitle birlikte taksit toplamı ${_tl(diger + aylik)} olur ve ekstreyi aşar. Önce ekstre tutarını güncelle ya da taksit tutarını düşür.';
      }
    }
    return null;
  }

  List<FinansKalemi> _kartaAitEkstreler(List<FinansKalemi> filtrelenmis, String kartId) {
    return filtrelenmis.where((i) => !i.isGelir && i.kategori == 'Kredi Kartı Ekstresi' && i.kartId == kartId).toList();
  }

  bool _krediBuAyAktifMi(KrediBorcu kredi, [String? ay]) {
    int fark = _ayFarki(kredi.baslangicTarihi, ay);
    return fark >= 0 && fark < kredi.toplamTaksit;
  }

  // ---------- Normal giderlerin ödemesi ve devreden borç ----------

  // Normal gider: gelir ve kart ekstresi dışındaki her şey (Market, Fatura, özel...)
  bool _normalGider(FinansKalemi k) => !k.isGelir && k.kategori != 'Kredi Kartı Ekstresi';

  double _kalemOncekiOdenen(FinansKalemi k, String ay) => k.odemeler.where((o) => o.ay.compareTo(ay) < 0).fold(0.0, (s, o) => s + o.tutar);

  double _kalemBuAyOdenen(FinansKalemi k, String ay) => k.odemeler.where((o) => o.ay == ay).fold(0.0, (s, o) => s + o.tutar);

  // Bu aya giren borç (önceki aylarda ödenenler düşülmüş)
  double _kalemBorcu(FinansKalemi k, String ay) => math.max(0.0, k.tutar - _kalemOncekiOdenen(k, ay));

  double _kalemKalani(FinansKalemi k, String ay) => math.max(0.0, _kalemBorcu(k, ay) - _kalemBuAyOdenen(k, ay));

  // Bir ayda görünen kalemler: o ayın kalemleri + önceki aylardan tamamı ödenmeden devreden giderler
  List<FinansKalemi> _ayKalemleri(String ay) {
    return finansListesi.where((k) {
      if (k.ayYilAnahtari == ay) return true;
      if (!_normalGider(k)) return false;
      if (k.ayYilAnahtari.compareTo(ay) > 0) return false;
      return _kalemOncekiOdenen(k, ay) < k.tutar - 0.009;
    }).toList();
  }

  // ---------- Kart ekstresi ve taksitler ----------

  // Ekstre ödenince o ayın taksitleri de ödenmiş olur
  void _ekstreTaksitleriniGuncelle(FinansKalemi e, bool? durum) {
    final DateTime simdi = DateTime.now();
    final bool gecmisAy = DateTime.parse('${e.ayYilAnahtari}-01').isBefore(DateTime(simdi.year, simdi.month, 1));
    for (final t in kartTaksitListesi.where((t) => t.kartId == e.kartId)) {
      final int fark = _ayFarki(DateTime.parse('${t.baslangicAyYil}-01'), e.ayYilAnahtari);
      if (fark >= 0 && fark < t.toplamTaksit) {
        t.odenenAylar[e.ayYilAnahtari] = durum ?? gecmisAy;
      }
    }
  }

  void _ekstreDurumDegistir(FinansKalemi e) {
    setState(() {
      e.odendiMi = !e.odendiMi;
      _ekstreTaksitleriniGuncelle(e, e.odendiMi);
    });
  }

  void _krediDurumDegistir(KrediBorcu kredi) {
    setState(() {
      bool mevcut = kredi.odenenAylar[_secilenAyYil] ?? false;
      kredi.odenenAylar[_secilenAyYil] = !mevcut;
    });
  }

  // Silme işlemini geri alınabilir yapar: silmeden önce etkilenen listelerin kopyası alınır,
  // altta "Geri al" çubuğu çıkar. Geri alınmazsa (çubuk kapanınca) fotoğraf dosyaları da silinir.
  void _geriAlliSil(String mesaj, List<String> anahtarlar, VoidCallback sil, {List<String> fotolar = const []}) {
    final Map<String, dynamic> simdi = _veriHaritasi();
    final Map<String, dynamic> once = {for (final k in anahtarlar) k: jsonDecode(jsonEncode(simdi[k]))};
    sil();
    if (!mounted) {
      for (final f in fotolar) {
        _fotoSil(f);
      }
      return;
    }
    final ScaffoldMessengerState gonderici = ScaffoldMessenger.of(context);
    gonderici.hideCurrentSnackBar();
    bool geriAlindi = false;
    gonderici
        .showSnackBar(
          SnackBar(
            content: Text(mesaj),
            duration: const Duration(seconds: 4),
            persist: false,
            showCloseIcon: true,
            action: SnackBarAction(
              label: 'Geri al',
              onPressed: () {
                geriAlindi = true;
                if (!mounted) return;
                final Map<String, dynamic> guncel = Map<String, dynamic>.from(jsonDecode(jsonEncode(_veriHaritasi())) as Map);
                for (final k in anahtarlar) {
                  guncel[k] = once[k];
                }
                setState(() => _veriyiUygula(guncel));
                _bildirimleriYenile();
              },
            ),
          ),
        )
        .closed
        .then((_) {
      if (geriAlindi) return;
      for (final f in fotolar) {
        _fotoSil(f);
      }
    });
  }

  void _kalemSil(String id) {
    _geriAlliSil('Kayıt silindi', ['finans', 'taksitler'], () {
      setState(() {
        final k = finansListesi.where((x) => x.id == id).firstOrNull;
        if (k != null && k.kategori == 'Kredi Kartı Ekstresi') {
          _ekstreTaksitleriniGuncelle(k, null);
        }
        finansListesi.removeWhere((item) => item.id == id);
      });
    });
  }

  void _taksitSil(String id) {
    _geriAlliSil('Taksit silindi', ['taksitler'], () {
      setState(() {
        kartTaksitListesi.removeWhere((item) => item.id == id);
      });
    });
  }

  void _krediSil(String id) {
    _geriAlliSil('Kredi silindi', ['krediler'], () {
      setState(() {
        krediListesi.removeWhere((item) => item.id == id);
      });
    });
  }

  // Kartı silince ona bağlı taksit ve ekstreler de silinir
  void _kartSil(String kartId) {
    _geriAlliSil('Kart silindi', ['kartlar', 'taksitler', 'finans'], () {
      setState(() {
        krediKartiListesi.removeWhere((k) => k.id == kartId);
        kartTaksitListesi.removeWhere((t) => t.kartId == kartId);
        finansListesi.removeWhere((i) => i.kartId == kartId);
      });
    });
  }

  // ---------- Sabit ödemeler ----------

  // Sabit ödemelerin aylık kayıtlarını oluşturur (bugüne veya seçili aya kadar)
  void _sabitleriUret() {
    if (sabitListesi.isEmpty) return;
    final String bugunAy = _ayAnahtari(DateTime.now());
    final String sonAy = _secilenAyYil.compareTo(bugunAy) > 0 ? _secilenAyYil : bugunAy;
    final mevcutIdler = finansListesi.map((k) => k.id).toSet();

    for (final s in sabitListesi) {
      DateTime ay = DateTime.parse('${s.baslangicAyYil}-01');
      int guvenlik = 0;
      while (guvenlik < 600) {
        final String a = _ayAnahtari(ay);
        if (a.compareTo(sonAy) > 0) break;
        final String? bitis = s.bitisAyYil;
        if (bitis != null && a.compareTo(bitis) > 0) break;

        final String id = '${s.id}_$a';
        if (!s.atlananAylar.contains(a) && !mevcutIdler.contains(id)) {
          final int aySonu = DateTime(ay.year, ay.month + 1, 0).day;
          final double tutar = s.tutarAy(a);
          final kalem = FinansKalemi(
            id: id,
            baslik: s.baslik,
            tutar: tutar,
            kategori: s.kategori,
            isGelir: s.isGelir,
            tarih: DateTime(ay.year, ay.month, _gunSinirla(s.gun, aySonu)),
            ayYilAnahtari: a,
            sabitId: s.id,
          );
          // Geçmiş aylardaki sabit giderler ödenmiş sayılır
          if (!s.isGelir && a.compareTo(bugunAy) < 0) {
            kalem.odemeler.add(KismiOdeme(ay: a, tutar: tutar, tarih: kalem.tarih));
          }
          finansListesi.add(kalem);
          mevcutIdler.add(id);
        }
        ay = DateTime(ay.year, ay.month + 1, 1);
        guvenlik++;
      }
    }
  }

  SabitOdeme? _sabitBul(String? id) => id == null ? null : sabitListesi.where((s) => s.id == id).firstOrNull;

  // Sabit ödemenin sadece bir ayını siler (diğer aylar devam eder)
  void _sabitAyiSil(FinansKalemi k) {
    final s = _sabitBul(k.sabitId);
    _silmeOnayiGoster(context, 'Sadece ${_ayAdi(k.ayYilAnahtari)} kaydı silinecek. Bu sabit ${k.isGelir ? 'gelir' : 'ödeme'} diğer aylarda devam eder.', () {
      _geriAlliSil('Kayıt silindi', ['sabitler', 'finans'], () {
        setState(() {
          if (s != null && !s.atlananAylar.contains(k.ayYilAnahtari)) s.atlananAylar.add(k.ayYilAnahtari);
          finansListesi.removeWhere((x) => x.id == k.id);
        });
      });
    });
  }

  Future<void> _sabitSilDialog(SabitOdeme s) async {
    final String ay = _secilenAyYil;
    final bool durdurulabilir = ay.compareTo(s.baslangicAyYil) > 0;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sabit Ödemeyi Kaldır'),
        content: Text(
          durdurulabilir
              ? '"${s.baslik}" için ne yapmak istersin?\n\nDurdurursan ${_ayAdi(ay)} ve sonrasında eklenmez, geçmiş aylardaki kayıtların korunur.'
              : '"${s.baslik}" ve tüm aylardaki kayıtları silinecek.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _geriAlliSil('Sabit ödeme silindi', ['sabitler', 'finans'], () {
                setState(() {
                  sabitListesi.removeWhere((x) => x.id == s.id);
                  finansListesi.removeWhere((k) => k.sabitId == s.id);
                });
              });
            },
            child: const Text('Tamamen Sil', style: TextStyle(color: Colors.red)),
          ),
          if (durdurulabilir)
            ElevatedButton(
              style: _anaDugmeStili,
              onPressed: () {
                Navigator.pop(ctx);
                _geriAlliSil('Sabit ödeme durduruldu', ['sabitler', 'finans'], () {
                  setState(() {
                    final DateTime d = DateTime.parse('$ay-01');
                    s.bitisAyYil = _ayAnahtari(DateTime(d.year, d.month - 1, 1));
                    finansListesi.removeWhere((k) => k.sabitId == s.id && k.ayYilAnahtari.compareTo(ay) >= 0 && k.odemeler.isEmpty);
                  });
                });
              },
              child: const Text('Bu Aydan İtibaren Durdur'),
            ),
        ],
      ),
    );
  }

  void _aySeciciGoster() async {
    DateTime suan = DateTime.parse('$_secilenAyYil-01');
    final DateTime? secilen = await showDatePicker(
      context: context,
      initialDate: suan,
      firstDate: enEskiTarih,
      lastDate: enYeniTarih,
      helpText: 'Görüntülemek İstediğiniz Ayı Seçin',
    );
    if (!mounted) return;
    if (secilen != null) {
      setState(() {
        _secilenAyYil = _ayAnahtari(secilen);
      });
    }
  }

  // ---------- Hesaplamalar ----------

  // Finans ve Analiz sekmeleri bu tek fonksiyondan beslenir
  _Ozet _ozetHesapla(List<FinansKalemi> filtrelenmis, [String? ay]) {
    final String a = ay ?? _secilenAyYil;

    double toplamGelir = 0;
    double ekstreToplam = 0;
    double ekstreOdenen = 0;
    double digerToplam = 0;
    double digerOdenen = 0;

    for (final k in filtrelenmis) {
      if (k.isGelir) {
        toplamGelir += k.tutar;
      } else if (k.kategori == 'Kredi Kartı Ekstresi') {
        ekstreToplam += k.tutar;
        if (k.odendiMi) ekstreOdenen += k.tutar;
      } else {
        final double borc = _kalemBorcu(k, a);
        digerToplam += borc;
        digerOdenen += math.min(borc, _kalemBuAyOdenen(k, a));
      }
    }

    double aktifTaksitler = 0;
    double odenenTaksitler = 0;
    for (var kart in krediKartiListesi) {
      if (_kartaAitEkstreler(filtrelenmis, kart.id).isEmpty) {
        for (var taksit in _kartaAitTaksitleriGetir(kart.id, a)) {
          aktifTaksitler += taksit.aylikTutar;
          if (taksit.odenenAylar[a] == true) {
            odenenTaksitler += taksit.aylikTutar;
          }
        }
      }
    }

    double aktifKrediler = 0;
    double odenenKrediler = 0;
    for (var kredi in krediListesi) {
      if (_krediBuAyAktifMi(kredi, a)) {
        aktifKrediler += kredi.aylikTutar;
        if (kredi.odenenAylar[a] == true) {
          odenenKrediler += kredi.aylikTutar;
        }
      }
    }

    return _Ozet(
      toplamGelir: toplamGelir,
      toplamGider: digerToplam + ekstreToplam + aktifTaksitler + aktifKrediler,
      odenenGider: digerOdenen + ekstreOdenen + odenenTaksitler + odenenKrediler,
    );
  }

  // Kategori bazlı gider toplamları
  Map<String, double> _kategoriToplamlari(List<FinansKalemi> filtrelenmis) {
    final Map<String, double> m = {};
    for (var k in filtrelenmis.where(_normalGider)) {
      m[k.kategori] = (m[k.kategori] ?? 0) + _kalemBorcu(k, _secilenAyYil);
    }

    double kartToplam = 0;
    for (var kart in krediKartiListesi) {
      final ekstreler = _kartaAitEkstreler(filtrelenmis, kart.id);
      if (ekstreler.isNotEmpty) {
        kartToplam += ekstreler.fold(0.0, (s, e) => s + e.tutar);
      } else {
        kartToplam += _kartaAitTaksitleriGetir(kart.id).fold(0.0, (s, t) => s + t.aylikTutar);
      }
    }
    // Kartı silinmiş eski ekstreler
    kartToplam += filtrelenmis.where((k) => k.kategori == 'Kredi Kartı Ekstresi' && !krediKartiListesi.any((x) => x.id == k.kartId)).fold(0.0, (s, k) => s + k.tutar);
    if (kartToplam > 0) m['Kredi Kartı'] = kartToplam;

    double krediToplam = 0;
    for (var kredi in krediListesi) {
      if (_krediBuAyAktifMi(kredi)) krediToplam += kredi.aylikTutar;
    }
    if (krediToplam > 0) m['Kredi'] = krediToplam;

    return m;
  }

  // Kategori bazlı gelir toplamları
  Map<String, double> _gelirToplamlari(List<FinansKalemi> filtrelenmis) {
    final Map<String, double> m = {};
    for (var i in filtrelenmis.where((i) => i.isGelir)) {
      m[i.kategori] = (m[i.kategori] ?? 0) + i.tutar;
    }
    return m;
  }

  // ---------- Satır modelleri ----------

  _Odeme _kalemOdemesi(FinansKalemi k, int aySonu) {
    final String ay = _secilenAyYil;
    final sabit = _sabitBul(k.sabitId);
    final bool devreden = k.ayYilAnahtari.compareTo(ay) < 0;
    final Color renk = _renk(k.kategori, gelir: k.isGelir);

    if (k.isGelir) {
      return _Odeme(
        baslik: k.baslik.isEmpty ? k.kategori : k.baslik,
        alt: sabit != null ? '${k.kategori} • Her ay' : k.kategori,
        tutar: k.tutar,
        renk: renk,
        nokta: renk,
        ikon: _gelirIkonu(k.kategori),
        gun: _gunSinirla(k.tarih.day.toString(), aySonu),
        vade: k.tarih,
        odendi: false,
        gelir: true,
        onTap: () {
          if (sabit != null) {
            _sabitOdemeDialogGoster(mevcut: sabit);
          } else {
            _islemEkleDialogGoster(mevcut: k);
          }
        },
        onDelete: () {
          if (sabit != null) {
            _sabitAyiSil(k);
          } else {
            _silmeOnayiGoster(context, 'Bu geliri silmek istediğinize emin misiniz?', () => _kalemSil(k.id));
          }
        },
      );
    }

    final double borc = _kalemBorcu(k, ay);
    final double kalan = _kalemKalani(k, ay);
    final double toplamOdenen = k.tutar - kalan;
    final bool odendi = kalan <= 0.009;
    final bool kismi = !odendi && toplamOdenen > 0.009;

    final altParcalar = <String>[k.kategori];
    if (sabit != null) altParcalar.add('Her ay');
    if (kismi) altParcalar.add('Ödenen ${_para(toplamOdenen)} • Kalan ${_para(kalan)}');

    return _Odeme(
      baslik: k.baslik.isEmpty ? k.kategori : k.baslik,
      alt: altParcalar.join(' • '),
      tutar: borc,
      renk: renk,
      nokta: renk,
      ikon: _kategoriIkonuGetir(k.kategori),
      gun: devreden ? 1 : _gunSinirla(k.tarih.day.toString(), aySonu),
      vade: k.tarih,
      odendi: odendi,
      kismi: kismi,
      gecikmeGoster: !devreden,
      rozet: devreden && !odendi ? 'Devreden' : null,
      kalanTutar: kalan,
      onToggle: () => _odemeYapGoster(k),
      onTap: () {
        if (sabit != null) {
          _sabitOdemeDialogGoster(mevcut: sabit);
        } else {
          _islemEkleDialogGoster(mevcut: k);
        }
      },
      onDelete: () {
        if (sabit != null) {
          _sabitAyiSil(k);
        } else {
          _silmeOnayiGoster(context, 'Bu gideri silmek istediğinize emin misiniz?', () => _kalemSil(k.id));
        }
      },
    );
  }

  _Odeme _ekstreOdemesi(KrediKarti kart, FinansKalemi e, int taksitSayisi, int aySonu) {
    final DateTime dt = DateTime.parse('$_secilenAyYil-01');
    final int gun = _gunSinirla(kart.sonOdemeGunu, aySonu);
    final Color kartRengi = _turRengi('Kredi Kartı');
    return _Odeme(
      baslik: '${kart.kartAdi} Ekstresi',
      alt: taksitSayisi == 0 ? 'Kredi Kartı Ekstresi' : 'Ekstre • $taksitSayisi taksit dahil',
      tutar: e.tutar,
      renk: kartRengi,
      nokta: kartRengi,
      ikon: Icons.credit_card,
      gun: gun,
      vade: DateTime(dt.year, dt.month, gun),
      odendi: e.odendiMi,
      onToggle: () async => _ekstreDurumDegistir(e),
      onTap: () => _islemEkleDialogGoster(mevcut: e),
      onDelete: () => _silmeOnayiGoster(context, 'Bu ekstreyi silmek istediğinize emin misiniz?', () => _kalemSil(e.id)),
    );
  }

  // Taksitler ayrıca ödenemez: ekstre ödenince ödenmiş sayılır (onToggle yok)
  _Odeme _taksitOdemesi(KartTaksiti t, KrediKarti kart, int aySonu) {
    final DateTime dt = DateTime.parse('$_secilenAyYil-01');
    final DateTime baslangic = DateTime.parse('${t.baslangicAyYil}-01');
    final int kacinci = _ayFarki(baslangic) + 1;
    final int gun = _gunSinirla(kart.sonOdemeGunu, aySonu);
    final Color kartRengi = _turRengi('Kredi Kartı');
    return _Odeme(
      baslik: t.baslik,
      alt: 'Taksit $kacinci/${t.toplamTaksit} • Bitiş: ${_bitisAyiHesapla(baslangic, t.toplamTaksit, kisa: true)}',
      tutar: t.aylikTutar,
      renk: kartRengi,
      nokta: kartRengi,
      ikon: Icons.receipt_long,
      gun: gun,
      vade: DateTime(dt.year, dt.month, gun),
      odendi: t.odenenAylar[_secilenAyYil] == true,
      gecikmeGoster: false,
      onTap: () => _taksitDuzenleDialogGoster(t),
      onDelete: () => _silmeOnayiGoster(context, 'Bu taksiti silmek istediğinize emin misiniz?', () => _taksitSil(t.id)),
    );
  }

  _Odeme _krediOdemesi(KrediBorcu kredi, int aySonu) {
    final DateTime dt = DateTime.parse('$_secilenAyYil-01');
    final int kacinci = _ayFarki(kredi.baslangicTarihi) + 1;
    final int gun = _gunSinirla(kredi.sonOdemeGunu, aySonu);
    return _Odeme(
      baslik: kredi.krediAdi,
      alt: '${kredi.krediTuru} Kredisi • Taksit $kacinci/${kredi.toplamTaksit}',
      tutar: kredi.aylikTutar,
      renk: _turRengi(kredi.krediTuru),
      nokta: _turRengi('Kredi'),
      ikon: _krediIkonuGetir(kredi.krediTuru),
      gun: gun,
      vade: DateTime(dt.year, dt.month, gun),
      odendi: kredi.odenenAylar[_secilenAyYil] == true,
      onToggle: () async => _krediDurumDegistir(kredi),
      onTap: () => _krediDuzenleDialogGoster(kredi),
      onDelete: () => _silmeOnayiGoster(context, 'Bu krediyi silmek istediğinize emin misiniz?', () => _krediSil(kredi.id)),
    );
  }

  // ============================== BİLDİRİMLER ==============================

  AndroidFlutterLocalNotificationsPlugin? get _androidBildirim {
    try {
      return flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    } catch (_) {
      return null;
    }
  }

  // ============================== BİLDİRİM SESLERİ ==============================

  // Android'de ses ayarı bildirim kanalına bağlıdır; her ses/seçenek birleşimi ayrı bir kanaldır
  String _kanalKimligi(bool finans) {
    final String sesId = finans ? sesOdeme : sesEtkinlik;
    return '${finans ? 'odeme' : 'etkinlik'}_${sesId}_${sessizdaCal ? 'alarm' : 'bildirim'}_${titresimAcik ? 'titresimli' : 'titresimsiz'}';
  }

  AndroidNotificationSound? _bildirimSesi(String sesId) => sesId == 'sistem' ? null : RawResourceAndroidNotificationSound('alfred_$sesId');

  String _kanalAdi(bool finans) {
    final String sesAdi = (bildirimSesleri[finans ? sesOdeme : sesEtkinlik] ?? bildirimSesleri['sistem']!)[0];
    return '${finans ? 'Ödeme Hatırlatıcıları' : 'Etkinlik Hatırlatıcıları'} • $sesAdi';
  }

  AndroidNotificationDetails _bildirimDetayi(String metin, {bool finans = false, bool ertele = true, bool yapildi = false}) {
    return AndroidNotificationDetails(
      _kanalKimligi(finans),
      _kanalAdi(finans),
      channelDescription: finans ? 'Kart, kredi, fatura ve diğer ödemelerin son ödeme tarihi hatırlatmaları' : 'İlaç, randevu, doğum günü, not ve diğer etkinliklerin hatırlatmaları',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
      visibility: NotificationVisibility.public,
      playSound: true,
      sound: _bildirimSesi(finans ? sesOdeme : sesEtkinlik),
      enableVibration: titresimAcik,
      audioAttributesUsage: sessizdaCal ? AudioAttributesUsage.alarm : AudioAttributesUsage.notification,
      styleInformation: BigTextStyleInformation(metin),
      actions: ertele
          ? <AndroidNotificationAction>[
              // Uygulamayı açmadan, arka planda hemen erteler
              AndroidNotificationAction('ertele', 'Ertele (${ertelemeEtiketi(ertelemeDk)})', showsUserInterface: false, cancelNotification: false),
              if (yapildi) const AndroidNotificationAction('yapildi', 'Yapıldı olarak işaretle', showsUserInterface: false, cancelNotification: true),
            ]
          : null,
    );
  }

  // Bildirimdeki "Ertele" düğmesi: ayarlardaki süre kadar sonra aynı bildirimi tekrar gönderir (soru sormaz)
  Future<void> _bildirimErtele(int? bildirimNo, String payload) async {
    final DateTime? zaman = await bildirimiHemenErtele(bildirimNo, payload.isEmpty ? null : payload);
    if (zaman != null && mounted) _snack('${ertelemeEtiketi(ertelemeDk)} sonra tekrar hatırlatacağım (${DateFormat('HH:mm').format(zaman)}).');
  }

  // Seçili ses ayarlarına göre kanalları oluşturur, kullanılmayan eski kanalları siler
  Future<void> _bildirimKanallariniKur() async {
    final AndroidFlutterLocalNotificationsPlugin? android = _androidBildirim;
    if (android == null) return;
    final Set<String> aktif = {};
    for (final bool finans in [false, true]) {
      final String id = _kanalKimligi(finans);
      aktif.add(id);
      try {
        await android.createNotificationChannel(
          AndroidNotificationChannel(
            id,
            _kanalAdi(finans),
            description: finans ? 'Kart, kredi, fatura ve diğer ödemelerin son ödeme tarihi hatırlatmaları' : 'İlaç, randevu, doğum günü, not ve diğer etkinliklerin hatırlatmaları',
            importance: Importance.max,
            playSound: true,
            sound: _bildirimSesi(finans ? sesOdeme : sesEtkinlik),
            enableVibration: titresimAcik,
            audioAttributesUsage: sessizdaCal ? AudioAttributesUsage.alarm : AudioAttributesUsage.notification,
          ),
        );
      } catch (e) {
        debugPrint('Kanal kurulamadı: $e');
      }
    }
    try {
      final dynamic kanallar = await (android as dynamic).getNotificationChannels();
      if (kanallar is List) {
        for (final k in kanallar) {
          final String id = (k as dynamic).id.toString();
          final bool bizim = id.startsWith('etkinlik_') || id.startsWith('odeme_');
          if (bizim && !aktif.contains(id)) {
            await (android as dynamic).deleteNotificationChannel(id);
          }
        }
      }
    } catch (e) {
      debugPrint('Eski bildirim kanalları temizlenemedi: $e');
    }
  }

  // Seçilen sesi hemen bir bildirimle dinletir
  Future<void> _sesOnizle(bool finans) async {
    try {
      await _bildirimKanallariniKur();
      final String ad = (bildirimSesleri[finans ? sesOdeme : sesEtkinlik] ?? bildirimSesleri['sistem']!)[0];
      final String metin = 'Seçtiğin ses: $ad';
      await flutterLocalNotificationsPlugin.show(999002, 'Alfred • Ses önizleme', metin, NotificationDetails(android: _bildirimDetayi(metin, finans: finans)));
    } catch (e) {
      if (mounted) setState(() => _bildirimHatasi = 'Ses önizlemesi gösterilemedi: $e');
    }
  }

  // Ses seçim penceresi: dokunduğun ses hemen çalar, pencere açık kalır
  void _sesSecimiGoster(bool finans) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (c, setS) {
          final String secili = finans ? sesOdeme : sesEtkinlik;
          return Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.8),
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _pencereBasligi(sheetContext, Icons.music_note, finans ? 'Ödeme Hatırlatma Sesi' : 'Etkinlik Hatırlatma Sesi'),
                const Divider(),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final e in bildirimSesleri.entries)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(secili == e.key ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: secili == e.key ? anaRenk : Colors.grey),
                            title: Text(e.value[0], style: TextStyle(fontWeight: secili == e.key ? FontWeight.bold : FontWeight.w500)),
                            subtitle: Text(e.value[1], style: const TextStyle(fontSize: 12)),
                            onTap: () {
                              setState(() {
                                if (finans) {
                                  sesOdeme = e.key;
                                } else {
                                  sesEtkinlik = e.key;
                                }
                              });
                              setS(() {});
                              _globalAyarlariKaydet();
                              _bildirimleriYenile();
                              _sesOnizle(finans);
                            },
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('Dokunduğun ses bildirim olarak çalar. Telefon sessizdeyse duymayabilirsin; bunun için "Sessiz modda da çal"ı aç.', style: TextStyle(fontSize: 11, color: gri(600))),
                ),
                SizedBox(width: double.infinity, child: ElevatedButton(style: _anaDugmeStili, onPressed: () => Navigator.pop(sheetContext), child: const Text('Tamam'))),
              ],
            ),
          );
        },
      ),
    );
  }

  // Tam zamanında (exact) alarm kurulabiliyor mu?
  Future<bool> _tamZamanliAlarmMi() async {
    try {
      final dynamic sonuc = await (_androidBildirim as dynamic)?.canScheduleExactNotifications();
      return sonuc == true;
    } catch (_) {
      return false;
    }
  }

  // Bildirimlerin nasıl kurulacağı: güvenilir modda alarm saati gibi (uyku modundan etkilenmez)
  Future<AndroidScheduleMode> _planlamaModu() async {
    if (bildirimGuvenilirMod) return AndroidScheduleMode.alarmClock;
    final bool tam = await _tamZamanliAlarmMi();
    return tam ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle;
  }

  // Bildirim iznini kontrol eder, istenirse izin penceresini gösterir
  Future<void> _bildirimIzinleriniKontrolEt({bool bildirimIste = false}) async {
    final AndroidFlutterLocalNotificationsPlugin? android = _androidBildirim;
    if (android == null) return;
    bool? izin;
    try {
      izin = await android.areNotificationsEnabled();
      if (bildirimIste && izin != true) {
        final dynamic sonuc = await kilitsizCalistir(() async => await (android as dynamic).requestNotificationsPermission());
        izin = sonuc == true ? true : await android.areNotificationsEnabled();
      }
    } catch (e) {
      if (mounted) setState(() => _bildirimHatasi = 'İzin kontrolü yapılamadı: $e');
      return;
    }
    if (!mounted) return;
    // Değişmediyse yeniden çizme (Ayarlar'a kaydırırken tüm sayfaların kurulması takılma yapıyordu)
    if (_bildirimIzniVar != izin) setState(() => _bildirimIzniVar = izin);
  }

  Future<void> _sistemAyariniAc(String eylem, {String? veri, Map<String, dynamic>? parametreler}) async {
    try {
      await AndroidIntent(action: eylem, data: veri, arguments: parametreler).launch();
    } catch (e) {
      if (mounted) setState(() => _bildirimHatasi = 'Ayarlar açılamadı: $e');
    }
  }

  // "Bildirim izni" satırına dokununca: izin yoksa önce sorar, sonra telefonun bildirim ayarlarını açar
  Future<void> _bildirimAyarlariniAc() async {
    if (_bildirimIzniVar != true) {
      await _bildirimIzinleriniKontrolEt(bildirimIste: true);
      if (!mounted || _bildirimIzniVar == true) return;
    }
    await _sistemAyariniAc('android.settings.APP_NOTIFICATION_SETTINGS', parametreler: <String, dynamic>{'android.provider.extra.APP_PACKAGE': 'com.example.kisisel_asistan'});
  }

  Future<void> _pilAyarlariniAc() => _sistemAyariniAc('android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS');

  Future<void> _uygulamaBilgisiniAc() => _sistemAyariniAc('android.settings.APPLICATION_DETAILS_SETTINGS', veri: 'package:com.example.kisisel_asistan');

  // Kısa süre içinde art arda çağrılırsa tek seferde planlar
  void _bildirimleriYenile() {
    _bildirimZamanlayici?.cancel();
    _bildirimZamanlayici = Timer(const Duration(milliseconds: 700), _bildirimleriPlanla);
  }

  // Bildirimin küçük yazılı kısmı: etkinlik adı, ne kadar sonra, saat ve not
  String _bildirimGovdesi(_AjandaOlay o, Hatirlatma h) {
    final Etkinlik e = o.etkinlik;
    String cumle;
    if (h.deger == 0) {
      cumle = (h.birim == 'gun' || o.gunBoyu) ? 'Bugün' : 'Şimdi';
    } else {
      switch (h.birim) {
        case 'dakika':
          cumle = '${h.deger} dk sonra';
          break;
        case 'saat':
          cumle = '${h.deger} saat sonra';
          break;
        case 'gun':
          cumle = h.deger == 1 ? 'Yarın' : '${h.deger} gün sonra';
          break;
        case 'hafta':
          cumle = '${h.deger} hafta sonra';
          break;
        default:
          cumle = 'Yaklaşıyor';
      }
    }
    final parcalar = <String>[e.baslik, cumle];
    if (!o.gunBoyu) {
      final ZamanDilimi z = e.zamanlar[o.zamanIndex];
      parcalar.add(z.etiket.isEmpty ? z.saatMetni : '${z.etiket} ${z.saatMetni}');
    }
    if (e.notlar.isNotEmpty) {
      parcalar.add(e.notlar.length > 80 ? '${e.notlar.substring(0, 80)}…' : e.notlar);
    }
    return parcalar.join(' • ');
  }

  // Aktif profildeki etkinliklerin hatırlatma bildirimleri
  List<_PlanliBildirim> _ajandaAdaylari(DateTime simdi, String profilId, String? profilEtiketi) {
    final DateTime bugun = DateTime(simdi.year, simdi.month, simdi.day);
    final List<_PlanliBildirim> adaylar = [];
    for (final e in _tumEtkinlikler()) {
      if (e.hatirlatmalar.isEmpty) continue;
      final EtkinlikTuru tur = _turBul(e.turId);
      final NotKaydi? kaynakNot = _etkinlikNotu(e);
      final String turAdi = kaynakNot == null ? tur.ad : (kaynakNot.liste ? 'Liste' : 'Not');
      final String baslik = profilEtiketi == null ? turAdi : '$profilEtiketi • $turAdi';
      final List<_PlanliBildirim> etkinlikAdaylari = [];
      for (int i = 0; i < 400; i++) {
        final DateTime gun = DateTime(bugun.year, bugun.month, bugun.day + i);
        if (!_etkinlikGunuMu(e, gun)) continue;
        final int adet = (e.tumGun || e.zamanlar.isEmpty) ? 1 : e.zamanlar.length;
        for (int z = 0; z < adet; z++) {
          final o = _AjandaOlay(e, gun, z);
          if (e.yapilanlar.contains(o.anahtar)) continue; // tamamlananlar için hatırlatma yok
          for (final h in e.hatirlatmalar) {
            final DateTime t = _hatirlatmaZamani(o, h);
            if (!t.isAfter(simdi.add(const Duration(seconds: 5)))) continue;
            etkinlikAdaylari.add(_PlanliBildirim(t, baslik, _bildirimGovdesi(o, h), 'etkinlik|${e.id}|${DateFormat('yyyy-MM-dd').format(gun)}|$z|$profilId'));
          }
        }
      }
      // Her etkinlik için en yakın 80 hatırlatma (sık tekrarlananlar diğerlerini boğmasın)
      etkinlikAdaylari.sort((a, b) => a.zaman.compareTo(b.zaman));
      adaylar.addAll(etkinlikAdaylari.take(80));
    }
    adaylar.sort((a, b) => a.zaman.compareTo(b.zaman));
    return adaylar.take(200).toList();
  }

  // Aktif profildeki ödenmemiş ödemelerin son ödeme tarihine göre hatırlatma bildirimleri
  List<_PlanliBildirim> _finansAdaylari(DateTime simdi, String profilId, String? profilEtiketi) {
    final List<_PlanliBildirim> sonuc = [];
    final DateTime bugun = DateTime(simdi.year, simdi.month, simdi.day);
    final DateTime sinir = bugun.add(const Duration(days: 75));
    final DateTime esik = simdi.add(const Duration(seconds: 5));

    void ekle({required String ad, required String kategori, required double tutar, required DateTime vade, required String payload}) {
      if (vade.isAfter(sinir)) return;
      _ozetOdemeEkle(vade, ad, tutar);
      if (!finansBildirimAcik) return;
      final String baslik = profilEtiketi == null ? kategori : '$profilEtiketi • $kategori';
      final String tutarMetni = gizlilikModu ? '' : ' • ${_tl(tutar)}';
      for (final h in finansHatirlatmalari) {
        final DateTime t = DateTime(vade.year, vade.month, vade.day - h.gun, h.saat ~/ 60, h.saat % 60);
        if (!t.isAfter(esik)) continue;
        final String cumle = h.gun == 0 ? 'Bugün son ödeme günü' : (h.gun == 1 ? 'Yarın son ödeme günü' : '${h.gun} gün sonra son ödeme');
        sonuc.add(_PlanliBildirim(t, baslik, '$ad • $cumle$tutarMetni', '$payload|$profilId', finans: true));
      }
      if (finansGecikmeBildirimi) {
        final DateTime t = DateTime(vade.year, vade.month, vade.day + 1, finansGecikmeSaati ~/ 60, finansGecikmeSaati % 60);
        if (t.isAfter(esik)) {
          final String gecBaslik = profilEtiketi == null ? '$kategori • Gecikti' : '$profilEtiketi • $kategori • Gecikti';
          sonuc.add(_PlanliBildirim(t, gecBaslik, '$ad • Son ödeme tarihi ${DateFormat('d MMMM', 'tr_TR').format(vade)} idi$tutarMetni', '$payload|$profilId', finans: true));
        }
      }
    }

    // Bu ay, geçen ay ve önümüzdeki 3 ay
    final List<String> aylar = [for (int k = -1; k <= 3; k++) _ayAnahtari(DateTime(simdi.year, simdi.month + k, 1))];

    // 1) Normal giderler (fatura, market, özel, sabit ödemelerin oluşmuş kayıtları)
    for (final k in finansListesi) {
      if (!_normalGider(k)) continue;
      final double odenen = k.odemeler.fold(0.0, (s, o) => s + o.tutar);
      final double kalan = k.tutar - odenen;
      if (kalan <= 0.009) continue;
      final DateTime vade = DateTime(k.tarih.year, k.tarih.month, k.tarih.day);
      if (vade.isBefore(bugun.subtract(const Duration(days: 1)))) continue;
      ekle(ad: k.baslik.isEmpty ? k.kategori : k.baslik, kategori: k.kategori, tutar: kalan, vade: vade, payload: 'finans|kalem|${k.id}|${k.ayYilAnahtari}');
    }

    for (final ay in aylar) {
      final DateTime d = DateTime.parse('$ay-01');
      final int aySonu = DateTime(d.year, d.month + 1, 0).day;

      // 2) Kredi kartı: ekstre varsa ekstre, yoksa o ayın ödenmemiş taksitleri
      for (final kart in krediKartiListesi) {
        final DateTime vade = DateTime(d.year, d.month, _gunSinirla(kart.sonOdemeGunu, aySonu));
        final ekstreler = finansListesi.where((i) => !i.isGelir && i.kategori == 'Kredi Kartı Ekstresi' && i.kartId == kart.id && i.ayYilAnahtari == ay).toList();
        if (ekstreler.isNotEmpty) {
          final e = ekstreler.first;
          if (!e.odendiMi) {
            ekle(ad: '${kart.kartAdi} ekstresi', kategori: 'Kredi Kartı', tutar: e.tutar, vade: vade, payload: 'finans|kart|${kart.id}|$ay');
          }
        } else {
          final odenmemis = _kartaAitTaksitleriGetir(kart.id, ay).where((t) => t.odenenAylar[ay] != true).toList();
          if (odenmemis.isNotEmpty) {
            final double toplam = odenmemis.fold(0.0, (s, t) => s + t.aylikTutar);
            ekle(ad: '${kart.kartAdi} taksitleri', kategori: 'Kredi Kartı', tutar: toplam, vade: vade, payload: 'finans|kart|${kart.id}|$ay');
          }
        }
      }

      // 3) Krediler
      for (final kredi in krediListesi) {
        if (!_krediBuAyAktifMi(kredi, ay)) continue;
        if (kredi.odenenAylar[ay] == true) continue;
        final DateTime vade = DateTime(d.year, d.month, _gunSinirla(kredi.sonOdemeGunu, aySonu));
        ekle(ad: kredi.krediAdi, kategori: '${kredi.krediTuru} Kredisi', tutar: kredi.aylikTutar, vade: vade, payload: 'finans|kredi|${kredi.id}|$ay');
      }

      // 4) Henüz kaydı oluşmamış gelecek aylardaki sabit ödemeler
      for (final s in sabitListesi) {
        if (s.isGelir) continue;
        if (ay.compareTo(s.baslangicAyYil) < 0) continue;
        final String? bitis = s.bitisAyYil;
        if (bitis != null && ay.compareTo(bitis) > 0) continue;
        if (s.atlananAylar.contains(ay)) continue;
        final String kayitId = '${s.id}_$ay';
        if (finansListesi.any((k) => k.id == kayitId)) continue; // kaydı var, yukarıda ele alındı
        final DateTime vade = DateTime(d.year, d.month, _gunSinirla(s.gun, aySonu));
        ekle(ad: s.baslik, kategori: s.kategori, tutar: s.tutarAy(ay), vade: vade, payload: 'finans|kalem|$kayitId|$ay');
      }
    }

    sonuc.sort((a, b) => a.zaman.compareTo(b.zaman));
    return sonuc.take(100).toList();
  }

  // ---------- Sabah özeti ----------

  final Map<String, _GunOzeti> _ozetBirikim = {};

  void _ozetOdemeEkle(DateTime vade, String ad, [double tutar = 0]) {
    final DateTime g = DateTime(vade.year, vade.month, vade.day);
    final _GunOzeti oz = _ozetBirikim.putIfAbsent(DateFormat('yyyy-MM-dd').format(g), () => _GunOzeti());
    oz.odeme++;
    oz.odemeTutar += tutar;
    oz.ogeler.add(_OzetOgesi(3000, 'Ödeme: $ad${(gizlilikModu || tutar <= 0) ? '' : ' (${_tl(tutar)})'}'));
  }

  // O an yüklü profilin önümüzdeki günlerdeki etkinliklerini özet için sayar
  void _ozetTopla(DateTime simdi) {
    final DateTime bugun = DateTime(simdi.year, simdi.month, simdi.day);
    for (int i = 0; i < 21; i++) {
      final DateTime gun = DateTime(bugun.year, bugun.month, bugun.day + i);
      final String anahtar = DateFormat('yyyy-MM-dd').format(gun);
      for (final o in _gunOlaylari(gun)) {
        if (o.etkinlik.yapilanlar.contains(o.anahtar)) continue;
        final _GunOzeti oz = _ozetBirikim.putIfAbsent(anahtar, () => _GunOzeti());
        oz.etkinlik++;
        oz.ogeler.add(_OzetOgesi(o.gunBoyu ? 1500 : o.siraDakika, o.gunBoyu ? o.etkinlik.baslik : '${o.etkinlik.zamanlar[o.zamanIndex].saatMetni} ${o.etkinlik.baslik}'));
      }
    }
  }

  List<_PlanliBildirim> _ozetAdaylari(DateTime simdi) {
    if (!sabahOzetiAcik) return [];
    final List<_PlanliBildirim> sonuc = [];
    final DateTime bugun = DateTime(simdi.year, simdi.month, simdi.day);
    for (int i = 0; i < 14; i++) {
      final DateTime gun = DateTime(bugun.year, bugun.month, bugun.day + i);
      final DateTime t = DateTime(gun.year, gun.month, gun.day, sabahOzetiSaati ~/ 60, sabahOzetiSaati % 60);
      if (!t.isAfter(simdi.add(const Duration(seconds: 5)))) continue;
      final String anahtar = DateFormat('yyyy-MM-dd').format(gun);
      final _GunOzeti? oz = _ozetBirikim[anahtar];
      if (oz == null || (oz.etkinlik == 0 && oz.odeme == 0)) continue;
      final List<String> parcalar = [];
      if (oz.etkinlik > 0) parcalar.add('${oz.etkinlik} etkinlik');
      if (oz.odeme > 0) parcalar.add('${oz.odeme} ödeme');
      final List<_OzetOgesi> sirali = List.of(oz.ogeler)..sort((a, b) => a.sira.compareTo(b.sira));
      final List<String> satirlar = ['Bugün ${parcalar.join(', ')} var.'];
      for (final o in sirali.take(5)) {
        satirlar.add('• ${o.metin}');
      }
      if (sirali.length > 5) satirlar.add('… ve ${sirali.length - 5} tane daha');
      sonuc.add(_PlanliBildirim(t, 'Günaydın', satirlar.join('\n'), 'ozet|$anahtar', ozet: true));
    }
    return sonuc;
  }

  // "Önümüzdeki hafta" özeti: seçilen günün ertesinden başlayan 7 günü toplar
  List<_PlanliBildirim> _haftaAdaylari(DateTime simdi) {
    if (!haftaOzetiAcik) return [];
    final List<_PlanliBildirim> sonuc = [];
    final DateTime bugun = DateTime(simdi.year, simdi.month, simdi.day);
    const List<String> gunAdlari = ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz'];
    for (int i = 0; i + 7 < 21; i++) {
      final DateTime gun = DateTime(bugun.year, bugun.month, bugun.day + i);
      if (gun.weekday != haftaOzetiGunu) continue;
      final DateTime t = DateTime(gun.year, gun.month, gun.day, haftaOzetiSaati ~/ 60, haftaOzetiSaati % 60);
      if (!t.isAfter(simdi.add(const Duration(seconds: 5)))) continue;
      int etkinlik = 0;
      int odeme = 0;
      double tutar = 0;
      DateTime? ilkGun;
      final List<String> gunSatirlari = [];
      for (int k = 1; k <= 7; k++) {
        final DateTime g = DateTime(bugun.year, bugun.month, bugun.day + i + k);
        final _GunOzeti? oz = _ozetBirikim[DateFormat('yyyy-MM-dd').format(g)];
        if (oz == null || (oz.etkinlik == 0 && oz.odeme == 0)) continue;
        etkinlik += oz.etkinlik;
        odeme += oz.odeme;
        tutar += oz.odemeTutar;
        ilkGun ??= g;
        final List<_OzetOgesi> sirali = List.of(oz.ogeler)..sort((a, b) => a.sira.compareTo(b.sira));
        final String kalan = sirali.length > 2 ? ' +${sirali.length - 2}' : '';
        gunSatirlari.add('${gunAdlari[g.weekday - 1]} ${g.day}: ${sirali.take(2).map((o) => o.metin).join(', ')}$kalan');
      }
      if (etkinlik == 0 && odeme == 0) continue;
      final List<String> parcalar = [];
      if (etkinlik > 0) parcalar.add('$etkinlik etkinlik');
      if (odeme > 0) parcalar.add(gizlilikModu || tutar <= 0 ? '$odeme ödeme' : '$odeme ödeme (${_tl(tutar)})');
      final String metin = ['${parcalar.join(', ')} var.', ...gunSatirlari].join('\n');
      final String baslik = haftaOzetiGunu == 7 ? 'Önümüzdeki hafta' : 'Önümüzdeki 7 gün';
      sonuc.add(_PlanliBildirim(t, baslik, metin, 'ozet|${DateFormat('yyyy-MM-dd').format(ilkGun ?? gun)}', ozet: true));
    }
    return sonuc;
  }

  // ---------- Kategori önerisi ----------

  List<String> _kategoriKelimeleri(String baslik) {
    final String kucuk = baslik.replaceAll('İ', 'i').replaceAll('I', 'ı').toLowerCase();
    return kucuk.split(RegExp(r'[^a-zçğıöşü0-9]+')).where((k) => k.length >= 3 && !RegExp(r'^\d+$').hasMatch(k)).toList();
  }

  // Yazılan başlıktaki kelimelerden birini daha önce kullandıysa, o zaman seçilen kategoriyi önerir
  String? _kategoriOner(String baslik, bool gelir) {
    final String onek = gelir ? 'i:' : 'g:';
    for (final k in _kategoriKelimeleri(baslik)) {
      final String? v = _kategoriHafizasi['$onek$k'];
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  void _kategoriOgren(String baslik, String kategori, bool gelir) {
    if (kategori.trim().isEmpty || kategori == 'Diğer (Özel)') return;
    final String onek = gelir ? 'i:' : 'g:';
    final List<String> kelimeler = _kategoriKelimeleri(baslik);
    if (kelimeler.isEmpty) return;
    for (final k in kelimeler) {
      _kategoriHafizasi.remove('$onek$k');
      _kategoriHafizasi['$onek$k'] = kategori;
    }
    while (_kategoriHafizasi.length > 400) {
      _kategoriHafizasi.remove(_kategoriHafizasi.keys.first);
    }
    _globalAyarlariKaydet();
  }

  // Aktif profilde kayıtlı veri var mı?
  bool _veriVarMi() => notListesi.isNotEmpty || notArsivi.isNotEmpty || copNotlari.isNotEmpty || copEtkinlikleri.isNotEmpty || finansListesi.isNotEmpty || etkinlikListesi.isNotEmpty || krediListesi.isNotEmpty || kartTaksitListesi.isNotEmpty || sabitListesi.isNotEmpty;

  // Yedek hatırlatma bildirimi
  _PlanliBildirim? _yedekBildirimiAdayi(DateTime simdi) {
    if (yedekHatirlatmaGunu <= 0) return null;
    final DateTime temel = _sonYedekTarihi ?? _ilkKullanim ?? simdi;
    DateTime vade = DateTime(temel.year, temel.month, temel.day + yedekHatirlatmaGunu, 10, 0);
    if (!vade.isAfter(simdi.add(const Duration(minutes: 1)))) {
      vade = DateTime(simdi.year, simdi.month, simdi.day + 1, 10, 0);
    }
    return _PlanliBildirim(vade, 'Yedekleme', 'Verilerini yedekleme zamanı geldi. Dokunup yedek al.', 'yedek');
  }

  // Aktif profilin verisini geçici olarak başka bir profille değiştirip geri almak için
  Map<String, Object?> _anlikAl() => {
        'gizlilik': gizlilikModu,
        'siralama': _siralama,
        'siralamaArtan': _siralamaArtan,
        'kartlar': krediKartiListesi,
        'krediler': krediListesi,
        'finans': finansListesi,
        'taksitler': kartTaksitListesi,
        'turler': etkinlikTurleri,
        'etkinlikler': etkinlikListesi,
        'sabitler': sabitListesi,
        'fAcik': finansBildirimAcik,
        'fHat': finansHatirlatmalari,
        'fGec': finansGecikmeBildirimi,
        'fGecSaat': finansGecikmeSaati,
        'ozel': ozelHatirlatmalar,
        'notlar': notListesi,
        'notArsiv': notArsivi,
        'copN': copNotlari,
        'copE': copEtkinlikleri,
        'notKat': notKategorileri,
        'ajSira': _ajandaSiralama,
        'ajYon': _ajandaSiralamaArtan,
        'nSira': _notSiralama,
        'nYon': _notSiralamaArtan,
        'nGor': _notGorunum,
      };

  void _anlikGeriYukle(Map<String, Object?> a) {
    gizlilikModu = a['gizlilik'] as bool;
    _siralama = a['siralama'] as String;
    _siralamaArtan = a['siralamaArtan'] as bool;
    krediKartiListesi = a['kartlar'] as List<KrediKarti>;
    krediListesi = a['krediler'] as List<KrediBorcu>;
    finansListesi = a['finans'] as List<FinansKalemi>;
    kartTaksitListesi = a['taksitler'] as List<KartTaksiti>;
    etkinlikTurleri = a['turler'] as List<EtkinlikTuru>;
    etkinlikListesi = a['etkinlikler'] as List<Etkinlik>;
    sabitListesi = a['sabitler'] as List<SabitOdeme>;
    finansBildirimAcik = a['fAcik'] as bool;
    finansHatirlatmalari = a['fHat'] as List<FinansHatirlatma>;
    finansGecikmeBildirimi = a['fGec'] as bool;
    finansGecikmeSaati = a['fGecSaat'] as int;
    ozelHatirlatmalar = a['ozel'] as List<Hatirlatma>;
    notListesi = a['notlar'] as List<NotKaydi>;
    notArsivi = a['notArsiv'] as List<NotKaydi>;
    copNotlari = a['copN'] as List<NotKaydi>;
    copEtkinlikleri = a['copE'] as List<Etkinlik>;
    notKategorileri = a['notKat'] as List<EtkinlikTuru>;
    _notSiralama = a['nSira'] as String;
    _notSiralamaArtan = a['nYon'] as bool;
    _notGorunum = a['nGor'] as String;
    _ajandaSiralama = a['ajSira'] as String;
    _ajandaSiralamaArtan = a['ajYon'] as bool;
  }

  // Tüm profillerin yaklaşan hatırlatmalarını hesaplar ve telefonun alarm sistemine kaydeder.
  // Uygulama kapalıyken de bildirimler zamanında gelir.
  Future<void> _bildirimleriPlanla() async {
    if (!_yuklendi) return;
    if (_bildirimPlanCalisiyor) {
      _bildirimPlanBekliyor = true;
      return;
    }
    _bildirimPlanCalisiyor = true;
    try {
      final AndroidFlutterLocalNotificationsPlugin? android = _androidBildirim;
      if (android == null) return;

      final DateTime simdi = DateTime.now();
      final bool cokProfil = profiller.length > 1;
      final List<_PlanliBildirim> secilen = [];
      _ozetBirikim.clear();

      // Aktif profil
      final String? aktifEtiket = cokProfil ? aktifHesapAdi : null;
      secilen.addAll(_ajandaAdaylari(simdi, aktifProfilId, aktifEtiket));
      secilen.addAll(_finansAdaylari(simdi, aktifProfilId, aktifEtiket));
      _ozetTopla(simdi);

      // Diğer profiller: verileri geçici olarak yükle, hesapla, aktif profili geri koy
      if (cokProfil) {
        final prefs = await SharedPreferences.getInstance();
        final Map<String, String> digerVeriler = {};
        for (final p in profiller) {
          if (p.id == aktifProfilId) continue;
          final String? m = prefs.getString('veri_${p.id}');
          if (m != null) digerVeriler[p.id] = m;
        }
        if (digerVeriler.isNotEmpty) {
          final Map<String, Object?> anlik = _anlikAl();
          final int okunamayanOnce = _okunamayanKayit;
          try {
            for (final p in profiller) {
              final String? m = digerVeriler[p.id];
              if (m == null) continue;
              _veriyiUygula(jsonDecode(m) as Map<String, dynamic>, profil: p);
              secilen.addAll(_ajandaAdaylari(simdi, p.id, p.ad));
              secilen.addAll(_finansAdaylari(simdi, p.id, p.ad));
              _ozetTopla(simdi);
            }
          } catch (e) {
            debugPrint('Diğer profiller planlanamadı: $e');
          } finally {
            _anlikGeriYukle(anlik);
            _okunamayanKayit = okunamayanOnce;
          }
        }
      }

      secilen.addAll(_ozetAdaylari(simdi));
      secilen.addAll(_haftaAdaylari(simdi));
      if (_veriVarMi()) {
        final _PlanliBildirim? yedek = _yedekBildirimiAdayi(simdi);
        if (yedek != null) secilen.add(yedek);
      }
      secilen.sort((a, b) => a.zaman.compareTo(b.zaman));
      final List<_PlanliBildirim> plan = secilen.take(350).toList();

      // Plan öncekiyle aynıysa telefona yeniden yazma
      final String imza = 'ertele4|$ertelemeDk|$bildirimGuvenilirMod|${_kanalKimligi(false)}|${_kanalKimligi(true)}|${plan.map((b) => '${b.zaman.millisecondsSinceEpoch}|${b.baslik}|${b.metin}|${b.payload}|${b.finans}').join('\n')}';
      if (imza == _sonPlanImzasi) return;

      // Önceki planı temizle
      final bekleyenler = await flutterLocalNotificationsPlugin.pendingNotificationRequests();
      for (final b in bekleyenler) {
        if (b.id < 900000) await flutterLocalNotificationsPlugin.cancel(b.id);
      }

      await _bildirimKanallariniKur();
      final AndroidScheduleMode mod = await _planlamaModu();

      // Sabit kimlikler: bildirim içeriğinden türetilir. Sıralı numara kullanılırsa, panelde duran bir bildirimin
      // numarası yeni planda başka bir bildirime geçer ve plan yenilenirken o bildirim paneldan silinirdi.
      final Set<int> kullanilan = {};
      try {
        for (final a in await (android as dynamic).getActiveNotifications()) {
          final dynamic n = a.id;
          if (n is int) kullanilan.add(n);
        }
      } catch (_) {}
      int kimlikUret(_PlanliBildirim b) {
        int h = 0x811c9dc5;
        for (final int c in '${b.zaman.millisecondsSinceEpoch}|${b.baslik}|${b.payload}'.codeUnits) {
          h = ((h ^ c) * 0x01000193) & 0x7fffffff;
        }
        int k = 1 + h % 899000;
        while (kullanilan.contains(k)) {
          k = k % 899000 + 1;
        }
        kullanilan.add(k);
        return k;
      }

      String hata = '';
      for (final b in plan) {
        final int id = kimlikUret(b);
        try {
          // UTC anı olarak verilir: telefonun saat dilimi ne olursa olsun doğru ana denk gelir
          await (android as dynamic).zonedSchedule(id, b.baslik, b.metin, tz.TZDateTime.from(b.zaman, tz.UTC), _bildirimDetayi(b.metin, finans: b.finans, ertele: !b.ozet, yapildi: b.payload.startsWith('etkinlik|')), scheduleMode: mod, payload: b.payload);
        } catch (e) {
          hata = 'Bildirim planlanamadı: $e';
          break;
        }
      }

      if (hata.isEmpty) _sonPlanImzasi = imza;
      if (!mounted) return;
      if (hata != _bildirimHatasi) setState(() => _bildirimHatasi = hata);
    } catch (e) {
      if (mounted) setState(() => _bildirimHatasi = 'Bildirim planı hazırlanamadı: $e');
    } finally {
      _bildirimPlanCalisiyor = false;
      if (_bildirimPlanBekliyor) {
        _bildirimPlanBekliyor = false;
        _bildirimleriYenile();
      }
    }
  }

  // ---------- Sorun giderme ----------

  Future<void> _bildirimDurumunuGoster() async {
    await _bildirimIzinleriniKontrolEt();
    final bool tam = await _tamZamanliAlarmMi();
    int bekleyen = 0;
    try {
      bekleyen = (await flutterLocalNotificationsPlugin.pendingNotificationRequests()).length;
    } catch (e) {
      debugPrint('Bekleyen bildirim sayısı alınamadı: $e');
    }
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bildirim durumu'),
        content: SingleChildScrollView(
          child: Text(
            'Bildirim izni: ${_bildirimIzniVar == true ? 'Açık' : 'KAPALI'}\n'
            'Tam zamanlı alarm izni: ${tam ? 'Açık' : 'Kapalı'}\n'
            'Planlama modu: ${bildirimGuvenilirMod ? 'Güvenilir (alarm saati gibi)' : 'Standart'}\n'
            'Telefonda planlı bildirim: $bekleyen',
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
        ),
        actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tamam'))],
      ),
    );
  }

  // Test bildirimi: ilk dokunuşta 1 dakika sonrasına kurulur, tekrar dokunulursa iptal edilir
  Future<void> _bildirimTestiDegistir() async {
    if (_testIsleniyor) return;
    _testIsleniyor = true;
    try {
      final DateTime? kurulu = _testZamani;
      if (kurulu != null && kurulu.isAfter(DateTime.now())) {
        await flutterLocalNotificationsPlugin.cancel(999001);
        _testZamanlayici?.cancel();
        if (mounted) setState(() => _testZamani = null);
        _snack('Test iptal edildi.');
        return;
      }

      final AndroidFlutterLocalNotificationsPlugin? android = _androidBildirim;
      if (android == null) {
        _snack('Bildirimler sadece Android telefonda çalışır.');
        return;
      }
      await _bildirimIzinleriniKontrolEt(bildirimIste: true);
      if (!mounted) return;
      if (_bildirimIzniVar != true) {
        _snack('Bildirim izni kapalı. Önce "Bildirim izni" satırından izin ver.');
        return;
      }
      await _bildirimKanallariniKur();
      final AndroidScheduleMode mod = await _planlamaModu();
      final DateTime zaman = DateTime.now().add(const Duration(minutes: 1));
      const String metin = 'Test • Bu bildirim 1 dakika önce planlandı. Ekran kapalıyken geldiyse sorun yok.';
      await (android as dynamic).zonedSchedule(999001, 'Alfred • Test', metin, tz.TZDateTime.from(zaman, tz.UTC), _bildirimDetayi(metin), scheduleMode: mod);
      if (!mounted) return;
      setState(() {
        _testZamani = zaman;
        _bildirimHatasi = '';
      });
      _testZamanlayici?.cancel();
      _testZamanlayici = Timer(const Duration(seconds: 62), () {
        if (mounted) setState(() => _testZamani = null);
      });
      _snack('Test 1 dakika sonra gelecek. Telefonu kilitleyip bekle. İptal etmek için aynı satıra tekrar dokun.');
    } catch (e) {
      if (mounted) setState(() => _bildirimHatasi = 'Test bildirimi planlanamadı: $e');
    } finally {
      _testIsleniyor = false;
    }
  }

  // ---------- Bildirime dokununca ilgili yere git ----------

  void _bildirimDinleyicisi() {
    final BildirimTiklamasi? t = bildirimTiklamasi.value;
    // Veriler yüklenmediyse açılışta işlenecek (_acilisBildiriminiIsle)
    if (t == null || !_yuklendi) return;
    bildirimTiklamasi.value = null;
    if (t.eylem == 'ertele') {
      _bildirimErtele(t.bildirimNo, t.payload);
      return;
    }
    _bildirimTiklamasiniIsle(t.payload);
  }

  // Uygulama bildirime dokunularak (kapalıyken) açıldıysa o bildirimi işler
  Future<void> _acilisBildiriminiIsle() async {
    String? payload;
    try {
      final detay = await flutterLocalNotificationsPlugin.getNotificationAppLaunchDetails();
      if (detay != null && detay.didNotificationLaunchApp) {
        payload = detay.notificationResponse?.payload;
        if (detay.notificationResponse?.actionId == 'ertele') {
          bildirimTiklamasi.value = null;
          if (mounted) await _bildirimErtele(detay.notificationResponse?.id, payload ?? '');
          return;
        }
      }
    } catch (e) {
      debugPrint('Bildirim başlatma bilgisi okunamadı: $e');
    }
    final BildirimTiklamasi? bekleyen = bildirimTiklamasi.value;
    if (bekleyen != null && bekleyen.eylem == 'ertele') {
      bildirimTiklamasi.value = null;
      if (mounted) await _bildirimErtele(bekleyen.bildirimNo, bekleyen.payload);
      return;
    }
    if (payload == null && bekleyen != null) payload = bekleyen.payload;
    bildirimTiklamasi.value = null;
    if (!mounted || payload == null || payload.isEmpty) return;
    await _bildirimTiklamasiniIsle(payload);
  }

  // Bildirimin taşıdığı bilgiye göre doğru profile, sekmeye ve öğeye gider, öğeyi vurgular
  Future<void> _bildirimTiklamasiniIsle(String payload) async {
    final List<String> p = payload.split('|');
    if (p.isEmpty) return;

    if (p[0] == 'yedek') {
      _sekmeyeGit(4, animasyon: false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _yedeklemeSayfasiniAc();
      });
      return;
    }

    if (p[0] == 'ozet') {
      final DateTime? gun = p.length > 1 ? DateTime.tryParse(p[1]) : null;
      setState(() {
        _ajandaListeGorunumu = false;
        if (gun != null) {
          _secilenAyYil = _ayAnahtari(gun);
          _ajandaGunSecimi = gun.day;
          _ajandaGunAyi = _secilenAyYil;
          _ajandaAcikDurum['gun:${DateFormat('yyyy-MM-dd').format(gun)}'] = true;
        }
        _vurguluEtkinlikId = null;
        _vurguluFinansAnahtari = null;
      });
      _sekmeyeGit(0, animasyon: false);
      // Takvimin altındaki günün etkinlik kartına kaydır
      Future.delayed(const Duration(milliseconds: 350), () {
        final BuildContext? hedef = _ajandaGunKartiAnahtari.currentContext;
        if (mounted && hedef != null && hedef.mounted) {
          Scrollable.ensureVisible(hedef, duration: const Duration(milliseconds: 450), alignment: 0.05, curve: Curves.easeInOut);
        }
      });
      return;
    }

    // Bildirim başka bir profile aitse önce o profile geç
    final String? profilId = p.length > 4 ? p[4] : null;
    if (profilId != null && profilId != aktifProfilId && profiller.any((x) => x.id == profilId)) {
      await _profilDegistir(profilId);
      if (!mounted) return;
    }

    if (p[0] == 'finans') {
      _finansBildirimTiklamasiniIsle(p);
      return;
    }
    if (p.length < 4 || p[0] != 'etkinlik') return;
    final String id = p[1];
    final DateTime? gun = DateTime.tryParse(p[2]);
    if (gun == null) return;
    final Etkinlik? e = _tumEtkinlikler().where((x) => x.id == id).firstOrNull;

    setState(() {
      _ajandaListeGorunumu = false;
      _secilenAyYil = _ayAnahtari(gun);
      _ajandaGunSecimi = gun.day;
      _ajandaGunAyi = _secilenAyYil;
      _vurguluFinansAnahtari = null;
      _vurguluEtkinlikId = e?.id;
      _vurguluGun = e == null ? null : DateTime(gun.year, gun.month, gun.day);
      if (e != null) {
        // Vurgulanan etkinliğin bulunduğu sekmeler açık gelsin
        _ajandaAcikDurum['tur:${DateFormat('yyyy-MM-dd').format(gun)}:${e.turId}'] = true;
        _ajandaAcikDurum['etk:${DateFormat('yyyy-MM-dd').format(gun)}:${e.id}'] = true;
        _ajandaAcikDurum['gun:${DateFormat('yyyy-MM-dd').format(gun)}'] = true;
      }
    });
    _sekmeyeGit(0, animasyon: false); // Ajanda

    if (e == null) {
      _snack('Bu etkinlik artık mevcut değil.');
      return;
    }

    // Vurgu birkaç saniye sonra kendiliğinden kalkar
    _vurguZamanlayici?.cancel();
    _vurguZamanlayici = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _vurguluEtkinlikId = null);
    });

    // Etkinlik ekranın dışında kaldıysa kaydırıp göster
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? hedef = _vurguAnahtari.currentContext;
      if (hedef != null) {
        Scrollable.ensureVisible(hedef, duration: const Duration(milliseconds: 450), alignment: 0.25, curve: Curves.easeInOut);
      }
    });
  }

  // Finans bildirimine dokunulunca: Finans sekmesi, o ay ve ilgili ödeme vurgulanır
  void _finansBildirimTiklamasiniIsle(List<String> p) {
    if (p.length < 4) return;
    final String tur = p[1];
    final String id = p[2];
    final String ay = p[3];
    if (DateTime.tryParse('$ay-01') == null) return;

    setState(() {
      _secilenAyYil = ay;
      gelecekGiderlerAcik = true;
      _vurguluEtkinlikId = null;
      _vurguluGun = null;
      _vurguluFinansAnahtari = '$tur:$id';
      _vurguluFinansAyi = ay;
    });
    _sekmeyeGit(2, animasyon: false); // Finans

    _vurguZamanlayici?.cancel();
    _vurguZamanlayici = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _vurguluFinansAnahtari = null);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? hedef = _vurguAnahtari.currentContext;
      if (hedef != null) {
        Scrollable.ensureVisible(hedef, duration: const Duration(milliseconds: 450), alignment: 0.25, curve: Curves.easeInOut);
      }
    });
  }

  // Bu etkinlik grubu şu an bildirimden gelip vurgulanıyor mu?
  bool _grupVurgulu(List<_AjandaOlay> grup) {
    final DateTime? vg = _vurguluGun;
    if (vg == null || _vurguluEtkinlikId == null) return false;
    final _AjandaOlay ilk = grup.first;
    return ilk.etkinlik.id == _vurguluEtkinlikId && ilk.gun.year == vg.year && ilk.gun.month == vg.month && ilk.gun.day == vg.day;
  }

  bool _finansVurgulu(_Birim b) => _vurguluFinansAnahtari != null && _vurguluFinansAnahtari == b.anahtar && _vurguluFinansAyi == _secilenAyYil;

  // Bildirimden gelinen ödemeyi renkli çerçeve ve ışıltıyla öne çıkarır
  List<Widget> _finansBirimWidgetlari(_Birim b) {
    if (!_finansVurgulu(b)) return b.widgetlar;
    final Color renk = _turRengi(b.kategori);
    return [
      TweenAnimationBuilder<double>(
        key: _vurguAnahtari,
        tween: Tween<double>(begin: 0, end: 1),
        duration: const Duration(milliseconds: 700),
        builder: (context, v, child) => Container(
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: yuzey.withValues(alpha: 0.85 * v),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: renk.withValues(alpha: v), width: 2),
            boxShadow: [BoxShadow(color: renk.withValues(alpha: 0.4 * v), blurRadius: 14, spreadRadius: 1)],
          ),
          child: child,
        ),
        child: Column(children: b.widgetlar),
      ),
    ];
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Uygulamaya dönünce: yeni gün/ay için sabit ödemeleri tamamla, izinleri tazele, bildirimleri yeniden planla
      setState(() {
        _sabitleriUret();
      });
      _copuTemizle();
      _bildirimIzinleriniKontrolEt();
      _bildirimleriYenile();
      _widgetBekleyenleriUygula().then((_) => _bildirimYapildilariUygula()).then((_) => _widgetVerisiniGuncelle());
    } else {
      // Arka plana geçerken bekleyen kaydı hemen yaz
      _kaydetHemen();
      if (state == AppLifecycleState.paused) {
        _otomatikYedekAl();
        _widgetVerisiniGuncelle();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    bildirimTiklamasi.removeListener(_bildirimDinleyicisi);
    bildirimYapildiSinyali.removeListener(_bildirimYapildilariUygula);
    _widgetAbonelik?.cancel();
    _bildirimZamanlayici?.cancel();
    _vurguZamanlayici?.cancel();
    _testZamanlayici?.cancel();
    _kaydetHemen();
    _sayfaKontrol.dispose();
    _sekmeBildirici.dispose();
    _notAramaCtrl.dispose();
    _ajandaAramaCtrl.dispose();
    _arayuzSurumu.dispose();
    super.dispose();
  }

  // ============================== NOTLAR ==============================

  NotKaydi? _notBul(String id) => notListesi.where((n) => n.id == id).firstOrNull;

  EtkinlikTuru? _notKategorisi(NotKaydi n) => notKategorileri.where((k) => k.id == n.kategori).firstOrNull;

  // Notun rengi kategorisinin rengidir (kategorisi yoksa gri)
  Color _notRengi(NotKaydi n) => _notKategorisi(n)?.renkVerisi ?? ajandaRenkleri[9];

  String _notBasligi(NotKaydi n) => n.baslik.isEmpty ? (n.liste ? 'Liste' : 'Not') : n.baslik;

  String _varsayilanNotKategorisi(bool liste) {
    final String tercih = liste ? 'genel' : 'notlar';
    if (notKategorileri.any((k) => k.id == tercih)) return tercih;
    return notKategorileri.isEmpty ? '' : notKategorileri.first.id;
  }

  // Hatırlatması olan not, Ajanda ve bildirimler için geçici bir etkinliğe çevrilir
  Etkinlik _notEtkinligi(NotKaydi n) {
    final DateTime t = n.hatirlatmaTarihi!;
    final DateTime gun = DateTime(t.year, t.month, t.day);
    final int? dk = n.hatirlatmaSaati;
    final String anahtar = '${DateFormat('yyyy-MM-dd').format(gun)}|0';
    final String ozet = n.liste ? n.maddeler.where((m) => !m.tamam).map((m) => m.metin).join(', ') : n.metin;
    return Etkinlik(
      id: 'not_${n.id}',
      baslik: _notBasligi(n),
      turId: 'not',
      notlar: ozet,
      baslangic: gun,
      tumGun: dk == null,
      zamanlar: dk == null ? <ZamanDilimi>[] : [ZamanDilimi(saat: dk ~/ 60, dakika: dk % 60)],
      hatirlatmalar: n.hatirlatmalar.map((h) => h.kopya()).toList(),
      yapilanlar: n.tamamlandi ? [anahtar] : <String>[],
      fotolar: List<String>.from(n.fotolar),
    );
  }

  // Normal etkinlikler + hatırlatması olan notlar
  List<Etkinlik> _tumEtkinlikler() => [
        ...etkinlikListesi,
        ...notListesi.where((n) => n.hatirlatmaTarihi != null).map(_notEtkinligi),
      ];

  NotKaydi? _etkinlikNotu(Etkinlik e) => e.id.startsWith('not_') ? _notBul(e.id.substring(4)) : null;

  // Not silinmez, çöp kutusuna taşınır ($copSuresiGun gün sonra kendiliğinden kalıcı silinir)
  void _notSil(String id) {
    final NotKaydi? n = _notBul(id);
    if (n == null) return;
    _geriAlliSil('Not çöp kutusuna taşındı', ['notlar', 'copNotlari'], () {
      n.silinme = DateTime.now();
      setState(() {
        notListesi.removeWhere((x) => x.id == id);
        copNotlari.insert(0, n);
      });
      _bildirimleriYenile();
    });
  }

  void _notSilOnayi(NotKaydi n) {
    _silmeOnayiGoster(context, '"${_notBasligi(n)}" çöp kutusuna taşınacak. $copSuresiGun gün içinde geri yükleyebilirsin.', () => _notSil(n.id));
  }

  // ---------- Arama yardımcıları ----------

  // Büyük/küçük harf ve Türkçe i/ı farkını yok sayar; karakter sayısı değişmez
  String _aramaNormal(String s) => s.replaceAll('İ', 'i').replaceAll('I', 'ı').toLowerCase().replaceAll('ı', 'i');

  // Aranan kelimeyi sarı fon ve kalın yazıyla vurgular
  Widget _vurguluMetin(String metin, String arama, TextStyle stil, {int? maxLines}) {
    final String a = _aramaNormal(arama.trim());
    if (a.isEmpty) return Text(metin, style: stil, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis);
    final String m = _aramaNormal(metin);
    final List<TextSpan> parcalar = [];
    int i = 0;
    while (true) {
      final int k = m.indexOf(a, i);
      if (k < 0) {
        if (i < metin.length) parcalar.add(TextSpan(text: metin.substring(i)));
        break;
      }
      if (k > i) parcalar.add(TextSpan(text: metin.substring(i, k)));
      parcalar.add(TextSpan(text: metin.substring(k, k + a.length), style: const TextStyle(backgroundColor: Color(0xFFFDE68A), fontWeight: FontWeight.bold, color: Colors.black)));
      i = k + a.length;
    }
    return Text.rich(TextSpan(style: stil, children: parcalar), maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis);
  }

  // Arama sonucunda notun tamamını göstermek yerine, kelimenin geçtiği bölümleri gösterir
  List<Widget> _notAramaOzeti(NotKaydi n, String arama) {
    final String a = _aramaNormal(arama.trim());
    final List<Widget> sonuc = [];
    if (a.isEmpty) return sonuc;
    final TextStyle stil = TextStyle(fontSize: 13, color: yaziRengi);
    final TextStyle kucuk = TextStyle(fontSize: 11, color: gri(600));
    if (n.liste) {
      final List<NotMaddesi> eslesen = n.maddeler.where((m) => _aramaNormal(m.metin).contains(a) || _aramaNormal(m.not).contains(a)).toList();
      for (final m in eslesen.take(4)) {
        sonuc.add(
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Row(
              children: [
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _notMaddeDegistir(n, m),
                  child: Padding(
                    padding: const EdgeInsets.all(7),
                    child: Icon(m.tamam ? Icons.check_circle : Icons.radio_button_unchecked, size: 18, color: m.tamam ? Colors.green : gri(600)),
                  ),
                ),
                const SizedBox(width: 3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _vurguluMetin(m.metin, arama, stil, maxLines: 2),
                      if (m.not.isNotEmpty) _vurguluMetin(m.not, arama, kucuk, maxLines: 2),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }
      if (eslesen.length > 4) sonuc.add(Padding(padding: const EdgeInsets.only(top: 6), child: Text('+${eslesen.length - 4} eşleşme daha', style: TextStyle(fontSize: 12, color: gri(600)))));
    }
    // Serbest not metni veya listenin genel notu
    final String m = _aramaNormal(n.metin);
    int i = 0;
    int adet = 0;
    while (adet < 2) {
      final int k = m.indexOf(a, i);
      if (k < 0) break;
      final int bas = math.max(0, k - 40);
      final int son = math.min(n.metin.length, k + a.length + 60);
      final String parca = n.metin.substring(bas, son).replaceAll('\n', ' ');
      sonuc.add(
        Padding(
          padding: const EdgeInsets.only(top: 6, right: 10),
          child: _vurguluMetin('${bas > 0 ? '…' : ''}$parca${son < n.metin.length ? '…' : ''}', arama, stil, maxLines: 3),
        ),
      );
      adet++;
      i = son;
    }
    return sonuc;
  }

  // "Yapıldı" işareti: listede tüm maddelere tik atılır; işaret kaldırılırsa tüm tikler de kalkar
  void _notTamamlandiDegistir(NotKaydi n) {
    setState(() {
      n.tamamlandi = !n.tamamlandi;
      if (n.liste) {
        for (final m in n.maddeler) {
          m.tamam = n.tamamlandi;
        }
      }
    });
    _bildirimleriYenile();
  }

  // Liste maddesine tik: tüm maddeler yapılınca liste tamamlanmış sayılır, biri geri alınırsa tamamlanma da kalkar
  void _notMaddeDegistir(NotKaydi n, NotMaddesi m) {
    setState(() {
      m.tamam = !m.tamam;
      if (n.maddeler.isNotEmpty) n.tamamlandi = n.maddeler.every((x) => x.tamam);
    });
    if (n.hatirlatmaTarihi != null) _bildirimleriYenile();
  }

  // ---------- Başlık düğmeleri ----------

  Widget _notEkleMenusu() {
    return PopupMenuButton<String>(
      tooltip: 'Ekle',
      onSelected: (v) => _notDuzenle(liste: v == 'liste'),
      itemBuilder: (c) => const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: 'not', child: Row(children: [Icon(Icons.notes, size: 18), SizedBox(width: 10), Text('Yeni not')])),
        PopupMenuItem<String>(value: 'liste', child: Row(children: [Icon(Icons.checklist, size: 18), SizedBox(width: 10), Text('Yeni liste')])),
      ],
      child: Container(
        decoration: BoxDecoration(color: anaRenk, borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: const Icon(Icons.add, color: Colors.white, size: 20),
      ),
    );
  }

  Widget _notAramaDugmesi() {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: () => setState(() {
        _notAramaAcik = !_notAramaAcik;
        if (!_notAramaAcik) {
          _notArama = '';
          _notAramaCtrl.clear();
        }
      }),
      child: Container(
        decoration: BoxDecoration(color: griDugme, shape: BoxShape.circle),
        padding: const EdgeInsets.all(8),
        child: Icon(_notAramaAcik ? Icons.search_off : Icons.search, size: 18, color: ikonGri),
      ),
    );
  }

  Widget _notSiralamaDugmesi() {
    return _siralamaMenusu(
      olcutler: const [
        ('tarih', 'Son düzenlemeye göre', Icons.event),
        ('kategori', 'Kategoriye göre', Icons.category_outlined),
      ],
      secili: () => _notSiralama,
      artan: () => _notSiralamaArtan,
      yonGoster: () => true,
      yonEtiketi: (a) => _notSiralama == 'tarih' ? (a ? 'Eskiden yeniye' : 'Yeniden eskiye') : (a ? 'Kategori sırasıyla' : 'Ters kategori sırasıyla'),
      olcutSecildi: (id) => setState(() => _notSiralama = id),
      yonSecildi: (a) => setState(() => _notSiralamaArtan = a),
      filtreler: const [
        ('hepsi', 'Liste ve notlar', Icons.dashboard_outlined),
        ('liste', 'Sadece listeler', Icons.checklist),
        ('not', 'Sadece notlar', Icons.notes),
      ],
      filtre: () => _notTurFiltresi,
      filtreSecildi: (id) => setState(() => _notTurFiltresi = id),
      gorunumler: const [
        ('notlar', 'Düz liste', Icons.view_agenda_outlined),
        ('kategoriler', 'Kategorilere göre', Icons.folder_copy_outlined),
      ],
      gorunum: () => _notGorunum,
      gorunumSecildi: (id) => setState(() => _notGorunum = id),
      gorunumGoster: () => notKategorileri.every((k) => k.id != _notFiltre),
    );
  }

  // Sabitlenenler her zaman üstte; sonra seçilen ölçüte göre
  List<NotKaydi> _notlariSirala(List<NotKaydi> kaynak) {
    final List<NotKaydi> liste = List<NotKaydi>.from(kaynak);
    int kat(NotKaydi n) {
      final int i = notKategorileri.indexWhere((k) => k.id == n.kategori);
      return i < 0 ? 999 : i;
    }

    liste.sort((a, b) {
      if (a.sabit != b.sabit) return a.sabit ? -1 : 1;
      if (_notSiralama == 'kategori') {
        final int c = kat(a).compareTo(kat(b));
        if (c != 0) return _notSiralamaArtan ? c : -c;
        return b.duzenleme.compareTo(a.duzenleme);
      }
      final int c = a.duzenleme.compareTo(b.duzenleme);
      return _notSiralamaArtan ? c : -c;
    });
    return liste;
  }

  // ---------- Kartlar ----------

  Widget _notKucukEtiket(IconData ikon, String metin, Color renk) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: yuzey.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ikon, size: 12, color: renk),
          const SizedBox(width: 4),
          Text(metin, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: renk)),
        ],
      ),
    );
  }

  String _notHatirlatmaMetni(NotKaydi n) {
    final DateTime t = n.hatirlatmaTarihi!;
    final String gun = DateFormat('d MMM', 'tr_TR').format(t);
    final int? dk = n.hatirlatmaSaati;
    return dk == null ? gun : '$gun ${_saatMetniDk(dk)}';
  }

  Widget _notKarti(NotKaydi n, {bool beyaz = false}) {
    final Color renk = _notRengi(n);
    final Color koyu = _koyu(renk);
    final EtkinlikTuru? kategori = _notKategorisi(n);
    final bool hatirlatmali = n.hatirlatmaTarihi != null;
    final int biten = n.maddeler.where((m) => m.tamam).length;
    final List<NotMaddesi> gorunen = n.maddeler.take(8).toList();
    final String arama = _notArama.trim();
    final List<Widget> aramaOzeti = arama.isEmpty ? <Widget>[] : _notAramaOzeti(n, arama);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: beyaz ? yuzey : _pastel(renk),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: renk.withValues(alpha: 0.3)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _notGoruntule(n.id, arama: arama),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 4, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(n.liste ? Icons.checklist : Icons.notes, size: 20, color: renk),
                    const SizedBox(width: 8),
                    Expanded(child: _vurguluMetin(_notBasligi(n), arama, TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: koyu), maxLines: 2)),
                    if (n.sabit) Icon(Icons.push_pin, size: 16, color: koyu),
                    PopupMenuButton<String>(
                      icon: Icon(Icons.more_vert, size: 20, color: koyu),
                      onSelected: (v) {
                        if (v == 'sabit') {
                          setState(() => n.sabit = !n.sabit);
                        } else if (v == 'duzenle') {
                          _notDuzenle(mevcut: n);
                        } else if (v == 'arsiv') {
                          _notArsivle(n);
                        } else if (v == 'sil') {
                          _notSilOnayi(n);
                        }
                      },
                      itemBuilder: (c) => <PopupMenuEntry<String>>[
                        const PopupMenuItem<String>(value: 'duzenle', child: Text('Düzenle')),
                        PopupMenuItem<String>(value: 'sabit', child: Text(n.sabit ? 'Sabitlemeyi kaldır' : 'Üste sabitle')),
                        const PopupMenuItem<String>(value: 'arsiv', child: Text('Arşivle')),
                        const PopupMenuItem<String>(value: 'sil', child: Text('Sil', style: TextStyle(color: Colors.red))),
                      ],
                    ),
                  ],
                ),
                if (arama.isNotEmpty)
                  ...aramaOzeti
                else if (n.liste) ...[
                  if (n.maddeler.isEmpty)
                    Padding(padding: const EdgeInsets.only(top: 4, right: 10), child: Text('Henüz madde yok', style: TextStyle(fontSize: 12, color: gri(600))))
                  else
                    for (final m in gorunen)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: Row(
                          children: [
                            // Baştaki daireye dokununca liste açılmadan tik atılır
                            InkWell(
                              customBorder: const CircleBorder(),
                              canRequestFocus: false,
                              onTap: () => _notMaddeDegistir(n, m),
                              child: Padding(
                                padding: const EdgeInsets.all(7),
                                child: Icon(m.tamam ? Icons.check_circle : Icons.radio_button_unchecked, size: 20, color: m.tamam ? Colors.green : gri(600)),
                              ),
                            ),
                            const SizedBox(width: 3),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    m.metin,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 14, color: m.tamam ? Colors.grey : yaziRengi, decoration: m.tamam ? TextDecoration.lineThrough : null),
                                  ),
                                  if (m.not.isNotEmpty) Text(m.not, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: gri(600))),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  if (n.maddeler.length > gorunen.length)
                    Padding(padding: const EdgeInsets.only(top: 6), child: Text('+${n.maddeler.length - gorunen.length} madde daha', style: TextStyle(fontSize: 12, color: gri(600)))),
                  // Listenin genel notu, maddelerin altında
                  if (n.metin.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, right: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.sticky_note_2_outlined, size: 14, color: koyu)),
                          const SizedBox(width: 6),
                          Expanded(child: Text(n.metin, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gri(800)))),
                        ],
                      ),
                    ),
                ] else if (n.metin.isNotEmpty)
                  Padding(padding: const EdgeInsets.only(top: 4, right: 10), child: Text(n.metin, maxLines: 4, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: yaziRengi))),
                if (arama.isEmpty && n.fotolar.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: _fotoSeridi(n.fotolar, boyut: 48)),
                Padding(
                  padding: const EdgeInsets.only(top: 10, right: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            if (kategori != null) _notKucukEtiket(kategori.ikonVerisi, kategori.ad, koyu),
                            if (n.liste && n.maddeler.isNotEmpty) _notKucukEtiket(Icons.done_all, '$biten/${n.maddeler.length}', koyu),
                            if (hatirlatmali) _notKucukEtiket(Icons.notifications_active_outlined, _notHatirlatmaMetni(n), koyu),
                          ],
                        ),
                      ),
                      if (hatirlatmali)
                        _yapildiHapi(n.tamamlandi, () => _notTamamlandiDegistir(n)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _notKategoriChipi({required String id, required String ad, required IconData ikon, required Color renk}) {
    final String etkin = notKategorileri.any((k) => k.id == _notFiltre) ? _notFiltre : '';
    final bool secili = etkin == id;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        avatar: Icon(ikon, size: 16, color: renk),
        label: Text(ad),
        selected: secili,
        selectedColor: _pastel(renk),
        side: BorderSide(color: secili ? renk : gri(300)),
        onSelected: (_) => setState(() => _notFiltre = (secili && id.isNotEmpty) ? '' : id),
      ),
    );
  }

  Widget _buildNotlarSekmesi() {
    final String arama = _aramaNormal(_notArama.trim());
    final String filtre = notKategorileri.any((k) => k.id == _notFiltre) ? _notFiltre : '';
    final List<NotKaydi> filtreli = notListesi.where((n) {
      if (filtre.isNotEmpty && n.kategori != filtre) return false;
      if (_notTurFiltresi == 'liste' && !n.liste) return false;
      if (_notTurFiltresi == 'not' && n.liste) return false;
      if (arama.isEmpty) return true;
      return _aramaNormal(n.baslik).contains(arama) || _aramaNormal(n.metin).contains(arama) || n.maddeler.any((m) => _aramaNormal(m.metin).contains(arama) || _aramaNormal(m.not).contains(arama));
    }).toList();
    final List<NotKaydi> liste = _notlariSirala(filtreli);

    Widget icerik;
    if (liste.isEmpty) {
      icerik = Center(
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sticky_note_2_outlined, size: 56, color: gri(400)),
              const SizedBox(height: 10),
              Text(
                notListesi.isEmpty ? 'Henüz not yok.\nSağ üstteki + ile liste veya not ekle.' : 'Bu filtreyle eşleşen not yok.',
                textAlign: TextAlign.center,
                style: TextStyle(color: gri(600)),
              ),
            ],
          ),
        ),
      );
    } else if (_notGorunum == 'kategoriler' && filtre.isEmpty) {
      // Kategori blokları: her kategori açılıp kapanan renkli bir bölüm
      final List<EtkinlikTuru> sira = _notSiralama == 'kategori' && !_notSiralamaArtan ? notKategorileri.reversed.toList() : notKategorileri;
      final List<Widget> bloklar = [];
      for (final k in sira) {
        final List<NotKaydi> icindekiler = liste.where((n) => n.kategori == k.id).toList();
        if (icindekiler.isEmpty) continue;
        bloklar.add(
          _kategoriBlogu(
            anahtar: 'notkat_${k.id}',
            ad: k.ad,
            altBaslik: '${icindekiler.length} ${icindekiler.length == 1 ? 'kayıt' : 'kayıt'}',
            sagMetin: '${icindekiler.length}',
            ikon: k.ikonVerisi,
            renk: k.renkVerisi,
            acik: _ajandaAcikMi('nkat:${k.id}', true) || arama.isNotEmpty,
            acikDegisti: (v) => _ajandaAcikDurum['nkat:${k.id}'] = v,
            children: [for (final n in icindekiler) Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: _notKarti(n, beyaz: true))],
          ),
        );
      }
      final List<NotKaydi> kategorisizler = liste.where((n) => !notKategorileri.any((k) => k.id == n.kategori)).toList();
      if (kategorisizler.isNotEmpty) {
        bloklar.add(
          _kategoriBlogu(
            anahtar: 'notkat_yok',
            ad: 'Kategorisiz',
            altBaslik: '${kategorisizler.length} kayıt',
            sagMetin: '${kategorisizler.length}',
            ikon: Icons.folder_open_outlined,
            renk: ajandaRenkleri[9],
            acik: _ajandaAcikMi('nkat:yok', true) || arama.isNotEmpty,
            acikDegisti: (v) => _ajandaAcikDurum['nkat:yok'] = v,
            children: [for (final n in kategorisizler) Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: _notKarti(n, beyaz: true))],
          ),
        );
      }
      icerik = ListView(padding: const EdgeInsets.fromLTRB(10, 4, 10, 20), children: bloklar);
    } else {
      icerik = ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 20), children: [for (final n in liste) _notKarti(n)]);
    }

    return DokunmaDinleyici(
      haricAlan: _notAramaAlani,
      onBosDokunma: () {
        if (!_notAramaAcik || !mounted) return;
        setState(() {
          _notAramaAcik = false;
          _notArama = '';
          _notAramaCtrl.clear();
        });
      },
      child: Column(
      children: [
        _sayfaBasligi(_profilBasligi(), [_notAramaDugmesi(), _notSiralamaDugmesi(), _notMenusu(), _notEkleMenusu()]),
        if (_notAramaAcik)
          Padding(
            key: _notAramaAlani,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: _aramaKutusu(
              kontrol: _notAramaCtrl,
              ipucu: 'Notlarda ara…',
              degisti: (v) => setState(() => _notArama = v),
              temizle: () {
                _notAramaCtrl.clear();
                setState(() => _notArama = '');
              },
            ),
          ),
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              _notKategoriChipi(id: '', ad: 'Tümü', ikon: Icons.apps, renk: anaRenk),
              for (final k in notKategorileri) _notKategoriChipi(id: k.id, ad: k.ad, ikon: k.ikonVerisi, renk: k.renkVerisi),
              ActionChip(avatar: const Icon(Icons.tune, size: 16), label: const Text('Kategoriler'), onPressed: _notKategorileriniYonet),
            ],
          ),
        ),
        Expanded(child: icerik),
      ],
      ),
    );
  }

  // Kategorileri ekle / düzenle / sil (renk ve ikon seçilebilir)
  Future<void> _notKategorileriniYonet() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (c, setS) => Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.75),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _pencereBasligi(sheetContext, Icons.label_outline, 'Not Kategorileri'),
              const Divider(),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      if (notKategorileri.isEmpty) Padding(padding: const EdgeInsets.all(12), child: Text('Kategori yok.', style: TextStyle(color: gri(600)))),
                      for (final k in List<EtkinlikTuru>.from(notKategorileri))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(backgroundColor: _pastel(k.renkVerisi), child: Icon(k.ikonVerisi, color: k.renkVerisi, size: 20)),
                          title: Text(k.ad),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit, size: 20, color: Colors.grey),
                                onPressed: () async {
                                  await _turDialogGoster(mevcut: k, hedefListe: notKategorileri, tur: 'Kategori', adEtiketi: 'Kategori adı', ipucu: 'Örn: Ders, İş, Alışveriş');
                                  setS(() {});
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red),
                                onPressed: () {
                                  final int notSayisi = notListesi.where((n) => n.kategori == k.id).length;
                                  _silmeOnayiGoster(
                                    sheetContext,
                                    notSayisi > 0
                                        ? '"${k.ad}" kategorisi silinecek. Bu kategorideki $notSayisi not silinmez, kategorisiz kalır.'
                                        : '"${k.ad}" kategorisi silinecek.',
                                    () {
                                      setState(() {
                                        notKategorileri.removeWhere((x) => x.id == k.id);
                                        for (final n in notListesi) {
                                          if (n.kategori == k.id) n.kategori = '';
                                        }
                                        if (_notFiltre == k.id) _notFiltre = '';
                                      });
                                      setS(() {});
                                    },
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await _turDialogGoster(hedefListe: notKategorileri, tur: 'Kategori', adEtiketi: 'Kategori adı', ipucu: 'Örn: Ders, İş, Alışveriş');
                    setS(() {});
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Yeni Kategori Ekle'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- Not / liste okuma ekranı ----------

  // Nota dokununca açılır: içeriği okunur, liste maddeleri tiklenir, içinde arama yapılır, düzenleme ayrı bir düğmedir
  Future<void> _notGoruntule(String id, {String arama = ''}) async {
    String aranan = arama.trim();
    bool aramaAcik = aranan.isNotEmpty;
    int eslesmeSirasi = 0;
    bool kaydirmaGerek = aranan.isNotEmpty;
    final aramaCtrl = TextEditingController(text: aranan);
    final GlobalKey aramaSatiriAnahtar = GlobalKey();
    int secimSurumu = 0; // artırılınca metin seçimi temizlenir
    final Map<int, GlobalKey> anahtarlar = {};
    GlobalKey anahtar(int i) => anahtarlar.putIfAbsent(i, () => GlobalKey());
    final duzenCtrl = TextEditingController(text: _notBul(id)?.metin ?? '');
    final FocusNode duzenOdak = FocusNode();
    void odakDegisti() => _arayuzSurumu.value++;
    duzenOdak.addListener(odakDegisti);

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => StatefulBuilder(
          builder: (sheetContext, setP) => ValueListenableBuilder<int>(
            valueListenable: _arayuzSurumu,
            builder: (c, surum, w) {
              final NotKaydi? n = _notBul(id);
              if (n == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (routeContext.mounted) Navigator.of(routeContext).maybePop();
                });
                return const Scaffold();
              }
              // Not düzenleme penceresinden kaydedilince (metin silinmiş ya da değişmiş olabilir) okuma ekranındaki
              // yazı alanı da güncellenir; yoksa eski metin görünür ve yazmaya devam edilirse geri gelir
              if (!n.liste && n.metin != duzenCtrl.text) {
                final String guncel = n.metin;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (duzenCtrl.text != guncel && _notBul(id)?.metin == guncel) {
                    duzenCtrl.value = TextEditingValue(text: guncel, selection: TextSelection.collapsed(offset: guncel.length));
                  }
                });
              }
              final Color renk = _notRengi(n);
              final EtkinlikTuru? kategori = _notKategorisi(n);
              final String a = _aramaNormal(aranan);
              final List<String> genelSatirlar = n.liste && n.metin.trim().isNotEmpty ? n.metin.split('\n') : <String>[];
              final List<String> satirlar = n.liste ? [...n.maddeler.map((m) => '${m.metin} ${m.not}'), ...genelSatirlar] : n.metin.split('\n');
              final List<int> eslesenler = [
                if (a.isNotEmpty)
                  for (int i = 0; i < satirlar.length; i++)
                    if (_aramaNormal(satirlar[i]).contains(a)) i,
              ];
              if (eslesmeSirasi >= eslesenler.length) eslesmeSirasi = 0;

              // Aranan kelimenin geçtiği satıra kaydır
              if (kaydirmaGerek) {
                kaydirmaGerek = false;
                if (eslesenler.isNotEmpty) {
                  final int hedef = eslesenler[eslesmeSirasi];
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    final BuildContext? hc = anahtar(hedef).currentContext;
                    if (hc != null) Scrollable.ensureVisible(hc, duration: const Duration(milliseconds: 300), alignment: 0.3, curve: Curves.easeInOut);
                  });
                }
              }

              Widget govde;
              if (n.liste) {
                govde = Column(
                  children: [
                    if (n.maddeler.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text('Bu listede henüz madde yok.', style: TextStyle(color: gri(600)))),
                    for (int i = 0; i < n.maddeler.length; i++)
                      Container(
                        key: anahtar(i),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => _notMaddeDegistir(n, n.maddeler[i]),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
                            child: Row(
                              children: [
                                Icon(n.maddeler[i].tamam ? Icons.check_circle : Icons.radio_button_unchecked, size: 24, color: n.maddeler[i].tamam ? Colors.green : gri(600)),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      _vurguluMetin(
                                        n.maddeler[i].metin,
                                        aranan,
                                        TextStyle(fontSize: 16, color: n.maddeler[i].tamam ? Colors.grey : yaziRengi, decoration: n.maddeler[i].tamam ? TextDecoration.lineThrough : null),
                                      ),
                                      if (n.maddeler[i].not.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 2),
                                          child: _vurguluMetin(n.maddeler[i].not, aranan, TextStyle(fontSize: 13, color: gri(600))),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    // Listenin genel notu, maddelerin altında
                    if (genelSatirlar.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: yuzey, borderRadius: BorderRadius.circular(12), border: Border.all(color: gri(200))),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [Icon(Icons.sticky_note_2_outlined, size: 16, color: gri(600)), const SizedBox(width: 6), Text('Genel not', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: gri(700)))]),
                            const SizedBox(height: 6),
                            SelectionArea(
                              key: ValueKey('gsec_$secimSurumu'),
                              child: SizedBox(
                                width: double.infinity,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    for (int j = 0; j < genelSatirlar.length; j++)
                                      SizedBox(
                                        key: aranan.isEmpty ? null : anahtar(n.maddeler.length + j),
                                        width: double.infinity,
                                        child: _vurguluMetin(genelSatirlar[j].isEmpty ? ' ' : genelSatirlar[j], aranan, TextStyle(fontSize: 15, height: 1.4, color: yaziRengi)),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                );
              } else {
                // Metin seçilip kopyalanabilir; seçim alanı ortalanmasın diye iki kat tam genişlikli kutu içinde
                govde = aranan.isEmpty
                    ? TextField(
                        controller: duzenCtrl,
                        focusNode: duzenOdak,
                        minLines: 3,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        style: TextStyle(fontSize: 16, height: 1.5, color: yaziRengi),
                        decoration: const InputDecoration(
                          hintText: 'Yazmak için dokunun…',
                          border: InputBorder.none,
                          isCollapsed: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 4),
                        ),
                        onChanged: (v) {
                          n.metin = v;
                          _kaydetPlanla();
                        },
                      )
                    : SizedBox(
                  width: double.infinity,
                  child: SelectionArea(
                    key: ValueKey('sec_$secimSurumu'),
                    child: SizedBox(
                      width: double.infinity,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (n.metin.trim().isEmpty) Text('Bu notta içerik yok.', style: TextStyle(color: gri(600))),
                          for (int i = 0; i < satirlar.length; i++)
                            SizedBox(
                              key: aranan.isEmpty ? null : anahtar(i),
                              width: double.infinity,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: _vurguluMetin(satirlar[i].isEmpty ? ' ' : satirlar[i], aranan, TextStyle(fontSize: 16, height: 1.5, color: yaziRengi)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              }

              return DokunmaDinleyici(
                haricAlan: aramaSatiriAnahtar,
                onDokunma: () {
                  // Her kısa dokunma metin seçimini temizler
                  if (!routeContext.mounted) return;
                  setP(() => secimSurumu++);
                },
                onBosDokunma: () {
                  // Düğme / onay kutusu dışında boş bir yere dokunmak açık aramayı kapatır
                  if (!routeContext.mounted) return;
                  if (aramaAcik) {
                    setP(() {
                      aramaAcik = false;
                      aranan = '';
                      eslesmeSirasi = 0;
                      aramaCtrl.clear();
                    });
                  }
                },
                child: Scaffold(
                backgroundColor: zemin,
                appBar: AppBar(
                  backgroundColor: zemin,
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  iconTheme: IconThemeData(color: koyuYazi),
                  title: Text(_notBasligi(n), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: koyuYazi)),
                  actions: [
                    if (duzenOdak.hasFocus)
                      IconButton(
                        tooltip: 'Bitti',
                        icon: Icon(Icons.check_circle, color: gelirRengi, size: 28),
                        onPressed: () {
                          duzenOdak.unfocus();
                          _kaydetHemen();
                        },
                      ),
                    IconButton(
                      tooltip: 'Bu notta ara',
                      icon: Icon(aramaAcik ? Icons.search_off : Icons.search),
                      onPressed: () => setP(() {
                        aramaAcik = !aramaAcik;
                        if (!aramaAcik) {
                          aranan = '';
                          aramaCtrl.clear();
                        }
                      }),
                    ),
                    IconButton(tooltip: 'Düzenle', icon: const Icon(Icons.edit_outlined), onPressed: () => _notDuzenle(mevcut: n)),
                    PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'sabit') {
                          setState(() => n.sabit = !n.sabit);
                        } else if (v == 'kopyala') {
                          final String metin = n.liste ? '${n.maddeler.map((m) => '${m.tamam ? '[x]' : '[ ]'} ${m.metin}${m.not.isEmpty ? '' : ' (${m.not})'}').join('\n')}${n.metin.trim().isEmpty ? '' : '\n\n${n.metin}'}' : n.metin;
                          Clipboard.setData(ClipboardData(text: '${_notBasligi(n)}\n$metin'));
                          _snack('Kopyalandı.');
                        } else if (v == 'sil') {
                          _notSilOnayi(n);
                        }
                      },
                      itemBuilder: (c) => <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(value: 'sabit', child: Text(n.sabit ? 'Sabitlemeyi kaldır' : 'Üste sabitle')),
                        const PopupMenuItem<String>(value: 'kopyala', child: Text('Metni kopyala')),
                        const PopupMenuItem<String>(value: 'sil', child: Text('Sil', style: TextStyle(color: Colors.red))),
                      ],
                    ),
                  ],
                ),
                body: Column(
                  children: [
                    if (aramaAcik)
                      Padding(
                        key: aramaSatiriAnahtar,
                        padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: _aramaKutusu(
                                kontrol: aramaCtrl,
                                ipucu: n.liste ? 'Bu listede ara…' : 'Bu notta ara…',
                                otoOdak: aranan.isEmpty,
                                degisti: (v) => setP(() {
                                  aranan = v.trim();
                                  eslesmeSirasi = 0;
                                  kaydirmaGerek = true;
                                }),
                                temizle: () => setP(() {
                                  aramaCtrl.clear();
                                  aranan = '';
                                  eslesmeSirasi = 0;
                                }),
                              ),
                            ),
                            if (aranan.isNotEmpty) ...[
                              Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text(eslesenler.isEmpty ? 'Yok' : '${eslesmeSirasi + 1}/${eslesenler.length}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                              IconButton(
                                icon: const Icon(Icons.keyboard_arrow_up),
                                onPressed: eslesenler.isEmpty
                                    ? null
                                    : () => setP(() {
                                          eslesmeSirasi = (eslesmeSirasi - 1 + eslesenler.length) % eslesenler.length;
                                          kaydirmaGerek = true;
                                        }),
                              ),
                              IconButton(
                                icon: const Icon(Icons.keyboard_arrow_down),
                                onPressed: eslesenler.isEmpty
                                    ? null
                                    : () => setP(() {
                                          eslesmeSirasi = (eslesmeSirasi + 1) % eslesenler.length;
                                          kaydirmaGerek = true;
                                        }),
                              ),
                            ],
                          ],
                        ),
                      ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                if (kategori != null) _notKucukEtiket(kategori.ikonVerisi, kategori.ad, _koyu(renk)),
                                if (n.sabit) _notKucukEtiket(Icons.push_pin, 'Sabit', _koyu(renk)),
                                if (n.hatirlatmaTarihi != null) _notKucukEtiket(Icons.notifications_active_outlined, _notHatirlatmaMetni(n), _koyu(renk)),
                                if (n.liste && n.maddeler.isNotEmpty) _notKucukEtiket(Icons.done_all, '${n.maddeler.where((m) => m.tamam).length}/${n.maddeler.length}', _koyu(renk)),
                              ],
                            ),
                            if (n.hatirlatmaTarihi != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: Row(
                                  children: [
                                    _yapildiHapi(n.tamamlandi, () => _notTamamlandiDegistir(n)),
                                    const SizedBox(width: 10),
                                    Text(n.tamamlandi ? 'Yapıldı olarak işaretli' : 'Yapıldı olarak işaretle', style: TextStyle(fontSize: 13, color: gri(700))),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 14),
                            govde,
                            if (n.fotolar.isNotEmpty) ...[
                              const SizedBox(height: 18),
                              _fotoSeridi(n.fotolar, boyut: 72),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                ),
              );
            },
          ),
        ),
      ),
    );
    duzenOdak.removeListener(odakDegisti);
    duzenOdak.dispose();
    duzenCtrl.dispose();
    _kaydetHemen();
    // Okuma ekranında yazıp geri dönünce not listesindeki kart da güncel metni göstersin
    if (mounted) {
      setState(() {});
      _bildirimleriYenile();
    }
  }

  // ---------- Not / liste ekleme ve düzenleme ----------

  Future<void> _notDuzenle({NotKaydi? mevcut, bool liste = true}) async {
    final Object jeton = Object();
    if (mevcut == null) {
      _acikEditorTuru = liste ? 'liste' : 'not';
      _editorBosMu = null;
      _editorJetonu = jeton;
    }
    try {
      await _notDuzenleIc(mevcut: mevcut, liste: liste);
    } finally {
      if (identical(_editorJetonu, jeton)) {
        _acikEditorTuru = null;
        _editorBosMu = null;
        _editorJetonu = null;
      }
    }
  }

  Future<void> _notDuzenleIc({NotKaydi? mevcut, bool liste = true}) async {
    final bool listeTuru = mevcut?.liste ?? liste;
    final baslikCtrl = TextEditingController(text: mevcut?.baslik ?? '');
    final metinCtrl = TextEditingController(text: mevcut?.metin ?? '');
    final yeniMaddeCtrl = TextEditingController();
    final yeniMaddeOdak = FocusNode();
    final SesliYazi ses = SesliYazi();
    final List<NotMaddesi> maddeler = (mevcut?.maddeler ?? <NotMaddesi>[]).map((m) => NotMaddesi(id: m.id, metin: m.metin, tamam: m.tamam, not: m.not)).toList();
    final Map<String, TextEditingController> maddeKontrol = {};
    TextEditingController kontrolDe(NotMaddesi m) => maddeKontrol.putIfAbsent(m.id, () => TextEditingController(text: m.metin));
    final Map<String, TextEditingController> notKontrol = {};
    TextEditingController notDe(NotMaddesi m) => notKontrol.putIfAbsent(m.id, () => TextEditingController(text: m.not));
    final Set<String> notAcik = {};
    if (mevcut == null) _editorBosMu = () => baslikCtrl.text.trim().isEmpty && metinCtrl.text.trim().isEmpty && maddeler.isEmpty && yeniMaddeCtrl.text.trim().isEmpty;

    String kategori = mevcut?.kategori ?? (_notFiltre.isNotEmpty ? _notFiltre : _varsayilanNotKategorisi(listeTuru));
    bool sabit = mevcut?.sabit ?? false;
    DateTime? hTarih = mevcut?.hatirlatmaTarihi;
    int? hSaat = mevcut?.hatirlatmaSaati;
    List<Hatirlatma> hatirlatmalar = (mevcut?.hatirlatmalar ?? <Hatirlatma>[]).map((h) => h.kopya()).toList();
    String? hata;
    final baslikAnahtar = GlobalKey();

    final List<String> fotolar = List<String>.from(mevcut?.fotolar ?? <String>[]);
    final List<String> yeniFotolar = [];
    final List<String> silinenFotolar = [];
    bool kaydedildi = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (innerContext) => StatefulBuilder(
        builder: (sheetContext, setModalState) {
          final DateTime? ht = hTarih;
          final int? hs = hSaat;

          void fotoKaldir(String ad) {
            setModalState(() {
              fotolar.remove(ad);
              if (yeniFotolar.contains(ad)) {
                yeniFotolar.remove(ad);
                _fotoSil(ad);
              } else {
                silinenFotolar.add(ad);
              }
            });
          }

          void maddeEkle(String metin) {
            final String t = metin.trim();
            if (t.isEmpty) return;
            ses.durdur(); // eklenen maddenin sesi, bir sonrakinin üstüne yazılmasın
            void temizle() => yeniMaddeCtrl.value = const TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0), composing: TextRange.empty);
            setModalState(() {
              maddeler.add(NotMaddesi(id: 'm${DateTime.now().microsecondsSinceEpoch}', metin: t));
              temizle();
            });
            yeniMaddeOdak.requestFocus();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!sheetContext.mounted) return;
              temizle(); // klavye öneri metni geri getirmesin
              yeniMaddeOdak.requestFocus();
              SystemChannels.textInput.invokeMethod<void>('TextInput.show');
            });
          }

          Future<void> tarihSec() async {
            final DateTime simdi = DateTime.now();
            final DateTime? secilen = await showDatePicker(
              context: sheetContext,
              initialDate: ht ?? DateTime(simdi.year, simdi.month, simdi.day),
              firstDate: DateTime(simdi.year - 1),
              lastDate: DateTime(simdi.year + 10),
            );
            if (secilen == null || !sheetContext.mounted) return;
            setModalState(() {
              hTarih = DateTime(secilen.year, secilen.month, secilen.day);
              if (hatirlatmalar.isEmpty) hatirlatmalar = [Hatirlatma(0, hSaat == null ? 'gun' : 'dakika', gunSaati: hSaat == null ? 540 : null)];
            });
          }

          Widget bolumBasligi(String metin) => Padding(
                padding: const EdgeInsets.only(top: 14, bottom: 6),
                child: Text(metin, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: gri(600))),
              );

          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
            child: Container(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.9),
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _pencereBasligi(innerContext, listeTuru ? Icons.checklist : Icons.notes, mevcut == null ? (listeTuru ? 'Yeni Liste' : 'Yeni Not') : (listeTuru ? 'Listeyi Düzenle' : 'Notu Düzenle')),
                  const Divider(),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            key: baslikAnahtar,
                            controller: baslikCtrl,
                            textCapitalization: TextCapitalization.sentences,
                            onChanged: (_) {
                              if (hata != null) setModalState(() => hata = null);
                            },
                            decoration: InputDecoration(
                              labelText: 'Başlık',
                              hintText: listeTuru ? 'Örn: Market listesi' : 'Örn: Ahmet – matematik ödevi',
                              errorText: hata,
                            ),
                          ),
                          if (ses.hata != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(ses.hata!, style: const TextStyle(fontSize: 12, color: Colors.red)),
                            ),
                          const SizedBox(height: 10),
                          if (listeTuru) ...[
                            ReorderableListView(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              buildDefaultDragHandles: false,
                              onReorderItem: (eski, yeni) => setModalState(() {
                                final NotMaddesi tasinan = maddeler.removeAt(eski);
                                maddeler.insert(yeni, tasinan);
                              }),
                              children: [
                            for (int mi = 0; mi < maddeler.length; mi++)
                              Column(
                                key: ValueKey('madde_${maddeler[mi].id}'),
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              Builder(builder: (_) {
                                final NotMaddesi m = maddeler[mi];
                                return Row(
                                children: [
                                  ReorderableDragStartListener(
                                    index: mi,
                                    child: const Padding(
                                      padding: EdgeInsets.fromLTRB(4, 8, 4, 8),
                                      child: Icon(Icons.drag_indicator, color: Colors.grey),
                                    ),
                                  ),
                                  Checkbox(
                                    value: m.tamam,
                                    activeColor: Colors.green,
                                    onChanged: (v) => setModalState(() => m.tamam = v ?? false),
                                  ),
                                  Expanded(
                                    child: TextField(
                                      controller: kontrolDe(m),
                                      onChanged: (v) => m.metin = v,
                                      textCapitalization: TextCapitalization.sentences,
                                      style: TextStyle(decoration: m.tamam ? TextDecoration.lineThrough : null, color: m.tamam ? Colors.grey : yaziRengi),
                                      decoration: const InputDecoration(isDense: true, border: InputBorder.none, hintText: 'Madde'),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Maddeye küçük not ekle',
                                    icon: Icon(Icons.sticky_note_2_outlined, size: 18, color: (notAcik.contains(m.id) || m.not.isNotEmpty) ? anaRenk : Colors.grey),
                                    onPressed: () => setModalState(() {
                                      if (!notAcik.remove(m.id)) notAcik.add(m.id);
                                    }),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                                    onPressed: () => setModalState(() {
                                      maddeler.remove(m);
                                      maddeKontrol.remove(m.id);
                                      notKontrol.remove(m.id);
                                    }),
                                  ),
                                ],
                              );
                              }),
                              Builder(builder: (_) {
                                final NotMaddesi m = maddeler[mi];
                                if (!(notAcik.contains(m.id) || m.not.isNotEmpty)) return const SizedBox.shrink();
                                return Padding(
                                  padding: const EdgeInsets.only(left: 76, right: 12, bottom: 6),
                                  child: TextField(
                                    controller: notDe(m),
                                    onChanged: (v) => m.not = v,
                                    textCapitalization: TextCapitalization.sentences,
                                    style: TextStyle(fontSize: 13, color: gri(700)),
                                    decoration: const InputDecoration(isDense: true, hintText: 'Küçük not…'),
                                  ),
                                );
                              }),
                                ],
                              ),
                              ],
                            ),
                            Row(
                              key: const ValueKey('yeni_madde_satiri'),
                              children: [
                                Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Icon(Icons.add, color: anaRenk)),
                                Expanded(
                                  child: TextField(
                                    controller: yeniMaddeCtrl,
                                    focusNode: yeniMaddeOdak,
                                    textCapitalization: TextCapitalization.sentences,
                                    textInputAction: TextInputAction.next,
                                    cursorColor: anaRenk,
                                    cursorWidth: 2,
                                    showCursor: true,
                                    // onEditingComplete verilince Enter klavyeyi kapatmaz; alan odakta kalır
                                    onEditingComplete: () => maddeEkle(yeniMaddeCtrl.text),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                                      hintText: 'Madde ekle…',
                                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: gri(300))),
                                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: anaRenk, width: 2)),
                                    ),
                                  ),
                                ),
                                ses.dugme(yeniMaddeCtrl, () {
                                  if (sheetContext.mounted) setModalState(() {});
                                }),
                                TextButton(onPressed: () => maddeEkle(yeniMaddeCtrl.text), child: const Text('Ekle')),
                              ],
                            ),
                            if (maddeler.any((m) => m.tamam))
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  onPressed: () => setModalState(() => maddeler.removeWhere((m) => m.tamam)),
                                  icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                                  label: const Text('Tamamlananları temizle'),
                                ),
                              ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: metinCtrl,
                              minLines: 2,
                              maxLines: 6,
                              textCapitalization: TextCapitalization.sentences,
                              decoration: InputDecoration(
                                labelText: 'Genel not (listenin altında görünür)',
                                alignLabelWithHint: true,
                                suffixIcon: ses.dugme(metinCtrl, () {
                                  if (sheetContext.mounted) setModalState(() {});
                                }),
                              ),
                            ),
                          ] else
                            TextField(
                              controller: metinCtrl,
                              minLines: 5,
                              maxLines: 12,
                              textCapitalization: TextCapitalization.sentences,
                              decoration: InputDecoration(
                                labelText: 'Not',
                                alignLabelWithHint: true,
                                suffixIcon: ses.dugme(metinCtrl, () {
                                  if (sheetContext.mounted) setModalState(() {});
                                }),
                              ),
                            ),
                          bolumBasligi('KATEGORİ'),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              for (final k in notKategorileri)
                                ChoiceChip(
                                  avatar: Icon(k.ikonVerisi, size: 16, color: k.renkVerisi),
                                  label: Text(k.ad),
                                  selected: kategori == k.id,
                                  selectedColor: _pastel(k.renkVerisi),
                                  side: BorderSide(color: kategori == k.id ? k.renkVerisi : gri(300)),
                                  onSelected: (_) => setModalState(() => kategori = k.id),
                                ),
                              ActionChip(
                                avatar: const Icon(Icons.add, size: 16),
                                label: const Text('Yeni'),
                                onPressed: () async {
                                  final EtkinlikTuru? yeni = await _turDialogGoster(hedefListe: notKategorileri, tur: 'Kategori', adEtiketi: 'Kategori adı', ipucu: 'Örn: Ders, İş, Alışveriş');
                                  if (yeni == null || !sheetContext.mounted) return;
                                  setModalState(() => kategori = yeni.id);
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Üste sabitle'),
                            value: sabit,
                            onChanged: (v) => setModalState(() => sabit = v),
                          ),
                          _formGrubu([
                            _formIcerikSatiri(
                              ikon: Icons.photo_library_outlined,
                              baslik: 'Fotoğraflar',
                              icerik: Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  for (int i = 0; i < fotolar.length; i++)
                                    _fotoKucukResmi(
                                      fotolar[i],
                                      64,
                                      onTap: () => _fotoGoruntule(
                                        List<String>.from(fotolar),
                                        i,
                                        sil: (ad) async {
                                          fotoKaldir(ad);
                                          return true;
                                        },
                                      ),
                                      onSil: () => fotoKaldir(fotolar[i]),
                                    ),
                                  PopupMenuButton<String>(
                                    tooltip: 'Fotoğraf ekle',
                                    onSelected: (v) async {
                                      final List<String> adlar = await _fotolariSecVeKaydet(v == 'kamera' ? ImageSource.camera : ImageSource.gallery);
                                      if (adlar.isEmpty || !sheetContext.mounted) return;
                                      setModalState(() {
                                        fotolar.addAll(adlar);
                                        yeniFotolar.addAll(adlar);
                                      });
                                    },
                                    itemBuilder: (menuContext) => const <PopupMenuEntry<String>>[
                                      PopupMenuItem<String>(value: 'kamera', child: Row(children: [Icon(Icons.photo_camera_outlined, size: 18), SizedBox(width: 8), Text('Kamera ile çek')])),
                                      PopupMenuItem<String>(value: 'galeri', child: Row(children: [Icon(Icons.photo_library_outlined, size: 18), SizedBox(width: 8), Text('Galeriden seç')])),
                                    ],
                                    child: Container(
                                      width: 64,
                                      height: 64,
                                      decoration: BoxDecoration(color: acikZemin, borderRadius: BorderRadius.circular(10)),
                                      child: Icon(Icons.add_a_photo_outlined, color: anaRenk),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ]),
                          const SizedBox(height: 14),
                          _formGrubu([
                            if (ht == null)
                              InkWell(
                                onTap: tarihSec,
                                child: Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                                  child: Row(
                                    children: [
                                      Icon(Icons.notifications_active_outlined, size: 20, color: anaRenk),
                                      SizedBox(width: 12),
                                      Text('Hatırlatma Ekle', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: anaRenk)),
                                    ],
                                  ),
                                ),
                              )
                            else ...[
                              _formSatiri(ikon: Icons.event, baslik: 'Tarih', deger: DateFormat('d MMMM yyyy, EEEE', 'tr_TR').format(ht), onTap: tarihSec),
                              // Eski sürümde saat seçilmiş notlar için: saati değiştirme / kaldırma
                              if (hs != null)
                                _formSatiri(
                                  ikon: Icons.access_time,
                                  baslik: 'Saat',
                                  deger: _saatMetniDk(hs),
                                  onTap: () async {
                                    final String? secim = await _secenekSheetiGoster(
                                      ikon: Icons.access_time,
                                      baslik: 'Saat',
                                      secili: 'saat',
                                      ogeler: const [
                                        ['saat', 'Saati değiştir'],
                                        ['tum', 'Saati kaldır'],
                                      ],
                                    );
                                    if (secim == null || !sheetContext.mounted) return;
                                    if (secim == 'tum') {
                                      setModalState(() {
                                        hSaat = null;
                                        hatirlatmalar = hatirlatmalar.where((h) => h.birim == 'gun' || h.birim == 'hafta').toList();
                                        if (hatirlatmalar.isEmpty) hatirlatmalar = [Hatirlatma(0, 'gun', gunSaati: 540)];
                                      });
                                    } else {
                                      final int? dk = await _saatSecDk(hs, 'Saat kaçta?');
                                      if (dk == null || !sheetContext.mounted) return;
                                      setModalState(() => hSaat = dk);
                                    }
                                  },
                                ),
                              _formSatiri(
                                ikon: Icons.alarm,
                                baslik: 'Ne kadar önce hatırlatsın?',
                                deger: hatirlatmalar.isEmpty ? 'Hatırlatma yok' : hatirlatmalar.map((h) => _hatirlatmaMetni(h, hs == null)).join(', '),
                                onTap: () async {
                                  final List<Hatirlatma>? sonuc = await _hatirlatmaSecimiGoster(hs == null, hatirlatmalar);
                                  if (sonuc == null || !sheetContext.mounted) return;
                                  setModalState(() => hatirlatmalar = sonuc);
                                },
                              ),
                              InkWell(
                                onTap: () => setModalState(() {
                                  hTarih = null;
                                  hSaat = null;
                                  hatirlatmalar = [];
                                }),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                  child: Row(children: [Icon(Icons.notifications_off_outlined, size: 20, color: Colors.red), SizedBox(width: 12), Text('Hatırlatmayı kaldır', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600))]),
                                ),
                              ),
                            ],
                          ]),
                          if (hata != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(hata!, style: const TextStyle(color: Colors.red, fontSize: 12))),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            style: _anaDugmeStili,
                            onPressed: () {
                              final String baslik = baslikCtrl.text.trim();
                              final List<NotMaddesi> temiz = [];
                              for (final m in maddeler) {
                                final String t = (maddeKontrol[m.id]?.text ?? m.metin).trim();
                                if (t.isNotEmpty) temiz.add(NotMaddesi(id: m.id, metin: t, tamam: m.tamam, not: (notKontrol[m.id]?.text ?? m.not).trim()));
                              }
                              final String bekleyen = yeniMaddeCtrl.text.trim();
                              if (listeTuru && bekleyen.isNotEmpty) temiz.add(NotMaddesi(id: 'm${DateTime.now().microsecondsSinceEpoch}', metin: bekleyen));
                              final String metin = metinCtrl.text.trim();
                              if (baslik.isEmpty && (listeTuru ? temiz.isEmpty : metin.isEmpty)) {
                                setModalState(() => hata = 'Bir başlık veya içerik yaz.');
                                _hataliAlaniGoster(baslikAnahtar);
                                return;
                              }
                              final EtkinlikTuru? secilenKategori = notKategorileri.where((k) => k.id == kategori).firstOrNull;
                              final NotKaydi yeni = NotKaydi(
                                id: mevcut?.id ?? 'n${DateTime.now().microsecondsSinceEpoch}',
                                baslik: baslik,
                                liste: listeTuru,
                                metin: metin,
                                maddeler: listeTuru ? temiz : <NotMaddesi>[],
                                kategori: secilenKategori?.id ?? '',
                                renk: secilenKategori?.renk ?? 9,
                                sabit: sabit,
                                tamamlandi: listeTuru && temiz.isNotEmpty ? temiz.every((m) => m.tamam) : (mevcut?.tamamlandi ?? false),
                                fotolar: List<String>.from(fotolar),
                                olusturma: mevcut?.olusturma,
                                duzenleme: mevcut?.duzenleme,
                                hatirlatmaTarihi: hTarih,
                                hatirlatmaSaati: hTarih == null ? null : hSaat,
                                hatirlatmalar: hTarih == null ? <Hatirlatma>[] : hatirlatmalar.map((h) => h.kopya()).toList(),
                              );
                              for (final ad in silinenFotolar) {
                                _fotoSil(ad);
                              }
                              kaydedildi = true;
                              setState(() {
                                final int sira = mevcut == null ? -1 : notListesi.indexWhere((x) => x.id == mevcut.id);
                                if (sira >= 0) {
                                  notListesi[sira] = yeni;
                                } else {
                                  notListesi.add(yeni);
                                }
                                // Kaydedilen not açık filtre veya aramaya takılıp görünmez kalmasın
                                if (_notFiltre.isNotEmpty && _notFiltre != yeni.kategori) _notFiltre = '';
                                if (_notTurFiltresi == 'liste' && !yeni.liste) _notTurFiltresi = 'hepsi';
                                if (_notTurFiltresi == 'not' && yeni.liste) _notTurFiltresi = 'hepsi';
                                final String aranan = _aramaNormal(_notArama.trim());
                                if (aranan.isNotEmpty && !_aramaNormal('${yeni.baslik} ${yeni.metin} ${yeni.maddeler.map((m) => m.metin).join(' ')}').contains(aranan)) {
                                  _notArama = '';
                                  _notAramaAcik = false;
                                  _notAramaCtrl.clear();
                                }
                              });
                              _bildirimleriYenile();
                              Navigator.of(innerContext).pop();
                            },
                            child: Text(mevcut == null ? 'Kaydet' : 'Güncelle'),
                          ),
                          if (mevcut != null)
                            TextButton.icon(
                              onPressed: () {
                                Navigator.of(innerContext).pop();
                                _notSilOnayi(mevcut);
                              },
                              icon: const Icon(Icons.delete_outline, color: Colors.red),
                              label: const Text('Sil', style: TextStyle(color: Colors.red)),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    await ses.kapat();

    // Kaydedilmeden kapatıldıysa bu oturumda eklenen fotoğrafları temizle
    if (!kaydedildi) {
      for (final ad in yeniFotolar) {
        _fotoSil(ad);
      }
    }
  }

  // ============================== YARDIMCILAR: FOTOĞRAF ==============================

  void _snack(String metin) {
    final ScaffoldMessengerState gonderici = ScaffoldMessenger.of(context);
    gonderici.hideCurrentSnackBar();
    gonderici.showSnackBar(SnackBar(content: Text(metin), duration: const Duration(seconds: 3), persist: false, showCloseIcon: true));
  }

  // Etkinlik fotoğrafları uygulamanın kendi klasöründe dosya olarak saklanır
  Future<Directory> _fotoDizini() async {
    final Directory? mevcut = _fotoKlasoru;
    if (mevcut != null) return mevcut;
    Directory kok;
    try {
      kok = await getApplicationDocumentsDirectory();
    } catch (_) {
      // path_provider eklentisi uygulamaya kurulu değilse (ör. tam derleme yapılmadıysa) uygulamanın kendi klasörü kullanılır;
      // Android'de eklentinin verdiği klasörle aynı yerdir
      kok = Directory('/data/user/0/com.example.kisisel_asistan/app_flutter');
      if (!await kok.exists()) await kok.create(recursive: true);
    }
    final Directory d = Directory('${kok.path}/etkinlik_fotolari');
    if (!await d.exists()) await d.create(recursive: true);
    _fotoKlasoru = d;
    return d;
  }

  // Kameradan bir, galeriden birden fazla fotoğraf alır; küçültüp uygulama klasörüne kaydeder, dosya adlarını döndürür
  Future<List<String>> _fotolariSecVeKaydet(ImageSource kaynak) async {
    final List<String> adlar = [];
    if (kIsWeb) {
      if (mounted) _snack('Fotoğraf ekleme sadece telefon uygulamasında çalışır (tarayıcıda dosya sistemi yok).');
      return adlar;
    }
    try {
      final List<XFile> secilenler = [];
      if (kaynak == ImageSource.gallery) {
        secilenler.addAll(await kilitsizCalistir(() => ImagePicker().pickMultiImage(maxWidth: 1600, maxHeight: 1600, imageQuality: 85)));
      } else {
        final XFile? tek = await kilitsizCalistir(() => ImagePicker().pickImage(source: kaynak, maxWidth: 1600, maxHeight: 1600, imageQuality: 85));
        if (tek != null) secilenler.add(tek);
      }
      if (secilenler.isEmpty) return adlar;
      final Directory d = await _fotoDizini();
      final int zaman = DateTime.now().microsecondsSinceEpoch;
      for (int i = 0; i < secilenler.length; i++) {
        final Uint8List bytes = await secilenler[i].readAsBytes();
        final String ad = 'f${zaman}_$i.jpg';
        await File('${d.path}/$ad').writeAsBytes(bytes, flush: true);
        adlar.add(ad);
      }
    } catch (e) {
      if (mounted) _snack(adlar.isEmpty ? 'Fotoğraf eklenemedi: $e' : '${adlar.length} fotoğraf eklendi, kalanlar eklenemedi: $e');
    }
    return adlar;
  }

  Future<void> _fotoSil(String ad) async {
    final Directory? d = _fotoKlasoru;
    if (d == null) return;
    try {
      final File f = File('${d.path}/$ad');
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('Fotoğraf dosyası silinemedi: $e');
    }
  }

  Future<void> _tumEtkinlikFotolariniSil() async {
    final Directory? d = _fotoKlasoru;
    if (d == null) return;
    try {
      if (!await d.exists()) return;
      await for (final f in d.list()) {
        if (f is File) {
          try {
            await f.delete();
          } catch (e) {
      debugPrint('Fotoğraf dosyası silinemedi: $e');
    }
        }
      }
    } catch (e) {
      debugPrint('Fotoğraf klasörü temizlenemedi: $e');
    }
  }

  // Küçük fotoğraf kutucuğu (dosya bozuk/silinmişse sade bir yer tutucu gösterir)
  Widget _fotoKucukResmi(String ad, double boyut, {VoidCallback? onTap, VoidCallback? onSil}) {
    final Directory? d = _fotoKlasoru;
    final Widget yerTutucu = Container(color: gri(200), child: const Icon(Icons.broken_image_outlined, color: Colors.grey));
    final Widget resim = d == null
        ? yerTutucu
        : Image.file(
            File('${d.path}/$ad'),
            fit: BoxFit.cover,
            cacheWidth: (boyut * 3).round(),
            errorBuilder: (c, e, s) => yerTutucu,
          );
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(10), child: SizedBox(width: boyut, height: boyut, child: resim)),
          if (onSil != null)
            Positioned(
              top: -6,
              right: -6,
              child: InkWell(
                onTap: onSil,
                child: Container(
                  decoration: BoxDecoration(color: Colors.red, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                  padding: const EdgeInsets.all(3),
                  child: const Icon(Icons.close, size: 12, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Etkinlik içinde gösterilen küçük fotoğraf şeridi
  Widget _fotoSeridi(List<String> fotolar, {double boyut = 44}) {
    if (fotolar.isEmpty) return const SizedBox.shrink();
    final int gorunen = math.min(fotolar.length, 5);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (int i = 0; i < gorunen; i++) _fotoKucukResmi(fotolar[i], boyut, onTap: () => _fotoGoruntule(fotolar, i)),
        if (fotolar.length > gorunen)
          GestureDetector(
            onTap: () => _fotoGoruntule(fotolar, gorunen),
            child: Container(
              width: boyut,
              height: boyut,
              decoration: BoxDecoration(color: acikZemin, borderRadius: BorderRadius.circular(10)),
              alignment: Alignment.center,
              child: Text('+${fotolar.length - gorunen}', style: TextStyle(fontWeight: FontWeight.bold, color: anaRenk)),
            ),
          ),
      ],
    );
  }

  Future<void> _fotoGoruntule(List<String> fotolar, int baslangic, {Future<bool> Function(String ad)? sil}) async {
    final Directory? d = _fotoKlasoru;
    if (d == null || fotolar.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (ctx) => FotoGoruntuleyici(klasor: d.path, fotolar: fotolar, baslangic: baslangic, sil: sil),
      ),
    );
  }

  // ============================== PROFİLLER ==============================

  Future<void> _profilFotoKaydet() async {
    final prefs = await SharedPreferences.getInstance();
    final Uint8List? foto = _profilFoto;
    if (foto == null) {
      await prefs.remove('profil_foto_$aktifProfilId');
    } else {
      await prefs.setString('profil_foto_$aktifProfilId', base64Encode(foto));
    }
  }

  Future<void> _profilFotoSec(ImageSource kaynak) async {
    try {
      final secilen = await kilitsizCalistir(() => ImagePicker().pickImage(source: kaynak, maxWidth: 480, maxHeight: 480, imageQuality: 85));
      if (secilen == null) return;
      final Uint8List bytes = await secilen.readAsBytes();
      if (!mounted) return;
      setState(() => _profilFoto = bytes);
      await _profilFotoKaydet();
    } catch (e) {
      if (mounted) _snack('Fotoğraf eklenemedi: $e');
    }
  }

  void _profilFotoSecenekleriniGoster() {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _pencereBasligi(sheetContext, Icons.account_circle_outlined, 'Profil Fotoğrafı'),
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.photo_library_outlined, color: anaRenk),
              title: const Text('Galeriden seç'),
              onTap: () {
                Navigator.pop(sheetContext);
                _profilFotoSec(ImageSource.gallery);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.photo_camera_outlined, color: anaRenk),
              title: const Text('Kamera ile çek'),
              onTap: () {
                Navigator.pop(sheetContext);
                _profilFotoSec(ImageSource.camera);
              },
            ),
            if (_profilFoto != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Fotoğrafı kaldır', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  setState(() => _profilFoto = null);
                  _profilFotoKaydet();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _profilAvatariId(String id, double yaricap) {
    final Uint8List? foto = _profilFotolari[id];
    final String ad = profiller.where((p) => p.id == id).firstOrNull?.ad ?? '?';
    return CircleAvatar(
      radius: yaricap,
      backgroundColor: acikZemin,
      backgroundImage: foto == null ? null : MemoryImage(foto),
      child: foto == null ? Text(ad.isEmpty ? '?' : String.fromCharCode(ad.runes.first).toUpperCase(), style: TextStyle(fontSize: yaricap * 0.9, fontWeight: FontWeight.bold, color: anaRenk)) : null,
    );
  }

  Widget _profilAvatari(double yaricap) => _profilAvatariId(aktifProfilId, yaricap);

  Widget _profilKarti() {
    return _beyazKart(
      child: Row(
        children: [
          GestureDetector(
            onTap: _profilFotoSecenekleriniGoster,
            child: Stack(
              children: [
                _profilAvatari(32),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(color: anaRenk, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                    child: const Icon(Icons.camera_alt, size: 12, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Profil', style: TextStyle(fontSize: 11, color: gri(600))),
                const SizedBox(height: 2),
                Text(aktifHesapAdi, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: koyuYazi)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Profili düzenle',
            icon: Icon(Icons.edit, size: 20, color: anaRenk),
            onPressed: () => _profilDetaySayfasiniAc(aktifProfilId),
          ),
        ],
      ),
    );
  }

  // Aktif profili değiştirir: mevcut veri kaydedilir, hedef profilin verisi yüklenir
  Future<void> _profilDegistir(String id) async {
    if (id == aktifProfilId || !profiller.any((p) => p.id == id)) return;
    await _kaydetHemen();
    final prefs = await SharedPreferences.getInstance();
    final String? metin = prefs.getString('veri_$id');
    Map<String, dynamic> veri = {};
    if (metin != null) {
      try {
        veri = jsonDecode(metin) as Map<String, dynamic>;
      } catch (e) {
        debugPrint('Profil verisi okunamadı: $e');
        if (mounted) _snack('Bu profilin verisi okunamadı; geçiş iptal edildi (veri silinmedi).');
        return;
      }
    }
    if (!mounted) return;
    _okunamayanKayit = 0;
    setState(() {
      aktifProfilId = id;
      _veriyiUygula(veri);
      _sabitleriUret();
      _vurguluEtkinlikId = null;
      _vurguluFinansAnahtari = null;
      _ajandaGunSecimi = null;
      _ajandaAcikDurum.clear();
      _notFiltre = '';
      _notArama = '';
      _notAramaAcik = false;
      _notAramaCtrl.clear();
      _ajandaArama = '';
      _ajandaAramaAcik = false;
      _ajandaAramaCtrl.clear();
    });
    _sonKaydedilenJson = '';
    if (_okunamayanKayit > 0) {
      if (metin != null) await prefs.setString('veri_${id}_kurtarma', metin);
      if (mounted) _snack('$_okunamayanKayit kayıt okunamadı ve atlandı; ham kopya saklandı.');
    }
    _bildirimleriYenile();
  }

  Future<void> _profilEkle(String ad) async {
    final String temiz = ad.trim();
    final String yeniId = 'p${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      profiller.add(Profil(id: yeniId, ad: temiz.isEmpty ? 'Yeni Profil' : temiz));
    });
    await _profilDegistir(yeniId); // kayıtlı veri olmadığı için boş bir profil açılır
  }

  Future<void> _profilSil(String id) async {
    if (profiller.length <= 1) return;
    final prefs = await SharedPreferences.getInstance();

    // Silinecek profilin etkinlik fotoğraflarını bul
    final List<String> fotolar = [];
    final String? metin = id == aktifProfilId ? jsonEncode(_veriHaritasi()) : prefs.getString('veri_$id');
    if (metin != null) {
      try {
        final veri = jsonDecode(metin) as Map<String, dynamic>;
        for (final anahtar in ['etkinlikler', 'notlar', 'notArsivi', 'copNotlari', 'copEtkinlikleri']) {
          for (final e in (veri[anahtar] as List? ?? [])) {
            for (final f in ((e as Map)['fotolar'] as List? ?? [])) {
              fotolar.add(f.toString());
            }
          }
        }
      } catch (e) {
      debugPrint('Silinecek profilin fotoğrafları bulunamadı: $e');
    }
    }

    if (id == aktifProfilId) {
      final String diger = profiller.firstWhere((p) => p.id != id).id;
      await _profilDegistir(diger);
    }
    if (!mounted) return;
    setState(() {
      profiller.removeWhere((p) => p.id == id);
      _profilFotolari.remove(id);
    });
    await prefs.remove('veri_$id');
    await prefs.remove('profil_foto_$id');
    for (final f in fotolar) {
      await _fotoSil(f);
    }
    await _kaydetHemen();
    _bildirimleriYenile();
  }

  Future<String?> _profilAdiDialogu({String baslangic = '', required String baslik}) async {
    final ctrl = TextEditingController(text: baslangic);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(baslik),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Profil adı', hintText: 'Örn: Ayşe, İş, Annem'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
          ElevatedButton(
            style: _anaDugmeStili,
            onPressed: () {
              final String ad = ctrl.text.trim();
              if (ad.isEmpty) return;
              Navigator.pop(ctx, ad);
            },
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
  }

  Future<void> _yeniProfilEkleAkisi() async {
    final String? ad = await _profilAdiDialogu(baslik: 'Yeni Profil');
    if (ad == null || !mounted) return;
    await _profilEkle(ad);
    if (mounted) _snack('"$ad" profili oluşturuldu ve açıldı.');
  }

  // Finans başlığına dokununca açılan hızlı profil seçimi
  void _profilSecimiGoster() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.8),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _pencereBasligi(sheetContext, Icons.groups_outlined, 'Profil Seç'),
            const Divider(),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: profiller.map((p) {
                    final bool aktif = p.id == aktifProfilId;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: _profilAvatariId(p.id, 20),
                      title: Text(p.ad, style: TextStyle(fontWeight: aktif ? FontWeight.bold : FontWeight.w500)),
                      trailing: aktif ? Icon(Icons.check_circle, color: anaRenk, size: 20) : null,
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _profilDegistir(p.id);
                      },
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _yeniProfilEkleAkisi();
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Yeni Profil'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _profillerSayfasiniAc();
                    },
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Yönet'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ============================== AYARLAR ALT SAYFALARI ==============================

  // Telefon ayarları gibi: ana başlığa dokununca kendi sayfası açılır
  void _altSayfaAc(String baslik, List<Widget> Function() govde) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (ctx) => Scaffold(
          backgroundColor: zemin,
          appBar: AppBar(
            backgroundColor: zemin,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            iconTheme: IconThemeData(color: koyuYazi),
            title: Text(baslik, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: koyuYazi)),
          ),
          body: SafeArea(
            child: ValueListenableBuilder<int>(
              valueListenable: _arayuzSurumu,
              builder: (c, surum, cocuk) => ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: govde()),
            ),
          ),
        ),
      ),
    );
  }

  Widget _ayarAyraci() => Divider(height: 1, indent: 72, endIndent: 16, color: gri(100));

  Widget _ayarAnahtari({required IconData ikon, required Color renk, required String baslik, required String alt, required bool deger, required ValueChanged<bool> degisti}) {
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      secondary: _ikonKutusu(ikon, renk: renk),
      title: Text(baslik, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: koyuYazi)),
      subtitle: Text(alt, style: TextStyle(fontSize: 12, color: gri(600))),
      value: deger,
      onChanged: degisti,
    );
  }

  String _bildirimOzetMetni() {
    final String izin = _bildirimIzniVar == null ? 'Kontrol ediliyor…' : (_bildirimIzniVar == true ? 'Açık' : 'Kapalı');
    return '$izin • ${bildirimGuvenilirMod ? 'Güvenilir mod' : 'Standart mod'}';
  }

  String _otoYedekSikligiMetni() {
    switch (otoYedekGunu) {
      case 2:
        return '2 günde bir';
      case 3:
        return '3 günde bir';
      case 7:
        return 'Haftada bir';
      default:
        return 'Her gün';
    }
  }

  String _otoYedekDurumMetni() {
    final DateTime? t = _sonOtoYedek;
    String metin;
    if (t == null) {
      metin = 'Henüz otomatik yedek alınmadı. Uygulama arka plana geçince alınır.';
    } else {
      final int gun = DateTime.now().difference(t).inDays;
      metin = '${DateFormat('d MMMM yyyy, HH:mm', 'tr_TR').format(t)} (${gun < 1 ? 'bugün' : '$gun gün önce'})';
    }
    if (_sonOtoYedekHata != null) metin += '\nSon deneme başarısız: $_sonOtoYedekHata';
    return metin;
  }

  String _yedekOzetMetni() {
    final DateTime? t = _sonYedekTarihi;
    if (t == null) return 'Şimdi yedek dosyası oluştur • Henüz elle yedek alınmadı';
    final int gun = DateTime.now().difference(t).inDays;
    return 'Şimdi yedek dosyası oluştur • Son elle yedek: ${DateFormat('d MMMM yyyy', 'tr_TR').format(t)} (${gun < 1 ? 'bugün' : '$gun gün önce'})';
  }

  // Ayarlar listesindeki özet: elle ya da otomatik, hangisi daha yeniyse onu gösterir
  String _yedekGenelMetni() {
    final DateTime? e = _sonYedekTarihi;
    final DateTime? o = _sonOtoYedek;
    if (e == null && o == null) return 'Henüz yedek alınmadı';
    final bool otoYeni = o != null && (e == null || o.isAfter(e));
    final DateTime t = otoYeni ? o : e!;
    final int gun = DateTime.now().difference(t).inDays;
    return 'Son yedek: ${DateFormat('d MMMM yyyy, HH:mm', 'tr_TR').format(t)} (${otoYeni ? 'otomatik' : 'elle'}, ${gun < 1 ? 'bugün' : '$gun gün önce'})';
  }

  // ============================== ARŞİV VE ÇÖP KUTUSU ==============================

  void _notArsivle(NotKaydi n) {
    _geriAlliSil('Not arşivlendi', ['notlar', 'notArsivi'], () {
      setState(() {
        notListesi.removeWhere((x) => x.id == n.id);
        n.sabit = false;
        notArsivi.insert(0, n);
      });
      _bildirimleriYenile();
    });
  }

  void _notArsivdenCikar(NotKaydi n) {
    _geriAlliSil('Not arşivden çıkarıldı', ['notlar', 'notArsivi'], () {
      setState(() {
        notArsivi.removeWhere((x) => x.id == n.id);
        notListesi.add(n);
      });
      _bildirimleriYenile();
    });
  }

  void _arsivNotunuCopeAt(NotKaydi n) {
    _geriAlliSil('Not çöp kutusuna taşındı', ['notArsivi', 'copNotlari'], () {
      n.silinme = DateTime.now();
      setState(() {
        notArsivi.removeWhere((x) => x.id == n.id);
        copNotlari.insert(0, n);
      });
    });
  }

  void _copNotunuGeriYukle(NotKaydi n) {
    _geriAlliSil('Not geri yüklendi', ['notlar', 'copNotlari'], () {
      n.silinme = null;
      setState(() {
        copNotlari.removeWhere((x) => x.id == n.id);
        notListesi.add(n);
      });
      _bildirimleriYenile();
    });
  }

  void _copEtkinliginiGeriYukle(Etkinlik e) {
    _geriAlliSil('Etkinlik geri yüklendi', ['etkinlikler', 'copEtkinlikleri'], () {
      e.silinme = null;
      setState(() {
        copEtkinlikleri.removeWhere((x) => x.id == e.id);
        etkinlikListesi.add(e);
      });
      _bildirimleriYenile();
    });
  }

  void _copNotunuKaliciSil(NotKaydi n) {
    _silmeOnayiGoster(context, '"${_notBasligi(n)}" kalıcı olarak silinecek. Bu işlem geri alınamaz.', () {
      for (final f in n.fotolar) {
        _fotoSil(f);
      }
      setState(() => copNotlari.removeWhere((x) => x.id == n.id));
    });
  }

  void _copEtkinliginiKaliciSil(Etkinlik e) {
    _silmeOnayiGoster(context, '"${e.baslik}" kalıcı olarak silinecek. Bu işlem geri alınamaz.', () {
      for (final f in e.fotolar) {
        _fotoSil(f);
      }
      setState(() => copEtkinlikleri.removeWhere((x) => x.id == e.id));
    });
  }

  void _copuBosalt() {
    final int toplam = copNotlari.length + copEtkinlikleri.length;
    if (toplam == 0) return;
    _silmeOnayiGoster(context, 'Çöp kutusundaki $toplam öğe kalıcı olarak silinecek. Bu işlem geri alınamaz.', () {
      for (final n in copNotlari) {
        for (final f in n.fotolar) {
          _fotoSil(f);
        }
      }
      for (final e in copEtkinlikleri) {
        for (final f in e.fotolar) {
          _fotoSil(f);
        }
      }
      setState(() {
        copNotlari.clear();
        copEtkinlikleri.clear();
      });
    });
  }

  // Süresi dolan çöp kutusu öğelerini (ve fotoğraflarını) kalıcı olarak siler
  void _copuTemizle() {
    if (!_yuklendi) return;
    final DateTime sinir = DateTime.now().subtract(Duration(days: copSuresiGun));
    final List<NotKaydi> eskiNotlar = copNotlari.where((n) => n.silinme != null && n.silinme!.isBefore(sinir)).toList();
    final List<Etkinlik> eskiEtkinlikler = copEtkinlikleri.where((e) => e.silinme != null && e.silinme!.isBefore(sinir)).toList();
    if (eskiNotlar.isEmpty && eskiEtkinlikler.isEmpty) return;
    for (final n in eskiNotlar) {
      for (final f in n.fotolar) {
        _fotoSil(f);
      }
    }
    for (final e in eskiEtkinlikler) {
      for (final f in e.fotolar) {
        _fotoSil(f);
      }
    }
    setState(() {
      copNotlari.removeWhere((n) => eskiNotlar.contains(n));
      copEtkinlikleri.removeWhere((e) => eskiEtkinlikler.contains(e));
    });
  }

  String _copKalanMetni(DateTime? silinme) {
    if (silinme == null) return '';
    final int kalan = copSuresiGun - DateTime.now().difference(silinme).inDays;
    return kalan <= 0 ? 'Bugün kalıcı olarak silinecek' : '$kalan gün sonra kalıcı olarak silinecek';
  }

  Widget _notMenusu() {
    return PopupMenuButton<String>(
      tooltip: 'Arşiv ve çöp kutusu',
      onSelected: (v) => _arsivCopSayfasiniAc(cop: v == 'cop'),
      itemBuilder: (c) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: 'arsiv', child: Row(children: [const Icon(Icons.archive_outlined, size: 18), const SizedBox(width: 10), Text('Arşiv (${notArsivi.length})')])),
        PopupMenuItem<String>(value: 'cop', child: Row(children: [const Icon(Icons.delete_outline, size: 18), const SizedBox(width: 10), Text('Çöp kutusu (${copNotlari.length + copEtkinlikleri.length})')])),
      ],
      child: Container(
        decoration: BoxDecoration(color: griDugme, shape: BoxShape.circle),
        padding: const EdgeInsets.all(8),
        child: Icon(Icons.more_vert, size: 18, color: ikonGri),
      ),
    );
  }

  Widget _arsivKaydiKarti({
    required Color renk,
    required IconData ikon,
    required String baslik,
    required String sorgu,
    required List<Widget> govde,
    required String alt,
    required VoidCallback onTap,
    required List<Widget> islemler,
  }) {
    final Color koyu = _koyu(renk);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: _pastel(renk),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: renk.withValues(alpha: 0.3)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(padding: const EdgeInsets.only(top: 1), child: Icon(ikon, size: 20, color: renk)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _vurguluMetin(baslik, sorgu, TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: koyu), maxLines: 2),
                      ...govde,
                      const SizedBox(height: 6),
                      Text(alt, style: TextStyle(fontSize: 11, color: gri(600))),
                    ],
                  ),
                ),
                ...islemler,
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Arşiv veya çöp kutusu sayfası: içinde arama yapılır
  void _arsivCopSayfasiniAc({required bool cop}) {
    final TextEditingController ctrl = TextEditingController();
    String sorgu = '';
    Navigator.of(context)
        .push(
      MaterialPageRoute<void>(
        builder: (ctx) => StatefulBuilder(
          builder: (c, setS) => ValueListenableBuilder<int>(
            valueListenable: _arayuzSurumu,
            builder: (c2, surum, w) {
              final String q = _aramaNormal(sorgu.trim());
              bool notUyar(NotKaydi n) => q.isEmpty || _aramaNormal(n.baslik).contains(q) || _aramaNormal(n.metin).contains(q) || n.maddeler.any((m) => _aramaNormal(m.metin).contains(q) || _aramaNormal(m.not).contains(q));
              bool etkUyar(Etkinlik e) => q.isEmpty || _aramaNormal(e.baslik).contains(q) || _aramaNormal(e.notlar).contains(q);

              final List<(DateTime, Widget)> ogeler = [];
              for (final n in (cop ? copNotlari : notArsivi).where(notUyar)) {
                final String tur = n.liste ? 'Liste' : 'Not';
                final List<Widget> govde = [];
                if (q.isNotEmpty) {
                  govde.addAll(_notAramaOzeti(n, sorgu.trim()));
                } else if (n.liste && n.maddeler.isNotEmpty) {
                  govde.add(Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(n.maddeler.take(3).map((m) => '${m.tamam ? '✓' : '•'} ${m.metin}').join('\n'), maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: gri(800))),
                  ));
                } else if (!n.liste && n.metin.trim().isNotEmpty) {
                  govde.add(Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(n.metin.trim(), maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: gri(800))),
                  ));
                }
                ogeler.add((
                  (cop ? n.silinme : null) ?? n.olusturma,
                  _arsivKaydiKarti(
                    renk: _notRengi(n),
                    ikon: n.liste ? Icons.checklist : Icons.notes,
                    baslik: _notBasligi(n),
                    sorgu: sorgu,
                    govde: govde,
                    alt: cop ? '$tur • ${_copKalanMetni(n.silinme)}' : '$tur • ${DateFormat('d MMM yyyy', 'tr_TR').format(n.olusturma)}',
                    onTap: () => _notOnizlemesiGoster(n),
                    islemler: cop
                        ? [
                            IconButton(tooltip: 'Geri yükle', icon: Icon(Icons.restore, size: 22, color: gelirRengi), onPressed: () => _copNotunuGeriYukle(n)),
                            IconButton(tooltip: 'Kalıcı sil', icon: Icon(Icons.delete_forever, size: 22, color: giderRengi), onPressed: () => _copNotunuKaliciSil(n)),
                          ]
                        : [
                            IconButton(tooltip: 'Arşivden çıkar', icon: Icon(Icons.unarchive_outlined, size: 22, color: gelirRengi), onPressed: () => _notArsivdenCikar(n)),
                            IconButton(tooltip: 'Çöp kutusuna taşı', icon: Icon(Icons.delete_outline, size: 22, color: giderRengi), onPressed: () => _arsivNotunuCopeAt(n)),
                          ],
                  ),
                ));
              }
              if (cop) {
                for (final e in copEtkinlikleri.where(etkUyar)) {
                  final EtkinlikTuru tur = _turBul(e.turId);
                  final List<Widget> govde = [];
                  if (e.notlar.trim().isNotEmpty) {
                    govde.add(Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _vurguluMetin(e.notlar.trim(), sorgu, TextStyle(fontSize: 13, color: gri(800)), maxLines: 3),
                    ));
                  }
                  ogeler.add((
                    e.silinme ?? e.baslangic,
                    _arsivKaydiKarti(
                      renk: tur.renkVerisi,
                      ikon: tur.ikonVerisi,
                      baslik: e.baslik,
                      sorgu: sorgu,
                      govde: govde,
                      alt: 'Etkinlik • ${DateFormat('d MMM yyyy', 'tr_TR').format(e.baslangic)} • ${_copKalanMetni(e.silinme)}',
                      onTap: () => _etkinlikOnizlemesiGoster(e),
                      islemler: [
                        IconButton(tooltip: 'Geri yükle', icon: Icon(Icons.restore, size: 22, color: gelirRengi), onPressed: () => _copEtkinliginiGeriYukle(e)),
                        IconButton(tooltip: 'Kalıcı sil', icon: Icon(Icons.delete_forever, size: 22, color: giderRengi), onPressed: () => _copEtkinliginiKaliciSil(e)),
                      ],
                    ),
                  ));
                }
              }
              ogeler.sort((a, b) => b.$1.compareTo(a.$1));

              final int toplam = cop ? copNotlari.length + copEtkinlikleri.length : notArsivi.length;
              return Scaffold(
                backgroundColor: zemin,
                appBar: AppBar(
                  backgroundColor: zemin,
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  iconTheme: IconThemeData(color: koyuYazi),
                  title: Text(cop ? 'Çöp kutusu' : 'Arşiv', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: koyuYazi)),
                  actions: [
                    if (cop && toplam > 0) TextButton(onPressed: _copuBosalt, child: Text('Boşalt', style: TextStyle(color: giderRengi, fontWeight: FontWeight.bold))),
                  ],
                ),
                body: SafeArea(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                        child: _aramaKutusu(
                          kontrol: ctrl,
                          ipucu: cop ? 'Çöp kutusunda ara…' : 'Arşivde ara…',
                          otoOdak: false,
                          degisti: (v) => setS(() => sorgu = v),
                          temizle: () {
                            ctrl.clear();
                            setS(() => sorgu = '');
                          },
                        ),
                      ),
                      if (cop)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline, size: 14, color: gri(600)),
                              const SizedBox(width: 6),
                              Expanded(child: Text('Çöp kutusundaki öğeler $copSuresiGun gün sonra kalıcı olarak silinir.', style: TextStyle(fontSize: 12, color: gri(600)))),
                            ],
                          ),
                        ),
                      Expanded(
                        child: ogeler.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(30),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(cop ? Icons.delete_outline : Icons.archive_outlined, size: 56, color: gri(400)),
                                      const SizedBox(height: 10),
                                      Text(
                                        q.isNotEmpty ? 'Aramayla eşleşen kayıt yok.' : (cop ? 'Çöp kutusu boş.' : 'Arşivde not yok.\nNot kartındaki ⋮ menüsünden "Arşivle" diyebilirsin.'),
                                        textAlign: TextAlign.center,
                                        style: TextStyle(color: gri(600)),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [for (final o in ogeler) o.$2]),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    )
        .then((_) => ctrl.dispose());
  }

  // Arşivdeki / çöpteki notun içeriğini salt okunur gösterir
  void _notOnizlemesiGoster(NotKaydi n) {
    final EtkinlikTuru? kategori = _notKategorisi(n);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.8),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _pencereBasligi(c, n.liste ? Icons.checklist : Icons.notes, _notBasligi(n)),
            const Divider(),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (kategori != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: _notKucukEtiket(kategori.ikonVerisi, kategori.ad, _koyu(kategori.renkVerisi))),
                    if (n.liste)
                      for (final m in n.maddeler)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(m.tamam ? Icons.check_box : Icons.check_box_outline_blank, size: 20, color: m.tamam ? gelirRengi : gri(500)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(m.metin, style: TextStyle(fontSize: 14, color: m.tamam ? gri(600) : yaziRengi, decoration: m.tamam ? TextDecoration.lineThrough : null)),
                                    if (m.not.isNotEmpty) Text(m.not, style: TextStyle(fontSize: 12, color: gri(600))),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        )
                    else
                      SelectableText(n.metin, style: TextStyle(fontSize: 15, color: yaziRengi)),
                    if (n.fotolar.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: _fotoSeridi(n.fotolar, boyut: 72)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Çöp kutusundaki etkinliğin bilgisini salt okunur gösterir
  void _etkinlikOnizlemesiGoster(Etkinlik e) {
    final EtkinlikTuru tur = _turBul(e.turId);
    final String saat = e.tumGun || e.zamanlar.isEmpty ? 'Tüm gün' : e.zamanlar.map((z) => z.saatMetni).join(', ');
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.8),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _pencereBasligi(c, tur.ikonVerisi, e.baslik),
            const Divider(),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${tur.ad} • ${DateFormat('d MMMM yyyy', 'tr_TR').format(e.baslangic)} • $saat', style: TextStyle(fontSize: 13, color: gri(700))),
                    if (e.tekrar != 'yok') Padding(padding: const EdgeInsets.only(top: 4), child: Text('Tekrar: ${_tekrarMetni(e)}', style: TextStyle(fontSize: 13, color: gri(700)))),
                    if (e.notlar.trim().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: SelectableText(e.notlar.trim(), style: TextStyle(fontSize: 15, color: yaziRengi))),
                    if (e.fotolar.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: _fotoSeridi(e.fotolar, boyut: 72)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Ayarlar > Arşiv ve çöp kutusu
  void _arsivCopAyarSayfasiniAc() {
    _altSayfaAc('Arşiv ve çöp kutusu', () {
      Widget sureSecenegi(int gun) {
        final bool secili = copSuresiGun == gun;
        return ListTile(
          leading: _ikonKutusu(Icons.timer_outlined, renk: secili ? anaRenk : gri(600)),
          title: Text('$gun gün', style: TextStyle(fontWeight: secili ? FontWeight.bold : FontWeight.w600, fontSize: 14, color: koyuYazi)),
          trailing: secili ? Icon(Icons.check_circle, color: anaRenk) : Icon(Icons.radio_button_unchecked, color: gri(400)),
          onTap: () {
            setState(() => copSuresiGun = gun);
            _globalAyarlariKaydet();
            _copuTemizle();
          },
        );
      }

      return [
        _ayarGrubu([
          _ayarSatiri(
            ikon: Icons.archive_outlined,
            renk: odenenRengi,
            baslik: 'Arşiv',
            alt: '${notArsivi.length} not',
            onTap: () => _arsivCopSayfasiniAc(cop: false),
          ),
          _ayarSatiri(
            ikon: Icons.delete_outline,
            renk: giderRengi,
            baslik: 'Çöp kutusu',
            alt: '${copNotlari.length} not • ${copEtkinlikleri.length} etkinlik',
            onTap: () => _arsivCopSayfasiniAc(cop: true),
          ),
        ]),
        _ayarGrupBasligi('Çöp kutusunda saklama süresi'),
        _ayarGrubu([sureSecenegi(7), sureSecenegi(14), sureSecenegi(30)]),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
          child: Text('Silinen not ve etkinlikler bu süre boyunca çöp kutusunda bekler, sonra fotoğraflarıyla birlikte kalıcı olarak silinir. Süreyi kısaltırsan süresi dolanlar hemen silinir.', style: TextStyle(fontSize: 12, color: gri(600))),
        ),
      ];
    });
  }

  // Ayarlar listesinde grupların üstündeki küçük başlık
  Widget _ayarGrupBasligi(String metin) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 26, 8, 8),
      child: Text(metin, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: gri(600))),
    );
  }

  // Bir gruptaki satırları tek kartta, aralarında ince çizgiyle gösterir
  Widget _ayarGrubu(List<Widget> satirlar) {
    return _beyazKart(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          for (int i = 0; i < satirlar.length; i++) ...[
            if (i > 0) _ayarAyraci(),
            satirlar[i],
          ],
        ],
      ),
    );
  }

  Widget _buildAyarlarSekmesi() {
    return Column(
      children: [
        _sayfaBasligi(_profilBasligi(), const []),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
            children: [
              _profilKarti(),

              _ayarGrupBasligi('Hesap'),
              _ayarGrubu([
                _ayarSatiri(
                  ikon: Icons.groups_outlined,
                  renk: anaRenk,
                  baslik: 'Profiller',
                  alt: '${profiller.length} profil • Aktif: $aktifHesapAdi',
                  onTap: () => _profillerSayfasiniAc(),
                ),
              ]),

              _ayarGrupBasligi('Uygulama'),
              _ayarGrubu([
                _ayarSatiri(
                  ikon: Icons.palette_outlined,
                  renk: _turRengi('Görev'),
                  baslik: 'Görünüm',
                  alt: 'Tema: ${_temaAdi(temaModu.value)}',
                  onTap: () => _gorunumSayfasiniAc(),
                ),
                _ayarSatiri(
                  ikon: Icons.notifications_active_outlined,
                  renk: kalanBorcRengi,
                  baslik: 'Bildirimler',
                  alt: _bildirimOzetMetni(),
                  onTap: () => _bildirimSayfasiniAc(),
                ),
              ]),

              _ayarGrupBasligi('Finans'),
              _ayarGrubu([
                _ayarSatiri(
                  ikon: Icons.credit_card_rounded,
                  renk: _turRengi('Kredi Kartı'),
                  baslik: 'Kartlar, krediler ve sabit ödemeler',
                  alt: '${krediKartiListesi.length} kart • ${kartTaksitListesi.length} taksit • ${krediListesi.length} kredi • ${sabitListesi.length} sabit',
                  onTap: _krediKartlariYonetimDialogGoster,
                ),
                _ayarSatiri(
                  ikon: Icons.payments_outlined,
                  renk: giderRengi,
                  baslik: 'Ödeme hatırlatmaları',
                  alt: finansBildirimAcik ? '${finansHatirlatmalari.length} hatırlatma${finansGecikmeBildirimi ? ' • gecikme uyarısı açık' : ''}' : 'Kapalı',
                  onTap: () => _odemeHatirlatmaSayfasiniAc(),
                ),
              ]),

              _ayarGrupBasligi('Veri ve güvenlik'),
              _ayarGrubu([
                _ayarSatiri(
                  ikon: Icons.lock_outline_rounded,
                  renk: gelirRengi,
                  baslik: 'Güvenlik',
                  alt: uygulamaKilidiAcik ? 'Uygulama kilidi açık' : 'Uygulama kilidi kapalı',
                  onTap: () => _guvenlikSayfasiniAc(),
                ),
                _ayarSatiri(
                  ikon: Icons.cloud_upload_outlined,
                  renk: odenenRengi,
                  baslik: 'Yedekleme',
                  alt: _yedekGenelMetni(),
                  onTap: () => _yedeklemeSayfasiniAc(),
                ),
                _ayarSatiri(
                  ikon: Icons.inventory_2_outlined,
                  renk: kalanBorcRengi,
                  baslik: 'Arşiv ve çöp kutusu',
                  alt: '${notArsivi.length} arşivde • ${copNotlari.length + copEtkinlikleri.length} çöpte',
                  onTap: () => _arsivCopAyarSayfasiniAc(),
                ),
                _ayarSatiri(
                  ikon: Icons.delete_forever,
                  renk: Colors.red,
                  baslik: 'Verileri sıfırla',
                  alt: 'Silme ve sıfırlama seçenekleri',
                  onTap: () => _veriSayfasiniAc(),
                ),
              ]),

              _ayarGrupBasligi('Hakkında'),
              _ayarGrubu([
                _ayarSatiri(
                  ikon: Icons.info_outline,
                  renk: anaRenk,
                  baslik: 'Uygulama bilgisi',
                  alt: 'Pil, bildirim ve izinleri telefon ayarlarından yönet',
                  sagIkon: Icons.open_in_new,
                  onTap: () => _uygulamaBilgisiniAc(),
                ),
              ]),
            ],
          ),
        ),
      ],
    );
  }

  String _temaAdi(String m) => m == 'koyu' ? 'Koyu' : (m == 'acik' ? 'Açık' : 'Sistem varsayılanı');

  Future<void> _temaSec(String m) async {
    temaModu.value = m;
    setState(() {});
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('tema_modu', m);
    } catch (e) {
      debugPrint('Tema tercihi kaydedilemedi: $e');
    }
  }

  String _kilitBeklemeMetni(int dk) => dk == 0 ? 'Uygulamadan her çıkışta' : '$dk dakika sonra';

  Future<void> _kilidiDegistir(bool ac) async {
    if (ac) {
      bool destek = true;
      try {
        destek = await _yerelDogrulama.isDeviceSupported();
      } catch (_) {}
      if (!destek) {
        _snack('Önce telefonunda bir ekran kilidi (PIN, desen veya parmak izi) kurmalısın.');
        return;
      }
    }
    final bool? ok = await kilitDogrula(ac ? 'Uygulama kilidini açmak için doğrulayın' : 'Uygulama kilidini kapatmak için doğrulayın');
    if (ok == null || !mounted) return;
    if (!ok) {
      _snack('Doğrulama yapılamadı, ayar değişmedi.');
      return;
    }
    setState(() => uygulamaKilidiAcik = ac);
    _globalAyarlariKaydet();
  }

  Future<void> _kilitBeklemeSec() async {
    final int? secim = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Ne zaman tekrar kilitlensin?'),
        children: [
          for (final int dk in const [0, 1, 5])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, dk),
              child: Row(
                children: [
                  Expanded(child: Text(_kilitBeklemeMetni(dk), style: TextStyle(fontWeight: dk == kilitBeklemeDk ? FontWeight.bold : FontWeight.normal))),
                  if (dk == kilitBeklemeDk) Icon(Icons.check, color: anaRenk),
                ],
              ),
            ),
        ],
      ),
    );
    if (secim == null || !mounted) return;
    setState(() => kilitBeklemeDk = secim);
    _globalAyarlariKaydet();
  }

  void _guvenlikSayfasiniAc() {
    _altSayfaAc('Güvenlik', () {
      return [
        _beyazKart(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              _ayarAnahtari(
                ikon: Icons.fingerprint,
                renk: gelirRengi,
                baslik: 'Uygulama kilidi',
                alt: 'Alfred açılırken parmak izi, yüz veya telefonun ekran kilidiyle doğrulama ister',
                deger: uygulamaKilidiAcik,
                degisti: (v) => _kilidiDegistir(v),
              ),
              if (uygulamaKilidiAcik) ...[
                _ayarAyraci(),
                _ayarSatiri(
                  ikon: Icons.timer_outlined,
                  renk: anaRenk,
                  baslik: 'Tekrar kilitleme',
                  alt: _kilitBeklemeMetni(kilitBeklemeDk),
                  onTap: () => _kilitBeklemeSec(),
                ),
              ],
              _ayarAyraci(),
              _ayarAnahtari(
                ikon: Icons.visibility_off_outlined,
                renk: kalanBorcRengi,
                baslik: 'İçeriği gizle',
                alt: 'Son uygulamalar ekranında önizleme boş görünür; ekran görüntüsü alınamaz',
                deger: ekranGizle,
                degisti: (v) {
                  setState(() => ekranGizle = v);
                  _globalAyarlariKaydet();
                  ekranGizleUygula(v);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            'Kilit yalnızca ekranı korur; verileri şifrelemez. Bildirimler ve widget telefonun kendi kilit ekranı kurallarına göre görünür.',
            style: TextStyle(fontSize: 12, color: gri(600)),
          ),
        ),
      ];
    });
  }

  void _gorunumSayfasiniAc() {
    _altSayfaAc('Görünüm', () {
      Widget secenek(String m, IconData ikon, String baslik, String alt) {
        final bool secili = temaModu.value == m;
        return ListTile(
          leading: _ikonKutusu(ikon, renk: secili ? anaRenk : gri(600)),
          title: Text(baslik, style: TextStyle(fontWeight: secili ? FontWeight.bold : FontWeight.w600, fontSize: 14, color: koyuYazi)),
          subtitle: Text(alt, style: TextStyle(fontSize: 12, color: gri(600))),
          trailing: secili ? Icon(Icons.check_circle, color: anaRenk) : Icon(Icons.radio_button_unchecked, color: gri(400)),
          onTap: () => _temaSec(m),
        );
      }

      return [
        _beyazKart(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              secenek('sistem', Icons.brightness_auto_outlined, 'Sistem varsayılanı', 'Telefonun açık / koyu ayarını izler'),
              _ayarAyraci(),
              secenek('acik', Icons.light_mode_outlined, 'Açık', 'Her zaman açık tema'),
              _ayarAyraci(),
              secenek('koyu', Icons.dark_mode_outlined, 'Koyu', 'Her zaman koyu tema'),
            ],
          ),
        ),
      ];
    });
  }

  void _profillerSayfasiniAc() {
    _altSayfaAc('Profiller', () {
      return [
        _beyazKart(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              for (int i = 0; i < profiller.length; i++) ...[
                if (i > 0) _ayarAyraci(),
                ListTile(
                  leading: _profilAvatariId(profiller[i].id, 22),
                  title: Text(profiller[i].ad, style: TextStyle(fontWeight: profiller[i].id == aktifProfilId ? FontWeight.bold : FontWeight.w600, fontSize: 14, color: koyuYazi)),
                  subtitle: Text(profiller[i].id == aktifProfilId ? 'Aktif profil • düzenlemek için dokun' : 'Geçmek için dokun', style: TextStyle(fontSize: 12, color: profiller[i].id == aktifProfilId ? anaRenk : gri(600))),
                  onTap: () async {
                    final Profil p = profiller[i];
                    if (p.id == aktifProfilId) {
                      _profilDetaySayfasiniAc(p.id);
                      return;
                    }
                    final bool? evet = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Profil değiştirilsin mi?'),
                        content: Text('"${p.ad}" profiline geçilecek.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
                          ElevatedButton(style: _anaDugmeStili, onPressed: () => Navigator.pop(ctx, true), child: const Text('Geç')),
                        ],
                      ),
                    );
                    if (evet == true && mounted) await _profilDegistir(p.id);
                  },
                  trailing: profiller[i].id == aktifProfilId
                      ? null
                      : PopupMenuButton<String>(
                          onSelected: (v) {
                            final Profil p = profiller[i];
                            if (v == 'duzenle') {
                              _profilDetaySayfasiniAc(p.id);
                            } else if (v == 'sil') {
                              _silmeOnayiGoster(context, '"${p.ad}" profili ve içindeki tüm finans, ajanda verileri silinecek. Bu işlem geri alınamaz.', () => _profilSil(p.id));
                            }
                          },
                          itemBuilder: (c) => [
                            const PopupMenuItem(value: 'duzenle', child: Text('Düzenle')),
                            const PopupMenuItem(value: 'sil', child: Text('Sil', style: TextStyle(color: Colors.red))),
                          ],
                        ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: _anaDugmeStili,
            onPressed: () => _yeniProfilEkleAkisi(),
            icon: const Icon(Icons.add),
            label: const Text('Yeni Profil Ekle'),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Her profilin finans kayıtları, ajandası ve ayarları birbirinden tamamen bağımsızdır. Tüm profillerin hatırlatmaları bildirim olarak gelmeye devam eder.',
          style: TextStyle(fontSize: 12, color: gri(600)),
        ),
      ];
    });
  }

  // Profil sayfası: ad, fotoğraf ve isteğe bağlı bilgiler (doğum günü girilirse Ajanda'ya otomatik eklenir)
  void _profilDetaySayfasiniAc(String profilId) {
    final Profil? p0 = profiller.where((x) => x.id == profilId).firstOrNull;
    if (p0 == null) return;
    final Profil p = p0;
    final adCtrl = TextEditingController(text: p.ad);
    final telCtrl = TextEditingController(text: p.telefon);
    final postaCtrl = TextEditingController(text: p.eposta);
    final sehirCtrl = TextEditingController(text: p.sehir);
    String dogum = p.dogum;
    String? adHatasi;

    Navigator.of(context)
        .push(
      MaterialPageRoute<void>(
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setS) {
            final bool aktif = p.id == aktifProfilId;
            final DateTime? dt = dogum.isEmpty ? null : DateTime.tryParse(dogum);

            Widget alan(String etiket, IconData ikon, Widget icerik) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      Icon(ikon, size: 20, color: gri(600)),
                      const SizedBox(width: 14),
                      Expanded(child: icerik),
                    ],
                  ),
                );

            return Scaffold(
              backgroundColor: zemin,
              appBar: AppBar(
                backgroundColor: zemin,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                iconTheme: IconThemeData(color: koyuYazi),
                title: Text('Profil', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: koyuYazi)),
              ),
              body: SafeArea(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  children: [
                    Center(
                      child: GestureDetector(
                        onTap: aktif ? _profilFotoSecenekleriniGoster : null,
                        child: Stack(
                          children: [
                            ValueListenableBuilder<int>(
                              valueListenable: _arayuzSurumu,
                              builder: (c, v, w) => _profilAvatariId(p.id, 44),
                            ),
                            if (aktif)
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(7),
                                  decoration: BoxDecoration(color: anaRenk, shape: BoxShape.circle, border: Border.all(color: yuzey, width: 2)),
                                  child: const Icon(Icons.camera_alt, size: 15, color: Colors.white),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (!aktif)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Center(child: Text('Fotoğrafı değiştirmek için önce bu profile geç.', style: TextStyle(fontSize: 12, color: gri(600)))),
                      ),
                    const SizedBox(height: 20),
                    _beyazKart(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        children: [
                          alan(
                            'Ad',
                            Icons.person_outline,
                            TextField(
                              controller: adCtrl,
                              textCapitalization: TextCapitalization.words,
                              onChanged: (_) {
                                if (adHatasi != null) setS(() => adHatasi = null);
                              },
                              decoration: InputDecoration(labelText: 'Ad', errorText: adHatasi),
                            ),
                          ),
                          alan(
                            'Doğum günü',
                            Icons.cake_outlined,
                            InkWell(
                              onTap: () async {
                                final DateTime simdi = DateTime.now();
                                final DateTime? sec = await showDatePicker(
                                  context: ctx,
                                  initialDate: dt ?? DateTime(simdi.year - 25, simdi.month, simdi.day),
                                  firstDate: DateTime(1900),
                                  lastDate: simdi,
                                );
                                if (sec != null) setS(() => dogum = DateFormat('yyyy-MM-dd').format(sec));
                              },
                              child: InputDecorator(
                                decoration: InputDecoration(
                                  labelText: 'Doğum günü (isteğe bağlı)',
                                  suffixIcon: dt == null ? null : IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setS(() => dogum = '')),
                                ),
                                child: Text(dt == null ? 'Seçilmedi' : DateFormat('d MMMM yyyy', 'tr_TR').format(dt)),
                              ),
                            ),
                          ),
                          alan('Telefon', Icons.phone_outlined, TextField(controller: telCtrl, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Telefon (isteğe bağlı)'))),
                          alan('E-posta', Icons.mail_outline, TextField(controller: postaCtrl, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'E-posta (isteğe bağlı)'))),
                          alan('Şehir', Icons.location_city_outlined, TextField(controller: sehirCtrl, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Şehir (isteğe bağlı)'))),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Doğum günü girersen Ajanda\'ya her yıl "Doğum günün kutlu olsun ${adCtrl.text.trim().isEmpty ? p.ad : adCtrl.text.trim()}!" etkinliği otomatik eklenir. Diğer bilgiler yalnızca bu cihazda saklanır; hepsi isteğe bağlıdır.',
                      style: TextStyle(fontSize: 12, color: gri(600)),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: _anaDugmeStili,
                        icon: const Icon(Icons.check),
                        label: const Text('Kaydet'),
                        onPressed: () {
                          final String yeniAd = adCtrl.text.trim();
                          if (yeniAd.isEmpty) {
                            setS(() => adHatasi = 'Ad boş bırakılamaz');
                            return;
                          }
                          setState(() {
                            p.ad = yeniAd;
                            p.dogum = dogum;
                            p.telefon = telCtrl.text.trim();
                            p.eposta = postaCtrl.text.trim();
                            p.sehir = sehirCtrl.text.trim();
                            if (p.id == aktifProfilId) _dogumSenkron();
                          });
                          if (p.id == aktifProfilId) _bildirimleriYenile();
                          Navigator.pop(ctx);
                          _snack('Profil kaydedildi.');
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: Colors.red),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Profili sil'),
                        onPressed: () {
                          if (profiller.length <= 1) {
                            _snack('En az bir profil kalmalı.');
                            return;
                          }
                          _silmeOnayiGoster(ctx, '"${p.ad}" profili ve içindeki tüm finans, ajanda verileri silinecek. Bu işlem geri alınamaz.', () {
                            _profilSil(p.id);
                            if (ctx.mounted) Navigator.pop(ctx);
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    )
        .then((_) {
      adCtrl.dispose();
      telCtrl.dispose();
      postaCtrl.dispose();
      sehirCtrl.dispose();
    });
  }

  void _bildirimSayfasiniAc() {
    _altSayfaAc('Bildirimler', () {
      final String izinMetni = _bildirimIzniVar == null ? 'Kontrol ediliyor…' : (_bildirimIzniVar == true ? 'Açık • bildirim ayarlarını açmak için dokun' : 'Kapalı • dokunup izin ver');
      final DateTime? testZamani = _testZamani;
      final bool testAktif = testZamani != null && testZamani.isAfter(DateTime.now());
      return [
        _beyazKart(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              _ayarSatiri(
                ikon: Icons.notifications_active_outlined,
                renk: anaRenk,
                baslik: 'Bildirim izni',
                alt: izinMetni,
                sagIkon: Icons.open_in_new,
                onTap: () => _bildirimAyarlariniAc(),
              ),
              _ayarAyraci(),
              _ayarAnahtari(
                ikon: Icons.wb_sunny_outlined,
                renk: _turRengi('Kredi'),
                baslik: 'Sabah özeti',
                alt: 'Her sabah o günün etkinlik ve ödeme sayısını bildirir (tüm profiller). Boş günlerde gelmez.',
                deger: sabahOzetiAcik,
                degisti: (v) {
                  setState(() => sabahOzetiAcik = v);
                  _globalAyarlariKaydet();
                  _bildirimleriYenile();
                },
              ),
              if (sabahOzetiAcik) ...[
                _ayarAyraci(),
                _ayarSatiri(
                  ikon: Icons.schedule,
                  renk: _turRengi('Kredi'),
                  baslik: 'Özet saati',
                  alt: _saatMetniDk(sabahOzetiSaati),
                  onTap: () async {
                    final int? dk = await _saatSecDk(sabahOzetiSaati, 'Özet kaçta gelsin?');
                    if (dk == null || !mounted) return;
                    setState(() => sabahOzetiSaati = dk);
                    _globalAyarlariKaydet();
                    _bildirimleriYenile();
                  },
                ),
              ],
              _ayarAyraci(),
              _ayarAnahtari(
                ikon: Icons.date_range,
                renk: anaRenk,
                baslik: 'Önümüzdeki hafta özeti',
                alt: 'Haftada bir, önümüzdeki 7 günün etkinlik ve ödeme sayısını bildirir (tüm profiller). Boş haftalarda gelmez.',
                deger: haftaOzetiAcik,
                degisti: (v) {
                  setState(() => haftaOzetiAcik = v);
                  _globalAyarlariKaydet();
                  _bildirimleriYenile();
                },
              ),
              if (haftaOzetiAcik) ...[
                _ayarAyraci(),
                _ayarSatiri(
                  ikon: Icons.today,
                  renk: anaRenk,
                  baslik: 'Özet günü',
                  alt: const ['Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi', 'Pazar'][haftaOzetiGunu - 1],
                  onTap: () async {
                    final String? secim = await _secenekSheetiGoster(
                      ikon: Icons.today,
                      baslik: 'Hafta özeti hangi gün gelsin?',
                      secili: '$haftaOzetiGunu',
                      ogeler: const [
                        ['7', 'Pazar'],
                        ['6', 'Cumartesi'],
                        ['5', 'Cuma'],
                        ['1', 'Pazartesi'],
                      ],
                    );
                    if (secim == null || !mounted) return;
                    setState(() => haftaOzetiGunu = int.parse(secim));
                    _globalAyarlariKaydet();
                    _bildirimleriYenile();
                  },
                ),
                _ayarAyraci(),
                _ayarSatiri(
                  ikon: Icons.schedule,
                  renk: anaRenk,
                  baslik: 'Özet saati (hafta)',
                  alt: _saatMetniDk(haftaOzetiSaati),
                  onTap: () async {
                    final int? dk = await _saatSecDk(haftaOzetiSaati, 'Hafta özeti kaçta gelsin?');
                    if (dk == null || !mounted) return;
                    setState(() => haftaOzetiSaati = dk);
                    _globalAyarlariKaydet();
                    _bildirimleriYenile();
                  },
                ),
              ],
              _ayarAyraci(),
              _ayarSatiri(
                ikon: Icons.snooze,
                renk: anaRenk,
                baslik: 'Erteleme süresi',
                alt: 'Bildirimdeki "Ertele" düğmesine basınca ${ertelemeEtiketi(ertelemeDk)} sonra tekrar hatırlatır. Uygulama açılmaz.',
                onTap: () async {
                  final String? secim = await _secenekSheetiGoster(
                    ikon: Icons.snooze,
                    baslik: 'Ertele düğmesi ne kadar ertelesin?',
                    secili: '$ertelemeDk',
                    ogeler: const [
                      ['5', '5 dakika'],
                      ['10', '10 dakika'],
                      ['15', '15 dakika'],
                      ['30', '30 dakika'],
                      ['60', '1 saat'],
                    ],
                  );
                  if (secim == null || !mounted) return;
                  setState(() => ertelemeDk = int.parse(secim));
                  _globalAyarlariKaydet();
                  _bildirimleriYenile();
                },
              ),
              _ayarAyraci(),
              _ayarAnahtari(
                ikon: Icons.alarm,
                renk: kalanBorcRengi,
                baslik: 'Güvenilir mod',
                alt: 'Bildirimleri alarm saati gibi kurar. Ekran kapalıyken ve telefon uykudayken de zamanında gelmesi için önerilir.',
                deger: bildirimGuvenilirMod,
                degisti: (v) {
                  setState(() => bildirimGuvenilirMod = v);
                  _globalAyarlariKaydet();
                  _bildirimleriYenile();
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _beyazKart(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              _ayarSatiri(
                ikon: Icons.fact_check_outlined,
                renk: gelirRengi,
                baslik: 'Bildirim durumunu kontrol et',
                alt: 'İzinler, planlı bildirim sayısı ve sıradaki bildirimler',
                onTap: () => _bildirimDurumunuGoster(),
              ),
              _ayarAyraci(),
              _ayarSatiri(
                ikon: testAktif ? Icons.cancel_outlined : Icons.notification_add_outlined,
                renk: testAktif ? Colors.red : _turRengi('Kredi Kartı'),
                baslik: testAktif ? 'Testi iptal et' : 'Ekran kapalıyken test et',
                alt: testAktif ? '${DateFormat('HH:mm:ss').format(testZamani)} saatinde gelecek • iptal etmek için dokun' : '1 dakika sonra bildirim gönderir; telefonu kilitleyip bekle',
                onTap: () => _bildirimTestiDegistir(),
              ),
              _ayarAyraci(),
              _ayarSatiri(
                ikon: Icons.battery_saver_outlined,
                renk: kalanBorcRengi,
                baslik: 'Pil kullanımı ayarları',
                alt: 'Alfred\'in pil kısıtlamasından muaf olduğundan emin ol',
                sagIkon: Icons.open_in_new,
                onTap: () => _pilAyarlariniAc(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _beyazKart(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              _ayarSatiri(
                ikon: Icons.music_note,
                renk: anaRenk,
                baslik: 'Etkinlik hatırlatma sesi',
                alt: bildirimSesleri[sesEtkinlik]![0],
                onTap: () => _sesSecimiGoster(false),
              ),
              _ayarAyraci(),
              _ayarSatiri(
                ikon: Icons.music_note,
                renk: giderRengi,
                baslik: 'Ödeme hatırlatma sesi',
                alt: bildirimSesleri[sesOdeme]![0],
                onTap: () => _sesSecimiGoster(true),
              ),
              _ayarAyraci(),
              _ayarAnahtari(
                ikon: Icons.volume_up_outlined,
                renk: kalanBorcRengi,
                baslik: 'Sessiz modda da çal',
                alt: 'Alarm sesi düzeyinde çalar; telefon sessizde veya titreşimdeyken de duyulur',
                deger: sessizdaCal,
                degisti: (v) {
                  setState(() => sessizdaCal = v);
                  _globalAyarlariKaydet();
                  _bildirimleriYenile();
                },
              ),
              _ayarAyraci(),
              _ayarAnahtari(
                ikon: Icons.vibration,
                renk: gelirRengi,
                baslik: 'Titreşim',
                alt: 'Bildirim gelirken telefon titresin',
                deger: titresimAcik,
                degisti: (v) {
                  setState(() => titresimAcik = v);
                  _globalAyarlariKaydet();
                  _bildirimleriYenile();
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _beyazKart(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Bildirimler ekran kapalıyken gelmiyorsa', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: koyuYazi)),
              const SizedBox(height: 8),
              Text(
                '1. Telefon Ayarları → Pil → Arka plan kullanım sınırları → "Hiç uyumayan uygulamalar" listesine Alfred\'i ekle. "Uyuyan uygulamalar" ve "Derin uyuyan uygulamalar" listelerinde Alfred olmasın. "Kullanılmayan uygulamaları uyut" kapalı olsun.\n\n'
                '2. Uygulamalar → Alfred → Pil → "Sınırsız".\n\n'
                '3. Ayarlar → Bildirimler → Kilit ekranı bildirimleri açık olsun ve Alfred\'e izin verilsin.\n\n'
                '4. Rahatsız Etme veya uyku modu açıksa Alfred\'i istisna olarak ekle.\n\n'
                '5. Uygulamayı son uygulamalardan kaydırarak kapatmak sorun değil; ama "Durdur / Zorla durdur" yapma, bu bekleyen bildirimleri siler.',
                style: TextStyle(fontSize: 12, height: 1.4, color: gri(700)),
              ),
            ],
          ),
        ),
        if (_bildirimHatasi.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10, left: 4),
            child: Text(_bildirimHatasi, style: const TextStyle(fontSize: 11, color: Colors.red)),
          ),
      ];
    });
  }

  String _finansGunMetni(int gun) => gun == 0 ? 'Son gün' : '$gun gün önce';

  String _saatMetniDk(int dakika) => '${(dakika ~/ 60).toString().padLeft(2, '0')}:${(dakika % 60).toString().padLeft(2, '0')}';

  Future<int?> _saatSecDk(int baslangicDk, String yardim) async {
    final TimeOfDay? t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: baslangicDk ~/ 60, minute: baslangicDk % 60),
      helpText: yardim,
      builder: _saatBuilder,
    );
    if (t == null) return null;
    return t.hour * 60 + t.minute;
  }

  Future<void> _finansHatirlatmaEkle() async {
    final String? secim = await _secenekSheetiGoster(
      ikon: Icons.event_repeat,
      baslik: 'Ne zaman hatırlatılsın?',
      secili: '',
      ogeler: const [
        ['0', 'Son gün'],
        ['1', '1 gün önce'],
        ['2', '2 gün önce'],
        ['3', '3 gün önce'],
        ['5', '5 gün önce'],
        ['7', '1 hafta önce'],
        ['14', '2 hafta önce'],
      ],
    );
    if (secim == null || !mounted) return;
    final int gun = int.tryParse(secim) ?? 0;
    final int? saat = await _saatSecDk(540, '${_finansGunMetni(gun)} saat kaçta hatırlatsın?');
    if (saat == null || !mounted) return;
    setState(() {
      finansHatirlatmalari.add(FinansHatirlatma(gun, saat));
    });
    _bildirimleriYenile();
  }

  void _odemeHatirlatmaSayfasiniAc() {
    _altSayfaAc('Ödeme hatırlatmaları', () {
      final List<FinansHatirlatma> sirali = List<FinansHatirlatma>.from(finansHatirlatmalari)
        ..sort((a, b) {
          final int c = b.gun.compareTo(a.gun);
          return c != 0 ? c : a.saat.compareTo(b.saat);
        });
      return [
        _beyazKart(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: _ayarAnahtari(
            ikon: Icons.payments_outlined,
            renk: giderRengi,
            baslik: 'Ödeme hatırlatmaları',
            alt: 'Son ödeme tarihi yaklaşınca bildirim gönder',
            deger: finansBildirimAcik,
            degisti: (v) {
              setState(() => finansBildirimAcik = v);
              _bildirimleriYenile();
            },
          ),
        ),
        if (finansBildirimAcik) ...[
          const SizedBox(height: 14),
          _beyazKart(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                  child: Align(alignment: Alignment.centerLeft, child: Text('HATIRLATMALAR', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: gri(600)))),
                ),
                for (final h in sirali) ...[
                  ListTile(
                    leading: _ikonKutusu(Icons.schedule, renk: anaRenk),
                    title: Text(_finansGunMetni(h.gun), style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: koyuYazi)),
                    subtitle: Text('Saat ${_saatMetniDk(h.saat)} • dokunup saati değiştir', style: TextStyle(fontSize: 12, color: gri(600))),
                    onTap: () async {
                      final int? yeni = await _saatSecDk(h.saat, '${_finansGunMetni(h.gun)} saat kaçta hatırlatsın?');
                      if (yeni == null || !mounted) return;
                      setState(() => h.saat = yeni);
                      _bildirimleriYenile();
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
                      onPressed: () {
                        setState(() => finansHatirlatmalari.remove(h));
                        _bildirimleriYenile();
                      },
                    ),
                  ),
                  _ayarAyraci(),
                ],
                ListTile(
                  leading: Icon(Icons.add_circle_outline, color: anaRenk),
                  title: Text('Hatırlatma ekle', style: TextStyle(color: anaRenk, fontWeight: FontWeight.bold)),
                  onTap: () => _finansHatirlatmaEkle(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _beyazKart(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                _ayarAnahtari(
                  ikon: Icons.warning_amber_rounded,
                  renk: kalanBorcRengi,
                  baslik: 'Gecikince de hatırlat',
                  alt: 'Ödenmemişse son tarihten bir gün sonra "Gecikti" bildirimi gelir',
                  deger: finansGecikmeBildirimi,
                  degisti: (v) {
                    setState(() => finansGecikmeBildirimi = v);
                    _bildirimleriYenile();
                  },
                ),
                if (finansGecikmeBildirimi) ...[
                  _ayarAyraci(),
                  _ayarSatiri(
                    ikon: Icons.schedule,
                    renk: anaRenk,
                    baslik: 'Gecikme bildirimi saati',
                    alt: _saatMetniDk(finansGecikmeSaati),
                    onTap: () async {
                      final int? yeni = await _saatSecDk(finansGecikmeSaati, 'Gecikme bildirimi saat kaçta gelsin?');
                      if (yeni == null || !mounted) return;
                      setState(() => finansGecikmeSaati = yeni);
                      _bildirimleriYenile();
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ];
    });
  }

  void _yedeklemeSayfasiniAc() {
    _altSayfaAc('Yedekleme', () {
      return [
        _beyazKart(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              _ayarSatiri(
                ikon: Icons.cloud_upload_outlined,
                renk: gelirRengi,
                baslik: 'Yedek al',
                alt: _yedekOzetMetni(),
                onTap: () => _yedekAl(),
              ),
              _ayarAyraci(),
              _ayarSatiri(
                ikon: Icons.settings_backup_restore,
                renk: kalanBorcRengi,
                baslik: 'Yedekten geri yükle',
                alt: 'Yedek geçmişinden ya da bir dosyadan',
                onTap: () => _yedekGecmisiGoster(),
              ),
              _ayarAyraci(),
              _ayarAnahtari(
                ikon: Icons.autorenew,
                renk: gelirRengi,
                baslik: 'Otomatik yedekleme',
                alt: otoYedekAcik ? 'Açık: uygulama ${_otoYedekSikligiMetni().toLowerCase()} kendiliğinden yedek alır (telefonun içine, "Yedek geçmişi"ne).' : 'Kapalı: yalnızca "Yedek al" ile aldığın yedekler olur.',
                deger: otoYedekAcik,
                degisti: (v) {
                  setState(() => otoYedekAcik = v);
                  _globalAyarlariKaydet();
                },
              ),
              if (otoYedekAcik) ...[
                _ayarAyraci(),
                _ayarSatiri(
                  ikon: Icons.update,
                  renk: anaRenk,
                  baslik: 'Yedekleme sıklığı',
                  alt: _otoYedekSikligiMetni(),
                  onTap: () async {
                    final String? secim = await _secenekSheetiGoster(
                      ikon: Icons.update,
                      baslik: 'Ne sıklıkla otomatik yedek alınsın?',
                      secili: '$otoYedekGunu',
                      ogeler: const [
                        ['1', 'Her gün'],
                        ['2', '2 günde bir'],
                        ['3', '3 günde bir'],
                        ['7', 'Haftada bir'],
                      ],
                    );
                    if (secim == null || !mounted) return;
                    setState(() => otoYedekGunu = int.parse(secim));
                    _globalAyarlariKaydet();
                  },
                ),
                _ayarAyraci(),
                _ayarSatiri(
                  ikon: _sonOtoYedekHata == null ? Icons.check_circle_outline : Icons.error_outline,
                  renk: _sonOtoYedekHata == null ? gelirRengi : giderRengi,
                  baslik: 'Son otomatik yedek',
                  alt: _otoYedekDurumMetni(),
                  onTap: () => _yedekGecmisiGoster(),
                ),
                _ayarAyraci(),
                _ayarAnahtari(
                  ikon: Icons.photo_library_outlined,
                  renk: anaRenk,
                  baslik: 'Otomatik yedeklere fotoğrafları ekle',
                  alt: otoYedekFoto ? 'Açık: yedekler fotoğraflarla birlikte alınır, boyut artar.' : 'Kapalı: yalnızca veriler yedeklenir, fotoğraflar telefonda kalır.',
                  deger: otoYedekFoto,
                  degisti: (v) {
                    setState(() => otoYedekFoto = v);
                    _globalAyarlariKaydet();
                  },
                ),
              ],
              _ayarAyraci(),
              _ayarSatiri(
                ikon: Icons.event_repeat,
                renk: anaRenk,
                baslik: 'Yedek hatırlatması',
                alt: yedekHatirlatmaGunu == 0 ? 'Kapalı' : 'Her $yedekHatirlatmaGunu günde bir hatırlat',
                onTap: () async {
                  final String? secim = await _secenekSheetiGoster(
                    ikon: Icons.event_repeat,
                    baslik: 'Ne sıklıkla yedek önerilsin?',
                    secili: '$yedekHatirlatmaGunu',
                    ogeler: const [
                      ['0', 'Kapalı'],
                      ['7', 'Haftada bir (7 gün)'],
                      ['14', 'İki haftada bir (14 gün)'],
                      ['30', 'Ayda bir (30 gün)'],
                      ['90', '3 ayda bir (90 gün)'],
                    ],
                  );
                  if (secim == null || !mounted) return;
                  setState(() => yedekHatirlatmaGunu = int.tryParse(secim) ?? 14);
                  _globalAyarlariKaydet();
                  _bildirimleriYenile();
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Yedek dosyası tüm profillerini, finans kayıtlarını, ajandanı ve fotoğraflarını içerir. Dosyayı Drive\'a veya bilgisayarına kaydetmeni öneririm.\n\n"Yedek al" ve otomatik yedekler uygulamanın kendi içinde saklanır; yanlışlıkla silinen ya da bozulan verileri geri getirmek içindir. Uygulama silinirse onlar da silinir, bu yüzden yedek aldıktan sonra "Dosya olarak kaydet"i seçip Drive\'a ya da bilgisayara da kaydet.',
          style: TextStyle(fontSize: 12, color: gri(600)),
        ),
      ];
    });
  }

  void _veriSayfasiniAc() {
    _altSayfaAc('Veriler', () {
      return [
        _beyazKart(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              _ayarSatiri(
                ikon: Icons.delete_sweep_outlined,
                renk: Colors.red,
                baslik: 'Bu profilin verilerini sıfırla',
                alt: '"$aktifHesapAdi" profilinin kayıtları, adı ve fotoğrafı silinir',
                onTap: () => _silmeOnayiGoster(
                  context,
                  '"$aktifHesapAdi" profilinin tüm finans ve ajanda verileri, adı ve fotoğrafı silinecek. Diğer profillere dokunulmaz.\n\nBu işlem geri alınamaz. Önce yedek almanı öneririm.',
                  () => _profilVerisiniSifirla(),
                ),
              ),
              _ayarAyraci(),
              _ayarSatiri(
                ikon: Icons.delete_forever,
                renk: Colors.red,
                baslik: 'Uygulamayı tamamen sıfırla',
                alt: 'Tüm profiller ve tüm veriler silinir',
                onTap: () => _silmeOnayiGoster(
                  context,
                  'TÜM profiller ve içlerindeki tüm veriler, fotoğraflar silinecek; uygulama ilk kurulum haline dönecek.\n\nBu işlem geri alınamaz. Önce yedek almanı öneririm.',
                  () => _tumunuSifirla(),
                ),
              ),
            ],
          ),
        ),
      ];
    });
  }

  Future<void> _profilVerisiniSifirla() async {
    for (final e in etkinlikListesi) {
      for (final f in e.fotolar) {
        await _fotoSil(f);
      }
    }
    for (final n in [...notListesi, ...notArsivi, ...copNotlari]) {
      for (final f in n.fotolar) {
        await _fotoSil(f);
      }
    }
    for (final e in copEtkinlikleri) {
      for (final f in e.fotolar) {
        await _fotoSil(f);
      }
    }
    if (!mounted) return;
    setState(() {
      _veriyiUygula(<String, dynamic>{});
      aktifHesapAdi = 'Profilim';
      _profilFoto = null;
      _ajandaGunSecimi = null;
      _vurguluEtkinlikId = null;
      _vurguluFinansAnahtari = null;
      _ajandaAcikDurum.clear();
      _notFiltre = '';
      _notArama = '';
      _notAramaAcik = false;
      _notAramaCtrl.clear();
      _ajandaArama = '';
      _ajandaAramaAcik = false;
      _ajandaAramaCtrl.clear();
    });
    await _profilFotoKaydet();
    await _kaydetHemen();
    _bildirimleriYenile();
    if (mounted) _snack('Profilin verileri sıfırlandı.');
  }

  Future<void> _tumunuSifirla() async {
    await _tumEtkinlikFotolariniSil();
    final prefs = await SharedPreferences.getInstance();
    for (final p in profiller) {
      await prefs.remove('veri_${p.id}');
      await prefs.remove('profil_foto_${p.id}');
    }
    if (!mounted) return;
    setState(() {
      profiller = [Profil(id: 'p1', ad: 'Profilim')];
      aktifProfilId = 'p1';
      _profilFotolari.clear();
      _veriyiUygula(<String, dynamic>{});
      _ajandaGunSecimi = null;
      _vurguluEtkinlikId = null;
      _vurguluFinansAnahtari = null;
      _ajandaAcikDurum.clear();
      _notFiltre = '';
      _notArama = '';
      _notAramaAcik = false;
      _notAramaCtrl.clear();
      _ajandaArama = '';
      _ajandaAramaAcik = false;
      _ajandaAramaCtrl.clear();
    });
    _sonKaydedilenJson = '';
    _sonProfilJson = '';
    await _kaydetHemen();
    _bildirimleriYenile();
    if (mounted) _snack('Tüm veriler sıfırlandı.');
  }

  // ============================== YEDEKLEME ==============================

  // Yedek içeriğini hazırlar (tüm profiller; istenirse etkinlik/not fotoğrafları da)
  Future<Map<String, dynamic>> _yedekHaritasiOlustur({required bool fotolarla}) async {
    await _kaydetHemen();
    final prefs = await SharedPreferences.getInstance();
    final List<Map<String, dynamic>> profilListesi = [];
    final Set<String> fotoAdlari = {};
    for (final p in profiller) {
      Map<String, dynamic> veri;
      if (p.id == aktifProfilId) {
        veri = _veriHaritasi();
      } else {
        final String? m = prefs.getString('veri_${p.id}');
        veri = m == null ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(m) as Map);
      }
      for (final anahtar in ['etkinlikler', 'notlar', 'notArsivi', 'copNotlari', 'copEtkinlikleri']) {
        for (final e in (veri[anahtar] as List? ?? [])) {
          for (final f in ((e as Map)['fotolar'] as List? ?? [])) {
            fotoAdlari.add(f.toString());
          }
        }
      }
      final Uint8List? foto = _profilFotolari[p.id];
      profilListesi.add({'id': p.id, 'ad': p.ad, 'veri': veri, 'foto': foto == null ? null : base64Encode(foto)});
    }
    final Map<String, String> etkinlikFotolari = {};
    final Directory? klasor = _fotoKlasoru;
    if (fotolarla && klasor != null) {
      for (final ad in fotoAdlari) {
        final File f = File('${klasor.path}/$ad');
        if (await f.exists()) etkinlikFotolari[ad] = base64Encode(await f.readAsBytes());
      }
    }
    return {
      'uygulama': 'alfred',
      'surum': 2,
      'tarih': DateTime.now().toIso8601String(),
      'aktifProfil': aktifProfilId,
      'profiller': profilListesi,
      'etkinlikFotolari': etkinlikFotolari,
    };
  }

  // ---------- Otomatik yedekler (uygulamanın kendi klasöründe, fotoğrafsız, son 7 kopya) ----------

  bool _otoYedekCalisiyor = false;

  Future<Directory?> _otoYedekKlasoru() async {
    if (kIsWeb) return null;
    try {
      final Directory belgeler = await getApplicationDocumentsDirectory();
      final Directory d = Directory('${belgeler.path}/otomatik_yedekler');
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    } catch (e) {
      debugPrint('Otomatik yedek klasörü açılamadı: $e');
      return null;
    }
  }

  Future<List<File>> _otoYedekDosyalari() async {
    final Directory? d = await _otoYedekKlasoru();
    if (d == null) return [];
    final List<File> liste = d.listSync().whereType<File>().where((f) => f.path.endsWith('.json') && f.uri.pathSegments.last.startsWith('alfred_')).toList();
    liste.sort((a, b) => _otoYedekZamani(b).compareTo(_otoYedekZamani(a)));
    return liste;
  }

  DateTime _otoYedekZamani(File f) {
    final Match? m = RegExp(r'(\d{4}-\d{2}-\d{2}_\d{4,6})').firstMatch(f.uri.pathSegments.last);
    if (m != null) {
      final String metin = m.group(1)!;
      try {
        return DateFormat(metin.length > 15 ? 'yyyy-MM-dd_HHmmss' : 'yyyy-MM-dd_HHmm').parse(metin);
      } catch (_) {}
    }
    return f.lastModifiedSync();
  }

  // Eski kopyaları sil: günlük 7, geri yükleme öncesi 3, elle alınan 5 tane kalsın
  Future<void> _otoYedekBudama() async {
    final List<File> hepsi = await _otoYedekDosyalari();
    final Map<String, int> sayac = {'oto': 0, 'once': 0, 'elle': 0};
    const Map<String, int> sinir = {'oto': 7, 'once': 3, 'elle': 5};
    for (final f in hepsi) {
      final String adi = f.uri.pathSegments.last;
      final String tur = adi.startsWith('alfred_once_') ? 'once' : (adi.startsWith('alfred_elle_') ? 'elle' : 'oto');
      sayac[tur] = (sayac[tur] ?? 0) + 1;
      if ((sayac[tur] ?? 0) > (sinir[tur] ?? 7)) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
  }

  // Seçilen sıklıkta (zorla: hemen) otomatik kopya alır; etiket 'oto' veya 'once' (geri yüklemeden önce)
  Future<void> _otomatikYedekAl({bool zorla = false, String etiket = 'oto'}) async {
    if (_otoYedekCalisiyor) return;
    if (!zorla && !otoYedekAcik) return; // kapalıysa günlük kopya alınmaz (geri yükleme öncesi güvenlik kopyası zorla alınır)
    _otoYedekCalisiyor = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_veriYuklemeHatasi) {
        _sonOtoYedekHata = 'Veri okunamadığı için yedek atlandı';
        await prefs.setString('son_oto_yedek_hata', _sonOtoYedekHata!);
        return;
      }
      if (!_veriVarMi()) return;
      if (!zorla) {
        final DateTime? son = DateTime.tryParse(prefs.getString('son_oto_yedek') ?? '');
        // Uygulama her gün aynı saatte açılmaz; bu yüzden sınır, seçilen sürenin 4 saat altı
        if (son != null && DateTime.now().difference(son).inHours < otoYedekGunu * 24 - 4) return;
      }
      final Directory? d = await _otoYedekKlasoru();
      if (d == null) {
        _sonOtoYedekHata = 'Yedek klasörü açılamadı';
        await prefs.setString('son_oto_yedek_hata', _sonOtoYedekHata!);
        return;
      }
      final Map<String, dynamic> yedek = await _yedekHaritasiOlustur(fotolarla: otoYedekFoto);
      yedek['otomatik'] = true;
      final String ad = 'alfred_${etiket}_${DateFormat('yyyy-MM-dd_HHmmss').format(DateTime.now())}.json';
      final File gecici = File('${d.path}/$ad.tmp');
      await gecici.writeAsString(jsonEncode(yedek), flush: true);
      await gecici.rename('${d.path}/$ad');
      final DateTime yedekZamani = DateTime.now();
      await prefs.setString('son_oto_yedek', yedekZamani.toIso8601String());
      await prefs.remove('son_oto_yedek_hata');
      _sonOtoYedek = yedekZamani;
      _sonOtoYedekHata = null;
      await _otoYedekBudama();
    } catch (e) {
      debugPrint('Otomatik yedek alınamadı: $e');
      _sonOtoYedekHata = 'Yedek alınamadı: $e';
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('son_oto_yedek_hata', _sonOtoYedekHata!);
      } catch (_) {}
    } finally {
      _otoYedekCalisiyor = false;
    }
  }

  String _otoYedekAdindanTarih(File f) {
    final String adi = f.uri.pathSegments.last;
    final DateTime t = _otoYedekZamani(f);
    final String metin = DateFormat('d MMMM yyyy, HH:mm', 'tr_TR').format(t);
    if (adi.startsWith('alfred_once_')) return '$metin (geri yüklemeden önce)';
    if (adi.startsWith('alfred_elle_')) return '$metin (elle alındı)';
    return metin;
  }

  // Yedekten geri yükleme: dosyadan içe aktarma ve yedek geçmişi (geri yükle / dosyaya kaydet / sil)
  Future<void> _yedekGecmisiGoster() async {
    List<File> dosyalar = await _otoYedekDosyalari();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (c, setS) => Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.8),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _pencereBasligi(sheetContext, Icons.settings_backup_restore, 'Yedekten geri yükle'),
              const Divider(),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _yedektenYukle();
                  },
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Dosyadan içe aktar'),
                ),
              ),
              const SizedBox(height: 14),
              Align(alignment: Alignment.centerLeft, child: Text('YEDEK GEÇMİŞİ', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: gri(600)))),
              if (dosyalar.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Henüz yedek yok. Uygulama her gün en fazla bir kez kendiliğinden kopya alır; "Yedek al" ile aldıkların da burada görünür.', style: TextStyle(color: gri(600))),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final f in dosyalar)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.history, color: anaRenk),
                          title: Text(_otoYedekAdindanTarih(f), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          subtitle: Text('${(f.lengthSync() / 1024).ceil()} KB', style: TextStyle(fontSize: 12, color: gri(600))),
                          onTap: () async {
                            Navigator.pop(sheetContext);
                            try {
                              await _yedegiUygula(await f.readAsBytes());
                            } catch (e) {
                              if (mounted) _snack('Yedek okunamadı: $e');
                            }
                          },
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) async {
                              if (v == 'yukle') {
                                Navigator.pop(sheetContext);
                                try {
                                  await _yedegiUygula(await f.readAsBytes());
                                } catch (e) {
                                  if (mounted) _snack('Yedek okunamadı: $e');
                                }
                              } else if (v == 'kaydet') {
                                try {
                                  final Uint8List yedekBytes = await f.readAsBytes();
                                  final String? yol = await kilitsizCalistir(() => FilePicker.platform.saveFile(dialogTitle: 'Yedeği nereye kaydedelim?', fileName: f.uri.pathSegments.last, bytes: yedekBytes));
                                  if (mounted) _snack(yol == null ? 'Kaydedilmedi.' : 'Dosya olarak kaydedildi.');
                                } catch (e) {
                                  if (mounted) _snack('Kaydedilemedi: $e');
                                }
                              } else if (v == 'sil') {
                                _silmeOnayiGoster(sheetContext, 'Bu yedek silinecek. Bu işlem geri alınamaz.', () async {
                                  try {
                                    await f.delete();
                                  } catch (_) {}
                                  dosyalar = await _otoYedekDosyalari();
                                  if (sheetContext.mounted) setS(() {});
                                });
                              }
                            },
                            itemBuilder: (c) => const <PopupMenuEntry<String>>[
                              PopupMenuItem<String>(value: 'yukle', child: Text('Bu yedeği geri yükle')),
                              PopupMenuItem<String>(value: 'kaydet', child: Text('Dosya olarak kaydet')),
                              PopupMenuItem<String>(value: 'sil', child: Text('Sil', style: TextStyle(color: Colors.red))),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // Yedek alır: fotoğraf tercihini sorar, uygulamanın içindeki geçmişe kaydeder, sonra isteğe bağlı dosyaya aktarmayı önerir
  Future<void> _yedekAl() async {
    try {
      bool fotolarla = elleYedekFoto;
      final bool? devam = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            title: const Text('Yedek al'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Tüm profillerin ve verilerin bir kopyası alınır.'),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Fotoğrafları da ekle', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(fotolarla ? 'Yedek daha büyük olur.' : 'Yalnızca veriler (daha küçük).', style: TextStyle(fontSize: 12, color: gri(600))),
                  value: fotolarla,
                  onChanged: (v) => setD(() => fotolarla = v),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
              ElevatedButton(style: _anaDugmeStili, onPressed: () => Navigator.pop(ctx, true), child: const Text('Yedek al')),
            ],
          ),
        ),
      );
      if (devam != true || !mounted) return;
      if (fotolarla != elleYedekFoto) {
        elleYedekFoto = fotolarla;
        _globalAyarlariKaydet();
      }
      final Map<String, dynamic> yedek = await _yedekHaritasiOlustur(fotolarla: fotolarla);
      final Uint8List bytes = Uint8List.fromList(utf8.encode(jsonEncode(yedek)));
      final Directory? gecmis = await _otoYedekKlasoru();
      if (gecmis == null) {
        // Uygulama içi klasör yoksa (ör. web) doğrudan dosya olarak kaydet
        await _yedekDisaAktar(bytes);
        return;
      }
      final String yol = '${gecmis.path}/alfred_elle_${DateFormat('yyyy-MM-dd_HHmmss').format(DateTime.now())}.json';
      final File gecici = File('$yol.tmp');
      await gecici.writeAsBytes(bytes, flush: true);
      await gecici.rename(yol);
      await _otoYedekBudama();
      // Yedek alındı: hatırlatma sayacı sıfırlanır (dosya olarak kaydetmek ayrıca önerilir)
      final prefsYedek = await SharedPreferences.getInstance();
      final DateTime yedekAni = DateTime.now();
      if (mounted) setState(() => _sonYedekTarihi = yedekAni);
      await prefsYedek.setString('son_yedek', yedekAni.toIso8601String());
      await prefsYedek.remove('yedek_ertele');
      _bildirimleriYenile();
      if (!mounted) return;
      final bool aktar = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Yedek alındı'),
              content: const Text('Yedek, uygulamanın içinde "Yedekten geri yükle" listesine kaydedildi.\n\nUygulama silinirse bu kopyalar da gider; güvende olması için dosya olarak da kaydedebilirsin.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Tamam')),
                ElevatedButton(style: _anaDugmeStili, onPressed: () => Navigator.pop(ctx, true), child: const Text('Dosya olarak kaydet')),
              ],
            ),
          ) ??
          false;
      if (aktar && mounted) await _yedekDisaAktar(bytes);
    } catch (e) {
      if (mounted) _snack('Yedek alınamadı: $e');
    }
  }

  // Hazır yedeği telefondaki bir dosyaya (Drive, İndirilenler vb.) kaydeder; hatırlatma tarihi de güncellenir
  Future<void> _yedekDisaAktar(Uint8List bytes) async {
    try {
      final String dosyaAdi = 'alfred_yedek_${DateFormat('yyyy-MM-dd_HHmm').format(DateTime.now())}.json';
      final String? yol = await kilitsizCalistir(() => FilePicker.platform.saveFile(dialogTitle: 'Yedeği nereye kaydedelim?', fileName: dosyaAdi, bytes: bytes));
      if (!mounted) return;
      if (yol == null) {
        _snack('Dosya kaydedilmedi.');
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      final DateTime simdi = DateTime.now();
      setState(() => _sonYedekTarihi = simdi);
      await prefs.setString('son_yedek', simdi.toIso8601String());
      await prefs.remove('yedek_ertele');
      _bildirimleriYenile();
      if (mounted) _snack('Yedek dosyası kaydedildi.');
    } catch (e) {
      if (mounted) _snack('Dosya kaydedilemedi: $e');
    }
  }

  Future<void> _yedektenYukle() async {
    try {
      final sonuc = await kilitsizCalistir(() => FilePicker.platform.pickFiles(dialogTitle: 'Yedek dosyasını seç', type: FileType.any, withData: true));
      if (!mounted) return;
      if (sonuc == null || sonuc.files.isEmpty) return;
      final Uint8List? bytes = sonuc.files.single.bytes;
      if (bytes == null) {
        _snack('Dosya okunamadı.');
        return;
      }
      await _yedegiUygula(bytes);
    } catch (e) {
      if (mounted) _snack('Yedek yüklenemedi: $e');
    }
  }

  // Yedek dosyasının içeriğini doğrular, onay alır ve tüm verilerle değiştirir.
  // Fotoğrafsız otomatik kopyalarda mevcut fotoğraflara dokunulmaz.
  Future<void> _yedegiUygula(Uint8List bytes) async {
    try {
      Map<String, dynamic> yedek;
      try {
        yedek = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      } catch (_) {
        _snack('Bu dosya geçerli bir yedek dosyası değil.');
        return;
      }
      if (yedek['uygulama'] != 'alfred' && yedek['uygulama'] != 'asistanim') {
        _snack('Bu dosya bu uygulamanın yedeği değil.');
        return;
      }

      // Yeni (çok profilli) ve eski (tek profilli) yedek biçimlerini aynı yapıya çevir
      final List<Map<String, dynamic>> yeniProfiller = [];
      String? yedekAktif;
      final Map<String, String> etkinlikFotolari = {};
      if (yedek['profiller'] is List) {
        for (final pm in (yedek['profiller'] as List)) {
          yeniProfiller.add(Map<String, dynamic>.from(pm as Map));
        }
        yedekAktif = yedek['aktifProfil']?.toString();
        final dynamic fm = yedek['etkinlikFotolari'];
        if (fm is Map) {
          fm.forEach((k, v) => etkinlikFotolari[k.toString()] = v.toString());
        }
      } else if (yedek['veri'] is Map) {
        final Map<String, dynamic> veri = Map<String, dynamic>.from(yedek['veri'] as Map);
        yeniProfiller.add({'id': 'p1', 'ad': veri['hesapAdi']?.toString() ?? 'Profilim', 'veri': veri, 'foto': yedek['profilFoto']});
      }
      if (yeniProfiller.isEmpty) {
        _snack('Yedek dosyasında profil bulunamadı.');
        return;
      }

      int say(String anahtar) {
        int toplam = 0;
        for (final pm in yeniProfiller) {
          final dynamic v = pm['veri'];
          if (v is Map) toplam += (v[anahtar] as List? ?? []).length;
        }
        return toplam;
      }

      final bool fotosuzOto = yedek['otomatik'] == true && etkinlikFotolari.isEmpty;
      final DateTime? yedekTarihi = DateTime.tryParse(yedek['tarih']?.toString() ?? '');
      final String ozet = '${yeniProfiller.length} profil • ${say('finans')} finans kaydı • ${say('kartlar')} kart • ${say('taksitler')} taksit • ${say('krediler')} kredi • ${say('sabitler')} sabit ödeme • ${say('etkinlikler')} etkinlik • ${say('notlar')} not • ${etkinlikFotolari.length} fotoğraf';

      final bool onay = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Yedek yüklensin mi?'),
              content: Text(
                '${yedekTarihi == null ? '' : 'Yedek tarihi: ${DateFormat('d MMMM yyyy, HH:mm', 'tr_TR').format(yedekTarihi)}\n\n'}Yedekte: $ozet.\n\nŞu an telefondaki TÜM profiller ve veriler silinip bu yedekle değiştirilecek.${fotosuzOto ? '\n\nBu kopyada fotoğraflar yok; telefondaki mevcut fotoğraflar korunur.' : ''}\n\nGüvenlik için işlemden önce şu anki verilerinin de otomatik bir kopyası alınır.',
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
                ElevatedButton(style: _anaDugmeStili, onPressed: () => Navigator.pop(ctx, true), child: const Text('Yükle')),
              ],
            ),
          ) ??
          false;
      if (!onay || !mounted) return;

      // Geri dönüş için mevcut durumun kopyasını al
      await _otomatikYedekAl(zorla: true, etiket: 'once');
      final prefs = await SharedPreferences.getInstance();

      // Eski profil kayıtlarını ve (otomatik kopya değilse) etkinlik fotoğraflarını temizle
      for (final p in profiller) {
        await prefs.remove('veri_${p.id}');
        await prefs.remove('profil_foto_${p.id}');
      }
      if (!fotosuzOto) await _tumEtkinlikFotolariniSil();

      // Yedekteki etkinlik fotoğraflarını dosya olarak geri yaz
      final Directory klasor = await _fotoDizini();
      for (final e in etkinlikFotolari.entries) {
        try {
          await File('${klasor.path}/${e.key}').writeAsBytes(base64Decode(e.value), flush: true);
        } catch (e) {
      debugPrint('Yedekteki fotoğraf yazılamadı: $e');
    }
      }

      // Profilleri ve verilerini kaydet
      final List<Profil> yeniListe = [];
      for (final pm in yeniProfiller) {
        final String id = pm['id']?.toString() ?? 'p${DateTime.now().microsecondsSinceEpoch}';
        yeniListe.add(Profil(id: id, ad: pm['ad']?.toString() ?? 'Profil'));
        await prefs.setString('veri_$id', jsonEncode(pm['veri'] ?? <String, dynamic>{}));
        final dynamic foto = pm['foto'];
        if (foto is String && foto.isNotEmpty) await prefs.setString('profil_foto_$id', foto);
      }
      final String yeniAktif = yeniListe.any((p) => p.id == yedekAktif) ? yedekAktif! : yeniListe.first.id;
      await prefs.setString('profiller', jsonEncode(yeniListe.map((p) => p.toJson()).toList()));
      await prefs.setString('aktif_profil', yeniAktif);

      // Belleğe yükle
      Map<String, dynamic> aktifVeri = {};
      final String? aktifMetin = prefs.getString('veri_$yeniAktif');
      if (aktifMetin != null) {
        try {
          aktifVeri = jsonDecode(aktifMetin) as Map<String, dynamic>;
        } catch (e) {
      debugPrint('Yedekteki aktif profil verisi okunamadı: $e');
    }
      }
      final Map<String, Uint8List> yeniFotolar = {};
      for (final p in yeniListe) {
        final String? f = prefs.getString('profil_foto_${p.id}');
        if (f != null) {
          try {
            yeniFotolar[p.id] = base64Decode(f);
          } catch (e) {
      debugPrint('Yedekteki profil fotoğrafı okunamadı: $e');
    }
        }
      }
      if (!mounted) return;
      setState(() {
        profiller = yeniListe;
        aktifProfilId = yeniAktif;
        _profilFotolari
          ..clear()
          ..addAll(yeniFotolar);
        _veriyiUygula(aktifVeri);
        _sabitleriUret();
        _ajandaGunSecimi = null;
        _vurguluEtkinlikId = null;
        _vurguluFinansAnahtari = null;
        _ajandaAcikDurum.clear();
        _notFiltre = '';
        _notArama = '';
        _notAramaAcik = false;
        _notAramaCtrl.clear();
        _ajandaArama = '';
        _ajandaAramaAcik = false;
        _ajandaAramaCtrl.clear();
      });
      _sonKaydedilenJson = '';
      _sonProfilJson = '';
      await _kaydetHemen();
      _bildirimleriYenile();
      if (mounted) _snack('Yedek yüklendi.');
    } catch (e) {
      if (mounted) _snack('Yedek yüklenemedi: $e');
    }
  }

  // Yedek alma zamanı geldiyse uygulama açılırken öneri gösterir
  Future<void> _yedekOnerisiniKontrolEt() async {
    if (!mounted || yedekHatirlatmaGunu <= 0 || !_veriVarMi()) return;
    final prefs = await SharedPreferences.getInstance();
    final DateTime simdi = DateTime.now();
    final String? erteleMetni = prefs.getString('yedek_ertele');
    if (erteleMetni != null) {
      final DateTime? ertele = DateTime.tryParse(erteleMetni);
      if (ertele != null && ertele.isAfter(simdi)) return;
    }
    final DateTime temel = _sonYedekTarihi ?? _ilkKullanim ?? simdi;
    final int gecenGun = simdi.difference(temel).inDays;
    if (gecenGun < yedekHatirlatmaGunu) return;
    if (!mounted) return;
    final String? secim = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Yedek zamanı'),
        content: Text(_sonYedekTarihi == null
            ? 'Verilerini henüz hiç yedeklemedin. Telefon kaybolursa veya uygulama silinirse kayıtların gider. Şimdi yedek almak ister misin?'
            : 'Son yedeğin $gecenGun gün önce alındı. Şimdi yeni bir yedek almak ister misin?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'sonra'), child: const Text('Yarın hatırlat')),
          ElevatedButton(style: _anaDugmeStili, onPressed: () => Navigator.pop(ctx, 'yedek'), child: const Text('Yedek al')),
        ],
      ),
    );
    if (secim == 'yedek') {
      await _yedekAl();
    } else {
      await prefs.setString('yedek_ertele', DateTime(simdi.year, simdi.month, simdi.day + 1, 9).toIso8601String());
    }
  }

  // ---------- Ajanda: etkinlik mantığı ----------

  EtkinlikTuru _turBul(String id) {
    if (id == 'not') return EtkinlikTuru(id: 'not', ad: 'Not', ikon: 24, renk: 6);
    return etkinlikTurleri.where((t) => t.id == id).firstOrNull ?? EtkinlikTuru(id: id, ad: 'Diğer', ikon: 4, renk: 9);
  }

  Map<String, List<int>> _turZamanlari(String turId) => turZamanlari[turId] ?? const <String, List<int>>{};

  void _etkinlikSil(String id) {
    if (id.startsWith('not_')) {
      _notSil(id.substring(4));
      return;
    }
    final Etkinlik? silinen = etkinlikListesi.where((x) => x.id == id).firstOrNull;
    if (silinen == null) return;
    unawaited(ertelenenleriIptalEt(etkinlikId: id));
    // Doğum günü etkinliği profil bilgisinden üretilir, çöp kutusuna gitmez
    if (id.startsWith('dogum_')) {
      _geriAlliSil('Etkinlik silindi', ['etkinlikler'], () {
        setState(() => etkinlikListesi.removeWhere((e) => e.id == id));
        _bildirimleriYenile();
      });
      return;
    }
    _geriAlliSil('Etkinlik çöp kutusuna taşındı', ['etkinlikler', 'copEtkinlikleri'], () {
      silinen.silinme = DateTime.now();
      setState(() {
        etkinlikListesi.removeWhere((e) => e.id == id);
        copEtkinlikleri.insert(0, silinen);
      });
      _bildirimleriYenile();
    });
  }

  // Eski sürümdeki hatırlatıcıları yeni etkinlik yapısına çevirir (veri kaybolmasın)
  Etkinlik _eskiHatirlaticiyiCevir(Hatirlatici h) {
    const turHaritasi = {'İlaç': 'ilac', 'Randevu': 'randevu', 'Doğum Günü': 'dogum', 'Görev': 'gorev'};
    final String turId = turHaritasi[h.tip] ?? 'gorev';
    final DateTime gun = DateTime(h.tarihSaat.year, h.tarihSaat.month, h.tarihSaat.day);
    final bool dogum = turId == 'dogum';

    final List<ZamanDilimi> zamanlar = [];
    if (!dogum) {
      final secili = h.zamanlamaSecenekleri.where((z) => hazirZamanlar.containsKey(z)).toList();
      if (turId == 'ilac' && secili.isNotEmpty) {
        for (final etiket in secili) {
          final List<int> s = hazirZamanlar[etiket] ?? const [9, 0];
          zamanlar.add(ZamanDilimi(etiket: etiket, saat: s[0], dakika: s[1]));
        }
        zamanlar.sort((a, b) => a.gundekiDakika.compareTo(b.gundekiDakika));
      } else {
        zamanlar.add(ZamanDilimi(saat: h.tarihSaat.hour, dakika: h.tarihSaat.minute));
      }
    }

    Hatirlatma hatirlatma = Hatirlatma(1, 'saat');
    final eslesme = RegExp(r'(\d+)\s*(dakika|saat|gün|hafta)').firstMatch(h.hatirlatmaSuresi);
    if (eslesme != null) {
      final int n = int.tryParse(eslesme.group(1) ?? '') ?? 1;
      final String birimMetni = eslesme.group(2) ?? 'saat';
      hatirlatma = Hatirlatma(n, birimMetni == 'gün' ? 'gun' : birimMetni);
    }
    if (dogum && hatirlatma.birim != 'gun' && hatirlatma.birim != 'hafta') {
      hatirlatma = Hatirlatma(0, 'gun');
    }

    return Etkinlik(
      id: h.id,
      baslik: h.baslik,
      turId: turId,
      notlar: h.acTok,
      baslangic: gun,
      tumGun: dogum,
      zamanlar: zamanlar,
      tekrar: dogum ? 'yil' : 'yok',
      hatirlatmalar: [hatirlatma],
      yapilanlar: h.tamamlandi ? ['${DateFormat('yyyy-MM-dd').format(gun)}|0'] : [],
    );
  }

  // Etkinlik bu günde gerçekleşiyor mu?
  bool _etkinlikGunuMu(Etkinlik e, DateTime d) {
    final DateTime gun = DateTime(d.year, d.month, d.day);
    final DateTime bas = DateTime(e.baslangic.year, e.baslangic.month, e.baslangic.day);
    if (gun.isBefore(bas)) return false;
    final DateTime? b = e.bitis;
    if (b != null && gun.isAfter(DateTime(b.year, b.month, b.day))) return false;

    switch (e.tekrar) {
      case 'gun':
        final int fark = DateTime.utc(gun.year, gun.month, gun.day).difference(DateTime.utc(bas.year, bas.month, bas.day)).inDays;
        return fark % math.max(1, e.aralik) == 0;
      case 'hafta':
        final List<int> gunler = e.haftaGunleri.isEmpty ? [bas.weekday] : e.haftaGunleri;
        return gunler.contains(gun.weekday);
      case 'ay':
        final int ayinSonu = DateTime(gun.year, gun.month + 1, 0).day;
        return gun.day == math.min(bas.day, ayinSonu);
      case 'yil':
        if (gun.month != bas.month) return false;
        final int yilinAySonu = DateTime(gun.year, gun.month + 1, 0).day;
        return gun.day == math.min(bas.day, yilinAySonu);
      default:
        return gun == bas;
    }
  }

  List<_AjandaOlay> _gunOlaylari(DateTime d) {
    final DateTime gun = DateTime(d.year, d.month, d.day);
    final List<_AjandaOlay> liste = [];
    for (final e in _tumEtkinlikler()) {
      if (!_etkinlikGunuMu(e, gun)) continue;
      if (e.tumGun || e.zamanlar.isEmpty) {
        liste.add(_AjandaOlay(e, gun, 0));
      } else {
        for (int i = 0; i < e.zamanlar.length; i++) {
          liste.add(_AjandaOlay(e, gun, i));
        }
      }
    }
    liste.sort((a, b) {
      final int c = a.siraDakika.compareTo(b.siraDakika);
      return c != 0 ? c : a.etkinlik.baslik.compareTo(b.etkinlik.baslik);
    });
    return liste;
  }

  Map<int, List<_AjandaOlay>> _ayEtkinlikHaritasi(String ay) {
    final DateTime dt = DateTime.parse('$ay-01');
    final int aySonu = DateTime(dt.year, dt.month + 1, 0).day;
    final Map<int, List<_AjandaOlay>> harita = {};
    for (int g = 1; g <= aySonu; g++) {
      final liste = _gunOlaylari(DateTime(dt.year, dt.month, g));
      if (liste.isNotEmpty) harita[g] = liste;
    }
    return harita;
  }

  int _aktifAjandaGunu(int aySonu) {
    final int? secim = _ajandaGunSecimi;
    if (secim != null && _ajandaGunAyi == _secilenAyYil) {
      return math.max(1, math.min(secim, aySonu));
    }
    return _ayAnahtari(DateTime.now()) == _secilenAyYil ? DateTime.now().day : 1;
  }

  String _hatirlatmaMetni(Hatirlatma h, bool gunBoyu) {
    final bool gunTabanli = h.birim == 'gun' || h.birim == 'hafta';
    final String saat = (gunTabanli && h.gunSaati != null) ? ' (${h.saatMetni})' : '';
    if (h.deger == 0) return h.birim == 'gun' ? 'Aynı gün$saat' : 'Zamanında';
    switch (h.birim) {
      case 'dakika':
        return '${h.deger} dk önce';
      case 'saat':
        return '${h.deger} saat önce';
      case 'gun':
        return '${h.deger} gün önce$saat';
      case 'hafta':
        return '${h.deger} hafta önce$saat';
      default:
        return '${h.deger} önce';
    }
  }

  String _tekrarMetni(Etkinlik e) {
    const adlar = ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz'];
    switch (e.tekrar) {
      case 'gun':
        return e.aralik <= 1 ? 'Her gün' : 'Her ${e.aralik} günde bir';
      case 'hafta':
        final List<int> gunler = e.haftaGunleri.isEmpty ? [e.baslangic.weekday] : (List<int>.from(e.haftaGunleri)..sort());
        return gunler.length == 7 ? 'Her gün' : gunler.map((g) => adlar[g - 1]).join(' ');
      case 'ay':
        return 'Her ay';
      case 'yil':
        return 'Her yıl';
      default:
        return '';
    }
  }

  // Bir gerçekleşme için hatırlatmanın tam olarak ne zaman çalacağı.
  // Gün/hafta önce hatırlatmalar, kullanıcının seçtiği saatte çalar (etkinliğin saatinden bağımsız).
  DateTime _hatirlatmaZamani(_AjandaOlay o, Hatirlatma h) {
    final DateTime g = o.gun;
    final bool gunTabanli = h.birim == 'gun' || h.birim == 'hafta';
    final int gunFarki = h.birim == 'hafta' ? h.deger * 7 : (h.birim == 'gun' ? h.deger : 0);

    if (o.gunBoyu || (gunTabanli && h.gunSaati != null)) {
      final int dk = h.gunSaati ?? o.etkinlik.hatirlatmaGunSaati;
      return DateTime(g.year, g.month, g.day - gunFarki, dk ~/ 60, dk % 60);
    }

    final DateTime z = o.zaman;
    switch (h.birim) {
      case 'dakika':
        return z.subtract(Duration(minutes: h.deger));
      case 'saat':
        return z.subtract(Duration(hours: h.deger));
      case 'gun':
        return DateTime(z.year, z.month, z.day - h.deger, z.hour, z.minute);
      case 'hafta':
        return DateTime(z.year, z.month, z.day - h.deger * 7, z.hour, z.minute);
      default:
        return z;
    }
  }

  // Bundan sonraki ilk hatırlatma zamanı (formda önizleme olarak gösterilir)
  DateTime? _siradakiHatirlatma(Etkinlik e) {
    if (e.hatirlatmalar.isEmpty) return null;
    final DateTime simdi = DateTime.now();
    final DateTime bugun = DateTime(simdi.year, simdi.month, simdi.day);
    final DateTime bas = DateTime(e.baslangic.year, e.baslangic.month, e.baslangic.day);
    final DateTime ilk = bas.isBefore(bugun) ? bugun : bas;
    DateTime? en;
    for (int i = 0; i < 800; i++) {
      final DateTime d = DateTime(ilk.year, ilk.month, ilk.day + i);
      if (!_etkinlikGunuMu(e, d)) continue;
      final int adet = (e.tumGun || e.zamanlar.isEmpty) ? 1 : e.zamanlar.length;
      for (int z = 0; z < adet; z++) {
        final o = _AjandaOlay(e, d, z);
        if (e.yapilanlar.contains(o.anahtar)) continue; // tamamlananlar için hatırlatma gönderilmez
        for (final h in e.hatirlatmalar) {
          final DateTime t = _hatirlatmaZamani(o, h);
          if (t.isAfter(simdi) && (en == null || t.isBefore(en))) en = t;
        }
      }
    }
    return en;
  }

  Future<void> _olayIsaretle(_AjandaOlay o) async {
    final Etkinlik e = o.etkinlik;
    final NotKaydi? not = _etkinlikNotu(e);
    if (not != null) {
      _notTamamlandiDegistir(not);
      return;
    }
    setState(() {
      if (e.yapilanlar.contains(o.anahtar)) {
        e.yapilanlar.remove(o.anahtar);
      } else {
        e.yapilanlar.add(o.anahtar);
      }
    });
    if (e.yapilanlar.contains(o.anahtar)) unawaited(ertelenenleriIptalEt(etkinlikId: e.id, anahtar: o.anahtar));
    _bildirimleriYenile();
  }

  void _etkinlikSilOnayi(Etkinlik e) {
    final NotKaydi? not = _etkinlikNotu(e);
    if (not != null) {
      _notSilOnayi(not);
      return;
    }
    _etkinlikSilSecenekleri(e);
  }

  // Tekrarlanmayan etkinlikte düz silme onayı; tekrarlananda "tekrarı bitir" seçeneği de sunulur
  void _etkinlikSilSecenekleri(Etkinlik e) {
    if (e.tekrar == 'yok') {
      _silmeOnayiGoster(context, '"${e.baslik}" etkinliği çöp kutusuna taşınacak. $copSuresiGun gün içinde geri yükleyebilirsin.', () => _etkinlikSil(e.id));
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(e.baslik),
        content: Text(
          'Bu etkinlik tekrarlanıyor. Ne yapmak istersin?\n\n'
          '• Tekrarı bitir: seçtiğin günden sonra ajandada ve bildirimde çıkmaz. Geçmiş günler ve "yapıldı" kayıtları kalır.\n\n'
          '• Tamamen sil: tüm günlerdeki kayıtlarıyla çöp kutusuna taşınır ($copSuresiGun gün içinde geri yüklenebilir).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _etkinlikSil(e.id);
            },
            child: const Text('Tamamen sil', style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _tekrariBitir(e);
            },
            child: const Text('Tekrarı bitir'),
          ),
        ],
      ),
    );
  }

  Future<void> _tekrariBitir(Etkinlik e) async {
    final DateTime bugun = DateTime.now();
    final DateTime bas = DateTime(e.baslangic.year, e.baslangic.month, e.baslangic.day);
    DateTime ilk = DateTime(bugun.year, bugun.month, bugun.day);
    if (ilk.isBefore(bas)) ilk = bas;
    final DateTime son = DateTime(math.max(2060, ilk.year + 1));
    final DateTime? secilen = await kilitsizCalistir(() async => await showDatePicker(
          context: context,
          initialDate: ilk,
          firstDate: bas,
          lastDate: son,
          helpText: 'Son gün (bu gün dahil)',
        ));
    if (secilen == null || !mounted) return;
    final Map<String, dynamic> once = {'etkinlikler': jsonDecode(jsonEncode(_veriHaritasi()['etkinlikler']))};
    setState(() => e.bitis = DateTime(secilen.year, secilen.month, secilen.day));
    unawaited(ertelenenleriIptalEt(etkinlikId: e.id));
    _bildirimleriYenile();
    final ScaffoldMessengerState gonderici = ScaffoldMessenger.of(context);
    gonderici.hideCurrentSnackBar();
    gonderici.showSnackBar(
      SnackBar(
        content: Text('Tekrar ${DateFormat('d MMMM', 'tr_TR').format(secilen)} günü bitecek'),
        duration: const Duration(seconds: 4),
        persist: false,
        showCloseIcon: true,
        action: SnackBarAction(
          label: 'Geri al',
          onPressed: () {
            if (!mounted) return;
            final Map<String, dynamic> guncel = Map<String, dynamic>.from(jsonDecode(jsonEncode(_veriHaritasi())) as Map);
            guncel['etkinlikler'] = once['etkinlikler'];
            setState(() => _veriyiUygula(guncel));
            _bildirimleriYenile();
          },
        ),
      ),
    );
  }

  // Aynı etkinliğin aynı gündeki saatlerini (dozlarını) tek grupta toplar
  List<List<_AjandaOlay>> _etkinlikGruplari(List<_AjandaOlay> olaylar) {
    final List<List<_AjandaOlay>> gruplar = [];
    final Map<String, List<_AjandaOlay>> harita = {};
    for (final o in olaylar) {
      final List<_AjandaOlay>? mevcutGrup = harita[o.etkinlik.id];
      if (mevcutGrup == null) {
        final List<_AjandaOlay> yeni = [o];
        harita[o.etkinlik.id] = yeni;
        gruplar.add(yeni);
      } else {
        mevcutGrup.add(o);
      }
    }
    return gruplar;
  }

  // Gecikti: saatli etkinlikte yapılmamış bir saati geçmişse; tüm gün etkinlikte günü geçmişse
  bool _grupGecikti(List<_AjandaOlay> grup) {
    if (_grupTamamMi(grup)) return false;
    final DateTime simdi = DateTime.now();
    final DateTime bugun = DateTime(simdi.year, simdi.month, simdi.day);
    for (final o in grup) {
      if (o.etkinlik.yapilanlar.contains(o.anahtar)) continue;
      if (o.gunBoyu ? DateTime(o.gun.year, o.gun.month, o.gun.day).isBefore(bugun) : o.zaman.isBefore(simdi)) return true;
    }
    return false;
  }

  bool _grupTamamMi(List<_AjandaOlay> grup) => grup.every((o) => o.etkinlik.yapilanlar.contains(o.anahtar));

  // Ajanda'da sekmelerin açık/kapalı durumu hatırlanır (aylar arasında gezsen de korunur)
  bool _ajandaAcikMi(String anahtar, bool varsayilan) => _ajandaAcikDurum[anahtar] ?? varsayilan;

  // Yapıldı / yapılmadı düğmesi
  Widget _yapildiHapi(bool yapildi, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(13),
      onTap: onTap,
      child: Container(
        width: 36,
        height: 26,
        decoration: BoxDecoration(color: yapildi ? Colors.green : Colors.blue, borderRadius: BorderRadius.circular(13)),
        child: Icon(yapildi ? Icons.check : Icons.remove, color: Colors.white, size: 16),
      ),
    );
  }

  String _etkinlikDetayMetni(Etkinlik e, bool gunBoyu, {bool turAdi = false}) {
    final parcalar = <String>[];
    if (turAdi) parcalar.add(_turBul(e.turId).ad);
    if (e.tekrar != 'yok') parcalar.add(_tekrarMetni(e));
    if (e.hatirlatmalar.isNotEmpty) {
      parcalar.add('Hatırlat: ${e.hatirlatmalar.map((h) => _hatirlatmaMetni(h, gunBoyu)).join(', ')}');
    }
    return parcalar.join(' • ');
  }

  // Etkinliğin salt okunur özeti: ad, tür, gün, saatler, tekrar, hatırlatma, not ve fotoğraflar
  Future<void> _etkinlikOzetiGoster(List<_AjandaOlay> grup) async {
    final Etkinlik e = grup.first.etkinlik;
    final EtkinlikTuru tur = _turBul(e.turId);
    final DateTime gun = grup.first.gun;
    final bool gunBoyu = grup.first.gunBoyu;

    Widget satir(IconData ikon, String baslik, Widget icerik) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(ikon, size: 20, color: tur.renkVerisi),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(baslik, style: TextStyle(fontSize: 11, color: gri(600))),
                    const SizedBox(height: 2),
                    icerik,
                  ],
                ),
              ),
            ],
          ),
        );
    final TextStyle yazi = TextStyle(fontSize: 14, color: koyuYazi, height: 1.35);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _pencereBasligi(ctx, tur.ikonVerisi, e.baslik.isEmpty ? tur.ad : e.baslik),
                const Divider(),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        satir(Icons.category_outlined, 'Tür', Text(tur.ad, style: yazi)),
                        satir(Icons.event, 'Tarih', Text(DateFormat('d MMMM yyyy, EEEE', 'tr_TR').format(gun), style: yazi)),
                        satir(
                          Icons.schedule,
                          gunBoyu ? 'Zaman' : (grup.length > 1 ? 'Saatler' : 'Saat'),
                          gunBoyu
                              ? Text('Tüm gün', style: yazi)
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    for (final o in grup)
                                      Builder(builder: (_) {
                                        final ZamanDilimi z = e.zamanlar[o.zamanIndex];
                                        final bool yapildi = e.yapilanlar.contains(o.anahtar);
                                        return Padding(
                                          padding: const EdgeInsets.only(bottom: 2),
                                          child: Row(
                                            children: [
                                              Text(z.etiket.isEmpty ? z.saatMetni : '${z.etiket} ${z.saatMetni}', style: yazi),
                                              if (yapildi) ...[
                                                const SizedBox(width: 6),
                                                Icon(Icons.check_circle, size: 15, color: gelirRengi),
                                              ],
                                            ],
                                          ),
                                        );
                                      }),
                                  ],
                                ),
                        ),
                        if (e.tekrar != 'yok') satir(Icons.repeat, 'Tekrar', Text(_tekrarMetni(e), style: yazi)),
                        satir(
                          Icons.notifications_none,
                          'Hatırlatma',
                          Text(e.hatirlatmalar.isEmpty ? 'Yok' : e.hatirlatmalar.map((h) => _hatirlatmaMetni(h, gunBoyu)).join(', '), style: yazi),
                        ),
                        if (e.notlar.trim().isNotEmpty) satir(Icons.notes, 'Not', SelectableText(e.notlar.trim(), style: yazi)),
                        if (e.fotolar.isNotEmpty)
                          satir(
                            Icons.photo_library_outlined,
                            'Fotoğraflar (${e.fotolar.length})',
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (int i = 0; i < e.fotolar.length; i++) _fotoKucukResmi(e.fotolar[i], 72, onTap: () => _fotoGoruntule(e.fotolar, i)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _etkinlikDialogGoster(mevcut: e);
                      },
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('Düzenle'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
    );
  }

  // Açılan etkinliğin içindeki tek bir saat satırı
  Widget _dozSatiri(_AjandaOlay o) {
    final Etkinlik e = o.etkinlik;
    final bool yapildi = e.yapilanlar.contains(o.anahtar);
    final ZamanDilimi? z = o.gunBoyu ? null : e.zamanlar[o.zamanIndex];
    final String baslik = z == null ? 'Tüm gün' : (z.etiket.isEmpty ? 'Özel saat' : z.etiket);
    final TextStyle stil = TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: yaziRengi, decoration: yapildi ? TextDecoration.lineThrough : null);
    return InkWell(
      onTap: () => _olayIsaretle(o),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        child: Row(
          children: [
            _yapildiHapi(yapildi, () => _olayIsaretle(o)),
            const SizedBox(width: 12),
            Expanded(child: Text(baslik, style: stil)),
            if (z != null) Text(z.saatMetni, style: stil.copyWith(fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  // Bir etkinliğin ekrandaki kutusu: her etkinlik aynı biçimde açılıp kapanır.
  // Başlıkta etkinlik adı ve "tamamlanan/toplam saat" yazar; açılınca saatler, fotoğraflar, Düzenle ve Sil görünür.
  Widget _ajandaEtkinlikKutusu(List<_AjandaOlay> grup, {bool turAdi = false}) {
    final Etkinlik e = grup.first.etkinlik;
    final EtkinlikTuru tur = _turBul(e.turId);
    final Color renk = tur.renkVerisi;
    final bool vurgulu = _grupVurgulu(grup);
    final bool gunBoyu = grup.first.gunBoyu;
    final int yapilan = grup.where((o) => e.yapilanlar.contains(o.anahtar)).length;
    final bool tamamMi = _grupTamamMi(grup);
    final bool gecikti = _grupGecikti(grup);
    final String detay = _etkinlikDetayMetni(e, gunBoyu, turAdi: turAdi);
    final String gunAnahtari = DateFormat('yyyy-MM-dd').format(grup.first.gun);

    final Widget baslikSutunu = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(e.baslik, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: yaziRengi)),
        if (detay.isNotEmpty) Text(detay, style: TextStyle(fontSize: 11, color: gri(600))),
      ],
    );

    final Widget icerik = Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Builder(builder: (tileContext) => ExpansionTile(
        key: ValueKey('etk_${e.id}_$gunAnahtari${vurgulu ? '_vurgu' : ''}'),
        initiallyExpanded: _ajandaAcikMi('etk:$gunAnahtari:${e.id}', false),
        onExpansionChanged: (v) {
          _ajandaAcikDurum['etk:$gunAnahtari:${e.id}'] = v;
          if (v) _acilanBolumuGoster(tileContext);
        },
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.fromLTRB(14, 2, 10, 2),
        childrenPadding: EdgeInsets.zero,
        title: Row(
          children: [
            Expanded(child: baslikSutunu),
            if (tamamMi) ...[
              Icon(Icons.check_circle, size: 17, color: gelirRengi),
              const SizedBox(width: 5),
            ] else if (gecikti) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: giderRengi.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
                child: Text('Gecikti', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: giderRengi)),
              ),
              const SizedBox(width: 6),
            ],
            Text('$yapilan/${grup.length}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _koyu(renk))),
            const SizedBox(width: 4),
          ],
        ),
        children: [
          ...grup.map(_dozSatiri),
          // Saat satırlarının altındaki boş alana dokununca etkinliğin özeti açılır
          InkWell(
            onTap: () => _etkinlikOzetiGoster(grup),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (e.fotolar.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(14, 4, 14, 8), child: _fotoSeridi(e.fotolar, boyut: 40)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                  child: Row(
                    children: [
                      TextButton.icon(
                        onPressed: () => _etkinlikOzetiGoster(grup),
                        icon: const Icon(Icons.info_outline, size: 16),
                        label: const Text('Ayrıntılar'),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () => _etkinlikDialogGoster(mevcut: e),
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: const Text('Düzenle'),
                      ),
                      TextButton.icon(
                        onPressed: () => _etkinlikSilOnayi(e),
                        icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                        label: const Text('Sil', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      )),
    );

    final Widget kutu = Container(
      decoration: BoxDecoration(
        color: yuzey.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: renk.withValues(alpha: 0.25)),
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(14), child: Material(color: Colors.transparent, child: icerik)),
    );

    // Bildirimden gelinen etkinlik: renkli çerçeve ve ışıltıyla öne çıkar
    final Widget gosterilen = !vurgulu
        ? kutu
        : TweenAnimationBuilder<double>(
            key: _vurguAnahtari,
            tween: Tween<double>(begin: 0, end: 1),
            duration: const Duration(milliseconds: 700),
            builder: (context, v, child) => Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: renk.withValues(alpha: v), width: 2),
                boxShadow: [BoxShadow(color: renk.withValues(alpha: 0.45 * v), blurRadius: 14, spreadRadius: 1)],
              ),
              child: child,
            ),
            child: kutu,
          );
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), child: gosterilen);
  }

  // Sağında tümünü silen X düğmesi olan arama kutusu
  Widget _aramaKutusu({required TextEditingController kontrol, required String ipucu, required ValueChanged<String> degisti, required VoidCallback temizle, bool otoOdak = true}) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: kontrol,
      builder: (c, deger, w) => TextField(
        controller: kontrol,
        autofocus: otoOdak,
        onChanged: degisti,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: ipucu,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: deger.text.isEmpty ? null : IconButton(tooltip: 'Temizle', icon: const Icon(Icons.close, size: 20), onPressed: temizle),
          filled: true,
          fillColor: yuzey,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: gri(300))),
        ),
      ),
    );
  }

  Widget _ajandaAramaDugmesi() {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: () => setState(() {
        _ajandaAramaAcik = !_ajandaAramaAcik;
        if (!_ajandaAramaAcik) {
          _ajandaArama = '';
          _ajandaAramaCtrl.clear();
        }
      }),
      child: Container(
        decoration: BoxDecoration(color: griDugme, shape: BoxShape.circle),
        padding: const EdgeInsets.all(8),
        child: Icon(_ajandaAramaAcik ? Icons.search_off : Icons.search, size: 18, color: ikonGri),
      ),
    );
  }

  // Arama sonucuna dokununca ilgili güne gider ve etkinliği vurgular
  void _ajandaAramaSonucunaGit(Etkinlik e, DateTime gun) {
    setState(() {
      _ajandaAramaAcik = false;
      _ajandaArama = '';
      _ajandaAramaCtrl.clear();
    });
    _bildirimTiklamasiniIsle('etkinlik|${e.id}|${DateFormat('yyyy-MM-dd').format(gun)}|0|$aktifProfilId');
  }

  // Aranan etkinlik/not hangi günlerde var: seçili ayın günlerini çip olarak gösterir, dokununca o güne gider
  Widget _ajandaAramaSonuclari(DateTime dt) {
    final String q = _aramaNormal(_ajandaArama.trim());
    final DateTime simdi = DateTime.now();
    final DateTime bugun = DateTime(simdi.year, simdi.month, simdi.day);
    final int aySonu = DateTime(dt.year, dt.month + 1, 0).day;
    final String ayAdi = DateFormat('MMMM', 'tr_TR').format(dt);

    final List<(Etkinlik, List<int>, DateTime?)> sonuclar = [];
    for (final e in _tumEtkinlikler()) {
      final EtkinlikTuru tur = _turBul(e.turId);
      final bool eslesti = _aramaNormal(e.baslik).contains(q) || _aramaNormal(e.notlar).contains(q) || _aramaNormal(tur.ad).contains(q);
      if (!eslesti) continue;
      final List<int> gunler = [
        for (int g = 1; g <= aySonu; g++)
          if (_etkinlikGunuMu(e, DateTime(dt.year, dt.month, g))) g,
      ];
      DateTime? sonraki;
      if (gunler.isEmpty) {
        for (int i = 0; i < 800; i++) {
          final DateTime d = DateTime(bugun.year, bugun.month, bugun.day + i);
          if (_etkinlikGunuMu(e, d)) {
            sonraki = d;
            break;
          }
        }
      }
      sonuclar.add((e, gunler, sonraki));
    }
    sonuclar.sort((a, b) {
      final int c = (b.$2.isNotEmpty ? 1 : 0).compareTo(a.$2.isNotEmpty ? 1 : 0);
      return c != 0 ? c : a.$1.baslik.compareTo(b.$1.baslik);
    });

    Widget gunCipi(Etkinlik e, DateTime gun, String metin, Color renk) {
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _ajandaAramaSonucunaGit(e, gun),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: _pastel(renk), borderRadius: BorderRadius.circular(10), border: Border.all(color: renk.withValues(alpha: 0.4))),
          child: Text(metin, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _koyu(renk))),
        ),
      );
    }

    if (sonuclar.isEmpty) {
      return Center(child: Padding(padding: const EdgeInsets.all(30), child: Text('Bu aramayla eşleşen etkinlik veya not yok.', textAlign: TextAlign.center, style: TextStyle(color: gri(600)))));
    }

    final List<Widget> kartlar = [];
    for (final s in sonuclar) {
      final Etkinlik e = s.$1;
      final List<int> gunler = s.$2;
      final DateTime? sonraki = s.$3;
      final EtkinlikTuru tur = _turBul(e.turId);
      final Color renk = tur.renkVerisi;
      final bool gunBoyu = e.tumGun || e.zamanlar.isEmpty;
      final String saatler = gunBoyu ? 'Tüm gün' : e.zamanlar.map((z) => z.saatMetni).join(', ');
      final String detay = '$saatler • ${_etkinlikDetayMetni(e, gunBoyu, turAdi: true)}';

      Widget gunlerAlani;
      if (gunler.isNotEmpty) {
        final DateTime ilkGun = DateTime(dt.year, dt.month, gunler.first);
        gunlerAlani = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$ayAdi ayında ${gunler.length} gün', style: TextStyle(fontSize: 11, color: gri(600))),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: gunler.length >= aySonu - 1
                  ? [gunCipi(e, ilkGun, 'Ayın her günü', renk)]
                  : [
                      for (final g in gunler.take(12)) gunCipi(e, DateTime(dt.year, dt.month, g), '$g ${DateFormat('E', 'tr_TR').format(DateTime(dt.year, dt.month, g))}', renk),
                      if (gunler.length > 12) gunCipi(e, DateTime(dt.year, dt.month, gunler[12]), '+${gunler.length - 12} gün', renk),
                    ],
            ),
          ],
        );
      } else if (sonraki != null) {
        gunlerAlani = Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('$ayAdi ayında yok', style: TextStyle(fontSize: 11, color: gri(600))),
            gunCipi(e, sonraki, 'Sonraki: ${DateFormat('d MMM yyyy', 'tr_TR').format(sonraki)}', renk),
          ],
        );
      } else {
        gunlerAlani = Text('Yaklaşan günü yok', style: TextStyle(fontSize: 11, color: gri(600)));
      }

      kartlar.add(
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: yuzey, borderRadius: BorderRadius.circular(16), border: Border.all(color: renk.withValues(alpha: 0.35))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(radius: 16, backgroundColor: _pastel(renk), child: Icon(tur.ikonVerisi, size: 18, color: renk)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _vurguluMetin(e.baslik, _ajandaArama, TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: koyuYazi)),
                        Text(detay, style: TextStyle(fontSize: 11, color: gri(600))),
                      ],
                    ),
                  ),
                ],
              ),
              if (e.notlar.isNotEmpty && _aramaNormal(e.notlar).contains(q))
                Padding(padding: const EdgeInsets.only(top: 6), child: _vurguluMetin(e.notlar.replaceAll('\n', ' '), _ajandaArama, TextStyle(fontSize: 12, color: gri(800)), maxLines: 2)),
              Padding(padding: const EdgeInsets.only(top: 10), child: gunlerAlani),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        Padding(padding: const EdgeInsets.only(bottom: 10, left: 2), child: Text('${sonuclar.length} sonuç • günler $ayAdi ayına göre. Başka ay için üstteki okları kullan.', style: TextStyle(fontSize: 11, color: gri(600)))),
        ...kartlar,
      ],
    );
  }

  // Ajanda sıralaması: etkinlik türüne göre (tür sırası) veya ilk saatine göre (erkenden geç / geçten erken)
  List<List<_AjandaOlay>> _ajandaGruplariSirala(List<List<_AjandaOlay>> gruplar) {
    final List<List<_AjandaOlay>> liste = List<List<_AjandaOlay>>.from(gruplar);
    if (_ajandaSiralama == 'saat') {
      liste.sort((a, b) {
        final int c = a.first.siraDakika.compareTo(b.first.siraDakika);
        return _ajandaSiralamaArtan ? c : -c;
      });
    } else {
      int sira(List<_AjandaOlay> g) {
        final int i = etkinlikTurleri.indexWhere((t) => t.id == g.first.etkinlik.turId);
        return i < 0 ? 999 : i;
      }

      liste.sort((a, b) => sira(a).compareTo(sira(b)));
    }
    return liste;
  }

  // Seçili günün etkinlikleri: türe göre renkli sekmeler, saate göre sıralamada tek liste
  List<Widget> _ajandaGunBloklari(DateTime gun, List<_AjandaOlay> olaylar) {
    final List<List<_AjandaOlay>> gruplar = _ajandaGruplariSirala(_etkinlikGruplari(olaylar));
    if (_ajandaSiralama == 'saat') {
      return [for (final g in gruplar) _ajandaEtkinlikKutusu(g, turAdi: true)];
    }

    final Map<String, List<List<_AjandaOlay>>> turGruplari = {};
    for (final g in gruplar) {
      turGruplari.putIfAbsent(g.first.etkinlik.turId, () => []).add(g);
    }
    final List<String> sira = [
      ...etkinlikTurleri.map((t) => t.id).where((id) => turGruplari.containsKey(id)),
      ...turGruplari.keys.where((k) => !etkinlikTurleri.any((t) => t.id == k)),
    ];

    return sira.map((turId) {
      final EtkinlikTuru tur = _turBul(turId);
      final List<List<_AjandaOlay>> liste = turGruplari[turId] ?? <List<_AjandaOlay>>[];
      final int toplam = liste.fold<int>(0, (s, g) => s + g.length);
      final int biten = liste.fold<int>(0, (s, g) => s + g.where((o) => o.etkinlik.yapilanlar.contains(o.anahtar)).length);
      final bool vurguVar = liste.any(_grupVurgulu);
      return _kategoriBlogu(
        anahtar: 'ajanda_${DateFormat('yyyy-MM-dd').format(gun)}_$turId${vurguVar ? '_vurgu' : ''}',
        ad: tur.ad,
        altBaslik: '${liste.length} etkinlik',
        sagMetin: '$biten/$toplam',
        ikon: tur.ikonVerisi,
        renk: tur.renkVerisi,
        acik: _ajandaAcikMi('tur:${DateFormat('yyyy-MM-dd').format(gun)}:$turId', false) || vurguVar,
        acikDegisti: (v) {
          _ajandaAcikDurum['tur:${DateFormat('yyyy-MM-dd').format(gun)}:$turId'] = v;
          // Ana başlık kapanınca içindeki etkinlikler de kapanır; yeniden açınca kapalı gelirler
          if (!v) {
            for (final g in liste) {
              _ajandaAcikDurum.remove('etk:${DateFormat('yyyy-MM-dd').format(gun)}:${g.first.etkinlik.id}');
            }
          }
        },
        children: [for (final g in liste) _ajandaEtkinlikKutusu(g)],
      );
    }).toList();
  }

  // Seçili ayın tüm gider ödemeleri tek tek (takvim kullanır)
  List<_Odeme> _ayOdemeleri() {
    final DateTime dt = DateTime.parse('$_secilenAyYil-01');
    final int aySonu = DateTime(dt.year, dt.month + 1, 0).day;
    final filtrelenmis = _ayKalemleri(_secilenAyYil);
    final List<_Odeme> liste = [];

    for (var item in filtrelenmis.where((i) => !i.isGelir)) {
      if (item.kategori == 'Kredi Kartı Ekstresi') continue;
      liste.add(_kalemOdemesi(item, aySonu));
    }

    for (var kart in krediKartiListesi) {
      final ekstreler = _kartaAitEkstreler(filtrelenmis, kart.id);
      final taksitler = _kartaAitTaksitleriGetir(kart.id);
      if (ekstreler.isNotEmpty) {
        liste.add(_ekstreOdemesi(kart, ekstreler.first, taksitler.length, aySonu));
      } else {
        for (var t in taksitler) {
          liste.add(_taksitOdemesi(t, kart, aySonu));
        }
      }
    }

    for (var kredi in krediListesi) {
      if (_krediBuAyAktifMi(kredi)) liste.add(_krediOdemesi(kredi, aySonu));
    }

    liste.sort((a, b) => a.gun.compareTo(b.gun));
    return liste;
  }

  // ---------- Sıralanabilir birimler ve kategori sekmeleri ----------

  // Gider birimleri: her normal gider bir birim, her kart (ekstre veya taksitleriyle) bir birim, her kredi bir birim
  List<_Birim> _giderBirimleri(List<FinansKalemi> filtrelenmis, int aySonu) {
    final String ay = _secilenAyYil;
    final List<_Birim> liste = [];

    for (var k in filtrelenmis.where((i) => !i.isGelir)) {
      if (k.kategori == 'Kredi Kartı Ekstresi') {
        // Kartı silinmiş eski ekstre: tek başına göster
        if (krediKartiListesi.any((x) => x.id == k.kartId)) continue;
        final double eskiTutar = k.tutar;
        liste.add(_Birim(
          anahtar: 'kalem:${k.id}',
          kategori: 'Kredi Kartı',
          gun: _gunSinirla(k.tarih.day.toString(), aySonu),
          tutar: eskiTutar,
          odenen: k.odendiMi ? eskiTutar : 0,
          ad: k.baslik,
          widgetlar: [
            _buildOdemeSatiri(_Odeme(
              baslik: 'Kredi Kartı Ekstresi',
              alt: 'Kartı silinmiş',
              tutar: eskiTutar,
              renk: _turRengi('Kredi Kartı'),
              nokta: _turRengi('Kredi Kartı'),
              ikon: Icons.credit_card,
              gun: k.tarih.day,
              vade: k.tarih,
              odendi: k.odendiMi,
              onToggle: () async => setState(() => k.odendiMi = !k.odendiMi),
              onDelete: () => _silmeOnayiGoster(context, 'Bu ekstreyi silmek istediğinize emin misiniz?', () => _kalemSil(k.id)),
            )),
          ],
        ));
        continue;
      }
      final o = _kalemOdemesi(k, aySonu);
      liste.add(_Birim(
        anahtar: 'kalem:${k.id}',
        kategori: k.kategori,
        gun: o.gun,
        tutar: o.tutar,
        odenen: math.min(o.tutar, _kalemBuAyOdenen(k, ay)),
        ad: o.baslik,
        widgetlar: [_buildOdemeSatiri(o)],
      ));
    }

    for (var kart in krediKartiListesi) {
      final ekstreler = _kartaAitEkstreler(filtrelenmis, kart.id);
      final taksitler = _kartaAitTaksitleriGetir(kart.id);
      if (ekstreler.isEmpty && taksitler.isEmpty) continue;
      final FinansKalemi? ekstre = ekstreler.isNotEmpty ? ekstreler.first : null;
      final double tutar = ekstre != null ? ekstre.tutar : taksitler.fold(0.0, (s, t) => s + t.aylikTutar);
      final double odenen = ekstre != null
          ? (ekstre.odendiMi ? ekstre.tutar : 0.0)
          : taksitler.where((t) => t.odenenAylar[ay] == true).fold(0.0, (s, t) => s + t.aylikTutar);
      liste.add(_Birim(
        anahtar: 'kart:${kart.id}',
        kategori: 'Kredi Kartı',
        gun: _gunSinirla(kart.sonOdemeGunu, aySonu),
        tutar: tutar,
        odenen: odenen,
        ad: kart.kartAdi,
        widgetlar: _kartWidgetlari(kart, ekstre, taksitler, aySonu),
      ));
    }

    for (var kredi in krediListesi.where((k) => _krediBuAyAktifMi(k))) {
      final o = _krediOdemesi(kredi, aySonu);
      liste.add(_Birim(
        anahtar: 'kredi:${kredi.id}',
        kategori: 'Kredi',
        gun: o.gun,
        tutar: kredi.aylikTutar,
        odenen: o.odendi ? kredi.aylikTutar : 0,
        ad: kredi.krediAdi,
        widgetlar: [_buildOdemeSatiri(o)],
      ));
    }

    return liste;
  }

  List<_Birim> _gelirBirimleri(List<FinansKalemi> filtrelenmis, int aySonu) {
    return filtrelenmis.where((i) => i.isGelir).map((k) {
      final o = _kalemOdemesi(k, aySonu);
      return _Birim(anahtar: 'kalem:${k.id}', kategori: k.kategori, gun: o.gun, tutar: k.tutar, odenen: 0, ad: o.baslik, widgetlar: [_buildOdemeSatiri(o)]);
    }).toList();
  }

  List<_Birim> _birimleriSirala(List<_Birim> liste, bool gelir) {
    final List<String> sira = gelir ? const ['Maaş', 'Ek Gelir', 'Yatırım', 'Kira Geliri'] : const ['Kredi Kartı', 'Market', 'Fatura', 'Kira & Ev', 'Kredi'];

    int katSirasi(String k) {
      final int i = sira.indexOf(k);
      return i < 0 ? 100 : i;
    }

    int katKiyas(_Birim a, _Birim b) {
      final int c = katSirasi(a.kategori).compareTo(katSirasi(b.kategori));
      return c != 0 ? c : a.kategori.compareTo(b.kategori);
    }

    int kiyas(_Birim a, _Birim b) {
      int c;
      if (_siralama == 'tarih') {
        c = a.gun.compareTo(b.gun);
        if (c == 0) c = katKiyas(a, b);
      } else if (_siralama == 'fiyat') {
        c = a.tutar.compareTo(b.tutar);
        if (c == 0) c = katKiyas(a, b);
      } else {
        c = katKiyas(a, b);
        if (c == 0) c = a.gun.compareTo(b.gun);
      }
      if (c == 0) c = a.ad.compareTo(b.ad);
      return c;
    }

    final s = List<_Birim>.from(liste);
    s.sort((a, b) => _siralamaArtan ? kiyas(a, b) : kiyas(b, a));
    return s;
  }

  String _gunAraligi(List<_Birim> grup) {
    final DateTime dt = DateTime.parse('$_secilenAyYil-01');
    final int enKucuk = grup.map((b) => b.gun).reduce(math.min);
    final int enBuyuk = grup.map((b) => b.gun).reduce(math.max);
    final String son = DateFormat('d MMM', 'tr_TR').format(DateTime(dt.year, dt.month, enBuyuk));
    return enKucuk == enBuyuk ? son : '$enKucuk–$son';
  }

  // Sıralanmış birimleri, art arda gelen aynı kategoriler tek sekmede olacak şekilde gruplar.
  // Türe göre: her kategori tek sekme. Tarihe/tutara göre: sıralama bozulmasın diye kategori sekmeleri bölünebilir.
  List<Widget> _kategoriSekmeleri(List<_Birim> birimler, {required bool gelir}) {
    final sirali = _birimleriSirala(birimler, gelir);
    final List<Widget> sonuc = [];
    int i = 0;
    int blokNo = 0;
    while (i < sirali.length) {
      final String kat = sirali[i].kategori;
      final List<_Birim> grup = [];
      while (i < sirali.length && sirali[i].kategori == kat) {
        grup.add(sirali[i]);
        i++;
      }
      final double toplam = grup.fold(0.0, (s, b) => s + b.tutar);
      final double kalan = grup.fold(0.0, (s, b) => s + (b.tutar - b.odenen));
      final altParcalar = <String>[];
      if (_siralama == 'tarih') altParcalar.add(_gunAraligi(grup));
      if (!gelir && toplam > 0) altParcalar.add(kalan <= 0.009 ? 'Tamamı ödendi' : 'Kalan ${_para(kalan)}');

      sonuc.add(_kategoriBlogu(
        anahtar: '${gelir ? 'gelir' : 'gider'}_${_siralama}_${blokNo}_$kat${grup.any(_finansVurgulu) ? '_vurgu' : ''}',
        ad: kat,
        altBaslik: altParcalar.isEmpty ? null : altParcalar.join(' • '),
        sagMetin: _para(toplam),
        ikon: gelir ? _gelirIkonu(kat) : _kategoriIkonuGetir(kat),
        renk: _renk(kat, gelir: gelir),
        acik: grup.any(_finansVurgulu),
        children: [for (final b in grup) ..._finansBirimWidgetlari(b)],
      ));
      blokNo++;
    }
    return sonuc;
  }

  // Bir kartın sekme içindeki görünümü: ekstre varsa ekstre satırı + altında taksit dökümü,
  // yoksa kart başlığı + altında tek tek taksit satırları (ekstre girilince ödenir)
  List<Widget> _kartWidgetlari(KrediKarti kart, FinansKalemi? ekstre, List<KartTaksiti> taksitler, int aySonu) {
    final Color kartRengi = _turRengi('Kredi Kartı');
    final DateTime dt = DateTime.parse('$_secilenAyYil-01');
    final int gun = _gunSinirla(kart.sonOdemeGunu, aySonu);

    if (ekstre != null) {
      return [
        _buildOdemeSatiri(_ekstreOdemesi(kart, ekstre, taksitler.length, aySonu)),
        if (taksitler.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(96, 0, 20, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Bu aya ait taksitler (ekstrenin içindedir):', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
                const SizedBox(height: 4),
                ...taksitler.map((t) {
                  final DateTime baslangic = DateTime.parse('${t.baslangicAyYil}-01');
                  final int kacinci = _ayFarki(baslangic) + 1;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '• ${t.baslik} (Taksit $kacinci/${t.toplamTaksit} • Bitiş: ${_bitisAyiHesapla(baslangic, t.toplamTaksit, kisa: true)})',
                            style: TextStyle(fontSize: 11, color: yaziSoluk),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(_para(t.aylikTutar), style: TextStyle(fontSize: 11, color: yaziSoluk)),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
      ];
    }

    return [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: yuzey.withValues(alpha: 0.8), width: 1))),
        child: Row(
          children: [
            Icon(Icons.credit_card, size: 18, color: kartRengi),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${kart.kartAdi} • Taksitler', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: koyuYazi)),
                  Text('Ekstre girilip ödenince taksitler de ödenmiş sayılır', style: TextStyle(fontSize: 10, color: gri(600))),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text('Son ödeme ${DateFormat('d MMM', 'tr_TR').format(DateTime(dt.year, dt.month, gun))}', style: TextStyle(fontSize: 11, color: gri(600))),
          ],
        ),
      ),
      ...taksitler.map((t) => _buildOdemeSatiri(_taksitOdemesi(t, kart, aySonu), girinti: 24)),
    ];
  }

  // ---------- Ödeme penceresi (kısmi ödeme) ----------

  // Ajanda özetindeki dokunulabilir sayı: dokununca o durumdaki etkinlikler listelenir
  Widget _durumSutunu(String baslik, int adet, Color renk, CrossAxisAlignment hiza, IconData ikon, List<MapEntry<DateTime, List<_AjandaOlay>>> ogeler) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _durumListesiGoster(baslik, renk, ikon, ogeler),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: _bilgiSutunu(baslik, '$adet', renk, hiza),
      ),
    );
  }

  Future<void> _durumListesiGoster(String baslik, Color renk, IconData ikon, List<MapEntry<DateTime, List<_AjandaOlay>>> ogeler) async {
    final List<MapEntry<DateTime, List<_AjandaOlay>>> sirali = List.of(ogeler)..sort((a, b) => a.key.compareTo(b.key));
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _pencereBasligi(ctx, ikon, '$baslik (${sirali.length})'),
              const Divider(),
              if (sirali.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text('Bu ay için $baslik etkinlik yok.', style: TextStyle(color: gri(600)))),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: sirali.length,
                    itemBuilder: (c, i) {
                      final DateTime gun = sirali[i].key;
                      final List<_AjandaOlay> grup = sirali[i].value;
                      final Etkinlik e = grup.first.etkinlik;
                      final EtkinlikTuru tur = _turBul(e.turId);
                      final List<String> saatler = [
                        for (final o in grup) o.gunBoyu ? 'Tüm gün' : e.zamanlar[o.zamanIndex].saatMetni,
                      ];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Container(width: 10, height: 10, decoration: BoxDecoration(color: tur.renkVerisi, shape: BoxShape.circle)),
                        minLeadingWidth: 10,
                        title: Text(e.baslik, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: koyuYazi)),
                        subtitle: Text('${DateFormat('d MMMM, EEEE', 'tr_TR').format(gun)} • ${saatler.join(', ')}', style: TextStyle(fontSize: 12, color: gri(600))),
                        trailing: Icon(Icons.chevron_right, size: 18, color: renk),
                        onTap: () {
                          Navigator.pop(ctx);
                          setState(() {
                            _ajandaListeGorunumu = false;
                            _ajandaGunSecimi = gun.day;
                            _ajandaGunAyi = _secilenAyYil;
                            // Etkinliğin bulunduğu sekmeler ve kutusu açık gelsin, birkaç saniye vurgulansın
                            _vurguluFinansAnahtari = null;
                            _vurguluEtkinlikId = e.id;
                            _vurguluGun = DateTime(gun.year, gun.month, gun.day);
                            _ajandaAcikDurum['tur:${DateFormat('yyyy-MM-dd').format(gun)}:${e.turId}'] = true;
                            _ajandaAcikDurum['etk:${DateFormat('yyyy-MM-dd').format(gun)}:${e.id}'] = true;
                            _ajandaAcikDurum['gun:${DateFormat('yyyy-MM-dd').format(gun)}'] = true;
                          });
                          _vurguZamanlayici?.cancel();
                          _vurguZamanlayici = Timer(const Duration(seconds: 6), () {
                            if (mounted) setState(() => _vurguluEtkinlikId = null);
                          });
                          // Liste penceresi kapanıp kutular açıldıktan sonra etkinliğe kaydır
                          Future.delayed(const Duration(milliseconds: 320), () {
                            final BuildContext? hedef = _vurguAnahtari.currentContext;
                            if (mounted && hedef != null && hedef.mounted) {
                              Scrollable.ensureVisible(hedef, duration: const Duration(milliseconds: 450), alignment: 0.25, curve: Curves.easeInOut);
                            }
                          });
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bilgiSutunu(String baslik, String deger, Color renk, CrossAxisAlignment hiza) {
    return Column(
      crossAxisAlignment: hiza,
      children: [
        Text(baslik, style: TextStyle(fontSize: 11, color: gri(600))),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(deger, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: renk)),
        ),
      ],
    );
  }

  Future<void> _odemeYapGoster(FinansKalemi k) async {
    final String ay = _secilenAyYil;
    final double ilkKalan = _kalemKalani(k, ay);
    final tutarCtrl = TextEditingController(text: ilkKalan > 0.009 ? _sayiMetni(ilkKalan) : '');
    String? hata;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (innerContext) => StatefulBuilder(
        builder: (context, setModalState) {
          final double borc = _kalemBorcu(k, ay);
          final double buAy = _kalemBuAyOdenen(k, ay);
          final double kalan = math.max(0.0, borc - buAy);
          final bool devreden = k.ayYilAnahtari.compareTo(ay) < 0;

          void odemeEkle(double miktar) {
            setState(() {
              k.odemeler.add(KismiOdeme(ay: ay, tutar: miktar, tarih: DateTime.now()));
            });
            Navigator.of(innerContext).pop();
          }

          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
            child: Container(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
              padding: const EdgeInsets.all(20),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _pencereBasligi(innerContext, Icons.payments_outlined, 'Ödeme'),
                    const Divider(),
                    Row(
                      children: [
                        Icon(_kategoriIkonuGetir(k.kategori), color: _turRengi(k.kategori), size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(k.baslik.isEmpty ? k.kategori : k.baslik, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: koyuYazi)),
                              Text(
                                devreden ? '${k.kategori} • ${_ayAdi(k.ayYilAnahtari)} ayından devreden' : '${k.kategori} • Son ödeme ${DateFormat('d MMMM', 'tr_TR').format(k.tarih)}',
                                style: TextStyle(fontSize: 11, color: gri(600)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: zemin, borderRadius: BorderRadius.circular(12)),
                      child: Row(
                        children: [
                          Expanded(child: _bilgiSutunu('Bu ayki borç', _tl(borc), giderRengi, CrossAxisAlignment.start)),
                          Expanded(child: _bilgiSutunu('Bu ay ödenen', _tl(buAy), odenenRengi, CrossAxisAlignment.center)),
                          Expanded(child: _bilgiSutunu('Kalan', _tl(kalan), kalanBorcRengi, CrossAxisAlignment.end)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (kalan > 0.009) ...[
                      TextField(
                        controller: tutarCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*[.,]?\d*'))],
                        decoration: InputDecoration(
                          labelText: 'Ödenecek tutar (₺)',
                          errorText: hata,
                          helperText: 'Bir kısmını ödeyebilirsin, kalan tutar sonraki aya devreder.',
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              style: _anaDugmeStili,
                              onPressed: () => odemeEkle(kalan),
                              child: const Text('Tamamını Öde'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () {
                                final double miktar = double.tryParse(tutarCtrl.text.replaceAll(',', '.')) ?? 0;
                                if (miktar <= 0) {
                                  setModalState(() => hata = 'Geçerli bir tutar girin');
                                  return;
                                }
                                odemeEkle(math.min(miktar, kalan));
                              },
                              child: const Text('Bu Kadarını Öde'),
                            ),
                          ),
                        ],
                      ),
                    ] else
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: _pastel(Colors.green), borderRadius: BorderRadius.circular(12)),
                        child: const Row(
                          children: [
                            Icon(Icons.check_circle, color: Colors.green, size: 20),
                            SizedBox(width: 8),
                            Expanded(child: Text('Bu borç tamamen ödendi.', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.green))),
                          ],
                        ),
                      ),
                    if (k.odemeler.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Text('Ödeme Geçmişi', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: koyuYazi)),
                      const SizedBox(height: 4),
                      ...k.odemeler.toList().map((o) => Row(
                            children: [
                              Icon(Icons.check_circle_outline, size: 16, color: odenenRengi),
                              const SizedBox(width: 8),
                              Expanded(child: Text('${_ayAdi(o.ay)} • ${DateFormat('d MMM', 'tr_TR').format(o.tarih)}', style: const TextStyle(fontSize: 12))),
                              Text(_tl(o.tutar), style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: odenenRengi)),
                              IconButton(
                                icon: const Icon(Icons.undo, size: 16, color: Colors.red),
                                tooltip: 'Ödemeyi geri al',
                                visualDensity: VisualDensity.compact,
                                onPressed: () {
                                  setState(() => k.odemeler.remove(o));
                                  setModalState(() {});
                                },
                              ),
                            ],
                          )),
                    ],
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------- Sıralama menüsü ----------

  String _yonEtiketi(bool artan) {
    switch (_siralama) {
      case 'tarih':
        return artan ? 'Erken tarihten geç tarihe' : 'Geç tarihten erken tarihe';
      case 'fiyat':
        return artan ? 'Düşük tutardan yükseğe' : 'Yüksek tutardan düşüğe';
      default:
        return artan ? 'Varsayılan sıra' : 'Ters sıra';
    }
  }

  // Seçim yapınca kapanmayan sıralama menüsü: menünün dışına dokununca kapanır
  Widget _siralamaMenusu({
    required List<(String, String, IconData)> olcutler,
    required String Function() secili,
    required bool Function() artan,
    required bool Function() yonGoster,
    required String Function(bool artan) yonEtiketi,
    required void Function(String id) olcutSecildi,
    required void Function(bool artan) yonSecildi,
    List<(String, String, IconData)>? gorunumler,
    String Function()? gorunum,
    void Function(String id)? gorunumSecildi,
    bool Function()? gorunumGoster,
    List<(String, String, IconData)>? filtreler,
    String Function()? filtre,
    void Function(String id)? filtreSecildi,
  }) {
    Widget baslik(String metin) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(metin, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
        );

    Widget oge({required IconData ikon, required String Function() etiket, required bool Function() seciliMi, required VoidCallback onPressed}) {
      return MenuItemButton(
        closeOnActivate: false,
        onPressed: onPressed,
        child: ValueListenableBuilder<int>(
          valueListenable: _arayuzSurumu,
          builder: (c, surum, w) {
            final bool s = seciliMi();
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(ikon, size: 18, color: s ? anaRenk : Colors.grey),
                const SizedBox(width: 10),
                Text(etiket(), style: TextStyle(fontWeight: s ? FontWeight.bold : FontWeight.normal)),
                if (s) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.check, size: 16, color: anaRenk),
                ],
              ],
            );
          },
        ),
      );
    }

    return MenuAnchor(
      style: MenuStyle(backgroundColor: WidgetStatePropertyAll<Color>(yuzey)),
      menuChildren: [
        baslik('SIRALAMA ÖLÇÜTÜ'),
        for (final o in olcutler) oge(ikon: o.$3, etiket: () => o.$2, seciliMi: () => secili() == o.$1, onPressed: () => olcutSecildi(o.$1)),
        ValueListenableBuilder<int>(
          valueListenable: _arayuzSurumu,
          builder: (c, surum, w) {
            if (!yonGoster()) return const SizedBox.shrink();
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(height: 8),
                baslik('YÖN'),
                oge(ikon: Icons.arrow_upward, etiket: () => yonEtiketi(true), seciliMi: () => artan(), onPressed: () => yonSecildi(true)),
                oge(ikon: Icons.arrow_downward, etiket: () => yonEtiketi(false), seciliMi: () => !artan(), onPressed: () => yonSecildi(false)),
              ],
            );
          },
        ),
        if (filtreler != null && filtre != null && filtreSecildi != null)
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(height: 8),
              baslik('GÖSTER'),
              for (final f in filtreler) oge(ikon: f.$3, etiket: () => f.$2, seciliMi: () => filtre() == f.$1, onPressed: () => filtreSecildi(f.$1)),
            ],
          ),
        if (gorunumler != null && gorunum != null && gorunumSecildi != null)
          ValueListenableBuilder<int>(
            valueListenable: _arayuzSurumu,
            builder: (c, surum, w) {
              if (gorunumGoster != null && !gorunumGoster()) return const SizedBox.shrink();
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(height: 8),
                  baslik('GÖRÜNÜM'),
                  for (final g in gorunumler) oge(ikon: g.$3, etiket: () => g.$2, seciliMi: () => gorunum() == g.$1, onPressed: () => gorunumSecildi(g.$1)),
                ],
              );
            },
          ),
      ],
      builder: (context, controller, child) => InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        child: Container(
          decoration: BoxDecoration(color: griDugme, borderRadius: BorderRadius.circular(20)),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: ValueListenableBuilder<int>(
            valueListenable: _arayuzSurumu,
            builder: (c, surum, w) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.sort, size: 18, color: ikonGri),
                Icon(artan() ? Icons.arrow_upward : Icons.arrow_downward, size: 12, color: ikonGri),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSiralamaDugmesi() {
    return _siralamaMenusu(
      olcutler: const [
        ('tur', 'Türe göre', Icons.category_outlined),
        ('tarih', 'Son düzenlemeye göre', Icons.event),
        ('fiyat', 'Tutara göre', Icons.payments_outlined),
      ],
      secili: () => _siralama,
      artan: () => _siralamaArtan,
      yonGoster: () => true,
      yonEtiketi: _yonEtiketi,
      olcutSecildi: (id) => setState(() => _siralama = id),
      yonSecildi: (a) => setState(() => _siralamaArtan = a),
    );
  }

  Widget _ajandaSiralamaDugmesi() {
    return _siralamaMenusu(
      olcutler: const [
        ('tur', 'Etkinlik türüne göre', Icons.category_outlined),
        ('saat', 'Etkinlik saatine göre', Icons.schedule),
      ],
      secili: () => _ajandaSiralama,
      artan: () => _ajandaSiralamaArtan,
      yonGoster: () => _ajandaSiralama == 'saat',
      yonEtiketi: (a) => a ? 'Erken saatten geç saate' : 'Geç saatten erken saate',
      olcutSecildi: (id) => setState(() => _ajandaSiralama = id),
      yonSecildi: (a) => setState(() => _ajandaSiralamaArtan = a),
    );
  }

  // Sayfa başlığı: solda profil (her sayfada), sağda sayfanın düğmeleri
  Widget _profilBasligi() {
    return InkWell(
      onTap: _profilSecimiGoster,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _profilAvatari(16),
          const SizedBox(width: 10),
          Flexible(child: _baslikMetni(aktifHesapAdi)),
          const SizedBox(width: 4),
          Icon(Icons.keyboard_arrow_down, color: gri(600)),
        ],
      ),
    );
  }

  // Bir bölüm açılınca genişleyen kısım ekranın altında kalmasın diye otomatik kaydırır
  void _acilanBolumuGoster(BuildContext ctx) {
    Future.delayed(const Duration(milliseconds: 280), () {
      if (!ctx.mounted) return;
      final RenderObject? ro = ctx.findRenderObject();
      if (ro is! RenderBox || !ro.attached) return;
      final bool uzun = ro.size.height > MediaQuery.of(ctx).size.height * 0.6;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeInOut,
        alignment: 0.05,
        alignmentPolicy: uzun ? ScrollPositionAlignmentPolicy.explicit : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  // ---------- Ortak görünüm parçaları (tüm sayfalar aynı tasarımı kullanır) ----------

  // Sayfa üst başlığı: solda başlık, sağda düğmeler
  Widget _sayfaBasligi(Widget sol, List<Widget> sag) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
      child: Row(
        children: [
          Expanded(child: sol),
          for (int i = 0; i < sag.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            sag[i],
          ],
        ],
      ),
    );
  }

  Widget _baslikMetni(String metin) => Text(metin, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: koyuYazi));

  Widget _gizlilikDugmesi() {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: () {
        setState(() => gizlilikModu = !gizlilikModu);
        _bildirimleriYenile();
      },
      child: Container(
        decoration: BoxDecoration(color: griDugme, shape: BoxShape.circle),
        padding: const EdgeInsets.all(8),
        child: Icon(gizlilikModu ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18, color: ikonGri),
      ),
    );
  }

  Widget _ekleDugmesi(VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(color: anaRenk, borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: const Icon(Icons.add, color: Colors.white, size: 20),
      ),
    );
  }

  // Renkli zeminli küçük ikon kutusu
  Widget _ikonKutusu(IconData ikon, {Color? renk}) {
    final Color r = renk ?? anaRenk;
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(color: r == anaRenk ? acikZemin : _pastel(r), borderRadius: BorderRadius.circular(10)),
      child: Icon(ikon, size: 18, color: r),
    );
  }

  // Kart başlığı: ikon kutusu + başlık (+ alt yazı) (+ sağ taraf)
  Widget _kartBasligi(IconData ikon, String baslik, {String? alt, Widget? sag}) {
    return Row(
      children: [
        _ikonKutusu(ikon),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(baslik, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: koyuYazi)),
              if (alt != null) Text(alt, style: TextStyle(fontSize: 11, color: gri(600))),
            ],
          ),
        ),
        ?sag,
      ],
    );
  }

  // Beyaz kart: köşe yuvarlaması dış kenarda, yazılar iç boşlukta (yazılar kesilmez)
  Widget _beyazKart({required Widget child, EdgeInsets padding = const EdgeInsets.all(16)}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: yuzey,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10)],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: padding, child: child),
      ),
    );
  }

  // Gelir / Borç / Kalacak özet satırı (Finans ve Analiz aynı)
  Widget _ozetSutunu(String baslik, double deger, Color renk, IconData ikon, CrossAxisAlignment hiza) {
    final Alignment hizalama = hiza == CrossAxisAlignment.start
        ? Alignment.centerLeft
        : (hiza == CrossAxisAlignment.end ? Alignment.centerRight : Alignment.center);
    return Column(
      crossAxisAlignment: hiza,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(ikon, size: 14, color: renk),
            const SizedBox(width: 4),
            Flexible(child: Text(baslik, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gri(600)))),
          ],
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: hizalama,
          child: Text(gizlilikModu ? '******' : _tl(deger), style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: renk)),
        ),
      ],
    );
  }

  Widget _ucluOzet(double gelir, double borc) {
    final double kalacak = gelir - borc;
    return Row(
      children: [
        Expanded(child: _ozetSutunu('Toplam Gelir', gelir, gelirRengi, Icons.arrow_circle_down_rounded, CrossAxisAlignment.start)),
        Container(width: 1, height: 38, margin: const EdgeInsets.symmetric(horizontal: 6), color: gri(200)),
        Expanded(child: _ozetSutunu('Bu Ayki Borç', borc, giderRengi, Icons.arrow_circle_up_rounded, CrossAxisAlignment.center)),
        Container(width: 1, height: 38, margin: const EdgeInsets.symmetric(horizontal: 6), color: gri(200)),
        Expanded(child: _ozetSutunu('Kalacak Olan', kalacak, _netRengi(kalacak), Icons.account_balance_wallet_outlined, CrossAxisAlignment.end)),
      ],
    );
  }

  // Açılıp kapanan bölüm (Gelir, Borç, Planlar): üstte iki değer, altında kategori sekmeleri
  Widget _bolumKarti({
    required IconData ikon,
    required Color ikonRengi,
    required String solBaslik,
    required String solDeger,
    required Color solRenk,
    String? sagBaslik,
    String? sagDeger,
    Color? sagRenk,
    required bool acik,
    required VoidCallback onToggle,
    required List<Widget> icerik,
    required String bosMetin,
  }) {
    return _beyazKart(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  _ikonKutusu(ikon, renk: ikonRengi),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(solBaslik, style: TextStyle(color: gri(600), fontSize: 12)),
                        const SizedBox(height: 4),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(solDeger, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: solRenk)),
                        ),
                      ],
                    ),
                  ),
                  if (sagBaslik != null && sagDeger != null) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(sagBaslik, style: TextStyle(color: gri(600), fontSize: 12)),
                          const SizedBox(height: 4),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Text(sagDeger, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: sagRenk ?? koyuYazi)),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  Icon(acik ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: Colors.grey),
                ],
              ),
            ),
          ),
          if (acik) ...[
            Divider(height: 1, color: gri(100)),
            if (icerik.isEmpty)
              Padding(padding: const EdgeInsets.all(25.0), child: Text(bosMetin, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)))
            else
              Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Column(children: icerik)),
          ],
        ],
      ),
    );
  }

  // Pastel renkli, ikonlu, açılıp kapanan kategori sekmesi (tüm sayfalarda aynı)
  Widget _kategoriBlogu({
    required String anahtar,
    required String ad,
    String? altBaslik,
    required String sagMetin,
    required IconData ikon,
    required Color renk,
    required List<Widget> children,
    bool acik = false,
    ValueChanged<bool>? acikDegisti,
  }) {
    final Color koyu = _koyu(renk);
    return Container(
      key: ValueKey(anahtar),
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      decoration: BoxDecoration(
        color: _pastel(renk),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: renk.withValues(alpha: 0.25)),
      ),
      child: Builder(
        builder: (tileContext) => ExpansionTile(
          initiallyExpanded: acik,
          onExpansionChanged: (v) {
            acikDegisti?.call(v);
            if (v) _acilanBolumuGoster(tileContext);
          },
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: Icon(ikon, color: renk, size: 22),
          title: Text(ad, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: koyu)),
          subtitle: altBaslik == null ? null : Text(altBaslik, style: TextStyle(fontSize: 11, color: gri(700))),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(sagMetin, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: koyu)),
              const SizedBox(width: 6),
              const Icon(Icons.expand_more, size: 18, color: Colors.grey),
            ],
          ),
          children: children,
        ),
      ),
    );
  }

  // Tek bir satır: [durum düğmesi] [tür ikonu] başlık / alt yazı • tarih   tutar  [sil]
  Widget _buildOdemeSatiri(_Odeme o, {double girinti = 0}) {
    final bool gecti = o.gecikmeGoster && !o.gelir && !o.odendi && DateTime.now().isAfter(DateTime(o.vade.year, o.vade.month, o.vade.day, 23, 59, 59));
    final String tarihMetni = DateFormat('d MMM', 'tr_TR').format(o.vade);

    // Durum düğmesi renkleri: gelir yeşil ok, ödendi yeşil tik, kısmi turuncu, ödenmedi mavi,
    // ayrıca ödenemeyen (ekstreye bağlı taksit) gri kilit
    Color hapRengi;
    IconData hapIkonu;
    if (o.gelir) {
      hapRengi = gelirRengi;
      hapIkonu = Icons.arrow_downward;
    } else if (o.odendi) {
      hapRengi = Colors.green;
      hapIkonu = Icons.check;
    } else if (o.onToggle == null) {
      hapRengi = hapGri;
      hapIkonu = Icons.lock_outline;
    } else if (o.kismi) {
      hapRengi = kalanBorcRengi;
      hapIkonu = Icons.timelapse;
    } else {
      hapRengi = Colors.blue;
      hapIkonu = Icons.remove;
    }

    final Widget durumHapi = Container(
      width: 36,
      height: 26,
      decoration: BoxDecoration(color: hapRengi, borderRadius: BorderRadius.circular(13)),
      child: Icon(hapIkonu, color: Colors.white, size: 16),
    );

    final AsyncTiklama? toggle = o.onToggle;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: o.onTap,
        child: Container(
          padding: EdgeInsets.fromLTRB(20 + girinti, 10, 8, 10),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: yuzey.withValues(alpha: 0.8), width: 1))),
          child: Row(
            children: [
              toggle != null ? InkWell(borderRadius: BorderRadius.circular(13), onTap: () => toggle(), child: durumHapi) : durumHapi,
              const SizedBox(width: 10),
              Icon(o.ikon, size: 20, color: o.renk),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            o.baslik,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: yaziRengi, decoration: (o.odendi && !o.gelir) ? TextDecoration.lineThrough : null),
                          ),
                        ),
                        if (o.rozet != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(color: _pastel(kalanBorcRengi), borderRadius: BorderRadius.circular(4)),
                            child: Text(o.rozet ?? '', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: kalanBorcRengi)),
                          ),
                        ] else if (gecti) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(color: Colors.red.withValues(alpha: koyuMod ? 0.25 : 0.15), borderRadius: BorderRadius.circular(4)),
                            child: const Text('Gecikti', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.red)),
                          ),
                        ],
                      ],
                    ),
                    if ((o.tarihGoster ? '${o.alt} • $tarihMetni' : o.alt).isNotEmpty)
                      Text(o.tarihGoster ? '${o.alt} • $tarihMetni' : o.alt, style: TextStyle(fontSize: 11, color: gri(600))),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                o.sagMetin ?? _para(o.tutar),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: o.gelir ? gelirRengi : yaziRengi,
                  decoration: (o.odendi && !o.gelir) ? TextDecoration.lineThrough : null,
                ),
              ),
              if (o.onDelete != null)
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                  visualDensity: VisualDensity.compact,
                  onPressed: o.onDelete,
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- Takvim ----------

  void _takvimGoster() {
    int? secilenGun;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (innerContext) => StatefulBuilder(
        builder: (takvimContext, setModalState) {
          final DateTime dt = DateTime.parse('$_secilenAyYil-01');
          final int aySonu = DateTime(dt.year, dt.month + 1, 0).day;
          final DateTime simdi = DateTime.now();
          final bool buAy = simdi.year == dt.year && simdi.month == dt.month;
          final int? sg = secilenGun;
          final int aktifGun = (sg != null && sg <= aySonu) ? sg : (buAy ? simdi.day : 1);

          final odemeler = _ayOdemeleri();
          final Map<int, List<_Odeme>> gunHaritasi = {};
          for (var o in odemeler) {
            gunHaritasi.putIfAbsent(o.gun, () => []).add(o);
          }

          final int bosluk = dt.weekday - 1;
          final int satirSayisi = ((bosluk + aySonu) / 7).ceil();
          final List<_Odeme> gunOdemeleri = gunHaritasi[aktifGun] ?? <_Odeme>[];
          final double gunToplam = gunOdemeleri.fold(0.0, (s, o) => s + o.tutar);
          final double gunKalan = gunOdemeleri.fold(0.0, (s, o) => s + o.kalan);

          void yenile() {
            if (takvimContext.mounted) setModalState(() {});
          }

          void ayDegistir(int fark) {
            final yeni = DateTime(dt.year, dt.month + fark, 1);
            setState(() {
              _secilenAyYil = _ayAnahtari(yeni);
            });
            setModalState(() {
              secilenGun = null;
            });
          }

          final List<Widget> satirlar = [];
          for (int r = 0; r < satirSayisi; r++) {
            satirlar.add(
              Row(
                children: List<Widget>.generate(7, (c) {
                  final int gun = r * 7 + c - bosluk + 1;
                  if (gun < 1 || gun > aySonu) {
                    return const Expanded(child: SizedBox(height: 54));
                  }
                  // Noktalar finans sayfasındaki kategori renginde
                  final renkler = (gunHaritasi[gun] ?? <_Odeme>[]).map((o) => o.nokta).toSet().take(3).toList();
                  final bool secili = gun == aktifGun;
                  final bool bugun = buAy && gun == simdi.day;
                  return Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => setModalState(() => secilenGun = gun),
                      child: Container(
                        height: 54,
                        margin: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: secili ? hucreSecili : (renkler.isNotEmpty ? hucreZemin : yuzey),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: secili ? const Color(0xFF2563EB) : gri(200)),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(color: bugun ? const Color(0xFF2563EB) : Colors.transparent, shape: BoxShape.circle),
                              child: Text('$gun', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: bugun ? Colors.white : yaziRengi)),
                            ),
                            const SizedBox(height: 3),
                            SizedBox(
                              height: 6,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: renkler
                                    .map((r) => Container(
                                          width: 6,
                                          height: 6,
                                          margin: const EdgeInsets.symmetric(horizontal: 1),
                                          decoration: BoxDecoration(color: r, shape: BoxShape.circle),
                                        ))
                                    .toList(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            );
          }

          return Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(takvimContext).size.height * 0.9),
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _ikonKutusu(Icons.calendar_month),
                      const SizedBox(width: 10),
                      Expanded(child: Text('Ödeme Takvimi', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: koyuYazi))),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _secilenAyYil = _ayAnahtari(DateTime.now());
                          });
                          setModalState(() => secilenGun = null);
                        },
                        child: const Text('Bugün'),
                      ),
                      IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(innerContext).pop()),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(icon: Icon(Icons.chevron_left, color: anaRenk), onPressed: () => ayDegistir(-1)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(color: acikZemin, borderRadius: BorderRadius.circular(20)),
                        child: Text(DateFormat('MMMM yyyy', 'tr_TR').format(dt), style: TextStyle(color: koyuYazi, fontWeight: FontWeight.bold, fontSize: 13)),
                      ),
                      IconButton(icon: Icon(Icons.chevron_right, color: anaRenk), onPressed: () => ayDegistir(1)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz']
                        .map((g) => Expanded(child: Center(child: Text(g, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)))))
                        .toList(),
                  ),
                  const SizedBox(height: 4),
                  ...satirlar,
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(color: acikZemin, borderRadius: BorderRadius.circular(16)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                          child: Row(
                            children: [
                              Expanded(child: _bilgiSutunu('$aktifGun ${DateFormat('MMMM yyyy', 'tr_TR').format(dt)}', _para(gunToplam), giderRengi, CrossAxisAlignment.start)),
                              Expanded(child: _bilgiSutunu('Kalan', _para(gunKalan), kalanBorcRengi, CrossAxisAlignment.end)),
                            ],
                          ),
                        ),
                        if (gunOdemeleri.isEmpty)
                          const Padding(
                            padding: EdgeInsets.fromLTRB(16, 0, 16, 14),
                            child: Text('Bu günde ödeme yok.', style: TextStyle(color: Colors.grey, fontSize: 12)),
                          )
                        else
                          ...gunOdemeleri.map((o) => _buildOdemeSatiri(o.takvimIcin(yenile))),
                        const SizedBox(height: 4),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------- Ana iskelet ----------

  Widget _sayfaOlustur(int i) {
    switch (i) {
      case 0:
        return _buildAjandaTakvimSekmesi();
      case 1:
        return _buildNotlarSekmesi();
      case 2:
        return _buildGiderVeButceSekmesi();
      case 3:
        return _buildAnalizSekmesi();
      default:
        return _buildAyarlarSekmesi();
    }
  }

  // Sekmeler: 0 Ajanda, 1 Notlar, 2 Finans, 3 Analiz, 4 Ayarlar (uygulama Ajanda ile açılır)
  void _sekmeyeGit(int i, {bool animasyon = true}) {
    if (_sayfaKontrol.hasClients) {
      if (animasyon && (i - _seciliSekme).abs() == 1) {
        _sayfaKontrol.animateToPage(i, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
      } else {
        _sayfaKontrol.jumpToPage(i);
      }
    }
    _seciliSekme = i;
    _sekmeBildirici.value = i;
    if (i == 4) _bildirimIzinleriniKontrolEt();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: PageView.builder(
          controller: _sayfaKontrol,
          physics: const SertSayfaFizigi(),
          itemCount: 5,
          onPageChanged: (i) {
            // setState kullanılmaz: sayfa yarıyı geçerken tüm sayfaları yeniden kurmak kaydırmada takılma yapıyordu
            _seciliSekme = i;
            _sekmeBildirici.value = i;
            if (i == 4) _bildirimIzinleriniKontrolEt();
          },
          itemBuilder: (ctx, i) => KalanSayfa(child: _sayfaOlustur(i)),
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 15, offset: const Offset(0, -4))],
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: ValueListenableBuilder<int>(
            valueListenable: _sekmeBildirici,
            builder: (c, secili, w) => NavigationBar(
            selectedIndex: secili,
            onDestinationSelected: (index) => _sekmeyeGit(index),
            height: 65,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.event_note_outlined), selectedIcon: Icon(Icons.event_note), label: 'Ajanda'),
              NavigationDestination(icon: Icon(Icons.sticky_note_2_outlined), selectedIcon: Icon(Icons.sticky_note_2), label: 'Notlar'),
              NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), selectedIcon: Icon(Icons.account_balance_wallet), label: 'Finans'),
              NavigationDestination(icon: Icon(Icons.donut_large_rounded), selectedIcon: Icon(Icons.donut_large), label: 'Analiz'),
              NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Ayarlar'),
            ],
            ),
          ),
        ),
      ),
    );
  }

  // takvimli: true ise ay etiketine tıklayınca takvim açılır, değilse tarih seçici
  Widget _buildAySeciciBaslik({bool takvimli = false, bool? bugunSecili}) {
    DateTime dt = DateTime.parse('$_secilenAyYil-01');
    String ayYilFormatli = DateFormat('MMMM yyyy', 'tr_TR').format(dt);
    String simdikiAyYil = _ayAnahtari(DateTime.now());
    bool bugundeMi = _secilenAyYil == simdikiAyYil && (bugunSecili ?? true);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 2.0),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: Icon(Icons.chevron_left, color: anaRenk),
                onPressed: () {
                  setState(() {
                    _secilenAyYil = _ayAnahtari(DateTime(dt.year, dt.month - 1, 1));
                  });
                },
              ),
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: takvimli ? _takvimGoster : _aySeciciGoster,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(color: acikZemin, borderRadius: BorderRadius.circular(20)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.calendar_month, size: 16, color: anaRenk),
                      const SizedBox(width: 8),
                      Text(ayYilFormatli, style: TextStyle(fontWeight: FontWeight.bold, color: koyuYazi, fontSize: 13)),
                    ],
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.chevron_right, color: anaRenk),
                onPressed: () {
                  setState(() {
                    _secilenAyYil = _ayAnahtari(DateTime(dt.year, dt.month + 1, 1));
                  });
                },
              ),
            ],
          ),
          Positioned(
            right: 0,
            child: AnimatedOpacity(
              opacity: bugundeMi ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: bugundeMi,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () {
                    setState(() {
                      _secilenAyYil = simdikiAyYil;
                      // Ajanda'da bugünün gününü de seç
                      _ajandaGunSecimi = DateTime.now().day;
                      _ajandaGunAyi = simdikiAyYil;
                    });
                  },
                  child: Text('Bugün', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: anaRenk)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================== FİNANS SEKMESİ ==============================

  Widget _buildGiderVeButceSekmesi() {
    final filtrelenmisFinans = _ayKalemleri(_secilenAyYil);
    final DateTime dt = DateTime.parse('$_secilenAyYil-01');
    final int aySonu = DateTime(dt.year, dt.month + 1, 0).day;

    final ozet = _ozetHesapla(filtrelenmisFinans);
    final double kalanBorc = math.max(0.0, ozet.toplamGider - ozet.odenenGider);
    final double kalanParam = ozet.toplamGelir - ozet.odenenGider;

    final giderSekmeleri = _kategoriSekmeleri(_giderBirimleri(filtrelenmisFinans, aySonu), gelir: false);
    final gelirSekmeleri = _kategoriSekmeleri(_gelirBirimleri(filtrelenmisFinans, aySonu), gelir: true);

    return Column(
      children: [
        _sayfaBasligi(
          _profilBasligi(),
          [
            _gizlilikDugmesi(),
            _buildSiralamaDugmesi(),
            _ekleDugmesi(() => _islemEkleDialogGoster()),
          ],
        ),
        _buildAySeciciBaslik(takvimli: true),
        Expanded(
          child: ListView(
            // ignore: deprecated_member_use
            cacheExtent: 4000,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            children: [
              // Gelen / giden / kalacak
              _beyazKart(child: _ucluOzet(ozet.toplamGelir, ozet.toplamGider)),
              const SizedBox(height: 14),
              _beyazKart(
                padding: EdgeInsets.zero,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: _ikonKutusu(Icons.credit_card_rounded),
                  title: Text('Kartlar, Taksitler, Krediler & Sabit Ödemeler', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: koyuYazi)),
                  subtitle: Text('${krediKartiListesi.length} Kart • ${kartTaksitListesi.length} Taksit • ${krediListesi.length} Kredi • ${sabitListesi.length} Sabit', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  trailing: Icon(Icons.arrow_forward_ios, size: 14, color: anaRenk),
                  onTap: _krediKartlariYonetimDialogGoster,
                ),
              ),
              const SizedBox(height: 14),
              _bolumKarti(
                ikon: Icons.arrow_circle_down_rounded,
                ikonRengi: gelirRengi,
                solBaslik: 'Toplam Gelir',
                solDeger: gizlilikModu ? '******' : _tl(ozet.toplamGelir),
                solRenk: gelirRengi,
                sagBaslik: 'Kalan Param',
                sagDeger: gizlilikModu ? '******' : _tl(kalanParam),
                sagRenk: _netRengi(kalanParam),
                acik: gelirlerAcik,
                onToggle: () => setState(() => gelirlerAcik = !gelirlerAcik),
                icerik: gelirSekmeleri,
                bosMetin: 'Bu aya ait gelir bulunmuyor.',
              ),
              const SizedBox(height: 14),
              _bolumKarti(
                ikon: Icons.arrow_circle_up_rounded,
                ikonRengi: giderRengi,
                solBaslik: 'Toplam Borç',
                solDeger: gizlilikModu ? '******' : _tl(ozet.toplamGider),
                solRenk: giderRengi,
                sagBaslik: 'Kalan Borç',
                sagDeger: gizlilikModu ? '******' : _tl(kalanBorc),
                sagRenk: kalanBorcRengi,
                acik: gelecekGiderlerAcik,
                onToggle: () => setState(() => gelecekGiderlerAcik = !gelecekGiderlerAcik),
                icerik: giderSekmeleri,
                bosMetin: 'Bu aya ait gider bulunmuyor.',
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<DropdownMenuItem<String>> _krediTuruSecenekleri() {
    return ['Konut', 'Taşıt', 'İhtiyaç', 'Ticari']
        .map((t) => DropdownMenuItem<String>(
              value: t,
              child: Row(
                children: [
                  Icon(_krediIkonuGetir(t), color: _turRengi(t), size: 20),
                  const SizedBox(width: 8),
                  Text('$t Kredisi'),
                ],
              ),
            ))
        .toList();
  }

  Widget _sonOdemeGunuAlani(TextEditingController ctrl, {String etiket = 'Son Ödeme Günü (1-31)'}) {
    return TextFormField(
      controller: ctrl,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(2),
      ],
      decoration: InputDecoration(
        labelText: etiket,
        hintText: 'Örn: 25',
      ),
      validator: (val) {
        if (val == null || val.isEmpty) return 'Gün boş bırakılamaz';
        int? gun = int.tryParse(val);
        if (gun == null || gun < 1 || gun > 31) return 'Lütfen 1 ile 31 arasında geçerli bir gün girin';
        return null;
      },
    );
  }

  void _silmeOnayiGoster(BuildContext context, String mesaj, VoidCallback onSil) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Silme Onayı'),
        content: Text(mesaj),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(ctx);
              onSil();
            },
            child: const Text('Sil'),
          ),
        ],
      ),
    );
  }

  // ============================== AJANDA SEKMESİ ==============================

  Widget _ajandaGorunumDugmesi() {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: () => setState(() => _ajandaListeGorunumu = !_ajandaListeGorunumu),
      child: Container(
        decoration: BoxDecoration(color: griDugme, shape: BoxShape.circle),
        padding: const EdgeInsets.all(8),
        child: Icon(_ajandaListeGorunumu ? Icons.calendar_month : Icons.format_list_bulleted, size: 18, color: ikonGri),
      ),
    );
  }

  Widget _dolguEkleDugmesi(String metin, VoidCallback onTap) {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: anaRenk,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onPressed: onTap,
      icon: const Icon(Icons.add, size: 18),
      label: Text(metin, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
    );
  }

  Widget _ajandaTakvimGrid(DateTime dt, int aySonu, Map<int, List<_AjandaOlay>> harita, int aktifGun) {
    final DateTime simdi = DateTime.now();
    final bool buAy = simdi.year == dt.year && simdi.month == dt.month;
    final int bosluk = dt.weekday - 1;
    final int satirSayisi = ((bosluk + aySonu) / 7).ceil();

    final List<Widget> satirlar = [];
    for (int r = 0; r < satirSayisi; r++) {
      satirlar.add(
        Row(
          children: List<Widget>.generate(7, (c) {
            final int gun = r * 7 + c - bosluk + 1;
            if (gun < 1 || gun > aySonu) {
              return const Expanded(child: SizedBox(height: 56));
            }
            final List<_AjandaOlay> olaylar = harita[gun] ?? <_AjandaOlay>[];
            final List<List<_AjandaOlay>> gruplar = _etkinlikGruplari(olaylar);

            // Her tür için bir nokta. O türün tüm etkinlikleri tamamlandıysa nokta soluk görünür.
            final List<Color> renkler = [];
            final Map<Color, bool> tamamHaritasi = {};
            for (final g in gruplar) {
              final Color rk = _turBul(g.first.etkinlik.turId).renkVerisi;
              if (!renkler.contains(rk)) renkler.add(rk);
              tamamHaritasi[rk] = (tamamHaritasi[rk] ?? true) && _grupTamamMi(g);
            }
            final int adet = gruplar.length;

            final bool secili = gun == aktifGun;
            final bool bugun = buAy && gun == simdi.day;
            return Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() {
                  _ajandaGunSecimi = gun;
                  _ajandaGunAyi = _secilenAyYil;
                }),
                child: Container(
                  height: 56,
                  margin: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: secili ? hucreSecili : (olaylar.isNotEmpty ? hucreZemin : yuzey),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: secili ? const Color(0xFF2563EB) : gri(200)),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(color: bugun ? const Color(0xFF2563EB) : Colors.transparent, shape: BoxShape.circle),
                              child: Text('$gun', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: bugun ? Colors.white : yaziRengi)),
                            ),
                            const SizedBox(height: 3),
                            SizedBox(
                              height: 6,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: renkler
                                    .take(4)
                                    .map((rk) => Container(
                                          width: 6,
                                          height: 6,
                                          margin: const EdgeInsets.symmetric(horizontal: 1),
                                          decoration: BoxDecoration(color: (tamamHaritasi[rk] ?? false) ? rk.withValues(alpha: 0.3) : rk, shape: BoxShape.circle),
                                        ))
                                    .toList(),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // İki veya daha fazla etkinlik varsa sağ üstte adet gösterilir
                      if (adet >= 2)
                        Positioned(
                          top: 3,
                          right: 3,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(color: const Color(0xFF64748B), borderRadius: BorderRadius.circular(8)),
                            child: Text('$adet', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      );
    }

    return Column(
      children: [
        Row(
          children: ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz']
              .map((g) => Expanded(child: Center(child: Text(g, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)))))
              .toList(),
        ),
        const SizedBox(height: 4),
        ...satirlar,
      ],
    );
  }

  // Takvimin altındaki renk açıklaması (bu ay kullanılan türler) ve rakam/soluk nokta açıklaması
  Widget _ajandaAciklama(Map<int, List<_AjandaOlay>> harita) {
    final List<String> kullanilan = [];
    for (final liste in harita.values) {
      for (final o in liste) {
        if (!kullanilan.contains(o.etkinlik.turId)) kullanilan.add(o.etkinlik.turId);
      }
    }
    if (kullanilan.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 12, 6, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: kullanilan.map((id) {
              final tur = _turBul(id);
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: tur.renkVerisi, shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text(tur.ad, style: TextStyle(fontSize: 11, color: gri(700))),
                ],
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _ajandaListeKarti(DateTime dt, Map<int, List<_AjandaOlay>> harita) {
    final List<int> gunler = harita.keys.toList()..sort();
    if (gunler.isEmpty) {
      return _beyazKart(
        child: const Center(
          child: Padding(padding: EdgeInsets.all(14), child: Text('Bu ay için etkinlik yok.', style: TextStyle(color: Colors.grey))),
        ),
      );
    }
    return _beyazKart(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          for (final g in gunler)
            (() {
              final DateTime tarih = DateTime(dt.year, dt.month, g);
              final String gunAnahtari = DateFormat('yyyy-MM-dd').format(tarih);
              final List<List<_AjandaOlay>> gruplar = _ajandaGruplariSirala(_etkinlikGruplari(harita[g]!));
              final bool vurguVar = gruplar.any(_grupVurgulu);
              final int tamam = gruplar.where(_grupTamamMi).length;
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: acikZemin, borderRadius: BorderRadius.circular(14)),
                child: Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: Builder(builder: (tileContext) => ExpansionTile(
                    key: ValueKey('liste_$gunAnahtari${vurguVar ? '_vurgu' : ''}'),
                    initiallyExpanded: _ajandaAcikMi('gun:$gunAnahtari', false) || vurguVar,
                    onExpansionChanged: (v) {
                      _ajandaAcikDurum['gun:$gunAnahtari'] = v;
                      // Gün kapanınca içindeki etkinlikler de kapanır
                      if (!v) {
                        for (final grup in gruplar) {
                          _ajandaAcikDurum.remove('etk:$gunAnahtari:${grup.first.etkinlik.id}');
                        }
                      }
                      if (v) _acilanBolumuGoster(tileContext);
                    },
                    shape: const Border(),
                    collapsedShape: const Border(),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 14),
                    childrenPadding: const EdgeInsets.only(bottom: 6),
                    title: Text(DateFormat('d MMMM, EEEE', 'tr_TR').format(tarih), style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: koyuYazi)),
                    subtitle: Text('${gruplar.length} etkinlik • $tamam tamamlandı', style: TextStyle(fontSize: 11, color: gri(700))),
                    children: [for (final grup in gruplar) _ajandaEtkinlikKutusu(grup, turAdi: true)],
                  )),
                ),
              );
            })(),
        ],
      ),
    );
  }

  Widget _buildAjandaTakvimSekmesi() {
    final DateTime dt = DateTime.parse('$_secilenAyYil-01');
    final int aySonu = DateTime(dt.year, dt.month + 1, 0).day;
    final harita = _ayEtkinlikHaritasi(_secilenAyYil);
    final int aktifGun = _aktifAjandaGunu(aySonu);
    final DateTime aktifTarih = DateTime(dt.year, dt.month, aktifGun);
    final List<_AjandaOlay> gunOlaylari = harita[aktifGun] ?? <_AjandaOlay>[];

    // Aynı etkinliğin birden fazla saati tek etkinlik sayılır (günlük bazda)
    int toplamOlay = 0;
    int tamamlanan = 0;
    int geciken = 0;
    int yaklasan = 0;
    final List<MapEntry<DateTime, List<_AjandaOlay>>> tamamListesi = [];
    final List<MapEntry<DateTime, List<_AjandaOlay>>> gecikenListesi = [];
    final List<MapEntry<DateTime, List<_AjandaOlay>>> yaklasanListesi = [];
    harita.forEach((g, liste) {
      final DateTime gunTarih = DateTime(dt.year, dt.month, g);
      for (final grup in _etkinlikGruplari(liste)) {
        toplamOlay++;
        if (_grupTamamMi(grup)) {
          tamamlanan++;
          tamamListesi.add(MapEntry(gunTarih, grup));
        } else if (_grupGecikti(grup)) {
          geciken++;
          gecikenListesi.add(MapEntry(gunTarih, grup));
        } else {
          yaklasan++;
          yaklasanListesi.add(MapEntry(gunTarih, grup));
        }
      }
    });

    final Widget ayrac = Container(width: 1, height: 38, margin: const EdgeInsets.symmetric(horizontal: 6), color: gri(200));

    return DokunmaDinleyici(
      haricAlan: _ajandaAramaAlani,
      onBosDokunma: () {
        if (!_ajandaAramaAcik || !mounted) return;
        setState(() {
          _ajandaAramaAcik = false;
          _ajandaArama = '';
          _ajandaAramaCtrl.clear();
        });
      },
      child: Column(
      children: [
        _sayfaBasligi(
          _profilBasligi(),
          [
            _ajandaAramaDugmesi(),
            _ajandaGorunumDugmesi(),
            _ajandaSiralamaDugmesi(),
            _hizliEkleDugmesi(),
            _ekleDugmesi(() => _etkinlikDialogGoster(varsayilanGun: aktifTarih)),
          ],
        ),
        if (_ajandaAramaAcik)
          Padding(
            key: _ajandaAramaAlani,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: _aramaKutusu(
              kontrol: _ajandaAramaCtrl,
              ipucu: 'Etkinlik, not veya tür ara…',
              degisti: (v) => setState(() => _ajandaArama = v),
              temizle: () {
                _ajandaAramaCtrl.clear();
                setState(() => _ajandaArama = '');
              },
            ),
          ),
        _buildAySeciciBaslik(bugunSecili: aktifGun == DateTime.now().day),
        if (_ajandaAramaAcik && _ajandaArama.trim().isNotEmpty)
          Expanded(child: _ajandaAramaSonuclari(dt))
        else
          Expanded(
          child: ListView(
            // ignore: deprecated_member_use
            cacheExtent: 4000,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            children: [
              _beyazKart(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kartBasligi(Icons.event_note, 'Bu Ayki Etkinlikler', alt: '$toplamOlay etkinlik'),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(child: _durumSutunu('Tamamlanan', tamamlanan, gelirRengi, CrossAxisAlignment.start, Icons.check_circle_outline, tamamListesi)),
                        ayrac,
                        Expanded(child: _durumSutunu('Geciken', geciken, giderRengi, CrossAxisAlignment.center, Icons.error_outline, gecikenListesi)),
                        ayrac,
                        Expanded(child: _durumSutunu('Yaklaşan', yaklasan, odenenRengi, CrossAxisAlignment.end, Icons.schedule, yaklasanListesi)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (_ajandaListeGorunumu)
                _ajandaListeKarti(dt, harita)
              else ...[
                _beyazKart(
                  padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
                  child: Column(
                    children: [
                      _ajandaTakvimGrid(dt, aySonu, harita, aktifGun),
                      _ajandaAciklama(harita),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _beyazKart(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      Padding(
                        key: _ajandaGunKartiAnahtari,
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            _ikonKutusu(Icons.today),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(DateFormat('d MMMM yyyy', 'tr_TR').format(aktifTarih), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: koyuYazi)),
                                  Text('${DateFormat('EEEE', 'tr_TR').format(aktifTarih)} • ${_etkinlikGruplari(gunOlaylari).length} etkinlik', style: TextStyle(fontSize: 11, color: gri(600))),
                                ],
                              ),
                            ),
                            _dolguEkleDugmesi('Etkinlik Ekle', () => _etkinlikDialogGoster(varsayilanGun: aktifTarih)),
                          ],
                        ),
                      ),
                      Divider(height: 1, color: gri(100)),
                      if (gunOlaylari.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(25.0),
                          child: Text('Bu günde etkinlik yok.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(children: _ajandaGunBloklari(aktifTarih, gunOlaylari)),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 10),
            ],
          ),
        ),
      ],
      ),
    );
  }

  // ============================== ANALİZ SEKMESİ ==============================

  String _sureMetni(int ay) {
    final int yil = ay ~/ 12;
    final int kalanAy = ay % 12;
    final parcalar = <String>[];
    if (yil > 0) parcalar.add('$yil yıl');
    if (kalanAy > 0) parcalar.add('$kalanAy ay');
    return parcalar.isEmpty ? '0 ay' : parcalar.join(' ');
  }

  List<_BorcOgesi> _borcOgeleri() {
    final List<_BorcOgesi> liste = [];
    for (var kredi in krediListesi) {
      liste.add(_BorcOgesi(
        ad: kredi.krediAdi,
        alt: '${kredi.krediTuru} Kredisi',
        renk: _turRengi(kredi.krediTuru),
        ikon: _krediIkonuGetir(kredi.krediTuru),
        aylik: kredi.aylikTutar,
        toplamAy: kredi.toplamTaksit,
        odenenAy: _odenenSayisi(kredi.odenenAylar, kredi.baslangicTarihi, kredi.toplamTaksit),
        baslangic: kredi.baslangicTarihi,
        bitisMetni: _bitisAyiHesapla(kredi.baslangicTarihi, kredi.toplamTaksit, kisa: true),
      ));
    }
    for (var taksit in kartTaksitListesi) {
      final DateTime baslangic = DateTime.parse('${taksit.baslangicAyYil}-01');
      final kart = krediKartiListesi.where((k) => k.id == taksit.kartId).firstOrNull;
      liste.add(_BorcOgesi(
        ad: taksit.baslik,
        alt: 'Kart Taksiti • ${kart?.kartAdi ?? 'Kart'}',
        renk: _turRengi('Kredi Kartı'),
        ikon: Icons.receipt_long,
        aylik: taksit.aylikTutar,
        toplamAy: taksit.toplamTaksit,
        odenenAy: _odenenSayisi(taksit.odenenAylar, baslangic, taksit.toplamTaksit),
        baslangic: baslangic,
        bitisMetni: _bitisAyiHesapla(baslangic, taksit.toplamTaksit, kisa: true),
      ));
    }
    return liste;
  }

  Widget _ilerlemeCubugu(double oran, Color renk, {double yukseklik = 8, Color? arkaPlan}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: LinearProgressIndicator(
        value: oran,
        minHeight: yukseklik,
        backgroundColor: arkaPlan ?? griDugme,
        valueColor: AlwaysStoppedAnimation<Color>(renk),
      ),
    );
  }

  Widget _buildBorcKutusu(_BorcOgesi b) {
    final Color koyu = _koyu(b.renk);
    final int yuzde = (b.oran * 100).round();
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _pastel(b.renk),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: b.renk.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(b.ikon, size: 22, color: b.renk),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(b.ad, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    Text('${b.alt} • Başlangıç: ${DateFormat('MMM yyyy', 'tr_TR').format(b.baslangic)}', style: TextStyle(fontSize: 11, color: gri(700))),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('Kalan', style: TextStyle(fontSize: 10, color: gri(700))),
                  Text(_para(b.kalan), style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: kalanBorcRengi)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: koyu),
                    children: [
                      TextSpan(text: 'Ödenen ${b.odenenAy}/${b.toplamAy} taksit'),
                      TextSpan(text: ' • ${_para(b.odenen)}'),
                    ],
                  ),
                ),
              ),
              Text('%$yuzde', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: koyu)),
            ],
          ),
          const SizedBox(height: 6),
          _ilerlemeCubugu(b.oran, b.renk, arkaPlan: yuzey),
          const SizedBox(height: 6),
          Text(
            'Aylık ${_para(b.aylik)} • ${_sureMetni(b.odenenAy)} ödendi • ${_sureMetni(b.kalanAy)} kaldı • Bitiş: ${b.bitisMetni}',
            style: TextStyle(fontSize: 11, color: gri(700)),
          ),
        ],
      ),
    );
  }

  Widget _buildAnalizSekmesi() {
    final filtrelenmisFinans = _ayKalemleri(_secilenAyYil);

    final ozet = _ozetHesapla(filtrelenmisFinans);
    final double toplamGider = ozet.toplamGider;
    final double odemeOrani = toplamGider > 0 ? (ozet.odenenGider / toplamGider).clamp(0.0, 1.0) : 0.0;

    // Paranın dağılımı (gider veya gelir)
    final Map<String, double> dagilim = _dagilimGelir ? _gelirToplamlari(filtrelenmisFinans) : _kategoriToplamlari(filtrelenmisFinans);
    final kategoriler = dagilim.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    final double dagilimToplami = kategoriler.fold(0.0, (s, e) => s + e.value);

    // Trend: seçili ay dahil son 6 ay
    final DateTime dt = DateTime.parse('$_secilenAyYil-01');
    final List<String> trendAylari = [];
    final List<double> trendGelir = [];
    final List<double> trendGider = [];
    for (int i = 5; i >= 0; i--) {
      final DateTime ay = DateTime(dt.year, dt.month - i, 1);
      final String anahtar = _ayAnahtari(ay);
      final o = _ozetHesapla(_ayKalemleri(anahtar), anahtar);
      trendAylari.add(DateFormat('MMM', 'tr_TR').format(ay));
      trendGelir.add(o.toplamGelir);
      trendGider.add(o.toplamGider);
    }
    final double trendMax = math.max(1.0, [...trendGelir, ...trendGider].reduce(math.max));

    // Borç durumu
    final borclar = _borcOgeleri();
    final devamEden = borclar.where((b) => b.kalanAy > 0).toList()..sort((a, b) => a.kalanAy.compareTo(b.kalanAy));
    final tamamlanan = borclar.where((b) => b.kalanAy == 0).toList();
    final double borcToplam = borclar.fold(0.0, (s, b) => s + b.toplam);
    final double borcOdenen = borclar.fold(0.0, (s, b) => s + b.odenen);
    final double borcKalan = math.max(0.0, borcToplam - borcOdenen);
    final double borcOran = borcToplam > 0 ? (borcOdenen / borcToplam).clamp(0.0, 1.0) : 0.0;
    final double tamamlananToplam = tamamlanan.fold(0.0, (s, b) => s + b.toplam);

    return Column(
      children: [
        _sayfaBasligi(_profilBasligi(), [_gizlilikDugmesi()]),
        _buildAySeciciBaslik(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            children: [
              // ---- Aylık özet ----
              _beyazKart(
                child: Column(
                  children: [
                    _kartBasligi(Icons.account_balance_wallet_outlined, 'Aylık Özet'),
                    const SizedBox(height: 14),
                    _ucluOzet(ozet.toplamGelir, toplamGider),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // ---- Bu ayın ödeme durumu ----
              _beyazKart(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kartBasligi(Icons.task_alt, 'Bu Ayın Ödeme Durumu', alt: 'Bu ayki giderlerin ne kadarı ödendi'),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(child: Text('Ödenen ${_para(ozet.odenenGider)}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: odenenRengi))),
                        Text('%${(odemeOrani * 100).round()}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: odenenRengi)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _ilerlemeCubugu(odemeOrani, odenenRengi),
                    const SizedBox(height: 6),
                    Text.rich(
                      TextSpan(
                        style: TextStyle(fontSize: 11, color: gri(600)),
                        children: [
                          const TextSpan(text: 'Toplam '),
                          TextSpan(text: _para(toplamGider), style: TextStyle(fontWeight: FontWeight.bold, color: giderRengi)),
                          const TextSpan(text: ' • Kalan '),
                          TextSpan(text: _para(math.max(0.0, toplamGider - ozet.odenenGider)), style: TextStyle(fontWeight: FontWeight.bold, color: kalanBorcRengi)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // ---- Paranın dağılımı ----
              _beyazKart(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kartBasligi(
                      Icons.pie_chart_outline,
                      'Paranın Dağılımı',
                      alt: _dagilimGelir ? 'Bu ayki gelirlerin kaynaklara göre dağılımı' : 'Bu ayki giderlerin türlere göre dağılımı',
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        ChoiceChip(
                          label: const Text('Giderler'),
                          selected: !_dagilimGelir,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => setState(() => _dagilimGelir = false),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('Gelirler'),
                          selected: _dagilimGelir,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => setState(() => _dagilimGelir = true),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (kategoriler.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Center(child: Text(_dagilimGelir ? 'Bu aya ait gelir verisi yok.' : 'Bu aya ait gider verisi yok.', style: const TextStyle(color: Colors.grey, fontSize: 13))),
                      )
                    else ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          height: 24,
                          child: Row(
                            children: kategoriler
                                .map((e) => Expanded(
                                      flex: (e.value / dagilimToplami * 1000).round().clamp(1, 1000),
                                      child: Container(color: _renk(e.key, gelir: _dagilimGelir)),
                                    ))
                                .toList(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...kategoriler.map((e) {
                        final double yuzde = e.value / dagilimToplami * 100;
                        final Color renk = _renk(e.key, gelir: _dagilimGelir);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Icon(_dagilimGelir ? _gelirIkonu(e.key) : _kategoriIkonuGetir(e.key), size: 20, color: renk),
                              const SizedBox(width: 10),
                              Expanded(child: Text(e.key, style: const TextStyle(fontSize: 13))),
                              Text('%${yuzde.toStringAsFixed(1).replaceAll('.', ',')}', style: TextStyle(fontSize: 11, color: gri(600))),
                              const SizedBox(width: 12),
                              Text(_para(e.value), style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _dagilimGelir ? gelirRengi : koyuYazi)),
                            ],
                          ),
                        );
                      }),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // ---- Son 6 ay ----
              _beyazKart(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kartBasligi(
                      Icons.bar_chart,
                      'Son 6 Ay',
                      alt: 'Aylık gelir ve gider karşılaştırması',
                      sag: Row(
                        children: [
                          Container(width: 8, height: 8, decoration: BoxDecoration(color: gelirRengi, shape: BoxShape.circle)),
                          const SizedBox(width: 4),
                          const Text('Gelir', style: TextStyle(fontSize: 11)),
                          const SizedBox(width: 8),
                          Container(width: 8, height: 8, decoration: BoxDecoration(color: giderRengi, shape: BoxShape.circle)),
                          const SizedBox(width: 4),
                          const Text('Gider', style: TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: List<Widget>.generate(6, (i) {
                        final double gelirYuk = 90 * trendGelir[i] / trendMax;
                        final double giderYuk = 90 * trendGider[i] / trendMax;
                        return Expanded(
                          child: Column(
                            children: [
                              SizedBox(
                                height: 96,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Container(width: 9, height: math.max(2.0, gelirYuk), decoration: BoxDecoration(color: gelirRengi, borderRadius: BorderRadius.circular(4))),
                                    const SizedBox(width: 3),
                                    Container(width: 9, height: math.max(2.0, giderYuk), decoration: BoxDecoration(color: giderRengi, borderRadius: BorderRadius.circular(4))),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(trendAylari[i], style: TextStyle(fontSize: 10, color: i == 5 ? anaRenk : Colors.grey, fontWeight: i == 5 ? FontWeight.bold : FontWeight.normal)),
                            ],
                          ),
                        );
                      }),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // ---- Borçtan kurtulma ----
              _beyazKart(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kartBasligi(Icons.flag_outlined, 'Ne Zaman Borçtan Kurtulacağım?', alt: 'Tüm kredi ve kart taksitleri'),
                    const SizedBox(height: 14),
                    if (borclar.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('Kayıtlı kredi veya kart taksiti yok.', style: TextStyle(color: Colors.grey, fontSize: 13)),
                      )
                    else ...[
                      Row(
                        children: [
                          Expanded(child: _bilgiSutunu('Toplam Borç', _para(borcToplam), giderRengi, CrossAxisAlignment.start)),
                          Expanded(child: _bilgiSutunu('Toplam Kalan', _para(borcKalan), kalanBorcRengi, CrossAxisAlignment.end)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: Text('Ödenen ${_para(borcOdenen)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: odenenRengi))),
                          Text('%${(borcOran * 100).round()}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: odenenRengi)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      _ilerlemeCubugu(borcOran, odenenRengi),
                      if (devamEden.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text('Devam eden (${devamEden.length})', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: gri(700))),
                        const SizedBox(height: 4),
                        ...devamEden.map(_buildBorcKutusu),
                      ],
                      if (tamamlanan.isNotEmpty) ...[
                        const Divider(height: 24),
                        Row(
                          children: [
                            const Icon(Icons.check_circle, size: 18, color: Colors.green),
                            const SizedBox(width: 8),
                            Expanded(child: Text('Tamamlanan (${tamamlanan.length})', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: gri(700)))),
                            Text(_para(tamamlananToplam), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ],
    );
  }

  // ============================== AYARLAR SEKMESİ ==============================

  Widget _ayarSatiri({required IconData ikon, required Color renk, required String baslik, required String alt, required VoidCallback onTap, IconData sagIkon = Icons.chevron_right}) {
    return ListTile(
      onTap: onTap,
      leading: _ikonKutusu(ikon, renk: renk),
      title: Text(baslik, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: koyuYazi)),
      subtitle: Text(alt, style: TextStyle(fontSize: 12, color: gri(600))),
      trailing: Icon(sagIkon, size: 18, color: Colors.grey),
    );
  }

  // ============================== DÜZENLEME PENCERELERİ ==============================

  // Alt pencerelerin ortak başlığı
  Widget _pencereBasligi(BuildContext ctx, IconData ikon, String baslik) {
    return Row(
      children: [
        _ikonKutusu(ikon),
        const SizedBox(width: 10),
        Expanded(child: Text(baslik, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: koyuYazi))),
        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(ctx).pop()),
      ],
    );
  }

  ButtonStyle get _anaDugmeStili => ElevatedButton.styleFrom(backgroundColor: anaRenk, foregroundColor: Colors.white);

  Future<void> _kartDuzenleDialogGoster(KrediKarti kart) async {
    final formKey = GlobalKey<FormState>();
    final kartAdiCtrl = TextEditingController(text: kart.kartAdi);
    final sonOdemeGunuCtrl = TextEditingController(text: kart.sonOdemeGunu);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (innerContext) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(innerContext).viewInsets.bottom),
        child: Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(innerContext).size.height * 0.75),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _pencereBasligi(innerContext, Icons.credit_card, 'Kredi Kartını Düzenle'),
              const Divider(),
              Flexible(
                child: SingleChildScrollView(
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextFormField(
                          controller: kartAdiCtrl,
                          decoration: const InputDecoration(labelText: 'Kart Adı'),
                          validator: (val) => val == null || val.isEmpty ? 'Bu alan boş bırakılamaz' : null,
                        ),
                        _sonOdemeGunuAlani(sonOdemeGunuCtrl),
                        const SizedBox(height: 20),
                        ElevatedButton(
                          style: _anaDugmeStili,
                          onPressed: () {
                            if (formKey.currentState!.validate()) {
                              setState(() {
                                kart.kartAdi = kartAdiCtrl.text;
                                kart.sonOdemeGunu = sonOdemeGunuCtrl.text;
                              });
                              Navigator.of(innerContext).pop();
                            }
                          },
                          child: const Text('Güncelle'),
                        ),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _taksitDuzenleDialogGoster(KartTaksiti taksit) async {
    final formKey = GlobalKey<FormState>();
    final baslikCtrl = TextEditingController(text: taksit.baslik);
    final tutarCtrl = TextEditingController(text: _sayiMetni(taksit.aylikTutar));
    final taksitSayisiCtrl = TextEditingController(text: taksit.toplamTaksit.toString());
    String secilenKartId = taksit.kartId;
    String secilenBaslangicAy = taksit.baslangicAyYil;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (innerContext) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _pencereBasligi(innerContext, Icons.receipt_long, 'Taksitli Harcamayı Düzenle'),
                const Divider(),
                Flexible(
                  child: SingleChildScrollView(
                    child: Form(
                      key: formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DropdownButton<String>(
                            value: krediKartiListesi.any((k) => k.id == secilenKartId) ? secilenKartId : null,
                            isExpanded: true,
                            hint: const Text('Kredi Kartı Seçin'),
                            items: krediKartiListesi.map((k) => DropdownMenuItem(value: k.id, child: Text('💳 ${k.kartAdi}'))).toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setModalState(() => secilenKartId = val);
                              }
                            },
                          ),
                          TextFormField(
                            controller: baslikCtrl,
                            decoration: const InputDecoration(labelText: 'Başlık'),
                            validator: (val) => val == null || val.isEmpty ? 'Bu alan boş bırakılamaz' : null,
                          ),
                          TextFormField(
                            controller: tutarCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*[.,]?\d*'))],
                            decoration: const InputDecoration(labelText: 'Aylık Taksit Tutarı (₺)'),
                            validator: (val) => val == null || val.isEmpty ? 'Bu alan boş bırakılamaz' : null,
                          ),
                          TextFormField(
                            controller: taksitSayisiCtrl,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                            decoration: const InputDecoration(labelText: 'Toplam Taksit Sayısı (Ay)'),
                            validator: (val) => val == null || val.isEmpty ? 'Bu alan boş bırakılamaz' : null,
                          ),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Başlangıç Ayı: ${_ayAdi(secilenBaslangicAy)}', style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
                              TextButton(
                                onPressed: () async {
                                  DateTime? picked = await showDatePicker(
                                    context: context,
                                    initialDate: DateTime.parse('$secilenBaslangicAy-01'),
                                    firstDate: enEskiTarih,
                                    lastDate: enYeniTarih,
                                  );
                                  if (!context.mounted) return;
                                  if (picked != null) {
                                    setModalState(() {
                                      secilenBaslangicAy = _ayAnahtari(picked);
                                    });
                                  }
                                },
                                child: const Text('Ayı Değiştir'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          ElevatedButton(
                            style: _anaDugmeStili,
                            onPressed: () {
                              if (formKey.currentState!.validate()) {
                                double aylik = double.tryParse(tutarCtrl.text.replaceAll(',', '.')) ?? 0.0;
                                int toplam = int.tryParse(taksitSayisiCtrl.text) ?? taksit.toplamTaksit;

                                final String? ekstreHatasi = _taksitEkstreHatasi(kartId: secilenKartId, baslangicAy: secilenBaslangicAy, toplam: toplam, aylik: aylik, haricTaksitId: taksit.id);
                                if (ekstreHatasi != null) {
                                  showDialog(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('Taksit ekstreyi aşıyor'),
                                      content: Text(ekstreHatasi),
                                      actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tamam'))],
                                    ),
                                  );
                                  return;
                                }

                                setState(() {
                                  taksit.baslik = baslikCtrl.text;
                                  taksit.aylikTutar = aylik;
                                  taksit.toplamTaksit = toplam;
                                  taksit.kartId = secilenKartId;
                                  taksit.baslangicAyYil = secilenBaslangicAy;
                                  // Tarih/taksit sayısı değiştiyse ödenen aylar yeniden hesaplanır
                                  taksit.odenenAylar = _odenenAylariYenidenHesapla(taksit.odenenAylar, DateTime.parse('$secilenBaslangicAy-01'), toplam);
                                });
                                Navigator.of(innerContext).pop();
                              }
                            },
                            child: const Text('Güncelle'),
                          ),
                          const SizedBox(height: 20),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _krediDuzenleDialogGoster(KrediBorcu kredi) async {
    final formKey = GlobalKey<FormState>();
    final krediAdiCtrl = TextEditingController(text: kredi.krediAdi);
    final tutarCtrl = TextEditingController(text: _sayiMetni(kredi.aylikTutar));
    final taksitSayisiCtrl = TextEditingController(text: kredi.toplamTaksit.toString());
    final sonOdemeGunuCtrl = TextEditingController(text: kredi.sonOdemeGunu);
    String secilenKrediTuru = kredi.krediTuru;
    DateTime secilenBaslangicTarihi = kredi.baslangicTarihi;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (innerContext) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _pencereBasligi(innerContext, Icons.account_balance, 'Krediyi Düzenle'),
                const Divider(),
                Flexible(
                  child: SingleChildScrollView(
                    child: Form(
                      key: formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DropdownButton<String>(
                            value: secilenKrediTuru,
                            isExpanded: true,
                            items: _krediTuruSecenekleri(),
                            onChanged: (val) {
                              if (val != null) {
                                setModalState(() => secilenKrediTuru = val);
                              }
                            },
                          ),
                          TextFormField(
                            controller: krediAdiCtrl,
                            decoration: const InputDecoration(labelText: 'Başlık (Örn: Ev Kredisi)'),
                            validator: (val) => val == null || val.isEmpty ? 'Bu alan boş bırakılamaz' : null,
                          ),
                          TextFormField(
                            controller: tutarCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*[.,]?\d*'))],
                            decoration: const InputDecoration(labelText: 'Aylık Taksit Tutarı (₺)'),
                            validator: (val) => val == null || val.isEmpty ? 'Bu alan boş bırakılamaz' : null,
                          ),
                          TextFormField(
                            controller: taksitSayisiCtrl,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                            decoration: const InputDecoration(labelText: 'Toplam Taksit Sayısı (Ay)'),
                            validator: (val) => val == null || val.isEmpty ? 'Bu alan boş bırakılamaz' : null,
                          ),
                          _sonOdemeGunuAlani(sonOdemeGunuCtrl),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Başlangıç Tarihi: ${DateFormat('dd.MM.yyyy', 'tr_TR').format(secilenBaslangicTarihi)}', style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
                              TextButton(
                                onPressed: () async {
                                  DateTime? picked = await showDatePicker(
                                    context: context,
                                    initialDate: secilenBaslangicTarihi,
                                    firstDate: enEskiTarih,
                                    lastDate: enYeniTarih,
                                  );
                                  if (!context.mounted) return;
                                  if (picked != null) {
                                    setModalState(() {
                                      secilenBaslangicTarihi = picked;
                                    });
                                  }
                                },
                                child: const Text('Tarihi Değiştir'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          ElevatedButton(
                            style: _anaDugmeStili,
                            onPressed: () {
                              if (formKey.currentState!.validate()) {
                                double aylik = double.tryParse(tutarCtrl.text.replaceAll(',', '.')) ?? 0.0;
                                int toplam = int.tryParse(taksitSayisiCtrl.text) ?? kredi.toplamTaksit;

                                setState(() {
                                  kredi.krediAdi = krediAdiCtrl.text;
                                  kredi.krediTuru = secilenKrediTuru;
                                  kredi.aylikTutar = aylik;
                                  kredi.toplamTaksit = toplam;
                                  kredi.baslangicTarihi = secilenBaslangicTarihi;
                                  kredi.sonOdemeGunu = sonOdemeGunuCtrl.text;
                                  // Tarih/taksit sayısı değiştiyse ödenen aylar yeniden hesaplanır
                                  kredi.odenenAylar = _odenenAylariYenidenHesapla(kredi.odenenAylar, secilenBaslangicTarihi, toplam);
                                });
                                Navigator.of(innerContext).pop();
                              }
                            },
                            child: const Text('Güncelle'),
                          ),
                          const SizedBox(height: 20),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _yeniKartEkleDialogGoster() async {
    final kartFormKey = GlobalKey<FormState>();
    final kartAdiCtrl = TextEditingController();
    final kartSonOdemeGunuCtrl = TextEditingController(text: '25');

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Yeni Kart Ekle'),
        content: Form(
          key: kartFormKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: kartAdiCtrl,
                decoration: const InputDecoration(labelText: 'Kart Adı (Örn: Bonus, Axess)'),
                validator: (val) => val == null || val.isEmpty ? 'Bu alan boş bırakılamaz' : null,
              ),
              _sonOdemeGunuAlani(kartSonOdemeGunuCtrl),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
          ElevatedButton(
            style: _anaDugmeStili,
            onPressed: () {
              if (kartFormKey.currentState!.validate()) {
                setState(() {
                  krediKartiListesi.add(
                    KrediKarti(
                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                      kartAdi: kartAdiCtrl.text,
                      limit: 50000,
                      sonOdemeGunu: kartSonOdemeGunuCtrl.text,
                    ),
                  );
                });
                Navigator.pop(ctx);
              }
            },
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
  }

  // Sabit ödeme / gelir ekleme ve düzenleme
  Future<void> _sabitOdemeDialogGoster({SabitOdeme? mevcut}) async {
    final formKey = GlobalKey<FormState>();
    bool isGelir = mevcut?.isGelir ?? false;
    const giderKat = ['Fatura', 'Kira & Ev', 'Market', 'Diğer (Özel)'];
    const gelirKat = ['Maaş', 'Ek Gelir', 'Yatırım', 'Kira Geliri', 'Diğer (Özel)'];

    String kategori = mevcut?.kategori ?? 'Fatura';
    if (!giderKat.contains(kategori) && !gelirKat.contains(kategori)) kategori = 'Diğer (Özel)';
    final ozelCtrl = TextEditingController(text: kategori == 'Diğer (Özel)' && mevcut != null ? mevcut.kategori : '');

    // Tutar değişikliği hangi aydan itibaren geçerli olacak
    final String degisimAyi = mevcut == null ? _secilenAyYil : (mevcut.baslangicAyYil.compareTo(_secilenAyYil) > 0 ? mevcut.baslangicAyYil : _secilenAyYil);
    final baslikCtrl = TextEditingController(text: mevcut?.baslik ?? '');
    final tutarCtrl = TextEditingController(text: mevcut != null ? _sayiMetni(mevcut.tutarAy(degisimAyi)) : '');
    final gunCtrl = TextEditingController(text: mevcut?.gun ?? DateTime.now().day.toString());
    String baslangic = mevcut?.baslangicAyYil ?? _secilenAyYil;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (innerContext) => StatefulBuilder(
        builder: (context, setModalState) {
          final List<String> kategoriler = isGelir ? gelirKat : giderKat;
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
            child: Container(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _pencereBasligi(innerContext, Icons.autorenew, mevcut == null ? 'Yeni Sabit Ödeme' : 'Sabit Ödemeyi Düzenle'),
                  const Divider(),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Form(
                        key: formKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(color: acikZemin, borderRadius: BorderRadius.circular(10)),
                              child: Text(
                                mevcut == null
                                    ? 'Her ay otomatik olarak eklenir. Ödemediğin tutar sonraki aya devreder.'
                                    : 'Yaptığın değişiklikler ${_ayAdi(degisimAyi)} ve sonraki aylara uygulanır. Geçmiş aylar değişmez.',
                                style: TextStyle(fontSize: 12, color: koyuYazi),
                              ),
                            ),
                            const SizedBox(height: 10),
                            if (mevcut == null)
                              Row(
                                children: [
                                  Expanded(
                                    child: ChoiceChip(
                                      label: const Text('Gider'),
                                      selected: !isGelir,
                                      onSelected: (_) => setModalState(() {
                                        isGelir = false;
                                        kategori = 'Fatura';
                                      }),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: ChoiceChip(
                                      label: const Text('Gelir'),
                                      selected: isGelir,
                                      onSelected: (_) => setModalState(() {
                                        isGelir = true;
                                        kategori = 'Maaş';
                                      }),
                                    ),
                                  ),
                                ],
                              ),
                            DropdownButton<String>(
                              value: kategoriler.contains(kategori) ? kategori : 'Diğer (Özel)',
                              isExpanded: true,
                              items: kategoriler
                                  .map((kat) => DropdownMenuItem<String>(
                                        value: kat,
                                        child: Row(
                                          children: [
                                            Icon(isGelir ? _gelirIkonu(kat) : _kategoriIkonuGetir(kat), size: 20, color: _renk(kat, gelir: isGelir)),
                                            const SizedBox(width: 8),
                                            Text(kat),
                                          ],
                                        ),
                                      ))
                                  .toList(),
                              onChanged: (val) {
                                if (val != null) setModalState(() => kategori = val);
                              },
                            ),
                            if (kategori == 'Diğer (Özel)')
                              TextFormField(
                                controller: ozelCtrl,
                                decoration: const InputDecoration(labelText: 'Özel Kategori Adı'),
                                validator: (val) => val == null || val.isEmpty ? 'Bu alan boş bırakılamaz' : null,
                              ),
                            TextFormField(
                              controller: baslikCtrl,
                              decoration: InputDecoration(labelText: isGelir ? 'Başlık (Örn: Maaş)' : 'Başlık (Örn: Telefon Faturası)'),
                              validator: (val) => val == null || val.isEmpty ? 'Bu alan boş bırakılamaz' : null,
                            ),
                            TextFormField(
                              controller: tutarCtrl,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*[.,]?\d*'))],
                              decoration: const InputDecoration(labelText: 'Aylık Tutar (₺)'),
                              validator: (val) => val == null || val.isEmpty ? 'Bu alan boş bırakılamaz' : null,
                            ),
                            _sonOdemeGunuAlani(gunCtrl, etiket: isGelir ? 'Her ayın kaçında? (1-31)' : 'Son Ödeme Günü (1-31)'),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Başlangıç: ${_ayAdi(baslangic)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                                TextButton(
                                  onPressed: () async {
                                    DateTime? picked = await showDatePicker(
                                      context: context,
                                      initialDate: DateTime.parse('$baslangic-01'),
                                      firstDate: enEskiTarih,
                                      lastDate: enYeniTarih,
                                    );
                                    if (!context.mounted) return;
                                    if (picked != null) setModalState(() => baslangic = _ayAnahtari(picked));
                                  },
                                  child: const Text('Değiştir'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                style: _anaDugmeStili,
                                onPressed: () {
                                  if (!formKey.currentState!.validate()) {
                                    _ilkHataliAlanaKaydir(formKey);
                                    return;
                                  }
                                  final double tutar = double.tryParse(tutarCtrl.text.replaceAll(',', '.')) ?? 0;
                                  final String katFinal = kategori == 'Diğer (Özel)' ? ozelCtrl.text : kategori;
                                  setState(() {
                                    if (mevcut == null) {
                                      sabitListesi.add(SabitOdeme(
                                        id: 'sabit_${DateTime.now().microsecondsSinceEpoch}',
                                        baslik: baslikCtrl.text,
                                        kategori: katFinal,
                                        isGelir: isGelir,
                                        gun: gunCtrl.text,
                                        baslangicAyYil: baslangic,
                                        tutarlar: {baslangic: tutar},
                                      ));
                                    } else {
                                      final s = mevcut;
                                      s.baslik = baslikCtrl.text;
                                      s.kategori = katFinal;
                                      s.gun = gunCtrl.text;
                                      s.baslangicAyYil = baslangic;
                                      final String uygulamaAyi = baslangic.compareTo(degisimAyi) > 0 ? baslangic : degisimAyi;
                                      if ((s.tutarAy(uygulamaAyi) - tutar).abs() > 0.009) {
                                        s.tutarlar.removeWhere((k, v) => k.compareTo(uygulamaAyi) > 0);
                                        s.tutarlar[uygulamaAyi] = tutar;
                                      }
                                      // Başlangıçtan önceki ödenmemiş kayıtları kaldır
                                      finansListesi.removeWhere((k) => k.sabitId == s.id && k.ayYilAnahtari.compareTo(s.baslangicAyYil) < 0 && k.odemeler.isEmpty);
                                      // Devam eden ayların kayıtlarını güncelle
                                      for (final k in finansListesi.where((k) => k.sabitId == s.id)) {
                                        k.baslik = s.baslik;
                                        k.kategori = s.kategori;
                                        if (k.ayYilAnahtari.compareTo(uygulamaAyi) >= 0 && k.odemeler.isEmpty) {
                                          final DateTime d = DateTime.parse('${k.ayYilAnahtari}-01');
                                          k.tutar = s.tutarAy(k.ayYilAnahtari);
                                          k.tarih = DateTime(d.year, d.month, _gunSinirla(s.gun, DateTime(d.year, d.month + 1, 0).day));
                                        }
                                      }
                                    }
                                    _sabitleriUret();
                                  });
                                  Navigator.of(innerContext).pop();
                                },
                                child: Text(mevcut == null ? 'Kaydet' : 'Güncelle'),
                              ),
                            ),
                            if (mevcut != null)
                              Center(
                                child: TextButton.icon(
                                  onPressed: () async {
                                    Navigator.of(innerContext).pop();
                                    await _sabitSilDialog(mevcut);
                                  },
                                  icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                                  label: const Text('Sabit Ödemeyi Kaldır', style: TextStyle(color: Colors.red)),
                                ),
                              ),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // Yönetim penceresindeki pastel satır
  Widget _yonetimSatiri({
    required IconData ikon,
    required Color renk,
    required String baslik,
    required String alt,
    required VoidCallback onEdit,
    required VoidCallback onDelete,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: _pastel(renk),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: renk.withValues(alpha: 0.25)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 14, right: 4),
        leading: Icon(ikon, color: renk),
        title: Text(baslik, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        subtitle: Text(alt, style: TextStyle(fontSize: 11, color: gri(700))),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(icon: Icon(Icons.edit, color: anaRenk, size: 18), onPressed: onEdit),
            IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18), onPressed: onDelete),
          ],
        ),
      ),
    );
  }

  Widget _yonetimBasligi(IconData ikon, String baslik, VoidCallback onEkle, String ekleMetni) {
    return Row(
      children: [
        _ikonKutusu(ikon),
        const SizedBox(width: 10),
        Expanded(child: Text(baslik, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: koyuYazi))),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: anaRenk,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: onEkle,
          icon: const Icon(Icons.add, size: 18),
          label: Text(ekleMetni, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }

  void _krediKartlariYonetimDialogGoster() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (innerContext) => StatefulBuilder(
        builder: (sheetContext, setModalState) {
          // Alt pencere kapanınca bu pencere de anında yenilensin
          Future<void> sonraYenile(Future<void> islem) async {
            await islem;
            if (sheetContext.mounted) setModalState(() {});
          }

          final String buAy = _ayAnahtari(DateTime.now());

          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
            child: Container(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.85),
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _pencereBasligi(innerContext, Icons.credit_card_rounded, 'Kartlar, Taksitler, Krediler & Sabit Ödemeler'),
                  const Divider(),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 1. KARTLARIM
                          _yonetimBasligi(Icons.credit_card, 'Kartlarım', () => sonraYenile(_yeniKartEkleDialogGoster()), 'Kart Ekle'),
                          const SizedBox(height: 6),
                          if (krediKartiListesi.isEmpty)
                            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Henüz eklenmiş kart yok.', style: TextStyle(color: Colors.grey, fontSize: 12)))
                          else
                            ...krediKartiListesi.map((kart) {
                              final int taksitSayisi = kartTaksitListesi.where((t) => t.kartId == kart.id).length;
                              return _yonetimSatiri(
                                ikon: Icons.credit_card,
                                renk: _turRengi('Kredi Kartı'),
                                baslik: kart.kartAdi,
                                alt: 'Her ayın ${kart.sonOdemeGunu}. günü son ödeme • $taksitSayisi Taksit',
                                onEdit: () => sonraYenile(_kartDuzenleDialogGoster(kart)),
                                onDelete: () {
                                  int ekstreSayisi = finansListesi.where((i) => i.kartId == kart.id).length;
                                  String mesaj = '"${kart.kartAdi}" kartını silmek istediğinize emin misiniz?';
                                  if (taksitSayisi > 0 || ekstreSayisi > 0) {
                                    mesaj += '\n\nBu karta bağlı $taksitSayisi taksit ve $ekstreSayisi ekstre kaydı da silinecek.';
                                  }
                                  _silmeOnayiGoster(sheetContext, mesaj, () {
                                    _kartSil(kart.id);
                                    setModalState(() {});
                                  });
                                },
                              );
                            }),
                          const Divider(height: 30),
                          // 2. KART TAKSİTLERİM
                          _yonetimBasligi(Icons.receipt_long, 'Kart Taksitlerim', () => sonraYenile(_islemEkleDialogGoster(baslangicKategori: 'Kredi Kartı Taksiti')), 'Taksit Ekle'),
                          const SizedBox(height: 6),
                          if (kartTaksitListesi.isEmpty)
                            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Henüz eklenmiş kart taksiti yok.', style: TextStyle(color: Colors.grey, fontSize: 12)))
                          else
                            ...kartTaksitListesi.map((taksit) {
                              final String kartAdi = krediKartiListesi.where((k) => k.id == taksit.kartId).firstOrNull?.kartAdi ?? 'Bilinmeyen Kart';
                              final DateTime baslangic = DateTime.parse('${taksit.baslangicAyYil}-01');
                              final int odenenAy = _odenenSayisi(taksit.odenenAylar, baslangic, taksit.toplamTaksit);
                              final double kalanBorc = taksit.aylikTutar * (taksit.toplamTaksit - odenenAy);
                              return _yonetimSatiri(
                                ikon: Icons.receipt_long,
                                renk: _turRengi('Kredi Kartı'),
                                baslik: '${taksit.baslik} ($kartAdi)',
                                alt: 'Aylık ${_para(taksit.aylikTutar)} • Ödenen $odenenAy/${taksit.toplamTaksit} • Kalan ${_para(kalanBorc)} • Bitiş: ${_bitisAyiHesapla(baslangic, taksit.toplamTaksit)}',
                                onEdit: () => sonraYenile(_taksitDuzenleDialogGoster(taksit)),
                                onDelete: () => _silmeOnayiGoster(sheetContext, 'Bu taksiti silmek istediğinize emin misiniz?', () {
                                  _taksitSil(taksit.id);
                                  setModalState(() {});
                                }),
                              );
                            }),
                          const Divider(height: 30),
                          // 3. KREDİLERİM
                          _yonetimBasligi(Icons.account_balance, 'Kredilerim', () => sonraYenile(_islemEkleDialogGoster(baslangicKategori: 'Kredi')), 'Kredi Ekle'),
                          const SizedBox(height: 6),
                          if (krediListesi.isEmpty)
                            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Henüz eklenmiş kredi yok.', style: TextStyle(color: Colors.grey, fontSize: 12)))
                          else
                            ...krediListesi.map((kredi) {
                              final int odenenAy = _odenenSayisi(kredi.odenenAylar, kredi.baslangicTarihi, kredi.toplamTaksit);
                              final double kalanKrediBorcu = kredi.aylikTutar * (kredi.toplamTaksit - odenenAy);
                              return _yonetimSatiri(
                                ikon: _krediIkonuGetir(kredi.krediTuru),
                                renk: _turRengi(kredi.krediTuru),
                                baslik: kredi.krediAdi,
                                alt: '${kredi.krediTuru} Kredisi • Aylık ${_para(kredi.aylikTutar)} • Son ödeme ayın ${kredi.sonOdemeGunu}. günü • Ödenen $odenenAy/${kredi.toplamTaksit} • Kalan ${_para(kalanKrediBorcu)} • Bitiş: ${_bitisAyiHesapla(kredi.baslangicTarihi, kredi.toplamTaksit)}',
                                onEdit: () => sonraYenile(_krediDuzenleDialogGoster(kredi)),
                                onDelete: () => _silmeOnayiGoster(sheetContext, '"${kredi.krediAdi}" kredisini silmek istediğinize emin misiniz?', () {
                                  _krediSil(kredi.id);
                                  setModalState(() {});
                                }),
                              );
                            }),
                          const Divider(height: 30),
                          // 4. SABİT ÖDEMELERİM
                          _yonetimBasligi(Icons.autorenew, 'Sabit Ödemelerim', () => sonraYenile(_sabitOdemeDialogGoster()), 'Sabit Ekle'),
                          const SizedBox(height: 2),
                          Text('Kira, fatura, abonelik, maaş gibi her ay tekrarlanan kalemler', style: TextStyle(fontSize: 11, color: gri(600))),
                          const SizedBox(height: 6),
                          if (sabitListesi.isEmpty)
                            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Henüz eklenmiş sabit ödeme yok.', style: TextStyle(color: Colors.grey, fontSize: 12)))
                          else
                            ...sabitListesi.map((s) {
                              final String? bitis = s.bitisAyYil;
                              final String sure = bitis == null ? '${_ayAdi(s.baslangicAyYil, kisa: true)}\'dan beri' : '${_ayAdi(s.baslangicAyYil, kisa: true)} – ${_ayAdi(bitis, kisa: true)}';
                              return _yonetimSatiri(
                                ikon: s.isGelir ? _gelirIkonu(s.kategori) : _kategoriIkonuGetir(s.kategori),
                                renk: _renk(s.kategori, gelir: s.isGelir),
                                baslik: s.baslik,
                                alt: '${s.isGelir ? 'Gelir' : 'Gider'} • ${s.kategori} • Her ayın ${s.gun}. günü • ${_para(s.tutarAy(buAy))} • $sure',
                                onEdit: () => sonraYenile(_sabitOdemeDialogGoster(mevcut: s)),
                                onDelete: () => sonraYenile(_sabitSilDialog(s)),
                              );
                            }),
                          const SizedBox(height: 20),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _islemEkleDialogGoster({FinansKalemi? mevcut, String? baslangicKategori}) async {
    final formKey = GlobalKey<FormState>();
    final baslikCtrl = TextEditingController(text: mevcut?.baslik ?? '');
    final tutarCtrl = TextEditingController(text: mevcut != null ? _sayiMetni(mevcut.tutar) : '');
    bool isGelir = mevcut?.isGelir ?? false;
    bool tekrarla = false;

    List<String> giderKatListesi = ['Kredi Kartı Ekstresi', 'Kredi Kartı Taksiti', 'Kredi', 'Market', 'Fatura', 'Kira & Ev', 'Diğer (Özel)'];
    List<String> gelirKatListesi = ['Maaş', 'Ek Gelir', 'Yatırım', 'Kira Geliri', 'Diğer (Özel)'];

    String secilenKategori = mevcut?.kategori ?? baslangicKategori ?? (isGelir ? 'Maaş' : 'Kredi Kartı Ekstresi');
    if (!giderKatListesi.contains(secilenKategori) && !gelirKatListesi.contains(secilenKategori)) {
      secilenKategori = 'Diğer (Özel)';
    }
    final ozelKategoriCtrl = TextEditingController(text: secilenKategori == 'Diğer (Özel)' && mevcut != null ? mevcut.kategori : '');

    String? secilenKartId = mevcut?.kartId ?? (krediKartiListesi.isNotEmpty ? krediKartiListesi.first.id : null);

    final taksitSayisiCtrl = TextEditingController(text: '3');
    String taksitBaslangicAy = _secilenAyYil;

    final krediTaksitSayisiCtrl = TextEditingController(text: '12');
    final krediSonOdemeGunuCtrl = TextEditingController(text: '25');
    DateTime krediBaslangicTarihi = DateTime.now();
    String secilenKrediTuru = 'İhtiyaç';

    // Yeni kayıtta: bu ay seçiliyse bugünün tarihi, değilse seçili ayın 1'i
    final DateTime simdi = DateTime.now();
    final bool buAySecili = _secilenAyYil == _ayAnahtari(simdi);
    DateTime islemTarihi = mevcut?.tarih ?? (buAySecili ? DateTime(simdi.year, simdi.month, simdi.day) : DateTime.parse('$_secilenAyYil-01'));

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (innerContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            List<String> kategoriler = isGelir ? gelirKatListesi : giderKatListesi;
            final bool ekstreMi = !isGelir && secilenKategori == 'Kredi Kartı Ekstresi';
            final bool tekrarlanabilir = mevcut == null && secilenKategori != 'Kredi Kartı Ekstresi' && secilenKategori != 'Kredi Kartı Taksiti' && secilenKategori != 'Kredi';
            final String gecerliKategori = secilenKategori == 'Diğer (Özel)' ? ozelKategoriCtrl.text.trim() : secilenKategori;
            final String? kategoriOnerisi = (mevcut == null && tekrarlanabilir) ? _kategoriOner(baslikCtrl.text, isGelir) : null;

            // Ekstre en az o ayın taksit toplamı kadar olmalı
            final String? ekstreKartId = secilenKartId;
            final double enAzEkstre = (ekstreMi && ekstreKartId != null)
                ? _kartaAitTaksitleriGetir(ekstreKartId, _ayAnahtari(islemTarihi)).fold(0.0, (s, t) => s + t.aylikTutar)
                : 0.0;

            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
              child: Container(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _pencereBasligi(innerContext, mevcut == null ? Icons.add_circle_outline : Icons.edit, mevcut == null ? 'Yeni İşlem Ekle' : 'İşlemi Düzenle'),
                    const Divider(),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Form(
                          key: formKey,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: ChoiceChip(
                                      label: const Text('Gider'),
                                      selected: !isGelir,
                                      onSelected: (val) {
                                        setModalState(() {
                                          isGelir = false;
                                          secilenKategori = 'Kredi Kartı Ekstresi';
                                        });
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: ChoiceChip(
                                      label: const Text('Gelir'),
                                      selected: isGelir,
                                      onSelected: (val) {
                                        setModalState(() {
                                          isGelir = true;
                                          secilenKategori = 'Maaş';
                                        });
                                      },
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              DropdownButton<String>(
                                value: kategoriler.contains(secilenKategori) ? secilenKategori : 'Diğer (Özel)',
                                isExpanded: true,
                                items: kategoriler
                                    .map((kat) => DropdownMenuItem(
                                          value: kat,
                                          child: Row(
                                            children: [
                                              Icon(isGelir ? _gelirIkonu(kat) : _kategoriIkonuGetir(kat), size: 20, color: _renk(kat, gelir: isGelir)),
                                              const SizedBox(width: 8),
                                              Text(kat),
                                            ],
                                          ),
                                        ))
                                    .toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setModalState(() => secilenKategori = val);
                                  }
                                },
                              ),

                              if (!isGelir && (secilenKategori == 'Kredi Kartı Ekstresi' || secilenKategori == 'Kredi Kartı Taksiti')) ...[
                                const SizedBox(height: 10),
                                if (krediKartiListesi.isEmpty)
                                  Row(
                                    children: [
                                      const Expanded(child: Text('Henüz kredi kartı eklemedin.', style: TextStyle(color: Colors.red, fontSize: 12))),
                                      ElevatedButton.icon(
                                        style: _anaDugmeStili,
                                        onPressed: () async {
                                          await _yeniKartEkleDialogGoster();
                                          if (!context.mounted) return;
                                          setModalState(() {
                                            if (krediKartiListesi.isNotEmpty) secilenKartId = krediKartiListesi.last.id;
                                          });
                                        },
                                        icon: const Icon(Icons.add, size: 18),
                                        label: const Text('Kart Ekle'),
                                      ),
                                    ],
                                  )
                                else
                                  DropdownButton<String>(
                                    value: krediKartiListesi.any((k) => k.id == secilenKartId) ? secilenKartId : null,
                                    isExpanded: true,
                                    hint: const Text('Kredi Kartı Seçin'),
                                    items: krediKartiListesi.map((k) => DropdownMenuItem(value: k.id, child: Text('💳 ${k.kartAdi} (${_formatliSonOdemeMetni(k.sonOdemeGunu)})'))).toList(),
                                    onChanged: (val) {
                                      if (val != null) {
                                        setModalState(() => secilenKartId = val);
                                      }
                                    },
                                  ),
                              ],

                              if (!isGelir && secilenKategori == 'Kredi') ...[
                                const SizedBox(height: 10),
                                DropdownButton<String>(
                                  value: secilenKrediTuru,
                                  isExpanded: true,
                                  items: _krediTuruSecenekleri(),
                                  onChanged: (val) {
                                    if (val != null) {
                                      setModalState(() => secilenKrediTuru = val);
                                    }
                                  },
                                ),
                                const SizedBox(height: 10),
                                TextFormField(
                                  controller: krediTaksitSayisiCtrl,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                  decoration: const InputDecoration(labelText: 'Toplam Kredi Taksit Sayısı (Ay)'),
                                  validator: (val) => val == null || val.isEmpty ? 'Bu alan boş bırakılamaz' : null,
                                ),
                                _sonOdemeGunuAlani(krediSonOdemeGunuCtrl),
                                const SizedBox(height: 10),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text('Kredi Başlangıç Tarihi: ${DateFormat('dd.MM.yyyy', 'tr_TR').format(krediBaslangicTarihi)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                                    TextButton(
                                      onPressed: () async {
                                        DateTime? picked = await showDatePicker(
                                          context: context,
                                          initialDate: krediBaslangicTarihi,
                                          firstDate: enEskiTarih,
                                          lastDate: enYeniTarih,
                                        );
                                        if (!context.mounted) return;
                                        if (picked != null) {
                                          setModalState(() {
                                            krediBaslangicTarihi = picked;
                                          });
                                        }
                                      },
                                      child: const Text('Tarih Seç'),
                                    ),
                                  ],
                                ),
                              ],

                              if (secilenKategori == 'Diğer (Özel)')
                                TextFormField(
                                  controller: ozelKategoriCtrl,
                                  decoration: const InputDecoration(labelText: 'Özel Kategori Adı'),
                                  validator: (val) => secilenKategori == 'Diğer (Özel)' && (val == null || val.isEmpty) ? 'Bu alan boş bırakılamaz' : null,
                                ),

                              if (secilenKategori != 'Kredi Kartı Ekstresi' && secilenKategori != 'Kredi Kartı Taksiti') ...[
                                TextFormField(
                                  controller: baslikCtrl,
                                  onChanged: (_) => setModalState(() {}),
                                  decoration: InputDecoration(
                                    labelText: (secilenKategori == 'Kredi') ? 'Kredi Başlığı (Örn: Ev Kredisi)' : 'Başlık',
                                  ),
                                ),
                                if (kategoriOnerisi != null && kategoriOnerisi != gecerliKategori)
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: ActionChip(
                                        avatar: Icon(Icons.lightbulb_outline, size: 18, color: anaRenk),
                                        label: Text('Kategori önerisi: $kategoriOnerisi'),
                                        onPressed: () {
                                          setModalState(() {
                                            if (kategoriler.contains(kategoriOnerisi)) {
                                              secilenKategori = kategoriOnerisi;
                                            } else {
                                              secilenKategori = 'Diğer (Özel)';
                                              ozelKategoriCtrl.text = kategoriOnerisi;
                                            }
                                          });
                                        },
                                      ),
                                    ),
                                  ),
                              ],

                              TextFormField(
                                controller: tutarCtrl,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*[.,]?\d*'))],
                                decoration: InputDecoration(
                                  labelText: (secilenKategori == 'Kredi Kartı Taksiti' || secilenKategori == 'Kredi')
                                      ? 'Aylık Taksit Tutarı (₺)'
                                      : (ekstreMi ? 'Toplam Ekstre Tutarı (₺)' : (tekrarla ? 'Aylık Tutar (₺)' : 'Tutar (₺)')),
                                  helperText: enAzEkstre > 0 ? 'En az ${_tl(enAzEkstre)} (bu ayki taksitlerin toplamı)' : null,
                                ),
                                validator: (val) {
                                  if (val == null || val.isEmpty) return 'Bu alan boş bırakılamaz';
                                  if (ekstreMi && enAzEkstre > 0) {
                                    final double girilen = double.tryParse(val.replaceAll(',', '.')) ?? 0;
                                    if (girilen + 0.009 < enAzEkstre) {
                                      return 'Bu kartın bu ayki taksit toplamı ${_tl(enAzEkstre)}. Ekstre bundan düşük olamaz.';
                                    }
                                  }
                                  return null;
                                },
                              ),

                              if (!isGelir && secilenKategori == 'Kredi Kartı Taksiti') ...[
                                const SizedBox(height: 10),
                                TextFormField(
                                  controller: baslikCtrl,
                                  decoration: const InputDecoration(labelText: 'Taksitli Harcama Açıklaması (Örn: Elektronik Alet)'),
                                  validator: (val) => val == null || val.isEmpty ? 'Bu alan boş bırakılamaz' : null,
                                ),
                                TextFormField(
                                  controller: taksitSayisiCtrl,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                  decoration: const InputDecoration(labelText: 'Toplam Taksit Sayısı (Ay)'),
                                  validator: (val) => val == null || val.isEmpty ? 'Bu alan boş bırakılamaz' : null,
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text('Taksit Başlangıç Ayı: ${_ayAdi(taksitBaslangicAy)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                                    TextButton(
                                      onPressed: () async {
                                        DateTime? picked = await showDatePicker(
                                          context: context,
                                          initialDate: DateTime.parse('$taksitBaslangicAy-01'),
                                          firstDate: enEskiTarih,
                                          lastDate: enYeniTarih,
                                        );
                                        if (!context.mounted) return;
                                        if (picked != null) {
                                          setModalState(() {
                                            taksitBaslangicAy = _ayAnahtari(picked);
                                          });
                                        }
                                      },
                                      child: const Text('Ay Seç'),
                                    ),
                                  ],
                                ),
                              ],

                              // Gider için son ödeme tarihi, gelir için tarih
                              if (secilenKategori != 'Kredi Kartı Ekstresi' && secilenKategori != 'Kredi Kartı Taksiti' && secilenKategori != 'Kredi') ...[
                                const SizedBox(height: 6),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${isGelir ? 'Tarih' : 'Son Ödeme Tarihi'}: ${DateFormat('dd.MM.yyyy', 'tr_TR').format(islemTarihi)}',
                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () async {
                                        DateTime? picked = await showDatePicker(
                                          context: context,
                                          initialDate: islemTarihi,
                                          firstDate: enEskiTarih,
                                          lastDate: enYeniTarih,
                                          helpText: isGelir ? 'Tarih Seçin' : 'Son Ödeme Tarihini Seçin',
                                        );
                                        if (!context.mounted) return;
                                        if (picked != null) {
                                          setModalState(() => islemTarihi = picked);
                                        }
                                      },
                                      child: const Text('Değiştir'),
                                    ),
                                  ],
                                ),
                              ],

                              // Her ay tekrarlanan sabit ödeme / gelir
                              if (tekrarlanabilir)
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  value: tekrarla,
                                  onChanged: (v) => setModalState(() => tekrarla = v),
                                  title: Text(isGelir ? 'Her ay tekrarlanan gelir' : 'Her ay tekrarlanan ödeme', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                                  subtitle: Text(
                                    isGelir ? 'Maaş gibi. Her ay otomatik eklenir.' : 'Kira, fatura gibi. Her ay otomatik eklenir, ödenmeyen kısım sonraki aya devreder.',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  secondary: Icon(Icons.autorenew, color: anaRenk),
                                ),

                              const SizedBox(height: 20),
                              ElevatedButton(
                                style: _anaDugmeStili,
                                onPressed: () {
                                  if (formKey.currentState!.validate()) {
                                    String formatliTutar = tutarCtrl.text.replaceAll(',', '.');
                                    String katFinal = secilenKategori == 'Diğer (Özel)' ? ozelKategoriCtrl.text : secilenKategori;
                                    double tutarSayi = double.tryParse(formatliTutar) ?? 0.0;
                                    String yeniAyAnahtar = _ayAnahtari(islemTarihi);

                                    if (!ekstreMi && secilenKategori != 'Kredi Kartı Taksiti' && secilenKategori != 'Kredi' && baslikCtrl.text.trim().isNotEmpty) {
                                      _kategoriOgren(baslikCtrl.text, katFinal, isGelir);
                                    }

                                    if (ekstreMi) {
                                      String kartIdFinal = secilenKartId ?? (krediKartiListesi.isNotEmpty ? krediKartiListesi.first.id : '1');
                                      var mevcutEkstreler = finansListesi.where((i) => !i.isGelir && i.kategori == 'Kredi Kartı Ekstresi' && i.kartId == kartIdFinal && i.ayYilAnahtari == yeniAyAnahtar).toList();

                                      if (mevcut == null && mevcutEkstreler.isNotEmpty) {
                                        showDialog(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            title: const Text('Uyarı'),
                                            content: const Text('Bu karta ait bu ay zaten bir ekstre girilmiş!'),
                                            actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tamam'))],
                                          ),
                                        );
                                        return;
                                      }
                                      if (mevcut != null && mevcutEkstreler.any((i) => i.id != mevcut.id)) {
                                        showDialog(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            title: const Text('Uyarı'),
                                            content: const Text('Bu karta ait bu ay zaten başka bir ekstre var!'),
                                            actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tamam'))],
                                          ),
                                        );
                                        return;
                                      }
                                    }

                                    if (!isGelir && secilenKategori == 'Kredi Kartı Taksiti') {
                                      final String? kartIdKontrol = secilenKartId ?? (krediKartiListesi.isNotEmpty ? krediKartiListesi.first.id : null);
                                      if (kartIdKontrol != null) {
                                        final String? ekstreHatasi = _taksitEkstreHatasi(kartId: kartIdKontrol, baslangicAy: taksitBaslangicAy, toplam: int.tryParse(taksitSayisiCtrl.text) ?? 3, aylik: tutarSayi);
                                        if (ekstreHatasi != null) {
                                          showDialog(
                                            context: context,
                                            builder: (ctx) => AlertDialog(
                                              title: const Text('Taksit ekstreyi aşıyor'),
                                              content: Text(ekstreHatasi),
                                              actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tamam'))],
                                            ),
                                          );
                                          return;
                                        }
                                      }
                                    }

                                    setState(() {
                                      int yeniIdInt = DateTime.now().microsecondsSinceEpoch;

                                      if (tekrarlanabilir && tekrarla) {
                                        // Sabit ödeme olarak kaydet: aylık kayıtlar otomatik oluşur
                                        sabitListesi.add(SabitOdeme(
                                          id: 'sabit_$yeniIdInt',
                                          baslik: baslikCtrl.text.isEmpty ? katFinal : baslikCtrl.text,
                                          kategori: katFinal,
                                          isGelir: isGelir,
                                          gun: islemTarihi.day.toString(),
                                          baslangicAyYil: yeniAyAnahtar,
                                          tutarlar: {yeniAyAnahtar: tutarSayi},
                                        ));
                                        _sabitleriUret();
                                      } else if (!isGelir && secilenKategori == 'Kredi Kartı Taksiti') {
                                        int toplamAy = int.tryParse(taksitSayisiCtrl.text) ?? 3;
                                        String kartIdFinal = secilenKartId ?? (krediKartiListesi.isNotEmpty ? krediKartiListesi.first.id : '1');

                                        Map<String, bool> otomatikOdenenler = _gecmisAylariOtomatikIsaretle(DateTime.parse('$taksitBaslangicAy-01'), toplamAy);

                                        kartTaksitListesi.add(
                                          KartTaksiti(
                                            id: yeniIdInt.toString(),
                                            kartId: kartIdFinal,
                                            baslik: baslikCtrl.text,
                                            aylikTutar: tutarSayi,
                                            toplamTaksit: toplamAy,
                                            baslangicAyYil: taksitBaslangicAy,
                                            odenenAylar: otomatikOdenenler,
                                          ),
                                        );
                                      } else if (!isGelir && secilenKategori == 'Kredi') {
                                        int toplamAy = int.tryParse(krediTaksitSayisiCtrl.text) ?? 12;

                                        Map<String, bool> otomatikOdenenler = _gecmisAylariOtomatikIsaretle(krediBaslangicTarihi, toplamAy);

                                        krediListesi.add(
                                          KrediBorcu(
                                            id: yeniIdInt.toString(),
                                            krediAdi: baslikCtrl.text.isEmpty ? '$secilenKrediTuru Kredisi' : baslikCtrl.text,
                                            krediTuru: secilenKrediTuru,
                                            aylikTutar: tutarSayi,
                                            toplamTaksit: toplamAy,
                                            baslangicTarihi: krediBaslangicTarihi,
                                            sonOdemeGunu: krediSonOdemeGunuCtrl.text,
                                            odenenAylar: otomatikOdenenler,
                                          ),
                                        );
                                      } else {
                                        String finalBaslik = baslikCtrl.text;
                                        if (ekstreMi) {
                                          finalBaslik = 'ekstre';
                                        }

                                        if (mevcut == null) {
                                          finansListesi.add(
                                            FinansKalemi(
                                              id: yeniIdInt.toString(),
                                              baslik: finalBaslik,
                                              tutar: tutarSayi,
                                              kategori: katFinal,
                                              isGelir: isGelir,
                                              tarih: islemTarihi,
                                              kartId: ekstreMi ? secilenKartId : null,
                                              ayYilAnahtari: yeniAyAnahtar,
                                            ),
                                          );
                                        } else {
                                          mevcut.baslik = finalBaslik;
                                          mevcut.tutar = tutarSayi;
                                          mevcut.kategori = katFinal;
                                          mevcut.isGelir = isGelir;
                                          mevcut.tarih = islemTarihi;
                                          mevcut.ayYilAnahtari = yeniAyAnahtar;
                                          mevcut.kartId = ekstreMi ? secilenKartId : null;
                                        }
                                      }
                                    });
                                    Navigator.of(innerContext).pop();
                                  } else {
                                    _ilkHataliAlanaKaydir(formKey);
                                  }
                                },
                                child: Text(mevcut == null ? 'Kaydet' : 'Güncelle'),
                              ),
                              const SizedBox(height: 20),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ---------- Ajanda: etkinlik türü penceresi ----------

  Widget _saatBuilder(BuildContext c, Widget? child) {
    return MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: child ?? const SizedBox.shrink());
  }

  // ---------- Ajanda formu: ortak satır bileşenleri ----------

  // Dokununca seçim açan satır: üstte küçük başlık, altında seçili değer
  Widget _formSatiri({required IconData ikon, required String baslik, required String deger, VoidCallback? onTap, Color? ikonRengi}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(ikon, size: 20, color: ikonRengi ?? anaRenk),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(baslik, style: TextStyle(fontSize: 11, color: gri(600))),
                  const SizedBox(height: 2),
                  Text(deger, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: koyuYazi)),
                ],
              ),
            ),
            if (onTap != null) const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  // İçinde özel bileşen (çipler vb.) olan satır
  Widget _formIcerikSatiri({required IconData ikon, required String baslik, required Widget icerik, Color? ikonRengi}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(ikon, size: 20, color: ikonRengi ?? anaRenk)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(baslik, style: TextStyle(fontSize: 11, color: gri(600))),
                const SizedBox(height: 6),
                icerik,
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Satırları ince çizgilerle ayıran yuvarlak köşeli grup
  Widget _formGrubu(List<Widget> satirlar) {
    final List<Widget> cocuklar = [];
    for (int i = 0; i < satirlar.length; i++) {
      if (i > 0) cocuklar.add(Divider(height: 1, indent: 46, color: gri(200)));
      cocuklar.add(satirlar[i]);
    }
    return Material(
      color: yuzey,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: gri(200))),
      child: Column(children: cocuklar),
    );
  }

  Future<EtkinlikTuru?> _turDialogGoster({EtkinlikTuru? mevcut, List<EtkinlikTuru>? hedefListe, String tur = 'Etkinlik Türü', String adEtiketi = 'Tür adı', String ipucu = 'Örn: Spor, Toplantı, Aşı'}) async {
    final List<EtkinlikTuru> hedef = hedefListe ?? etkinlikTurleri;
    final adCtrl = TextEditingController(text: mevcut?.ad ?? '');
    int ikon = mevcut?.ikon ?? 4;
    int renk = mevcut?.renk ?? 4;
    String? hata;

    return showDialog<EtkinlikTuru>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (innerContext, setS) => AlertDialog(
          title: Text(mevcut == null ? 'Yeni $tur' : '$tur Düzenle'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: _pastel(ajandaRenkleri[renk]),
                        child: Icon(ajandaIkonlari[ikon], color: ajandaRenkleri[renk]),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: adCtrl,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: InputDecoration(labelText: adEtiketi, hintText: ipucu, errorText: hata),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('Renk', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: List<Widget>.generate(ajandaRenkleri.length, (i) {
                      return GestureDetector(
                        onTap: () => setS(() => renk = i),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: ajandaRenkleri[i],
                            shape: BoxShape.circle,
                            border: renk == i ? Border.all(color: koyuYazi, width: 3) : null,
                          ),
                          child: renk == i ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 16),
                  const Text('İkon', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: List<Widget>.generate(ajandaIkonlari.length, (i) {
                      final bool secili = ikon == i;
                      return GestureDetector(
                        onTap: () => setS(() => ikon = i),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: secili ? _pastel(ajandaRenkleri[renk]) : hucreZemin,
                            borderRadius: BorderRadius.circular(10),
                            border: secili ? Border.all(color: ajandaRenkleri[renk], width: 2) : null,
                          ),
                          child: Icon(ajandaIkonlari[i], size: 22, color: secili ? ajandaRenkleri[renk] : gri(600)),
                        ),
                      );
                    }),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('İptal')),
            ElevatedButton(
              style: _anaDugmeStili,
              onPressed: () {
                final String ad = adCtrl.text.trim();
                if (ad.isEmpty) {
                  setS(() => hata = 'Bir ad girin');
                  return;
                }
                final bool ayniAdVar = hedef.any((t) => t.ad.toLowerCase() == ad.toLowerCase() && t.id != mevcut?.id);
                if (ayniAdVar) {
                  setS(() => hata = 'Bu isimde bir tür zaten var');
                  return;
                }
                if (mevcut == null) {
                  final yeni = EtkinlikTuru(id: 'tur_${DateTime.now().microsecondsSinceEpoch}', ad: ad, ikon: ikon, renk: renk);
                  setState(() {
                    hedef.add(yeni);
                  });
                  Navigator.pop(dialogContext, yeni);
                } else {
                  setState(() {
                    mevcut.ad = ad;
                    mevcut.ikon = ikon;
                    mevcut.renk = renk;
                  });
                  Navigator.pop(dialogContext, mevcut);
                }
              },
              child: const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _turSecenekleriGoster(EtkinlikTuru t) async {
    final String? secim = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(t.ad),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'duzenle'),
            child: const Row(children: [Icon(Icons.edit, size: 18), SizedBox(width: 10), Text('Düzenle')]),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'sil'),
            child: const Row(children: [Icon(Icons.delete_outline, size: 18, color: Colors.red), SizedBox(width: 10), Text('Sil', style: TextStyle(color: Colors.red))]),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (secim == 'duzenle') {
      await _turDialogGoster(mevcut: t);
    } else if (secim == 'sil') {
      if (etkinlikTurleri.length <= 1) {
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Silinemez'),
            content: const Text('En az bir etkinlik türü kalmalı.'),
            actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tamam'))],
          ),
        );
        return;
      }
      final int kullanan = etkinlikListesi.where((e) => e.turId == t.id).length;
      final bool onay = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Türü Sil'),
              content: Text(
                kullanan > 0
                    ? '"${t.ad}" türünü $kullanan etkinlik kullanıyor. Silersen bu etkinlikler gri "Diğer" türüyle görünmeye devam eder. Devam edilsin mi?'
                    : '"${t.ad}" türünü silmek istediğinize emin misiniz?',
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
                ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white), onPressed: () => Navigator.pop(ctx, true), child: const Text('Sil')),
              ],
            ),
          ) ??
          false;
      if (onay && mounted) {
        setState(() {
          etkinlikTurleri.removeWhere((x) => x.id == t.id);
        });
      }
    }
  }

  Future<Hatirlatma?> _hatirlatmaDialogGoster(bool gunBoyu) async {
    final ctrl = TextEditingController(text: '2');
    String birim = gunBoyu ? 'gun' : 'saat';
    final Map<String, String> birimler = gunBoyu
        ? {'gun': 'gün önce', 'hafta': 'hafta önce'}
        : {'dakika': 'dakika önce', 'saat': 'saat önce', 'gun': 'gün önce', 'hafta': 'hafta önce'};

    return showDialog<Hatirlatma>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (innerContext, setS) => AlertDialog(
          title: const Text('Özel Hatırlatma'),
          content: Row(
            children: [
              SizedBox(
                width: 70,
                child: TextField(
                  controller: ctrl,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<String>(
                  value: birim,
                  isExpanded: true,
                  items: birimler.entries.map((e) => DropdownMenuItem<String>(value: e.key, child: Text(e.value))).toList(),
                  onChanged: (v) {
                    if (v != null) setS(() => birim = v);
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('İptal')),
            ElevatedButton(
              style: _anaDugmeStili,
              onPressed: () {
                final int n = int.tryParse(ctrl.text) ?? 0;
                if (n <= 0) return;
                Navigator.pop(dialogContext, Hatirlatma(n, birim));
              },
              child: const Text('Ekle'),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Ajanda formu: seçim pencereleri ----------

  // Etkinlik türü seçimi: liste halinde, her türün yanında düzenle/sil, altta yeni tür
  Future<String?> _turSecimiGoster(String seciliId) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (innerContext, setS) => Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(innerContext).size.height * 0.8),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _pencereBasligi(sheetContext, Icons.category_outlined, 'Etkinlik Türü'),
              const Divider(),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: etkinlikTurleri.map((t) {
                      final bool secili = t.id == seciliId;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(radius: 18, backgroundColor: _pastel(t.renkVerisi), child: Icon(t.ikonVerisi, size: 20, color: t.renkVerisi)),
                        title: Text(t.ad, style: TextStyle(fontWeight: secili ? FontWeight.bold : FontWeight.w500)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (secili) Icon(Icons.check_circle, color: anaRenk, size: 20),
                            IconButton(
                              tooltip: 'Düzenle / Sil',
                              icon: const Icon(Icons.edit_outlined, size: 18, color: Colors.grey),
                              onPressed: () async {
                                await _turSecenekleriGoster(t);
                                if (innerContext.mounted) setS(() {});
                              },
                            ),
                          ],
                        ),
                        onTap: () => Navigator.pop(sheetContext, t.id),
                      );
                    }).toList(),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final yeni = await _turDialogGoster();
                    if (yeni != null && sheetContext.mounted) Navigator.pop(sheetContext, yeni.id);
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Yeni Tür Ekle'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Basit tek seçimli liste penceresi (Tekrar, Süre için)
  Future<String?> _secenekSheetiGoster({required IconData ikon, required String baslik, required List<List<String>> ogeler, required String secili}) {
    return showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _pencereBasligi(sheetContext, ikon, baslik),
            const Divider(),
            ...ogeler.map((o) {
              final bool aktif = o[0] == secili;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(o[1], style: TextStyle(fontWeight: aktif ? FontWeight.bold : FontWeight.w500)),
                trailing: aktif ? Icon(Icons.check_circle, color: anaRenk, size: 20) : null,
                onTap: () => Navigator.pop(sheetContext, o[0]),
              );
            }),
          ],
        ),
      ),
    );
  }

  Future<String?> _sureDialogGoster(int baslangicN, String baslangicBirim) {
    final ctrl = TextEditingController(text: baslangicN.toString());
    String birim = baslangicBirim;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (innerContext, setS) => AlertDialog(
          title: const Text('Ne kadar süre devam edecek?'),
          content: Row(
            children: [
              SizedBox(
                width: 70,
                child: TextField(controller: ctrl, keyboardType: TextInputType.number, textAlign: TextAlign.center, inputFormatters: [FilteringTextInputFormatter.digitsOnly]),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<String>(
                  value: birim,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 'gun', child: Text('gün boyunca')),
                    DropdownMenuItem(value: 'hafta', child: Text('hafta boyunca')),
                    DropdownMenuItem(value: 'ay', child: Text('ay boyunca')),
                    DropdownMenuItem(value: 'yil', child: Text('yıl boyunca')),
                  ],
                  onChanged: (v) {
                    if (v != null) setS(() => birim = v);
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('İptal')),
            ElevatedButton(
              style: _anaDugmeStili,
              onPressed: () {
                final int n = int.tryParse(ctrl.text) ?? 0;
                if (n <= 0) return;
                Navigator.pop(dialogContext, '$n|$birim');
              },
              child: const Text('Tamam'),
            ),
          ],
        ),
      ),
    );
  }

  Future<int?> _aralikDialogGoster(int baslangicN) {
    final ctrl = TextEditingController(text: baslangicN.toString());
    return showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Kaç günde bir?'),
        content: Row(
          children: [
            const Text('Her '),
            SizedBox(
              width: 70,
              child: TextField(controller: ctrl, keyboardType: TextInputType.number, textAlign: TextAlign.center, inputFormatters: [FilteringTextInputFormatter.digitsOnly]),
            ),
            const Text(' günde bir'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('İptal')),
          ElevatedButton(
            style: _anaDugmeStili,
            onPressed: () {
              final int n = int.tryParse(ctrl.text) ?? 0;
              if (n < 1) return;
              Navigator.pop(dialogContext, n);
            },
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
  }

  // Hatırlatma seçimi: işaretli / işaretsiz kutular. Gün/hafta önce seçilince saatini sorar.
  // Kendi eklediğin süreler listede kalır (sonraki etkinliklerde de çıkar) ve silinebilir.
  Future<List<Hatirlatma>?> _hatirlatmaSecimiGoster(bool gunBoyu, List<Hatirlatma> baslangic) {
    final List<Hatirlatma> secili = baslangic.map((h) => h.kopya()).toList();
    final List<Hatirlatma> secenekler = gunBoyu
        ? [Hatirlatma(0, 'gun'), Hatirlatma(1, 'gun'), Hatirlatma(1, 'hafta')]
        : [Hatirlatma(0, 'dakika'), Hatirlatma(10, 'dakika'), Hatirlatma(1, 'gun'), Hatirlatma(1, 'hafta')];

    bool gunTabanli(Hatirlatma h) => h.birim == 'gun' || h.birim == 'hafta';
    bool uygun(Hatirlatma h) => gunBoyu ? gunTabanli(h) : true;

    // Kendi eklediklerin: kalıcı liste + bu etkinlikte seçili olup standart olmayanlar
    final List<Hatirlatma> ozelHavuz = [];
    final List<Hatirlatma> silinenler = [];
    void havuzaEkle(Hatirlatma h) {
      if (!uygun(h)) return;
      if (secenekler.any((s) => s.ayni(h))) return;
      if (ozelHavuz.any((o) => o.ayni(h))) return;
      ozelHavuz.add(Hatirlatma(h.deger, h.birim));
    }

    for (final h in ozelHatirlatmalar) {
      havuzaEkle(h);
    }
    for (final h in secili) {
      havuzaEkle(h);
    }

    return showModalBottomSheet<List<Hatirlatma>>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (innerContext, setS) {
          final List<Hatirlatma> tumListe = [...secenekler, ...ozelHavuz];

          // Gün/hafta önce hatırlatmalarda bildirimin çalacağı saati kullanıcıdan alır
          Future<int?> saatSor(Hatirlatma h, int baslangicDakika) async {
            final TimeOfDay? t = await showTimePicker(
              context: innerContext,
              initialTime: TimeOfDay(hour: baslangicDakika ~/ 60, minute: baslangicDakika % 60),
              helpText: '${_hatirlatmaMetni(Hatirlatma(h.deger, h.birim), gunBoyu)} saat kaçta hatırlatsın?',
              builder: _saatBuilder,
            );
            if (t == null) return null;
            return t.hour * 60 + t.minute;
          }

          return Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(innerContext).size.height * 0.85),
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _pencereBasligi(sheetContext, Icons.notifications_active_outlined, 'Ne kadar önce hatırlatsın?'),
                const Divider(),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        ...tumListe.map((h) {
                          final bool ozel = ozelHavuz.any((o) => o.ayni(h));
                          final Hatirlatma? secilen = secili.where((x) => x.ayni(h)).firstOrNull;
                          Widget? altYazi;
                          if (!ozel && gunTabanli(h) && secilen == null) {
                            altYazi = Text('Seçince bildirimin saatini soracağız', style: TextStyle(fontSize: 11, color: gri(600)));
                          }
                          final bool saatDugmesi = secilen != null && gunTabanli(h);
                          return CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            activeColor: anaRenk,
                            value: secilen != null,
                            title: Text(_hatirlatmaMetni(Hatirlatma(h.deger, h.birim), gunBoyu)),
                            subtitle: altYazi,
                            secondary: (saatDugmesi || ozel)
                                ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (saatDugmesi)
                                        OutlinedButton.icon(
                                          style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                                          onPressed: () async {
                                            final int? dk = await saatSor(h, secilen.gunSaati ?? 540);
                                            if (dk == null || !innerContext.mounted) return;
                                            setS(() => secilen.gunSaati = dk);
                                          },
                                          icon: const Icon(Icons.schedule, size: 16),
                                          label: Text(secilen.saatMetni),
                                        ),
                                      if (ozel)
                                        IconButton(
                                          tooltip: 'Bu süreyi sil',
                                          icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                                          onPressed: () => setS(() {
                                            secili.removeWhere((x) => x.ayni(h));
                                            ozelHavuz.removeWhere((x) => x.ayni(h));
                                            silinenler.add(Hatirlatma(h.deger, h.birim));
                                          }),
                                        ),
                                    ],
                                  )
                                : null,
                            onChanged: (v) async {
                              if (v == true) {
                                if (gunTabanli(h)) {
                                  final int? dk = await saatSor(h, 540);
                                  if (dk == null || !innerContext.mounted) return;
                                  setS(() {
                                    if (!secili.any((x) => x.ayni(h))) secili.add(Hatirlatma(h.deger, h.birim, gunSaati: dk));
                                  });
                                } else {
                                  setS(() {
                                    if (!secili.any((x) => x.ayni(h))) secili.add(Hatirlatma(h.deger, h.birim));
                                  });
                                }
                              } else {
                                setS(() => secili.removeWhere((x) => x.ayni(h)));
                              }
                            },
                          );
                        }),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.add_circle_outline, color: anaRenk),
                          title: Text('Özel süre ekle', style: TextStyle(color: anaRenk, fontWeight: FontWeight.bold)),
                          onTap: () async {
                            final Hatirlatma? yeni = await _hatirlatmaDialogGoster(gunBoyu);
                            if (yeni == null || !innerContext.mounted) return;
                            int? dk;
                            if (gunTabanli(yeni)) {
                              dk = await saatSor(yeni, 540);
                              if (dk == null || !innerContext.mounted) return;
                            }
                            setS(() {
                              silinenler.removeWhere((x) => x.ayni(yeni));
                              if (!tumListe.any((x) => x.ayni(yeni))) ozelHavuz.add(Hatirlatma(yeni.deger, yeni.birim));
                              if (!secili.any((x) => x.ayni(yeni))) secili.add(Hatirlatma(yeni.deger, yeni.birim, gunSaati: dk));
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: _anaDugmeStili,
                    onPressed: () {
                      // Kendi eklediğin süreler kalıcı olarak saklanır; silinenler listeden kalkar
                      final List<Hatirlatma> kalici = ozelHatirlatmalar.where((h) => !silinenler.any((s) => s.ayni(h))).map((h) => Hatirlatma(h.deger, h.birim)).toList();
                      for (final h in ozelHavuz) {
                        if (!kalici.any((k) => k.ayni(h))) kalici.add(Hatirlatma(h.deger, h.birim));
                      }
                      setState(() => ozelHatirlatmalar = kalici);
                      Navigator.pop(sheetContext, secili);
                    },
                    child: const Text('Tamam'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ---------- Ajanda: etkinlik ekleme / düzenleme ----------

  // Form doğrulaması başarısız olunca ilk hatalı alanı ekranda gösterir
  void _ilkHataliAlanaKaydir(GlobalKey<FormState> formAnahtari) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? kok = formAnahtari.currentContext;
      if (kok == null || !kok.mounted) return;
      Element? bulunan;
      void gez(Element e) {
        if (bulunan != null) return;
        if (e is StatefulElement) {
          final State st = e.state;
          if (st is FormFieldState && st.hasError) {
            bulunan = e;
            return;
          }
        }
        e.visitChildren(gez);
      }
      kok.visitChildElements(gez);
      final Element? hedef = bulunan;
      if (hedef != null && hedef.mounted) {
        Scrollable.ensureVisible(hedef, alignment: 0.3, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  // Hatalı alanı ekranda gösterir (kaydırılabilir formlarda eksik alan görünmeden kalmasın)
  void _hataliAlaniGoster(GlobalKey anahtar) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? c = anahtar.currentContext;
      if (c != null && c.mounted) {
        Scrollable.ensureVisible(c, alignment: 0.3, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  Widget _hizliEkleDugmesi() {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: _hizliEkleGoster,
      child: Container(
        decoration: BoxDecoration(color: griDugme, shape: BoxShape.circle),
        padding: const EdgeInsets.all(8),
        child: Icon(Icons.bolt, size: 18, color: ikonGri),
      ),
    );
  }

  String _hizliOzetMetni(HizliCozum c) {
    final DateTime t = c.tarih ?? DateTime.now();
    final String gun = DateFormat('EEEE, d MMMM', 'tr_TR').format(t);
    final List<String> p = [gun];
    p.add(c.dakika == null ? 'Tüm gün' : _saatMetniDk(c.dakika!));
    switch (c.tekrar) {
      case 'gun':
        p.add('Her gün');
        break;
      case 'hafta':
        p.add('Her hafta');
        break;
      case 'ay':
        p.add('Her ay');
        break;
      case 'yil':
        p.add('Her yıl');
        break;
    }
    return p.join(' • ');
  }

  // Tek cümleyle etkinlik: önce anlaşılan kısım gösterilir, sonra etkinlik penceresi dolu açılır
  Future<void> _hizliEkleGoster() async {
    final ctrl = TextEditingController();
    final SesliYazi ses = SesliYazi();

    final HizliCozum? sonuc = await showModalBottomSheet<HizliCozum>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final String metin = ctrl.text.trim();
          final HizliCozum? c = metin.isEmpty ? null : hizliCoz(metin, DateTime.now());
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _pencereBasligi(ctx, Icons.bolt, 'Hızlı Ekle'),
                    const Divider(),
                    TextField(
                      controller: ctrl,
                      autofocus: true,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.done,
                      onChanged: (_) => setS(() {}),
                      onSubmitted: (_) {
                        if (c != null) Navigator.pop(ctx, c);
                      },
                      decoration: InputDecoration(
                        hintText: ses.dinliyor ? 'Dinliyorum… konuşabilirsin' : 'Örn: yarın 15:00 diş randevusu',
                        suffixIcon: ses.dugme(ctrl, () {
                          if (ctx.mounted) setS(() {});
                        }),
                      ),
                    ),
                    if (ses.hata != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(ses.hata!, style: const TextStyle(fontSize: 12, color: Colors.red)),
                      ),
                    const SizedBox(height: 12),
                    if (c == null)
                      Text(
                        'Tarihi, saati ve başlığı tek cümlede yaz.\nÖrnekler: cuma 18:30 maç • her pazartesi 09:00 toplantı • 15 ekim doğum günü • 2 saat sonra ilaç • haftaya salı akşam 8 yemek',
                        style: TextStyle(fontSize: 12, color: gri(600), height: 1.4),
                      )
                    else
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: acikZemin, borderRadius: BorderRadius.circular(12)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.baslik.isEmpty ? 'Başlık yok (pencerede yazabilirsin)' : c.baslik, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: koyuYazi)),
                            const SizedBox(height: 4),
                            Text(_hizliOzetMetni(c), style: TextStyle(fontSize: 13, color: gri(700))),
                          ],
                        ),
                      ),
                    const SizedBox(height: 14),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ElevatedButton.icon(
                        style: _anaDugmeStili,
                        onPressed: c == null ? null : () => Navigator.pop(ctx, c),
                        icon: const Icon(Icons.arrow_forward, size: 18),
                        label: const Text('Devam'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    await ses.kapat();
    ctrl.dispose();
    if (sonuc == null || !mounted) return;
    final DateTime gun = sonuc.tarih ?? DateTime.now();
    final bool saatli = sonuc.dakika != null;
    String tur = sonuc.turIpucu;
    if (!etkinlikTurleri.any((t) => t.id == tur)) {
      tur = etkinlikTurleri.any((t) => t.id == 'gorev') ? 'gorev' : (etkinlikTurleri.isNotEmpty ? etkinlikTurleri.first.id : 'gorev');
    }
    String tekrar = sonuc.tekrar;
    if (tekrar == 'yok' && sonuc.turIpucu == 'dogum') tekrar = 'yil';
    final Etkinlik taslak = Etkinlik(
      id: 'etk_${DateTime.now().microsecondsSinceEpoch}',
      baslik: sonuc.baslik,
      turId: tur,
      baslangic: DateTime(gun.year, gun.month, gun.day),
      tumGun: !saatli,
      zamanlar: saatli ? [ZamanDilimi(saat: sonuc.dakika! ~/ 60, dakika: sonuc.dakika! % 60)] : <ZamanDilimi>[],
      tekrar: tekrar,
      haftaGunleri: tekrar == 'hafta' ? (sonuc.haftaGunleri.isEmpty ? [gun.weekday] : sonuc.haftaGunleri) : <int>[],
      hatirlatmalar: sonuc.hatirlatma != null ? [sonuc.hatirlatma!] : (saatli ? [Hatirlatma(10, 'dakika')] : [Hatirlatma(0, 'gun', gunSaati: 540)]),
    );
    await _etkinlikDialogGoster(taslak: taslak);
  }

  Future<void> _etkinlikDialogGoster({Etkinlik? mevcut, DateTime? varsayilanGun, Etkinlik? taslak}) async {
    final Object jeton = Object();
    if (mevcut == null) {
      _acikEditorTuru = 'etkinlik';
      _editorBosMu = null;
      _editorJetonu = jeton;
    }
    try {
      await _etkinlikDialogGosterIc(mevcut: mevcut, varsayilanGun: varsayilanGun, taslak: taslak);
    } finally {
      if (identical(_editorJetonu, jeton)) {
        _acikEditorTuru = null;
        _editorBosMu = null;
        _editorJetonu = null;
      }
    }
  }

  Future<void> _etkinlikDialogGosterIc({Etkinlik? mevcut, DateTime? varsayilanGun, Etkinlik? taslak}) async {
    if (mevcut != null && mevcut.id.startsWith('not_')) {
      final NotKaydi? not = _etkinlikNotu(mevcut);
      if (not != null) await _notDuzenle(mevcut: not);
      return;
    }
    final formKey = GlobalKey<FormState>();
    final zamanHataAnahtar = GlobalKey();
    final sureHataAnahtar = GlobalKey();
    final Etkinlik? kaynak = mevcut ?? taslak;
    final adCtrl = TextEditingController(text: kaynak?.baslik ?? '');
    final notCtrl = TextEditingController(text: kaynak?.notlar ?? '');
    final String yeniId = mevcut?.id ?? 'etk_${DateTime.now().microsecondsSinceEpoch}';
    if (mevcut == null) _editorBosMu = () => adCtrl.text.trim().isEmpty && notCtrl.text.trim().isEmpty;

    final DateTime simdi = DateTime.now();
    String turId = kaynak?.turId ?? (etkinlikTurleri.any((t) => t.id == 'gorev') ? 'gorev' : (etkinlikTurleri.isNotEmpty ? etkinlikTurleri.first.id : 'gorev'));
    DateTime baslangic = kaynak?.baslangic ?? (varsayilanGun ?? DateTime(simdi.year, simdi.month, simdi.day));
    bool tumGun = kaynak?.tumGun ?? false;
    List<ZamanDilimi> zamanlar = kaynak != null ? kaynak.zamanlar.map((z) => z.kopya()).toList() : <ZamanDilimi>[];
    String tekrar = kaynak?.tekrar ?? 'yok';
    int aralik = kaynak?.aralik ?? 1;
    List<int> haftaGunleri = List<int>.from(kaynak?.haftaGunleri ?? <int>[]);
    String sureModu = kaynak?.bitis != null ? 'tarih' : 'suresiz';
    DateTime? bitis = kaynak?.bitis;
    int sureSayisi = 7;
    String sureBirimi = 'gun';
    List<Hatirlatma> hatirlatmalar = kaynak != null ? kaynak.hatirlatmalar.map((h) => h.kopya()).toList() : [Hatirlatma(10, 'dakika')];
    int gunSaati = kaynak?.hatirlatmaGunSaati ?? 540;
    String? zamanHatasi;
    String? sureHatasi;

    // Fotoğraflar: bu oturumda eklenenler kaydedilmeden çıkılırsa silinir, kaldırılanlar kaydedilince silinir
    final List<String> fotolar = List<String>.from(mevcut?.fotolar ?? <String>[]);
    final List<String> yeniFotolar = [];
    final List<String> silinenFotolar = [];
    bool kaydedildi = false;

    // Eski kayıtlarda saati olmayan gün/hafta hatırlatmalarına mevcut davranışı görünür saat olarak yaz
    for (final h in hatirlatmalar) {
      if ((h.birim == 'gun' || h.birim == 'hafta') && h.gunSaati == null) {
        h.gunSaati = tumGun ? gunSaati : (zamanlar.isNotEmpty ? zamanlar.first.gundekiDakika : gunSaati);
      }
    }

    // Türe göre akıllı başlangıç değerleri (sadece yeni etkinlikte)
    void turVarsayilaniUygula(String id) {
      switch (id) {
        case 'ilac':
          tumGun = false;
          zamanlar = <ZamanDilimi>[];
          tekrar = 'gun';
          aralik = 1;
          hatirlatmalar = [Hatirlatma(10, 'dakika')];
          break;
        case 'dogum':
          tumGun = true;
          tekrar = 'yil';
          hatirlatmalar = [Hatirlatma(0, 'gun', gunSaati: 540), Hatirlatma(1, 'gun', gunSaati: 540)];
          break;
        case 'randevu':
          tumGun = false;
          zamanlar = <ZamanDilimi>[];
          tekrar = 'yok';
          hatirlatmalar = [Hatirlatma(10, 'dakika'), Hatirlatma(1, 'gun', gunSaati: 540)];
          break;
        case 'gorev':
          tumGun = false;
          zamanlar = <ZamanDilimi>[];
          tekrar = 'yok';
          hatirlatmalar = [Hatirlatma(10, 'dakika')];
          break;
        default:
          break;
      }
    }

    if (mevcut == null && taslak == null) turVarsayilaniUygula(turId);

    // Tüm gün / saatli geçişinde uygun olmayan hatırlatmaları çıkarır (saatleri korunur)
    List<Hatirlatma> hatirlatmalariUyarla(List<Hatirlatma> liste, bool gunBoyu) {
      final List<Hatirlatma> sonuc = [];
      for (final h in liste) {
        final bool gunTabanli = h.birim == 'gun' || h.birim == 'hafta';
        if (gunBoyu && !gunTabanli) continue;
        if (!sonuc.any((x) => x.ayni(h))) sonuc.add(h.kopya());
      }
      return sonuc;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (innerContext) => StatefulBuilder(
        builder: (sheetContext, setModalState) {
          final EtkinlikTuru secilenTur = _turBul(turId);
          final Color turRenk = secilenTur.renkVerisi;
          const gunAdlari = ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz'];
          const birimAdlari = {'gun': 'gün', 'hafta': 'hafta', 'ay': 'ay', 'yil': 'yıl'};

          DateTime? bitisHesapla() {
            if (tekrar == 'yok' || sureModu == 'suresiz') return null;
            if (sureModu == 'tarih') return bitis;
            final DateTime b = DateTime(baslangic.year, baslangic.month, baslangic.day);
            if (sureBirimi == 'hafta') return DateTime(b.year, b.month, b.day + sureSayisi * 7 - 1);
            if (sureBirimi == 'ay') return DateTime(b.year, b.month + sureSayisi, b.day - 1);
            if (sureBirimi == 'yil') return DateTime(b.year + sureSayisi, b.month, b.day - 1);
            return DateTime(b.year, b.month, b.day + sureSayisi - 1);
          }

          // Tekrarın ikinci günü: bitiş bundan önce olursa tekrar hiç gerçekleşmez
          DateTime? ikinciTekrar() {
            if (tekrar == 'yok') return null;
            final DateTime b = DateTime(baslangic.year, baslangic.month, baslangic.day);
            final Etkinlik gecici = Etkinlik(id: 'gecici', baslik: '', turId: turId, baslangic: b, tumGun: true, tekrar: tekrar, aralik: math.max(1, aralik), haftaGunleri: List<int>.from(haftaGunleri));
            final int sinir = math.min(4000, 400 * math.max(1, aralik));
            for (int i = 1; i <= sinir; i++) {
              final DateTime d = DateTime(b.year, b.month, b.day + i);
              if (_etkinlikGunuMu(gecici, d)) return d;
            }
            return null;
          }

          String? sureTutarsizligi() {
            if (tekrar == 'yok' || sureModu == 'suresiz') return null;
            final DateTime? son = bitisHesapla();
            final DateTime? ikinci = ikinciTekrar();
            if (son == null || ikinci == null) return null;
            if (!son.isBefore(ikinci)) return null;
            return 'Tekrar ayarıyla süre uyuşmuyor: ilk tekrar ${DateFormat('d MMMM yyyy', 'tr_TR').format(ikinci)} günü olur, bitiş ise ${DateFormat('d MMMM yyyy', 'tr_TR').format(son)}. Süreyi uzat ya da "Süresiz" seç.';
          }

          void sureyiUyumluYap() {
            if (sureTutarsizligi() != null) {
              setModalState(() {
                sureModu = 'suresiz';
                sureHatasi = 'Önceki süre yeni tekrara uymadığı için "Süresiz" yapıldı. İstersen yeniden seç.';
              });
            }
          }

          Etkinlik taslak() {
            return Etkinlik(
              id: yeniId,
              baslik: adCtrl.text.trim(),
              turId: turId,
              notlar: notCtrl.text.trim(),
              baslangic: DateTime(baslangic.year, baslangic.month, baslangic.day),
              tumGun: tumGun,
              zamanlar: zamanlar.map((z) => z.kopya()).toList(),
              tekrar: tekrar,
              aralik: math.max(1, aralik),
              haftaGunleri: List<int>.from(haftaGunleri),
              bitis: bitisHesapla(),
              hatirlatmalar: hatirlatmalar.map((h) => h.kopya()).toList(),
              hatirlatmaGunSaati: gunSaati,
              yapilanlar: List<String>.from(mevcut?.yapilanlar ?? <String>[]),
              fotolar: List<String>.from(fotolar),
            );
          }

          final DateTime? hesaplananBitis = bitisHesapla();
          final String? sureUyarisi = sureTutarsizligi();
          final bool saatYok = !tumGun && zamanlar.isEmpty;
          final DateTime? sonrakiHatirlatma = saatYok ? null : _siradakiHatirlatma(taslak());

          String tekrarOzeti() {
            switch (tekrar) {
              case 'gun':
                return aralik <= 1 ? 'Her gün' : 'Her $aralik günde bir';
              case 'hafta':
                return 'Haftanın belirli günleri';
              case 'ay':
                return 'Her ayın ${baslangic.day}. günü';
              case 'yil':
                return 'Her yıl ${DateFormat('d MMMM', 'tr_TR').format(baslangic)}';
              default:
                return 'Tekrarlanmaz';
            }
          }

          String sureOzeti() {
            switch (sureModu) {
              case 'sayi':
                final String son = hesaplananBitis == null ? '' : ' • Son gün: ${DateFormat('d MMM yyyy', 'tr_TR').format(hesaplananBitis)}';
                return '$sureSayisi ${birimAdlari[sureBirimi]} boyunca$son';
              case 'tarih':
                final DateTime? b = bitis;
                return b == null ? 'Tarih seçilmedi' : '${DateFormat('d MMMM yyyy', 'tr_TR').format(b)} tarihine kadar';
              default:
                return 'Süresiz';
            }
          }

          void fotoKaldir(String ad) {
            setModalState(() {
              fotolar.remove(ad);
              if (yeniFotolar.contains(ad)) {
                yeniFotolar.remove(ad);
                _fotoSil(ad);
              } else {
                silinenFotolar.add(ad);
              }
            });
          }

          // Saat ekleme: türe özel kısayol yoksa doğrudan saat seçici açılır
          Future<void> ozelSaatEkle() async {
            final TimeOfDay? t = await showTimePicker(
              context: sheetContext,
              initialTime: const TimeOfDay(hour: 9, minute: 0),
              helpText: 'Saat kaçta?',
              builder: _saatBuilder,
            );
            if (!sheetContext.mounted) return;
            if (t != null) {
              setModalState(() {
                zamanlar.add(ZamanDilimi(saat: t.hour, dakika: t.minute));
                zamanlar.sort((a, b) => a.gundekiDakika.compareTo(b.gundekiDakika));
                zamanHatasi = null;
              });
            }
          }

          final Widget saatEkleKutusu = Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(color: acikZemin, borderRadius: BorderRadius.circular(20)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 16, color: anaRenk),
                SizedBox(width: 4),
                Text('Saat ekle', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: anaRenk)),
              ],
            ),
          );

          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
            child: Container(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.92),
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _pencereBasligi(innerContext, secilenTur.ikonVerisi, mevcut == null ? 'Yeni Etkinlik' : 'Etkinliği Düzenle'),
                  const Divider(),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Form(
                        key: formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // ---- Ad ----
                            TextFormField(
                              controller: adCtrl,
                              textCapitalization: TextCapitalization.sentences,
                              decoration: InputDecoration(
                                labelText: 'Ad / Başlık',
                                hintText: turId == 'ilac' ? 'Örn: Metformin 850 mg' : (turId == 'dogum' ? 'Örn: Ayşe\'nin doğum günü' : 'Örn: Kardiyoloji kontrolü'),
                              ),
                              validator: (val) => val == null || val.trim().isEmpty ? 'Bu alan boş bırakılamaz' : null,
                            ),
                            const SizedBox(height: 14),

                            // ---- Tür, tarih, saat ----
                            _formGrubu([
                              _formSatiri(
                                ikon: secilenTur.ikonVerisi,
                                ikonRengi: turRenk,
                                baslik: 'Tür',
                                deger: secilenTur.ad,
                                onTap: () async {
                                  final String? secim = await _turSecimiGoster(turId);
                                  if (!sheetContext.mounted) return;
                                  setModalState(() {
                                    if (secim != null) {
                                      turId = secim;
                                      if (mevcut == null) turVarsayilaniUygula(secim);
                                      // Yeni türe uymayan öğün adlarını kaldır, saatleri koru
                                      final Map<String, List<int>> izinli = _turZamanlari(secim);
                                      for (final z in zamanlar) {
                                        if (z.etiket.isNotEmpty && !izinli.containsKey(z.etiket)) z.etiket = '';
                                      }
                                    } else if (!etkinlikTurleri.any((x) => x.id == turId) && etkinlikTurleri.isNotEmpty) {
                                      turId = etkinlikTurleri.first.id;
                                    }
                                  });
                                },
                              ),
                              _formSatiri(
                                ikon: Icons.event,
                                baslik: 'Tarih',
                                deger: DateFormat('d MMMM yyyy, EEEE', 'tr_TR').format(baslangic),
                                onTap: () async {
                                  final DateTime? secilen = await showDatePicker(
                                    context: sheetContext,
                                    initialDate: baslangic,
                                    firstDate: enEskiTarih,
                                    lastDate: enYeniTarih,
                                  );
                                  if (!sheetContext.mounted) return;
                                  if (secilen != null) setModalState(() => baslangic = secilen);
                                },
                              ),
                              SwitchListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                                secondary: Icon(Icons.wb_sunny_outlined, color: anaRenk, size: 20),
                                title: const Text('Tüm gün', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                                value: tumGun,
                                onChanged: (v) => setModalState(() {
                                  tumGun = v;
                                  hatirlatmalar = hatirlatmalariUyarla(hatirlatmalar, v);
                                }),
                              ),
                              if (!tumGun)
                                _formIcerikSatiri(
                                  ikon: Icons.access_time,
                                  baslik: 'Saat',
                                  icerik: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 6,
                                        crossAxisAlignment: WrapCrossAlignment.center,
                                        children: [
                                          ...zamanlar.asMap().entries.map((en) {
                                            final int i = en.key;
                                            final ZamanDilimi z = en.value;
                                            return InputChip(
                                              avatar: Icon(Icons.schedule, size: 16, color: turRenk),
                                              label: Text(z.etiket.isEmpty ? z.saatMetni : '${z.etiket} ${z.saatMetni}'),
                                              onPressed: () async {
                                                final TimeOfDay? t = await showTimePicker(
                                                  context: sheetContext,
                                                  initialTime: TimeOfDay(hour: z.saat, minute: z.dakika),
                                                  builder: _saatBuilder,
                                                );
                                                if (!sheetContext.mounted) return;
                                                if (t != null) {
                                                  setModalState(() {
                                                    z.saat = t.hour;
                                                    z.dakika = t.minute;
                                                    zamanlar.sort((a, b) => a.gundekiDakika.compareTo(b.gundekiDakika));
                                                  });
                                                }
                                              },
                                              onDeleted: () => setModalState(() => zamanlar.removeAt(i)),
                                            );
                                          }),
                                          if (_turZamanlari(turId).isEmpty)
                                            InkWell(
                                              borderRadius: BorderRadius.circular(20),
                                              onTap: ozelSaatEkle,
                                              child: saatEkleKutusu,
                                            )
                                          else
                                            PopupMenuButton<String>(
                                              tooltip: 'Saat ekle',
                                              onSelected: (v) async {
                                                if (v == '_ozel') {
                                                  await ozelSaatEkle();
                                                  return;
                                                }
                                                // Öğün/zaman zaten ekliyse kaldır
                                                if (zamanlar.any((z) => z.etiket == v)) {
                                                  setModalState(() => zamanlar.removeWhere((z) => z.etiket == v));
                                                  return;
                                                }
                                                // Değilse saatini sor (otomatik saat atanmaz)
                                                final List<int> onerilen = _turZamanlari(turId)[v] ?? const [9, 0];
                                                final TimeOfDay? t = await showTimePicker(
                                                  context: sheetContext,
                                                  initialTime: TimeOfDay(hour: onerilen[0], minute: onerilen[1]),
                                                  helpText: '$v saati kaçta?',
                                                  builder: _saatBuilder,
                                                );
                                                if (!sheetContext.mounted) return;
                                                if (t != null) {
                                                  setModalState(() {
                                                    zamanlar.add(ZamanDilimi(etiket: v, saat: t.hour, dakika: t.minute));
                                                    zamanlar.sort((a, b) => a.gundekiDakika.compareTo(b.gundekiDakika));
                                                    zamanHatasi = null;
                                                  });
                                                }
                                              },
                                              itemBuilder: (menuContext) => <PopupMenuEntry<String>>[
                                                ..._turZamanlari(turId).keys.map((etiket) {
                                                  return CheckedPopupMenuItem<String>(
                                                    value: etiket,
                                                    checked: zamanlar.any((z) => z.etiket == etiket),
                                                    child: Text(etiket),
                                                  );
                                                }),
                                                const PopupMenuDivider(),
                                                const PopupMenuItem<String>(
                                                  value: '_ozel',
                                                  child: Row(children: [Icon(Icons.more_time, size: 18), SizedBox(width: 8), Text('Özel saat')]),
                                                ),
                                              ],
                                              child: saatEkleKutusu,
                                            ),
                                        ],
                                      ),
                                      if (zamanlar.isNotEmpty)
                                        Padding(padding: const EdgeInsets.only(top: 6), child: Text('Saati değiştirmek için üzerine dokun', style: TextStyle(fontSize: 11, color: gri(600)))),
                                      if (zamanHatasi != null)
                                        Padding(key: zamanHataAnahtar, padding: const EdgeInsets.only(top: 6), child: Text(zamanHatasi!, style: const TextStyle(color: Colors.red, fontSize: 12))),
                                    ],
                                  ),
                                ),
                            ]),
                            const SizedBox(height: 14),

                            // ---- Tekrar ve süre ----
                            _formGrubu([
                              _formSatiri(
                                ikon: Icons.repeat,
                                baslik: 'Tekrar',
                                deger: tekrarOzeti(),
                                onTap: () async {
                                  final String? secim = await _secenekSheetiGoster(
                                    ikon: Icons.repeat,
                                    baslik: 'Tekrar',
                                    secili: (tekrar == 'gun' && aralik > 1) ? 'gunN' : tekrar,
                                    ogeler: const [
                                      ['yok', 'Tekrarlanmaz'],
                                      ['gun', 'Her gün'],
                                      ['gunN', 'Birkaç günde bir…'],
                                      ['hafta', 'Haftanın belirli günleri'],
                                      ['ay', 'Her ay'],
                                      ['yil', 'Her yıl'],
                                    ],
                                  );
                                  if (!sheetContext.mounted || secim == null) return;
                                  if (secim == 'gunN') {
                                    final int? n = await _aralikDialogGoster(aralik > 1 ? aralik : 2);
                                    if (!sheetContext.mounted || n == null) return;
                                    setModalState(() {
                                      tekrar = 'gun';
                                      aralik = n;
                                    });
                                    sureyiUyumluYap();
                                    return;
                                  }
                                  setModalState(() {
                                    tekrar = secim;
                                    if (secim == 'gun') aralik = 1;
                                    if (secim == 'hafta' && haftaGunleri.isEmpty) haftaGunleri = [baslangic.weekday];
                                    if (secim == 'yok') {
                                      sureModu = 'suresiz';
                                      sureHatasi = null;
                                    }
                                  });
                                  sureyiUyumluYap();
                                },
                              ),
                              if (tekrar == 'hafta')
                                _formIcerikSatiri(
                                  ikon: Icons.date_range,
                                  baslik: 'Hangi günler?',
                                  icerik: Wrap(
                                    spacing: 6,
                                    children: List<Widget>.generate(7, (i) {
                                      return FilterChip(
                                        label: Text(gunAdlari[i]),
                                        selected: haftaGunleri.contains(i + 1),
                                        onSelected: (v) => setModalState(() {
                                          if (v) {
                                            haftaGunleri.add(i + 1);
                                          } else if (haftaGunleri.length > 1) {
                                            haftaGunleri.remove(i + 1);
                                          }
                                        }),
                                      );
                                    }),
                                  ),
                                ),
                              if (tekrar != 'yok')
                                _formSatiri(
                                  ikon: Icons.timelapse,
                                  baslik: 'Ne kadar süre devam edecek?',
                                  deger: sureOzeti(),
                                  onTap: () async {
                                    final String? secim = await _secenekSheetiGoster(
                                      ikon: Icons.timelapse,
                                      baslik: 'Ne kadar süre devam edecek?',
                                      secili: sureModu,
                                      ogeler: const [
                                        ['suresiz', 'Süresiz'],
                                        ['sayi', 'Belirli bir süre boyunca'],
                                        ['tarih', 'Bir tarihe kadar'],
                                      ],
                                    );
                                    if (!sheetContext.mounted || secim == null) return;
                                    if (secim == 'suresiz') {
                                      setModalState(() {
                                        sureModu = 'suresiz';
                                        sureHatasi = null;
                                      });
                                    } else if (secim == 'sayi') {
                                      final String? sonuc = await _sureDialogGoster(sureSayisi, sureBirimi);
                                      if (!sheetContext.mounted || sonuc == null) return;
                                      final List<String> parca = sonuc.split('|');
                                      final String eskiModu = sureModu;
                                      final int eskiSayi = sureSayisi;
                                      final String eskiBirim = sureBirimi;
                                      setModalState(() {
                                        sureModu = 'sayi';
                                        sureSayisi = int.tryParse(parca[0]) ?? 7;
                                        sureBirimi = parca.length > 1 ? parca[1] : 'gun';
                                        sureHatasi = null;
                                      });
                                      // Tekrara uymayan süre kabul edilmez
                                      final String? uyumsuz = sureTutarsizligi();
                                      if (uyumsuz != null) {
                                        setModalState(() {
                                          sureModu = eskiModu;
                                          sureSayisi = eskiSayi;
                                          sureBirimi = eskiBirim;
                                          sureHatasi = uyumsuz;
                                        });
                                      }
                                    } else if (secim == 'tarih') {
                                      // İlk tekrardan önceki tarihler seçilemez
                                      final DateTime? ikinci = ikinciTekrar();
                                      final DateTime ilkSecilebilir = ikinci ?? enEskiTarih;
                                      DateTime baslangicTarihi = bitis ?? DateTime(baslangic.year, baslangic.month, baslangic.day + 30);
                                      if (baslangicTarihi.isBefore(ilkSecilebilir)) baslangicTarihi = ilkSecilebilir;
                                      final DateTime? secilen = await showDatePicker(
                                        context: sheetContext,
                                        initialDate: baslangicTarihi,
                                        firstDate: ilkSecilebilir,
                                        lastDate: enYeniTarih.isBefore(ilkSecilebilir) ? ilkSecilebilir : enYeniTarih,
                                        helpText: 'Bitiş tarihini seçin',
                                      );
                                      if (!sheetContext.mounted || secilen == null) return;
                                      setModalState(() {
                                        sureModu = 'tarih';
                                        bitis = secilen;
                                        sureHatasi = null;
                                      });
                                    }
                                  },
                                ),
                            ]),
                            if (sureHatasi != null)
                              Padding(key: sureHataAnahtar, padding: const EdgeInsets.only(top: 6, left: 4), child: Text(sureHatasi!, style: const TextStyle(color: Colors.red, fontSize: 12)))
                            else if (sureUyarisi != null)
                              Padding(key: sureHataAnahtar, padding: const EdgeInsets.only(top: 6, left: 4), child: Text(sureUyarisi, style: const TextStyle(color: Colors.red, fontSize: 12))),
                            const SizedBox(height: 14),

                            // ---- Hatırlatma ----
                            _formGrubu([
                              _formSatiri(
                                ikon: Icons.notifications_active_outlined,
                                baslik: 'Hatırlatma',
                                deger: hatirlatmalar.isEmpty ? 'Hatırlatma yok' : hatirlatmalar.map((h) => _hatirlatmaMetni(h, tumGun)).join(', '),
                                onTap: () async {
                                  final List<Hatirlatma>? sonuc = await _hatirlatmaSecimiGoster(tumGun, hatirlatmalar);
                                  if (!sheetContext.mounted) return;
                                  if (sonuc != null) setModalState(() => hatirlatmalar = sonuc);
                                },
                              ),
                            ]),
                            if (hatirlatmalar.isNotEmpty)
                              Container(
                                width: double.infinity,
                                margin: const EdgeInsets.only(top: 8),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(color: acikZemin, borderRadius: BorderRadius.circular(10)),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      saatYok
                                          ? 'İlk hatırlatma zamanı, saat eklediğinde burada görünecek.'
                                          : (sonrakiHatirlatma != null
                                              ? 'İlk hatırlatma: ${DateFormat('d MMMM yyyy, HH:mm', 'tr_TR').format(sonrakiHatirlatma)}'
                                              : 'Gelecekte çalacak bir hatırlatma yok (tamamlananlar sayılmaz).'),
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: koyuYazi),
                                    ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 14),

                            // ---- Not ----
                            TextFormField(
                              controller: notCtrl,
                              maxLines: 3,
                              minLines: 2,
                              textCapitalization: TextCapitalization.sentences,
                              decoration: const InputDecoration(
                                labelText: 'Not / İçerik',
                                hintText: 'İstediğin her şeyi yazabilirsin (doz, aç/tok, adres, doktor adı…)',
                                alignLabelWithHint: true,
                              ),
                            ),
                            const SizedBox(height: 14),
                            _formGrubu([
                              _formIcerikSatiri(
                                ikon: Icons.photo_library_outlined,
                                baslik: 'Fotoğraflar',
                                icerik: Wrap(
                                  spacing: 12,
                                  runSpacing: 12,
                                  children: [
                                    for (int i = 0; i < fotolar.length; i++)
                                      _fotoKucukResmi(
                                        fotolar[i],
                                        64,
                                        onTap: () => _fotoGoruntule(
                                          List<String>.from(fotolar),
                                          i,
                                          sil: (ad) async {
                                            fotoKaldir(ad);
                                            return true;
                                          },
                                        ),
                                        onSil: () => fotoKaldir(fotolar[i]),
                                      ),
                                    PopupMenuButton<String>(
                                      tooltip: 'Fotoğraf ekle',
                                      onSelected: (v) async {
                                        final List<String> adlar = await _fotolariSecVeKaydet(v == 'kamera' ? ImageSource.camera : ImageSource.gallery);
                                        if (adlar.isEmpty || !sheetContext.mounted) return;
                                        setModalState(() {
                                          fotolar.addAll(adlar);
                                          yeniFotolar.addAll(adlar);
                                        });
                                      },
                                      itemBuilder: (menuContext) => const <PopupMenuEntry<String>>[
                                        PopupMenuItem<String>(value: 'kamera', child: Row(children: [Icon(Icons.photo_camera_outlined, size: 18), SizedBox(width: 8), Text('Kamera ile çek')])),
                                        PopupMenuItem<String>(value: 'galeri', child: Row(children: [Icon(Icons.photo_library_outlined, size: 18), SizedBox(width: 8), Text('Galeriden seç')])),
                                      ],
                                      child: Container(
                                        width: 64,
                                        height: 64,
                                        decoration: BoxDecoration(color: acikZemin, borderRadius: BorderRadius.circular(10)),
                                        child: Icon(Icons.add_a_photo_outlined, color: anaRenk),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ]),

                            const SizedBox(height: 22),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                style: _anaDugmeStili,
                                onPressed: () {
                                  final bool gecerli = formKey.currentState!.validate();
                                  bool hataVar = !gecerli;
                                  if (!tumGun && zamanlar.isEmpty) {
                                    setModalState(() => zamanHatasi = 'En az bir saat ekleyin');
                                    hataVar = true;
                                  }
                                  if (tekrar != 'yok' && sureModu == 'tarih') {
                                    final DateTime? b = bitis;
                                    if (b == null || b.isBefore(DateTime(baslangic.year, baslangic.month, baslangic.day))) {
                                      setModalState(() => sureHatasi = 'Bitiş tarihi başlangıçtan önce olamaz');
                                      hataVar = true;
                                    }
                                  }
                                  final String? tutarsiz = sureTutarsizligi();
                                  if (tutarsiz != null) {
                                    setModalState(() => sureHatasi = tutarsiz);
                                    hataVar = true;
                                  }
                                  if (hataVar) {
                                    if (!gecerli) {
                                      _ilkHataliAlanaKaydir(formKey);
                                    } else {
                                      _hataliAlaniGoster(zamanHatasi != null ? zamanHataAnahtar : sureHataAnahtar);
                                    }
                                    return;
                                  }

                                  final Etkinlik e = taslak();
                                  for (final ad in silinenFotolar) {
                                    _fotoSil(ad);
                                  }
                                  kaydedildi = true;
                                  setState(() {
                                    if (mevcut == null) {
                                      etkinlikListesi.add(e);
                                    } else {
                                      final int i = etkinlikListesi.indexWhere((x) => x.id == mevcut.id);
                                      if (i >= 0) {
                                        etkinlikListesi[i] = e;
                                      } else {
                                        etkinlikListesi.add(e);
                                      }
                                    }
                                    // Etkinliğin tarihine git ki hemen görülsün
                                    _secilenAyYil = _ayAnahtari(e.baslangic);
                                    _ajandaGunSecimi = e.baslangic.day;
                                    _ajandaGunAyi = _secilenAyYil;
                                  });
                                  _bildirimleriYenile();
                                  Navigator.of(innerContext).pop();
                                },
                                child: Text(mevcut == null ? 'Kaydet' : 'Güncelle'),
                              ),
                            ),
                            if (mevcut != null)
                              Center(
                                child: TextButton.icon(
                                  onPressed: () {
                                    final Etkinlik silinecek = mevcut;
                                    Navigator.of(innerContext).pop();
                                    _etkinlikSilSecenekleri(silinecek);
                                  },
                                  icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                                  label: const Text('Etkinliği Sil', style: TextStyle(color: Colors.red)),
                                ),
                              ),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    // Kaydedilmeden kapatıldıysa bu oturumda eklenen fotoğrafları temizle
    if (!kaydedildi) {
      for (final ad in yeniFotolar) {
        _fotoSil(ad);
      }
    }
  }

}


// Sayfadaki dokunmaları izler.
// onBosDokunma: yalnızca hiçbir düğme / kart / onay kutusu dokunmayı üstlenmediyse çalışır
// (Flutter'ın hareket yarışında en içteki öğe kazandığı için bu güvenilir bir ayrımdır).
// onDokunma: her kısa dokunmadan sonra çalışır (örn. metin seçimini temizlemek için).
class DokunmaDinleyici extends StatefulWidget {
  final GlobalKey? haricAlan; // bu alanın içindeki dokunmalar yok sayılır
  final VoidCallback? onBosDokunma;
  final VoidCallback? onDokunma;
  final Widget child;
  const DokunmaDinleyici({super.key, required this.child, this.haricAlan, this.onBosDokunma, this.onDokunma});

  @override
  State<DokunmaDinleyici> createState() => _DokunmaDinleyiciState();
}

class _DokunmaDinleyiciState extends State<DokunmaDinleyici> {
  Offset? _baslangic;
  DateTime? _zaman;

  bool _haricteMi(Offset konum) {
    final BuildContext? c = widget.haricAlan?.currentContext;
    final RenderObject? ro = c?.findRenderObject();
    if (ro is! RenderBox || !ro.attached) return false;
    final Offset sol = ro.localToGlobal(Offset.zero);
    return (sol & ro.size).contains(konum);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: widget.onBosDokunma == null
          ? null
          : (d) {
              if (_haricteMi(d.globalPosition)) return;
              widget.onBosDokunma!();
            },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          _baslangic = e.position;
          _zaman = DateTime.now();
        },
        onPointerUp: (e) {
          final Offset? b = _baslangic;
          final DateTime? z = _zaman;
          _baslangic = null;
          _zaman = null;
          if (widget.onDokunma == null || b == null || z == null) return;
          if ((e.position - b).distance > 18) return;
          if (DateTime.now().difference(z).inMilliseconds > 350) return;
          if (_haricteMi(e.position)) return;
          Future<void>.delayed(Duration.zero, () {
            if (mounted) widget.onDokunma!();
          });
        },
        onPointerCancel: (_) {
          _baslangic = null;
          _zaman = null;
        },
        child: widget.child,
      ),
    );
  }
}
