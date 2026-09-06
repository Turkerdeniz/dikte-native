# Değişiklik Geçmişi

Bu dosya kullanıcıya ve bakım yapan geliştiriciye dönük önemli değişiklikleri özetler. Ayrıntılı teknik davranış için `docs/` belgelerine bak.

## Çalışma ağacı — Kısa ve Net kısayolu artık ayarlanabilir — 6 Eylül 2026

- Kısa ve Net kısayolu (`⌥E`) artık Ham kısayolu gibi Ayarlar'dan bağımsız olarak değiştirilebilir; sabit değil.
- İki kısayol aynı kombinasyona ayarlanamaz; çakışma tespit edilirse (yeni kayıt sırasında veya başlangıçta) her ikisi de varsayılanlara (`⌥D` / `⌥E`) döner.
- Bir kısayolun kaydı başarısız olursa diğeri etkilenmez ve önceki çalışan değeri korunur.
- `⌥D` akışı, route politikası ve varsayılan davranış değişmedi.

## Çalışma ağacı — Kısa ve Net modu — 6 Eylül 2026

- `⌥E` artık yapılandırılmış coding prompt üretmiyor; konuşmayı cevaplamadan kısa ve anlaşılır bir metne indirgiyor. Mod adları kullanıcı arayüzünde **Ham** (`⌥D`) ve **Kısa ve Net** (`⌥E`) olarak değişti.
- Yeni indirgeme sözleşmesi her ayrı istek, karar, soru ve kısıtla birlikte olumsuz talimatları ("yapma", "dokunma") korur; dolgu, tekrar ve vazgeçilen alternatifleri atar. Kullanıcı fikir değiştirdiyse yalnız son karar, ekleme yaptıysa iki ifade de yazılır. Başlık, şablon veya kod bloğu üretmez.
- Maksimum kayıt süresi (5 dakika) ve Codex timeout'u (120 saniye) değişmedi; kısa süre denenen 10 dakika / 240 saniye değerleri geri alındı ve kayıtlı 10 dakikalık değer migration ile 5 dakikaya indirilir.
- `⌥D` akışı, route politikası, thread ayrımı ve History geriye dönük uyumluluğu değişmedi; kayıtlı `captureMode` ham değerleri (`general`/`coding`) korundu.

## Çalışma ağacı — Coding Dictation — 31 Ağustos 2026

- Sabit `⌥E` ile mevcut General `⌥D` akışından ayrı Coding mode eklendi; General'ın süreye bağlı `>30.0 saniye` Codex yönlendirmesi korundu.
- Coding mode her kayıt süresinde ayrı kalıcı Codex thread'ine gider ve ayrı prompt compiler sözleşmesiyle yalnız yapılandırılmış nihai coding prompt üretir.
- Capture mode overlay'de metin badge'leri kaldırıldı; General turuncu, Coding kırmızı dot ile ayırt edilir. Bildirim, History ve eski kayıt/thread ayarları geriye dönük uyumludur.
- `⌥E` kaydı başarısız olursa General kısayolu çalışmaya devam eder; doğrulanmış bundle `/Applications/Dikte.app` olarak kuruldu ve eski bundle Çöp'e taşındı.

## 1.1.2-local aday — 26 Ağustos 2026

- CoreAudio seviye teslimi tek slotlu bounded kanala taşındı; MainActor görev birikmesi kaldırıldı.
- Waveform tek Canvas çizimine geçirildi ve ekran takibi tek eşzamanlı sorguyla sınırlandı.
- Whisper/VAD sıcak bekleme süresi 45 saniyeye indirildi; büyük kayıt tamponları işlem sonunda bırakılıyor.
- ggml Metal residency heartbeat devre dışı bırakıldı; Metal ve flash-attention korunuyor.
- History performans ayrıntısına görsel kuyruk, ekran sorgusu ve model süreleri eklendi.

## 1.1.1-local aday — 26 Ağustos 2026

- Kayıt/işleme overlay'i ön uygulamanın görünür penceresini izleyerek aktif fiziksel ekrana ve macOS Space'ine taşınıyor.
- Ekran çözümlemesi kullanılamazsa imleç ekranına, ardından ana ekrana güvenli fallback uygulanıyor; imleç normal durumda overlay'i peşinden sürüklemiyor.
- Overlay yalnız görünürken Space, uygulama ve ekran değişikliklerini izliyor; gizlendiğinde gözlemciler ve 250 ms takip timer'ı duruyor.
- Gerçek RMS dalgası 30 FPS'e çıkarıldı; sabit attack/release filtresi ve 60 ms doğrusal geçişle hareket yumuşatıldı.
- Bu sürüm ayrı aday build olarak hazırlanır; açık kullanıcı izni olmadan kurulu uygulamaya yüklenmez.

## 1.1.0-local aday — 25 Ağustos 2026

- İsteğe bağlı, tek kullanımlık “Sonraki kaydı tanı için sakla” akışı eklendi.
- Yalnız açıkça işaretlenen kayıt 16 kHz mono PCM WAV olarak; VAD bölgeleri, Whisper parça tanıları ve metin aşamalarıyla birlikte ayrı `Diagnostics` paketinde saklanıyor.
- Tanı kaydı History kimliğine bağlanıyor; General ve History ekranlarından görüntülenebiliyor ve tanı verileri normal geçmiş/model dosyalarına dokunmadan silinebiliyor.
- Mikrofon testi tanı işaretini tüketmiyor; normal kullanımda ham sesin diske yazılmaması davranışı korunuyor.
- Bu sürüm 25 Ağustos 2026'da `/Applications/Dikte.app` üzerine kuruldu.

