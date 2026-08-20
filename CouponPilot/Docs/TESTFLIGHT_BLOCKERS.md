# TestFlight 배포 보류 메모

작성일: 2026-08-19

## 배포 전 외부 설정

1. Firebase iOS 설정 파일
   - Xcode 프로젝트에는 `GoogleService-Info.plist`가 등록되어 있으나 실제 파일이 없습니다.
   - Firebase Console에서 번들 ID `com.couponpilot.app`용 파일을 다시 다운로드해 `CouponPilot/GoogleService-Info.plist`로 추가해야 합니다.

2. Apple 서명 팀
   - 프로젝트 설정 팀 ID: `5M7Y3K8P3C`
   - 이 Mac에서 확인된 Apple Development 인증서 팀 ID: `KUHRKC3B77`
   - Xcode `CouponPilot > Signing & Capabilities > Team`을 실제 Apple Developer Program 가입 팀으로 맞춰야 합니다.

## 확인 결과

- iOS 시뮬레이터 빌드: 통과
- 백엔드 API 계약 테스트: 통과
- iPhone Release 아카이브: Apple provisioning profile 부재로 보류
- Cloud Run에는 이번 릴리스 보완 코드가 아직 배포되지 않음
