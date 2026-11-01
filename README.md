<p align="center">
  <img src="assets/icon/alfred_ikon_1024.png" width="120" alt="Alfred">
</p>

<h1 align="center">Alfred</h1>

<p align="center">
  Kişisel ajanda, not ve bütçe asistanı · Personal agenda, notes and budget assistant
</p>

<p align="center">
  <a href="#türkçe">Türkçe</a> · <a href="#english">English</a>
</p>

---

## Türkçe

Alfred; günlük işlerini, notlarını ve paranı tek bir yerde toplayan bir Android uygulamasıdır. Hesap açmak gerekmez, verilerin yalnızca telefonunda durur.

> Uygulamanın arayüzü şimdilik yalnızca Türkçedir.

### Özellikler

**Ajanda**
- Etkinlik türleri (Görev, İlaç, Randevu, Uçuş, Kargo… ve kendi türlerin), her türün kendi rengi ve simgesi
- Tek seferlik veya tekrarlanan etkinlikler: her gün, her N günde bir, haftanın belirli günleri, aylık, yıllık; süresiz ya da bitiş tarihli
- Bir etkinliğe birden fazla saat (örneğin ilaç dozları: Sabah, Öğle, Akşam); her saat ayrı ayrı "yapıldı" işaretlenir
- Ayın özeti: Tamamlanan, Geciken ve Yaklaşan sayaçları; dokununca ilgili etkinlikler listelenir
- Takvim ve liste görünümü, türe veya saate göre sıralama
- Etkinliğe not ve fotoğraf ekleme, ayrıntı penceresi
- "Tekrarı bitir": geçmiş kayıtları silmeden tekrarlanan bir etkinliği belirli bir günde sonlandırma

**Bildirimler**
- Etkinlikten önce istediğin kadar hatırlatma (dakika, saat, gün, hafta önce)
- Bildirimden uygulamayı açmadan **Ertele** ve **Yapıldı olarak işaretle**
- Günlük sabah özeti ve haftalık "önümüzdeki hafta" özeti
- Ödeme hatırlatmaları, gecikme bildirimi
- Bildirim sesi, titreşim ve "sessizdeyken de çal" seçenekleri

**Notlar ve listeler**
- Serbest not veya maddeli liste (alışveriş listesi gibi)
- Kategoriler, renkler, sabitleme, fotoğraf ekleme
- Notlara hatırlatma eklenebilir; hatırlatmalı notlar ajandada da görünür
- Son düzenlemeye göre sıralama, arama, arşiv ve çöp kutusu

**Finans**
- Gelir ve gider kayıtları, kategoriler
- Kredi kartları, kredi borçları, kart taksitleri
- Sabit ödemeler (kira, abonelik, fatura) her ay kendiliğinden oluşur
- Kısmi ödeme, ödenmemiş tutar takibi
- Geçmiş kayıtlara bakarak kategori önerisi
- Analiz sekmesinde grafikler

**Diğer**
- Sesle yazma (Hızlı Ekle, not ve liste maddeleri)
- Ana ekran widget'ı ve uygulama simgesi kısayolları
- Birden fazla profil (örneğin kendin ve ailen için ayrı veriler)
- Uygulama kilidi (telefonun ekran kilidi veya parmak izi)
- Gizlilik modu (tutarları gizler)
- Açık, koyu ve sistem teması
- Yedekleme: uygulama içi otomatik yedek, dosyaya dışa aktarma ve dosyadan geri yükleme

### Gizlilik

Alfred hesap istemez ve verilerini hiçbir sunucuya göndermez. Her şey telefonunun içinde saklanır. Bu yüzden **düzenli yedek almanı** öneririm: Ayarlar → Yedekleme → Yedek al → "Dosya olarak kaydet" ile yedeği Drive'a ya da başka bir yere kaydedebilirsin. Uygulama silinirse, telefonun içindeki yedekler de silinir.

### Kurulum

1. [Releases](../../releases) sayfasından en son sürümün APK dosyasını (ör. `Alfred-1.0.0.apk`) indir.
2. Telefonda dosyayı aç. Android "bilinmeyen kaynaklardan yükleme" izni isteyebilir; bu izni yalnızca kurulum için ver.
3. İlk açılışta bildirim izni ver. Hatırlatmaların zamanında gelmesi için Ayarlar → Bildirimler bölümündeki önerileri (tam zamanlı alarm, pil kısıtlamasını kaldırma) uygulaman iyi olur.

