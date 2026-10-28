/**
 * STEP 2 of 2 - "fix".
 * Subscribes to Zoom_Webinar_Resync__e. Its running user is NOT the publisher; it is set by
 * PlatformEventSubscriberConfigs/ZoomWebinarResyncSubscriber1Config to the webinar owner.
 * That is the whole trick: code here runs AS the owner, so the recreated Campaign Member is
 * created by (and in the context of) the user Zoom is listening for.
 *
 * One webinar owner = one copy of this 3-line trigger + one subscriber config.
 * For a second owner, copy it as ZoomWebinarResyncSubscriber2 with its own config.
 */
trigger ZoomWebinarResyncSubscriber1 on Zoom_Webinar_Resync__e (after insert) {
    ZoomWebinarResyncHandler.process(Trigger.new);
}
