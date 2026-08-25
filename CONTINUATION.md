# Dikte Native — Güncel Handoff

Son doğrulama: 25 Ağustos 2026

## Mevcut durum

- Kaynak deposu: `main` dalı, private GitHub hedefi `Turkerdeniz/dikte-native`
- Kurulu bundle: `com.turkerdenizer.dikte.native`, sürüm `1.0.2 (3)`
- Repo aday build: `1.1.0 (4)`; `/Applications` üzerine kurulmadı
- Hedef: macOS 15+, yalnız ARM64
- Kurulum: `/Applications/Dikte.app`
- Model: `ggml-large-v3-turbo-q5_0.bin`, 574.041.195 byte, doğrulanmış SHA-256
- VAD: gömülü Silero `v6.2.0`, doğrulanmış SHA-256
- Varsayılan dil: Türkçe
- Varsayılan kısayol: `⌥D`
- Codex eşiği: gerçek kayıt süresi kesin olarak `>30.0 saniye`
- Codex: uygulamaya ait developer düzenleme sözleşmesi; transkript JSON veri sınırında, doğrudan yapıştırılabilir metin çıktısı
- Overlay: sol alt kompakt
- Whisper tanısı: tek kullanımlık ve varsayılan kapalı; açıkça seçilen kayıt `Diagnostics/` altında geçici WAV + metadata olarak saklanır

## Son doğrulama özeti

- Swift test paketi başarılı; performans fixture'ı yalnız açık fixture verilince çalışır.
- Gerçek 547 MB Whisper modeli Apple M5 Metal backend'ine yüklenip bırakıldı.
- ARM64 release build, strict code-sign, audio-input entitlement ve VAD checksum doğrulandı.
- Uninstall `--dry-run` ve `--remove-data --dry-run` değişiklik yapmadan doğru hedefleri gösterdi.

Kesin test sayısını burada sabitleme; güncel sayı için test çıktısını kaynak kabul et:

```sh
./scripts/build.sh
```

## Bilinen sınırlar

- Genel dağıtım/notarization yok; yerel imza yalnız bu Mac için.
- Whisper hızlı, düşük sesli veya başka insanların konuştuğu gürültülü ortamda kusursuz değildir.
- Voice Processing ve Qwen metin düzeltici bu sürümde yoktur.
- Codex gecikmesi yerel transkripsiyondan bağımsızdır ve 120 saniye timeout'a sahiptir.
- Otomatik yapıştırma Accessibility iznine bağlıdır; panoya kopyalama bağlı değildir.

## Bakım başlangıç noktası

1. Önce `git status` ve [release kontrol listesini](docs/TESTING.md) kontrol et.
2. Günlük kullanım hatasında önce History içindeki ses/parça/performance tanısını incele.
3. Crash iddiasında yeni `.ips` tarihini ve breadcrumb aşamasını doğrula.
4. Yeni özellik eklemeden önce mevcut kısa, beklemeli ve `>30 saniye` akışlarını regresyon testinden geçir.

## Ana belgeler

- [README](README.md)
- [Mimari](docs/ARCHITECTURE.md)
- [Operasyon](docs/OPERATIONS.md)
- [Test](docs/TESTING.md)
- [Sorun giderme](docs/TROUBLESHOOTING.md)
- [Değişiklik geçmişi](CHANGELOG.md)
