#import <Foundation/Foundation.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fail(NSString *message) {
    fprintf(stderr, "NoDraw Duplicate Preview: %s\n", message.UTF8String);
    return EXIT_FAILURE;
}

static BOOL isWithin(NSString *path, NSString *root) {
    return [path isEqualToString:root] || [path hasPrefix:[root stringByAppendingString:@"/"]];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSFileManager *files = NSFileManager.defaultManager;
        NSBundle *bundle = NSBundle.mainBundle;
        NSURL *home = files.homeDirectoryForCurrentUser.URLByResolvingSymlinksInPath;
        NSString *override = NSProcessInfo.processInfo.environment[@"NODRAW_DUPLICATE_PREVIEW_DATA_DIR"];
        NSURL *data;
        if (override != nil) {
            if (![override hasPrefix:@"/"]) return fail(@"NODRAW_DUPLICATE_PREVIEW_DATA_DIR must be an absolute path.");
            data = [NSURL fileURLWithPath:override isDirectory:YES].URLByStandardizingPath.URLByResolvingSymlinksInPath;
            NSMutableArray<NSURL *> *forbidden = [NSMutableArray arrayWithObject:[home URLByAppendingPathComponent:@"MediaArchive" isDirectory:YES]];
            for (NSString *name in @[@"NoDraw", @"NoDraw Editor Preview", @"MediaViewer", @"com.nodraw.app", @"media-viewer", @"com.mediaviewer"]) {
                [forbidden addObject:[home URLByAppendingPathComponent:[@"Library/Application Support/" stringByAppendingString:name] isDirectory:YES]];
            }
            if ([data.path isEqualToString:@"/"] || [data.path isEqualToString:home.path]) return fail(@"The preview data override cannot be the filesystem root or home directory.");
            for (NSURL *live in forbidden) {
                if (isWithin(data.path, live.URLByResolvingSymlinksInPath.path)) return fail(@"The preview data override cannot use an installed app's live data directory.");
            }
        } else {
            NSURL *support = [files URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
            if (support == nil) return fail(@"Could not locate your Application Support directory.");
            data = [support URLByAppendingPathComponent:@"NoDraw Duplicate Preview" isDirectory:YES];
        }

        NSURL *support = [data URLByAppendingPathComponent:@"AppSupport" isDirectory:YES];
        NSURL *archive = [data URLByAppendingPathComponent:@"Archive" isDirectory:YES];
        NSError *error = nil;
        if (![files createDirectoryAtURL:support withIntermediateDirectories:YES attributes:nil error:&error]) return fail(error.localizedDescription);
        BOOL directory = NO;
        if ([files fileExistsAtPath:archive.path isDirectory:&directory]) {
            if (!directory) return fail(@"The preview Archive path exists but is not a directory.");
        } else {
            NSURL *sample = [bundle.resourceURL URLByAppendingPathComponent:@"DemoArchive" isDirectory:YES];
            NSURL *staging = [data URLByAppendingPathComponent:[@".Archive-seed-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
            if (![files copyItemAtURL:sample toURL:staging error:&error]) return fail(error.localizedDescription);
            if (![files moveItemAtURL:staging toURL:archive error:&error]) {
                [files removeItemAtURL:staging error:nil];
                // Another simultaneous launch may have finished the same one-time seed.
                if (![files fileExistsAtPath:archive.path isDirectory:&directory] || !directory) return fail(error.localizedDescription);
            }
        }

        // Always override inherited live-profile variables, including legacy aliases.
        setenv("NODRAW_APP_SUPPORT_DIR", support.path.fileSystemRepresentation, 1);
        setenv("MEDIAVIEWER_APP_SUPPORT_DIR", support.path.fileSystemRepresentation, 1);
        setenv("NODRAW_ARCHIVE_PATH", archive.path.fileSystemRepresentation, 1);
        setenv("MEDIAVIEWER_ARCHIVE_PATH", archive.path.fileSystemRepresentation, 1);

        NSURL *core = [[bundle.bundleURL URLByAppendingPathComponent:@"Contents/MacOS" isDirectory:YES] URLByAppendingPathComponent:@"NoDraw"];
        char **arguments = calloc((size_t)argc + 6, sizeof(char *));
        if (arguments == NULL) return fail(@"Could not allocate launch arguments.");
        arguments[0] = (char *)core.path.fileSystemRepresentation;
        arguments[1] = "--editor-preview";
        arguments[2] = "-hasCompletedOnboarding";
        arguments[3] = "YES";
        arguments[4] = "-downloadServerEnabled";
        arguments[5] = "NO";
        for (int index = 1; index < argc; index++) arguments[index + 5] = argv[index];
        execv(arguments[0], arguments);
        int savedErrno = errno;
        free(arguments);
        return fail([NSString stringWithFormat:@"Could not start duplicate review: %s", strerror(savedErrno)]);
    }
}
