#import "Chronos.h"

NSString *currentASIN = nil;

static double    lastLoggedElapsed = -1;
static NSInteger lastTotalDuration = -1;

@implementation AudibleMetadataCapture

+ (void)initialize
{
    if (self == [AudibleMetadataCapture class])
    {
        currentASIN = nil;
    }
}

+ (NSString *)getAudibleDocumentsPath
{
    @try
    {
        NSArray *paths =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count > 0)
        {
            return paths[0];
        }
    }
    @catch (__unused NSException *e)
    {
        [Logger error:LOG_CATEGORY_UTILITIES
               format:@"Failed to get documents path: %@", e.description];
    }
    return nil;
}

+ (NSInteger)getCurrentProgressForASIN:(NSString *)asin
{
    if (!asin || asin.length == 0)
        return -1;

    @try
    {
        NSString *documentsPath = [self getAudibleDocumentsPath];
        if (!documentsPath)
            return -1;

        NSString *listeningLogPath = [documentsPath stringByAppendingPathComponent:@"listeningLog"];
        NSFileManager *fileManager = [NSFileManager defaultManager];

        NSDirectoryEnumerator *enumerator     = [fileManager enumeratorAtPath:listeningLogPath];
        NSString              *targetFileName = [NSString stringWithFormat:@"%@.json", asin];
        NSString              *logFilePath    = nil;

        for (NSString *file in enumerator)
        {
            if ([file.lastPathComponent isEqualToString:targetFileName])
            {
                logFilePath = [listeningLogPath stringByAppendingPathComponent:file];
                break;
            }
        }

        if (!logFilePath || ![fileManager fileExistsAtPath:logFilePath])
        {
            [Logger info:LOG_CATEGORY_DEFAULT format:@"No listening log found for ASIN: %@", asin];
            return -1;
        }

        NSData *data = [NSData dataWithContentsOfFile:logFilePath];
        if (!data)
            return -1;

        NSError *error         = nil;
        NSArray *progressArray = [NSJSONSerialization JSONObjectWithData:data
                                                                 options:0
                                                                   error:&error];

        if (error || ![progressArray isKindOfClass:[NSArray class]] || progressArray.count == 0)
        {
            [Logger error:LOG_CATEGORY_DEFAULT
                   format:@"Failed to parse listening log for ASIN %@: %@", asin,
                          error.localizedDescription];
            return -1;
        }

        NSDictionary *lastEntry = progressArray.lastObject;
        if ([lastEntry isKindOfClass:[NSDictionary class]])
        {
            NSNumber *position = lastEntry[@"position"];
            if (position)
            {
                return [position integerValue] / 1000;
            }
        }
    }
    @catch (__unused NSException *e)
    {
        [Logger error:LOG_CATEGORY_UTILITIES
               format:@"Exception getting progress for ASIN %@: %@", asin, e.description];
    }

    return -1;
}

+ (NSInteger)calculateTotalDurationFromChapters:(NSArray *)chapters
{
    NSInteger totalDurationMS = 0;

    for (NSDictionary *chapter in chapters)
    {
        if ([chapter isKindOfClass:[NSDictionary class]])
        {
            NSNumber *lengthMS = chapter[@"lengthMS"];
            if ([lengthMS isKindOfClass:[NSNumber class]])
            {
                totalDurationMS += [lengthMS integerValue];
            }

            NSArray *nestedChapters = chapter[@"chapters"];
            if ([nestedChapters isKindOfClass:[NSArray class]] && nestedChapters.count > 0)
            {
                totalDurationMS += [self calculateTotalDurationFromChapters:nestedChapters];
            }
        }
    }

    return totalDurationMS;
}

