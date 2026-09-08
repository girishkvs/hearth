#import <Foundation/Foundation.h>
#import <OpenDirectory/OpenDirectory.h>

NS_ASSUME_NONNULL_BEGIN

@interface HearthPolicyReadResult : NSObject
@property(nonatomic, readonly, copy, nullable) NSDictionary *policies;
@property(nonatomic, readonly, strong, nullable) NSError *error;
- (instancetype)initWithPolicies:(nullable NSDictionary *)policies error:(nullable NSError *)error;
@end

FOUNDATION_EXPORT HearthPolicyReadResult *HearthReadRecordPolicies(ODRecord *record);
FOUNDATION_EXPORT HearthPolicyReadResult *HearthReadNodePolicies(ODNode *node);

NS_ASSUME_NONNULL_END
