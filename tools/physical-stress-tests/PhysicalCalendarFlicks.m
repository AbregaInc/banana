#import "PhysicalCalendarFlicks.h"
#import <XCTest/XCTest.h>

// XCTest exposes individual drags publicly. Its event recorder can also schedule
// two touches together, which lets the second start during the first native coast.
// These selectors are used by Appium's WebDriverAgent and checked at runtime.
@protocol CalendarPointerPath
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(double)time;
- (void)moveToPoint:(CGPoint)point atOffset:(double)time;
- (void)liftUpAtOffset:(double)time;
@end

@protocol CalendarEventRecord
- (instancetype)initWithName:(NSString *)name interfaceOrientation:(NSInteger)orientation;
- (void)addPointerEventPath:(id)path;
@end

@protocol CalendarEventSynthesizer
- (void)synthesizeEvent:(id)event completion:(void (^)(BOOL, NSError *))completion;
@end

@interface XCUIDevice (CalendarEventDelivery)
- (id<CalendarEventSynthesizer>)eventSynthesizer;
@end

// XCUICoordinate records its events in the display's fixed portrait coordinate
// space. Convert the application's oriented screen points before recording ours.
static CGPoint portraitPoint(CGPoint p, CGSize screen, UIInterfaceOrientation orientation) {
    switch (orientation) {
        case UIInterfaceOrientationLandscapeRight: return CGPointMake(screen.height - p.y, p.x);
        case UIInterfaceOrientationLandscapeLeft: return CGPointMake(p.y, screen.width - p.x);
        case UIInterfaceOrientationPortraitUpsideDown: return CGPointMake(screen.width - p.x, screen.height - p.y);
        default: return p;
    }
}

static void sendCalendarTouches(NSString *name, void (^paths)(Class, id<CalendarEventRecord>),
                                void (^completion)(NSError *)) {
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    XCUIDevice *device = XCUIDevice.sharedDevice;
    if (![recordClass instancesRespondToSelector:@selector(initWithName:interfaceOrientation:)] ||
        ![recordClass instancesRespondToSelector:@selector(addPointerEventPath:)] ||
        ![pathClass instancesRespondToSelector:@selector(initForTouchAtPoint:offset:)] ||
        ![pathClass instancesRespondToSelector:@selector(moveToPoint:atOffset:)] ||
        ![pathClass instancesRespondToSelector:@selector(liftUpAtOffset:)] ||
        ![device respondsToSelector:@selector(eventSynthesizer)] ||
        ![(NSObject *)device.eventSynthesizer respondsToSelector:@selector(synthesizeEvent:completion:)]) {
        completion([NSError errorWithDomain:@"CalendarFlicks" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"This XCTest runtime lacks timed pointer paths."
        }]);
        return;
    }
    id<CalendarEventRecord> record = [(id<CalendarEventRecord>)[recordClass alloc]
        initWithName:name interfaceOrientation:UIInterfaceOrientationPortrait];
    paths(pathClass, record);
    [device.eventSynthesizer synthesizeEvent:record completion:^(BOOL success, NSError *error) {
        if (!success && !error) {
            error = [NSError errorWithDomain:@"CalendarFlicks" code:2 userInfo:@{
                NSLocalizedDescriptionKey: @"XCTest did not deliver the recorded touches."
            }];
        }
        completion(error);
    }];
}

@implementation PhysicalCalendarFlicks
+ (void)sendInFrame:(CGRect)frame screenSize:(CGSize)screenSize orientation:(UIInterfaceOrientation)orientation
         directions:(NSArray<NSNumber *> *)directions
         completion:(void (^)(NSError *))completion {
    sendCalendarTouches(@"Calendar consecutive flicks", ^(Class pathClass, id<CalendarEventRecord> record) {
        for (NSUInteger gesture = 0; gesture < directions.count; gesture++) {
            double start = gesture * 0.26;
            CGFloat from = directions[gesture].boolValue ? 0.78 : 0.22;
            CGFloat to = 1 - from;
            CGPoint point = CGPointMake(CGRectGetMinX(frame) + from * frame.size.width,
                                        CGRectGetMinY(frame) + 0.65 * frame.size.height);
            id<CalendarPointerPath> path = [(id<CalendarPointerPath>)[pathClass alloc]
                initForTouchAtPoint:portraitPoint(point, screenSize, orientation) offset:start];
            for (int step = 1; step <= 6; step++) {
                point.x = CGRectGetMinX(frame) + (from + (to - from) * step / 6) * frame.size.width;
                [path moveToPoint:portraitPoint(point, screenSize, orientation) atOffset:start + step * 0.023];
            }
            [path liftUpAtOffset:start + 0.145];
            [record addPointerEventPath:path];
        }
    }, completion);
}

+ (void)spreadInFrame:(CGRect)frame screenSize:(CGSize)screenSize orientation:(UIInterfaceOrientation)orientation
           completion:(void (^)(NSError *))completion {
    sendCalendarTouches(@"Calendar 1.5x spread", ^(Class pathClass, id<CalendarEventRecord> record) {
        // Both paths stay within the hour grid even when its visible height is short.
        for (int side = -1; side <= 1; side += 2) {
            CGFloat radius = frame.size.width * 0.16;
            CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
            CGPoint point = CGPointMake(center.x + side * radius, center.y);
            id<CalendarPointerPath> path = [(id<CalendarPointerPath>)[pathClass alloc]
                initForTouchAtPoint:portraitPoint(point, screenSize, orientation) offset:0];
            for (int step = 1; step <= 10; step++) {
                point.x = center.x + side * radius * (1 + 0.05 * step);
                [path moveToPoint:portraitPoint(point, screenSize, orientation) atOffset:0.08 + 0.03 * step];
            }
            [path liftUpAtOffset:0.4];
            [record addPointerEventPath:path];
        }
    }, completion);
}
@end
