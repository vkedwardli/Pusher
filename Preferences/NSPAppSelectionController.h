#import <Preferences/PSViewController.h>
#import <AppList/AppList.h>
#import "NSPAppSelectionALApplicationTableDataSource.h"
#import "NSPCustomizeAppsController.h"

@interface NSPAppSelectionController : UITableViewController <UITableViewDelegate, UISearchResultsUpdating> {
  ALApplicationList *_appList;
  NSPAppSelectionALApplicationTableDataSource *_appListDataSource;
}
@property (nonatomic, copy) BOOL selectingMultiple;
@property (nonatomic, retain) NSString *title;
@property (nonatomic, retain) NSString *rightButtonTitle;
@property (nonatomic, retain) NSMutableArray *selectedAppIDs;
@property (nonatomic, retain) NSPCustomizeAppsController *customizeAppsController;
- (void)dismiss;
@end
