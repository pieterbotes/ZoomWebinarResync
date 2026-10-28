@IsTest
private class ZoomWebinarResyncTest {

    // Users are "setup" objects. Inserting them and then Campaigns/Leads in the same
    // context causes MIXED_DML errors, so all non-setup DML happens inside System.runAs().
    private static User makeUser(String alias) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User u = new User(
            Alias = alias,
            Email = alias + '@zoomresync.test',
            UserName = alias + '.' + Datetime.now().getTime() + '@zoomresync.test',
            LastName = alias,
            ProfileId = p.Id,
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/New_York',
            UserPermissionsMarketingUser = true
        );
        insert u;
        return u;
    }

    private static Campaign makeCampaignAs(User owner) {
        Campaign c = new Campaign(Name = 'Zoom Webinar Test', IsActive = true);
        System.runAs(owner) { insert c; }
        return c;
    }

    private static Lead makeLeadAs(User u) {
        Lead l = new Lead(LastName = 'Registrant', Company = 'Acme', Email = 'reg@acme.test');
        System.runAs(u) { insert l; }
        return l;
    }

    @IsTest
    static void publishesEventWhenNonOwnerAddsMember() {
        User owner = makeUser('wbowner');
        User integ = makeUser('wbinteg');
        Campaign c = makeCampaignAs(owner);
        Lead l = makeLeadAs(integ);
        ZoomWebinarResyncPublisher.ownerIdsOverride = new Set<Id>{ owner.Id };

        Test.startTest();
        System.runAs(integ) {
            insert new CampaignMember(CampaignId = c.Id, LeadId = l.Id, Status = 'Sent');
        }
        Test.stopTest();

        System.assertEquals(1, ZoomWebinarResyncPublisher.lastPublished.size(), 'one event expected');
        System.assertEquals(owner.Id, Id.valueOf(ZoomWebinarResyncPublisher.lastPublished[0].Campaign_Owner_Id__c));
    }

    @IsTest
    static void noEventWhenOwnerAddsMember() {
        User owner = makeUser('wbowner');
        Campaign c = makeCampaignAs(owner);
        Lead l = makeLeadAs(owner);
        ZoomWebinarResyncPublisher.ownerIdsOverride = new Set<Id>{ owner.Id };

        Test.startTest();
        System.runAs(owner) {
            insert new CampaignMember(CampaignId = c.Id, LeadId = l.Id, Status = 'Sent');
        }
        Test.stopTest();

        System.assertEquals(0, ZoomWebinarResyncPublisher.lastPublished.size(), 'owner inserts are already synced');
    }

    @IsTest
    static void handlerRecreatesMemberAsOwner() {
        User owner = makeUser('wbowner');
        User integ = makeUser('wbinteg');
        Campaign c = makeCampaignAs(owner);
        Lead l = makeLeadAs(integ);
        ZoomWebinarResyncPublisher.ownerIdsOverride = new Set<Id>(); // isolate the handler

        CampaignMember original = new CampaignMember(CampaignId = c.Id, LeadId = l.Id, Status = 'Responded');
        System.runAs(integ) { insert original; }

        Zoom_Webinar_Resync__e evt = new Zoom_Webinar_Resync__e(
            Campaign_Member_Id__c = original.Id,
            Campaign_Owner_Id__c  = owner.Id
        );

        Test.startTest();
        System.runAs(owner) {
            ZoomWebinarResyncHandler.process(new List<Zoom_Webinar_Resync__e>{ evt });
        }
        Test.stopTest();

        List<CampaignMember> afterFix = [
            SELECT Id, CreatedById, Status, LeadId FROM CampaignMember WHERE CampaignId = :c.Id
        ];
        System.assertEquals(1, afterFix.size(), 'still exactly one member');
        System.assertNotEquals(original.Id, afterFix[0].Id, 'member was recreated');
        System.assertEquals(owner.Id, afterFix[0].CreatedById, 'copy is created by the webinar owner');
        System.assertEquals('Responded', afterFix[0].Status, 'fields carried over');
        System.assertEquals(l.Id, afterFix[0].LeadId);
    }

    @IsTest
    static void handlerIgnoresEventsForOtherOwners() {
        User owner = makeUser('wbowner');
        User someoneElse = makeUser('wbother');
        User integ = makeUser('wbinteg');
        Campaign c = makeCampaignAs(owner);
        Lead l = makeLeadAs(integ);
        ZoomWebinarResyncPublisher.ownerIdsOverride = new Set<Id>();

        CampaignMember original = new CampaignMember(CampaignId = c.Id, LeadId = l.Id, Status = 'Sent');
        System.runAs(integ) { insert original; }

        Test.startTest();
        System.runAs(someoneElse) {
            ZoomWebinarResyncHandler.process(new List<Zoom_Webinar_Resync__e>{
                new Zoom_Webinar_Resync__e(Campaign_Member_Id__c = original.Id, Campaign_Owner_Id__c = owner.Id)
            });
        }
        Test.stopTest();

        System.assertEquals(original.Id, [SELECT Id FROM CampaignMember WHERE CampaignId = :c.Id].Id,
            'a subscriber must only act on its own owner\'s events');
    }
}
