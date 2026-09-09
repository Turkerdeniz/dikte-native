# CASE: Kayıt sessiz — mikrofon yerine hoparlör seçiliyor

**Durum:** fixed-pending-acceptance (kullanıcı kaydı henüz doğrulamadı)
**Açılış:** 9 Eylül 2026 22:12 · **Kapanış (kod):** 9 Eylül 2026 22:17

## Belirti

Dikte hiç ses almıyor. Kayıt başlıyor, hata vermiyor, sonunda "ses paketi
üretmedi" diyor. Kullanıcı ayrıca son kayıtların transkript kalitesinden
memnun değil (ayrı konu, aşağıda).

## Beklenen / gerçekleşen

Beklenen: yerleşik mikrofondan ses paketi akar.
Gerçekleşen: 0 paket, 0 örnek, peak 0, rms 0.

## Reprodüksiyon

Kullanıcının makinesinde 22:08:47'den itibaren **her** kayıtta, kendiliğinden.
İzole script'te üretilemedi — hata uygulamanın süreç durumuna bağlı.

## Ortam

- macOS 15, Apple Silicon
- Kurulu build: `de6c6407` (9 Eylül 22:02, AudioDiagnostics düzeltmesi dahil)
- `history.json` tanı kayıtları birincil kanıt

## Sınıf

system/permissions → **cihaz seçimi** (mantık hatası)

## Kanıt

`history.json`, başarısız kayıtların tamamı:

```
deviceName: 'MacBook Pro Hoparlörü' | deviceID: 'BuiltInSpeakerDevice'
paket: 0 | restartCount: 1
```

22:08:29'daki son başarılı kayıt: `deviceID: 'BuiltInMicrophoneDevice'`, 534 paket.
Sınır tam olarak o kaydın ardında.

Yeni bir süreçte yerleşik mikrofon sorunsuz: 2 saniyede 188 paket. Donanım ve
izin sağlam.

## Kök neden

`AudioRecorder.builtInMicrophone()` cihazı **yerelleştirilmiş görünen ada göre**
seçiyordu:

```swift
name.contains("macbook") && !name.contains("iphone")
```

"MacBook Pro Hoparlörü" bu koşulu geçiyor. Mikrofon discovery session'ı bir
noktada çıkış aygıtını da listelemeye başlamış ve `.devices.first` onu seçmiş.
`AVCaptureSession` hatasız başlıyor ve hiç sample buffer üretmiyor — sessiz
başarısızlık.

Ad kuralı hiçbir dilde ayırt edemez ("MacBook Pro Speakers" da geçer). Bu
7 Eylül'den önce de vardı; yeni değil, sadece tetiklendi.

## Reddedilen hipotezler

1. **VPIO teardown cihazı bırakmıyor.** Hoparlör seçimi VPIO'lu kaydın hemen
   ardından başladığı için güçlü görünüyordu. İzole deney çürüttü: eski
   teardown (yalnız `engine.stop()`) ve yeni teardown (`setVoiceProcessingEnabled
   (false)` + `reset()`) sonrası normal yakalama **ikisinde de 141 paket**.
   Buna dayanarak yazdığım teardown değişikliği geri alındı — kanıtlanmamış
   düzeltme bırakılmadı.
2. **VPIO hoparlörü mikrofon listesine sokuyor.** Ayrıca ölçüldü: VPIO öncesi,
   eski teardown sonrası ve yeni teardown sonrası cihaz listesi **üçünde de
   aynı 2 cihaz**, hoparlör yok. Çürütüldü.
3. **Mikrofon izni / donanım.** Yeni süreçte 188 paket ile çürütüldü.

VPIO'nun uygulama sürecinde hoparlörü neden listeye soktuğu **açıklanmadı**.
Düzeltme bunu zararsız hale getiriyor ama sebebi bilinmiyor.

## Düzeltme

`AudioRecorder.builtInMicrophone()`:
1. Önce sabit `BuiltInMicrophoneDevice` uniqueID'si aranır.
2. Ada göre yedek yol korunur ama artık cihazın **gerçekten giriş kanalı**
   olmasını da şart koşar (`deviceHasAudioInput`, CoreAudio
   `kAudioDevicePropertyStreamConfiguration` / input scope).

## Regresyon testi

`Tests/DikteNativeTests/MicrophoneSelectionTests.swift`:
- yerleşik mikrofonun giriş kanalı bildirdiği,
- `BuiltInSpeakerDevice`'ın reddedildiği,
- eski ad kuralının hoparlörü kabul ettiği (kusurun kendisi).

`swift test` → 115 geçti, 3 beklenen atlama.

## Runtime kabulü

**Eksik.** Build alındı, imzalandı, `73bc8d72` olarak kuruldu ve çalışıyor.
Kullanıcının gerçek bir `⌥D` kaydıyla ses geldiğini doğrulaması gerekiyor;
kaynak/build başarısı bunun yerine geçmez.

## Kalan risk / geri alma

Risk düşük: değişiklik yalnız cihaz seçimini daraltıyor. Yerleşik mikrofonun
uniqueID'si beklenenden farklı olan bir makinede ad yedeği devrede kalır, o da
artık giriş kanalı şartına bağlı. Geri alma: tek commit.

## Ayrı konu — transkript kalitesi

Kullanıcı genel kaliteden de şikâyetçi. Bu vakada **incelenmedi**; 22:08 öncesi
kayıtlar normal yoldan geliyor ve makul görünüyor (peak 0.10–0.16). Ayrı vaka
olarak ele alınmalı.
