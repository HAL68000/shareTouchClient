# ShareTouch Client (Flutter)

Client mobile nativo per Android/iOS con:
- scansione QR sessione
- connessione Socket.IO al server ShareTouch
- ricezione stream WebRTC desktop
- gesture remote control (tap, drag, pinch zoom, pan 3 dita, doppio tap 2 dita = tasto Windows)

## Requisiti
- Flutter SDK installato
- Server ShareTouch attivo (Node)

## Setup
1. Nella cartella progetto:
   - `flutter pub get`
2. Avvia app:
   - `flutter run`

## Permessi richiesti
- Camera per QR scanner
- Internet per socket/webrtc

### Android
Verifica in `android/app/src/main/AndroidManifest.xml`:
- `<uses-permission android:name="android.permission.CAMERA" />`
- `<uses-permission android:name="android.permission.INTERNET" />`

### iOS
Aggiungi in `ios/Runner/Info.plist`:
- `NSCameraUsageDescription` con testo esplicativo

## Flusso utilizzo
1. Apri app, inserisci URL server (es. `http://192.168.1.10:3000`)
2. Scansiona QR del desktop (oppure inserisci codice sessione)
3. Tocca `Connetti`
4. Controlla lo schermo condiviso con le gesture
