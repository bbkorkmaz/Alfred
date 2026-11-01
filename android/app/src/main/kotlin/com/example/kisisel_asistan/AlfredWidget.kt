package com.example.kisisel_asistan

import android.app.Activity
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.style.StrikethroughSpan
import android.text.style.StyleSpan
import android.graphics.Typeface
import android.util.TypedValue
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

// ---------------------------------------------------------------------------
// Veri: Flutter tarafı "HomeWidgetPreferences" içine yazar, widget buradan okur
// ---------------------------------------------------------------------------
object AlfredVeri {
    private const val TERCIH = "HomeWidgetPreferences"

    fun tercih(c: Context) = c.getSharedPreferences(TERCIH, Context.MODE_PRIVATE)

    fun veri(c: Context): JSONObject = try {
        JSONObject(tercih(c).getString("w_veri", null) ?: "{}")
    } catch (e: Exception) {
        JSONObject()
    }

    fun ayar(c: Context, id: Int): JSONObject = try {
        JSONObject(tercih(c).getString("wc_$id", null) ?: "{}")
    } catch (e: Exception) {
        JSONObject()
    }

    fun ayarYaz(c: Context, id: Int, o: JSONObject) {
        tercih(c).edit().putString("wc_$id", o.toString()).commit()
    }

    // Bir widget'ın göstereceği notların kimlikleri:
    //  - "nids" varsa yalnızca onlar,
    //  - yoksa eski tekli "nid",
    //  - ikisi de yoksa tüm notlar ("nharic" içindekiler hariç; sonradan eklenenler dahil). Sabitlenenler başa gelir.
    fun notKimlikleri(c: Context, ayar: JSONObject): List<String> {
        val l = ArrayList<String>()
        val a = ayar.optJSONArray("nids")
        if (a != null) {
            for (i in 0 until a.length()) l.add(a.optString(i))
            return l
        }
        if (ayar.optString("nid").isNotEmpty()) {
            l.add(ayar.optString("nid"))
            return l
        }
        val haric = HashSet<String>()
        val h = ayar.optJSONArray("nharic")
        if (h != null) for (i in 0 until h.length()) haric.add(h.optString(i))
        val tum = veri(c).optJSONArray("n") ?: return l
        val sabitler = ArrayList<String>()
        for (i in 0 until tum.length()) {
            val n = tum.optJSONObject(i) ?: continue
            val id = n.optString("i")
            if (haric.contains(id)) continue
            if (n.optBoolean("s")) sabitler.add(id) else l.add(id)
        }
        sabitler.addAll(l)
        return sabitler
    }

    fun not(c: Context, nid: String): JSONObject? {
        val a = veri(c).optJSONArray("n") ?: return null
        for (i in 0 until a.length()) {
            val n = a.optJSONObject(i) ?: continue
            if (n.optString("i") == nid) return n
        }
        return null
    }

    // Uygulama kapalıyken atılan tikler; uygulama açılınca Flutter bunları işler
    @Synchronized
    fun kuyrugaEkle(c: Context, k: String, d: Boolean) {
        val ham = tercih(c).getString("w_bekleyen", null)
        val a = try { JSONArray(ham ?: "[]") } catch (e: Exception) { JSONArray() }
        a.put(JSONObject().put("k", k).put("d", d))
        tercih(c).edit().putString("w_bekleyen", a.toString()).commit()
    }

    fun kuyrukHaritasi(c: Context): Map<String, Boolean> {
        val h = HashMap<String, Boolean>()
        val ham = tercih(c).getString("w_bekleyen", null) ?: return h
        try {
            val a = JSONArray(ham)
            for (i in 0 until a.length()) {
                val o = a.getJSONObject(i)
                h[o.getString("k")] = o.optBoolean("d")
            }
        } catch (e: Exception) {
        }
        return h
    }
}

