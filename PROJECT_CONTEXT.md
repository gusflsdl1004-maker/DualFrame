# PROJECT_CONTEXT

> 이 문서만 읽고 작업을 이어갈 수 있도록 작성되었습니다.
> 개발 규칙·보고 양식은 `CLAUDE.md`를 따릅니다(여기서 중복하지 않음).
> 최종 갱신: Task 064 (`678980c`)

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
- **저장된 코덱/프로필/레벨** — 파일의 format description에서 직접 파싱. `AVVideoCodecKey`는 요청값일 뿐이고 **레벨은 VideoToolbox가 정하므로**, 인코더가 실제로 어느 레벨로 돌았는지는 이 값으로만 확인 가능

---

## 4. 최근 수정 사항 (058~064)

- **058**: writer 직렬 루프 → TaskGroup 병렬. **fps 변화 없었음**(중요한 음성 결과)
- **059~061**: 측정값을 Debug→Release로 이동. Release가 진짜 증상이 있는 곳이기 때문
- **062**: 두 조건 비교 화면. 조건은 `writerStats.count`로 판별(1=Long Only, 2=Long+Short)
- **063**: 계측이 아닌 **병목 제거** 2건
  - video·audio가 **같은 serial DispatchQueue**를 쓰고 있었음. AVFoundation은 큐 단위로 delegate 콜백을 직렬화하므로, 오디오 콜백이 도는 동안 도착한 비디오 프레임은 대기해야 했고 그게 바로 `FrameWasLate` 조건. Task 052는 AsyncStream만 분리했고 그 아래 큐는 공유 상태로 남아 있었음. 이제 output별 전용 큐 + 명시적 `.userInitiated` QoS
  - `alwaysDiscardsLateVideoFrames`가 상수 → **설정**. Task 055가 `false`로 하드코딩한 뒤 **모든 측정이 `false` 상태에서만 이뤄져 비교 자체가 없었음**. 기본값을 AVFoundation 기본(`discard`)으로 되돌리고, 진단 화면에서 전환 가능하게 함. 어떤 설정이었는지가 각 녹화의 `RecordingDiagnostics`에 함께 저장됨
- **064**: 조사 대상을 캡처 경로 → **인코더 경로**로 전환. 아래 5·6절이 이 결과로 바뀜

---

## 5. 아직 해결되지 않은 문제

**4K60이 나오지 않는다.**

| 조건 | 저장 FPS | 프레임당 | 측정 시점 |
|---|---|---|---|
| Long Only | ~50fps → **~40fps** | 20.0 → 25.0ms | 062 이전 → 063 이후 |
| Long + Short | ~36.6fps → **~35fps** | 27.3 → 28.6ms | 062 이전 → 063 이후 |
| (예산) | 60fps | 16.7ms | |

Release 빌드 + Xcode 분리 상태에서도 동일하게 재현됨.

**Task 063의 큐 분리로 개선되지 않았다.** Long Only는 오히려 50→40으로 내려갔는데, 이것이 큐 분리의 회귀인지 측정 편차/발열인지는 **구분되지 않았다**(같은 조건 재측정 없음). 판단 보류 항목이며, 필요하면 `bc2aa11` 되돌리기로 1회 검증 가능.

---

## 6. 현재 가장 유력한 원인

**H.264로는 4K60을 인코딩할 수 없다. 사양 밖이다.**

H.264 레벨은 해상도가 아니라 **매크로블록 처리량**으로 프레임레이트를 제한한다.
4K 1프레임 = (3840/16)×(2160/16) = **32,400 매크로블록**.

| Level | MaxMBPS | 4K 최대 |
|---|---|---|
| 5.0 | 589,824 | 18fps |
| **5.1** | **983,040** | **30fps** |
| 5.2 | 2,073,600 | 64fps |

Apple의 하드웨어 H.264 인코더는 iPhone에서 **Level 5.1을 넘지 않는다.** iOS 자체 카메라가 "고효율"(HEVC)에서만 4K60을 제공하고 "높은 호환성"(H.264)에서는 4K 24/30만 제공하는 이유가 이것이다.

