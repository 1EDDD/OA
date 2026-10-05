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

    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc]
         initForOpeningContentTypes:@[UTTypeAudio]
         asCopy:YES];

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
            track.title = (NSString *)item.value;
        } else if ([item.commonKey isEqualToString:AVMetadataCommonKeyArtist] &&
                   [item.value isKindOfClass:NSString.class] &&
                   [((NSString *)item.value) length]) {
            track.artist = (NSString *)item.value;
        }
    }

    NSString *playlist = self.pendingPlaylist ?: @"";
    self.pendingPlaylist = @"";

    // A local file is a real row in the open playlist UI, while playback stays local.
    track.playlist = playlist;
    [_tracks addObject:track];
    [self persist];

    dispatch_async(dispatch_get_main_queue(), ^{
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
        NSArray *tracks = (NSArray *)[self.store valueForKey:@"_tracks"];
    return 1 + tracks.count;
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

static const NSInteger SPFLocalButtonTag = 9048;
static const NSInteger SPFLocalRowsTag = 9050;

static BOOL SPFViewTreeContainsPlaylistLabel(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = [(UILabel *)view text];
        if (text.length && [text rangeOfString:@"playlist" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }

    for (UIView *child in view.subviews) {
        if (SPFViewTreeContainsPlaylistLabel(child)) return YES;
    }
    return NO;
}

static BOOL SPFIsPlaylistViewController(UIViewController *vc) {
    if (!vc || !vc.viewIfLoaded.window) return NO;
    if (SPFViewTreeContainsPlaylistLabel(vc.view)) return YES;

    // Some Spotify screens expose the playlist subtitle only through accessibility.
    UIAccessibilityElement *focused = UIAccessibilityFocusedElement(UIAccessibilityNotificationVoiceOverIdentifier);
    if ([focused isKindOfClass:NSString.class] &&
        [(NSString *)focused rangeOfString:@"playlist" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }

    return NO;
}

static UIScrollView *SPFLargestScrollView(UIView *root) {
    UIScrollView *best = nil;
    CGFloat bestScore = 0;

    NSMutableArray *stack = [NSMutableArray arrayWithObject:root ?: (UIView *)[UIView new]];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if ([view isKindOfClass:UIScrollView.class] && view != root) {
            UIScrollView *scroll = (UIScrollView *)view;
            CGFloat area = CGRectGetWidth(scroll.bounds) * CGRectGetHeight(scroll.bounds);
            CGFloat score = area + MIN(scroll.contentSize.height, 5000.0) * 120.0;
            if (CGRectGetWidth(scroll.bounds) > 250.0 && CGRectGetHeight(scroll.bounds) > 250.0 && score > bestScore) {
                best = scroll;
                bestScore = score;
            }
        }

        [stack addObjectsFromArray:view.subviews];
    }
    return best;
}

static void SPFRemoveOldRows(UIView *view) {
    UIView *rows = [view viewWithTag:SPFLocalRowsTag];
    if (rows) [rows removeFromSuperview];
}

static void SPFPlayLocalTrackFromRow(SPFTrack *track) {
    [[SPFStore shared] playTrack:track];
}

static UIView *SPFBuildLocalSongRow(SPFTrack *track, CGFloat width) {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 72.0)];
    row.backgroundColor = UIColor.clearColor;

    UIImageView *art = [[UIImageView alloc] initWithFrame:CGRectMake(8, 6, 60, 60)];
    art.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1.0];
    art.layer.cornerRadius = 4.0;
    art.clipsToBounds = YES;

    NSURL *fileURL = [[[SPFStore shared] storageURL] URLByAppendingPathComponent:track.filename ?: @""];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:fileURL options:nil];
    for (AVMetadataItem *item in asset.commonMetadata) {
        if ([item.commonKey isEqualToString:AVMetadataCommonKeyArtwork] && [item.value isKindOfClass:NSData.class]) {
            UIImage *image = [UIImage imageWithData:(NSData *)item.value scale:2.0];
            if (image) art.image = image;
        }
    }
    if (!art.image) {
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(60, 60)];
        art.image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [[UIColor colorWithWhite:0.11 alpha:1.0] setFill];
            UIRectFill(CGRectMake(0, 0, 60, 60));
            NSDictionary *attrs = @{
                NSFontAttributeName: [UIFont systemFontOfSize:26.0 weight:UIFontWeightSemibold],
                NSForegroundColorAttributeName: UIColor.whiteColor
            };
            [@"♪" drawAtPoint:CGPointMake(20, 15) withAttributes:attrs];
        }];
    }
    [row addSubview:art];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(80, 12, MAX(120.0, width - 126.0), 24)];
    title.text = track.title.length ? track.title : @"Local audio";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    [row addSubview:title];

    UILabel *artist = [[UILabel alloc] initWithFrame:CGRectMake(80, 38, MAX(120.0, width - 126.0), 20)];
    artist.text = track.artist.length ? track.artist : @"Local File";
    artist.textColor = [UIColor colorWithWhite:1.0 alpha:0.60];
    artist.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    artist.lineBreakMode = NSLineBreakByTruncatingTail;
    [row addSubview:artist];

    UIButton *hit = [UIButton buttonWithType:UIButtonTypeSystem];
    hit.frame = row.bounds;
    hit.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [hit addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        SPFPlayLocalTrackFromRow(track);
    }] forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:hit];

    UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(80, 71, MAX(100.0, width - 80), 1)];
    divider.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [row addSubview:divider];

    return row;
}

