# Yapılacaklar

Bu dosya, üzerinde durulmuş ama henüz tamamlanmamış işleri — bloklanmış denemeler ve
tanımlanmış-ama-uygulanmamış planlar — kaybolmadan takip etmek için var. Kod
değişikliği burada anlatılmaz; ilgili kaynak dosyalar ve (varsa) `git stash`
girdisi referans verilir.

## Karar bekleyen

### 1. Gürültü bastırma: kanıt zayıf, kapalı kalıyor — 7 Eylül 2026

**Önceki kayıt düzeltildi.** Bu bölümde daha önce "gürültü tabanını %55 düşürüyor"
yazıyordu; o sayılar hatalıydı. A/B çiftinin her iki kaydında da `noiseFloor` ve
`speechThreshold` alanları **0**, yani hiç kaydedilmemiş (bkz. madde 2). Gürültü
tabanı hakkında elimizde veri yok.

Aynı gürültülü ortam, 19 saniye arayla aynı cümle. Gerçekten ölçülen:

| | Açık | Kapalı |
|---|---|---|
| Turbo güveni | 0.759 | 0.796 |
| Zayıf token oranı | 0.140 | 0.162 |
| peakLevel | 0.867 | 0.131 |
| rmsLevel | 0.0632 | 0.0183 |

**Metin farkı (asıl kanıt):** "güncel uygulamayı kullanmıyorum" açıkken "güncel
uygulama yapıyorum", kapalıyken doğru. "kapatış yapmanı" açıkken "tabataç
yapmanı", kapalıyken doğru.

**Gözlem:** VPIO seviyeyi ~3.5 kat yükseltmiş (rms 0.018 → 0.063). Bu kendi AGC'si.
Agresif kazanç artı telefon görüşmesi için ayarlanmış gürültü bastırmanın Whisper'ın
güvendiği yapıyı bozması makul bir açıklama, ama doğrulanmadı.

**Sınır:** Tek çift. Güven farkı küçük, tek başına anlamlı değil. İkna edici olan
metin farkı, o da n=1. "Gürültüyü azaltıyor" iddiasını destekleyecek hiçbir
ölçümümüz yok.

**Karar:** Deneysel ve varsayılan kapalı kalıyor. Madde 2 çözülmeden yeni ölçüm
yapmak anlamsız — önce tanı alanlarının neden yazılmadığı bulunmalı.

### 2. Tanı alanları her kayıtta yazılmıyor olabilir — 7 Eylül 2026

17:25:54'te kurulan build'den **önceki** tüm kayıtlarda `noiseFloor` ve
`speechThreshold` 0; o andan sonraki kayıtlarda dolu. Sınır tam olarak kurulum anı,
yani alanları yazan kod o ana kadar çalışan binary'de yoktu — oysa aynı kayıtlar
"Voice Processing I/O" formatı gösteriyor, yani VPIO'lu bir build'di. Çelişki
çözülmedi.

**Önemi:** Madde 1'deki gürültü tabanı karşılaştırması bu yüzden yapılamadı ve
bir ara yanlış raporlandı. Tanı verisine güvenilmeden önce bu çözülmeli.

---

## Uygulandı

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
