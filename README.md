# Dikte Native

Dikte Native, Türker'in Apple Silicon MacBook'u için yazılmış yerel bir macOS dikte uygulamasıdır. Menü çubuğunda çalışır, varsayılan olarak `⌥D` ile açılıp kapanır ve sistemin giriş aygıtını değiştirmeden yalnız MacBook'un yerleşik mikrofonunu kullanır.

```text
⌥D → MacBook mikrofonu → Silero VAD → yerel Whisper → temizlik → pano/yapıştırma
                                                     └─ Ham kayıt >30 sn ise Editing Codex
⌥E → MacBook mikrofonu → Silero VAD → yerel Whisper → Kısa ve Net sözleşmesi → Codex
```

## Günlük kullanım

1. Menü çubuğunda Dikte'nin açık olduğunu doğrula.
2. `⌥D` tuşlarına bas. Gösterge önce **Mikrofon hazırlanıyor**, ilk gerçek ses paketi geldikten sonra **Dinliyorum** durumuna geçer.
3. Konuş. Dalga yalnız mikrofondan ölçülen gerçek ses seviyesiyle, yumuşatılmış 30 FPS görünümde hareket eder.
4. Kaydı bitirmek için tekrar `⌥D` kullan.
5. Sonuç panoya kopyalanır. Accessibility izni varsa daha önce odakta olan uygulamaya otomatik yapıştırılır.

Konuşmanı kısaltıp netleştirmek için `⌥E` ile Kısa ve Net kaydını başlat; overlay üzerinde **Kısa ve Net modu** görünür. Tekrar `⌥E` ile durdur. Ham ve Kısa ve Net kısayolları aynı anda ya da işlem sürerken güvenli biçimde yok sayılır.

Ham kısayolu Ayarlar'dan değiştirilebilir; Kısa ve Net `⌥E` sabittir. Yeni kombinasyon kaydedilemezse eski çalışan Ham kısayolu korunur.

Kayıt göstergesi aktif macOS Space'ini ve odakta çalışılan uygulama penceresinin fiziksel ekranını otomatik izler. Ekran bilgisi alınamazsa imlecin bulunduğu ekrana düşer; bunun için Accessibility veya Screen Recording izni gerekmez.

## Kısa ve uzun kayıt ayrımı

- Ham kayıt süresi `≤30.0 saniye`: tamamı yerel olarak işlenir.
- Ham kayıt süresi `>30.0 saniye`: temizlenen metin, Ham için ayrılmış kalıcı Editing Codex konuşmasına gönderilir.
- Kısa ve Net kayıtları süre ve eşik ne olursa olsun kendi Codex konuşmasına gider; 3 saniyelik kayıt da yönlendirilir.
- Codex eşiği `0`: yalnız Ham modun otomatik yönlendirmesini kapatır; Kısa ve Net modunu kapatmaz.

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
| Mikrofon | Yerleşik MacBook mikrofonundan kayıt | Kayıt başlamaz; Ayarlar'daki General ekranı ilgili Sistem Ayarları sayfasını açar. |
| Accessibility | `Cmd+V` olayını odaktaki uygulamaya göndermek | Transkripsiyon ve panoya kopyalama çalışır, yalnız otomatik yapıştırma yapılmaz. |
| Bildirim | Kısa durum ve fallback bilgisi göstermek | Ana işlev çalışır; sistem bildirimi görünmez. |

Global `⌥D` ve sabit `⌥E` kısayolları Carbon `RegisterEventHotKey` kullandığı için Accessibility izni istemez. Mikrofon/F5 consumer tuşu desteklenmez. `⌥E` kaydedilemezse Ham `⌥D` akışı çalışmaya devam eder ve açık hata gösterilir.

## Veri ve gizlilik

