# Android daily study reminders

Android owns recurrence; it does not need a running Flutter engine, a foreground
app, a network request, or another count refresh to schedule tomorrow.

## Eligibility and daily suppression

- An enabled setting plus a known positive workload and known review activity
  permits daily reminders. Native preferences retain only eligibility, the local
  reminder time, the pending alarm time and a study-day suppression marker.
- Zero or unknown workload, unknown review activity, account release and disabling
  reminders cancel delivery and remove recurrence eligibility. No work is inferred
  from an unknown count. A later positive refresh can enable recurrence again.
- A reminder always uses the existing neutral message without a count. Yesterday's
  positive workload permits tomorrow's neutral nudge until a later reconciliation
  says otherwise; it is not a claim that the old count is still accurate. Android
  neither refreshes server data nor estimates when future cards become due.
- Studying with work remaining dismisses a posted reminder and suppresses the rest
  of that study day, while leaving the next eligible day's alarm scheduled. If the
  last known workload becomes zero, reminders remain silent until a positive refresh.
- Study-day suppression resets at midnight America/Sao_Paulo, matching Recall's
  study-day contract. The reminder's configured wall-clock time uses the device's
  local timezone. Delivery records the study day durably before posting; a failed
  write suppresses posting. Reconciliation, time changes, repeated broadcasts and
  disable/enable cannot create a second reminder in that study day. Cancellation
  keeps this anonymous day marker, including across account changes.

## Background delivery and recovery

Every one-shot alarm attempt rearms the next local slot before posting, including
when notification permission or the channel is blocked. A permission revocation
between checking and posting is caught and leaves tomorrow armed. Reboot, package
replacement, clock and timezone broadcasts restore one pending alarm from native
preferences. A delayed alarm from an earlier study day is skipped; it cannot
become today's reminder. Existing active preferences upgrade as last-known positive
eligibility. An already-consumed reminder from an older build has no recoverable
eligibility; one app refresh is needed to seed the new schedule.

The existing `setAndAllowWhileIdle` inexact alarm requires no new permission or
exact-alarm access. The configured time is the earliest delivery target, not an
exact delivery guarantee; Android battery/Doze/OEM restrictions can delay it.
Force-stopping an Android app also prevents its background delivery until the app
is launched again. No foreground service, card scheduling, review queue or server
writes are added.

## Evidence and remaining device acceptance

`RecallReminderRecurrenceTest` uses real Android preferences and Robolectric alarms
on API 28/35, with repeated receiver dispatch and no further Dart apply. It covers
several ignored days, daily deduplication, study suppression with tomorrow retained,
zero/unknown/disabled state, reboot/update restore, blocked notifications, permission
revocation during posting, stale/early alarms, changed time and device-zone differences.
The controller/bridge tests cover transfer of today's study suppression, the BRT
boundary, settings, unknown state, permission denial and persistence failures.
Tests assert state and delivery behavior, not text or layout. Instrumentation tests
also cover actual notification posting when permitted, but require a device run.

A real two-day delivery is not proven by clock-controlled tests. To prove it:
install the eventual signed update on a test Android device, seed synthetic positive
workload and known review activity, enable notifications and choose a reminder time.
Background the app without force-stopping it. Record the first notification's real
delivery time, dismiss/ignore it, and leave the app unopened through the following
real day (including overnight idle). Record exactly one next-day notification and
confirm its tap opens Study. Repeat with a reboot or in-place update between days.
Then study with work remaining before the reminder: the posted/today's reminder
must disappear/stay silent and the following day's must arrive without reopening.
Separately check zero/unknown work, blocked app/channel permission, disabling and
changing the time, and confirm alarms remain inexact when exact access is denied.
Record device/Android/build versions and timing delays without account/card content.
The full CI gate and real device acceptance are separate from targeted local tests.
