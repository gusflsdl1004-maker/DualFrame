# PROJECT_CONTEXT

> 이 문서만 읽고 작업을 이어갈 수 있도록 작성되었습니다.
> 개발 규칙·보고 양식은 `CLAUDE.md`를 따릅니다(여기서 중복하지 않음).
> 최종 갱신: Task 062 (`756c216`)

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

---

## 3. 현재 코드 상태

### 아키텍처
```
AVCaptureSession
 ├─ videoOutput (AVCaptureVideoDataOutput)  ─┐
 ├─ audioOutput (AVCaptureAudioDataOutput)  ─┤
 └─ previewLayer는 session에 직접 바인딩      │ (data output 풀 사용 안 함)
                                             ↓
SampleBufferOutputForwarder (nonisolated class, 캡처 큐)
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
- **"Long vs Long+Short 비교"** 화면 (두 조건 2열)

---

## 4. 최근 수정 사항 (058~062)

- **058**: writer 직렬 루프 → TaskGroup 병렬. **fps 변화 없었음**(중요한 음성 결과)
- **059~061**: 측정값을 Debug→Release로 이동. Release가 진짜 증상이 있는 곳이기 때문
- **062**: 두 조건 비교 화면. 조건은 `writerStats.count`로 판별(1=Long Only, 2=Long+Short)

---

## 5. 아직 해결되지 않은 문제

**4K60이 나오지 않는다.**

| 조건 | 저장 FPS | 프레임당 |
|---|---|---|
| Long Only | ~50fps | 20.0ms |
| Long + Short | ~36.6fps | 27.3ms |
| (예산) | 60fps | 16.7ms |

Release 빌드 + Xcode 분리 상태에서도 동일하게 재현됨.

---

## 6. 현재 가장 유력한 원인

**프레임이 writer에 도달하기 전에 사라진다 — AVCaptureVideoDataOutput 단계.**

근거:
- writer는 **제안받은 것의 99.6~99.8%를 수락**하는데, **초당 36.6장만 제안**된다
- 도착 FPS 38.7, lateDropped 291 (AVFoundation이 delegate 호출 **전에** 버림)
- **산술이 결정적**: Long 단독 20ms/frame인데 자기 append는 1.75ms. **나머지 18ms는 우리 코드 밖**

**미확정**: 드롭 사유(FrameWasLate / OutOfBuffers / Discontinuity)를 아직 실측하지 못했다. Task 060에서 계측은 배포됨, 측정만 남음.

**주의해야 할 가능성**: `Discontinuity`로 나오면 발열/리소스 압박이며 **코드로 해결 불가**. 그 경우 "4K는 30fps, 60fps는 1080p"가 현실적 결론일 수 있다.

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

---

## 8. 다음 작업 우선순위

1. **Release 빌드로 두 조건 각각 10초 이상 녹화** → 설정 → 진단 → "Long vs Long+Short 비교" 화면 확인
   - 두 녹화 길이를 비슷하게 맞출 것(누적 카운트 비교가 왜곡됨)
2. **드롭 사유 분포에 따라 분기**:
   - `OutOfBuffers`가 듀얼에서만 → crop이 소스 버퍼를 붙잡는 것. crop 최적화
   - `OutOfBuffers`가 양쪽 다 → 버퍼 보유 구조. **`alwaysDiscardsLateVideoFrames`를 `true`로 되돌려 비교**(Task 055 변경이 큐잉으로 풀을 더 먹는 가설의 직접 검증)
   - `FrameWasLate` → delegate 큐 점유 계측(Task 060 item 2, 의도적으로 보류해둠)
   - `Discontinuity` → 발열/리소스. 코드 문제 아님. 장시간 발열 측정으로 전환
3. **crop 실측값이 7.3ms 한계비용을 설명하는지** 확인
4. 위가 정리된 뒤에야 비트레이트 하향(Task 049에서 4K60을 ~100Mbps로 올림) 재검토

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