Güncelleme için yeni sürümün APK'sını aynı şekilde kurman yeterli; verilerin korunur.

### Kaynaktan derleme

[Flutter](https://docs.flutter.dev/get-started/install) kurulu olmalı.

```bash
git clone <bu deponun adresi>
cd kisisel_asistan
flutter pub get
flutter run --release
```

Kodun neredeyse tamamı `lib/main.dart` dosyasındadır. Android'e özgü parçalar (widget, kilit ekranı, bildirim ayarları) `android/app/src/main/` altındadır.

### Durum

Kişisel kullanım için geliştirilen, sürekli değişen bir projedir. Yalnızca Android'de denenmiştir.

### Lisans

[MIT](LICENSE). Kodu kullanabilir, değiştirebilir ve paylaşabilirsin; lisans metnini ve telif satırını korumak yeterli.

Alfred **olduğu gibi** sunulur, hiçbir garanti verilmez. Uygulamanın kullanımından doğabilecek veri kaybı, kaçırılan hatırlatma veya hatalı hesaplama gibi sonuçlardan geliştirici sorumlu tutulamaz. Önemli bilgilerini yalnızca Alfred'e bırakma ve düzenli yedek al. Finans bölümü kişisel takip içindir; mali danışmanlık yerine geçmez.

---

## English

Alfred is an Android app that keeps your daily tasks, notes and money in one place. No account is needed, and your data stays on your phone.

> The app's interface is currently available in Turkish only.

### Features

**Agenda**
- Event types (Task, Medication, Appointment, Flight, Delivery… plus your own), each with its own color and icon
- One-off or recurring events: daily, every N days, specific weekdays, monthly, yearly; open-ended or with an end date
- Several times per event (e.g. medication doses: morning, noon, evening), each one checked off separately
- Monthly summary: Completed, Overdue and Upcoming counters; tap one to list its events
- Calendar and list views, sorting by type or time
- Notes and photos on events, plus a details view
- "End repeat": stop a recurring event on a given day without losing its history

**Notifications**
- Any number of reminders before an event (minutes, hours, days, weeks)
- **Snooze** and **Mark as done** right from the notification, without opening the app
- Daily morning summary and weekly "next week" summary
- Payment reminders and overdue alerts
- Notification sound, vibration and "ring even in silent mode" options

**Notes and lists**
- Free-text notes or checklists (like a shopping list)
- Categories, colors, pinning, photos
- Notes can have reminders; those notes also appear in the agenda
- Sorting by last edit, search, archive and trash

**Finance**
- Income and expense records with categories
- Credit cards, loans and card installments
- Fixed payments (rent, subscriptions, bills) are created automatically each month
- Partial payments and outstanding balance tracking
- Category suggestions based on your past entries
- Charts in the Analysis tab

**Other**
- Voice typing (Quick Add, notes and list items)
- Home screen widget and app icon shortcuts
- Multiple profiles (e.g. separate data for you and your family)
- App lock (phone screen lock or fingerprint)
- Privacy mode (hides amounts)
- Light, dark and system themes
- Backups: automatic in-app backups, export to a file and restore from a file

### Privacy

Alfred asks for no account and sends your data to no server. Everything is stored on your phone, so **take backups regularly**: Settings → Backup → Back up → "Save as file" lets you save a copy to Drive or anywhere else. If the app is uninstalled, the backups kept inside the app are removed too.

### Installation

1. Download the latest APK (e.g. `Alfred-1.0.0.apk`) from the [Releases](../../releases) page.
2. Open the file on your phone. Android may ask for permission to install from unknown sources; grant it only for this install.
3. Allow notifications on first launch. For reminders to arrive on time, follow the suggestions under Settings → Notifications (exact alarms, removing battery restrictions).

To update, install the newer APK the same way; your data is kept.

### Building from source

You need [Flutter](https://docs.flutter.dev/get-started/install).

```bash
git clone <this repository's URL>
cd kisisel_asistan
flutter pub get
flutter run --release
```

Almost all of the code lives in `lib/main.dart`. Android-specific parts (widget, lock screen, notification settings) are under `android/app/src/main/`.

### Status

A personal project under active development. Tested on Android only.

### License

[MIT](LICENSE). You may use, modify and share the code as long as the license text and copyright notice are kept.

Alfred is provided **as is**, without warranty of any kind. The developer cannot be held liable for any outcome of using the app, such as data loss, missed reminders or incorrect calculations. Don't rely on Alfred alone for important information, and back up regularly. The finance section is for personal tracking and is not financial advice.
