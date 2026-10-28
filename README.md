# Zoom Webinar: re-sync Campaign Members created by integration users

> **Disclaimer:** This is a personal lab project. It is **not** an official Zoom product, is not affiliated with, endorsed by, or supported by Zoom Video Communications, Inc., and comes with no warranty. Test thoroughly in a sandbox before using it anywhere else.

## The problem

The Zoom for Lightning Webinar integration uses user-level OAuth. A Campaign Member added in Salesforce is only pushed to Zoom as a registrant when it is added **in the context of the webinar owner**, meaning the user who did the Webinar OAuth and owns the webinar and its Campaign. A Marketing Cloud form inserts members as the **MC integration user**, so Zoom never gets them.

A note on "owner": `CampaignMember` has no `OwnerId` field of its own. In practice, "owner" means the user the insert **runs as**, and that same user also becomes `CreatedById`. Neither can be changed after insert. That leaves one fix: **delete the member and insert it again while running as the webinar owner.** The design below does this, so it works whichever of those values the Zoom package actually checks.

The hard part is the "running as" bit. Salesforce automation normally runs as whoever caused it, which here is the MC integration user.

## Options considered

| # | Approach | Truly runs as owner? | Verdict |
|---|----------|---------------------|---------|
| A | **Apex trigger publishes a Platform Event → Apex subscriber trigger whose running user is overridden to the owner** (`PlatformEventSubscriberConfig`) | Yes | **Recommended.** No OAuth, no callouts, bulk-safe |
| B | Same as A, but a **record-triggered Flow** publishes the event (Apex subscriber still does the fix) | Yes | Good if the admins want to own the "when" logic in Flow |
| C | Flow or Apex **HTTP callout to the org's own REST API** through a Named Credential authenticated as the owner | Yes | Works, but needs a Connected App, an Auth Provider, and token upkeep. Fallback only |
| D | Apex with **"Set Audit Fields upon Record Creation"** to stamp `CreatedById` = owner | **No.** Only the field changes; the code still runs as the integration user | Works only if the Zoom package reads the `CreatedById` field rather than the running user. Risky |
| E | MC writes to a **staging object** (or straight to the event) instead of `CampaignMember`; automation then creates the member as the owner | Yes | Cleanest, because nothing gets deleted. Needs MC to change its target object |

A pure Flow version isn't possible because a flow can't switch its running user. Record-triggered flows run as the triggering user, and scheduled or async paths run as the Automated Process user.

## How option A works

```
MC integration user inserts CampaignMember
        │
        ▼
CampaignMemberZoomResync (after insert trigger, runs as MC user)
  - Campaign owned by a managed owner?        (Zoom_Webinar_Resync_Owner__mdt)
  - Inserted by someone other than the owner?
  → publish Zoom_Webinar_Resync__e { memberId, ownerId }   (Publish After Commit)
        │  (async, a few seconds later)
        ▼
ZoomWebinarResyncSubscriber1 (platform event trigger, RUNS AS OWNER via subscriber config)
  - only act on events where ownerId == me
  - read original member (all createable fields)
  - savepoint → delete original → insert identical copy   (rollback + retry on failure)
        │
        ▼
Zoom package CampaignMember trigger fires as the owner → registrant pushed to Zoom
        │
        ▼
CampaignMemberZoomResync fires again, sees running user == owner → does nothing (no loop)
```

**Analogy for JS:** a platform event works like Node's `EventEmitter` (or a message queue). The trigger calls `emit('resync', {...})`, and a listener somewhere else handles it. The useful part here is that Salesforce lets you choose **which user the listener runs as**. Ordinary code can't switch users mid-transaction.

## Files

```
force-app/main/default/
  objects/Zoom_Webinar_Resync__e/            platform event + 2 text fields
  objects/Zoom_Webinar_Resync_Owner__mdt/    "which owners do we manage" (Username__c, Active__c)
  customMetadata/...Webinar_Owner_1          one row per owner  ← fill in username
  triggers/CampaignMemberZoomResync          detect + publish
  triggers/ZoomWebinarResyncSubscriber1      subscriber for owner 1
  PlatformEventSubscriberConfigs/...Config   makes subscriber 1 run as owner 1  ← fill in username
  classes/ZoomWebinarResyncPublisher         publish logic
  classes/ZoomWebinarResyncHandler           delete + recreate logic
  classes/ZoomWebinarResyncTest              unit tests
```

## Setup and deploy

### Quick route: Workbench

```bash
node build-package.js webinar.owner@yourorg.com
```

