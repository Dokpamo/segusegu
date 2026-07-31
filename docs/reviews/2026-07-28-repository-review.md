# 저장소 코드 리뷰 — 2026-07-28

## 결론

검토 snapshot은 핵심 Rust 검사와 대부분의 호스트 빌드는 통과했지만,
출시 또는 agent 기능 확장의 기준선으로 승인할 수 없다.

가장 먼저 해결해야 할 문제는 다음 네 가지다.

1. 하나의 `data_root`를 여러 프로세스가 동시에 열 수 있어, 늦게 연
   프로세스의 복구가 정상 실행 중인 import와 generation을 파괴한다.
2. provider usage 값의 정수 변환 실패가 branch를 영구 `pending` 상태로
   남길 수 있다.
3. v2에서 v3으로의 migration이 v2에서 허용되던 동일 timestamp 메시지를
   올바르게 복원하지 못한다.
4. C ABI 숫자는 그대로인데 event JSON 계약이 바뀌어 이전 ABI 2 client가
   호환되지 않는 payload를 정상 계약으로 오인할 수 있다.

Agent run, tool loop, background task는 현재 generation보다 상태와 재시작
경계가 훨씬 많다. 위 네 항목을 먼저 고치지 않으면 새 기능이 기존 결함의
피해 범위를 확대한다.

## 검토 기준

- 검토일: 2026-07-28
- 브랜치: `agent/multi-room-branching-chat`
- 범위: Rust core와 bindings, Android, Apple, Windows, CI와 테스트 계약
- 방식: 정적 검토, 직접 작성한 임시 입력과 loopback provider 재현,
  저장소가 제공하는 검사와 host에서 가능한 native 검사
- 교차 검증: 저장소·플랫폼·테스트·외부 연구 영역별 독립 agent 검토 후
  근거를 재확인해 하나의 보고서로 통합

| 근거 영역 | 기준 snapshot |
|---|---|
| Rust, bindings, Android, Windows, CI | `8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461` |
| Apple의 검토 시작 시 11-file patch | 이후 동일 patch가 commit된 `9d3d40e9456ee1695ed139f5de6d2e4d02218e8b` |

검토 시작 시 Apple 관련 11개 파일에 사용자의 미커밋 변경이 이미 있었다.
그 변경은 보존했으며 이 리뷰에서는 제품 코드를 수정하지 않았다. 아래
Apple line reference는 그 working tree snapshot을 기준으로 한다. 해당
변경은 문서 작성 중 별도 작업에서
`9d3d40e9456ee1695ed139f5de6d2e4d02218e8b`로 commit됐다.

문서 최종 검증 중 `9d3d40e` 이후 Rust core/provider/storage와 Apple
app/package에 별도의 미커밋 수정이 나타났다. 이 보고서는 그 동시 작업을
검토하거나 포함하지 않으며, 일부 finding을 겨냥한 변경처럼 보여도
재현·검증 전에는 해소 증거로 간주하지 않는다. Rust/Android/Windows 근거는
`8d7f8b4`, Apple 근거는 `9d3d40e` snapshot의 symbol과 line을 기준으로
고정한다.

심각도는 다음 의미로 사용한다.

- **P1**: 데이터 손상, 영구 진행 불능, credential 오사용, 호환성 또는 CI
  신뢰 경계를 깨므로 다음 기능 작업 전에 수정해야 한다.
- **P2**: 비정상 입력, concurrency, 복구 또는 플랫폼 품질에서 실제 장애를
  만들 수 있어 출시 전에 수정하거나 명시적으로 수용해야 한다.

## P1 findings

### CR-01 — `data_root`에 단일 writer/owner lock이 없다

근거:

