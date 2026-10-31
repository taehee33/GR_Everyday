# GR Mac — RICOH GR ↔ Mac 무선 연결 앱 (비공식)

카메라를 Wi-Fi로 붙여서 **사진을 먼저 보고, 고른 것만 Mac에 저장**하는 macOS 앱.
GR Relay(iOS)의 화면 구성을 참고했습니다.

| 화면 | 기능 |
|---|---|
| 연결 | Bluetooth로 카메라 찾기 → 카메라 Wi-Fi 자동 켜기 → Mac 자동 접속, 마지막 카메라 다시 연결 |
| 라이브러리 | 썸네일 그리드, 전체/JPG/RAW/영상/미저장 필터, 클릭 선택, 더블클릭 크게 보기(←/→, 스페이스=선택), **선택 저장**, 진행률·중지, 저장됨 표시 |
| 원격 촬영 | 라이브뷰, 화면 클릭 초점, 셔터(스페이스), 즉시/2/5/10초 타이머, 3분할 구도 가이드, 노출값 표시 |
| 카메라 설정 | 이미지 컨트롤(색감), 노출 모드·셔터·조리개·ISO·노출보정·측광·화이트밸런스, 파일 형식 |

카메라 설정 화면은 카메라가 알려주는 항목(`/v1/props`의 `xxxList`)으로 자동 구성되므로 GR IV 전용 항목도 "기타"에 나타납니다.

## 실행

```bash
./scripts/build-app.sh          # build/GR Mac.app 생성
open "build/GR Mac.app"
```

또는 Finder에서 `build/GR Mac.app`을 더블클릭. 원하면 응용 프로그램 폴더로 옮겨도 됩니다.

### 처음 연결
1. 카메라 메뉴에서 **Bluetooth 켜기**(가능하면 "켜져 있는 조건 = 항상")
2. 앱에서 **Bluetooth로 찾기** → 카메라 옆 **연결**
3. macOS가 Bluetooth 권한·페어링을 물으면 허용
4. 연결되면 라이브러리가 뜹니다. 사진을 고르고 **선택 저장** (기본 폴더 `~/Pictures/GR`, 툴바의 폴더 버튼으로 변경)

### 다시 연결 (촬영 다녀온 뒤)
1. 카메라 전원을 켭니다.
2. 휴대폰의 **GR WORLD**에서 카메라에 연결해 **WLAN(Wi-Fi)**을 켭니다.
3. GR Mac에서 **"휴대폰 GR WORLD로 WLAN(Wi-Fi) 켜고 연결"** → 저장된 암호로 카메라 Wi-Fi에 접속해 라이브러리가 열립니다.

페어링한 뒤 Mac은 Bluetooth로 카메라에 다시 붙을 수 없습니다. macOS는 페어링 때 카메라에 IRK를 넘기고
이후 공개 주소로 접속하는데, 카메라가 이 접속에 응답하지 않습니다(PacketLogger로 확인: 연결 0.19초 뒤 0x3E).
앱에서는 이 동작을 바꿀 수 없어서(서드파티 앱은 programmatic pairing 비활성), 카메라 Wi-Fi는 휴대폰이 켭니다.
페어링 직후 앱이 켜져 있는 동안은 페어링한 Bluetooth 연결로 Mac이 직접 Wi-Fi를 켭니다.

Mac이 이미 카메라 `GR_…` Wi-Fi에 붙어 있으면 **"이미 Mac이 카메라 Wi-Fi에 연결돼 있어요"**.

카메라 Wi-Fi에 붙어 있는 동안 Mac의 인터넷은 끊깁니다. **연결 끊기**를 누르면 원래 Wi-Fi로 돌아갑니다.

## 카메라 없이 개발

```bash
python3 scripts/mock_camera.py   # 가짜 카메라 http://127.0.0.1:8765
open --env GRLINK_CAMERA_URL=http://127.0.0.1:8765 "build/GR Mac.app"
```
→ "이미 Mac이 카메라 Wi-Fi에 연결돼 있어요"를 누르면 가짜 사진으로 모든 화면을 시험할 수 있습니다.

## 검증 상태

- 가짜 카메라로 라이브러리·선택 저장·라이브뷰·초점·셔터·설정 화면 동작 확인
- 실제 RICOH GR IV HDF(펌웨어 1.20)로 페어링 → WLAN 켜기 → 라이브러리, 그리고 휴대폰 GR WORLD로 WLAN을 켠 뒤 재연결을 확인했습니다.
  Bluetooth UUID와 HTTP API는 GR III/IIIx 커뮤니티 분석과 같습니다.

## 구조

```
Sources/GRLink/
  App.swift             사이드바, 연결 화면, 상태 표시
  ConnectionModel.swift 연결 흐름 (BLE → Wi-Fi → HTTP), 끊김 감시
  BLEWaker.swift        CoreBluetooth: 전원 On, Wi-Fi AP 켜기, SSID/비번 읽기
  WiFi.swift            networksetup으로 Wi-Fi 전환/복귀
  CameraAPI.swift       http://192.168.0.1/v1/* 호출
  LibraryModel/View     목록·선택·다운로드
  RemoteView.swift      라이브뷰(MJPEG)·초점·셔터·타이머
  SettingsView.swift    촬영/색감 설정
```

참고: [gr3sync](https://github.com/sotashimozono/gr3sync), [ricoh-wireless-protocol](https://github.com/CursedHardware/ricoh-wireless-protocol), [ricoh-gr-bluetooth-api](https://github.com/dm-zharov/ricoh-gr-bluetooth-api), [grCameraAnalysis](https://github.com/sky18Dragon/grCameraAnalysis)
