# 탐색 (Explore) 설계

순간들 탭 안의 세 번째 공간. 순서는 **순간들 · 탐색 · 내 갤러리** (2026-11-14 사용자 결정).
순간들은 한 장씩 크게 넘겨 보는 최신 흐름, 탐색은 촘촘한 그리드에 정렬과 필터를 붙인 곳.

## 단계

1. **탐색 뼈대 + 정렬** (완료, 서버 적용 2026-11-14)
   - 그리드(iPhone 3칸, 넓은 화면은 더 많이), 누르면 순간들과 같은 상세.
   - 정렬: 추천 / 좋아요 / 최신.
   - 좋아요 순일 때만 기간: 이번 주(7일) / 이번 달(30일) / 올해(365일) / 전체.
2. **필터: 기종 · 화상 · 지역** (완료)
   - 기종: `photos.camera` 그대로(앱이 "RICOH "를 떼고 저장, 고른 기종은 정해진 목록).
   - 화상: 새 열 `photos.look` = 필름 GR이면 `film`, 아니면 `image_control.name` (DB가 자동 계산).
   - 지역: 새 열 `photos.region`. 앱이 좌표를 한국어로 역지오코딩해서 저장.
     국내는 시·도 짧은 이름(서울, 경기, 제주 …), 해외는 나라 이름(일본, 미국 …).
     위치를 공유하지 않은 사진은 지역도 없음. 직접 적은 장소 이름(`place`)으로는 정하지 않음.
   - 필터 목록은 지금 공유된 사진에 실제로 있는 값만, 장수와 함께(`explore_facets()`).
   - 정렬 하나 + 필터 여러 개를 함께(AND).
3. **이전 당선작** (완료, 서버 적용 2026-11-14) — PLAN-contest.md

## 필터 줄 (2026-11-14 사용자 요청으로 바꿈)

- 칩 한 줄: **정렬**(추천 / 좋아요 / 최신, 좋아요면 같은 메뉴에 기간) · **기종** · **화상** · **지역**, 오른쪽에 ✕(모두 지우기).
- 기종 메뉴: 전체 / 디지털 GR 모두 / 필름 GR 모두, 그 아래 디지털 GR과 필름 GR을 나눠 기종별로.
- 화상 메뉴는 기종에 따라 바뀜: 디지털이면 이미지 컨트롤만, 필름이면 필름만(칩 이름도 "필름"),
  고르지 않았으면 둘 다 나눠서. 기종을 바꿔서 고른 화상이 맞지 않게 되면 화상은 풀림.
- 서버: `20261114040000_moment_explore_kind.sql` — `explore_photos`에 `p_kind`('film'|'digital'),
  `is_film_gr()`, `explore_facets`에 `films`·`controls` 목록 추가(`looks`는 이전 앱용으로 남김).

## 서버 (`supabase/migrations/20261114030000_moment_explore.sql`)

- `photos.region` (1–20자, 위치가 있을 때만), 소유자가 바꿀 수 있음(`grant update (region)`).
- `photos.look` 생성 열(stored).
- `explore_photos(p_sort, p_period, p_camera, p_look, p_region, p_offset, p_limit)` → `setof photos`.
  security invoker라 `photos readable` 정책(차단, 숨김)이 그대로 적용됨. PostgREST가 결과에
  `author:profiles!photos_owner_fkey(...)`를 붙여 읽을 수 있음.
  - 추천 점수: `(순간들 좋아요 + 1) / (공유 후 지난 시간(h) + 2)^1.5` — 새 사진과 좋아요 많은 사진이 위로.
  - 페이지는 offset(30장씩). 추천은 시간이 지나며 순서가 바뀌므로 앱이 이미 받은 사진은 건너뜀.
- `explore_facets()` → `{cameras, looks, regions: [{value, count}]}`.
- 부분 인덱스: 좋아요 순, 기종, 화상, 지역 (공유된 사진만).

## 앱

- `MomentStore.explore(_:offset:limit:)`, `exploreFacets()`. Mock도 같은 규칙.
- `MomentExplore`(모델): 정렬·기간·필터 상태, 페이지, 좋아요(순간들 좋아요), 신고한 사진 빼기.
- `MomentExploreView`: 정렬 메뉴 + 필터 칩 줄 + 그리드. 상세는 `MomentFeedDetail` 재사용.
- 지역 저장: `MomentRegion.name(lat:lon:)`. 업로드 뒤, 정보 고친 뒤 `region`을 함께 씀.
- 이미 올라간 사진 중 위치가 있는 것은 한 번 채워 넣기(서버 적용 뒤).