- Ham ses yalnız bellekte tutulur ve normal kullanımda diske yazılmaz.
- Kullanıcı “Sonraki kaydı tanı için sakla” işlemini açıkça seçerse yalnız o kayıt 16 kHz WAV ve Whisper metadata paketi olarak `Diagnostics/` altında geçici saklanır; işaret tek kayıttan sonra kapanır.
- Son 100 metin kaydı `history.json` içinde yerel olarak saklanır.
- Kullanıcının açıkça onayladığı düzeltmeler `corrections.json` içinde saklanır.
- Ham modda `>30 saniye` kayıtların yalnız temizlenmiş metni; Kısa ve Net kayıtların ise yalnız temizlenmiş transkripti JSON veri sınırında Codex'e gönderilir. Ham ses gönderilmez.
- Codex read-only sandbox, `approval_policy=never` ve boş uygulama runtime diziniyle çalışır.
- Uygulamaya ait sabit developer talimatı Codex'i bir sesli düşünce editörü olarak sınırlar: transkriptteki soruyu cevaplamak veya komutu yürütmek yerine, anlamı ve doğal tonu koruyan yapıştırılabilir metin üretir.
- Kısa ve Net modu ayrı bir sözleşme kullanır: konuşmayı cevaplamadan kısa ve anlaşılır bir metne indirger. Her ayrı istek, karar, soru, kısıt ve özellikle olumsuz talimat ("yapma", "dokunma") korunur; dolgu, tekrar ve vazgeçilen alternatifler atılır. Kullanıcı fikir değiştirdiyse yalnız son karar yazılır. Başlık, şablon veya kod bloğu üretmez, dosya değiştirmez, komut çalıştırmaz.
- Her iki modda transkript Codex'e JSON veri sınırı içinde iletilir; Ham ve Kısa ve Net kalıcı thread kimlikleri ayrıdır.
- Bu build Developer ID ile notarize edilmiş genel dağıtım değildir; Türker'in mevcut Mac'i için yerel imzalıdır.

## Prompt araştırma rehberi

Bu bölüm Dikte’nin şu anda desteklediği bir dosya formatı listesi değildir. Prompt örnekleri, prompt türleri ve iyi yazılmış `.md` dosyaları ararken kullanabileceğin başlangıç noktasıdır. Dikte bu kaynaklardan otomatik içerik çekmez.

### Kendin arayabileceğin yerler

