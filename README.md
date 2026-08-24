# Dikte Native

Apple Silicon için sıfırdan yazılmış, menü çubuğunda çalışan yerel macOS dikte uygulaması.

## Akış

`⌥D → MacBook mikrofonu → yerel whisper.cpp → yerel temizlik → panoya kopyala/yapıştır`

Kayıt süresi ayarlanan eşikten **kesin olarak uzunsa** (varsayılan `>30.0 sn`) temizlenmiş metin, yeni pencere açmadan aynı kalıcı Codex konuşmasına gönderilir. Codex bulunamazsa, iptal olursa veya hata verirse yerel metin korunur.

## Teknik sınırlar

- macOS 15+, yalnız ARM64
- Swift 6, SwiftUI/AppKit, AVCapture + AVAudioConverter
- Resmî `whisper.cpp v1.9.2` XCFramework (manifestte URL + checksum sabit)
- Model: `ggml-large-v3-turbo-q5_0.bin`, resmî Hugging Face kaynağı + SHA-256 doğrulama
- Python, Qt, Homebrew, ffmpeg, whisper-server, event tap ve LaunchAgent yok
- Accessibility yalnız otomatik `Cmd+V` için kullanılır
- Ses diske yazılmaz; geçmiş en fazla 100 metin kaydıdır
- Eksik veya olağan dışı kısa Whisper parçaları aynı Turbo modelinde özgün zaman aralığıyla yeniden çözülür
- Kayıt göstergesi varsayılan olarak sol altta kompakt çalışır; eski geniş üst görünüm Ayarlar'dan seçilebilir
- Tek Turbo modeli son kullanımdan 120 saniye sonra veya bellek baskısında bırakılır

## Kayıt güvenilirliği

Dikte yalnız MacBook’un yerleşik mikrofonunu cihaz kimliğiyle seçer ve sistemin varsayılan girişini değiştirmez. İlk gerçek ses paketi gelmeden kayıt başlamış sayılmaz. Paket gelmezse oturum bir kez yeniden kurulur; hata sürerse cihaz formatı ve paket sayısı History içinde tanı olarak saklanır.

General ekranındaki **5 sn test et** düğmesi transkripsiyon yapmadan gerçek mikrofon paketlerini ve seviyesini doğrular.

Her Whisper parçası ayrı doğrulanır. Bir parça boş dönerse aynı Turbo modeliyle yeniden denenir ve gerekirse bütün kayıt fallback'i çalışır. Eksiklik kurtarılamazsa kısmi metin otomatik yapıştırılmaz; panoda ve History'de korunur.

## Build ve kurulum

İlk kez sabit yerel imzalama kimliğini oluştur:

```sh
./scripts/setup-signing.sh
```

Ardından:

```sh
./scripts/build.sh
./scripts/install.sh
```

Build, `Dikte Native Local Signing` kimliği bulunmazsa durur; ad-hoc imzaya düşmez. İmzalı uygulama, Desktop File Provider metadata’sından korunmak için `build/Dikte.app.zip` olarak üretilir; kurulum betiği bunu `/Applications/Dikte.app` konumuna açar.

## Kaynak sınırı

Bu proje `yusufipk/dikte` kaynak kodunu içermez veya kopyalamaz. Eski proje yalnız ürün davranışlarını anlamak için referans kabul edilmiştir.
