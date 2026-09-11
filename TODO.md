# Yapılacaklar

Bu dosya, üzerinde durulmuş ama henüz tamamlanmamış işleri — bloklanmış denemeler ve
tanımlanmış-ama-uygulanmamış planlar — kaybolmadan takip etmek için var. Kod
değişikliği burada anlatılmaz; ilgili kaynak dosyalar ve (varsa) `git stash`
girdisi referans verilir.

## Bekleyen

### Birkaç gün gerçek kullanım, sonra sabitleri ayarla — 11 Eylül 2026

11 Eylül'de dört şey birden değişti. Beşincisini eklemeden önce hangisinin ne
kadar fark ettiğini görmek gerekiyor; yoksa sonucu okumak imkânsızlaşır.

Kullanımdan sonra gerçek veriyle gözden geçirilecek sabitler:

| Sabit | Değer | Neden şüpheli |
|---|---|---|
| `RoutePolicy.minimumTokensForRepair` | 8 | Geçmişe karakter tahminiyle uygulandı, token sayısı saklanmıyordu. Gerçekten bozuk birkaç çok kısa kaydı da eliyor ("Bence direkt planlayı", güven 0.575). |
| `RoutePolicy.repairConfidenceThreshold` | 0.75 | Kısa kayıtların ~%14'ünü onarıma yolluyor. Çok fazla Codex beklemesi olursa düşürülür. |
| `TranscriptWord.uncertainThreshold` | 0.60 | Gerçek bir kayıtta bozuk kelime 0.37, sınırdaki doğru kelime 0.61 çıktı — ayrım dar. |

`transcriptWords` artık History'de saklandığı için bu üçü de tahminle değil
ölçümle ayarlanabilir.

**İzlenecek belirti:** kısa kayıtlarda beklenmedik Codex beklemesi; doğru
kelimelerin turuncu işaretlenmesi; riskli düzeltmenin gerekirken devreye
girmemesi.

### Adım 3 — model kuantizasyonunu ölç (yapılmadı)

Şu an `ggml-large-v3-turbo-q5_0`. `q8_0` daha az kayıplı; bellek ve hız
maliyetine karşı doğruluk kazancı **ölçülebilir** artık, çünkü her kayıtta
`primaryConfidence` ve kelime bazlı güven saklanıyor.

Yöntem: aynı `Diagnostics/` WAV'ını iki modelle çalıştır, güven dağılımını ve
metni karşılaştır. Tek kayıt yeterli değil; birkaç farklı ortamdan kayıt gerekir.

### Bilinen sınır — düzeltme güveni kelime başına

`TextCleaner.applyCorrections` riskli düzeltmeyi kelime başına eşleştiriyor,
geçiş başına değil. Aynı kayıtta hem emin hem şüpheli bir "boyut" varsa ikisi de
değişir. Bugünkü davranışın aynısı, daha kötüsü değil; geçiş bazlı çözüm için
kelime listesini metin konumlarıyla hizalamak gerekir.

---

## Uygulandı

### Gürültü bastırma kaldırıldı — 11 Eylül 2026

Ölçüldü ve kaldırıldı. Aynı oturumda, aynı ortamda, 20 dakika içinde:

| | Gürültü tabanı (medyan) | Güven (ort) |
|---|---|---|
| Açık (n=3) | 0.00195 | 0.668 |
| Kapalı (n=9) | 0.00882 | 0.759 |

Voice Processing I/O gürültü tabanını yaklaşık **4.5 kat** düşürüyor — yani
teknik olarak çalışıyor. Ama tanıma belirgin biçimde kötüleşiyor. Açıkken
alınan bir kayıt: "İyicek olay, back-endler, bekliklerini kaldıralım";
kapatıldıktan iki dakika sonra aynı ortamda: "Yaklaşan son tarihler kısmı için
tasarım araştırmasını yapacağız."

Sonuç: **daha az gürültü daha iyi tanıma demek değil.** VPIO telefon görüşmesi
için ayarlanmış; gürültüyle birlikte Whisper'ın güvendiği yapıyı da eziyor.

7 Eylül'deki n=1 ölçüm de aynı yönü göstermişti. Ayrıca 9 Eylül'de hoparlörün
yakalama aygıtı olarak seçilmesini bu özellik tetiklemişti
(`docs/debug/CASE-speaker-selected-as-microphone.md`).