## 1.0.2-local — 25 Ağustos 2026

- Codex çağrılarına yüksek öncelikli, uygulamaya ait bir sesli düşünce editörü sözleşmesi eklendi.
- Uzun diktedeki soru ve komutlar artık Codex tarafından cevaplanmak yerine, anlamı ve doğal tonu korunarak doğrudan yapıştırılabilir metne dönüştürülüyor.
- Transkript JSON veri sınırı içinde taşınıyor; kullanıcı içeriğinin düzenleme sözleşmesini bozması engelleniyor.
- Eski serbest bağlamlı kalıcı Codex thread'i migrasyon sırasında yalnız bir kez temizleniyor; yeni editör konuşması yeniden başlatmalar arasında korunuyor.
- Codex ayar ekranı etkin editör davranışını açıkça gösteriyor.

## 1.0.1-local — 24 Ağustos 2026

- Uygulama ikonu daha sade, yağmur mavisi ve gece laciverti bir tasarımla yenilendi.
- Açık mavi mikrofon ile küçük sıcak turuncu kayıt göstergesi korunarak küçük Finder önizlemesindeki okunabilirlik artırıldı.
- Görünür ikon yüzeyi tuvalin yaklaşık `%94`'üne çıkarıldı; kalın dış taşıyıcı çerçeve hissi azaltıldı.
- 16–1024 piksel AppIcon çıktılarının tamamı gerçek alpha kanalıyla yeniden üretildi.

## 1.0.0-local — 24 Ağustos 2026

### Temel uygulama

- Swift 6, SwiftUI/AppKit tabanlı ARM64 menü çubuğu uygulaması sıfırdan oluşturuldu.
- `⌥D` global aç/kapat kısayolu, kompakt gerçek RMS göstergesi ve dört sekmeli ayarlar eklendi.
- Ses her zaman MacBook'un yerleşik mikrofonundan, sistem giriş aygıtını değiştirmeden yakalanıyor.
- Mikrofonun doğal CoreAudio formatı `AVAudioConverter` ile 16 kHz mono Float32'ye dönüştürülüyor.

### Konuşma ve transkripsiyon

- Resmî whisper.cpp `v1.9.2` XCFramework ve `large-v3-turbo-q5_0` modeli sabitlendi.
- Resmî Silero `v6.2.0` VAD modeli gömüldü; uzun sessizlikler çıkarılıp konuşma en fazla 20 saniyelik parçalara ayrılıyor.
- Türkçe için beam search 5, doğrulanmış özel terim promptu ve sessizlik halüsinasyonu filtresi eklendi.
- Eksik Whisper parçaları özgün zaman aralığından tekrar çözülüyor; gerekirse bütün kayıt fallback uygulanıyor.
- Kurtarılamayan kısmi sonuç otomatik yapıştırılmıyor, panoda ve History'de korunuyor.

### Codex ve veri güvenliği

- `>30 saniye` kayıtlar aynı kalıcı Codex thread'ine gönderiliyor; kısa kayıtlar yerelde kalıyor.
- Codex read-only sandbox ve approval olmadan yalnız metin üretimi için kullanılıyor.
- Ham ses diske yazılmıyor; History son 100 kayıtla sınırlı.
- Kullanıcı düzeltmelerinden yalnız açıkça onaylanan eşleşmeler sözlüğe ekleniyor.

### Dayanıklılık ve performans

- Memory-pressure olayları actor güvenli `AsyncStream` köprüsüne taşındı.
- Aktif işlem sırasında model unload erteleniyor; idle/preload durumunda güvenli biçimde bırakılıyor.
- Normal 120 saniyelik model bırakma timer'ı AppModel'e taşındı; yeni kayıt iptal ediyor ve bütün pipeline çıkışları aynı loglu release yolunu kullanıyor.
- Crash breadcrumb yalnız session/aşama/model/bellek baskısı metadata'sı saklıyor.
- Whisper dört thread'e sabitlendi; ses tamponları yeniden kullanılıyor ve waveform 20 FPS çalışıyor.
- Model bütünlüğü sabit 4 MB streaming buffer ile doğrulanıyor; değişmeyen model sonraki açılışlarda atomik receipt üzerinden yeniden hash edilmeden kabul ediliyor.
- Pipeline aşama süreleri, CPU, RAM, disk, thread ve thermal state History tanısına eklendi.

### Dağıtım ve bakım

- Sabit `Dikte Native Local Signing` kimliği, strict code-sign, ARM64, entitlement ve VAD checksum kontrolleri eklendi.
- Veriyi varsayılan olarak koruyan, LaunchServices/login item temizliği yapan geri alınabilir uninstall akışı eklendi; Çöp yedeği çift ikon üretmemesi için `.app.disabled` tutuluyor.
- Kullanıcı, mimari, operasyon, test ve sorun giderme belgeleri oluşturuldu.

## Kaynak geçmişi notu

Bu proje eski `yusufipk/dikte` kodunu içermez. Önceki Linux/Python/Qt uygulaması yalnız davranış referansı olarak incelendi.
