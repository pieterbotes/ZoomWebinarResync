/**
 * Called from the platform event subscriber trigger, which runs AS the webinar owner.
 *
 * For each event addressed to the current user:
 *   1. read the original Campaign Member (all createable fields)
 *   2. delete it
 *   3. insert an identical copy
 * Because step 3 runs as the owner, the copy's CreatedById is the owner and the Zoom
 * package's CampaignMember trigger fires in the owner's context -> it pushes to Zoom.
 *
 * Why delete first? Salesforce allows only one Campaign Member per Lead/Contact per
 * Campaign, so the copy cannot be inserted while the original still exists. And CreatedById
 * can't be updated after insert, so "recreate" is the only option.
 */
public without sharing class ZoomWebinarResyncHandler {

    @TestVisible
    private static Integer maxRetries = 4;

    // Never copy these: we WANT the copy to get fresh system values for the new running user.
    // (If "Set Audit Fields upon Record Creation" is enabled, CreatedById becomes createable,
    // and copying it would quietly defeat the whole fix.)
    private static final Set<String> SKIP_FIELDS = new Set<String>{
        'id', 'createdbyid', 'createddate', 'lastmodifiedbyid', 'lastmodifieddate', 'systemmodstamp'
    };

    public static void process(List<Zoom_Webinar_Resync__e> events) {
        Id me = UserInfo.getUserId();

        Set<Id> memberIds = new Set<Id>();
        for (Zoom_Webinar_Resync__e e : events) {
            // Every subscriber receives every event. Only act on events for the owner this
            // subscriber runs as. If the run-as config is missing, the trigger runs as the
            // Automated Process user, matches nothing, and does nothing - a safe failure.
            if (String.isBlank(e.Campaign_Owner_Id__c) || String.isBlank(e.Campaign_Member_Id__c)) {
                continue;
            }
            if (Id.valueOf(e.Campaign_Owner_Id__c) != me) {
                continue;
            }
            memberIds.add(Id.valueOf(e.Campaign_Member_Id__c));
        }
        System.debug(LoggingLevel.INFO, 'ZoomResync handler: running as ' + UserInfo.getUserName()
            + ' | events received: ' + events.size()
            + ' | addressed to me: ' + memberIds.size());

        if (memberIds.isEmpty()) {
            return;
        }

        // Dynamic SOQL: the field list is built at runtime so custom fields the Marketing
        // Cloud form fills in (phone, "are you a client", etc.) are carried over automatically.
        // ":memberIds" and ":me" bind to the local variables above.
        String soql = 'SELECT ' + String.join(createableFields(), ', ')
                    + ' FROM CampaignMember WHERE Id IN :memberIds AND CreatedById != :me';
        List<CampaignMember> originals = Database.query(soql);
        if (originals.isEmpty()) {
            return; // already deleted or already fixed
        }

        List<CampaignMember> copies = new List<CampaignMember>();
        for (CampaignMember cm : originals) {
            // clone(preserveId=false, isDeepClone=true, preserveReadonlyTimestamps=false, preserveAutonumber=false)
            copies.add(cm.clone(false, true, false, false));
        }

        // Savepoint = "undo point". If the insert fails we roll back the delete too,
        // so a registrant is never lost.
        Savepoint sp = Database.setSavepoint();
        try {
            delete originals;
            insert copies;
            for (Integer i = 0; i < originals.size(); i++) {
                System.debug(LoggingLevel.INFO, 'ZoomResync handler: recreated member '
                    + originals[i].Id + ' -> ' + copies[i].Id + ' (now created by ' + UserInfo.getUserName() + ')');
            }
        } catch (Exception ex) {
            Database.rollback(sp);
            if (currentRetries() < maxRetries) {
                // Salesforce redelivers the whole batch later (up to 9 times).
                throw new EventBus.RetryableException('Zoom webinar resync failed, retrying: ' + ex.getMessage());
            }
            System.debug(LoggingLevel.ERROR, 'Zoom webinar resync gave up for ' + memberIds + ': ' + ex.getMessage());
        }
    }

    private static List<String> createableFields() {
        List<String> names = new List<String>{ 'Id' };
        for (Schema.SObjectField f : Schema.SObjectType.CampaignMember.fields.getMap().values()) {
            Schema.DescribeFieldResult d = f.getDescribe();
            if (d.isCreateable() && !d.isCalculated() && !SKIP_FIELDS.contains(d.getName().toLowerCase())) {
                names.add(d.getName());
            }
        }
        return names;
    }

    // EventBus.TriggerContext only exists inside a platform event trigger (not in unit tests).
    private static Integer currentRetries() {
        try {
            return EventBus.TriggerContext.currentContext().retries;
        } catch (Exception e) {
            return maxRetries; // not in an event trigger -> don't throw RetryableException
        }
    }
}