Kaldırılanlar: `VoiceProcessingCaptureDriver`, `AppSettings.noiseSuppression`
(kayıtlı anahtar migration ile siliniyor), Ayarlar'daki toggle,
`AudioDiagnostics.voiceProcessingFallbackReason`, gated donanım testi.
**Korunanlar:** 80 Hz high-pass, uyarlanabilir konuşma eşiği ve gürültü
tabanı/eşik tanı alanları — bunlar bağımsız çalışıyor ve ölçüm için gerekli.


### Tanı alanları sessizce siliniyordu — 9 Eylül 2026'da düzeltildi

`AudioDiagnostics` eski geçmiş dosyalarıyla uyumluluk için elle yazılmış bir
`init(from:)` taşıyor ve o `vadFallbackReason`'da bitiyordu. 7 Eylül'de eklenen
`noiseFloor`, `speechThreshold` ve `voiceProcessingFallbackReason` decode
edilmiyordu.

Mekanizma: değer diske doğru yazılıyor, uygulama bir sonraki açılışta `load()`
sırasında onu düşürüyor, ardından ilk `persist()` dosyanın tamamını sıfırlarla
geri yazıyordu. Yani veri sessizce yok ediliyordu — 7 Eylül'deki gürültü
ölçümünün kaybolmasının ve bir ara yanlış raporlanmasının sebebi buydu.

Düzeltme üç eksik alanı decode ediyor. `AudioDiagnosticsCodingTests` hem bu üç
alanı adıyla hem de tüm alanları `Equatable` üzerinden kontrol ediyor; ikincisi
alan-agnostik, yani ileride eklenip decoder'da unutulan her alan testi düşürür.
`HistoryEntry`'nin elle yazılmış decoder'ı tarandı, onun 24 alanı da tam.


### Gürültülü ortam iyileştirmeleri — 7 Eylül 2026

