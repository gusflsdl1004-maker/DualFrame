# PROJECT_CONTEXT

> 이 문서만 읽고 작업을 이어갈 수 있도록 작성되었습니다.
> 개발 규칙·보고 양식은 `CLAUDE.md`를 따릅니다(여기서 중복하지 않음).
> 최종 갱신: Task 068 (`c81efa1`)

---

## 1. 프로젝트 목적

**DualFrame** — iOS 카메라 앱. 녹화 버튼 한 번으로

- **Long-form** (16:9, 사용자가 고른 화질/FPS)
- **Short-form** (9:16, 1080×1920, 소스를 center-crop)

두 파일을 **동시에** 저장한다.

최우선 원칙: **녹화된 영상을 절대 잃지 않는다.** 안정성 > 화질 > UI > 신기능.

---

## 2. 완료된 작업

### 기능 (041~050)
| Task | 내용 |
|---|---|
| 041 | 저장 공간 / 예상 촬영 가능 시간 표시 |
| 042 | 저장 방식(Long만 / Long+Short)을 사용자 개념으로 도입, `RecordingMode`는 내부 전용으로 유지 |
| 042-revised | "Short만 저장" 제거 — `RecordingService`에 실제 short-only 능력이 없어 UI가 거짓말을 하고 있었음 |
| 043 | 실기기 버그 수정 + 카메라 줌(렌즈 버튼·슬라이더·핀치) |
| 044 | 줌 렌즈 열거 수정, 캡처 버퍼 전달 설정 |
| 045 | 캡처 구성 원자성, 줌 ramp, 상태바 레이아웃 |
| 046 | **듀얼 모드 writer가 화질/FPS를 무시하던 버그 수정** (`OutputProfile.longForm`이 1920×1080@30 하드코딩) |
| 047 | 요청 포맷을 지원하는 카메라를 선택하도록 변경 |
| 049 | 능력 판정 구현 3개를 `DeviceCapabilityService` 하나로 통합, `AVVideoAverageBitRateKey` 명시 |
| 050 | Recording HUD, 비트레이트 프리셋(표준/고화질/최고화질), FPS 화면 실시간 갱신, 줌 배율 표시, Debug 정보 분리 |
| 051 | "녹화 이어하기" UI 제거 |
| 052 | Landscape 전용 레이아웃 |

### 성능 조사 (048, 053~062)
| Task | 내용 |
|---|---|
| 048 | crop / write / actorHold 계측 |
| 052 | video·audio 전달 스트림 분리 |
| 053 | append 경로 단계별 계측(7단계) |
| 054 | 캡처 경로 계측(4지점 + output 설정) |
| 055 | 버퍼 깊이 12→2, `alwaysDiscardsLateVideoFrames=false` |
| 056 | `CIContext(cacheIntermediates: false)` + autoreleasepool |
| 057 | 모든 debug print를 비동기 `debugLog`로 (33곳) |
| 057b | 성능 수치 4종을 **Release 진단 화면**에 노출 |
| 058 | **Long/Short writer 병렬화** (TaskGroup) |
| 059 | writer별 시도/성공/notReady/평균 append 통계 (Release) |
| 060 | `kCMSampleBufferAttachmentKey_DroppedFrameReason` 집계 (Release) |
| 061 | Short 전용 경로 전수 열거 + crop 실측을 Release로 |
| 062 | **Long Only vs Long+Short 비교 화면** |
| 063 | **video/audio delegate 큐 분리** + `alwaysDiscardsLateVideoFrames`를 런타임 전환 가능하게 |
| 064 | **인코더 경로**: H.264 4K60이 하드웨어 사양 밖임을 확인, 코덱 자동 선택 + B-frame 비활성 |
| 065 | 코덱 결정 기록 + 듀얼 readback이 서로 덮어쓰던 버그 수정 |
| 066 | 발열 상태(시작/최고/종료) + 드롭 사유 집계 출력 |
| 067 | 드롭 프레임 attachment 전체 덤프 + backlog/uptime/thermal/PTS |
| 068 | **VTPixelTransferSession crop 추가** (CoreImage와 설정 전환) |

---

## 3. 현재 코드 상태

