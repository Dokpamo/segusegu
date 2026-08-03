# 제3자 라이선스 도입 정책

## 목적과 적용 범위

이 문서는 LorePia에 code, library, generated source, executable, model,
dataset, font, icon, prompt, skill, template 또는 hosted service를 도입하기
전의 engineering gate를 정의한다.

목표는 “GPL만 없으면 된다”가 아니다. 실제 배포물에 대해 다음을 확인하는
것이다.

- 사용·수정·상업 배포 권한이 있는가
- source 공개, relink, notice, attribution, offer 의무가 있는가
- optional feature와 transitive dependency에 다른 조건이 숨어 있는가
- package metadata와 실제 artifact의 license가 일치하는가
- model, asset, service 약관이 source code license와 별개인가

이 문서는 법률 의견이 아니다. 수동 검토 또는 차단으로 분류된 항목을 실제
제품에 넣으려면 OSS compliance 담당자나 변호사의 판단이 필요하다.

## 현재 저장소 기준선

LorePia 저장소 자체에는 공개 open-source license grant가 없다. 프로젝트
`LICENSE`나 project-authored license header를 추가하지 않는다. 제3자 고지
의무는 제3자 notice로 별도 관리한다.

Rust에는 현재 [`cargo-deny`](../../deny.toml) gate가 있다. 허용 목록은
다음과 같다.

- Apache-2.0
- BSD-3-Clause
- CDLA-Permissive-2.0
- ISC
- MIT
- MPL-2.0
- Unicode-3.0
- Zlib

`cargo deny check`의 graph는 실제 제품 대상인 macOS, iOS, Android,
Windows의 현재 Apple Silicon/Intel, simulator/emulator, x64/ARM64 조합으로
제한한다. Linux Tauri shell은 제품 대상이 아니므로 Linux 전용 GTK graph는
이 gate의 배포 graph에 포함하지 않는다. CI가 Linux host에서 공통 Rust
source를 컴파일한다는 사실은 Linux application 지원을 뜻하지 않는다.

2026-07-28에 기존 `cargo deny check licenses`가 통과했고, 2026-08-02
Tauri 전환 graph에서 전체 `cargo deny check`의 advisories, bans, licenses,
sources 검사가 통과했다. 현재 resolved graph의 MPL-2.0 사용은 UniFFI
package family와 Tauri frontend build tooling에 한정해 검토한다. 이는
MPL을 모든 신규 dependency에 자동 허용하자는 제품 결정이 아니라, 이미
사용하는 핵심 dependency의 현 상태다.

정확히 다섯 개의 RustSec `unmaintained` notice는 예외다:
`RUSTSEC-2025-0075`, `RUSTSEC-2025-0080`, `RUSTSEC-2025-0081`,
`RUSTSEC-2025-0098`, `RUSTSEC-2025-0100`. 모두 pinned Tauri
`2.11.x`의 `tauri-utils -> urlpattern`을 통해 들어오는 `rust-unic`
transitive crate이며, 현재 호환 가능한 안전한 교체 버전이 없다. 이들은
취약점 또는 unsoundness 판정이 아니라 유지보수 중단 알림이므로 exact ID와
사유로만 임시 승인한다. Tauri가 `urlpattern` dependency를 교체하면 즉시
예외를 제거하며, 그 밖의 advisory나 신규 unmaintained crate에는 이 승인을
확장하지 않는다.

