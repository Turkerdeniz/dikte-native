# Test ve Release Kontrolü

## Otomatik testler

Tam paket:

```sh
swift test --arch arm64 -j 1
```

Build script aynı paketi release build'den önce otomatik çalıştırır. Test grupları:

- 48/16 kHz ses dönüştürme, sessizlik kırpma ve boş ses
- Silero VAD checksum/yükleme, zaman dönüşümü, beklemeli ve 20 saniyelik parçalar
- Whisper parça kabul, halüsinasyon, retry ve dört-thread politikası
- eksik parça/bütün kayıt fallback kararları
- Türkçe ayar ve eski config migrasyonları
- Codex JSON event/thread parser
- Ham/Kısa ve Net route policy sınırı, kısayol çakışması ve capture-mode geçişleri
- Codex developer düzenleme sözleşmesi, Kısa ve Net indirgeme sözleşmesi, JSON veri sınırı ve iki ayrı thread migrasyonu
- Kısa ve Net sözleşmesinin olumsuz talimatları koruması, fikir değişikliğinde son kararı seçmesi ve şablon/kod bloğu üretmemesi
- tek kullanımlık Whisper tanı işareti, WAV süre/başlık doğrulaması, History bağlantısı ve güvenli tanı silme sınırı
- overlay boyut/konum, negatif ekran koordinatları ve ön pencerenin ekran çoğunluğu politikası
- waveform attack/release, sınırlandırma, sessizliğe dönüş ve kayıtlar arası reset
- CPU/RAM/disk tanı snapshot'ı
- memory-pressure actor köprüsü ve model bırakma politikası
- idle model release timer'ının çalışması, iptali ve yeni kayıtla değiştirilmesi
- crash breadcrumb içerik sınırı
- kaldırma bakım komutu parser'ı
- streaming model SHA-256 ve değiştirilmiş dosyayı reddeden verification receipt

Gerçek 547 MB model yükleme testi:

```sh
DIKTE_TEST_INSTALLED_MODEL=1 swift test --arch arm64 -j 1 \
  --filter WhisperEngineTests/testInstalledModelCanLoadWhenRequested
```

4/6/8 thread benchmark'ı yalnız açık test fixture'ıyla çalışır:

```sh
DIKTE_BENCHMARK_AUDIO=/absolute/path/to/fixture.wav \
  swift test --filter PerformanceBenchmarkTests
```

Normal kullanımda ham ses fixture olarak saklanmaz.

## Script ve paket kontrolleri

```sh
for script in scripts/*.sh; do zsh -n "$script"; done
./scripts/uninstall.sh --dry-run
./scripts/uninstall.sh --remove-data --dry-run
./scripts/build.sh
```

Dry-run öncesi ve sonrası `/Applications/Dikte.app` ile Application Support inode/boyutları karşılaştırılarak değişiklik yapılmadığı doğrulanır.

## Manuel işlev matrisi

| Senaryo | Beklenen sonuç |
|---|---|
| `⌥D`, 3–5 sn Türkçe | Yerel sonuç, panoya kopyalama ve izin varsa otomatik yapıştırma |
| `⌥E`, 3 sn konuşma | Süreden bağımsız Kısa ve Net modu; ayrı Codex thread'ine indirgeme isteği gönderilir |
| `⌥E` ile kayıt sürerken `⌥D` | Karşı mod kaydı başlatılmaz/durdurulmaz; aktif kayıt korunur |
| Codex işleme aşamasında `⌥D` veya `⌥E` | Kısayol yok sayılır; çalışan işlem kesilmez |
| İlk cümle, 8–12 sn sessizlik, ikinci cümle | Her iki cümle sonuçta bulunur |
| Yalnız sessizlik/müzik | Whisper çalışmaz; kısa “Ses algılanmadı” bildirimi |
| Bluetooth kulaklık bağlı | Kayıt MacBook mikrofonundan; sistem giriş/çıkış seçimi değişmez |
| `Codex`, `Whisper`, `Option D` içeren Türkçe | Doğrulanmış İngilizce terimler korunur |
| Tam `30.0 sn` | Yerel pipeline |
| `30.1 sn` ve üzeri | Kalıcı Codex thread; başarısızsa yerel fallback |
| Ham kısayolunu Kısa ve Net'in mevcut kombinasyonuyla aynı yapma denemesi | Reddedilir; her iki kısayol kendi önceki değerinde kalır |
| Boş Whisper parçası | Özgün aralıktan retry; gerekirse bütün kayıt fallback |
| Kurtarılamayan parça | Otomatik yapıştırma yok; kısmi metin panoda/History'de `incomplete` |
| Accessibility kapalı | Transkripsiyon/pano çalışır, yalnız Cmd+V yapılmaz |
| Uygulama ikinci kez açılır | İkinci süreç yerine mevcut Settings öne gelir |
| Space veya ön uygulama ekranı değişir | Overlay en geç 300 ms içinde aktif hedefe geçer; yalnız imleç hareketi normal durumda taşımaz |
| Tam ekran/Stage Manager | Overlay aktif uygulama yanında görünür kalır |
| Ekran çıkarılır | Overlay kalan ana ekrana güvenli biçimde taşınır |

