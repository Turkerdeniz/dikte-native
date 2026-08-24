# Dikte Native — Devam Notu

Son güncelleme: 23 Ağustos 2026

## Tamamlananlar

- Sıfırdan Swift 6 / SwiftUI / AppKit proje oluşturuldu; eski GPL/Python/Qt kodu kopyalanmadı.
- Resmî `whisper.cpp v1.9.2` XCFramework URL ve checksum ile sabitlendi.
- Native menü çubuğu, dört sekmeli ayarlar, `Option+D` Carbon hotkey, AVAudioEngine bellek kaydı, deterministik temizlik, pano/yapıştırma, son 100 geçmiş kaydı ve native login item yazıldı.
- `duration > threshold` kuralı testli; `30.0` yerel, `30.1` Codex.
- Codex salt-okunur/geçici runtime, kalıcı thread ID, canlı JSON event parser, timeout/cancel/error fallback ve kayıp thread için tek retry yazıldı.
- Sabit `Dikte Native Local Signing` sertifikası Login Keychain’e kuruldu.
- ARM64 release build, embedded framework rpath, hardened runtime entitlement ve strict code-sign doğrulaması tamamlandı.
- Paket: `build/Dikte.app.zip`; kurulum: `scripts/install.sh`.
- Son test turunda 4/4 unit test geçti.

## Güncel çalışma durumu

- Otomatik ilk-açılış ve ilk-kayıt model indirmesi kapalı kalıyor; indirme yalnız açık kullanıcı eylemiyle başlıyor.
- Kullanıcının açık izniyle `ggml-large-v3-turbo-q5_0.bin` indirildi.
- Model boyutu `574041195`, SHA-256 değeri `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`; resmî metadata ile eşleşiyor.
- Gerçek entegrasyon testinde model Apple M5 Metal backend’e başarıyla yüklendi ve bırakıldı.
- Mikrofon izni uyarısının modelle ilgisiz olduğu doğrulandı. General ekranına izin durumu ve Mikrofon Sistem Ayarları düğmesi eklendi.
- Son release `/Applications/Dikte.app` altında kurulu, strict imza doğrulaması geçti ve tek süreç olarak çalışıyor.

## Bir sonraki oturumda ilk işler

1. Kullanıcı macOS Mikrofon gizlilik ayarından Dikte’ye izin versin ve uygulamayı yeniden açsın.
2. Gerçek Türkçe sesle kısa kayıt → transkripsiyon → pano/yapıştırma uçtan uca test edilsin.
3. 30 saniyeden uzun gerçek kayıtla Codex kalıcı thread ve fallback uçtan uca doğrulansın.
4. Finder’dan tekrar açıldığında Ayarlar penceresinin görünmesi kullanıcıyla görsel olarak kontrol edilsin.

## Bilinen önemli ayrıntılar

- Kurulu son binary kapanmadan önce `/Applications/Dikte.app` altında stabil çalışıyordu; PID kontrolü geçti.
- Eski kurulumlar update sırasında Trash’e taşındı; kalıcı silme yapılmadı.
- Desktop File Provider `.app` imzasına Finder metadata eklediği için build geçici dizinde imzalanıp ZIP olarak saklanıyor.
- Self-signed sertifikanın Team ID’si olmadığı için yalnız embedded `whisper.framework` yüklemeye yönelik `disable-library-validation` entitlement kullanılıyor.
# 23 Ağustos 2026 — Güvenilir kayıt ve yerel temizleme

- MacBook mikrofonu doğal formatta yakalanıp `AVAudioConverter` ile 16 kHz mono Float32'ye dönüştürülüyor.
- İlk paket için 1,5 saniye bekleniyor; başarısızlıkta bir otomatik yeniden deneme var.
- General ekranındaki 5 saniyelik canlı test gerçek cihazda doğrulandı: 48 kHz, mono, non-interleaved, 353 callback, sıfır dönüşüm hatası.
- Whisper beam search 5, sessizlik kırpma, kısa sessizlik halüsinasyonu filtresi ve doğrulanmış terim promptu kullanıyor.
- Eski `0.1` Codex eşiği bir defalık migrasyonla `30.0` saniyeye dönüyor; `0` kapalı kalıyor.
- Kullanılmayan Qwen modeli, llama.cpp bağımlılığı ve yardımcı süreç projeden tamamen kaldırıldı.
- History ham Whisper, deterministik metin, yerel sonuç, Codex sonucu ve ses tanısını ayrı tutuyor. “Düzelt ve öğret” yalnız onaylanan eşleşmeleri sözlüğe ekliyor.
- 15 test geçiyor; kurulu Whisper modeli Apple M5 Metal bağlamıyla yükleme testini geçti.

## 23 Ağustos 2026 — Silero VAD ve uzun bekleme düzeltmesi

