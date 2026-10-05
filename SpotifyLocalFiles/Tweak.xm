#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const SPFTracksKey = @"SpotifyLocalFiles.tracks";
static AVAudioPlayer *SPFPlayer = nil;

@interface SPFTrack : NSObject
@property(nonatomic, copy) NSString *uuid;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *artist;
@property(nonatomic, copy) NSString *filename;
@property(nonatomic, copy) NSString *playlist;
@end

@implementation SPFTrack
@end

@class SPFLibraryViewController;

@interface SPFStore : NSObject <UIDocumentPickerDelegate>
+ (instancetype)shared;
- (void)showLibraryFrom:(UIViewController *)presenter;
- (void)importFrom:(UIViewController *)presenter;
- (NSArray<SPFTrack *> *)tracksForPlaylist:(NSString *)playlist;
- (void)playTrack:(SPFTrack *)track;
- (void)addTrack:(SPFTrack *)track toPlaylist:(NSString *)playlist;
@property(nonatomic, copy) NSString *pendingPlaylist;
@end

@interface SPFLibraryViewController : UITableViewController
@property(nonatomic, strong) SPFStore *store;
@end

@implementation SPFStore {
    NSMutableArray<SPFTrack *> *_tracks;
}

+ (instancetype)shared {
    static SPFStore *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [SPFStore new];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _tracks = [NSMutableArray array];

    NSArray *raw = [[NSUserDefaults standardUserDefaults] arrayForKey:SPFTracksKey];
    for (NSDictionary *d in raw ?: @[]) {
        SPFTrack *track = [SPFTrack new];
        track.uuid = d[@"uuid"] ?: NSUUID.UUID.UUIDString;
        track.title = d[@"title"] ?: @"Untitled";
        track.artist = d[@"artist"] ?: @"Local File";
        track.filename = d[@"filename"] ?: @"";
        track.playlist = d[@"playlist"] ?: @"";
        [_tracks addObject:track];
    }

    return self;
}

- (void)persist {
    NSMutableArray *raw = [NSMutableArray arrayWithCapacity:_tracks.count];
    for (SPFTrack *track in _tracks) {
        [raw addObject:@{
            @"uuid": track.uuid ?: @"",
            @"title": track.title ?: @"Untitled",
            @"artist": track.artist ?: @"Local File",
            @"filename": track.filename ?: @"",
            @"playlist": track.playlist ?: @""
        }];
    }
    [[NSUserDefaults standardUserDefaults] setObject:raw forKey:SPFTracksKey];
}

- (NSURL *)storageURL {
    NSURL *documents = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                                inDomains:NSUserDomainMask] firstObject];
    NSURL *folder = [documents URLByAppendingPathComponent:@"SpotifyLocalFiles" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:folder
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return folder;
}

- (NSArray<SPFTrack *> *)tracksForPlaylist:(NSString *)playlist {
    if (playlist.length == 0) return @[];

    NSMutableArray *result = [NSMutableArray array];
    for (SPFTrack *track in _tracks) {
        if ([track.playlist localizedCaseInsensitiveCompare:playlist] == NSOrderedSame) {
            [result addObject:track];
        }
    }
    return result;
}

- (void)addTrack:(SPFTrack *)track toPlaylist:(NSString *)playlist {
    if (!track || playlist.length == 0) return;
    track.playlist = playlist;
    [self persist];
}

- (UIViewController *)topControllerFrom:(UIViewController *)root {
    UIViewController *top = root;

    while (top.presentedViewController) {
        top = top.presentedViewController;
    }

    if (top.navigationController && top.navigationController.visibleViewController != top) {
        top = top.navigationController.visibleViewController;
        while (top.presentedViewController) {
            top = top.presentedViewController;
        }
    }

    return top;
}

- (UIViewController *)currentSpotifyController {
    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if ([candidate isKindOfClass:UIWindowScene.class] &&
            candidate.activationState != UISceneActivationStateUnattached) {
            scene = (UIWindowScene *)candidate;
            break;
        }
    }

    UIWindow *window = scene.keyWindow ?: scene.windows.firstObject;
    return [self topControllerFrom:window.rootViewController];
}