### 아키텍처
```
AVCaptureSession
 ├─ videoOutput → videoSampleBufferQueue (serial, .userInitiated)  ─┐
 ├─ audioOutput → audioSampleBufferQueue (serial, .userInitiated)  ─┤  ← 063: 큐 분리
 └─ previewLayer는 session에 직접 바인딩                             │ (data output 풀 사용 안 함)
                                                                    ↓
SampleBufferOutputForwarder (nonisolated class, 각 캡처 큐)
 ├─ videoStream  AsyncStream, bufferingNewest(2) → 단일 consumer
 └─ audioStream  AsyncStream, bufferingNewest(24) → 단일 consumer
                                             ↓
RecordingService (actor)
 └─ append(): writer들을 TaskGroup으로 **병렬** 처리
      ├─ Long-form  : input.append(sampleBuffer)          (crop 없음)
      └─ Short-form : VideoFrameCropper → adaptor.append   (crop 있음)
```

### 핵심 규칙 (변경 시 주의)
- **orientation은 `OrientationManager`만 계산.** `RecordingService`는 writer만 관리
- `OutputProfile.longForm`/`.shortForm` 상수는 **데이터가 아니라 식별자** — dictionary key, `profile == .shortForm`(crop 분기), `statuses[.longForm]` 조회에 쓰임. 필드를 바꾸면 Equatable identity가 깨져 crop이 조용히 멈춤
- 실제 writer 해상도/FPS는 `effectiveWriterFormat(for:)`가 `activeQuality`/`activeFPS`에서 계산
- `BitrateEstimationService`가 **인코더와 저장공간 예측의 단일 정의**
- `DeviceCapabilityService`가 **"어떤 카메라" + "그 포맷 가능한가"의 단일 구현** (Settings·capture 공용)

### Release에서 볼 수 있는 진단 (설정 → 진단)
- 저장된 파일 FPS / 실제 도착 FPS / 전달된 프레임
- late drop(카메라) / stream drop(소비자)
- **카메라 프레임 드롭 사유** (FrameWasLate / OutOfBuffers / Discontinuity)
- writer별: 시도·성공·notReady·수락률·평균 append·crop(render/pool)
- **"Long vs Long+Short 비교"** 화면 (두 조건 2열, 상단에 캡처 설정 필터)
- **캡처 실험 스위치**: `늦은 프레임 버림`(기본) ↔ `늦은 프레임 대기`. 다음 녹화부터 적용되고, 어떤 설정이었는지가 각 기록에 저장됨
- **인코더 실험 스위치**: 코덱(자동/H.264/HEVC), 키프레임 간격(1/2/4초). 비트레이트는 설정 → 녹화 화질의 프리셋(절반/표준/고화질/최고화질)
- **코덱 결정 기록** (065) — `Long-form: auto 3840x2160@60 → hvc1`. writer를 만드는 시점의 판단
- **저장된 코덱/프로필/레벨** — 파일의 format description에서 직접 파싱. `AVVideoCodecKey`는 요청값일 뿐이고 **레벨은 VideoToolbox가 정하므로**, 인코더가 실제로 어느 레벨로 돌았는지는 이 값으로만 확인 가능
- 위 두 가지는 **다른 질문에 답한다**: 요청한 것 vs 나온 것. 어긋나면 그 자체가 단서
- **발열 상태** (066) — 시작 / **최고** / 종료. 시작값만으로는 스로틀링을 볼 수 없어서 3개를 기록한다. `nominal → serious`면 도중에 스로틀된 것
- 앱 내 로그 링버퍼에 `[Task066-Thermal]`, `[Task066-Drop]`이 남는다 (Release에서도)

---

## 4. 최근 수정 사항 (058~068)

- **058**: writer 직렬 루프 → TaskGroup 병렬. **fps 변화 없었음**(중요한 음성 결과)
- **059~061**: 측정값을 Debug→Release로 이동. Release가 진짜 증상이 있는 곳이기 때문
- **062**: 두 조건 비교 화면. 조건은 `writerStats.count`로 판별(1=Long Only, 2=Long+Short)
- **063**: 계측이 아닌 **병목 제거** 2건
  - video·audio가 **같은 serial DispatchQueue**를 쓰고 있었음. AVFoundation은 큐 단위로 delegate 콜백을 직렬화하므로, 오디오 콜백이 도는 동안 도착한 비디오 프레임은 대기해야 했고 그게 바로 `FrameWasLate` 조건. Task 052는 AsyncStream만 분리했고 그 아래 큐는 공유 상태로 남아 있었음. 이제 output별 전용 큐 + 명시적 `.userInitiated` QoS
  - `alwaysDiscardsLateVideoFrames`가 상수 → **설정**. Task 055가 `false`로 하드코딩한 뒤 **모든 측정이 `false` 상태에서만 이뤄져 비교 자체가 없었음**. 기본값을 AVFoundation 기본(`discard`)으로 되돌리고, 진단 화면에서 전환 가능하게 함. 어떤 설정이었는지가 각 녹화의 `RecordingDiagnostics`에 함께 저장됨
