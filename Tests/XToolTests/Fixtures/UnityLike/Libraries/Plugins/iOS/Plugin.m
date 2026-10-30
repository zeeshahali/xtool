__attribute__((objc_root_class))
@interface XTPlugin
+ (int)value;
@end

@implementation XTPlugin
+ (int)value { return 2; }
@end

int PluginValue(void)
{
#if __has_feature(objc_arc)
#error "per-file -fno-objc-arc was not applied"
#endif
    return [XTPlugin value];
}
