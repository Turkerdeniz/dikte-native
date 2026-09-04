# Sorun Giderme

## “Ses algılanmadı”

Bu mesaj iki farklı durumu ayırır:

- `0 paket`: mikrofon oturumu hiç veri üretmedi. History'de cihaz, format ve retry bilgisi bulunur.
- Paket var fakat konuşma yok: RMS/VAD konuşma eşiğini geçmedi. Büyük tanı modalı yerine kısa bildirim gösterilir.

General > **5 sn test et** ile canlı RMS ve paket sayısını kontrol et. Dalga sessizlikte düz kalmalı, konuşurken hareket etmelidir.

## Mikrofon izni reddedildi

General ekranındaki **Sistem Ayarlarını Aç** düğmesini kullan veya:

```sh
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone'
```

Dikte görünmiyorsa imzalı `/Applications/Dikte.app` sürümünü aç, izin isteğini tekrar üret ve uygulamayı yeniden başlat.

## Sonuç panoda fakat yapışmıyor

Accessibility yalnız otomatik `Cmd+V` için gereklidir. Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik altında güncel Dikte'yi etkinleştir. İzin yokken kayıt ve panoya kopyalama yine çalışır.

## Model eksik veya bozuk

Beklenen dosya:

```text
~/Library/Application Support/Dikte Native/Models/ggml-large-v3-turbo-q5_0.bin
```

Doğrulama:

```sh
MODEL="$HOME/Library/Application Support/Dikte Native/Models/ggml-large-v3-turbo-q5_0.bin"
stat -f '%z' "$MODEL"
shasum -a 256 "$MODEL"
```

Beklenen boyut `574041195`, SHA-256 `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`. Değer farklıysa Local Model ekranından silip yeniden indir.

## Cümlenin yalnız son kısmı çıktı

History ayrıntısında VAD bölüm/parça sayısı ve her `chunkDiagnostic` kontrol edilir:

1. Ses tanısında callback ve örnek sayısı bütün kayıt boyunca artmış mı?
2. VAD ilk ve son konuşmayı ayrı bölgeler olarak bulmuş mu?
3. Her Whisper parçasında token/metin var mı?
4. Retry veya bütün-kayıt fallback çalışmış mı?

Eksik parça artık sessizce atlanmaz. Bütün fallback de başarısızsa otomatik yapıştırma durur ve bulunan metin panoda korunur.

## Hızlı veya gürültülü konuşma yanlış anlaşılıyor

Önce General dilini **Türkçe** bırak. “Codex”, “Whisper” ve proje isimleri için History > **Düzelt ve öğret** kullan. Yalnız onaylanan eşleşmeler prompt sözlüğüne girer.

Silero VAD konuşma dışı sessizlik ve gürültüyü azaltır fakat arka plandaki başka insan seslerini ayıramaz. Agresif denoise veya Apple Voice Processing bu sürümde yoktur. Bu nedenle mikrofon mesafesi ve konuşma netliği hâlâ etkilidir.

## “İzlediğiniz için teşekkür ederim” çıktı

Bu yaygın bir Whisper sessizlik halüsinasyonudur. Kısa/sessiz kayıtlarda filtrelenir ve parça retry ister. Tekrarlanırsa History'deki RMS, VAD konuşma süresi ve ham Whisper metni birlikte incelenmelidir.

## Codex uzun sürüyor veya çalışmıyor

General Codex yalnız gerçek kayıt süresi eşikten uzun olduğunda çalışır; `30.0` saniye yerel, `30.1` saniye Codex'tir. Coding mode ise eşik ve süre bağımsız olarak Codex'e gider; kısa coding kaydı için eşik ayarını değiştirmek gerekmez.

General ve Coding thread'leri ayrıdır. Coding sonucunda History/overlay üzerinde **Coding** veya **Coding mode** etiketi görünmüyorsa bu feature build'inin çalıştığını doğrula; eski kurulu bundle bu davranışı içermez.

Çalıştırılabilir dosya sırası:

1. `/Applications/ChatGPT.app/Contents/Resources/codex`
2. Dikte'nin `PATH` değerindeki `codex`

Codex timeout'u 120 saniyedir. Hata/iptal durumunda yerel metin korunur. History'deki `codexError` gerçek nedeni gösterir.

Coding prompt compiler dosya değiştirmez, komut çalıştırmaz ve kod yazmaz; yalnızca konuşmayı açık coding-agent prompt'una dönüştürür. Eksik bilgi varsa prompt içinde açıkça belirtilir.

## Beklenmedik kapanış

Önce History'deki “Beklenmedik kapanış” kaydına bak. Aşama, model durumu ve son memory-pressure seviyesi içerir; ham ses veya transkript içermez.

```sh
log show --last 30m --predicate 'subsystem == "com.turkerdenizer.dikte.native"' --style compact
ls -lt ~/Library/Logs/DiagnosticReports/DikteNative*.ips
```

Yeni `.ips` dosyasının tarihi ve stack'i güncel build ile eşleştirilmeden eski crash raporu güncel hata kabul edilmemelidir.

## Finder veya uygulama seçicide iki Dikte

Önce gerçek kayıtları listele:

```sh
mdfind 'kMDItemCFBundleIdentifier == "com.turkerdenizer.dikte.native"'
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump | rg -n 'com.turkerdenizer.dikte.native|path:.*Dikte'
```

Yalnız `/Applications/Dikte.app` varsa ikinci ikon çoğunlukla istemci uygulamanın önbelleğidir. Uygulamayı kapatıp açmak veya macOS oturumunu yenilemek yeterlidir. Eski gerçek `.app` yolu varsa önce onu Çöp'e taşı ve güncel uygulamayı tekrar kaydet:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Dikte.app
```

Sistem `DictationIM.app` Apple'ın kendi bileşenidir ve silinmemelidir.
