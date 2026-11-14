# 이달의 사진관 (당선작) 설계

탐색 3단계. 매달 순간들에 공유된 사진 중 한 장을 당선작으로 뽑고, 당선작은 앱 아이콘이 된다
(2026-11-14 사용자 결정).

## 규칙

- 기간: 매월 1일 ~ 말일, **한국 시간**(Asia/Seoul).
- 대상: 그 달에 순간들에 공유된 사진 전부. 따로 출품하지 않음. 순간들에서 내렸거나 숨겨진 사진은 빠짐.
- 선정: 달이 끝나면 좋아요 순으로 정렬한 목록(`contest_ranking`)을 보고 운영자가 최종 1장을 고름(`announce_contest`).
  보통 1위. 좋아요는 **말일까지 받은 것만** 세어서, 달이 끝난 뒤에는 순위가 움직이지 않음.
- 자동 집계 작업(cron)은 없음. 운영자가 확인할 때 계산함.

## 서버 (`supabase/migrations/20261114050000_moment_contests.sql`, 적용 2026-11-14)

- `contests(month, title, theme, intro, winner, icon_crop, announced_at)`. 누구나 읽기만 가능.
  - `month`는 그 달 1일(`2026-11-01`). 운영자가 달마다 한 줄 넣음. 줄이 없으면 앱에 아무것도 안 보임.
  - `winner`는 사진이 지워지면 null.
  - `icon_crop` `{x, y, size}`: 아이콘으로 쓸 정사각형. x·y는 왼쪽 위 모서리(너비·높이 대비), size는 짧은 변 대비. 없으면 가운데.
- `contest_ranking(month, limit)`: 순위, 사진 id, 말일까지 좋아요, 지금 좋아요, 이름, 캡션, 썸네일 주소. 운영자 전용(앱에서는 호출 불가).
- `announce_contest(month, photo, crop)`: 달이 끝나야 하고, 그 달에 공유된 사진이어야 함. 다시 실행하면 선정이나 자르기를 바꿈. 운영자 전용.

어드민 페이지가 생기기 전까지 SQL 편집기에서:

```sql
insert into contests (month, title, theme, intro) values ('2026-12-01', '12월 사진관', '주제 한 줄', '소개 글');
select * from contest_ranking('2026-11-01');
select announce_contest('2026-11-01', '<photo id>', '{"x":0.1,"y":0,"size":0.8}');
```

## 앱

- 순간들 위: `MomentContestNotice`. 이번 달 줄이 있으면 주제·제목·안내, 발표된 가장 최근 당선작 카드(누르면 상세).
- 탐색 위: `MomentPastWinners`. 발표된 달을 최신순으로, 아이콘 모양 썸네일 한 줄.
- 데이터: `MomentStore.contests(limit:)`, `MomentFeed(source: .winners)`를 `MomentAccount.contests`로 하나만 둠.
- 설정 › 앱 로고(iOS): `AppIconPicker`. 앱에 들어 있는 당선작 아이콘(`AppIconCatalog.months`) + 기본 로고.

## 앱 아이콘

iOS 홈 화면 아이콘은 앱 안에 넣어 둔 아이콘으로만 바꿀 수 있음. 그래서 새 당선작 아이콘은 **다음 앱 업데이트**에 들어감
(매달 낼 필요는 없고, 다음 업데이트에 실림). 발표·공지·이전 당선작은 업데이트 없이 바로 보임.

1. `announce_contest` 실행(필요하면 자르기 위치 포함).
2. `swift scripts/contest-icon.swift 2026-11` → `AppIcon-2026-11.appiconset`, `AppIconPreview-2026-11.imageset`,
   `Sources/iOS/AppIconCatalog.swift` 갱신.
3. 빌드해서 업데이트 제출. iOS 타깃은 `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES`라 따로 등록할 것 없음.

Mac은 아직 없음(Mac은 앱이 켜져 있을 때만 Dock 아이콘을 바꿀 수 있음).

## 어드민 페이지 (PLAN-admin.md)

좋아요 순위 보기, 당선작 고르기, 자르기 위치 정하기, 달 추가·공지 글 쓰기. 위 테이블과 함수를 그대로 씀.