- **064**: 조사 대상을 캡처 경로 → **인코더 경로**로 전환. 아래 5·6절이 이 결과로 바뀜
- **065**: 코덱 검증 전용. 결정 기록 + `canApply` 가드 + **듀얼 readback 버그 수정**(아래 7절 참조)
- **066**: 발열 계측. 드롭 사유 집계는 060에 이미 있었고 출력 형식만 추가

---

## 5. 해결된 것 / 남은 것

### ✅ 해결: 4K60 Long Only = **59.47fps** (iPhone 12, Task 064)

**원인은 H.264 레벨 한계였다.** H.264는 해상도가 아니라 **매크로블록 처리량**으로 프레임레이트가 제한된다. 4K 1프레임 = (3840/16)×(2160/16) = **32,400 매크로블록**.

| Level | MaxMBPS | 4K 최대 |
|---|---|---|
| 5.0 | 589,824 | 18fps |
| **5.1** | **983,040** | **30fps** |
| 5.2 | 2,073,600 | 64fps |

Apple의 하드웨어 H.264 인코더는 iPhone에서 Level 5.1을 넘지 않는다. iOS 카메라가 "고효율"(HEVC)에서만 4K60을 주고 "높은 호환성"(H.264)에서는 4K 24/30만 주는 이유가 이것이다.

`RecordingService`는 작성 시점부터 `AVVideoCodecKey: .h264`를 하드코딩하고 있었다. **053~063의 모든 측정이 사양상 60fps가 불가능한 설정에서 이뤄졌다.** Task 064에서 `.auto`(4K60만 HEVC)로 바꾸자 40 → 59.47fps.

**이로써 무혐의가 확정된 것**: 카메라 공급, 캡처 경로, AsyncStream, 버퍼 풀, actor, writer, HEVC 인코더, 발열, 10-bit HDR(측정값 `420v` = 8-bit).

### ❌ 남은 것: Long + Short = **51.64fps**

| 조건 | 저장 FPS | 프레임당 |
|---|---|---|
| Long Only | **59.47fps** | 16.815 ms |
| Long + Short | **51.64fps** | 19.365 ms |
| 차이 (Short 한계비용) | | **+2.550 ms** |

**천장은 59.47fps다.** Short를 완전히 공짜로 만들어도 60fps는 나오지 않는다.

---

## 6. 현재 원인 — Short crop 경로

`VideoFrameCropper`가 **CoreImage**를 쓰는데, CoreImage는 항상 선형 RGB 작업공간에서 동작한다. 따라서 프레임마다:

```
캡처 420v(YCbCr) ──CIContext.render──▶ 32BGRA ──HEVC 인코더──▶ YCbCr
                   (변환 1 + crop/scale)      (변환 2, 되돌림)
```

서로 상쇄되는 색공간 변환 2회 + 중간 버퍼 **8.29MB**(420v면 3.11MB, 2.7배).

**Task 068에서 `VTPixelTransferSession` 구현을 추가**했다. YCbCr을 유지하므로 변환 2와 대역폭이 사라진다. CoreImage 구현은 그대로 두고 **진단 화면에서 전환**한다 — 색·선명도는 빌드가 판정할 수 없어 즉시 롤백 수단이 필요하기 때문.

측정 대기 중.

---

## 7. 실험 결과 및 측정값 요약

### 확정된 수치 (Release, 실기기)
```
Long Only        저장 50fps  → 063 이후 40fps
Long + Short     저장 36.6fps → 063 이후 35fps,  도착 38.7fps,  lateDropped 291
writer 수락률    Long 99.6% / Short 99.8%
평균 append      Long 1.75ms / Short 0.66ms
```