// ---------------------------------------------------------------------------
// Widget sağlayıcısı
// ---------------------------------------------------------------------------
class AlfredWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) guncelle(context, mgr, id)
    }

    override fun onAppWidgetOptionsChanged(context: Context, mgr: AppWidgetManager, id: Int, opts: Bundle?) {
        super.onAppWidgetOptionsChanged(context, mgr, id, opts)
        guncelle(context, mgr, id)
    }

    override fun onDeleted(context: Context, ids: IntArray) {
        val e = AlfredVeri.tercih(context).edit()
        for (id in ids) e.remove("wc_$id")
        e.apply()
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        when (intent.action) {
            Intent.ACTION_DATE_CHANGED, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED, Intent.ACTION_MY_PACKAGE_REPLACED -> hepsiniYenile(context)
        }
    }

    companion object {
        fun hepsiniYenile(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(ComponentName(context, AlfredWidget::class.java))
            for (id in ids) guncelle(context, mgr, id)
        }

        fun verileriYenile(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(ComponentName(context, AlfredWidget::class.java))
            mgr.notifyAppWidgetViewDataChanged(ids, R.id.liste)
        }

        private fun ac(context: Context, yol: String): PendingIntent =
            HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("alfred://widget/$yol"))

        private fun baslikMetni(context: Context, ayar: JSONObject): String {
            return when (ayar.optString("tur", "hafta")) {
                "bugun", "hafta" -> "Yaklaşan etkinlikler"
                "finans" -> "Finans · " + (AlfredVeri.veri(context).optJSONObject("f")?.optString("ay") ?: "")
                "not", "notlar" -> {
                    val idler = AlfredVeri.notKimlikleri(context, ayar)
                    if (idler.size == 1) (AlfredVeri.not(context, idler[0])?.optString("b") ?: "Not") else "Notlar"
                }
                else -> "Alfred"
            }
        }

        fun acilisYolu(context: Context, ayar: JSONObject): String = when (ayar.optString("tur", "hafta")) {
            "finans" -> "finans"
            "not", "notlar" -> {
                val idler = AlfredVeri.notKimlikleri(context, ayar)
                if (idler.size == 1) "not/" + idler[0] else "notlar"
            }
            else -> "ajanda"
        }

        fun guncelle(context: Context, mgr: AppWidgetManager, id: Int) {
            val ayar = AlfredVeri.ayar(context, id)
            val koyu = ayar.optString("tema", "koyu") == "koyu"
            val rv = RemoteViews(context.packageName, R.layout.widget_alfred)

            rv.setInt(R.id.kok, "setBackgroundResource", if (koyu) R.drawable.widget_arka else R.drawable.widget_arka_acik)
            rv.setTextViewText(R.id.baslik, baslikMetni(context, ayar))
            rv.setTextColor(R.id.baslik, if (koyu) Color.parseColor("#F9FAFB") else Color.parseColor("#111827"))

            val genislik = mgr.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 300)
            val dugmeGorunum = if (genislik >= 210) View.VISIBLE else View.GONE
            rv.setViewVisibility(R.id.dugme_not, dugmeGorunum)
            rv.setViewVisibility(R.id.dugme_liste, dugmeGorunum)
            rv.setViewVisibility(R.id.dugme_etkinlik, dugmeGorunum)

            rv.setOnClickPendingIntent(R.id.kok, ac(context, acilisYolu(context, ayar)))
            rv.setOnClickPendingIntent(R.id.baslik, ac(context, acilisYolu(context, ayar)))
            rv.setOnClickPendingIntent(R.id.dugme_not, ac(context, "yeni_not"))
            rv.setOnClickPendingIntent(R.id.dugme_liste, ac(context, "yeni_liste"))
            rv.setOnClickPendingIntent(R.id.dugme_etkinlik, ac(context, "yeni_etkinlik"))

            val servis = Intent(context, AlfredWidgetService::class.java)
            servis.putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
            servis.data = Uri.parse(servis.toUri(Intent.URI_INTENT_SCHEME))
            rv.setRemoteAdapter(R.id.liste, servis)
            rv.setEmptyView(R.id.liste, R.id.bos)
            rv.setTextColor(R.id.bos, if (koyu) Color.parseColor("#9CA3AF") else Color.parseColor("#6B7280"))

            val sablon = Intent(context, AlfredWidgetIslem::class.java)
            val bayrak = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            rv.setPendingIntentTemplate(R.id.liste, PendingIntent.getActivity(context, 0, sablon, bayrak))

            mgr.updateAppWidget(id, rv)
            mgr.notifyAppWidgetViewDataChanged(id, R.id.liste)
        }
    }
}

