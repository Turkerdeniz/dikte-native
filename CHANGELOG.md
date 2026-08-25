# Değişiklik Geçmişi

Bu dosya kullanıcıya ve bakım yapan geliştiriciye dönük önemli değişiklikleri özetler. Ayrıntılı teknik davranış için `docs/` belgelerine bak.

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
