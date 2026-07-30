# 아이콘 원본

LorePia가 직접 그린 아이콘의 **작업 원본**입니다. 앱이 이 파일을 읽지는
않습니다 — 아이콘을 고칠 때 좌표를 역산하지 않기 위한 기준입니다.

## 어디에 무엇이 있나

| 위치 | 내용 | 앱이 사용 |
|---|---|---|
| `icons/` | 채팅·설정·작성창에 쓰이는 아이콘 원본 (24 단위 그리드, 스트로크) | 아니오 |
| `tabicons/` | 하단 탭바 아이콘 원본 | 아니오 (아래 에셋이 사본) |
| `Apps/iOS/Assets.xcassets/Tab*.imageset/*.svg` | 탭바가 실제로 쓰는 SVG | **예** |
| `Packages/LorepiaKit/Sources/LorepiaKit/DesignSystem/LorepiaGlyph.swift` | 나머지 아이콘 전부. `Path` 좌표로 직접 그림 | **예** |

`_sheet_*.svg`와 `_preview.svg`는 여러 아이콘을 한 장에 늘어놓은 비교용
시트입니다.

## 고치는 순서

1. `icons/`의 SVG를 먼저 수정한다.
2. 같은 좌표를 `LorepiaGlyph.swift`의 해당 `case`에 옮긴다. 그리드는 24
   단위, 스트로크는 대부분 2, 라운드 캡·조인을 쓴다. 채우는 글리프는
   `isFilled`로 표시한다.
3. 탭바 아이콘은 `Assets.xcassets`의 SVG를 교체한다.

두 곳을 함께 고쳐야 원본과 화면이 어긋나지 않습니다.
