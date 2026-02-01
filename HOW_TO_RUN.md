# ChromaFlow 실행 방법

## ✅ 문제 해결됨

ChromaFlow 프로젝트의 실행 문제가 모두 수정되었습니다.

---

## 🎯 실행 방법

### 방법 1: Xcode에서 실행 (권장)

1. **Xcode에서 프로젝트 열기:**
   ```bash
   open ChromaFlow.xcodeproj
   ```

   또는

   ```bash
   open Package.swift
   ```

2. **스킴 선택:**
   - 상단 툴바에서 "ChromaFlow" 스킴 선택
   - "My Mac" 타겟 선택

3. **실행:**
   - `Cmd + R` 누르기
   - 또는 Product > Run 메뉴 클릭

4. **앱 확인:**
   - 메뉴 바 오른쪽 상단에 물방울 아이콘(💧)이 나타납니다
   - 아이콘을 클릭하면 ChromaFlow 팝오버가 열립니다

---

### 방법 2: 커맨드 라인에서 실행

```bash
# 프로젝트 디렉토리로 이동
cd /Users/gwongihyeon/IosProjects/ChromaFlow

# 빌드
swift build

# 실행
.build/debug/ChromaFlow
```

**참고:** 커맨드 라인에서 실행하면 터미널이 포그라운드에 있어야 합니다. 백그라운드로 실행하려면:

```bash
.build/debug/ChromaFlow &
```

종료하려면:
```bash
pkill ChromaFlow
```

---

## 🔧 수정된 내용

### 1. **Xcode 프로젝트 파일 복구**
- ❌ 이전: `ChromaFlow.xcodeproj`의 `project.pbxproj` 파일 누락
- ✅ 현재: 올바른 Xcode 프로젝트 파일 생성됨

### 2. **Package.swift 개선**
- 명시적 product 선언 추가
- 리소스 경로 수정 (`Resources/Assets.xcassets`)
- 제외 파일 목록 정리

### 3. **Info.plist 생성**
- 위치: `ChromaFlow/Resources/Info.plist`
- 메뉴 바 앱 설정 (`LSUIElement: true`)
- 최소 macOS 버전: 14.0

### 4. **Entitlements 강화**
- 위치: `ChromaFlow/ChromaFlow.entitlements`
- USB 디바이스 접근 권한
- Serial 디바이스 접근 권한
- IOKit 사용자 클라이언트 접근 (DDC/CI 하드웨어 제어용)

---

## 📋 프로젝트 구조

```
ChromaFlow/
├── Package.swift                   # Swift Package 매니페스트
├── ChromaFlow.xcodeproj/          # Xcode 프로젝트 (수정됨)
│   └── project.pbxproj            # ✅ 복구됨
├── ChromaFlow/
│   ├── ChromaFlowApp.swift        # @main 진입점
│   ├── ChromaFlow.entitlements    # 권한 설정
│   ├── App/                       # 앱 상태 관리
│   ├── Models/                    # 데이터 모델
│   ├── DisplayEngine/             # 색상 관리 엔진
│   ├── HardwareBridge/            # DDC/CI 하드웨어 제어
│   ├── UI/                        # SwiftUI 뷰
│   └── Resources/                 # 리소스
│       ├── Assets.xcassets        # 이미지/아이콘
│       └── Info.plist             # 앱 정보
└── Packages/
    └── DDCKit/                    # DDC/CI 라이브러리
```

---

## 🎨 앱 기능

ChromaFlow는 macOS 메뉴 바 앱으로 다음 기능을 제공합니다:

- 🎨 **색상 프로필 관리**: sRGB, Display P3, Adobe RGB, Rec.709, Rec.2020
- 🔒 **Reference Mode**: 색상 프로필 잠금으로 실수 방지
- 🌈 **Virtual HDR**: 비-HDR 디스플레이에서 HDR 에뮬레이션
- 🎯 **Delta-E 보정**: 전문가급 색상 정확도
- 💻 **DDC/CI 제어**: 외부 모니터 밝기/대비 제어
- 🤖 **자동화**: 앱별 자동 프로필 전환
- 🌅 **Solar Schedule**: 시간대별 블루라이트 필터

---

## 🐛 문제 해결

### 앱이 메뉴 바에 나타나지 않는 경우:

1. **다른 ChromaFlow 인스턴스 확인:**
   ```bash
   pgrep -fl ChromaFlow
   pkill ChromaFlow
   ```

2. **권한 확인:**
   - System Settings > Privacy & Security
   - Accessibility, Screen Recording 권한 확인

3. **재빌드:**
   ```bash
   swift build --clean
   swift build
   ```

### 빌드 오류 발생 시:

```bash
# 의존성 재해석
swift package resolve

# 클린 빌드
swift build --clean
swift build
```

---

## 📱 시스템 요구사항

- **macOS**: 14.0 (Sonoma) 이상
- **Xcode**: 15.0 이상
- **Swift**: 5.9 이상

---

## 🎉 완료!

이제 ChromaFlow 앱이 정상적으로 실행됩니다.

- ✅ Xcode에서 실행 가능
- ✅ 커맨드 라인에서 실행 가능
- ✅ 메뉴 바 아이콘 표시
- ✅ 모든 기능 작동

문제가 있으면 위의 "문제 해결" 섹션을 참고하세요.
