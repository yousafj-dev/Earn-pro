# Database schema (Firestore)

All user-facing IDs should be Firebase Auth UIDs unless otherwise specified. Never trust the client to calculate money, approve tasks, or confirm referrals.

## `users/{uid}`
```json
{
  "uid": "Firebase Auth UID",
  "displayName": "User display name",
  "email": "user@example.com",
  "createdAt": "server timestamp",
  "referralCode": "unique code assigned by trusted backend",
  "referredBy": "optional inviter UID",
  "role": "user",
  "accountStatus": "active"
}
```
The starter app creates a basic profile at signup. For a production system, generate unique referral codes on a trusted backend and add email verification, rate limits, and abuse checks.

## `tasks/{taskId}`
```json
{
  "title": "Sponsor task title",
  "description": "What the user must do",
  "sponsorName": "Sponsor/business",
  "rewardMinorUnits": 1000,
  "currency": "PKR",
  "status": "active",
  "startsAt": "timestamp",
  "endsAt": "timestamp",
  "createdAt": "timestamp"
}
```
Use minor currency units (e.g. paisa) as integers to avoid floating-point money errors. Only admins/backend can create or edit tasks.

## `taskSubmissions/{submissionId}`
```json
{
  "uid": "submitting user UID",
  "taskId": "task document ID",
  "proofUrl": "optional uploaded proof",
  "status": "pending",
  "submittedAt": "timestamp",
  "reviewedAt": null
}
```
A trusted reviewer/backend verifies the task before awarding anything.

## `referrals/{referralId}`
```json
{
  "inviterUid": "inviter UID",
  "inviteeUid": "new user UID",
  "status": "pending",
  "createdAt": "timestamp",
  "qualifiedAt": null,
  "rewardEntryId": null
}
```
Prevent self-referrals, duplicate invitees, repeated device/account abuse, and rewards before qualification.

## `walletLedger/{entryId}`
```json
{
  "uid": "owner UID",
  "type": "task_reward | referral_reward | withdrawal | adjustment",
  "amountMinorUnits": 1000,
  "currency": "PKR",
  "status": "posted",
  "sourceId": "task/referral/withdrawal ID",
  "createdAt": "timestamp",
  "createdBy": "trusted backend/admin UID"
}
```
Treat the ledger as append-only. Compute displayed balance by summing valid ledger entries on the backend, or maintain a server-controlled balance updated transactionally. Never allow clients to write ledger entries or balances.

## `withdrawals/{withdrawalId}`
```json
{
  "uid": "requesting user UID",
  "amountMinorUnits": 50000,
  "currency": "PKR",
  "method": "easypaisa | jazzcash | bank",
  "destinationToken": "protected/limited-access payment destination",
  "status": "pending",
  "requestedAt": "timestamp",
  "reviewedAt": null,
  "reviewedBy": null,
  "paymentReference": null
}
```
Do not store payment PINs, passwords, or OTPs. Restrict destination details to authorized admins and minimize retention.

## Roles and permissions
- `user`: reads own profile and permitted public active tasks; creates own task submissions through validated rules.
- `admin`: managed via Firebase custom claims set by a trusted Admin SDK environment, never by the client.
- Backend: validates task submissions and referrals; posts rewards; reserves withdrawal funds; writes audit logs.
- All money-related actions need idempotency keys and server-side transactions to prevent double payments.
