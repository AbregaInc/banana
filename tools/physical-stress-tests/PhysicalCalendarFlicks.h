#import <UIKit/UIKit.h>

/// Consecutive one-finger gestures in one XCTest event record, with no idle wait between them.
NS_ASSUME_NONNULL_BEGIN
@interface PhysicalCalendarFlicks : NSObject
+ (void)sendInFrame:(CGRect)frame
         screenSize:(CGSize)screenSize
        orientation:(UIInterfaceOrientation)orientation
          directions:(NSArray<NSNumber *> *)directions
         completion:(void (^)(NSError * _Nullable))completion
    NS_SWIFT_NAME(send(in:screenSize:orientation:directions:completion:));
+ (void)spreadInFrame:(CGRect)frame screenSize:(CGSize)screenSize orientation:(UIInterfaceOrientation)orientation
           completion:(void (^)(NSError * _Nullable))completion
    NS_SWIFT_NAME(spread(in:screenSize:orientation:completion:));
@end
NS_ASSUME_NONNULL_END
