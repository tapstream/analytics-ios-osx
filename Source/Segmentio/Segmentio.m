// Segmentio.m
// Copyright 2013 Segment.io

#import "Segmentio.h"

#ifdef DEBUG
#define SegmentioDebugLog(...) NSLog(__VA_ARGS__)
#else
#define SegmentioDebugLog(...)
#endif

#define SEGMENTIO_API_URL [NSURL URLWithString:@"https://api.segment.io/v1/import"]
#define SEGMENTIO_MAX_BATCH_SIZE 100



static NSString * const kSessionID = @"kSegmentioSessionID";

static NSString *ToISO8601(NSDate *date) {
    static dispatch_once_t dateFormatToken;
    static NSDateFormatter *dateFormat;
    dispatch_once(&dateFormatToken, ^{
        dateFormat = [[NSDateFormatter alloc] init];
        dateFormat.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS";
        dateFormat.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        dateFormat.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [[dateFormat stringFromDate:date] stringByAppendingString:@"Z"];
}

static NSString *GetSessionID(BOOL reset) {
    // As of May 1, 2013 we cannot use UDIDs see https://developer.apple.com/news/?id=3212013a
    // so we use a generated UUID that we save to NSUserDefaults
    // We could use serial number or mac address
    // (see http://developer.apple.com/library/mac/#technotes/tn1103/_index.html )
    // but it's really not necessary since they can be nil and we are only using them as SessionID anyways.
    // Similarly, we decided not to use identifierForVendor because it can't be reset to a new value on logout.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults stringForKey:kSessionID] || reset) {
        CFUUIDRef theUUID = CFUUIDCreate(NULL);
        CFStringRef string = CFUUIDCreateString(NULL, theUUID);
        SegmentioDebugLog(@"New SessionID: %@", string);
        CFRelease(theUUID);
        [defaults setObject:(__bridge_transfer NSString *)string forKey:kSessionID];
    }
    return [defaults stringForKey:kSessionID];
}

static NSMutableDictionary *CreateContext(NSDictionary *parameters) {
    NSMutableDictionary *context = [NSMutableDictionary dictionary];
    [context setValue:@"analytics-ios-osx" forKey:@"library"];
    // TODO add any device information here
    if (parameters != nil) {
        [context addEntriesFromDictionary:parameters];
    }
    return context;
}




@interface Segmentio ()

@property(nonatomic, strong) NSTimer *flushTimer;
@property(nonatomic, strong) NSMutableArray *queue;
@property(nonatomic, strong) NSArray *batch;
@property(nonatomic, strong) NSURLConnection *connection;
@property(nonatomic, assign) NSInteger responseCode;
@property(nonatomic, strong) NSMutableData *responseData;

@end




@implementation Segmentio {
    dispatch_queue_t _serialQueue;
}

static Segmentio *sharedInstance = nil;



#pragma mark - Initializiation

+ (instancetype)withSecret:(NSString *)secret
{
    return [self withSecret:secret flushAt:20 flushAfter:30 delegate:nil];
}

+ (instancetype)withSecret:(NSString *)secret delegate:(SegmentioListenerDelegate *)delegate
{
    return [self withSecret:secret flushAt:20 flushAfter:30 delegate:delegate];
}

+ (instancetype)withSecret:(NSString *)secret flushAt:(NSUInteger)flushAt flushAfter:(NSUInteger)flushAfter
{
    return [self withSecret:secret flushAt:flushAt flushAfter:flushAfter delegate:nil];
}

+ (instancetype)withSecret:(NSString *)secret flushAt:(NSUInteger)flushAt flushAfter:(NSUInteger)flushAfter delegate:(SegmentioListenerDelegate *)delegate
{
    NSParameterAssert(secret.length > 0);
    NSParameterAssert(flushAt > 0);
    NSParameterAssert(flushAfter > 0);

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] initWithSecret:secret flushAt:flushAt flushAfter:flushAfter delegate:delegate];
    });
    return sharedInstance;
}

+ (instancetype)sharedInstance
{
    NSAssert(sharedInstance, @"%@ sharedInstance called before withSecret", self);
    return sharedInstance;
}