// ---------------------------------------------------------------------------
// Listeye dokunma: tik atma ya da uygulamayı açma (görünmez ara etkinlik)
// ---------------------------------------------------------------------------
class AlfredWidgetIslem : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            when (intent.getStringExtra("islem")) {
                "tik" -> {
                    val k = intent.getStringExtra("k")
                    if (k != null) {
                        AlfredVeri.kuyrugaEkle(this, k, intent.getBooleanExtra("d", true))
                        AlfredWidget.verileriYenile(this)
                    }
                }
                "ac" -> {
                    val yol = intent.getStringExtra("yol") ?: "ajanda"
                    val git = Intent(this, MainActivity::class.java)
                    git.action = HomeWidgetLaunchIntent.HOME_WIDGET_LAUNCH_ACTION
                    git.data = Uri.parse("alfred://widget/$yol")
                    git.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    startActivity(git)
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("AlfredWidget", "Islem hatasi", e)
        }
        finish()
    }
}

// ---------------------------------------------------------------------------
// Liste içeriği (widget büyüyünce daha çok satır görünür)
// ---------------------------------------------------------------------------
class AlfredWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        AlfredFabrika(applicationContext, intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, 0))
}

class Satir(
    val baslik: Boolean = false,
    val metin: String,
    val alt: String = "", // başlığın altındaki tek satırlık önizleme
    val sag: String = "",
    val kutu: Boolean = false,
    val tikli: Boolean = false,
    val tamam: Boolean = false,
    val anahtar: String = "",
    val yol: String = "ajanda",
    val bosluk: Int = 0 // >0: boş alanı dolduran, dokununca açan görünmez satır (dp)
)

class AlfredFabrika(private val ctx: Context, private val id: Int) : RemoteViewsService.RemoteViewsFactory {
    private var satirlar: List<Satir> = emptyList()
    private var koyu = true

    override fun onCreate() {}
    override fun onDestroy() {}
    override fun getLoadingView(): RemoteViews? = null
    override fun getViewTypeCount(): Int = 1
    override fun getItemId(position: Int): Long = position.toLong()
    override fun hasStableIds(): Boolean = false
    override fun getCount(): Int = satirlar.size

    override fun onDataSetChanged() {
        satirlar = try { olustur() } catch (e: Exception) { listOf(Satir(metin = "Widget verisi okunamadı")) }
    }

    // Notun başlığının altında görünecek tek satır
    private fun onizleme(n: JSONObject, kuyruk: Map<String, Boolean>, nid: String): String {
        if (n.optBoolean("l")) {
            val m = n.optJSONArray("m") ?: return "Liste boş"
            var toplam = 0
            var biten = 0
            val kalanlar = ArrayList<String>()
            for (i in 0 until m.length()) {
                val o = m.getJSONObject(i)
                val tamam = kuyruk["m|" + nid + "|" + o.optString("i")] ?: o.optBoolean("x")
                toplam++
                if (tamam) biten++ else kalanlar.add(o.optString("t"))
            }
            if (toplam == 0) return "Liste boş"
            if (kalanlar.isEmpty()) return "Hepsi tamam ($toplam/$toplam)"
            return "$biten/$toplam · " + kalanlar.joinToString(", ")
        }
        for (satir in n.optString("y").split("\n")) {
            if (satir.isNotBlank()) return satir.trim()
        }
        return "Boş not"
    }

    private fun saatGectiMi(t: String): Boolean {
        val m = Regex("^(\\d{1,2}):(\\d{2})").find(t.trim()) ?: return false
        val cal = java.util.Calendar.getInstance()
        val simdi = cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + cal.get(java.util.Calendar.MINUTE)
        return m.groupValues[1].toInt() * 60 + m.groupValues[2].toInt() < simdi
    }

    private fun gunEtiketi(d: String, bugun: String): String {
        if (d == bugun) return "Bugün"
        val tr = Locale("tr", "TR")
        val bicim = SimpleDateFormat("yyyy-MM-dd", tr)
        val yarin = Calendar.getInstance()
        yarin.add(Calendar.DAY_OF_YEAR, 1)
        if (d == bicim.format(yarin.time)) return "Yarın"
        return try {
            SimpleDateFormat("EEEE, d MMMM", tr).format(bicim.parse(d)!!)
        } catch (e: Exception) {
            d
        }
    }

