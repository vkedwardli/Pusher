#import <Preferences/PSListController.h>

@interface NSPServiceListController : PSViewController <UITableViewDelegate, UITableViewDataSource> {
  NSDictionary *_prefs;
  UITableView *_table;
  NSArray *_sections;
  NSMutableDictionary *_data;
  NSArray *_services;
}
@end
