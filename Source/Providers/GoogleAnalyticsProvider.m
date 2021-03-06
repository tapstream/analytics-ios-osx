// GoogleAnalyticsProvider.m
// Copyright 2013 Segment.io

#import "GoogleAnalyticsProvider.h"
#import "GAI.h"

#ifdef DEBUG
#define AnalyticsDebugLog(...) NSLog(__VA_ARGS__)
#else
#define AnalyticsDebugLog(...)
#endif

@implementation GoogleAnalyticsProvider {
    
}

#pragma mark - Initialization

+ (instancetype)withNothing
{
    return [[self alloc] initWithNothing];
}

- (id)initWithNothing
{
    if (self = [self init]) {
        self.name = @"Google Analytics";
        self.valid = NO;
        self.initialized = NO;
    }
    return self;
}

- (void)start
{
    // Require setup with the trackingId.
    NSString *trackingId = [self.settings objectForKey:@"mobileTrackingId"];
    [[GAI sharedInstance] trackerWithTrackingId:trackingId];
    
    // Optionally turn on uncaught exception tracking.
    NSString *reportUncaughtExceptions = [self.settings objectForKey:@"reportUncaughtExceptions"];
    if ([reportUncaughtExceptions boolValue]) {
        [GAI sharedInstance].trackUncaughtExceptions = YES;
    }
    
    // TODO: add support for sample rate
    
    // All done!
    AnalyticsDebugLog(@"GoogleAnalyticsProvider initialized.");
}


#pragma mark - Settings

- (void)validate
{
    // All that's required is the trackingId.
    BOOL hasTrackingId = [self.settings objectForKey:@"mobileTrackingId"] != nil;
    self.valid = hasTrackingId;
}


#pragma mark - Analytics API

- (void)identify:(NSString *)userId traits:(NSDictionary *)traits context:(NSDictionary *)context
{
    // Not allowed to attach the userId in GA because it's prohibited in their terms of service.

    // We can set traits though. Iterate over all the traits and set them.
    for (NSString *key in traits) {
        [[[GAI sharedInstance] defaultTracker] set:key value:[traits objectForKey:key]];
    }
}

- (void)track:(NSString *)event properties:(NSDictionary *)properties context:(NSDictionary *)context
{
    // Try to extract a "category" property.
    NSString *category = @"All"; // default
    NSString *categoryProperty = [properties objectForKey:@"category"];
    if (categoryProperty) {
        category = categoryProperty;
    }
    
    // Try to extract a "label" property.
    NSString *label = [properties objectForKey:@"label"];
    
    // Try to extract a "revenue" or "value" property.
    NSNumber *value = [Provider extractRevenue:properties];
    NSNumber *valueFallback = [Provider extractRevenue:properties withKey:@"value"];
    if (!value && valueFallback) {
        // fall back to the "value" property
        value = valueFallback;
    }
    
    AnalyticsDebugLog(@"Sending to Google Analytics: category %@, action %@, label %@, value %@", category, event, label, value);
    
    // Track the event!
    [[[GAI sharedInstance] defaultTracker] sendEventWithCategory:category withAction:event withLabel:label withValue:value];
}

- (void)screen:(NSString *)screenTitle properties:(NSDictionary *)properties context:(NSDictionary *)context
{
    [[[GAI sharedInstance] defaultTracker] sendView:screenTitle];
}

@end