This creates `deploy/zoom-webinar-resync.zip`, with the owner's username filled into both the Custom Metadata row and the subscriber config. In Workbench, go to **Migration → Deploy**, choose the zip, and tick **Single Package** and **Rollback On Error**. Set **Test Level** to *RunSpecifiedTests* with `ZoomWebinarResyncTest`.

The only value you need is the **webinar owner**: the user who did the Zoom Webinar OAuth and owns the Campaign. The "integration user" isn't configured anywhere, because any other user who adds a member triggers the fix.

### Manual route

1. **Fill in the placeholders.** Replace `REPLACE_WITH_WEBINAR_OWNER_USERNAME` with the webinar owner's **username** in two files:
   - `customMetadata/Zoom_Webinar_Resync_Owner.Webinar_Owner_1.md-meta.xml`
   - `PlatformEventSubscriberConfigs/ZoomWebinarResyncSubscriber1Config...`
2. **Check the owner's permissions.** The owner must:
   - have the **Marketing User** checkbox enabled;
   - be able to delete and create Campaign Members on their campaigns;
   - be an active user;
   - have Webinar connected under Zoom User Config.
3. **Deploy** to the sandbox with the Salesforce CLI (it's a Node.js tool):
   ```bash
   sf project deploy start --source-dir force-app --target-org my-sandbox --test-level RunSpecifiedTests --tests ZoomWebinarResyncTest
   ```
   The subscriber config can only be set through metadata deploys, never in the Setup UI. To check it, go to **Setup → Platform Events → Zoom Webinar Resync → Subscriptions**. The subscriber should list the owner as its running user.
4. **Test end to end:** submit the MC form, then:
   - Confirm the member in Salesforce now shows **Created By = owner**.
   - Confirm the registrant appears in Zoom.
   - Confirm Zoom-page registrations still sync and aren't duplicated.
5. **Add another webinar owner:**
   - Add a CMDT row for them.
   - Copy the subscriber trigger as `ZoomWebinarResyncSubscriber2`.
   - Copy the config, pointing it at the new trigger and the new owner's username.

## Option B: Flow publishes, Apex subscribes

Use this if the admins would rather keep the trigger condition in Flow. Deactivate `CampaignMemberZoomResync` and build:

- **Record-Triggered Flow** on Campaign Member: *A record is created*, *Actions and Related Records* (after-save).
  - **Entry condition (formula):** `{!$Record.Campaign.OwnerId} <> {!$User.Id}` AND the campaign is a Zoom webinar campaign. Check the Campaign Type, or a Get Records on the Zoom Webinar package object that looks up this campaign.
  - **Create Records → Zoom_Webinar_Resync__e:**
    - `Campaign_Member_Id__c` = `{!$Record.Id}`
    - `Campaign_Owner_Id__c` = `{!$Record.Campaign.OwnerId}`
- Keep `ZoomWebinarResyncSubscriber1`, its config, and `ZoomWebinarResyncHandler` exactly as they are.

A **platform-event-triggered Flow** subscriber isn't a reliable replacement for the Apex subscriber. Event-triggered flows run as the Automated Process user, and support for changing their running user should be checked against the current release notes before you rely on it.

## Option C (fallback): callout as the owner

Use this only if subscriber configs aren't allowed. In Flow: an async path → **HTTP Callout** action → Named Credential (External Credential with a Named Principal, authenticated once as the owner) → `POST /services/data/v62.0/composite/graph`. Each graph does `DELETE /sobjects/CampaignMember/{id}`, then `POST /sobjects/CampaignMember` with `allOrNone`. Each owner needs their own Named Credential, and the token expires if the owner's password or session policy changes.

## Questions to confirm before go-live

1. **What exactly does the package check?** The running user, `CreatedById`, or `Campaign.OwnerId`? Option A covers all three. Option D only covers `CreatedById`.
2. **Delete side effect.** Deleting the original member as the owner could fire the package's "remove registrant" logic for someone who was never registered. Confirm it's a harmless no-op, and that it can't run *after* the re-add and cancel the registration.
3. **Zoom → Salesforce inserts.** Which user do registrations from the Zoom page arrive as? If it isn't the owner, this automation will recreate them too. That's harmless, but they'd be pushed back to Zoom. Exclude that user if needed.
4. **Single point of failure.** If the owner is deactivated, the subscriber stops. Consider a dedicated webinar-host user that owns all webinars.
5. **Volume.** Each member costs one platform event. That's fine for webinar registrations, but check the org's event allocation if MC bulk-loads lists.
6. **Option E.** If the MC team can write to a staging object instead of `CampaignMember`, the handler only needs to *create* the member, so nothing is ever deleted and question 2 goes away.