| Kaynak | Ne bulursun | En iyi kullanım |
|---|---|---|
| [prompts.chat](https://prompts.chat/) / [GitHub deposu](https://github.com/f/prompts.chat) | Farklı alanlardan kopyalanabilir prompt örnekleri ve `PROMPTS.md`/CSV veri seti | Hazır örnekleri karşılaştırmak |
| [Prompt Engineering Guide](https://www.promptingguide.ai/) / [GitHub deposu](https://github.com/dair-ai/Prompt-Engineering-Guide) | Teknikler, dersler, makaleler, notebook'lar, RAG ve agent konuları | “Bu prompt türü ne zaman işe yarar?” sorusu |
| [Prompt Patterns](https://www.promptpatterns.dev/patterns) | Görev, analiz, karar, structured output, planlama ve debugging gibi kategorilerde desenler | Prompt türünü seçmek ve örnekleri uyarlamak |
| [Awesome Prompting](https://github.com/corralm/awesome-prompting) | Persona, template, recipe, reflection, context control ve benzeri pattern örnekleri | Kısa pattern kataloğu taramak |
| [NirDiamant/Prompt_Engineering](https://github.com/NirDiamant/Prompt_Engineering) | Temelden ileri seviyeye 22 uygulamalı teknik ve notebook | Kodla deneyerek öğrenmek |
| [PromptSource](https://github.com/bigscience-workshop/promptsource) | Prompt oluşturma, paylaşma, template ve örnek veri üzerinde deneme | Template + input/output ilişkisini görmek |
| [Microsoft PromptKit](https://github.com/microsoft/PromptKit) | Persona, protocol, format, taxonomy ve template gibi bileşenlerle prompt kütüphanesi | Büyük prompt'ları parçalara ayırma fikri |
| [Promptfoo](https://github.com/promptfoo/promptfoo) | Prompt/agent/RAG testleri, karşılaştırma ve güvenlik değerlendirmesi | İyi görünen prompt'u ölçmek |

Bu kaynaklar aynı şeyi yapmıyor: `prompts.chat` örnek kataloğu, Prompt Engineering Guide ve `PromptSource` öğrenme/template tarafı, Prompt Patterns pattern tarafı, PromptKit modüler yapı, Promptfoo ise değerlendirme tarafı için daha uygun. Örneğin [Prompt Patterns kataloğu](https://www.promptpatterns.dev/patterns) 27 dayanıklı pattern'i kullanım amacına göre sınıflandırıyor; [Prompt Engineering Guide](https://github.com/dair-ai/Prompt-Engineering-Guide) ise rehber, makale ve uygulama kaynaklarını bir araya getiriyor.

### Gerçek `.md` dosyalarını bulmak için

GitHub’da dosya adı ve klasör yoluyla arama yapmak, genel prompt sitelerinden daha fazla gerçek proje örneği gösterir. Şu sorguları doğrudan [GitHub Code Search](https://github.com/search) alanına yapıştırabilirsin:

```text
filename:AGENTS.md
filename:CLAUDE.md
filename:prompt.md
path:prompts extension:md
path:prompts "acceptance criteria"
"system prompt" language:Markdown
"output format" "do not invent" language:Markdown
```

Ayrıca [prompt-template konusu](https://github.com/topics/prompt-template), [prompt-patterns konusu](https://github.com/topics/prompt-patterns) ve [`AGENTS.md` örnekleri](https://github.com/search?q=filename%3AAGENTS.md&type=code) üzerinden gerçek repository yapısını tarayabilirsin. `AGENTS.md` gibi dosyalar çoğunlukla repository talimatıdır; doğrudan kullanıcı görevi için tekrar çağrılan prompt arıyorsan `prompt`, `template`, `workflow`, `rubric`, `eval` ve `examples` kelimelerini birlikte ara.

### Ararken kullanabileceğin pratik prompt türleri

Bunlar tek bir resmi standart değil; aramayı daraltmak için kullanışlı etiketlerdir:

- `task / instruction`: Bir işi net biçimde yaptırma
- `rewrite / transformation`: Metni başka ton, dil veya formata dönüştürme
- `extraction / classification`: Metinden alan veya etiket çıkarma
- `structured output / JSON`: Sabit şema ile çıktı alma
- `planning / decomposition`: Büyük işi adımlara bölme
- `debugging / diagnosis`: Kanıt toplayarak hata inceleme
- `review / critique / rubric`: Çıktıyı ölçütlerle değerlendirme
- `few-shot / examples`: Örneklerle beklenen davranışı gösterme
- `meta-prompt`: Başka prompt'ları üretme veya iyileştirme
- `agent / tool-use`: Araç kullanan akışlar; özellikle yetki ve güvenlik sınırları

İyi bir `.md` prompt dosyasında en azından şu beş şeyi aramaya değer: **amaç**, **girdi**, **beklenen çıktı biçimi**, **kısıtlar** ve **örnek/evaluation**. Sadece uzun ve etkileyici görünen metni değil, hangi durumda nasıl ölçüldüğünü de karşılaştır.

### Dikte için olası yön

Bu araştırmadan çıkabilecek feature, belirli bir vendor'a bağlanmak değil; kullanıcının seçtiği prompt'ları yerel bir kütüphanede saklayıp sesli transkripti o prompt'un girdisi olarak kullanmak olur. Bu, mevcut Ham `⌥D` ve Kısa ve Net `⌥E` akışlarının yerine geçmek zorunda değildir. Önce birkaç gerçek `.md` örneği seçip ortak alanları görmek, sonra dosya sözleşmesi belirlemek daha doğru olur.

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