static void SPFInstallLocalRows(UIViewController *vc, NSString *playlist) {
    if (playlist.length == 0) return;

    NSArray<SPFTrack *> *tracks = [[SPFStore shared] tracksForPlaylist:playlist];
    UIScrollView *scroll = SPFLargestScrollView(vc.view);
    if (!scroll) return;

    UIView *rows = [scroll viewWithTag:SPFLocalRowsTag];
    if (tracks.count == 0) {
        [rows removeFromSuperview];
        return;
    }

    NSString *signature = [NSString stringWithFormat:@"SpotifyLocalFiles:%@:%lu", playlist, (unsigned long)tracks.count];
    if (!rows || ![rows.accessibilityIdentifier isEqualToString:signature]) {
        [rows removeFromSuperview];

        CGFloat width = MAX(300.0, CGRectGetWidth(scroll.bounds));
        rows = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, tracks.count * 72.0 + 8.0)];
        rows.tag = SPFLocalRowsTag;
        rows.accessibilityIdentifier = signature;
        rows.backgroundColor = UIColor.clearColor;

        for (NSUInteger i = 0; i < tracks.count; i++) {
            UIView *row = SPFBuildLocalSongRow(tracks[i], width);
            CGRect frame = row.frame;
            frame.origin.y = i * 72.0;
            row.frame = frame;
            [rows addSubview:row];
        }
        [scroll addSubview:rows];
    }

    CGFloat originalHeight = MAX(scroll.contentSize.height, CGRectGetHeight(scroll.bounds));
    CGFloat y = originalHeight + 6.0;
    CGRect frame = rows.frame;
    frame.origin.x = 0;
    frame.origin.y = y;
    frame.size.width = MAX(300.0, CGRectGetWidth(scroll.bounds));
    rows.frame = frame;
    rows.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    CGFloat neededHeight = y + rows.bounds.size.height + 18.0;
    if (neededHeight > scroll.contentSize.height) {
        CGSize size = scroll.contentSize;
        size.height = neededHeight;
        scroll.contentSize = size;
    }
    [scroll bringSubviewToFront:rows];
}

static void SPFInstallUI(UIViewController *vc) {
    if (!vc || !vc.view.window) return;
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.spotify.client"]) return;
    if (!SPFIsPlaylistViewController(vc)) return;

    NSString *playlist = [[SPFStore shared] playlistContextFrom:vc];
    if (playlist.length == 0) return;

    SPFLocalButton *button = (SPFLocalButton *)[vc.view viewWithTag:SPFLocalButtonTag];
    if (!button) {
        CGFloat width = CGRectGetWidth(vc.view.bounds);
        button = [SPFLocalButton buttonWithType:UIButtonTypeSystem];
        button.tag = SPFLocalButtonTag;
        button.owner = vc;
        button.frame = CGRectMake(width - 112.0, 54.0, 96.0, 52.0);
        button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        button.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.96];
        button.layer.cornerRadius = 26.0;
        [button setTitle:@"♫+" forState:UIControlStateNormal];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
        [button addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            [[SPFStore shared] importFrom:vc];
        }] forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:button];
        [vc.view bringSubviewToFront:button];
    }

    SPFInstallLocalRows(vc, playlist);
}

static void (*SPFOriginalViewDidAppear)(UIViewController *self, SEL _cmd, BOOL animated) = NULL;
static void (*SPFOriginalViewDidLayoutSubviews)(UIViewController *self, SEL _cmd) = NULL;

static void SPFHookedViewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (SPFOriginalViewDidAppear) SPFOriginalViewDidAppear(self, _cmd, animated);
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.spotify.client"]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        SPFInstallUI(self);
    });
}

static void SPFHookedViewDidLayoutSubviews(UIViewController *self, SEL _cmd) {
    if (SPFOriginalViewDidLayoutSubviews) SPFOriginalViewDidLayoutSubviews(self, _cmd);
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.spotify.client"]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        SPFInstallUI(self);
    });
}

__attribute__((constructor))
static void SPFInitialize(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.spotify.client"]) return;

    Class vcClass = objc_getClass("UIViewController");
    Method appear = class_getInstanceMethod(vcClass, @selector(viewDidAppear:));
    if (appear) {
        SPFOriginalViewDidAppear = (void (*)(UIViewController *, SEL, BOOL))method_getImplementation(appear);
        method_setImplementation(appear, (IMP)SPFHookedViewDidAppear);
    }

    Method layout = class_getInstanceMethod(vcClass, @selector(viewDidLayoutSubviews));
    if (layout) {
        SPFOriginalViewDidLayoutSubviews = (void (*)(UIViewController *, SEL))method_getImplementation(layout);
        method_setImplementation(layout, (IMP)SPFHookedViewDidLayoutSubviews);
    }

    NSLog(@"[SpotifyLocalFiles] loaded - Spotify %@",
          [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);
}