Hoparlör sesi veya audio loopback gerekmez; otomatik testler sentetik/sessizlik verisiyle çalışır. Gerçek mikrofondan `⌥D` ve `⌥E` manuel testi uygun fiziksel ortam bulunduğunda yapılmalıdır.

## Crash ve bellek baskısı

Kurulu imzalı uygulamada warning/critical olayları şu aşamalarda ayrı denenir:

- idle
- arming/recording
- VAD/Whisper processing
- Codex bekleme

Kontrol:

```sh
memory_pressure -S -l warn -s 5
log show --last 10m --predicate 'subsystem == "com.turkerdenizer.dikte.native"' --style compact
ls -lt ~/Library/Logs/DiagnosticReports/DikteNative*.ips
```

Yeni `.ips`, `BUG IN CLIENT OF LIBDISPATCH`, actor isolation veya stack overflow olmamalı. Aktif Whisper işlemi bitmeli; bekleyen unload daha sonra uygulanmalı.

## Performans ölçümü

History ayrıntısı her işlemde monotonik aşama süreleri, kullanıcı/sistem CPU zamanı, başlangıç/bitiş resident ve physical footprint, disk I/O, thread sayısı ve thermal state taşır.

Hedefler:

| Ölçüm | Hedef |
|---|---|
| 60 sn idle ortalama CPU | `≤0,5%` |
| Model bırakıldıktan sonra RAM | `≤300 MB` |
| 3–5 sn sıcak stop-to-paste | `≤2 sn` |
| 30 sn stop-to-result | `≤6 sn` (Codex hariç) |
| 30 sn VAD | `≤500 ms` |
| Sağlıklı sıcak kayıtta model disk okuması | `<10 MB` |
| İşlem sonrası CPU/GPU idle dönüşü | `≤2 sn` |
| Application Support model toplamı | `<600 MB` |
| 100 kayıt History | `<1 MB` |

Anlık `%50–100 CPU`, birden fazla çekirdeğin kısa süreli kullanımıdır ve tek başına hata değildir. Karar toplam CPU zamanı, gecikme, enerji ve idle'a dönüşe göre verilir. GPU yüzdesi uygulama içinde gösterilmez; Instruments Metal System Trace kullanılır.

## Final release kapısı

- [ ] Tüm otomatik testler başarılı
- [ ] Gerçek Whisper modeli Metal ile yükleniyor
- [ ] Script syntax ve iki uninstall dry-run başarılı
- [ ] ARM64, strict signature, entitlement ve VAD checksum başarılı
- [ ] Kısa/uzun/sessiz/beklemeli manuel testler başarılı
- [ ] Kaldırma `--keep-data` veriyi koruyor
- [ ] Yeniden kurulumdan sonra tek LaunchServices kaydı var
- [ ] Yeni crash raporu yok
- [ ] Kaynak ağacında model, history, key veya sertifika yok
- [ ] README bağlantıları ve komutları çalışıyor
- [ ] Tag commit'i ile GitHub release checksum'u eşleşiyor
