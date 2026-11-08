# GR Everyday — RICOH GR ↔ Mac·iPhone 연결 앱 (비공식)

(이전 이름: GR Mac / GR Connect)

카메라를 Wi-Fi로 붙여서 **사진을 먼저 보고, 고른 것만 Mac에 저장**하는 macOS 앱.
GR Relay(iOS)의 화면 구성을 참고했습니다.

| 화면 | 기능 |
|---|---|
| 카메라 | Bluetooth로 카메라 찾기 → 카메라 Wi-Fi 자동 켜기 → Mac 자동 접속, 다시 연결, USB 연결. 카메라마다 사진 지정(기본은 코드로 그린 GR, 이미지를 끌어다 놓거나 관리 → 카메라 사진 바꾸기) |
| 라이브러리 | 라이트룸식 그리드(G)·확대 보기(E, 필름스트립·히스토그램·촬영 정보)·편집(D). 클릭/⌘/⇧ 선택, 드래그 영역 선택, 별점, 동영상 재생, Tab/⇧Tab/F로 패널 숨김·가득찬 화면·전체화면, **선택 저장**, 촬영 정보(노출 모드·이미지 컨트롤·비율·크롭·HDF)로 거르기. 카메라가 없어도 마지막으로 본 카드의 목록·썸네일을 볼 수 있음(사진 650장에 수 MB) |
| 편집 | 저장한 사진만(원본 유지): 노출·대비·하이라이트·섀도·색온도·색조·생동감·채도·선명도(Apple Core Image 기본 필터, 카메라 처리와 다름), 자르기(비율 고정)·회전·반전·수평, 원본과 비교, 실행 취소, 설정 복사·붙여넣기, **다른 이름으로 저장**(JPEG/HEIC/TIFF/PNG). 촬영 때 이미지 컨트롤을 메이커노트에서 읽어 표시(ExifTool 표에 있는 코드만 이름 표시) |
| 원격 촬영 | 라이브뷰, 화면 클릭 초점, 셔터(스페이스), 즉시/2/5/10초 타이머, 3분할 구도 가이드, 노출값 표시 |
| 촬영 통계 | GR WORLD의 GR 로그처럼 달력·촬영 횟수, 노출 모드(P/Av/Tv/Sn/M)·이미지 컨트롤·화상비율·크롭·HDF별 장수(날/전체). 줄이나 숫자를 누르면 라이브러리에서 그 사진만 표시. 카드에서 지운 사진도 기록에 남아 따로 표시(흐린 +숫자, ‘카드에 있는 사진만’으로 전환 가능) |
| 설정 | 저장 폴더·날짜별 폴더, **새 사진 자동 저장**(기본 꺼짐, 파일 종류 JPG/RAW/동영상·연결 방식 USB/Wi-Fi 선택), 조작, 캐시 |
| 카메라 설정 | 이미지 컨트롤(색감), 노출 모드·셔터·조리개·ISO·노출보정·측광·화이트밸런스, 파일 형식 |

카메라 설정 화면은 카메라가 알려주는 항목(`/v1/props`의 `xxxList`)으로 자동 구성되므로 GR IV 전용 항목도 "기타"에 나타납니다.

### 촬영 통계는 어떻게 세나
- 사진마다 원본의 앞 64KB만 한 번 읽어(EXIF·메이커노트) 캐시에 둡니다. 라이브러리를 열면 새 사진만 읽습니다.
- 노출 모드는 EXIF `ExposureProgram`(P 2, Av 3, Tv 4; M은 1로 가정, 아직 미확인). **Sn은 EXIF로는 P와 같고** 메이커노트 0x0033이 `[0, 32, 1]`인 것으로 구분합니다.
  크롭은 35mm 환산 초점거리(28 꺼짐 / 35 / 50). GR IV HDF 펌웨어 1.20에서 시험 촬영으로 확인했고, 합계가 GR 로그와 같았습니다(사진 235·동영상 5).
  M·B·T·BT로 찍은 사진은 아직 확인하지 않았고, M 외에는 "기타 (코드)"로 나옵니다.
