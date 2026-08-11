# Firestore security rules

Deploy the included owner-only rules after signing in with Firebase CLI:

```bash
cd /Users/jaehyun/Documents/Codex/2026-08-10/ai/CouponPilot
firebase deploy --only firestore:rules --project proj-aj21-211200020328
```

The rules allow a Firebase-authenticated user to read and write only their own
`users/{uid}` profile, coupons, and used-coupon history. Coupon images and OCR raw text are
not sent to Firestore by this app.