- (NSString *)playlistContextFrom:(UIViewController *)viewController {
    NSString *title = viewController.navigationItem.title;
    if (title.length == 0) title = viewController.title;
    return [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

- (void)showLibraryFrom:(UIViewController *)presenter {
    presenter = [self topControllerFrom:presenter];

    SPFLibraryViewController *library =
        [[SPFLibraryViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    library.store = self;
    library.title = @"Local Files";
    library.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:library
                                                      action:@selector(spf_close)];
    library.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:library
                                                      action:@selector(spf_import)];

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:library];
    [presenter presentViewController:nav animated:YES completion:nil];
}

- (void)importFrom:(UIViewController *)presenter {
    presenter = [self topControllerFrom:presenter];
    self.pendingPlaylist = [self playlistContextFrom:presenter];

    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc]
                  initForOpeningContentTypes:@[UTTypeAudio]
                  asCopy:YES];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.audio"]
                                                                          inMode:UIDocumentPickerModeImport];
    }

    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *source = urls.firstObject;
    if (!source) return;

    BOOL secured = [source startAccessingSecurityScopedResource];

    NSString *extension = source.pathExtension.length ? source.pathExtension : @"m4a";
    NSString *uuid = NSUUID.UUID.UUIDString;
    NSString *storedName = [NSString stringWithFormat:@"%@.%@", uuid, extension];
    NSURL *destination = [[self storageURL] URLByAppendingPathComponent:storedName];

    NSError *copyError = nil;
    [[NSFileManager defaultManager] copyItemAtURL:source toURL:destination error:&copyError];

    if (secured) {
        [source stopAccessingSecurityScopedResource];
    }

    if (copyError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert =
                [UIAlertController alertControllerWithTitle:@"Import failed"
                                                    message:copyError.localizedDescription
                                             preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                       style:UIAlertActionStyleDefault
                                                     handler:nil]];
            UIViewController *top = [self currentSpotifyController];
            [top presentViewController:alert animated:YES completion:nil];
        });
        return;
    }

    SPFTrack *track = [SPFTrack new];
    track.uuid = uuid;
    track.filename = storedName;
    track.title = [source.lastPathComponent stringByDeletingPathExtension];
    track.artist = @"Local File";
    track.playlist = @"";

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:destination options:nil];
    for (AVMetadataItem *item in asset.commonMetadata) {
        if ([item.commonKey isEqualToString:AVMetadataCommonKeyTitle] &&
            [item.value isKindOfClass:NSString.class] &&
            [((NSString *)item.value) length]) {
            track.title = item.value;
        } else if ([item.commonKey isEqualToString:AVMetadataCommonKeyArtist] &&
                   [item.value isKindOfClass:NSString.class] &&
                   [((NSString *)item.value) length]) {
            track.artist = item.value;
        }
    }

    [_tracks addObject:track];
    [self persist];

    NSString *playlist = self.pendingPlaylist ?: @"";
    self.pendingPlaylist = @"";

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [self currentSpotifyController];

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:track.title
                                                message:playlist.length
                                                    ? [NSString stringWithFormat:@"%@\n\nLocal Files stores this track on the device.", playlist]
                                                    : @"Local Files stores this track on the device."
                                         preferredStyle:UIAlertControllerStyleAlert];

        if (playlist.length) {
            [alert addAction:[UIAlertAction actionWithTitle:@"Add to this playlist"
                                                       style:UIAlertActionStyleDefault
                                                     handler:^(__unused UIAlertAction *action) {
                [self addTrack:track toPlaylist:playlist];
                [[NSNotificationCenter defaultCenter] postNotificationName:@"SpotifyLocalFilesDidChange"
                                                                    object:nil];
            }]];
        }

        [alert addAction:[UIAlertAction actionWithTitle:@"Done"
                                                   style:UIAlertActionStyleCancel
                                                 handler:nil]];

        [top presentViewController:alert animated:YES completion:nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SpotifyLocalFilesDidChange"
                                                            object:nil];
    });
}

- (void)playTrack:(SPFTrack *)track {
    if (!track.filename.length) return;

    NSURL *url = [[self storageURL] URLByAppendingPathComponent:track.filename];
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) return;

    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionDuckOthers
                   error:nil];
    [session setActive:YES error:nil];

    SPFPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
    if (!SPFPlayer || error) {
        NSLog(@"[SpotifyLocalFiles] player init failed: %@", error);
        return;
    }

    [SPFPlayer prepareToPlay];
    [SPFPlayer play];
    NSLog(@"[SpotifyLocalFiles] playing %@", track.title);
}

@end

@implementation SPFLibraryViewController

