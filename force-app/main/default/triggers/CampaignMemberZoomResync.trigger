/**
 * STEP 1 of 2 - "detect".
 * Runs in whatever user context created the Campaign Member (e.g. the Marketing Cloud
 * integration user). It does NOT fix anything itself; it only publishes an event saying
 * "this member needs to be recreated by the webinar owner".
 *
 * Keep triggers thin: all logic lives in the class so it can be unit tested.
 */
trigger CampaignMemberZoomResync on CampaignMember (after insert) {
    ZoomWebinarResyncPublisher.handleAfterInsert(Trigger.new);
}