> **⚠ 듀얼 모드 "저장 FPS"는 Task 065 이전까지 신뢰할 수 없다.**
> `writerContexts.keys`는 Dictionary라 순회 순서가 정의되지 않는데,
> `lastSavedNominalFrameRate`/`lastSavedVideoFormat`을 매 반복마다 무조건 대입하고
> 있었다. 즉 듀얼에서는 **마지막에 끝난 writer의 값**이 남았고, 그게 Long인지
> Short인지는 실행마다 달랐다. 36.6fps가 4K Long이 아니라 1080×1920 Short의
> 수치였을 수 있다. 065에서 profile별로 기록하도록 수정 — **이후 측정만 유효.**

### 확정된 수치 (Debug, 실기기)
```
appendTotal      ~2ms
actorWait        ~0.05ms
yield→consumer   0.09ms
captureEntry→append  0.12ms
callback interval    ~16.5ms (=60.4fps, 카메라는 정상 공급)
bufferDepth=2 시 inFlight max 1~3, yielded == released (누수 없음)
```

### 과거 회귀 이력 (git 기준)
- **Task 043 (`0ad66f0`)**: 카메라 바인딩을 단일 광각 → 가상 멀티렌즈로 변경. 그 디바이스의 4K 포맷이 30fps 상한이라 **4K60 녹화가 여기서 깨짐**. Task 047(`39a14bf`)에서 포맷 인식형 선택으로 수정
- **Task 050 (`72b40fb`)**: FPS 화면이 stale 화질을 읽던 버그 수정. 그 결과 **4K60이 "선택 불가"로 보이기 시작** — 기능을 없앤 게 아니라 이미 참이던 판정이 드러난 것

### 내가 만들고 되돌린 자책골 (재발 방지용)
- 047b: 버퍼 깊이 12 → 캡처 풀 고갈 (055에서 2로 수정)
- 021: 기본 `CIContext`가 소스 버퍼 retain (056에서 캐시 비활성)
- 048~056: debug `print()`가 actor/캡처 큐를 막음 (057에서 비동기화). **단 Release 재현으로 이건 주원인이 아님이 확인됨**
- 047b: GeometryReader 안 `.ignoresSafeArea()`로 HUD가 화면 밖으로 잘림 (ZStack으로 수정)
- 052: AsyncStream만 분리하고 그 아래 **DispatchQueue는 공유로 남겨둠** — 절반만 고친 분리였음 (063에서 완료)
- 055: `alwaysDiscardsLateVideoFrames=false`를 **검증 없이** 하드코딩. 이후 모든 측정이 이 값에서만 이뤄져 비교 불가 상태를 8개 Task 동안 유지 (063에서 설정으로 전환)
- 019~064: 듀얼 모드에서 `lastSavedNominalFrameRate`/`lastSavedVideoFormat`이 **비결정적으로 덮어써짐**. Dictionary 순회 순서에 의존. 판단 근거로 쓰던 수치 자체가 어느 writer의 것인지 불명이었다 (065에서 profile별 기록으로 수정)
- **가장 큰 것 — 053~063 (11개 Task)**: 인코더 설정을 한 번도 의심하지 않고 캡처 경로만 팠다. `AVVideoCodecKey: .h264`는 처음부터 코드에 있었고, H.264 레벨 한계는 **계산으로 즉시 확인 가능한 사실**이었다. 교훈: 파이프라인 조사는 **양 끝을 먼저 확인**할 것. 소스(카메라 공급)는 Task 054에서 60.4fps로 확인했지만 싱크(인코더 사양)는 확인하지 않았다

---

## 8. 다음 작업 우선순위

### 먼저: Task 068 측정 — 같은 iPhone 12, 4회

진단 → **Short crop 실험**에서 구현을 바꿔가며 측정한다.

| # | Short crop 구현 | 저장 방식 | 목적 |
|---|---|---|---|
| 1 | CoreImage (기본) | Long만 | 기준선 재확인 (crop 안 함, 59.47 나와야 정상) |
| 2 | CoreImage | Long + Short | 기준선 (51.64) |
| 3 | VideoToolbox | Long만 | 1과 같아야 정상 — 다르면 뭔가 잘못된 것 |
| 4 | **VideoToolbox** | **Long + Short** | **본 측정** |

각 10초 이상, 길이를 비슷하게. 확인할 값:

