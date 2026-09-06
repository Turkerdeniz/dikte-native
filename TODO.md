# Yapılacaklar

Bu dosya, üzerinde durulmuş ama henüz tamamlanmamış işleri — bloklanmış denemeler ve
tanımlanmış-ama-uygulanmamış planlar — kaybolmadan takip etmek için var. Kod
değişikliği burada anlatılmaz; ilgili kaynak dosyalar ve (varsa) `git stash`
girdisi referans verilir.

## Bloklanmış

### 1. Gürültü bastırma (Voice Processing I/O) — 6 Eylül 2026

**Durum:** Bloklandı, tekrar bakılacak. Kurulu uygulamaya hiçbir şey yansımadı;
tüm deneme `git stash` içinde duruyor, ana daldan (main) hiç commit edilmedi.

**Hedef:** macOS'un Voice Processing I/O'sunu (`AVAudioEngine` + `AVAudioInputNode.
setVoiceProcessingEnabled(true)`) kullanarak isteğe bağlı, varsayılan kapalı bir
gürültü bastırma seçeneği eklemek — mevcut `AVCaptureSession` tabanlı yakalama
yoluna dokunmadan, ayrı bir sürücü olarak.

**Neden zor:** Uygulamanın temel sözü "sistem giriş aygıtını değiştirmeden yalnız
MacBook'un yerleşik mikrofonunu kullanmak." `AVAudioEngine`'in `inputNode`'u
varsayılan olarak sistemin *o anki varsayılan giriş aygıtını* kullanır (AirPods
bağlıysa onu kullanabilir) — bu yüzden cihazı built-in mikrofona **sabitlemek**
zorunlu, isteğe bağlı bir iyileştirme değil.

**Bulgular (standalone Swift script'lerle, gerçek donanımda tekrarlanabilir
şekilde doğrulandı — kod tabanına hiç girmedi):**

1. VPIO gerçek ses veriyor, çökmüyor — `setVoiceProcessingEnabled(true)` çalışıyor.
2. Bu Mac'in mikrofon dizisi VPIO altında **9 kanal, 48 kHz ham veri** olarak
   görünüyor (beklenen tek kanal beamformed çıktı değil). Muhtemelen çoklu-mikrofon
   dizisinin ham elemanları.
3. `installTap`'a doğrudan farklı bir kanal sayısıyla format istemek,
   `AVAudioEngine`'in kendi downmix'ini yapmasını sağlıyor — **izole çalıştığında**
   gerçek, geçerli tek kanallı ses veriyor (doğrulandı: `maxPeak` makul, format
   doğru).
4. `installTap`'a doğrudan hedef 16 kHz'i istemek (resample + downmix birlikte)
   engine başlatmayı **başarısız kılıyor** (`kAUInitialize`, durum -10875). VPIO
   kendi donanım hızında (48 kHz) sabit; resample ayrı bir adım (`AVAudioConverter`)
   olarak yapılmalı.
5. **Asıl blokaj:** cihazı built-in mikrofona sabitlemek (`AudioUnitSetProperty`,
   `kAudioOutputUnitProperty_CurrentDevice`) **ile** mono-downmix `installTap`
   birlikte istendiğinde, engine yine `kAUInitialize` (-10875) hatasıyla
   başlamıyor. Bu **iki kez, izole bir script'te tekrar üretildi** — rastgele
   bir arıza değil, gerçek bir uyumsuzluk. Pinleme tek başına çalışıyor
   (`kAudioOutputUnitProperty_CurrentDevice` başarıyla dönüyor); downmix tek
   başına çalışıyor; ikisi birlikte istendiğinde engine başlamıyor.

**Denenmiş ama kod tabanına girmemiş çözüm:** `git stash list` içinde
`"blocked: VPIO noise suppression - device pin + downmix tap fails kAUInitialize
(-10875)"` mesajıyla duruyor. İçerik: `AppSettings.swift`'e `noiseSuppression`
ayarı, `AudioRecorder.swift`'e `VoiceProcessingCaptureDriver` + `audioDeviceID
(forUniqueID:)` yardımcı fonksiyonu, `SettingsView.swift`'e toggle,
`AppModel.swift`'te `settings.noiseSuppression`'ın `recorder.start`'a
geçirilmesi, ve gerçek donanıma karşı çalışan (varsayılan atlanan, `DIKTE_TEST_
NOISE_SUPPRESSION=1` ile açılan) `Tests/DikteNativeTests/
NoiseSuppressionCaptureTests.swift`. Bu stash `git stash apply stash@{0}` (veya
güncel indeksi kontrol edip doğru numarayla) ile geri getirilebilir — ama şu an
**çalışmıyor**, doğrudan üzerine inşa edilmemeli.

**Sonraki adım için olası yönler (denenmedi):**
- `AVAudioEngine.inputNode` yerine ham `AudioComponentInstance`/AUGraph ile VPIO'yu
  manuel kurmak — daha fazla kontrol, ama gerçek bir yeniden yazım.
- Sıralamayı değiştirmek: cihazı `setVoiceProcessingEnabled(true)`'dan **önce**
  pinlemeyi denemek (şu ana kadar hep VPIO açıldıktan sonra pinlendi).
  `kAudioUnitProperty_StreamFormat`'ı `installTap` üzerinden değil doğrudan
  `AudioUnitSetProperty` ile ayarlamayı denemek.
- Apple'ın VPIO + özel cihaz seçimi için resmi örnek kod/dokümantasyonuna
  bakmak (bu konuda güncel bir referans bulunamadı, muhtemelen az belgelenmiş
  bir macOS köşesi).

---

## Uygulandı

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
