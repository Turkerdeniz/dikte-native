# Dikte Native — Güncel Handoff

Son doğrulama: 31 Ağustos 2026

## Mevcut durum

- Kaynak deposu: `main` dalı, private GitHub hedefi `Turkerdeniz/dikte-native`
- Kurulu bundle: `com.turkerdenizer.dikte.native`; doğrulanmış güncel Coding Dictation bundle'ı `/Applications/Dikte.app` olarak kurulu
- Repo çalışma ağacı: Coding Dictation kaynakları ve güncel release çıktısı; önceki kurulu bundle Çöp'te geri alınabilir durumda
- Hedef: macOS 15+, yalnız ARM64
- Kurulum: `/Applications/Dikte.app`
- Model: `ggml-large-v3-turbo-q5_0.bin`, 574.041.195 byte, doğrulanmış SHA-256
- VAD: gömülü Silero `v6.2.0`, doğrulanmış SHA-256
- Varsayılan dil: Türkçe
- Varsayılan kısayol: `⌥D`
- Coding mode: sabit `⌥E`; General `⌥D` akışı korunuyor
- Codex eşiği: General için gerçek kayıt süresi kesin olarak `>30.0 saniye`; Coding süre/eşik bağımsız
- Codex: General Editing ve Coding prompt compiler sözleşmeleri ayrı; iki thread kimliği ve transkript JSON veri sınırı
- Overlay: sol alt kompakt; aktif Space ve ön uygulamanın fiziksel ekranını otomatik takip eder; General turuncu, Coding kırmızı dot kullanır
- Whisper tanısı: tek kullanımlık ve varsayılan kapalı; açıkça seçilen kayıt `Diagnostics/` altında geçici WAV + metadata olarak saklanır

## Son doğrulama özeti

- Swift test paketi başarılı; son feature çalıştırmasında 78 test geçti, 2 mevcut fixture testi atlandı.
- Gerçek 547 MB Whisper modeli Apple M5 Metal backend'ine yüklenip bırakıldı.
- ARM64 release build, strict code-sign, audio-input entitlement ve VAD checksum doğrulandı.
- Güncel `/Applications/Dikte.app` ile görünür `Dikte.app` aynı ARM64 binary hash'ine sahip; runtime mikrofon testi 488 paket, RMS 0.0342, 3.3 saniye konuşma ve 0 dönüşüm hatası verdi.
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
- Hoparlör sesi/audio loopback ortamı yoksa gerçek mikrofonla `⌥D`/`⌥E` manuel QA çalıştırılmadı; bu, otomatik testlerin kapsamı dışındaki runtime doğrulamasıdır.

## Bakım başlangıç noktası

1. Önce `git status` ve [release kontrol listesini](docs/TESTING.md) kontrol et.
2. Günlük kullanım hatasında önce History içindeki ses/parça/performance tanısını incele.
3. Crash iddiasında yeni `.ips` tarihini ve breadcrumb aşamasını doğrula.
4. Yeni özellik eklemeden önce General kısa, General `>30 saniye` ve Coding kısa akışlarını regresyon testinden geçir; çapraz kısayol basışlarını da kontrol et.

## Ana belgeler

- [README](README.md)
- [Mimari](docs/ARCHITECTURE.md)
- [Operasyon](docs/OPERATIONS.md)
- [Test](docs/TESTING.md)
- [Sorun giderme](docs/TROUBLESHOOTING.md)
- [Değişiklik geçmişi](CHANGELOG.md)