- GR Mac이 한 번 본 사진은 앱 데이터 폴더(`~/Library/Containers/com.hantaehee.greveryday/Data/Library/Application Support/GR Mac/shot-history.json`)에 남아, 카드에서 지운 뒤에도 셉니다.
  그 전에 지운 사진은 GR 로그에만 있습니다. 파일 이름과 촬영 시각으로 구분하므로 카드를 포맷해 이름이 다시 쓰여도 섞이지 않습니다.
- 썸네일·날짜·통계 캐시는 파일 이름으로 저장됩니다. 연결할 때 가장 최근 파일의 촬영 시각을 확인해, 이름이 다시 쓰였으면 캐시를 저절로 비웁니다.

## 실행

```bash
./scripts/build-app.sh          # Xcode로 빌드해 /Applications/GR Everyday.app에 설치 (샌드박스)
open "/Applications/GR Everyday.app"
```

Xcode에서 `GR Mac.xcodeproj`를 열어 실행해도 됩니다. App Store에 올릴 때는 Product → Archive.
앱은 App Store 샌드박스 안에서 돌아갑니다. 데이터는 `~/Library/Containers/com.hantaehee.greveryday`에 있고,
샌드박스 전 빌드의 촬영 기록·편집·캐시는 처음 실행할 때 macOS가 그곳으로 옮깁니다(`App/container-migration.plist`).
카메라 Wi-Fi에 접속하려면 위치 권한이 필요합니다(macOS는 위치 권한이 있는 앱에만 Wi-Fi 이름을 보여 줍니다).
소스는 `Sources/Shared`(모델·공용 화면), `Sources/Mac`(Mac 화면), `Sources/iOS`(iPhone·iPad 화면)로 나뉩니다.

바탕화면 안의 폴더에서 실행하면 macOS가 앱을 확인하지 못해 위치 권한 창이 뜨지 않고, 카메라 Wi-Fi에 접속할 수 없습니다. 응용 프로그램 폴더에서 실행하세요.

### 처음 연결
1. 카메라 메뉴에서 **Bluetooth 켜기**(가능하면 "켜져 있는 조건 = 항상")
2. 앱에서 **Bluetooth로 찾기** → 카메라 옆 **연결**
3. macOS가 Bluetooth 권한·페어링을 물으면 허용
4. 연결되면 라이브러리가 뜹니다. 사진을 고르고 **선택 저장** (기본 폴더 `~/Pictures/GR`, 툴바의 폴더 버튼으로 변경)

### USB로 연결
카메라를 USB-C 케이블로 Mac에 연결하고 켠 뒤 **"USB로 연결"**. Mac의 Wi-Fi는 원래 네트워크에 그대로 있어서
인터넷과 AirPlay를 계속 쓸 수 있습니다. GR IV는 USB에서 PTP 카메라(드라이브 아님)로 잡히고 파일만 제공하므로
라이브러리·크게 보기·영상·선택 저장은 되고, 원격 촬영과 카메라 설정은 Wi-Fi 연결에서만 됩니다.
(확인: 210장 목록, 13.5MB 원본 0.95초, 영상 탐색·썸네일)

### 다시 연결 (촬영 다녀온 뒤)
1. 카메라 전원을 켭니다.
2. 휴대폰의 **GR WORLD**에서 카메라에 연결해 **WLAN(Wi-Fi)**을 켭니다.
3. GR Mac에서 **"휴대폰 GR WORLD로 WLAN(Wi-Fi) 켜고 연결"** → 저장된 암호로 카메라 Wi-Fi에 접속해 라이브러리가 열립니다.
4. 연결되면 휴대폰 제어 센터에서 **Bluetooth를 끄고** 휴대폰을 잠가 둡니다. 카메라 WLAN이 그대로 유지됩니다
   (확인: Bluetooth를 켠 채 잠그면 54초 뒤 WLAN이 꺼졌고, Bluetooth를 끄고 잠그면 2분 넘게 유지).
   WLAN이 꺼져도 GR WORLD로 다시 켜면 GR Mac이 자동으로 다시 접속합니다(확인됨).

