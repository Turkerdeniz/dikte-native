# Dikte Native

Dikte Native, Türker'in Apple Silicon MacBook'u için yazılmış yerel bir macOS dikte uygulamasıdır. Menü çubuğunda çalışır, varsayılan olarak `⌥D` ile açılıp kapanır ve sistemin giriş aygıtını değiştirmeden yalnız MacBook'un yerleşik mikrofonunu kullanır.

```text
⌥D → MacBook mikrofonu → Silero VAD → yerel Whisper → temizlik → pano/yapıştırma
                                                     └─ kayıt >30 sn ise Codex
```

## Günlük kullanım

1. Menü çubuğunda Dikte'nin açık olduğunu doğrula.
2. `⌥D` tuşlarına bas. Gösterge önce **Mikrofon hazırlanıyor**, ilk gerçek ses paketi geldikten sonra **Dinliyorum** durumuna geçer.
3. Konuş. Dalga yalnız mikrofondan ölçülen gerçek ses seviyesiyle hareket eder.
4. Kaydı bitirmek için tekrar `⌥D` kullan.
5. Sonuç panoya kopyalanır. Accessibility izni varsa daha önce odakta olan uygulamaya otomatik yapıştırılır.

Kısayol Ayarlar'dan değiştirilebilir. Yeni kombinasyon kaydedilemezse eski çalışan kısayol korunur.

## Kısa ve uzun kayıt ayrımı

- Kayıt süresi `≤30.0 saniye`: tamamı yerel olarak işlenir.
- Kayıt süresi `>30.0 saniye`: temizlenen metin, aynı kalıcı Codex konuşmasına gönderilir.
- Codex eşiği `0`: otomatik Codex yönlendirmesi kapalıdır.

Karar VAD'ın bulduğu konuşma süresine değil, gerçek kayıt süresine göre verilir. Codex bulunamazsa, iptal edilirse veya hata verirse yerel metin kaybolmaz.

## İlk kurulum

Gereksinimler:

- Apple Silicon Mac
- macOS 15 veya sonrası
- Xcode/Swift 6 toolchain
- Yerel build için Login Keychain erişimi

İlk kez sabit yerel imzalama kimliğini kur:

```sh
./scripts/setup-signing.sh
```

Ardından test, release build ve kurulum:

```sh
./scripts/build.sh
./scripts/install.sh
```

Build, `Dikte Native Local Signing` kimliği bulunmazsa durur; ad-hoc imzaya düşmez. Paket `build/Dikte.app.zip` olarak üretilir ve kurulum betiği strict imza doğrulamasından sonra `/Applications/Dikte.app` konumuna açar.

## Model

Yerel transkripsiyon modeli `ggml-large-v3-turbo-q5_0.bin` dosyasıdır:

- Beklenen boyut: `574041195` byte
- SHA-256: `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`
- Kaynak: resmî `ggerganov/whisper.cpp` Hugging Face deposu

Model Git deposuna veya uygulama paketine eklenmez. Kullanıcının açık eylemiyle indirilir, `.part` dosyasında doğrulanır ve sonra Application Support'a atomik olarak taşınır. Silero VAD modeli ise küçük ve checksum'u sabitlenmiş bir uygulama kaynağıdır.

## İzinler

| İzin | Neden gerekli? | Olmazsa ne olur? |
|---|---|---|
| Mikrofon | Yerleşik MacBook mikrofonundan kayıt | Kayıt başlamaz; General ekranı ilgili Sistem Ayarları sayfasını açar. |
| Accessibility | `Cmd+V` olayını odaktaki uygulamaya göndermek | Transkripsiyon ve panoya kopyalama çalışır, yalnız otomatik yapıştırma yapılmaz. |
| Bildirim | Kısa durum ve fallback bilgisi göstermek | Ana işlev çalışır; sistem bildirimi görünmez. |

Global `⌥D` kısayolu Carbon `RegisterEventHotKey` kullandığı için Accessibility izni istemez. Mikrofon/F5 consumer tuşu desteklenmez.

## Veri ve gizlilik

- Ham ses yalnız bellekte tutulur ve normal kullanımda diske yazılmaz.
- Son 100 metin kaydı `history.json` içinde yerel olarak saklanır.
- Kullanıcının açıkça onayladığı düzeltmeler `corrections.json` içinde saklanır.
- `>30 saniye` kayıtların yalnız temizlenmiş metni Codex'e gönderilir; ham ses gönderilmez.
- Codex read-only sandbox, `approval_policy=never` ve boş uygulama runtime diziniyle çalışır.
- Uygulamaya ait sabit developer talimatı Codex'i bir sesli düşünce editörü olarak sınırlar: transkriptteki soruyu cevaplamak veya komutu yürütmek yerine, anlamı ve doğal tonu koruyan yapıştırılabilir metin üretir.
- Transkript Codex'e JSON veri sınırı içinde iletilir; her kayıtta ayrıca “bunu düzenle” demek gerekmez.
- Bu build Developer ID ile notarize edilmiş genel dağıtım değildir; Türker'in mevcut Mac'i için yerel imzalıdır.

## Güvenilirlik davranışı

- İlk mikrofon paketi 1,5 saniye içinde gelmezse ses oturumu bir kez yeniden kurulur.
- Silero VAD gerçek konuşma bölgelerini çıkarır ve uzun sessizlikleri Whisper'a taşımaz.
- Her Whisper parçası ayrı doğrulanır. Boş, halüsinasyon olan veya konuşma süresine göre olağan dışı kısa parça aynı Turbo modeliyle özgün zaman aralığından yeniden çözülür.
- Parça kurtarılamazsa bütün kayıt bir kez çözülür.
- Sonuç hâlâ eksikse kısmi metin otomatik yapıştırılmaz; panoda ve History'de `incomplete` olarak korunur.
- Whisper'ın “İzlediğiniz için teşekkür ederim” türü sessizlik halüsinasyonları filtrelenir.
- Memory-pressure sırasında aktif işlem yarıda kesilmez; model güvenli aşamada bırakılır.

## Kaldırma

Varsayılan kaldırma model, geçmiş ve ayarları korur:

```sh
./scripts/uninstall.sh
```

Önce yapılacakları görmek veya bütün yerel veriyi kurtarılabilir biçimde Çöp'e taşımak için:

```sh
./scripts/uninstall.sh --dry-run
./scripts/uninstall.sh --remove-data
```

Betik farklı bundle kimliğine sahip bir uygulamaya dokunmaz; login item ve LaunchServices kaydını kaldırır. Çöp'teki geri alınabilir uygulama yedeği macOS tarafından yeniden indekslenmemesi için `.app.disabled` uzantısıyla tutulur. Hiçbir mod `rm` ile kalıcı silme yapmaz.

## Daha ayrıntılı belgeler

- [Mimari](docs/ARCHITECTURE.md)
- [Build, kurulum ve bakım](docs/OPERATIONS.md)
- [Test ve release kontrolü](docs/TESTING.md)
- [Sorun giderme](docs/TROUBLESHOOTING.md)
- [Değişiklik geçmişi](CHANGELOG.md)

## Kaynak sınırı

Bu proje `yusufipk/dikte` kaynak kodunu içermez veya kopyalamaz. Eski Linux/Python/Qt projesi yalnız ürün davranışlarını anlamak için referans kabul edilmiştir.