- 저장 FPS (목표: 4번이 59.47에 근접)
- 진단 → **crop 평균 / CIContext render / PixelBuffer 생성** — VT에서 얼마나 줄었나
- 진단 → 인코더 → **Short crop 구현** (어느 구현이었는지 기록됨)

**빌드가 판정할 수 없는 것 — 반드시 눈으로**:
- Short 영상의 **색·밝기**. `420v`는 video range라 full range로 오인되면 뜨거나 눌려 보인다. Long은 멀쩡한데 Short만 이상하면 이 문제다
- Short 영상의 **선명도**. CoreImage와 VT 스케일러 결과가 다를 수 있다

이상하면 진단에서 CoreImage로 되돌리면 끝. 재빌드 불필요.

### 판정 후

- **4번이 ~59fps + 화질 정상** → 완료. CoreImage 경로 유지 여부만 결정
- **4번이 개선됐지만 부족** → 남은 비용이 곧 스케일 연산 자체. Short 독립 큐(프레임을 버려서라도 Long 60fps 보호) 검토
- **4번이 개선 없음** → crop이 아니라 `adaptor.append`나 두 번째 인코더 세션 자체가 비용. 인코더 2개 동시 구동의 한계로 넘어감
- **색이 깨짐** → `CVBufferPropagateAttachments`만으로 부족한 것. `kVTPixelTransferPropertyKey_Destination*` 명시 설정 필요

### 미해결 보류 항목

- **Task 063 큐 분리 회귀 여부**: Long Only 50→40이 큐 분리 탓인지 끝내 귀속 못 함. 이후 코덱 수정으로 59.47이 나와 **실익이 사라졌으므로 종결**
- **4K 프리뷰 레이어**: Apple Camera와 동일 방식(`previewLayer.session = session`)이고 Metal/CoreImage 추가 렌더링 없음이 코드로 확인됨. **후보에서 제외**

---

## 9. 주의사항

### 다시 조사하지 말 것 (이미 배제됨)
| 항목 | 배제 근거 |
|---|---|
| **Writer / AVAssetWriterInput** | 수락률 99.6~99.8%, append 1.75/0.66ms |
| **Debug print 오버헤드** | Release + Xcode 분리에서 동일하게 36fps 재현 |
| **Long/Short 직렬 처리** | Task 058 병렬화 후 fps 변화 없음 |
| **경쟁 Output** | 세션에 video/audio output 2개뿐. Photo/Movie/Metadata output 없음. preview는 session에 바인딩되어 data output 풀 미사용 |
| **RecordingService actor 블로킹** | actorWait ~0.05ms |
| **AsyncStream 전달** | yield→consumer 0.09ms, end-to-end 0.12ms |
| **activeFormat / frameDuration** | 코드 검증 완료. `activeFormat` 대입 **후** frame duration 설정(순서 중요) |
| **타임스탬프 / mediaTimeScale** | 소스 PTS 그대로 사용, mediaTimeScale 기본값이 정답 |
| **Settings와 capture의 능력 판정 불일치** | Task 049에서 단일 구현으로 통합 |
| **버퍼 누수** | yielded == released, inFlight max 1~3 |

### 작업 시 주의
- **이 환경에는 실기기가 없다.** 시뮬레이터에는 카메라가 없어 캡처/녹화 경로가 실행되지 않는다. 성능·화질·발열은 **전부 사용자 실기기 측정에 의존**한다
- **측정 데이터 없이 추측으로 수정하지 말 것.** 이 프로젝트에서 추측성 수정은 두 번 새 버그를 만들었다
- **`strings`로 한글 문자열을 검증할 수 없다.** Release에 확실히 있는 "녹화 시작"도 0으로 나온다. ASCII 태그(`Task0xx`)만 유효한 증거이며, Debug 분리 검증은 **소스 레벨 감사**로 해야 한다
- **xcodebuild가 재컴파일 없이 "BUILD SUCCEEDED"를 출력할 수 있다.** 스크립트로 파일을 수정한 뒤에는 dylib 타임스탬프와 심볼까지 확인할 것
- `project.pbxproj`에 `DEVELOPMENT_TEAM`이 자동 주입된다. 커밋에 포함하지 말 것
- 커밋은 Task당 하나, 커밋 후 push까지 완료할 것
