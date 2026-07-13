# Recall due-count widget

`RecallWidget` reads only `due_count` and `updated_at` from the App Group
`group.com.german.ankiReview`. The Flutter app writes those two aggregate values
through `RecallWidgetPlugin`; the extension has no Supabase client, credentials,
account identifier, deck metadata, card content, or review rows.
The count is the sum of due review cards across every deck, independent of the
active deck filter or new-card limit. `updated_at` advances only after a
successful cloud refresh, so the widget can show honest stale state offline.

The checked-in Xcode target can be recreated or repaired from the app directory:

```sh
ruby ios/tool/add_widget_extension.rb
```

The script is idempotent. It adds the extension, embeds it in Runner, wires the
native bridge, and applies the App Group entitlement to both targets.

## Signing

Register `group.com.german.ankiReview` for the selected Apple Developer team and
enable it on both `com.german.ankiReview` and
`com.german.ankiReview.RecallWidget`. A free Personal Team may not provision App
Groups; if signing rejects the entitlement, use an Apple Developer Program team.
The widget requires iOS 18 because its App Intent hands the explicit study URL
to `OpenURLIntent`; the containing Recall app continues to support iOS 16+.

For a temporary Personal Team device build, first copy `health-apps` under
`/private/tmp`, then run:

```sh
ruby ios/tool/prepare_personal_team_build.rb ios/Runner.xcodeproj
```

That guarded script refuses to touch a non-temporary project and removes only
the widget target/App Group entitlement from the copy. The checked-in project
always keeps the complete widget for an enrolled team.

## Routing

The Start Study App Intent opens `recall://study`. `RecallDeepLinkController`
accepts only that exact route. The app shell owns the final navigation action so
a warm app can switch from Decks or Stats back to Study.
