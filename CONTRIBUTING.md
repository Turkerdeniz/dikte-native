# Katkı rehberi

Dikte Native kişisel konuşma işler. Kod katkısından önce bilinmesi gereken tek
kural bu, ve aşağıdaki bölüm onunla ilgili.

## Kurulum

```sh
git config core.hooksPath .githooks
./scripts/setup-signing.sh
swift test
```

İlk satır bu depodaki commit kancalarını devreye alır. Git kancaları klonla
gelmez, yani bu komut çalıştırılmadan aşağıdaki korumalar çalışmaz.

## Gizlilik: depoya asla girmeyecek veriler

Bu uygulamayı kullanan herkesin diskinde kendi sesinin ve yazdıklarının izi
oluşur. Uygulama bunları `~/Library/Application Support/Dikte Native` altına
yazar, yani normalde çalışma ağacına düşmezler. Yine de bir kopya test için
depoya taşınabilir; aşağıdakiler bu yüzden yasaktır:

| Ne | Nerede oluşur |
|---|---|
| Ses kayıtları (`.wav`, `.caf`, `.m4a`, …) | `Diagnostics/`, elle alınmış kopyalar |
| Transkript geçmişi | `history.json` |
| Öğrenilmiş düzeltmeler | `corrections.json` |
| Tanı paketleri | `Diagnostics/<uuid>/` |
| Mutlak ev dizini yolları | commit'lere sızar, kullanıcı adını açık eder |

`.gitignore` bunları kapsar ve `.githooks/pre-commit` farklı bir adla ya da
`git add -f` ile eklenmiş olanları yakalar. Kanca yanlış yere karışırsa
`git commit --no-verify` ile atlanabilir — ama ne eklediğini bilerek.

## Ölçümü nasıl raporlamalı

Bu projede kararlar ölçümle veriliyor ve ölçümün kaynağı çoğu zaman gerçek
kullanım oluyor. Bulguyu yazarken **toplu sayıyı** yaz, transkripti değil:

- İyi: "3.939 kelimede eşik %22,2'sini işaretliyordu; okunan örneklemde bunların
  ancak dörtte biri gerçekten yanlıştı."
- Kötü: konuşmacının cümlelerini birebir alıntılamak.

Bir örneğe gerçekten ihtiyaç varsa (bir tanıma hatasının biçimini göstermek
gibi) tek kelimelik, bağlamsız ve kimseyi tanımlamayan bir parça yeterlidir.
Aynısı commit mesajları ve test fixture'ları için de geçerli — ikisi de
`.gitignore` ile korunamaz ve kalıcıdır.

Ölçüm defterleri (`TODO.md`, `CONTINUATION.md`) bu yüzden depoda tutulmuyor;
ham alıntı taşıdıkları için yerelde kalıyorlar.

## Ölçmeden önce birimi doğrula

Ölçümle karar vermenin en sinsi tuzağı yanlış okuma değil, **doğru okunan
sayının yanlış birimde olması**. Sonuç ikna edici çıkar, tutarlı görünür ve
kendini ele vermez.

Bu depoda bir kez oldu. `chunkDiagnostics.sourceStart` saniye cinsinden
saklanıyor; örnek sayısı sanılıp 16.000'e bölündü. 0,485 saniye böylece
0,00003 oldu ve bütün kayıtlar "konuşma kaydın ilk anında başlıyor" gibi
göründü. Buradan çıkan teşhis — sesin baştan kırpıldığı — kendi içinde
tutarlıydı ve var olmayan bir sorun için bir düzeltme yazılmasına ramak
kalmıştı. Doğru birimle bakıldığında medyan 0,485 saniyeydi ve aranan
ilişkinin korelasyonu r = −0,001 çıktı: etki yoktu.

Bir alandan sonuç çıkarmadan önce birimini **ikinci bir kaynaktan** doğrula:

- alanı yazan koda bak (`SpeechSegmenter`, `AudioRecorder`, `CoreTypes`),
- ya da `Diagnostics/` altındaki metadata gibi aynı değeri başka biçimde
  gösteren bir çıktıyla karşılaştır,
- ya da en azından makullük sınırını uygula: birkaç saniyelik bir kayıtta
  0,00003 saniyelik bir başlangıç değeri bir ölçüm değil, bir birim hatasıdır.

Aynısı milisaniye/saniye, örnek/saniye, byte/örnek ve olasılık/yüzde çiftleri
için de geçerli. Bir bulgu şaşırtıcıysa, önce birimden şüphelen.

## Çalışma biçimi

- Küçük değişiklik → doğrula → diff'i incele → commit.
- İddia kanıtla desteklenmeli. Derlemenin ve testin geçmesi görsel, ses veya
  performans davranışının doğrulandığı anlamına gelmez; bunlar kurulu
  uygulamada kontrol edilir.
- Commit öncesi `swift test`, ardından `./scripts/build.sh`. Ayrıntılı sürüm
  kontrol listesi [docs/TESTING.md](docs/TESTING.md) içinde.
- Commit mesajı ne yapıldığını değil **neden** yapıldığını anlatmalı; sayısal
  bir bulgu varsa oraya yazılır.

## Belgeler

- [Mimari](docs/ARCHITECTURE.md)
- [Operasyon](docs/OPERATIONS.md)
- [Test](docs/TESTING.md)
- [Sorun giderme](docs/TROUBLESHOOTING.md)