페어링한 뒤 Mac은 Bluetooth로 카메라에 다시 붙을 수 없습니다. macOS는 페어링 때 카메라에 IRK를 넘기고
이후 공개 주소로 접속하는데, 카메라가 이 접속에 응답하지 않습니다(PacketLogger로 확인: 연결 0.19초 뒤 0x3E).
앱에서는 이 동작을 바꿀 수 없어서(서드파티 앱은 programmatic pairing 비활성), 카메라 Wi-Fi는 휴대폰이 켭니다.
페어링 직후 앱이 켜져 있는 동안은 페어링한 Bluetooth 연결로 Mac이 직접 Wi-Fi를 켭니다.

Mac이 이미 카메라 `GR_…` Wi-Fi에 붙어 있으면 **"이미 Mac이 카메라 Wi-Fi에 연결돼 있어요"**.

카메라 Wi-Fi에 붙어 있는 동안 Mac의 인터넷은 끊깁니다. **연결 끊기**를 누르면 원래 Wi-Fi로 돌아갑니다.

## 카메라 없이 개발

```bash
python3 scripts/mock_camera.py   # 가짜 카메라 http://127.0.0.1:8765
open --env GRLINK_CAMERA_URL=http://127.0.0.1:8765 "build/xcode/Build/Products/Release/GR Everyday.app"
```
→ "이미 Mac이 카메라 Wi-Fi에 연결돼 있어요"를 누르면 가짜 사진으로 모든 화면을 시험할 수 있습니다.

## 검증 상태

- 가짜 카메라로 라이브러리·선택 저장·라이브뷰·초점·셔터·설정 화면 동작 확인
- 실제 RICOH GR IV HDF(펌웨어 1.20)로 페어링 → WLAN 켜기 → 라이브러리, 그리고 휴대폰 GR WORLD로 WLAN을 켠 뒤 재연결을 확인했습니다.
  Bluetooth UUID와 HTTP API는 GR III/IIIx 커뮤니티 분석과 같습니다.
- 촬영 통계·통계에서 라이브러리 거르기는 USB 연결로 확인했습니다. Wi-Fi 연결에서는 아직 확인하지 않았습니다.
- 자동 저장은 꺼져 있을 때 아무것도 받지 않는 것까지 확인했고, 켠 상태로 받는 동작은 아직 실행하지 않았습니다.

## 구조

```
Sources/GRLink/
  App.swift             사이드바, 앱 설정, 상태 표시
  CameraView.swift      카메라 탭(등록·연결·연결 정보), CameraArt.swift 카메라 사진·기본 그림
  ConnectionModel.swift 연결 흐름 (BLE → Wi-Fi → HTTP), 끊김 감시
  BLEWaker.swift        CoreBluetooth: 전원 On, Wi-Fi AP 켜기, SSID/비번 읽기
  WiFi.swift            networksetup으로 Wi-Fi 전환/복귀
  USBCamera.swift       USB(PTP) 카메라를 ImageCaptureCore로 읽고, 같은 HTTP API를 127.0.0.1에서 제공
  CameraAPI.swift       http://192.168.0.1/v1/* 호출
  LibraryModel/View     목록·선택·다운로드, 그리드·확대 보기·필름스트립
  Viewer.swift          확대/이동 캔버스, 스크롤·드래그·클릭 설정, 동영상 재생, 단축키
  Develop.swift         보정 엔진(Core Image)·내보내기, DevelopView.swift 편집 화면
  MakerNote.swift       EXIF·메이커노트 읽기(이미지 컨트롤, HDF, 노출 모드), ShotChips.swift 정보 패널 칩
  ShotStats.swift       촬영 통계 읽기·캐시·지운 사진 기록, StatsView.swift 촬영 통계 화면
  RemoteView.swift      라이브뷰(MJPEG)·초점·셔터·타이머
  SettingsView.swift    촬영/색감 설정
```

참고: [gr3sync](https://github.com/sotashimozono/gr3sync), [ricoh-wireless-protocol](https://github.com/CursedHardware/ricoh-wireless-protocol), [ricoh-gr-bluetooth-api](https://github.com/dm-zharov/ricoh-gr-bluetooth-api), [grCameraAnalysis](https://github.com/sky18Dragon/grCameraAnalysis)