    private fun olustur(): List<Satir> {
        val ayar = AlfredVeri.ayar(ctx, id)
        koyu = ayar.optString("tema", "koyu") == "koyu"
        var tur = ayar.optString("tur", "hafta")
        if (tur == "bugun") tur = "hafta"
        val veri = AlfredVeri.veri(ctx)
        val kuyruk = AlfredVeri.kuyrukHaritasi(ctx)
        val l = ArrayList<Satir>()

        if (!veri.has("g")) {
            l.add(Satir(metin = "Alfred'i bir kez açınca veriler burada görünür"))
            return l
        }

        when (tur) {
            "hafta" -> {
                val bugun = SimpleDateFormat("yyyy-MM-dd", Locale("tr", "TR")).format(Date())
                val g = veri.optJSONArray("g") ?: JSONArray()
                for (gi in 0 until g.length()) {
                    val gun = g.getJSONObject(gi)
                    val d = gun.getString("d")
                    if (d < bugun) continue
                    val ev = gun.optJSONArray("e") ?: continue
                    if (ev.length() == 0) continue
                    val satirlar = ArrayList<Satir>()
                    for (ei in 0 until ev.length()) {
                        val e = ev.getJSONObject(ei)
                        val anahtar = "e|" + e.getString("i") + "|" + e.getString("a")
                        val tamam = kuyruk[anahtar] ?: e.optBoolean("x")
                        // Saati geçmiş VE yapılmış bugünkü etkinlikler gizlenir; yapılmamış olanlar görünmeye devam eder
                        if (d == bugun && tamam && saatGectiMi(e.optString("t"))) continue
                        satirlar.add(Satir(metin = e.optString("b"), sag = e.optString("t"), kutu = true, tikli = true, tamam = tamam, anahtar = anahtar, yol = "etkinlik/" + d + "/" + e.getString("i")))
                    }
                    if (satirlar.isEmpty()) continue
                    l.add(Satir(baslik = true, metin = gunEtiketi(d, bugun)))
                    l.addAll(satirlar)
                }
                if (l.isEmpty()) l.add(Satir(metin = "Yaklaşan etkinlik yok"))
            }
            "not", "notlar" -> {
                val idler = AlfredVeri.notKimlikleri(ctx, ayar)
                if (idler.size == 1) {
                    // Tek not seçiliyse tamamı görünür (listede maddelere tik atılabilir)
                    val nid = idler[0]
                    val n = AlfredVeri.not(ctx, nid)
                    if (n == null) {
                        l.add(Satir(metin = "Not bulunamadı. Widget'a uzun basıp ayarlardan başka bir not seç."))
                    } else if (n.optBoolean("l")) {
                        val m = n.optJSONArray("m") ?: JSONArray()
                        for (i in 0 until m.length()) {
                            val o = m.getJSONObject(i)
                            val anahtar = "m|" + nid + "|" + o.getString("i")
                            val tamam = kuyruk[anahtar] ?: o.optBoolean("x")
                            l.add(Satir(metin = o.optString("t"), kutu = true, tikli = true, tamam = tamam, anahtar = anahtar, yol = "not/$nid"))
                        }
                        if (l.isEmpty()) l.add(Satir(metin = "Liste boş", yol = "not/$nid"))
                    } else {
                        for (satir in n.optString("y").split("\n")) {
                            if (satir.isNotBlank()) l.add(Satir(metin = satir.trim(), yol = "not/$nid"))
                        }
                        if (l.isEmpty()) l.add(Satir(metin = "Not boş", yol = "not/$nid"))
                    }
                } else {
                    // Birden çok not: her biri için başlık + tek satır önizleme, kaydırılabilir
                    for (nid in idler) {
                        val n = AlfredVeri.not(ctx, nid) ?: continue
                        l.add(Satir(metin = n.optString("b"), alt = onizleme(n, kuyruk, nid), yol = "not/$nid"))
                    }
                    if (l.isEmpty()) l.add(Satir(metin = "Seçili not bulunamadı. Widget'a uzun basıp ayarlardan not seç.", yol = "notlar"))
                }
            }
            "finans" -> {
                val gizle = ayar.optBoolean("gizle", false)
                val f = veri.optJSONObject("f")
                if (f == null) {
                    l.add(Satir(metin = "Finans verisi yok"))
                } else {
                    val kalan = if (gizle) "•••••" else f.optString("kalan")
                    val odenen = if (gizle) "•••••" else f.optString("odenen")
                    l.add(Satir(baslik = true, metin = "Kalan $kalan  ·  Ödenen $odenen", yol = "finans"))
                    val k = f.optJSONArray("k") ?: JSONArray()
                    for (i in 0 until k.length()) {
                        val o = k.getJSONObject(i)
                        l.add(Satir(metin = o.optString("b"), sag = if (gizle) "•••" else o.optString("t"), kutu = true, tamam = o.optBoolean("x"), yol = "finans"))
                    }
                    if (k.length() == 0) l.add(Satir(metin = "Bu ay gider yok", yol = "finans"))
                }
            }
            else -> l.add(Satir(metin = "Widget ayarlanmamış"))
        }

        // Altta kalan boş alana dokununca da ilgili yer açılsın
        val secenekler = AppWidgetManager.getInstance(ctx).getAppWidgetOptions(id)
        val yukseklik = secenekler.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 300)
        var kullanilan = 0
        for (r in l) kullanilan += if (r.alt.isNotEmpty()) 54 else 38
        val kalan = yukseklik - 56 - kullanilan
        if (kalan > 8) l.add(Satir(metin = "", yol = AlfredWidget.acilisYolu(ctx, ayar), bosluk = kalan))
        return l
    }

    override fun getViewAt(position: Int): RemoteViews {
        val s = satirlar[position]
        val rv = RemoteViews(ctx.packageName, R.layout.widget_satir)
        val ana = if (koyu) Color.parseColor("#F9FAFB") else Color.parseColor("#111827")
        val soluk = if (koyu) Color.parseColor("#9CA3AF") else Color.parseColor("#6B7280")
        val vurgu = if (koyu) Color.parseColor("#A5B4FC") else Color.parseColor("#4F46E5")

        rv.setViewVisibility(R.id.kutu, if (s.kutu) View.VISIBLE else View.GONE)
        if (s.kutu) {
            rv.setImageViewResource(R.id.kutu, if (s.tamam) R.drawable.widget_tik_dolu else R.drawable.widget_tik_bos)
        }

        val yazi = SpannableString(s.metin)
        if (s.tamam && s.metin.isNotEmpty()) yazi.setSpan(StrikethroughSpan(), 0, s.metin.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        if (s.alt.isNotEmpty() && s.metin.isNotEmpty()) yazi.setSpan(StyleSpan(Typeface.BOLD), 0, s.metin.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        rv.setInt(R.id.metin, "setMaxLines", if (s.alt.isNotEmpty()) 1 else 3)
        rv.setViewVisibility(R.id.alt, if (s.alt.isEmpty()) View.GONE else View.VISIBLE)
        rv.setTextViewText(R.id.alt, s.alt)
        rv.setTextColor(R.id.alt, soluk)
        rv.setTextViewText(R.id.metin, yazi)
        rv.setTextColor(R.id.metin, if (s.baslik) vurgu else if (s.tamam) soluk else ana)
        rv.setTextViewTextSize(R.id.metin, TypedValue.COMPLEX_UNIT_SP, if (s.baslik) 12f else 14f)

        rv.setViewVisibility(R.id.sag, if (s.sag.isEmpty()) View.GONE else View.VISIBLE)
        rv.setTextViewText(R.id.sag, s.sag)
        rv.setTextColor(R.id.sag, soluk)

        // Android satırları yeniden kullanır; önceki satırdan kalan boşluk sıfırlansın
        rv.setViewPadding(R.id.satir, 0, 0, 0, 0)
        rv.setViewVisibility(R.id.kutu, if (s.kutu) View.VISIBLE else View.GONE)
        rv.setViewVisibility(R.id.sag, if (s.sag.isEmpty()) View.GONE else View.VISIBLE)
        if (s.bosluk > 0) {
            val px = (s.bosluk * ctx.resources.displayMetrics.density).toInt()
            rv.setViewVisibility(R.id.kutu, View.GONE)
            rv.setViewVisibility(R.id.sag, View.GONE)
            rv.setViewPadding(R.id.satir, 0, px, 0, 0)
        }

        val ac = Intent().putExtra("islem", "ac").putExtra("yol", s.yol)
        rv.setOnClickFillInIntent(R.id.satir, ac)
        rv.setOnClickFillInIntent(R.id.metin, ac)
        rv.setOnClickFillInIntent(R.id.alt, ac)
        rv.setOnClickFillInIntent(R.id.sag, ac)
        if (s.tikli) {
            rv.setOnClickFillInIntent(
                R.id.kutu,
                Intent().putExtra("islem", "tik").putExtra("k", s.anahtar).putExtra("d", !s.tamam)
            )
        } else if (s.kutu) {
            rv.setOnClickFillInIntent(R.id.kutu, ac)
        }
        return rv
    }
}

// ---------------------------------------------------------------------------
// Widget eklenince (ve uzun basıp "ayarla" denince) açılan ayar ekranı
// ---------------------------------------------------------------------------
class AlfredWidgetAyar : Activity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)
        widgetId = intent?.extras?.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }

        val mevcut = AlfredVeri.ayar(this, widgetId)
        val notlar = AlfredVeri.veri(this).optJSONArray("n") ?: JSONArray()
        val notIdleri = ArrayList<String>()
        val notAdlari = ArrayList<String>()
        val yeniMod = !mevcut.has("nids") && mevcut.optString("nid").isEmpty() // "tüm notlar, işaretini kaldırdıklarım hariç"
        val seciliAcik = HashSet<String>()
        val nidsA = mevcut.optJSONArray("nids")
        if (nidsA != null) for (i in 0 until nidsA.length()) seciliAcik.add(nidsA.optString(i))
        if (mevcut.optString("nid").isNotEmpty()) seciliAcik.add(mevcut.optString("nid"))
        val harics = HashSet<String>()
        val harA = mevcut.optJSONArray("nharic")
        if (harA != null) for (i in 0 until harA.length()) harics.add(harA.optString(i))
        for (i in 0 until notlar.length()) {
            val n = notlar.getJSONObject(i)
            notIdleri.add(n.optString("i"))
            notAdlari.add((if (n.optBoolean("l")) "☑ " else "📝 ") + n.optString("b"))
        }

        val dp = resources.displayMetrics.density
        fun px(v: Int) = (v * dp).toInt()

        val kutu = LinearLayout(this)
        kutu.orientation = LinearLayout.VERTICAL
        kutu.setPadding(px(20), px(16), px(20), px(8))

        fun baslik(t: String): TextView {
            val tv = TextView(this)
            tv.text = t
            tv.textSize = 15f
            tv.setTypeface(null, android.graphics.Typeface.BOLD)
            tv.setPadding(0, px(12), 0, px(4))
            return tv
        }

        kutu.addView(baslik("Bu widget ne göstersin?"))
        val turGrubu = RadioGroup(this)
        val turler = listOf(
            "hafta" to "Yaklaşan etkinlikler",
            "notlar" to "Notlar ve listeler",
            "finans" to "Finans (bu ayın giderleri)"
        )
        val turIdleri = HashMap<String, Int>()
        for ((anahtar, ad) in turler) {
            val rb = RadioButton(this)
            rb.text = ad
            rb.id = View.generateViewId()
            turIdleri[anahtar] = rb.id
            turGrubu.addView(rb)
        }
        kutu.addView(turGrubu)

        // Gösterilecek notlar: her biri bir onay kutusu (seçilenler görünür kalır)
        val notKutusu = LinearLayout(this)
        notKutusu.orientation = LinearLayout.VERTICAL
        val notOnay = ArrayList<CheckBox>()

        val ipucu = TextView(this)
        ipucu.text = "Göstermek istemediklerinin işaretini kaldır:"
        ipucu.setPadding(0, px(4), 0, px(4))
        notKutusu.addView(ipucu)

        val yeniOtomatik = CheckBox(this)
        yeniOtomatik.text = "Sonradan eklediğim notlar da otomatik görünsün"
        yeniOtomatik.isChecked = yeniMod
        notKutusu.addView(yeniOtomatik)

        val hizli = LinearLayout(this)
        hizli.orientation = LinearLayout.HORIZONTAL
        val hepsiDugme = Button(this)
        hepsiDugme.text = "Hepsini seç"
        val temizDugme = Button(this)
        temizDugme.text = "Temizle"
        hizli.addView(hepsiDugme)
        hizli.addView(temizDugme)
        notKutusu.addView(hizli)

        for (i in notAdlari.indices) {
            val cb = CheckBox(this)
            cb.text = notAdlari[i]
            cb.isChecked = if (yeniMod) !harics.contains(notIdleri[i]) else seciliAcik.contains(notIdleri[i])
            notOnay.add(cb)
            notKutusu.addView(cb)
        }
        hepsiDugme.setOnClickListener { for (cb in notOnay) cb.isChecked = true }
        temizDugme.setOnClickListener { for (cb in notOnay) cb.isChecked = false }
        if (notAdlari.isEmpty()) {
            val bos = TextView(this)
            bos.text = "Henüz not yok. Önce Alfred'de not oluştur."
            notKutusu.addView(bos)
        }
        kutu.addView(notKutusu)

        val gizle = CheckBox(this)
        gizle.text = "Tutarları gizle (•••)"
        kutu.addView(gizle)

        kutu.addView(baslik("Görünüm"))
        val temaGrubu = RadioGroup(this)
        temaGrubu.orientation = LinearLayout.HORIZONTAL
        val koyuRb = RadioButton(this)
        koyuRb.text = "Koyu"
        koyuRb.id = View.generateViewId()
        val acikRb = RadioButton(this)
        acikRb.text = "Açık"
        acikRb.id = View.generateViewId()
        temaGrubu.addView(koyuRb)
        temaGrubu.addView(acikRb)
        kutu.addView(temaGrubu)

        val tamam = Button(this)
        tamam.text = "Tamam"
        kutu.addView(tamam)

        fun gorunumuGuncelle() {
            val secili = turler.firstOrNull { turIdleri[it.first] == turGrubu.checkedRadioButtonId }?.first ?: "hafta"
            notKutusu.visibility = if (secili == "notlar") View.VISIBLE else View.GONE
            gizle.visibility = if (secili == "finans") View.VISIBLE else View.GONE
        }
        turGrubu.setOnCheckedChangeListener { _, _ -> gorunumuGuncelle() }

        // Mevcut ayarları yerleştir
        val mevcutTur = when (mevcut.optString("tur", "hafta")) {
            "bugun" -> "hafta"
            "not" -> "notlar"
            else -> mevcut.optString("tur", "hafta")
        }
        turGrubu.check(turIdleri[mevcutTur] ?: turIdleri["hafta"]!!)
        gizle.isChecked = mevcut.optBoolean("gizle", false)
        temaGrubu.check(if (mevcut.optString("tema", "koyu") == "koyu") koyuRb.id else acikRb.id)
        gorunumuGuncelle()

        tamam.setOnClickListener {
            val secili = turler.firstOrNull { turIdleri[it.first] == turGrubu.checkedRadioButtonId }?.first ?: "hafta"
            val secilenler = JSONArray()
            val disarida = JSONArray()
            for (i in notOnay.indices) {
                if (notOnay[i].isChecked) secilenler.put(notIdleri[i]) else disarida.put(notIdleri[i])
            }
            if (secili == "notlar" && secilenler.length() == 0) {
                Toast.makeText(this, "En az bir not ya da liste seç.", Toast.LENGTH_LONG).show()
                return@setOnClickListener
            }
            val o = JSONObject()
            o.put("tur", secili)
            if (secili == "notlar") {
                if (yeniOtomatik.isChecked) o.put("nharic", disarida) else o.put("nids", secilenler)
            }
            o.put("gizle", gizle.isChecked)
            o.put("tema", if (temaGrubu.checkedRadioButtonId == koyuRb.id) "koyu" else "acik")
            AlfredVeri.ayarYaz(this, widgetId, o)
            AlfredWidget.guncelle(this, AppWidgetManager.getInstance(this), widgetId)
            setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
            finish()
        }

        val kaydirma = ScrollView(this)
        kaydirma.addView(kutu)
        setContentView(kaydirma)
    }
}