- (void)spf_close {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)spf_import {
    [self.store importFrom:self];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1 + [self.store valueForKey:@"_tracks"].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"SPFLocalCell";
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];

    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }

    NSArray *tracks = [self.store valueForKey:@"_tracks"];

    if (indexPath.row == 0) {
        cell.textLabel.text = @"Import audio file";
        cell.detailTextLabel.text = @"Choose a file from Files";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    SPFTrack *track = tracks[indexPath.row - 1];
    cell.textLabel.text = track.title;
    cell.detailTextLabel.text = track.playlist.length
        ? [NSString stringWithFormat:@"%@ • %@", track.artist, track.playlist]
        : track.artist;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.row == 0) {
        [self.store importFrom:self];
        return;
    }

    NSArray *tracks = [self.store valueForKey:@"_tracks"];
    if (indexPath.row - 1 < tracks.count) {
        [self.store playTrack:tracks[indexPath.row - 1]];
    }
}

@end

@interface SPFLocalButton : UIButton
@property(nonatomic, weak) UIViewController *owner;
@end

@implementation SPFLocalButton
@end

@interface SPFPlaylistPanel : UIView
@property(nonatomic, weak) UIViewController *owner;
@end

@implementation SPFPlaylistPanel
@end

static void SPFRemoveOldUI(UIViewController *vc) {
    for (UIView *view in [vc.view.subviews copy]) {
        if (view.tag == 9048 || view.tag == 9049) {
            [view removeFromSuperview];
        }
    }
}

static void SPFInstallUI(UIViewController *vc) {
    if (!vc || !vc.view.window) return;
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.spotify.client"]) return;

    SPFRemoveOldUI(vc);

    CGFloat width = CGRectGetWidth(vc.view.bounds);
    SPFLocalButton *button = [SPFLocalButton buttonWithType:UIButtonTypeSystem];
    button.tag = 9048;
    button.owner = vc;
    button.frame = CGRectMake(width - 64.0, 54.0, 50.0, 42.0);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    button.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.92];
    button.layer.cornerRadius = 20.0;
    [button setTitle:@"♫+" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightBold];

    [button addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        [[SPFStore shared] showLibraryFrom:vc];
    }] forControlEvents:UIControlEventTouchUpInside];

    [vc.view addSubview:button];
    [vc.view bringSubviewToFront:button];

    NSString *playlist = [[SPFStore shared] playlistContextFrom:vc];
    NSArray<SPFTrack *> *tracks = [[SPFStore shared] tracksForPlaylist:playlist];

    if (tracks.count == 0) return;

    CGFloat panelHeight = 60.0;
    SPFPlaylistPanel *panel =
        [[SPFPlaylistPanel alloc] initWithFrame:CGRectMake(10.0,
                                                           CGRectGetHeight(vc.view.bounds) - panelHeight - 14.0,
                                                           width - 20.0,
                                                           panelHeight)];
    panel.tag = 9049;
    panel.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                             UIViewAutoresizingFlexibleTopMargin;
    panel.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.94];
    panel.layer.cornerRadius = 16.0;
    panel.owner = vc;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 4, 90, 20)];
    label.text = @"LOCAL";
    label.textColor = [UIColor colorWithWhite:1 alpha:0.65];
    label.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightBold];
    [panel addSubview:label];

    UIScrollView *scroll =
        [[UIScrollView alloc] initWithFrame:CGRectMake(8, 22, panel.bounds.size.width - 16, 32)];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    scroll.showsHorizontalScrollIndicator = NO;

    CGFloat x = 0;
    for (SPFTrack *track in tracks) {
        UIButton *item = [UIButton buttonWithType:UIButtonTypeSystem];
        NSString *title = track.title.length ? track.title : @"Local";
        item.frame = CGRectMake(x, 0, MAX(120.0, MIN(230.0, title.length * 7.0 + 58.0)), 28.0);
        item.layer.cornerRadius = 13.0;
        item.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1.0];
        [item setTitle:title forState:UIControlStateNormal];
        [item setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        item.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        item.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);

        [item addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            [[SPFStore shared] playTrack:track];
        }] forControlEvents:UIControlEventTouchUpInside];

        [scroll addSubview:item];
        x += item.bounds.size.width + 8.0;
    }

    scroll.contentSize = CGSizeMake(x, 28.0);
    [panel addSubview:scroll];
    [vc.view addSubview:panel];
    [vc.view bringSubviewToFront:panel];
}

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.spotify.client"]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        SPFInstallUI(self);
    });
}

%end

%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.spotify.client"]) return;

    NSLog(@"[SpotifyLocalFiles] loaded - Spotify %@",
          [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);
}