- (id)initWithSecret:(NSString *)secret flushAt:(NSUInteger)flushAt flushAfter:(NSUInteger)flushAfter delegate:(SegmentioListenerDelegate *)delegate
{
    NSParameterAssert(secret.length);
    
    if (self = [self init]) {
        _flushAt = flushAt;
        _flushAfter = flushAfter;
        _delegate = delegate;
        _secret = secret;
        _sessionId = GetSessionID(NO);
        _queue = [NSMutableArray array];
        _flushTimer = [NSTimer scheduledTimerWithTimeInterval:self.flushAfter
                                                       target:self
                                                     selector:@selector(flush)
                                                     userInfo:nil
                                                      repeats:YES];
        _serialQueue = dispatch_queue_create("io.segment.analytics.segmentio", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}



#pragma mark - Analytics API

- (void)identify:(NSString *)userId traits:(NSDictionary *)traits context:(NSDictionary *)context
{
    dispatch_async(_serialQueue, ^{
        self.userId = userId;
    });

    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [dictionary setValue:traits forKey:@"traits"];

    [self enqueueAction:@"identify" dictionary:dictionary context:context];
}

 - (void)track:(NSString *)event properties:(NSDictionary *)properties context:(NSDictionary *)context
{
    NSAssert(event.length, @"%@ track requires an event name.", self);

    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [dictionary setValue:event forKey:@"event"];
    [dictionary setValue:properties forKey:@"properties"];
    
    [self enqueueAction:@"track" dictionary:dictionary context:context];
}

- (void)alias:(NSString *)from to:(NSString *)to context:(NSDictionary *)context
{
    NSAssert(from.length, @"%@ alias requires a from id.", self);
    NSAssert(to.length, @"%@ alias requires a to id.", self);

    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [dictionary setValue:from forKey:@"from"];
    [dictionary setValue:to forKey:@"to"];
    
    [self enqueueAction:@"alias" dictionary:dictionary context:context];
}



#pragma mark - Queueing

- (void)enqueueAction:(NSString *)action dictionary:(NSMutableDictionary *)dictionary context:(NSDictionary *)context
{
    // attach these parts of the payload outside since they are all synchronous
    // and the timestamp will be more accurate.
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    [payload setValue:action forKey:@"action"];
    [payload setValue:ToISO8601([NSDate date]) forKey:@"timestamp"];
    [payload addEntriesFromDictionary:dictionary];
    [payload setValue:CreateContext(context) forKey:@"context"];

    dispatch_async(_serialQueue, ^{

        // attach userId and sessionId inside the dispatch_async in case
        // they've changed (see identify function)
        [payload setValue:self.userId forKey:@"userId"];
        [payload setValue:self.sessionId forKey:@"sessionId"];

        SegmentioDebugLog(@"%@ Enqueueing action: %@", self, payload);

        [self.queue addObject:payload];
        
        [self flushQueueByLength];
    });
}

- (void)flush
{
    dispatch_async(_serialQueue, ^{
        if ([self.queue count] == 0) {
            SegmentioDebugLog(@"%@ No queued API calls to flush.", self);
            return;
        }
        else if (self.connection != nil) {
            SegmentioDebugLog(@"%@ API request already in progress, not flushing again.", self);
            return;
        }
        else if ([self.queue count] >= SEGMENTIO_MAX_BATCH_SIZE) {
            self.batch = [self.queue subarrayWithRange:NSMakeRange(0, SEGMENTIO_MAX_BATCH_SIZE)];
        }
        else {
            self.batch = [NSArray arrayWithArray:self.queue];
        }

        SegmentioDebugLog(@"%@ Flushing %lu of %lu queued API calls.", self, (unsigned long)self.batch.count, (unsigned long)self.queue.count);

        NSMutableDictionary *payloadDictionary = [NSMutableDictionary dictionary];
        [payloadDictionary setObject:self.secret forKey:@"secret"];
        [payloadDictionary setObject:self.batch forKey:@"batch"];
        
        NSData *payload = [NSJSONSerialization dataWithJSONObject:payloadDictionary
                                                          options:0 error:NULL];
        self.connection = [self connectionForPayload:payload];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.connection start];
        });
    });
}

- (void)flushQueueByLength
{
    dispatch_async(_serialQueue, ^{
        SegmentioDebugLog(@"%@ Length is %lu.", self, (unsigned long)self.queue.count);
        if (self.connection == nil && [self.queue count] >= self.flushAt)
            [self flush];
    });
}

- (void)reset
{
    [self.flushTimer invalidate];
    self.flushTimer = nil;
    self.flushTimer = [NSTimer scheduledTimerWithTimeInterval:self.flushAfter
                                                       target:self
                                                     selector:@selector(flush)
                                                     userInfo:nil
                                                      repeats:YES];
    dispatch_async(_serialQueue, ^{
        self.sessionId = GetSessionID(YES); // changes the UUID
        self.userId = nil;
        self.queue = [NSMutableArray array];
    });
}



#pragma mark - Connection delegate callbacks

- (NSURLConnection *)connectionForPayload:(NSData *)payload
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:SEGMENTIO_API_URL];
    [request setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:payload];
    
    SegmentioDebugLog(@"%@ Sending batch API request: %@", self,
                      [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding]);
    
    return [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSHTTPURLResponse *)response
{
    NSAssert([NSThread isMainThread], @"Should be on main since URL connection should have started on main");
    self.responseCode = [response statusCode];
    self.responseData = [NSMutableData data];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    NSAssert([NSThread isMainThread], @"Should be on main since URL connection should have started on main");
    [self.responseData appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    dispatch_async(_serialQueue, ^{

        if (self.responseCode != 200) {
            NSLog(@"%@ API request had an error: %@", self, [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding]);
        }
        else {
            SegmentioDebugLog(@"%@ API request success 200", self);
        }

        // TODO
        // Currently we don't retry sending any of the queued calls. If they return 
        // with a response code other than 200 we still remove them from the queue.
        // Is that the desired behavior? Suggestion: (retry if network error or 500 error. But not 400 error)
        [self.queue removeObjectsInArray:self.batch];

        self.batch = nil;
        self.responseCode = 0;
        self.responseData = nil;
        self.connection = nil;

        if (self.delegate) {
            [self.delegate onAPISuccess];
        }
    });
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    dispatch_async(_serialQueue, ^{
        NSLog(@"%@ Network failed while sending API request: %@", self, error);

        self.batch = nil;
        self.responseCode = 0;
        self.responseData = nil;
        self.connection = nil;

        if (self.delegate) {
            [self.delegate onAPIFailure];
        }
    });
}



#pragma mark - NSObject

- (NSString *)getSessionId
{
    return self.sessionId;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<Segmentio secret:%@>", self.secret];
}

@end