+ (NSInteger)getTotalDurationForASIN:(NSString *)asin
{
    if (!asin || asin.length == 0)
        return -1;

    @try
    {
        NSString *documentsPath = [self getAudibleDocumentsPath];
        if (!documentsPath)
            return -1;

        NSString *assetsPlistPath  = [documentsPath stringByAppendingPathComponent:@"assets.plist"];
        NSFileManager *fileManager = [NSFileManager defaultManager];

        if (![fileManager fileExistsAtPath:assetsPlistPath])
        {
            [Logger info:LOG_CATEGORY_DEFAULT
                  format:@"assets.plist not found - book may not be downloaded"];
            return -1;
        }

        NSArray *assets = [NSArray arrayWithContentsOfFile:assetsPlistPath];
        if (![assets isKindOfClass:[NSArray class]])
        {
            [Logger error:LOG_CATEGORY_DEFAULT format:@"Failed to load assets.plist"];
            return -1;
        }

        for (NSDictionary *asset in assets)
        {
            if ([asset isKindOfClass:[NSDictionary class]])
            {
                NSString *assetASIN = asset[@"asin"];
                if ([assetASIN isEqualToString:asin])
                {
                    NSDictionary *trackInfo = asset[@"trackInfo"];
                    if ([trackInfo isKindOfClass:[NSDictionary class]])
                    {
                        NSArray *chapters = trackInfo[@"chapters"];
                        if ([chapters isKindOfClass:[NSArray class]] && chapters.count > 0)
                        {
                            NSInteger totalDurationMS =
                                [self calculateTotalDurationFromChapters:chapters];

                            if (totalDurationMS > 0)
                            {
                                NSInteger totalDurationSeconds = totalDurationMS / 1000;
                                return totalDurationSeconds;
                            }
                        }
                    }
                }
            }
        }

        [Logger info:LOG_CATEGORY_DEFAULT
              format:@"ASIN %@ not found in assets.plist - book may not be downloaded", asin];
    }
    @catch (__unused NSException *e)
    {
        [Logger error:LOG_CATEGORY_UTILITIES
               format:@"Exception getting duration for ASIN %@: %@", asin, e.description];
    }

    return -1;
}

+ (void)loadBookDataForASIN:(NSString *)asin
{
    if (!asin || asin.length == 0)
        return;

    if ([asin isEqualToString:currentASIN])
        return;

    currentASIN       = asin;
    lastLoggedElapsed = -1;
    lastTotalDuration = -1;

    [HardcoverAPI autoSwitchToEditionForASIN:asin];

    NSInteger totalDuration = [self getTotalDurationForASIN:asin];
    if (totalDuration == -1)
    {
        [Logger info:LOG_CATEGORY_DEFAULT
              format:@"Book with ASIN %@ is not downloaded. Please download the book first.", asin];
        return;
    }

    lastTotalDuration = totalDuration;
}

+ (void)updateProgressAfterDelay:(NSString *)asin
{
    if (!asin || asin.length == 0)
        return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                   ^{ [self handleProgressUpdate:asin]; });
}

+ (void)handleProgressUpdate:(NSString *)asin
{
    @try
    {
        NSInteger currentProgress = [self getCurrentProgressForASIN:asin];
        NSInteger totalDuration   = [self getTotalDurationForASIN:asin];

        if (currentProgress == -1 || totalDuration == -1)
        {
            [Logger info:LOG_CATEGORY_DEFAULT
                  format:@"Could not get progress data for ASIN: %@", asin];
            return;
        }

        if (abs((int) (currentProgress - lastLoggedElapsed)) < 1 &&
            totalDuration == lastTotalDuration)
            return;

        lastLoggedElapsed = currentProgress;
        lastTotalDuration = totalDuration;

        [Logger info:LOG_CATEGORY_DEFAULT
              format:@"Progress update: %ld/%ld seconds (%.1f%%)", (long) currentProgress,
                     (long) totalDuration, (currentProgress * 100.0 / totalDuration)];

        [[HardcoverAPI sharedInstance]
            updateListeningProgressForASIN:asin
                           progressSeconds:currentProgress
                              totalSeconds:totalDuration
                                completion:^(BOOL success, NSError *error) {
                                    if (!success)
                                    {
                                        [Logger
                                             error:LOG_CATEGORY_HARDCOVER
                                            format:@"Progress update failed for ASIN %@: %@", asin,
                                                   error ? error.localizedDescription
                                                         : @"Unknown error"];
                                    }
                                }];

        double completionPercentage = (double) currentProgress / totalDuration;
        if (completionPercentage >= 0.90)
        {
            [Logger info:LOG_CATEGORY_DEFAULT format:@"Book is 90%% complete, marking as finished"];
            [[HardcoverAPI sharedInstance]
                markBookCompletedForASIN:asin
                            totalSeconds:totalDuration
                              completion:^(BOOL success, NSError *error) {
                                  if (!success)
                                  {
                                      [Logger
                                           error:LOG_CATEGORY_HARDCOVER
                                          format:@"Failed to mark book completed for ASIN %@: %@",
                                                 asin,
                                                 error ? error.localizedDescription
                                                       : @"Unknown error"];
                                  }
                              }];
        }
    }
    @catch (__unused NSException *e)
    {
        [Logger error:LOG_CATEGORY_UTILITIES
               format:@"Exception in handleProgressUpdate: %@", e.description];
    }
}