`cargo-deny` output에 LGPL이나 GPL 문자열이 보인다는 이유만으로 그
license가 선택됐다고 단정하면 안 된다. SPDX `OR`는 조건 중 하나를 선택할
수 있고 `AND`는 모두 준수해야 한다.
[SPDX license expression](https://spdx.github.io/spdx-spec/v2.3/SPDX-license-expressions/)을
원문 그대로 해석하고, 선택한 branch를 decision record에 남긴다.

현재 gate는 Rust graph만 다룬다. Gradle, SwiftPM/Xcode, NuGet, bundled
native binary, font, asset, model, downloaded tool과 실제 store artifact를
모두 청산했다는 뜻이 아니다.

또한 현재 `deny.toml`은 MPL-2.0을 허용하므로 신규 MPL dependency도 자동
검사만으로는 통과한다. dependency diff와 승인 기록 gate가 추가되기 전까지
신규 MPL은 reviewer가 수동으로 막거나 승인해야 한다.

## 기본 정책

### Fast path 후보

다음은 exact artifact와 notice를 확인한 뒤 일반적으로 자동 gate 후보가
될 수 있다.

- MIT
- Apache-2.0
- BSD-2-Clause, BSD-3-Clause
- ISC
- Zlib
- Unicode-3.0
- CDLA-Permissive-2.0

Fast path도 무검토를 뜻하지 않는다.

- 정확한 package owner, version, source revision을 고정한다.
- package 내부 LICENSE와 metadata를 대조한다.
- copyright, permission notice, Apache NOTICE와 attribution을 보존한다.
- patent, trademark, service terms와 export restriction을 별도 확인한다.
- shipped inventory에는 binary뿐 아니라 실제 배포되는 source, document,
  asset와 installer를 기록한다.
- 별도 build/service provenance inventory에는 비배포 generator, build tool,
  runtime downloader와 hosted-service 약관도 기록한다.

### 수동 검토

다음은 dependency 추가 전에 수동 승인한다.

- MPL-2.0, EPL, CDDL 같은 file-level 또는 weak copyleft
- LGPL 계열
- GPL 계열에 SPDX `WITH` exception이 있고 그 exception의 적용 가능성이
  별도 승인된 경우
- `OR`/`AND`가 섞인 복합 SPDX expression
- OFL font, CC-BY asset, CC0/Unlicense
- code generator와 generated output의 별도 조건
- 외부 executable이나 사용자가 별도 설치하는 CLI
- model weight, dataset, embedding model, voice model
- SDK/CLI EULA, API terms, brand/trademark assets
- custom 또는 source-available license

MPL-2.0은 file-level copyleft이며 larger proprietary work와 결합할 수 있지만,
배포하는 MPL code와 수정분의 source/notice 의무를 추적해야 한다.
[Mozilla MPL FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)를 확인하고,
기존 UniFFI 승인 기준선과 신규 도입을 분리해 기록한다.

LGPL은 “dynamic link면 무조건 안전”으로 처리하지 않는다. mobile static
link, native bridge, relink 가능성, reverse-engineering 제한, source/notice
제공을 실제 packaging 방식으로 검토한다.

### 기본 차단

다음은 별도 법률·제품 결정 전 merge, bundle, vendor, auto-download,
install script 추가를 차단한다.

- 별도 승인된 SPDX `WITH` exception이 없는 GPL 계열
- AGPL 계열
- EUPL과 그 밖의 strong copyleft
- SSPL 같은 network/source-available 조건
- Business Source License `BUSL-1.1`
- Commons Clause, Elastic License와 field-of-use restriction
- NonCommercial, NoDerivatives
- `UNLICENSED`, `UNKNOWN`, `NOASSERTION`, 또는 artifact/provenance에서 적용
  가능한 license grant를 확인할 수 없음
- all-rights-reserved 또는 재배포/수정 제한 proprietary license

`BSL-1.0`은 Boost Software License이고 `BUSL-1.1`은 Business Source
License다. 이름이 비슷하므로 scanner rule에서 혼동하지 않는다.

No license는 public domain이 아니다. 명시적 grant가 확인되지 않으면 복사,
번들, 수정, 재배포하지 않는다.

## Hermes와 OpenClaw 감사 결과

이번 감사는 외부 저장소를 임시 디렉터리에만 clone해 고정 tag/commit의
LICENSE, notice, manifest, lockfile와 공개 package metadata를 읽는 방식으로
수행했다. dependency 설치가 필요한 교차 검사에서는 lifecycle script를
비활성화했다. LorePia workspace에는 외부 source나 artifact를 복사하지
않았다.

결과는 지정 snapshot의 engineering pre-screen이다. 모든 ClawHub/Skills Hub
항목, 모든 native platform artifact, 서비스 약관과 향후 release까지 청산한
법률 감사가 아니다. 실제 채택 시 정확한 release artifact로 다시 실행한다.

### 상위 저장소

- Hermes Agent
  [`v2026.7.20`](https://github.com/NousResearch/hermes-agent/releases/tag/v2026.7.20)의
  [root LICENSE](https://github.com/NousResearch/hermes-agent/blob/v2026.7.20/LICENSE)는
  MIT다.
- OpenClaw
  [`v2026.7.1`](https://github.com/openclaw/openclaw/releases/tag/v2026.7.1)의
  [root LICENSE](https://github.com/openclaw/openclaw/blob/v2026.7.1/LICENSE)는
  MIT다.
- OpenClaw의
  [THIRD_PARTY_NOTICES](https://github.com/openclaw/openclaw/blob/v2026.7.1/THIRD_PARTY_NOTICES.md)는
  adapted Pi/pi-mono code를 MIT로 기록하지만 일반 package-manager
  dependency 전체 목록은 아니다.

MIT source를 실제로 복사한다고 LorePia 전체를 open source로 만들 필요는
없지만, substantial copied portion에는 원 저작권과 permission notice를
보존해야 한다. 현재 저장소의 낮은 compliance 마찰 목표에는 source,
prompt, schema, test, UI text, asset을 복사하지 않는 no-copy 독자 재구현
방식이 가장 적합하다.

### Hermes의 주의 대상

고정 source와 lock을 조사한 결과, root MIT만 보고 하위 기능을 함께 가져오면
안 된다.

- [WhatsApp bridge lock](https://github.com/NousResearch/hermes-agent/blob/v2026.7.20/scripts/whatsapp-bridge/package-lock.json)은
  Baileys를 통해
  [`libsignal 6.0.0` GPL-3.0](https://github.com/WhiskeySockets/libsignal-node/blob/bcea72df9ec34d9d9140ab30619cf479c7c144c7/LICENSE)을
  설치하며 sharp/libvips 계열 LGPL artifact도 포함한다.
- [Python manifest](https://github.com/NousResearch/hermes-agent/blob/v2026.7.20/pyproject.toml)와
  [resolved lock](https://github.com/NousResearch/hermes-agent/blob/v2026.7.20/uv.lock)의
  기본 closure에도
  [Python CA bundle 2026.5.20](https://pypi.org/project/certifi/2026.5.20/)과
  `pathspec 1.1.1` MPL-2.0,
  `tqdm 4.67.3`의 `(MPL-2.0 AND MIT)`가 있다. optional extra에는
  [`edge-tts 7.2.7`](https://pypi.org/project/edge-tts/7.2.7/),
  [`python-telegram-bot 22.6`](https://pypi.org/project/python-telegram-bot/22.6/),
  [`mautrix 0.21.0`](https://pypi.org/project/mautrix/0.21.0/) 같은
  LGPL/MPL dependency가 있다. root MIT와 별도로 각 file/source/notice
  의무를 추적해야 한다.
- [web-pentest skill](https://github.com/NousResearch/hermes-agent/blob/v2026.7.20/optional-skills/security/web-pentest/SKILL.md)은
  AGPL upstream의 방법론만 참고하고 code를 빌리지 않았다고 명시한다. 반면
  [darwinian-evolver skill](https://github.com/NousResearch/hermes-agent/blob/v2026.7.20/optional-skills/research/darwinian-evolver/SKILL.md)은
  [AGPL-3.0 upstream](https://github.com/imbue-ai/darwinian_evolver/blob/7f12365d2059c47e29068a5a6f498a293148d2a9/LICENSE)을
  설치하고 CLI나 별도 driver subprocess로 호출한다. bundled driver는
  upstream Python API도 직접 import하므로 distribution/runtime 결합을 별도
  법률 검토해야 한다.
- [godmode skill](https://github.com/NousResearch/hermes-agent/blob/v2026.7.20/optional-skills/security/godmode/SKILL.md)은
  metadata가 MIT지만 bundled script와 reference가
  [AGPL-3.0 G0DM0D3](https://github.com/elder-plinius/G0DM0D3/blob/f6301765fb90eb7b336bdf365319cd2fe44b1187/LICENSE)에서
  port됐다고 명시한다. provenance와 license compatibility가 해결될 때까지
  해당 source의 복사·배포를 차단한다.
- [obliteratus skill](https://github.com/NousResearch/hermes-agent/blob/v2026.7.20/optional-skills/mlops/obliteratus/SKILL.md)은
  metadata가 MIT지만 AGPL-3.0 upstream 설치·CLI 실행과 Python API import
  예시를 포함한다. exact upstream revision과 결합 방식이 승인될 때까지
  copy, bundle, auto-install과 runtime integration을 차단한다.
- built-in
  [OpenViking provider](https://github.com/NousResearch/hermes-agent/blob/v2026.7.20/plugins/memory/openviking/README.md)는
  별도 server를 요구하고 시작할 수 있다. upstream server는
  [AGPL-3.0](https://github.com/volcengine/OpenViking/blob/8391d3a7582393fe0c94d5844a83308ade92f2d3/LICENSE)이므로
  SDK/server의 auto-install, bundle과 subprocess 도입을 차단한다.
- bundled
  [PowerPoint skill](https://github.com/NousResearch/hermes-agent/blob/v2026.7.20/skills/productivity/powerpoint/LICENSE.txt)은
  all-rights-reserved proprietary terms를 적용한다. 다른 문서 기능도
  skill/tool별로 별도 확인한다.
- 외부 Hub skill, computer-use/browser driver, font와 UI asset은 각각 별도
  license와 provenance를 가진다.
- 외부 memory/model provider는 code license 외에 data egress와 service
  terms가 있다.

PyPI `hermes-agent==0.19.0`도 artifact별 내용이 다르다.
[release files](https://pypi.org/project/hermes-agent/0.19.0/#files)의 wheel
`bd0bac012aee38a60894781f4597dc29ee7bedb3448540249921f10d3bef327f`에는
root MIT LICENSE file이 있지만 위의 audited skill source는 없다. declared
external dependency의 license는 여전히 별도다. 반면 sdist
`ac986bede64a2785436676c0ea084ec586574f8cb00a9d047e095b435d3e21c0`에는
위 proprietary PowerPoint 자료와 optional skill source도 들어간다. package
metadata의 MIT 표기만 보고 sdist 전체를 승인하지 않는다.

따라서 Hermes runtime, WhatsApp bridge, optional skill, prompt, script,
font, asset을 LorePia에 복사·vendor·auto-install하지 않는다.

### OpenClaw의 주의 대상

공개 [`openclaw@2026.7.1` npm artifact](https://registry.npmjs.org/openclaw/2026.7.1)의
production shrinkwrap를 검사했을 때 단독 조건으로 GPL/LGPL/AGPL 준수를
요구하는 package는 확인되지 않았다. 그러나 이를 “permissive-only”로
요약하면 안 된다.

- JSZip은 `(MIT OR GPL-3.0-or-later)`이므로 MIT branch 선택과 고지를
  기록해야 한다.
- `web-push 3.6.7`은 MPL-2.0, `fast-sha256 1.3.0`은 Unlicense이며,
  optional `sqlite-vec` metadata도 비정규 `MIT OR Apache` 표기다.
- 이 검사는 core npm artifact의 production graph 범위다. monorepo의 모든
  workspace, native artifact, 외부 plugin, runtime download를 승인하지 않는다.

WhatsApp, Signal, QQBot은 core artifact에서 빠지고 필요할 때 설치되는 official
external plugin이다. source root MIT와 공개 plugin artifact의 권리표시·내용을
분리해서 검토해야 한다.

- [WhatsApp source manifest](https://github.com/openclaw/openclaw/blob/v2026.7.1/extensions/whatsapp/package.json)는
  Baileys와 audio-decode를 사용한다. 실제
  [`@openclaw/whatsapp@2026.7.1` artifact](https://registry.npmjs.org/%40openclaw%2Fwhatsapp/2026.7.1)는
  `node_modules`에
  [`libsignal 6.0.0` GPL-3.0](https://github.com/WhiskeySockets/libsignal-node/blob/bcea72df9ec34d9d9140ab30619cf479c7c144c7/LICENSE)을,
  그리고
  [`codec-parser 2.5.0` LGPL-3.0-or-later](https://github.com/eshaz/codec-parser/blob/7834ca161922cd58f5e627d75b7dcc45dcce7e58/LICENSE)을
  실제 포함한다.
- [`@openclaw/qqbot@2026.7.1` artifact](https://registry.npmjs.org/%40openclaw%2Fqqbot/2026.7.1)는
  metadata가 `UNLICENSED`이고 LICENSE가 없는
  `@tencent-connect/qqbot-connector@1.1.0` code를 실제 포함한다.
- [Signal installer](https://github.com/openclaw/openclaw/blob/v2026.7.1/extensions/signal/src/install-signal-cli.ts)는
  GPL-3.0-or-later인
  [`signal-cli`](https://github.com/AsamK/signal-cli/blob/64a629002d078e84bd6bbfb550c1a81a4aa0a8ac/LICENSE)를
  외부 실행하며 일부 경로에서 `releases/latest`를 동적으로 내려받는다.
  version/digest가 고정되지 않으므로 auto-install을 차단한다.
- 세 external plugin의 v2026.7.1 npm metadata와 최상위 artifact에는 plugin
  자체의 license 표기가 없다. monorepo root MIT가 각 공개 artifact에 어떻게
  적용되는지 추정하지 않고 artifact-level 수동 검토 대상으로 둔다.
- Claude Agent SDK, Copilot CLI, audio/video utility, computer-use driver,
  runtime-downloaded model은 각각 별도 약관과 license를 확인해야 한다.

이는 OpenClaw core가 GPL이 됐다는 뜻이 아니다. 선택 plugin과 실제 배포
artifact를 root와 분리하지 않으면 GPL/LGPL/무라이선스 코드를 함께
배포하게 될 수 있다는 뜻이다.

### 동명 프로젝트 차단

[`pjasicek/OpenClaw`](https://github.com/pjasicek/OpenClaw/tree/5ee5740ca98377c76b13b50c84f610b0066a4717)는 AI agent가 아닌
게임 engine이며
[GPL-3.0](https://github.com/pjasicek/OpenClaw/blob/5ee5740ca98377c76b13b50c84f610b0066a4717/LICENSE.txt)이다.
정확한 GitHub owner, repository, tag 또는 commit을 dependency decision record에
기록해 이름 충돌로 들어오지 못하게 한다.

## No-copy 독자 재구현 절차

기능 아이디어를 채택할 때는 다음 절차를 사용한다.

1. 연구 문서에 official public documentation과 고정 revision을 기록한다.
2. 외부의 source 구조, function/schema 이름, prompt, UI 문구를 옮기지 않고
   관찰 가능한 목적과 safety requirement만 중립적으로 적는다.
3. LorePia의 Rust/native ownership과 제품 용어로 독자 설계한다.
4. 외부 source에서 가져온 test vector가 아니라 project-owned synthetic
   fixture와 독자 acceptance test를 만든다.
5. PR에 요구사항별 source URL, 독자 설계 결정, 구현자, 신규 dependency와
   license를 기록한다.
6. reviewer가 copied source, prompt, skill, schema, asset, icon, screenshot,
   sample config가 없는지 확인한다.

연구자와 구현자를 분리하는 것이 실용적이면 분리한다. 그렇지 못하면 적어도
연구 note와 구현 spec 사이에 표현을 그대로 복사하지 않았음을 review한다.
이 절차는 engineering provenance 통제이며, 법률상 형식화된 clean-room
인증을 마쳤다는 뜻이 아니다. 신규 dependency의 license나 patent/terms
검토를 생략하는 수단도 아니다.

## Dependency intake 절차

### 1. 정확한 대상을 고정

- canonical owner/repository/package registry
- exact version, tag와 commit
- artifact digest
- package manager와 enabled feature/extra
- build, test, dev, optional, runtime 중 어느 scope인지

### 2. 권리와 provenance 확인

- root LICENSE
- file header와 subdirectory LICENSE
- THIRD_PARTY_NOTICES
- package metadata와 실제 tarball/wheel/archive 내부 license
- fork/adapted/generated source의 upstream
- logo, font, icon, sample, prompt, model, dataset의 별도 권리

metadata가 MIT라고 해도 bundled file이 다른 license면 실제 file을 기준으로
검토한다.

### 3. transitive graph 확인

- 모든 production feature/extra를 켠 lock graph
- platform별 conditional dependency
- build script가 내려받는 binary
- optional plugin과 installer
- runtime auto-download
- test/CI artifact가 release에 섞이는지

install script는 반드시 disabled 상태로 먼저 inspect한다. 조사 때문에
외부 package의 lifecycle script를 실행하지 않는다.

### 4. 실제 배포물 확인

source tree가 아니라 store에 제출할 APK/AAB, app bundle, MSIX, native
library와 installer를 scan한다.

- SBOM 생성
- license and notice inventory
- source offer/relink requirement
- binary provenance와 signature
- model/asset digest
- unused package가 packaging에서 제거됐는지

### 5. 의사결정 기록

최소 필드:

```text
Component:
Purpose:
Canonical source:
Version / commit / digest:
SPDX expression:
Selected OR branch:
Transitive/optional scope:
Modified:
Distributed:
Notice/source/relink obligations:
Service/model/asset terms:
Decision:
Reviewer and date:
```

## Model, prompt, skill과 asset

Source code scanner만으로 다음 항목을 승인하지 않는다.

### Model

- repository와 exact revision
- weight file SHA-256
- model license와 acceptable-use terms URL
- 상업 이용, redistribution, derivative 허용 여부
- required notice
- 사용자가 동의한 terms version과 시점

license가 없거나 custom terms를 읽지 못한 model은 auto-download하지 않는다.

### Prompt, skill, template

실행 코드가 아니어도 표현물이고 별도 license일 수 있다.

- external skill/prompt를 built-in으로 복사하지 않는다.
- 사용자가 import한 개인 data와 앱이 재배포하는 built-in을 구분한다.
- 사용자 직접 작성물은 `user_authored`, content hash와 timestamp를 기록한다.
- 외부 도입물은 source URL/hash, author, SPDX와 notice를 기록한다.
- unknown license는 앱 bundle, marketplace, sync 대상에서 제외한다.

### Font, icon, image, audio

- repository root license가 asset에 적용되는지 확인한다.
- commercial font license의 양도 가능성을 추정하지 않는다.
- logo와 product character에는 trademark와 personality rights도 확인한다.
- project-owned asset 또는 OS-native symbol을 우선한다.

## CI gate 권고

현재 Rust `cargo deny check`를 유지하고 다음을 단계적으로 추가한다.

- Rust, Gradle, SwiftPM, NuGet의 locked dependency inventory
- exact shipped artifact의 CycloneDX 또는 SPDX SBOM
- SPDX expression을 평가해 승인된 non-blocked branch가 없으면 fail
- `AND`에 차단 조건이 있으면 fail, `WITH`와 custom expression은 manual
- 승인된 `WITH` exception이 없는 GPL, AGPL, EUPL, SSPL, BUSL,
  Commons-Clause, `UNLICENSED`, `UNKNOWN`, `NOASSERTION`과 적용 가능한 grant
  미확인은 selected SPDX branch를 기준으로 fail-closed
- LGPL/MPL/custom license의 approval record check
- third-party notice generation과 drift check
- downloaded binary/model/asset의 URL, revision, digest, license manifest
- PR diff의 new package, script download, vendored source, binary 검사
- optional feature와 platform condition을 포함한 matrix

Scanner success는 승인에 필요한 증거 중 하나일 뿐이다. package metadata가
누락되거나 잘못된 경우를 잡기 위해 사람이 provenance와 실제 artifact를
확인해야 한다.

## 자주 틀리는 판단

### “상위 저장소가 MIT면 plugin도 MIT다”

아니다. subdirectory, plugin, dependency, asset, model, service는 별도 조건을
가질 수 있다.

### “GPL executable을 subprocess로 부르면 무조건 안전하다”

아니다. 별도 설치와 표준 IPC는 coupling을 줄일 수 있지만 자동 면책선이
아니다. LorePia가 다운로드, 번들, patch, 필수 설치하거나 intimate protocol로
결합하면 별도 검토가 필요하다. 판단 근거에는
[GNU GPL FAQ의 aggregation과 communication 구분](https://www.gnu.org/licenses/gpl-faq.html.en)을
포함하되 실제 결합 방식은 별도 법률 검토한다.

### “`MIT OR GPL`이면 GPL이다”

항상 그렇지 않다. `OR`는 허용된 branch를 선택할 수 있다. LorePia가 MIT를
선택했다는 기록과 MIT notice가 필요하다. `AND`와 혼동하지 않는다.

### “무라이선스 GitHub/npm package는 무료로 쓸 수 있다”

아니다. 명시적 권리 grant가 없으므로 fail-closed다.

### “MPL이 있으면 앱 전체를 공개해야 한다”

일반적으로 MPL은 file-level copyleft지만 배포하는 covered/modified file의
source와 notice 의무는 남는다. 현재 UniFFI 사용과 신규 MPL dependency를
각각 기록한다.

## 이번 조사에 따른 결정

- Hermes와 OpenClaw runtime을 dependency, vendor, subprocess로 추가하지
  않는다.
- 두 프로젝트의 code, prompt, skill, schema, test, asset을 복사하지 않는다.
- memory, approval, durable task, delegation 같은 기능 목적만 no-copy
  방식으로 Rust/native에 독립 구현한다.
- WhatsApp/Signal/QQ connector, browser/computer-use driver, 외부 skill
  marketplace는 현재 LorePia 범위에서 제외한다.
- 실제 신규 dependency를 제안할 때 이 문서의 intake record와 artifact
  license scan을 PR의 필수 증거로 제출한다.