- Resmî `ggml-silero-v6.2.0.bin` (885.098 bayt) uygulamaya gömüldü; SHA-256 değeri `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987`.
- VAD her kayıtta çalışıyor: eşik 0,50; minimum konuşma 100 ms; minimum sessizlik 400 ms; kenar dolgusu 200 ms.
- Uzun sessizlikler çıkarılıp konuşma bölümleri 250 ms ayraçlarla en fazla 20 saniyelik Whisper parçalarına dönüştürülüyor.
- Otomatik dil algılama yalnız ilk Whisper parçasında yapılıyor; parça bindirmelerindeki tekrarlar birleştirme sırasında ayıklanıyor.
- VAD eksik/bozuksa veya ses enerjisine rağmen konuşma bulamazsa mevcut enerji tabanlı bütün-ses yolu kullanılıyor.
- History artık VAD bölüm/parça sayısını, algılanan konuşma süresini ve fallback nedenini gösteriyor; eski JSON kayıtları varsayılan değerlerle okunuyor.
- Qwen model dosyası kullanıcı isteğiyle silindi.
- 24 test geçiyor; gömülü VAD modelinin yüklenmesi/sessizliği reddetmesi ve kurulu Whisper modelinin Metal yüklemesi ayrıca doğrulandı.
- Overlay “Üst” konumunda güvenli ekran alanının 4 puan altına taşındı; böylece uygulamaların üst kontrol satırını daha az kapatıyor.
- Standalone whisper.cpp VAD sınırlarının `Float` olmasına rağmen saniye değil santisaniye taşıdığı doğrulandı; örnek indeks dönüşümü `/100` ile düzeltildi. Önceki build kısa kayıtlarda fallback'e düşüyor, uzun kayıtta ise neredeyse tüm sesi VAD parçası sayıyordu.

## 23 Ağustos 2026 — Hızlı konuşma için ikinci Whisper geçişi

- `ggml-large-v3-q5_0.bin` (1.081.140.203 bayt) indirildi ve SHA-256 `d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1` ile doğrulandı.
- İlk geçişte hızlı `large-v3-turbo-q5_0` korunuyor.
- Ortalama token güveni `%64` altındaysa veya konuşma hızı saniyede `3,2` kelimeyi aşıyorsa güçlü modelle ikinci geçiş yapılıyor.
- Güçlü modelin sonucu belirgin biçimde daha düşük güvenliyse Turbo sonucu korunuyor.
- Aynı anda yalnız tek Whisper bağlamı bellekte tutuluyor; model değişiminde önceki bağlam bırakılıyor.
- History iki modelin metnini, güven puanlarını ve ikinci geçiş nedenini ayrı gösteriyor.
- Her iki model Apple M5 Metal bağlamında başarıyla yüklenip bırakıldı; test paketi 28/28 geçti.

## 23 Ağustos 2026 — Çoklu güven kararı ve kompakt gösterge

- İkinci geçiş artık ortalama güven, zayıf token oranı, kelime/sn ve boşluksuz karakter/sn sinyallerini birlikte kullanıyor.
- Başlangıç eşikleri: `%64` ortalama güven, `%20` zayıf token, `2,5 kelime/sn`, `12,5 karakter/sn`.
- Kullanıcının `%91` güvenle yanlış çözülen gerçek hızlı Türkçe örneği regresyon testine eklendi ve ikinci geçişi tetikliyor.
- Large v3 sonucu; sayı koruma, doğrulanmış terimler, uzunluk, metin benzerliği ve model güveni kontrollerinden geçmeden seçilmiyor.
- History tetikleme nedenlerini, iki hız ölçüsünü, zayıf token oranını, seçilen modeli ve seçim nedenini gösteriyor.
- Overlay varsayılan olarak `286 × 46 pt` kompakt panel ve imlecin bulunduğu ekranın sol alt köşesinde açılıyor.
- Kompakt panel gerçek RMS dalgası, sayaç ve durdurma düğmesini koruyor; eski geniş üst görünüm Ayarlar'da seçenek olarak kalıyor.

## 23 Ağustos 2026 — Eksik parça kurtarma ve performans ölçümü

- Önceki `large-v3-q5_0` ikinci model hattı kaldırıldı; eski History alanları yalnız geriye uyumluluk için okunuyor.
- Her VAD/Whisper parçası ayrı doğrulanıyor. Boş veya olağan dışı kısa parça, özgün kesintisiz ses aralığıyla aynı Turbo modelinde Türkçe yeniden çözülüyor.
- Parça retry başarısızsa bütün kayıt fallback'i çalışıyor. O da başarısızsa kısmi metin otomatik yapıştırılmıyor; panoda `incomplete` History kaydıyla korunuyor.
- History parça metinlerini, retry nedenini ve sürelerini; ayrıca CPU zamanı, bellek, disk I/O, thread, termal durum ve pipeline aşamalarını gösteriyor.
- Türkçe 18,1 saniyelik fixture ölçümünde: 4 thread `772 ms / 216 ms CPU`, 6 thread `745 ms / 231 ms CPU`, 8 thread `758 ms / 238 ms CPU`. `%10` gecikme sınırı içinde en düşük CPU zamanı nedeniyle 4 thread seçildi.
- Turbo model sıcak bekleme süresi 120 saniyeye çıkarıldı ve bellek baskısında anında bırakma eklendi.
