# Mimari

Bu belge Dikte Native'in ses paketinden son metne kadar izlediği yolu ve hata durumlarında hangi veriyi koruduğunu açıklar.

## Sınırlar

- Swift 6, SwiftUI/AppKit ve yalnız ARM64
- Minimum macOS 15
- Tek menü çubuğu uygulama süreci
- Python, Qt, Homebrew, ffmpeg, whisper-server, event tap ve LaunchAgent yok
- Kayıt sırasında `AVCaptureSession`; uzun kayıtta geçici `codex` alt süreci
- Ham ses için kalıcı dosya yok

## Veri akışı

```mermaid
flowchart LR
    A[Option+D · Ham] --> B[arming]
    A2[Option+E · Kısa ve Net] --> B
    B -->|ilk gerçek paket| C[recording]
    C --> D[16 kHz mono Float32]
    D --> E[Silero VAD]
    E --> F[en fazla 20 sn Whisper parçaları]
    F --> G[Turbo Whisper]
    G -->|eksik parça| H[özgün aralık retry]
    H -->|hâlâ eksik| I[bütün kayıt fallback]
    G --> J[deterministik temizlik]
    H --> J
    I --> J
    J -->|Ham · süre ≤ eşik| K[pano / otomatik yapıştırma]
    J -->|Ham · süre > eşik| L[Ham Editing Codex thread]
    J -->|Kısa ve Net · her süre| L2[Kısa ve Net Codex thread]
    L --> K
    L2 --> K
    L -->|hata / iptal / timeout| J
    L2 -->|hata / iptal / timeout| J
```

İki kısayol aynı kayıt hattını paylaşır; `CaptureMode` capture başlangıcında seçilir ve asenkron işlem boyunca değişmeden taşınır. Her iki kısayol da Ayarlar’dan bağımsız olarak değiştirilebilir (varsayılan `⌥D` / `⌥E`); ikisi aynı kombinasyona ayarlanamaz, çakışma tespit edilirse varsayılanlara döner. Başlatma yarışında, karşı modun kaydı sürerken veya `processing` aşamasında gelen kısayol yok sayılır.

## Durum makinesi

Uygulamanın tek bir ana durumu vardır:

| Durum | Anlamı | Çıkış |
|---|---|---|
| `idle` | Kayıt veya metin işi yok | Kısayol/menü ile `arming` |
| `arming` | MacBook mikrofonu bağlanıyor, ilk gerçek paket bekleniyor | Paketle `recording`; iki başarısız denemeyle `idle` |
| `recording` | Ses belleğe ekleniyor ve gerçek RMS gösteriliyor | İkinci kısayolla `processing` |
| `processing(stage)` | Ses hazırlama, VAD, Whisper, retry, temizlik, Codex veya kopyalama | Başarı/hata/iptal sonrası tek `returnToIdle()` yolu |

İlk paket gelmeden `recording` gösterilmez. Kayıt animasyonu bu nedenle oturumun açıldığına değil, mikrofondan veri geldiğine kanıttır.

## Overlay ve ekran takibi

Non-activating overlay, Core Graphics pencere listesindeki frontmost uygulama PID'si ve pencere sınırlarıyla hedef fiziksel ekranı çözer. Pencerenin çoğunluğu başka ekrana geçmeden overlay taşınmaz. Bilgi alınamazsa imleç ekranı, ardından `NSScreen.main` kullanılır. Space, uygulama ve ekran değişiklikleri olayla; pencerenin monitörler arasında sürüklenmesi yalnız overlay görünürken 250 ms aralıkla izlenir. Overlay gizlenince bütün gözlemciler ve timer durur.

Gerçek RMS sunum seviyesi 30 Hz teslim edilir; `0.55` attack, `0.25` release ve `0.01` sessizlik tabanlı filtre hem kompakt hem geniş dalgayı besler. Filtre kayıt başında ve `idle` dönüşünde sıfırlanır.

## Ses yakalama

`AudioRecorder` yerleşik MacBook mikrofonunu `AVCaptureDevice` kimliğiyle bulur. Bluetooth kulaklık veya Continuity Camera mikrofonuna sessiz fallback yapmaz ve macOS'un sistem genelindeki giriş aygıtını değiştirmez.

Mikrofonun doğal örnekleme hızı, kanal sayısı ve interleaved düzeni kabul edilir. `AVAudioConverter` sonucu 16 kHz, mono, non-interleaved Float32'ye dönüştürür. Dönüştürücü ve PCM tamponları aynı format sürdüğü sürece tekrar kullanılır. Ses callback'i uygulamaya özel seri kuyrukta; oturum başlatma/durdurma ayrı seri kuyrukta çalışır.

Tanı verisi cihaz adı/kimliği, format, callback ve örnek sayısı, RMS/peak, konuşma süresi, retry ve dönüşüm hatasını içerir. Ham örnekler tanıya yazılmaz.

## VAD ve Whisper

Gömülü `ggml-silero-v6.2.0.bin` modeli şu sabitlerle çalışır:

- eşik `0.50`
- minimum konuşma `100 ms`
- minimum sessizlik `400 ms`
- kenar dolgusu `200 ms`
- parça üst sınırı `20 saniye`
- parçalar arası yapay sessizlik `250 ms`

VAD konuşma bulamaz ve enerji de düşükse Whisper çalıştırılmaz. Belirgin enerji varsa veya VAD modeli kullanılamazsa bütün-ses fallback uygulanır.

Whisper `large-v3-turbo-q5_0`, Metal, flash attention, dört thread ve `beam_size=5` kullanır. Türkçe ayarında dil `tr` olarak sabittir. Otomatik dil yalnız ilk parçada algılanır. Parçalar arasında serbest konuşma bağlamı taşınmaz; yalnız doğrulanmış özel terimler prompt olarak verilir.

