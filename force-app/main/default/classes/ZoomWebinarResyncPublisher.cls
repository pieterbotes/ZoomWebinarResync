/**
 * Called from the CampaignMember after-insert trigger.
 *
 * For every new Campaign Member:
 *   - Is its Campaign owned by a webinar owner we manage (Zoom_Webinar_Resync_Owner__mdt)?
 *   - Was it inserted by somebody OTHER than that owner?
 * If both are true, Zoom will ignore it, so we publish a Zoom_Webinar_Resync__e event.
 *
 * "without sharing" so the Campaign query works no matter what the integration user can see.
 */
public without sharing class ZoomWebinarResyncPublisher {

    // Tests cannot insert Custom Metadata rows, so they set this instead.
    @TestVisible
    private static Set<Id> ownerIdsOverride;

    // Lets tests check what was published (you cannot SOQL-query platform events).
    @TestVisible
    private static List<Zoom_Webinar_Resync__e> lastPublished = new List<Zoom_Webinar_Resync__e>();

    public static void handleAfterInsert(List<CampaignMember> newMembers) {
        Set<Id> managedOwners = getManagedOwnerIds();
        if (managedOwners.isEmpty()) {
            return;
        }

        // Collect campaign ids first so we run ONE query for the whole batch
        // (Salesforce limits you to 100 SOQL queries per transaction - never query in a loop).
        Set<Id> campaignIds = new Set<Id>();
        for (CampaignMember cm : newMembers) {
            campaignIds.add(cm.CampaignId);
        }

        Map<Id, Campaign> campaignsById = new Map<Id, Campaign>([
            SELECT Id, OwnerId
            FROM Campaign
            WHERE Id IN :campaignIds AND OwnerId IN :managedOwners
        ]);

        Id runningUserId = UserInfo.getUserId();
        List<Zoom_Webinar_Resync__e> events = new List<Zoom_Webinar_Resync__e>();

        for (CampaignMember cm : newMembers) {
            Campaign c = campaignsById.get(cm.CampaignId);
            if (c == null) {
                continue; // not a webinar campaign we manage
            }
            if (c.OwnerId == runningUserId) {
                continue; // the owner added it -> Zoom already syncs it. Also stops infinite loops.
            }
            events.add(new Zoom_Webinar_Resync__e(
                Campaign_Member_Id__c = cm.Id,
                Campaign_Owner_Id__c  = c.OwnerId
            ));
        }

        // Search the debug log for "ZoomResync" to follow each step.
        System.debug(LoggingLevel.INFO, 'ZoomResync publisher: running as ' + UserInfo.getUserName()
            + ' | new members: ' + newMembers.size()
            + ' | need resync: ' + events.size());

        if (events.isEmpty()) {
            return;
        }

        // Event is defined as "Publish After Commit": if the Marketing Cloud insert rolls back,
        // the event is never delivered.
        List<Database.SaveResult> results = EventBus.publish(events);
        lastPublished.addAll(events);

        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                System.debug(LoggingLevel.INFO, 'ZoomResync publisher: event queued for member '
                    + events[i].Campaign_Member_Id__c + ' -> owner ' + events[i].Campaign_Owner_Id__c);
            } else {
                System.debug(LoggingLevel.ERROR, 'Zoom resync publish failed for '
                    + events[i].Campaign_Member_Id__c + ': ' + results[i].getErrors());
            }
        }
    }

    // Cached for the rest of the transaction so a bulk load only runs this query once.
    private static Set<Id> cachedOwnerIds;

    private static Set<Id> getManagedOwnerIds() {
        if (ownerIdsOverride != null) {
            return ownerIdsOverride;
        }
        if (cachedOwnerIds != null) {
            return cachedOwnerIds;
        }

        // Custom Metadata stores usernames (same value as the subscriber config), so there is
        // only one thing to fill in per owner. Turn them into User Ids with one query.
        Set<String> usernames = new Set<String>();
        for (Zoom_Webinar_Resync_Owner__mdt row : Zoom_Webinar_Resync_Owner__mdt.getAll().values()) {
            if (row.Active__c && String.isNotBlank(row.Username__c)) {
                usernames.add(row.Username__c.trim());
            }
        }

        cachedOwnerIds = new Set<Id>();
        if (!usernames.isEmpty()) {
            // new Map<Id, User>(list).keySet() is a common Apex shortcut for "give me the Ids".
            cachedOwnerIds = new Map<Id, User>([
                SELECT Id FROM User WHERE Username IN :usernames AND IsActive = true
            ]).keySet();
        }
        return cachedOwnerIds;
    }
}