- [`Storage::open`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/storage/src/database.rs#L81)은 디렉터리와
  SQLite를 연 뒤 즉시 migration과 recovery를 실행한다.
- recovery는 모든 `running` generation을 `cancelled`로 바꾸고 pending
  assistant를 삭제하거나 취소한다.
  [`apply_recovery_transaction`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/storage/src/database.rs#L1835)
- import journal과 staging cleanup도 같은 open 경로에서 실행된다.

동일 root를 사용하는 두 번째 Core 또는 진단 CLI를 첫 Core가 실행 중일 때
열어 직접 확인했다. 두 번째 open은 첫 Core의 import staging을 제거해
commit을 `ENOENT`로 실패시켰고, 실행 중 generation을 취소했다. 첫
프로세스는 그 generation을 계속 실행 중이라고 생각할 수 있다.

필요한 수정:

- DB나 staging에 접근하기 전에 cross-process exclusive lock을 획득하고
  `Storage` 수명 동안 유지한다.
- lock 대상은 canonicalized app-owned root와 결합하고 symlink를 따르지
  않아야 한다.
- 진단 명령이 필요하면 복구를 수행하지 않는 명시적 read-only mode로
  분리한다.
- 별도 프로세스 두 개로 import, generation, reopen을 강제하는 회귀
  테스트를 추가한다.

### CR-02 — terminal commit 실패가 branch를 영구 `pending`으로 남긴다

근거:

- provider usage는 `u64`다.
  [`GenerationUsage`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/domain/src/provider.rs#L31)
- SQLite 기록 직전에 `u64_to_i64` 변환을 수행한다.
  [`finalize_generation`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/storage/src/database.rs#L1215)
- 변환 또는 terminal transaction이 실패해도 core task는 failure event를
  내보내고 generation registry에서 항목을 제거한다.
  [`execute_generation_task`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/core/src/app.rs#L1178)

loopback SSE가 `i64::MAX + 1`의 usage와 정상 text를 반환하도록 만들어
재현했다. 사용자에게는 failure가 도착했지만 transaction 전체가 rollback되어
assistant row는 content가 있는 `pending`으로 남았다. 이후 cancel은
`not_found`가 되고 같은 branch의 다음 send는 pending generation 때문에
거부됐다.

필요한 수정:

- provider 경계에서 usage의 저장 가능 범위를 검증하거나, DB 표현을 계약에
  맞게 바꾼다.
- 어떤 terminalization 실패에서도 generation과 assistant가 반드시
  `failed` 또는 `cancelled`로 끝나는 보상 transaction을 둔다.
- registry 제거와 terminal persistence의 순서를 하나의 명시적 상태
  protocol로 정의한다.
- overflow, DB failure injection, core drop, cancel 경합을 각각 테스트한다.

### CR-03 — v2→v3 migration이 유효한 동일 timestamp 이력을 거부한다

근거:

- migration은 `ORDER BY created_at, id`의 `LAG(id)`로 parent를 만든다.
  [`0003_conversation_branches.sql`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/storage/migrations/0003_conversation_branches.sql#L36)
- assistant generation의 `user_message_id`는 그 결과인 `parent_id`를
  사용한다.
  [`generation backfill`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/storage/migrations/0003_conversation_branches.sql#L169)
- migration 후 validator도 같은 정렬을 유일한 timeline으로 간주한다.
  [`validate_legacy_messages_for_branch_migration`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/storage/src/database.rs#L1652)

v2는 동시 send를 배제하지 않았고 timestamp는 유일 key가 아니었다. 사용자와
assistant가 같은 timestamp를 갖는 합법적인 fixture에서 ID 정렬에 따라
assistant가 먼저 배치되어 `generations.user_message_id NOT NULL` 조건으로
migration이 실패했다.

필요한 수정:

- v2의 `generation_id`, role, 기존 관계를 이용해 user/assistant pair를 먼저
  복원하고, timestamp만으로 인과관계를 만들지 않는다.
- destructive table 교체 전에 전체 legacy graph를 검증한다.
- 동일 timestamp, concurrent generation, pending, partial, 취소, 손상된
  generation ID, rollback fixture를 추가한다.

### CR-04 — ABI 2가 서로 다른 event 계약 두 개를 가리킨다

근거:

- C ABI 상수는 여전히 2다.
  [`ABI_VERSION`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/bindings/c-api/src/lib.rs#L21)
- event는 Rust `ChatEvent`를 raw JSON으로 직렬화한다.
  [`lorepia_core_poll_events_json`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/bindings/c-api/src/lib.rs#L476),
  [`core_json`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/bindings/c-api/src/lib.rs#L623)
- 현재 event schema는 event version 2와 branch/message identity를 포함한다.
  [`ChatEvent`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/chat/src/events.rs#L45)

이전 ABI 2도
[`ABI_VERSION = 2`](https://github.com/Dokpamo/segusegu/blob/3350314d7203fe9bdc7205aee34bb91de7528577/bindings/c-api/src/lib.rs#L21)였지만
event는 [version 1](https://github.com/Dokpamo/segusegu/blob/3350314d7203fe9bdc7205aee34bb91de7528577/crates/chat/src/events.rs#L42)이었고
Windows client도 [version 1만 허용](https://github.com/Dokpamo/segusegu/blob/3350314d7203fe9bdc7205aee34bb91de7528577/apps/windows/Lorepia.Native/CoreClient.cs#L427)했다.
ABI handshake는 성공하지만 payload를 처리하지 못하므로, ABI 숫자가
제공해야 할 호환성 보장이 깨진다.

필요한 수정:

- breaking event 변경과 함께 C ABI를 3으로 올리거나, event schema version
  negotiation과 명시적인 구버전 변환을 추가한다.
- ABI 2 fixture client와 ABI 3 client를 함께 실행하는 contract test를 둔다.
- UniFFI generated source와 Windows DTO drift도 같은 change set에서 검사한다.

### CR-05 — platform 파일을 범위 밖으로 rename하면 CI가 skipped-green 된다

[`changed_paths`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/scripts/ci-path-filter.sh#L116)은
`git diff --name-only`의 결과만 검사한다. Git이 rename을 감지하면 destination
경로만 반환하므로 `apps/android/Foo.kt`를 `docs/Foo.kt`로 옮긴 변경은 Android
검사를 실행하지 않을 수 있다.

`--name-status -z`로 source와 destination을 모두 검사하거나 rename detection을
끄고 양쪽 경로를 받아야 한다. 임시 Git 저장소에서 platform→docs,
platform→platform, 삭제, copy를 재현하는 self-test가 필요하다.

### CR-06 — Windows profile 변경 후 이전 credential을 다른 profile에 저장할 수 있다

Settings의 profile selector는 profile을 바꾸지만
[`SettingsPage.xaml`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/apps/windows/Lorepia.App/Pages/SettingsPage.xaml#L20),
`PasswordBox`는 새 profile을 시작하거나 저장·삭제할 때만 비운다.
[`SettingsPage.xaml.cs`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/apps/windows/Lorepia.App/Pages/SettingsPage.xaml.cs#L29)

사용자가 A profile의 key를 입력한 뒤 B를 선택하고 저장하면 그 text가 B의
credential로 전달될 수 있다. 선택 변경 때 secret field를 즉시 지우고,
credential 변경은 별도 명시적 action으로 표시해야 한다. A→B→save와 빠른
selection 경합을 실제 ViewModel/UI test로 추가해야 한다.

### CR-07 — Android가 대화 재진입 후 실행 중 generation을 복원하지 않는다

Android `openReady`는 persisted messages와 settings를 불러오지만
[`ChatViewModel.openReady`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/apps/android/app/src/main/kotlin/dev/lorepia/app/feature/chat/ChatViewModel.kt#L229),
pending assistant에서 active generation을 복원하거나 polling을 시작하지 않는다.
Rust Core는 살아 있는 상태에서 route 이동이나 ViewModel 재생성 후 같은
대화에 다시 들어오면 generation은 계속 실행되지만 새 ViewModel은 이를
관찰하거나 취소할 수 없다.

대화 open 시 pending/cancelled/failed row로 generation state를 재구성하고,
pending generation이면 polling을 재개해야 한다. chat back-stack entry
pop→동일 대화 재진입, Application Core가 살아 있는 새
`ViewModelStoreOwner`의 ViewModel 재생성, process death 후 terminal
recovery를 각각 테스트해야 한다.

### CR-08 — Android import의 discard와 commit이 동시에 시작될 수 있다

`commit()`은 `isCommitting`만 검사하고 `isDiscarding`은 검사하지 않는다.
[`ImportReviewViewModel.commit`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/apps/android/app/src/main/kotlin/dev/lorepia/app/feature/importreview/ImportReviewViewModel.kt#L35)
반대로 화면의 commit button도 `isDiscarding` 동안 활성 상태다.
[`ImportReviewScreen`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/apps/android/app/src/main/kotlin/dev/lorepia/app/feature/importreview/ImportReviewScreen.kt#L223)

두 Core command가 같은 inspection을 경쟁하면 한쪽은 이미 claim된 ID로
실패하고, local staged-document cleanup과 navigation callback 순서도
비결정적이 된다. 또한
[`discard`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/apps/android/app/src/main/kotlin/dev/lorepia/app/feature/importreview/ImportReviewViewModel.kt#L63)는
Core 오류를 모두 삼킨 뒤 local cleanup과 navigation을 실행해 retry 기회도
없앤다. 하나의 atomic UI intent/operation state로 commit과 discard를 상호
배제하고, 실패를 표시하며, double tap과 back/commit 경합을 테스트해야 한다.

## P2 findings

| ID | 문제 | 근거와 필요한 방향 |
|---|---|---|
| CR-09 | 빈 HTTP 2xx와 불완전 SSE가 성공 처리된다 | stream에 event가 하나도 없어도 `Ok(usage)`이며, `[DONE]` 뒤 delta도 계속 처리한다. [`stream_chat`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/providers/src/openai_compatible.rs#L114), [`process_event`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/providers/src/openai_compatible.rs#L213). terminal marker, finish reason, 최소 유효 event를 검증해야 한다. |
| CR-10 | 미래 schema DB를 거부하기 전에 변경할 수 있다 | `Storage::open`은 [journal mode를 WAL로 바꾸고](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/storage/src/database.rs#L96) `MIGRATION_0001`을 실행한 뒤에야 schema version을 비교한다. [`migrate`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/storage/src/database.rs#L1579). 먼저 read-only inspection을 하고 미래 버전은 byte-level 변경 없이 거부해야 한다. |
| CR-11 | SQLite main file symlink가 root 밖 파일을 열 수 있다 | owned directory는 non-following 검사하지만 [`db/lorepia.sqlite3`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/storage/src/database.rs#L81) 자체는 `Connection::open`이 따른다. DB, WAL, SHM의 file type과 ownership을 open 전에 검증해야 한다. |
| CR-12 | NFKC 뒤 생기는 `..` logical path가 허용된다 | traversal 검사는 [NFKC 전](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/content/src/path.rs#L25)이고, full-width dot 두 개는 [normalize 후](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/content/src/path.rs#L35) `..`가 된다. 현재 flat staging은 host escape를 막지만 logical ID를 쓰는 미래 consumer에는 위험하다. normalize 후 모든 규칙을 다시 적용해야 한다. |
| CR-13 | provider/profile/credential 변경이 원자적이지 않다 | Core의 존재 확인→settings 저장과 settings 해제→profile 삭제가 분리돼 있다. [`update_settings`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/core/src/app.rs#L694), [`delete_provider_profile`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/core/src/app.rs#L746). Android는 [credential부터 삭제](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/apps/android/app/src/main/kotlin/dev/lorepia/app/feature/settings/SettingsViewModel.kt#L180)하고 Windows는 [profile부터 삭제](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/apps/windows/Lorepia.App/ViewModels/SettingsViewModel.cs#L275)해 중간 실패 시 secret과 profile이 어긋난다. storage revision과 플랫폼 credential 보상/재시도 계약이 필요하다. |
| CR-14 | Apple async refresh가 새 branch 선택을 오래된 결과로 덮을 수 있다 | metadata와 message action refresh는 conversation ID만 검증한 뒤 active branch/mode/messages를 기록한다. [`refreshBranchMetadata`](https://github.com/Dokpamo/segusegu/blob/9d3d40e9456ee1695ed139f5de6d2e4d02218e8b/apps/apple/Packages/LorepiaKit/Sources/LorepiaKit/Features/Chat/ChatViewModel.swift#L600), [`restoreAfterMessageAction`](https://github.com/Dokpamo/segusegu/blob/9d3d40e9456ee1695ed139f5de6d2e4d02218e8b/apps/apple/Packages/LorepiaKit/Sources/LorepiaKit/Features/Chat/ChatViewModel.swift#L957). branch/selection revision guard가 필요하다. |
| CR-15 | event overflow 복구가 플랫폼 실부하로 검증되지 않았다 | core bus는 bounded broadcast이고 client는 dropped count 후 SQLite를 다시 읽는다. 이 경로를 256개 이상 burst와 화면 전환 중 실제 binding으로 검증하는 테스트가 없다. |
| CR-16 | 최대 source를 읽은 뒤 metadata 4 MiB 제한을 적용한다 | standalone JSON은 [source 전체를 읽은 뒤](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/content/src/lib.rs#L79) [metadata 4 MiB 제한](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/content/src/adapters.rs#L26)을 적용한다. streaming 또는 bounded prefix parser로 allocation peak를 제한해야 한다. |
| CR-17 | pending import review 수에 전역 상한이 없다 | Core의 [`pending_imports`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/crates/core/src/app.rs#L63)는 개별 파일 제한만 있고 동시 review 수/총 staging bytes 제한이 없다. count와 byte quota, eviction/expiry가 필요하다. |
| CR-18 | Windows와 Android의 native test matrix가 지원 범위를 덜 검증한다 | Windows 핵심 Chat/Settings ViewModel과 ARM64가 CI에서 빠지고, Android는 API 36 Debug 중심이라 min API 26과 release shrinker 경로를 놓친다. |
| CR-19 | Apple의 generated-binding 없는 source graph가 필수 CI에 없다 | [`Package.swift`](https://github.com/Dokpamo/segusegu/blob/9d3d40e9456ee1695ed139f5de6d2e4d02218e8b/apps/apple/Packages/LorepiaKit/Package.swift#L16)에는 `LOREPIA_SKIP_GENERATED=1` 분기가 있지만 [일반 build script](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/scripts/build-apple.sh#L7)는 먼저 binding을 생성한다. 수동 실행은 59/59 통과했다. artifact 생성 전 별도 필수 job으로 고정해야 한다. |
| CR-20 | native fixture 변경이 Android/Apple CI를 깨우지 않는다 | [path filter](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/scripts/ci-path-filter.sh#L23)의 platform scope에 `testdata/*`가 없지만 [Android build](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/apps/android/app/build.gradle.kts#L40)는 해당 fixture를 instrumentation asset으로 묶는다. fixture 변경도 native job을 실행하고 self-test에서 실제 포함 여부를 확인해야 한다. |
| CR-21 | Android가 send 실패 전에 draft를 지운다 | UI는 [draft를 먼저 비운 뒤](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/apps/android/app/src/main/kotlin/dev/lorepia/app/feature/chat/ChatScreen.kt#L361) async send를 시작한다. credential/core 오류 시 원문을 복구하지 않아 사용자의 입력이 사라진다. 성공 확인 뒤 clear하거나 failed text를 복원해야 한다. |
| CR-22 | Android가 persisted pending bubble과 streamed bubble을 중복 표시할 수 있다 | `preserve_partial_generations=true`에서 checkpoint content가 있는 경우, 화면은 [persisted messages와 `streamedText`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/apps/android/app/src/main/kotlin/dev/lorepia/app/feature/chat/ChatScreen.kt#L305)를 동시에 렌더링하고 reconciliation은 pending row를 [다시 읽으면서 stream text를 유지](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/apps/android/app/src/main/kotlin/dev/lorepia/app/feature/chat/ChatViewModel.kt#L318)한다. checkpoint 이후 한 응답이 두 bubble에 나타나는 실부하 test가 필요하다. |
| CR-23 | Windows polling 오류가 composer를 고착시킨다 | poll의 일반 예외는 [status만 바꾸고](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/apps/windows/Lorepia.App/ViewModels/ChatViewModel.cs#L355) `eventCursor`를 남긴다. composer는 [`eventCursor is null`](https://github.com/Dokpamo/segusegu/blob/8d7f8b447e6ea3401ee75ecd2f93f80a50f7b461/apps/windows/Lorepia.App/ViewModels/ChatViewModel.cs#L83)일 때만 활성화되므로 reload 전까지 send가 막힐 수 있다. persisted reconciliation과 retry/terminal reset이 필요하다. |

## 실행한 검사

| 검사 | 결과 |
|---|---|
| `cargo fmt --all --check` | 통과 |
| `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings` | 통과 |
| `cargo test --workspace --all-features --locked` | 99 passed, 0 failed, 7 ignored |
| `RUSTDOCFLAGS="-D warnings" cargo doc --workspace --no-deps --locked` | 통과 |
| Apple generated/live Swift package tests | 63/63 통과 |
| `LOREPIA_SKIP_GENERATED=1` Swift package tests | 59/59 통과 |
| iOS simulator build | 통과 |
| macOS build | 통과 |
| C ABI/UniFFI contract tests | 14/14 통과 |
| portable Windows .NET tests | 43/43 통과 |
| iOS UI stable rerun | 7개 중 4개 통과, composer 관련 3개 실패 |
| `cargo deny check licenses` | 현재 Rust Cargo graph 통과. Gradle, Swift, .NET, asset와 외부 후보는 범위 밖 |

iOS UI 실패는 accessibility query가 끝나지 않은 뒤 test runner host가
`SIGKILL`된 형태였다. `testChatComposerSoftWrapMovesAsOne`만 따로 반복해도 약
43초 후 같은 형태로 실패했다. 첫 moving-worktree 실행은 환경이 유효하지
않았으며 위 stable rerun만 결과로 사용했다.

### 재현 명령과 증거 한계

Rust 외 결과의 저장소 entry point는 다음과 같다.

```bash
cargo test --locked -p lorepia-c-api -p lorepia-uniffi
./scripts/build-apple.sh
LOREPIA_SKIP_GENERATED=1 \
  swift test --package-path apps/apple/Packages/LorepiaKit
./scripts/test-apple-launch.sh
dotnet test apps/windows/Lorepia.Native.Tests/Lorepia.Native.Tests.csproj
```

Apple 검사는 arm64 macOS 26.5.2, Xcode 26.6(17F113), iPhone 17 Pro simulator
환경에서 실행했다. `test-apple-launch.sh`의 stable rerun은 iOS UI 7개 중
4개가 통과하고 composer 3개가 실패한 결과다. portable Windows test는
macOS의 .NET 8 대상이라 실제 WinUI나 PasswordVault를 로드하지 않는다.

CR-01부터 CR-03까지는 임시 directory, 직접 만든 legacy DB fixture와
loopback SSE server로 재현했지만 일회성 harness를 저장소에 보존하지 않았다.
관찰 결과는 finding에 기록했으나, 수정 완료 판단에는 같은 재현을 project-owned
regression test로 옮겨야 한다. 이 보고서 숫자만으로 closure하지 않는다.

## 실행하지 못했거나 현재 host에서 의미가 제한된 검사

- Android Gradle test, lint, assembleDebug: 설치된 Java runtime이 없어 실행하지
  못했다.
- Windows WinUI live build와 실제 PasswordVault/UI test: macOS host에서는
  실행할 수 없었다.
- Windows ARM64 build와 launch: 현재 CI도 x64만 실행한다.
- Rust의 ignored 7개 performance scenario: 기능 회귀용이며 pass/fail 시간
  상한이 없으므로 이번 결과의 성능 승인 근거가 아니다.

## 추가해야 할 강제 테스트

1. 동일 `data_root`를 여는 두 프로세스와 crash/reopen matrix
2. 모든 terminal state에서 DB failure injection과 재시작
3. v2 migration의 timestamp tie, concurrent send, rollback, 미래 schema
4. 빈 2xx, `[DONE]` 뒤 data, 중복 terminal, fragmented JSON, 과대 usage SSE
5. event queue overflow 뒤 Android/Apple/Windows persisted reconciliation
6. Windows profile A/B credential 전환과 settings/profile 동시 수정
7. Android commit/discard/back 경합과 process-death reopen
8. CI path-filter rename/copy/delete, platform fixture 변경
9. Android API 26 및 release R8, Windows ARM64 build
10. Android send 실패 draft 복원과 checkpoint/stream bubble 중복
11. Windows polling 예외 뒤 persisted reconciliation과 composer 복구

## 수정 순서

1. CR-01부터 CR-04까지를 하나의 안정화 milestone으로 처리한다.
2. CR-05부터 CR-08까지 플랫폼/CI P1을 처리한다.
3. CR-09부터 CR-23까지 provider/storage/native 복구 문제를 분류해 처리한다.
4. dropped-event, migration, native lifecycle 강제 테스트를 필수 CI로 올린다.
5. 그 뒤에만 memory, tool loop, durable agent run을 시작한다.

이 문서는 발견과 검증 결과를 기록한 것이며 수정 구현은 포함하지 않는다.
