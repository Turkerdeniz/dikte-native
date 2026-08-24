# Değişiklik Geçmişi

Bu dosya kullanıcıya ve bakım yapan geliştiriciye dönük önemli değişiklikleri özetler. Ayrıntılı teknik davranış için `docs/` belgelerine bak.

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
