# Build, Kurulum ve Bakım

## Yerel imzalama

Uygulama yalnız bu Mac için oluşturulan `Dikte Native Local Signing` kimliğini kullanır. Özel anahtar Login Keychain'de kalır ve Git deposuna yazılmaz.

```sh
./scripts/setup-signing.sh
security find-identity -v -p codesigning | rg 'Dikte Native Local Signing'
```

`setup-signing.sh` geçici anahtar, sertifika ve PKCS#12 dosyalarını `/private/tmp` altında oluşturur; işlem sonunda geçici dizini temizler. Kimlik yoksa `build.sh` durur.

## Build

```sh
./scripts/build.sh
```

Betik sırasıyla:

1. İmzalama kimliğini doğrular.
2. ARM64 Swift test paketini çalıştırır.
3. ARM64 release executable üretir.
4. Uygulama bundle'ını geçici dizinde kurar.
5. App icon, resource bundle ve whisper.framework ekler.
6. Framework ve uygulamayı hardened runtime ile imzalar.
7. Strict code-sign, audio-input entitlement, ARM64 ve VAD checksum kontrolü yapar.
8. `build/Dikte.app.zip` üretir.

Manuel doğrulama:

```sh
ditto -x -k build/Dikte.app.zip /private/tmp/dikte-release-check
codesign --verify --deep --strict --verbose=2 /private/tmp/dikte-release-check/Dikte.app
lipo -archs /private/tmp/dikte-release-check/Dikte.app/Contents/MacOS/DikteNative
shasum -a 256 build/Dikte.app.zip
```

## Kurulum ve güncelleme

```sh
./scripts/install.sh
```

Kurulum ZIP'i doğrular, çalışan Dikte'yi sonlandırır, eski uygulamanın LaunchServices kaydını kaldırır ve eski bundle'ı `/private/tmp` altında `.disabled` yedeğe taşır. Yeni uygulamayı `/Applications/Dikte.app` konumuna kopyalar, tekrar strict imza doğrulaması yapar, LaunchServices'a kaydeder ve açar.

Güncelleme sonrasında:

```sh
codesign --verify --deep --strict /Applications/Dikte.app
mdfind 'kMDItemCFBundleIdentifier == "com.turkerdenizer.dikte.native"'
pgrep -fl '/Applications/Dikte.app/Contents/MacOS/DikteNative'
```

İlk sabit imzalı sürümde Mikrofon ve Accessibility izinleri bir kez yeniden istenebilir. Aynı kimlikle sonraki build'lerde macOS genellikle izin bağını korur.

## Geri dönüş

Private GitHub release'teki `Dikte.app.zip` ve `SHA256SUMS` aynı etikete aittir. Geri dönüş için:

1. ZIP checksum'unu doğrula.
2. Dosyayı projenin `build/Dikte.app.zip` konumuna koy.
3. `./scripts/install.sh` çalıştır.

Model ve History uygulama bundle'ından ayrı olduğu için uygulama geri dönüşünde korunur. History şeması yeni alanları opsiyonel decode eder.

## Güvenli kaldırma

Önce dry-run önerilir:

```sh
./scripts/uninstall.sh --dry-run
```

Varsayılan:

```sh
./scripts/uninstall.sh
```

Bu akış uygulamayı kapatır, kendi bakım moduyla `SMAppService.mainApp.unregister()` çalıştırır, LaunchServices kaydını kaldırır ve `.app` bundle'ını Çöp'e taşır. Model, geçmiş, düzeltmeler ve ayarlar korunur.

Tam yerel veri kaldırma:

```sh
./scripts/uninstall.sh --remove-data
```

Application Support, preferences, cache ve saved-state öğeleri benzersiz isimlerle Çöp'e taşınır. Script kalıcı `rm` kullanmaz. macOS'un TCC izin kayıtları sistem tarafından yönetilir ve varsayılan kaldırma sırasında sıfırlanmaz.

## Veri envanteri

```text
/Applications/Dikte.app
~/Library/Application Support/Dikte Native/
  Models/ggml-large-v3-turbo-q5_0.bin
  Models/ggml-large-v3-turbo-q5_0.bin.part
  history.json
  corrections.json
  active-session.json
  CodexRuntime/
~/Library/Preferences/com.turkerdenizer.dikte.native.plist
~/Library/Caches/com.turkerdenizer.dikte.native/
```

## Log ve crash inceleme

Son yaşam döngüsü ve bellek baskısı logları:

```sh
log show --last 30m --predicate 'subsystem == "com.turkerdenizer.dikte.native"' --style compact
```

Crash raporları:

```sh
ls -lt ~/Library/Logs/DiagnosticReports/DikteNative*.ips
```

Beklenmedik kapanışta `active-session.json` bir sonraki açılışta History'ye içeriksiz tanı kaydı olarak alınır ve sonra temizlenir.

## Release işlemi

1. Çalışma ağacının temiz olduğunu doğrula.
2. [Test kontrol listesini](TESTING.md) tamamla.
3. `CHANGELOG.md` güncelle.
4. Final commit'i oluştur.
5. `v1.0.0-local` annotated tag oluştur.
6. Etiketlenmiş commit'ten yeniden build al.
7. ZIP SHA-256 üret.
8. Private GitHub Release'e ZIP ve `SHA256SUMS` ekle.