+ (void)handlePlayPauseEventWithInfo:(NSDictionary *)nowPlayingInfo
{
    if (!nowPlayingInfo || !currentASIN)
        return;

    @try
    {
        NSNumber   *rate          = nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate];
        static BOOL lastIsPlaying = NO;
        BOOL        isPlaying     = (rate ? ([rate doubleValue] > 0.0) : NO);

        if (isPlaying != lastIsPlaying)
        {
            lastIsPlaying = isPlaying;
            [self updateProgressAfterDelay:currentASIN];
        }
    }
    @catch (__unused NSException *e)
    {
        [Logger error:LOG_CATEGORY_UTILITIES
               format:@"Exception in handlePlayPauseEventWithInfo: %@", e.description];
    }
}

@end

%hook MPNowPlayingInfoCenter

- (void)setNowPlayingInfo:(NSDictionary *)nowPlayingInfo
{
    if (nowPlayingInfo && currentASIN)
    {
        [AudibleMetadataCapture handlePlayPauseEventWithInfo:nowPlayingInfo];
    }
    %orig;
}

%end

%hook NSManagedObjectContext
- (NSArray *)executeFetchRequest:(NSFetchRequest *)request error:(NSError **)error
{
    NSArray *res = %orig;
    @try
    {
        if (!request || ![request isKindOfClass:[NSFetchRequest class]])
            return res;
        if (![res isKindOfClass:[NSArray class]] || res.count != 1)
            return res;
        NSString *entityName = nil;
        if ([request respondsToSelector:@selector(entityName)])
            entityName = request.entityName;
        if (![entityName isEqualToString:@"DBItem"])
            return res;
        NSPredicate *pred = request.predicate;
        if (!pred)
            return res;
        NSString *format = pred.predicateFormat;
        if (format.length == 0)
            return res;
        if ([format rangeOfString:@" OR "].location != NSNotFound ||
            [format rangeOfString:@" IN "].location != NSNotFound)
            return res;
        NSRange keyRange = [format rangeOfString:@"asin == \""];
        if (keyRange.location == NSNotFound)
            return res;
        NSUInteger startIdx = NSMaxRange(keyRange);
        if (startIdx >= format.length)
            return res;
        NSRange rest     = NSMakeRange(startIdx, format.length - startIdx);
        NSRange endQuote = [format rangeOfString:@"\"" options:0 range:rest];
        if (endQuote.location == NSNotFound || endQuote.location <= startIdx)
            return res;
        NSString *asin =
            [format substringWithRange:NSMakeRange(startIdx, endQuote.location - startIdx)];
        if (asin.length && ![asin isEqualToString:currentASIN])
        {
            [AudibleMetadataCapture loadBookDataForASIN:asin];
        }
    }
    @catch (__unused NSException *e)
    {
        [Logger error:LOG_CATEGORY_UTILITIES
               format:@"Exception in NSManagedObjectContext hook: %@", e.description];
    }
    return res;
}
%end

%ctor
{
    [Logger notice:LOG_CATEGORY_DEFAULT format:@"Tweak initialized"];
}