`git stash` içindeki VPIO denemesi iki düzeltmeyle canlandırıldı (cihaz
`setVoiceProcessingEnabled`'dan **önce** pinlenir; tap formatı node'un kendi
örnekleme hızını korur, yalnız kanalı 1'e indirir). `stash@{0}` içeriği artık
çalışma ağacında olduğu için gereksiz; silinmesi Türker'in onayına bırakıldı.
Ayrıca
`AVAudioIONode.audioUnit` public olduğu için selector hack'i kaldırıldı, VPIO
açılamazsa normal yakalamaya dönen bir fallback eklendi. Bunun yanında
uyarlanabilir konuşma eşiği, 80 Hz high-pass ve güven tabanlı kabul kapısı
uygulandı. Ayrıntı için CHANGELOG'un 7 Eylül 2026 girdisine bak.


### 2. CorrectionStore / "Düzelt ve öğret" — 6 Eylül 2026'da düzeltildi

Aşağıdaki tanım (ve altındaki plan) 6 Eylül 2026'da uygulandı: `TextCleaner.
applyCorrections` deterministik bulma-değiştirme katmanı eklendi, ölü
`promptPairs` kaldırıldı, `useCount` artık yalnız gerçek uygulanmaları sayıyor
(yeniden öğretme saymıyor) ve Ayarlar'da her düzeltmenin yanında "N kez devreye
girdi" görünüyor. Aşağıdaki bölüm, sorunun neden gerçek olduğunu belgeleyen
orijinal analiz olarak korunuyor.

### (orijinal tanım — artık uygulandı) CorrectionStore / "Düzelt ve öğret"

**Bağlam:** Kullanıcı, öğrenilen düzeltmelerin gerçekten işe yarayıp yaramadığından
emin olamadığını belirtti. Kod incelemesi bunun **gerçek bir sebebi olduğunu**
doğruladı — bu bir yanlış izlenim değil, kod tabanında somut bir eksiklik var.

**Bulunan sorun ([CorrectionStore.swift:74-76](Sources/DikteNative/CorrectionStore.swift)):**

```swift
var promptPairs: [String] {
    entries.filter(\.isEnabled).map { "\($0.heard) → \($0.corrected)" }
}
```

`promptPairs` **tanımlı ama hiçbir yerde kullanılmıyor** — tamamen ölü kod.
Gerçekte kullanılan tek şey `promptTerms`:

```swift
var promptTerms: [String] {
    Array(Set(["Codex", "Dikte", "Whisper", "Option D"] +
              entries.filter(\.isEnabled).map(\.corrected))).sorted()
}
```

Bu yalnız `corrected` (düzeltilmiş) kelimeyi alıyor, `heard` (yanlış duyulan) tarafını
tamamen atıyor. `AppModel.swift`'te bu liste Whisper'a `initial_prompt` olarak
("Özel isimler: ...") veriliyor ([WhisperEngine.swift:114](Sources/DikteNative/WhisperEngine.swift)) — yani öğrenilen her düzeltme,
Whisper'ın kod çözücüsüne **yalnızca "bu kelime muhtemelen geçecek" şeklinde
yumuşak bir ipucu** olarak gidiyor. Bu, "X duyulursa Y'ye çevir" gibi **kesin bir
bulma-değiştirme mekanizması değil** — olasılıksal bir öneri, garanti değil.

**Sonuç:** Kullanıcı bir düzeltme öğrettiğinde:
- Whisper'ın o kelimeyi doğru tanıma **ihtimali biraz artabilir**, ama garanti yok.
- `heard` tarafı (asıl yanlış duyulan biçim) **hiçbir işlem görmüyor** — ne bir
  metin değiştirme adımında, ne başka bir yerde kullanılıyor.
- Kullanıcının "öğreniyor mu, öğrenmiyor mu belli değil" hissi doğru bir gözlem;
  çünkü mekanizma zaten deterministik bir garanti sunmuyor, yalnız olasılıksal.

**İkincil gözlem:** `useCount` alanı yalnız kullanıcı **aynı düzeltmeyi tekrar
onayladığında** artıyor ([CorrectionStore.swift:83](Sources/DikteNative/CorrectionStore.swift)); düzeltmenin gerçek
transkripsiyonlarda kaç kez **fiilen işe yaradığını** izlemiyor. Yani `useCount`
kullanıcıya "bu düzeltme kaç kez gerçekten devreye girdi" bilgisini vermiyor,
yalnız "kaç kez yeniden öğretildi" bilgisini tutuyor.

**Tanımlanan (uygulanmamış) çözüm planı:**

1. **Deterministik katman ekle:** `TextCleaner` içine, Whisper çıktısından sonra
   çalışan, onaylanmış `heard → corrected` çiftlerini **harfi harfine, kelime
   sınırına duyarlı, büyük/küçük harf duyarsız bulma-değiştirme** olarak uygulayan
   bir adım eklemek. Bu, mevcut olasılıksal Whisper-prompt ipucunun **üstüne**
   eklenir, yerine geçmez — ikisi birlikte: Whisper'a önceden ipucu ver (mevcut
   `promptTerms`), sonra çıktıyı kesin biçimde düzelt (yeni adım, `promptPairs`'i
   canlandırır).
2. **Ölü kodu temizle veya kullan:** `promptPairs` ya yukarıdaki deterministik
   adımda kullanılmalı, ya da hiç kullanılmayacaksa kaldırılmalı — şu anki hâliyle
   yanıltıcı (var olması "bir işe yarıyor" izlenimi veriyor, yaramıyor).
3. **Gerçek etkinliği izle:** `useCount`'u yalnız yeniden öğretmede değil, deterministik
   düzeltme adımı gerçekten bir eşleşme bulup uyguladığında da artırmak — kullanıcı
   Ayarlar'da "bu düzeltme 12 kez devreye girdi" gibi somut bir sayı görebilir,
   şu anki "öğreniyor mu bilmiyorum" belirsizliğini doğrudan çözer.
4. **Test kapsamı:** Yeni deterministik adım için `TextCleaner` testlerine, en az
   "onaylanmış eşleşme metinde birebir geçiyorsa değiştirilir", "büyük/küçük harf
   farkı değiştirmeyi engellemez", "kelime sınırı olmayan kısmi eşleşme
   değiştirilmez" senaryoları eklenmeli.

**Kapsam dışı bırakılan (ayrı bir fikir, karıştırılmamalı):** Kısa ve Net modunun
ham/damıtılmış transkript farkını da bir öğrenme sinyali olarak kullanma fikri —
bu tamamen farklı bir mekanizma (öğrenilmiş sözlük değil, sözleşme kalitesi
geri bildirimi) olur; yukarıdaki plana dahil edilmedi.

---

## Düşük öncelik / karara bağlanmamış

### 3. `AppModel.swift` boyutu (880+ satır)

Coding mode, Kısa ve Net modu ve çift kısayol eklemeleri sırasında dosya sürekli
büyüdü; artık capture lifecycle, iki ayrı Codex akışı, hotkey kurulumu, tanı
kaydı, memory-pressure tepkisi ve model idle-release aynı dosyada. Önerilen
düzeltme (davranış değişikliği yok, yalnız organizasyon): dosyayı `AppModel+
Codex.swift`, `AppModel+HotKeys.swift` gibi extension dosyalarına bölmek. Karar
kullanıcıya bırakıldı, henüz uygulanmadı.