Bir parça şu durumlarda retry ister:

- sıfır token veya boş metin,
- sessizlik halüsinasyonu,
- en az iki saniye konuşmaya göre olağan dışı kısa sonuç.

Retry özgün, kesintisiz kayıt aralığında yeni decoder durumu, kesin Türkçe ve `no_speech_thold=0.35` ile yapılır. Son güvence bütün 16 kHz kaydın bir kez çözülmesidir. Kurtarılamayan eksiklik `incomplete` kaydı üretir ve otomatik yapıştırmayı engeller.

## Codex

Ham mod için yalnız `duration > threshold` olduğunda deterministik temizlenmiş metin Codex'e gider; `30.0` saniye yerel, `30.1` saniye Codex sınırıdır. Kısa ve Net modu ise süre/eşik bağımsız olarak Codex'e gider. Çalıştırılabilir dosya önce `/Applications/ChatGPT.app/Contents/Resources/codex`, sonra uygulama `PATH`'i içinde aranır.

Codex:

- yeni pencere açmadan `codex exec --json` kullanır,
- `read-only` sandbox ve `approval_policy=never` ile çalışır,
- kullanıcı config/rules dosyalarını yüklemez,
- Ham çağrısında uygulamaya ait sabit `developer_instructions` düzenleme sözleşmesini; Kısa ve Net çağrısında ayrı indirgeme sözleşmesini modele verir,
- transkripti talimat değil JSON içindeki düzenlenecek kaynak veri olarak sınırlar,
- Ham mod soru/komuta cevap vermeden yalnız yapıştırılabilir nihai düz metni üretir; Kısa ve Net modu aynı metni kısaltılmış biçimde üretir,
- Kısa ve Net sözleşmesi dosya/komut/araç kullanmaz; her ayrı talimatı ve olumsuz ifadeyi korur, vazgeçilen alternatifleri atar, şablon veya kod bloğu üretmez,
- Application Support içindeki boş `CodexRuntime` dizininde çalışır,
- `thread.started` kimliğini gelir gelmez moda ait UserDefaults anahtarına yazar,
- Ham ve Kısa ve Net sonraki çağrılarda ayrı kalıcı thread'lerini resume eder,
- 120 saniye timeout uygular.

Thread kayıpsa ilgili mod için bir kez yeni thread denenir. Her hata, timeout ve iptal temizlenmiş yerel metne düşer. Kısa ve Net thread'i Ham thread'inden bağımsızdır; yeni Kısa ve Net konuşması yalnız kendi anahtarını sıfırlar.
Sözleşmenin eklendiği ilk migrasyon eski Ham editör thread'ini bir kez temizler; ikinci thread anahtarı da feature migrasyonunda temizlenir ve sonraki açılışlarda ayrı tutulur.

## Model ve bellek yaşam döngüsü

Whisper ilk kayıtta arka planda hazırlanabilir. Tek sahibi AppModel olan idle scheduler, bütün pipeline çıkışları `returnToIdle()` yoluna ulaştıktan 120 saniye sonra modeli loglu release yoluyla bırakır; yeni kayıt timer'ı iptal eder. `MemoryPressureMonitor`, DispatchSource olaylarını bir `AsyncStream` üzerinden MainActor'a taşır:

- `idle`: warning/critical modelin hemen bırakılmasını ister.
- `arming/recording`: preload iptal edilir, ses kaydı kesilmez.
- `processing`: bırakma ertelenir ve işlem `idle` durumuna döndüğünde uygulanır.

İptal edilmiş preload sonradan `isLoaded=true` yazamaz. Shutdown ses oturumunu ve kısayolu hemen durdurur; Whisper/VAD/Codex temizliği ana thread'i senkron bekletmez.

## Kalıcı veri

| Veri | Konum | İçerik |
|---|---|---|
| Model | `~/Library/Application Support/Dikte Native/Models/` | 547 MB Whisper modeli, geçici `.part` ve doğrulama receipt'i |
| Geçmiş | `.../Dikte Native/history.json` | Son 100 metin kaydı ve tanılar |
| Düzeltmeler | `.../Dikte Native/corrections.json` | Yalnız kullanıcı onaylı eşleşmeler |
| Crash breadcrumb | `.../Dikte Native/active-session.json` | Session ID, aşama, model/bellek baskısı; içerik yok |
| Codex runtime | `.../Dikte Native/CodexRuntime/` | Uygulamaya özel geçici çalışma dizini |
| Whisper tanısı | `.../Dikte Native/Diagnostics/<capture-id>/` | Yalnız açık tek-kayıt işaretinde 16 kHz WAV ve History bağlantılı metadata |
| Ayarlar | macOS UserDefaults | Dil, Ham kısayolu, sabit Kısa ve Net `⌥E`, eşik, iki ayrı thread ID ve görünüm tercihleri |

History atomik Codable JSON olarak yazılır ve 100 kayıtla sınırlandırılır. `captureMode` alanı Ham/Kısa ve Net ayrımını taşır (kayıtlı ham değerler `general`/`coding` olarak korunur); eski History kayıtları alan yokken geriye dönük olarak okunur.
Tanı bayrağı kalıcı ayar değildir: mikrofon testi tarafından tüketilmez, ilk başlayan normal kayıtta tüketilir ve uygulama yeniden açıldığında kapalıdır. Metadata gerçek süreyi, ses tanısını, VAD bölgelerini, Whisper parçalarını ve ham/temiz/nihai metni taşır. Normal kayıt hattı tanı kapalıyken dosya veya klasör oluşturmaz.
