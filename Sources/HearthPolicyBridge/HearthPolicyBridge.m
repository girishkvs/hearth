#import "HearthPolicyBridge.h"

@implementation HearthPolicyReadResult
- (instancetype)initWithPolicies:(NSDictionary *)policies error:(NSError *)error {
    self = [super init];
    if (self) {
        if (policies && ![policies isKindOfClass:[NSDictionary class]]) {
            _error = [NSError errorWithDomain:@"HearthPolicyRead" code:1 userInfo:nil];
        } else {
            _policies = [policies copy];
            _error = error;
        }
    }
    return self;
}
@end

HearthPolicyReadResult *HearthReadRecordPolicies(ODRecord *record) {
    NSError *error = nil;
    NSDictionary *policies = [record accountPoliciesAndReturnError:&error];
    return [[HearthPolicyReadResult alloc] initWithPolicies:policies error:error];
}

HearthPolicyReadResult *HearthReadNodePolicies(ODNode *node) {
    NSError *error = nil;
    NSDictionary *policies = [node accountPoliciesAndReturnError:&error];
    return [[HearthPolicyReadResult alloc] initWithPolicies:policies error:error];
}