`RecordingService`는 작성 시점부터 `AVVideoCodecKey: .h264`를 하드코딩하고 있었다. **이 프로젝트의 모든 4K60 측정은 사양상 60fps에 도달할 수 없는 인코더 설정에서 이뤄졌다.**

지금까지 측정된 모든 것과 모순이 없다:
- writer는 제안받은 것을 수락한다(99.6~98%) — 인코더 큐가 아니라 **인코더 처리량**이 한계
- Long 단독 20ms/frame 중 append 1.75ms, **나머지 18ms가 우리 코드 밖** = VideoToolbox
- 캡처 단계 최적화 6종을 모두 적용해도 변화가 없었다

**아직 확정은 아니다.** `.auto`가 HEVC를 고르고도 60fps가 나오지 않으면 이 가설은 틀린 것이고, 그때는 발열/지속 처리량 한계(`Discontinuity`)로 넘어간다. 진단의 **저장된 코덱/레벨**이 그 판정의 근거다.

---

## 7. 실험 결과 및 측정값 요약

### 확정된 수치 (Release, 실기기)
```
Long Only        저장 50fps
Long + Short     저장 36.6fps,  도착 38.7fps,  lateDropped 291
writer 수락률    Long 99.6% / Short 99.8%
평균 append      Long 1.75ms / Short 0.66ms
```

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
- **가장 큰 것 — 053~063 (11개 Task)**: 인코더 설정을 한 번도 의심하지 않고 캡처 경로만 팠다. `AVVideoCodecKey: .h264`는 처음부터 코드에 있었고, H.264 레벨 한계는 **계산으로 즉시 확인 가능한 사실**이었다. 교훈: 파이프라인 조사는 **양 끝을 먼저 확인**할 것. 소스(카메라 공급)는 Task 054에서 60.4fps로 확인했지만 싱크(인코더 사양)는 확인하지 않았다

---

## 8. 다음 작업 우선순위

### 먼저: Task 064 측정 — 1회로 판정된다

Release, 4K60, Long만 저장, 10초. **코덱 = 자동(기본값)이면 별도 설정 없이 바로.**

진단 → 해당 기록 → **인코더 → 저장된 포맷**을 본다.

| 저장된 포맷 | 저장 FPS | 판정 |
|---|---|---|
| `hvc1 … level=5.1` | **~60fps** | **원인 확정.** H.264 레벨 한계였음. 종료 |
| `hvc1 … level=5.1` | 여전히 ~40fps | 코덱이 아님 → 발열/지속 처리량으로 이동 |
| `avc1 …` | — | `.auto` 판정 로직 버그. 코드 확인 |

### 그 다음 (위에서 확정되지 않은 경우에만)

같은 조건으로 하나씩만 바꿔 비교한다. 한 번에 하나씩.

1. 비트레이트: 설정 → 녹화 화질 → **절반** (4K60 100Mbps → 50Mbps)
2. 키프레임 간격: 진단 → **2초** 또는 **4초**
3. 저장 방식을 Long + Short로 바꿔 crop 비용 재확인

### 그래도 안 되면

- **발열/지속 처리량**: 10초가 아니라 **3분 이상** 녹화해 FPS가 시간에 따라 떨어지는지 본다. 떨어지면 코드 문제가 아니다
- **4K 프리뷰 레이어**: 세션에 바인딩된 `AVCaptureVideoPreviewLayer`는 data output 풀을 쓰지 않지만 매 프레임을 렌더 서버에서 축소한다. 제거할 수 없으므로(뷰파인더) 측정 방법부터 설계해야 함
- **Task 063 큐 분리 회귀 여부**: Long Only 50→40이 큐 분리 탓인지 미확정. `bc2aa11` 되돌리기로 1회 검증 가능

### 현실적 결론 가능성

위가 모두 소진되면 **"4K는 30fps, 60fps는 1080p"**가 이 기기의 한계일 수 있다. 그 경우 UI에서 4K60을 조용히 폴백시키지 말고 **명시적으로 안내**할 것.

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
