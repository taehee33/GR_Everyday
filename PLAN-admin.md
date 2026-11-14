# 어드민 페이지

2026-11-14 사용자 요청. 설정 › 계정 › 로그아웃 아래 `어드민` (어드민만 보임). iOS·Mac 공통 (`MomentAdminView`).

## 서버 (`supabase/migrations/20261114060000_moment_admin.sql`)

- `admins(user_id)`: 정책 없음, 함수로만 읽고 씀. 첫 어드민은 사용자명 `soongone`.
- `is_admin()`: 앱이 어드민 줄을 보일지 정할 때. 나머지 `admin_*` 함수는 모두 안에서 `require_admin()`으로 확인.
- `profiles.shares_per_month`: 사람별 한 달 공유 한도. null이면 `app_config.limits.shares_per_month`.
  `share_photo_for`, `shares_left`가 `share_limit()`을 씀.
- 벽 최대 장수 (`20261114080000_moment_admin_wall.sql`): 업로드 함수는 계속 `profiles.wall_limit`을 읽음.
  `wall_limit_own`이 false면 `app_config.limits.wall_photos_free`를 따라가고, 기본값을 바꾸면 함께 바뀜.
  나중에 구매로 벽을 늘릴 때도 `wall_limit_own = true`로 둘 것.
- 기본 한 달 공유 한도 3 (2026-11-14 사용자 결정, 5에서 바꿈).

## 화면

- 사용자: 검색. 공유와 벽 모두 같은 순서: 한도(기본값 또는 숫자) · 이 사람만 따로 정하기 · 지금 쓴 수(보기만) · 저장.
  숫자는 따로 정하기를 켰을 때만 바꿀 수 있음. (`admin_set_shares_used`는 서버에 남아 있지만 화면에서는 뺌.)
- 기본값: 한 달 공유 한도, 벽 최대 장수. 따로 정하지 않은 모두에게 바로.
- 당선작: 달 추가·글 수정·삭제, 좋아요 순 후보, 당선작 넣기·빼기 (`admin_set_winner`, 달이 끝나기 전에도 됨, 테스트용).
  아이콘 자르기 위치는 아직 화면 없음 (가운데).
- 순간들 하트 색 (당선작 화면 아래, 2026-11-14): `app_config.heart_color` "#RRGGBB", `admin_set_heart_color`
  (`20261114100000_moment_heart_color.sql`). 앱은 `MomentHeartColor`가 켤 때·앱으로 돌아올 때 읽고 마지막 색을 기억. 기본은 하양 (2026-11-14 사용자 결정). 아주 밝은 색(휘도 > 0.9)은 라이트 모드에서 검정, 위 글씨는 `onTint`.
  `MomentLikePlace.moment.tint`를 쓰는 곳(하트, 탐색 칩, 당선작 글씨 등)이 모두 같이 바뀜. 저장한 기기는 바로,
  다른 사람은 다음에 앱을 열거나 돌아올 때 (실시간 구독은 안 함).
- 어드민 명단: 사용자명으로 추가, 빼기 (마지막 한 명은 못 뺌).
