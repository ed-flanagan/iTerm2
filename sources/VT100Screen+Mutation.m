//
//  VT100Screen+Mutation.m
//  iTerm2Shared
//
//  Created by George Nachman on 12/9/21.
//

// For mysterious reasons this needs to be in the iTerm2XCTests to avoid runtime failures to call
// its methods in tests. If I ever have an appetite for risk try https://stackoverflow.com/a/17581430/321984
#import "VT100Screen+Mutation.h"
#import "VT100Screen+Resizing.h"

#import "CapturedOutput.h"
#import "DebugLogging.h"
#import "NSArray+iTerm.h"
#import "NSColor+iTerm.h"
#import "NSData+iTerm.h"
#import "NSDictionary+iTerm.h"
#import "SearchResult.h"
#import "TmuxStateParser.h"
#import "VT100RemoteHost.h"
#import "VT100ScreenMutableState+Resizing.h"
#import "VT100ScreenMutableState+TerminalDelegate.h"
#import "VT100Screen+Private.h"
#import "VT100Token.h"
#import "VT100WorkingDirectory.h"
#import "iTerm2SharedARC-Swift.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermCapturedOutputMark.h"
#import "iTermCommandHistoryCommandUseMO.h"
#import "iTermImageMark.h"
#import "iTermNotificationController.h"
#import "iTermOrderEnforcer.h"
#import "iTermPreferences.h"
#import "iTermSelection.h"
#import "iTermShellHistoryController.h"
#import "iTermTemporaryDoubleBufferedGridController.h"
#import "iTermTextExtractor.h"
#import "iTermURLMark.h"

#include <sys/time.h>

#warning TODO: I can't call regular VT100Screen methods from here because they'll use _state instead of _mutableState! I think this should eventually be its own class, not a category, to enfore the shared-nothing regime.

@implementation VT100Screen (Mutation)

- (VT100Grid *)mutableAltGrid {
    return (VT100Grid *)_state.altGrid;
}

- (VT100Grid *)mutablePrimaryGrid {
    return (VT100Grid *)_state.primaryGrid;
}

- (LineBuffer *)mutableLineBuffer {
    return (LineBuffer *)_mutableState.linebuffer;
}

- (void)mutUpdateConfig {
    _mutableState.config = _nextConfig;
}

#pragma mark - Clearing

- (void)mutClearScrollbackBuffer {
    [_mutableState clearScrollbackBuffer];
}

- (void)mutResetTimestamps {
    [self.mutablePrimaryGrid resetTimestamps];
    [self.mutableAltGrid resetTimestamps];
}

- (void)mutRemoveLastLine {
    DLog(@"BEGIN removeLastLine with cursor at %@", VT100GridCoordDescription(self.currentGrid.cursor));
    const int preHocNumberOfLines = [_mutableState.linebuffer numberOfWrappedLinesWithWidth:_mutableState.width];
    const int numberOfLinesAppended = [_mutableState.currentGrid appendLines:self.currentGrid.numberOfLinesUsed
                                                                toLineBuffer:_mutableState.linebuffer];
    if (numberOfLinesAppended <= 0) {
        return;
    }
    [_mutableState.currentGrid setCharsFrom:VT100GridCoordMake(0, 0)
                                         to:VT100GridCoordMake(_mutableState.width - 1,
                                                               _mutableState.height - 1)
                                     toChar:self.currentGrid.defaultChar
                         externalAttributes:nil];
    [self.mutableLineBuffer removeLastRawLine];
    const int postHocNumberOfLines = [_mutableState.linebuffer numberOfWrappedLinesWithWidth:_mutableState.width];
    const int numberOfLinesToPop = MAX(0, postHocNumberOfLines - preHocNumberOfLines);

    [_mutableState.currentGrid restoreScreenFromLineBuffer:_mutableState.linebuffer
                                           withDefaultChar:[self.currentGrid defaultChar]
                                         maxLinesToRestore:numberOfLinesToPop];
    // One of the lines "removed" will be the one the cursor is on. Don't need to move it up for
    // that one.
    const int adjustment = self.currentGrid.cursorX > 0 ? 1 : 0;
    _mutableState.currentGrid.cursorX = 0;
    const int numberOfLinesRemoved = MAX(0, numberOfLinesAppended - numberOfLinesToPop);
    const int y = MAX(0, self.currentGrid.cursorY - numberOfLinesRemoved + adjustment);
    DLog(@"numLinesAppended=%@ numLinesToPop=%@ numLinesRemoved=%@ adjustment=%@ y<-%@",
          @(numberOfLinesAppended), @(numberOfLinesToPop), @(numberOfLinesRemoved), @(adjustment), @(y));
    _mutableState.currentGrid.cursorY = y;
    DLog(@"Cursor at %@", VT100GridCoordDescription(self.currentGrid.cursor));
}

#pragma mark - Appending

- (void)mutAppendStringAtCursor:(NSString *)string {
    [_mutableState appendStringAtCursor:string];
}

- (void)mutAppendScreenChars:(const screen_char_t *)line
                      length:(int)length
      externalAttributeIndex:(id<iTermExternalAttributeIndexReading>)externalAttributeIndex
                continuation:(screen_char_t)continuation {
    [_mutableState appendScreenChars:line
                              length:length
              externalAttributeIndex:externalAttributeIndex
                        continuation:continuation];
}


#pragma mark - Arrangements

- (void)mutRestoreInitialSize {
    if (_state.initialSize.width > 0 && _state.initialSize.height > 0) {
        [self setSize:_state.initialSize];
        _mutableState.initialSize = VT100GridSizeMake(-1, -1);
    }
}

- (void)mutSetHistory:(NSArray *)history {
    // This is way more complicated than it should be to work around something dumb in tmux.
    // It pads lines in its history with trailing spaces, which we'd like to trim. More importantly,
    // we need to trim empty lines at the end of the history because that breaks how we move the
    // screen contents around on resize. So we take the history from tmux, append it to a temporary
    // line buffer, grab each wrapped line and trim spaces from it, and then append those modified
    // line (excluding empty ones at the end) to the real line buffer.
    [_mutableState clearBufferSavingPrompt:YES];
    LineBuffer *temp = [[[LineBuffer alloc] init] autorelease];
    temp.mayHaveDoubleWidthCharacter = YES;
    self.mutableLineBuffer.mayHaveDoubleWidthCharacter = YES;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    // TODO(externalAttributes): Add support for external attributes here. This is only used by tmux at the moment.
    iTermMetadata metadata;
    iTermMetadataInit(&metadata, now, nil);
    for (NSData *chars in history) {
        screen_char_t *line = (screen_char_t *) [chars bytes];
        const int len = [chars length] / sizeof(screen_char_t);
        screen_char_t continuation;
        if (len) {
            continuation = line[len - 1];
            continuation.code = EOL_HARD;
        } else {
            memset(&continuation, 0, sizeof(continuation));
        }
        [temp appendLine:line
                  length:len
                 partial:NO
                   width:_state.currentGrid.size.width
                metadata:iTermMetadataMakeImmutable(metadata)
            continuation:continuation];
    }
    NSMutableArray *wrappedLines = [NSMutableArray array];
    int n = [temp numLinesWithWidth:_state.currentGrid.size.width];
    int numberOfConsecutiveEmptyLines = 0;
    for (int i = 0; i < n; i++) {
        ScreenCharArray *line = [temp wrappedLineAtIndex:i
                                                   width:_state.currentGrid.size.width
                                            continuation:NULL];
        if (line.eol == EOL_HARD) {
            [self stripTrailingSpaceFromLine:line];
            if (line.length == 0) {
                ++numberOfConsecutiveEmptyLines;
            } else {
                numberOfConsecutiveEmptyLines = 0;
            }
        } else {
            numberOfConsecutiveEmptyLines = 0;
        }
        [wrappedLines addObject:line];
    }
    for (int i = 0; i < n - numberOfConsecutiveEmptyLines; i++) {
        ScreenCharArray *line = [wrappedLines objectAtIndex:i];
        screen_char_t continuation = { 0 };
        if (line.length) {
            continuation = line.line[line.length - 1];
        }
        [self.mutableLineBuffer appendLine:line.line
                                    length:line.length
                                   partial:(line.eol != EOL_HARD)
                                     width:_state.currentGrid.size.width
                                  metadata:iTermMetadataMakeImmutable(metadata)
                              continuation:continuation];
    }
    if (!_state.unlimitedScrollback) {
        [self.mutableLineBuffer dropExcessLinesWithWidth:_state.currentGrid.size.width];
    }

    // We don't know the cursor position yet but give the linebuffer something
    // so it doesn't get confused in restoreScreenFromScrollback.
    [self.mutableLineBuffer setCursor:0];
    [_mutableState.currentGrid restoreScreenFromLineBuffer:_mutableState.linebuffer
                                           withDefaultChar:[_state.currentGrid defaultChar]
                                         maxLinesToRestore:MIN([_mutableState.linebuffer numLinesWithWidth:_state.currentGrid.size.width],
                                                               _state.currentGrid.size.height - numberOfConsecutiveEmptyLines)];
}

- (void)stripTrailingSpaceFromLine:(ScreenCharArray *)line {
    const screen_char_t *p = line.line;
    int len = line.length;
    for (int i = len - 1; i >= 0; i--) {
        // TODO: When I add support for URLs to tmux, don't pass 0 here - pass the URL code instead.
        if (p[i].code == ' ' && ScreenCharHasDefaultAttributesAndColors(p[i], 0)) {
            len--;
        } else {
            break;
        }
    }
    line.length = len;
}

- (void)mutSetAltScreen:(NSArray *)lines {
    self.mutableLineBuffer.mayHaveDoubleWidthCharacter = YES;
    if (!_state.altGrid) {
        _mutableState.altGrid = [[self.mutablePrimaryGrid copy] autorelease];
    }

    // Initialize alternate screen to be empty
    [self.mutableAltGrid setCharsFrom:VT100GridCoordMake(0, 0)
                                   to:VT100GridCoordMake(_state.altGrid.size.width - 1, _state.altGrid.size.height - 1)
                               toChar:[_state.altGrid defaultChar]
        externalAttributes:nil];
    // Copy the lines back over it
    int o = 0;
    for (int i = 0; o < _state.altGrid.size.height && i < MIN(lines.count, _state.altGrid.size.height); i++) {
        NSData *chars = [lines objectAtIndex:i];
        screen_char_t *line = (screen_char_t *) [chars bytes];
        int length = [chars length] / sizeof(screen_char_t);

        do {
            // Add up to _state.altGrid.size.width characters at a time until they're all used.
            screen_char_t *dest = [self.mutableAltGrid screenCharsAtLineNumber:o];
            memcpy(dest, line, MIN(_state.altGrid.size.width, length) * sizeof(screen_char_t));
            const BOOL isPartial = (length > _state.altGrid.size.width);
            dest[_state.altGrid.size.width] = dest[_state.altGrid.size.width - 1];  // TODO: This is probably wrong?
            dest[_state.altGrid.size.width].code = (isPartial ? EOL_SOFT : EOL_HARD);
            length -= _state.altGrid.size.width;
            line += _state.altGrid.size.width;
            o++;
        } while (o < _state.altGrid.size.height && length > 0);
    }
}

- (int)mutNumberOfLinesDroppedWhenEncodingContentsIncludingGrid:(BOOL)includeGrid
                                                        encoder:(id<iTermEncoderAdapter>)encoder
                                                 intervalOffset:(long long *)intervalOffsetPtr {
    // We want 10k lines of history at 80 cols, and fewer for small widths, to keep the size
    // reasonable.
    const int maxLines80 = [iTermAdvancedSettingsModel maxHistoryLinesToRestore];
    const int effectiveWidth = _mutableState.width ?: 80;
    const int maxArea = maxLines80 * (includeGrid ? 80 : effectiveWidth);
    const int maxLines = MAX(1000, maxArea / effectiveWidth);

    // Make a copy of the last blocks of the line buffer; enough to contain at least |maxLines|.
    LineBuffer *temp = [[_mutableState.linebuffer copyWithMinimumLines:maxLines
                                                               atWidth:effectiveWidth] autorelease];

    // Offset for intervals so 0 is the first char in the provided contents.
    int linesDroppedForBrevity = ([_mutableState.linebuffer numLinesWithWidth:effectiveWidth] -
                                  [temp numLinesWithWidth:effectiveWidth]);
    long long intervalOffset =
        -(linesDroppedForBrevity + _mutableState.cumulativeScrollbackOverflow) * (_mutableState.width + 1);

    if (includeGrid) {
        int numLines;
        if ([iTermAdvancedSettingsModel runJobsInServers]) {
            numLines = _state.currentGrid.size.height;
        } else {
            numLines = [_state.currentGrid numberOfLinesUsed];
        }
        [_mutableState.currentGrid appendLines:numLines toLineBuffer:temp];
    }

    [temp encode:encoder maxLines:maxLines80];
    *intervalOffsetPtr = intervalOffset;
    return linesDroppedForBrevity;
}

#pragma mark - Terminal Fundamentals

- (void)mutCrlf {
    [_mutableState appendCarriageReturnLineFeed];
}

- (void)mutLinefeed {
    [_mutableState appendLineFeed];
}

- (void)setCursorX:(int)x Y:(int)y {
    DLog(@"Move cursor to %d,%d", x, y);
    _mutableState.currentGrid.cursor = VT100GridCoordMake(x, y);
}

- (void)mutRemoveAllTabStops {
    [_mutableState.tabStops removeAllObjects];
}

#pragma mark - DVR

- (void)mutSetFromFrame:(screen_char_t*)s
                    len:(int)len
               metadata:(NSArray<NSArray *> *)metadataArrays
                   info:(DVRFrameInfo)info {
    assert(len == (info.width + 1) * info.height * sizeof(screen_char_t));
    NSMutableData *storage = [NSMutableData dataWithLength:sizeof(iTermMetadata) * info.height];
    iTermMetadata *md = (iTermMetadata *)storage.mutableBytes;
    [metadataArrays enumerateObjectsUsingBlock:^(NSArray * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if (idx >= info.height) {
            *stop = YES;
            return;
        }
        iTermMetadataInitFromArray(&md[idx], obj);
    }];
    [_mutableState.currentGrid setContentsFromDVRFrame:s metadataArray:md info:info];
    for (int i = 0; i < info.height; i++) {
        iTermMetadataRelease(md[i]);
    }
    [self resetScrollbackOverflow];
    _mutableState.savedFindContextAbsPos = 0;
    [delegate_ screenRemoveSelection];
    [delegate_ screenNeedsRedraw];
    [_mutableState.currentGrid markAllCharsDirty:YES];
}

#pragma mark - Find on Page

- (void)mutSaveFindContextAbsPos {
    int linesPushed;
    linesPushed = [_mutableState.currentGrid appendLines:[_state.currentGrid numberOfLinesUsed]
                                            toLineBuffer:_mutableState.linebuffer];

    [self mutSaveFindContextPosition];
    [self mutPopScrollbackLines:linesPushed];
}

- (void)mutRestorePreferredCursorPositionIfPossible {
    [_mutableState.currentGrid restorePreferredCursorPositionIfPossible];
}

- (void)mutRestoreSavedPositionToFindContext:(FindContext *)context {
    int linesPushed;
    linesPushed = [_mutableState.currentGrid appendLines:[_mutableState.currentGrid numberOfLinesUsed]
                                            toLineBuffer:_mutableState.linebuffer];

    [_mutableState.linebuffer storeLocationOfAbsPos:_mutableState.savedFindContextAbsPos
                                          inContext:context];

    [self mutPopScrollbackLines:linesPushed];
}

- (void)mutSetFindString:(NSString*)aString
     forwardDirection:(BOOL)direction
                 mode:(iTermFindMode)mode
          startingAtX:(int)x
          startingAtY:(int)y
           withOffset:(int)offset
            inContext:(FindContext*)context
      multipleResults:(BOOL)multipleResults {
    DLog(@"begin self=%@ aString=%@", self, aString);
    LineBuffer *tempLineBuffer = [[_mutableState.linebuffer copy] autorelease];
    [tempLineBuffer seal];

    // Append the screen contents to the scrollback buffer so they are included in the search.
    [_mutableState.currentGrid appendLines:[_state.currentGrid numberOfLinesUsed]
                              toLineBuffer:tempLineBuffer];

    // Get the start position of (x,y)
    LineBufferPosition *startPos;
    startPos = [tempLineBuffer positionForCoordinate:VT100GridCoordMake(x, y)
                                               width:_state.currentGrid.size.width
                                              offset:offset * (direction ? 1 : -1)];
    if (!startPos) {
        // x,y wasn't a real position in the line buffer, probably a null after the end.
        if (direction) {
            DLog(@"Search from first position");
            startPos = [tempLineBuffer firstPosition];
        } else {
            DLog(@"Search from last position");
            startPos = [[tempLineBuffer lastPosition] predecessor];
        }
    } else {
        DLog(@"Search from %@", startPos);
        // Make sure startPos is not at or after the last cell in the line buffer.
        BOOL ok;
        VT100GridCoord startPosCoord = [tempLineBuffer coordinateForPosition:startPos
                                                                       width:_state.currentGrid.size.width
                                                                extendsRight:YES
                                                                          ok:&ok];
        LineBufferPosition *lastValidPosition = [[tempLineBuffer lastPosition] predecessor];
        if (!ok) {
            startPos = lastValidPosition;
        } else {
            VT100GridCoord lastPositionCoord = [tempLineBuffer coordinateForPosition:lastValidPosition
                                                                               width:_state.currentGrid.size.width
                                                                        extendsRight:YES
                                                                                  ok:&ok];
            assert(ok);
            long long s = startPosCoord.y;
            s *= _state.currentGrid.size.width;
            s += startPosCoord.x;

            long long l = lastPositionCoord.y;
            l *= _state.currentGrid.size.width;
            l += lastPositionCoord.x;

            if (s >= l) {
                startPos = lastValidPosition;
            }
        }
    }

    // Set up the options bitmask and call findSubstring.
    FindOptions opts = 0;
    if (!direction) {
        opts |= FindOptBackwards;
    }
    if (multipleResults) {
        opts |= FindMultipleResults;
    }
    [tempLineBuffer prepareToSearchFor:aString startingAt:startPos options:opts mode:mode withContext:context];
    context.hasWrapped = NO;
}

- (void)mutSaveFindContextPosition {
    _mutableState.savedFindContextAbsPos = [_mutableState.linebuffer absPositionOfFindContext:_mutableState.findContext];
}

- (void)mutStoreLastPositionInLineBufferAsFindContextSavedPosition {
    _mutableState.savedFindContextAbsPos = [[_mutableState.linebuffer lastPosition] absolutePosition];
}

- (BOOL)mutContinueFindResultsInContext:(FindContext *)context
                                toArray:(NSMutableArray *)results {
    // Append the screen contents to the scrollback buffer so they are included in the search.
    LineBuffer *temporaryLineBuffer = [[_mutableState.linebuffer copy] autorelease];
    [temporaryLineBuffer seal];

#warning TODO: This is an unusual use of mutation since it is only temporary. But probably Find should happen off-thread anyway.
    [_mutableState.currentGrid appendLines:[_state.currentGrid numberOfLinesUsed]
                              toLineBuffer:temporaryLineBuffer];

    // Search one block.
    LineBufferPosition *stopAt;
    if (context.dir > 0) {
        stopAt = [temporaryLineBuffer lastPosition];
    } else {
        stopAt = [temporaryLineBuffer firstPosition];
    }

    struct timeval begintime;
    gettimeofday(&begintime, NULL);
    BOOL keepSearching = NO;
    int iterations = 0;
    int ms_diff = 0;
    do {
        if (context.status == Searching) {
            [temporaryLineBuffer findSubstring:context stopAt:stopAt];
        }

        // Handle the current state
        switch (context.status) {
            case Matched: {
                // NSLog(@"matched");
                // Found a match in the text.
                NSArray *allPositions = [temporaryLineBuffer convertPositions:context.results
                                                                    withWidth:_state.currentGrid.size.width];
                for (XYRange *xyrange in allPositions) {
                    SearchResult *result = [[[SearchResult alloc] init] autorelease];

                    result.startX = xyrange->xStart;
                    result.endX = xyrange->xEnd;
                    result.absStartY = xyrange->yStart + _mutableState.cumulativeScrollbackOverflow;
                    result.absEndY = xyrange->yEnd + _mutableState.cumulativeScrollbackOverflow;

                    [results addObject:result];

                    if (!(context.options & FindMultipleResults)) {
                        assert([context.results count] == 1);
                        [context reset];
                        keepSearching = NO;
                    } else {
                        keepSearching = YES;
                    }
                }
                [context.results removeAllObjects];
                break;
            }

            case Searching:
                // NSLog(@"searching");
                // No result yet but keep looking
                keepSearching = YES;
                break;

            case NotFound:
                // NSLog(@"not found");
                // Reached stopAt point with no match.
                if (context.hasWrapped) {
                    [context reset];
                    keepSearching = NO;
                } else {
                    // NSLog(@"...wrapping");
                    // wrap around and resume search.
                    FindContext *tempFindContext = [[[FindContext alloc] init] autorelease];
                    [temporaryLineBuffer prepareToSearchFor:_mutableState.findContext.substring
                                                 startingAt:(_mutableState.findContext.dir > 0 ? [temporaryLineBuffer firstPosition] : [[temporaryLineBuffer lastPosition] predecessor])
                                                    options:_mutableState.findContext.options
                                                       mode:_mutableState.findContext.mode
                                                withContext:tempFindContext];
                    [_mutableState.findContext reset];
                    // TODO test this!
                    [context copyFromFindContext:tempFindContext];
                    context.hasWrapped = YES;
                    keepSearching = YES;
                }
                break;

            default:
                assert(false);  // Bogus status
        }

        struct timeval endtime;
        if (keepSearching) {
            gettimeofday(&endtime, NULL);
            ms_diff = (endtime.tv_sec - begintime.tv_sec) * 1000 +
            (endtime.tv_usec - begintime.tv_usec) / 1000;
            context.status = Searching;
        }
        ++iterations;
    } while (keepSearching && ms_diff < context.maxTime * 1000);

    switch (context.status) {
        case Searching: {
            int numDropped = [temporaryLineBuffer numberOfDroppedBlocks];
            double current = context.absBlockNum - numDropped;
            double max = [temporaryLineBuffer largestAbsoluteBlockNumber] - numDropped;
            double p = MAX(0, current / max);
            if (context.dir > 0) {
                context.progress = p;
            } else {
                context.progress = 1.0 - p;
            }
            break;
        }
        case Matched:
        case NotFound:
            context.progress = 1;
            break;
    }
    // NSLog(@"Did %d iterations in %dms. Average time per block was %dms", iterations, ms_diff, ms_diff/iterations);

    return keepSearching;
}

#pragma mark - Color Map

- (void)mutLoadInitialColorTable {
    [_mutableState loadInitialColorTable];
}

- (void)mutSetDimOnlyText:(BOOL)dimOnlyText {
    _mutableState.dimOnlyText = dimOnlyText;
}

- (void)mutSetDarkMode:(BOOL)darkMode {
    _mutableState.darkMode = darkMode;
}

- (void)mutSetUseSeparateColorsForLightAndDarkMode:(BOOL)value {
    _mutableState.useSeparateColorsForLightAndDarkMode = value;
}

- (void)mutSetMinimumContrast:(float)value {
    _mutableState.minimumContrast = value;
}

- (void)mutSetMutingAmount:(double)value {
    _mutableState.mutingAmount = value;
}

- (void)mutSetDimmingAmount:(double)value {
    _mutableState.dimmingAmount = value;
}

#pragma mark - Accessors

- (void)mutSetExited:(BOOL)exited {
    [_mutableState setExited:exited];
}

// WARNING: This is called on PTYTask's thread.
- (void)mutAddTokens:(CVector)vector length:(int)length highPriority:(BOOL)highPriority {
    [_mutableState addTokens:vector length:length highPriority:highPriority];
}

- (void)mutScheduleTokenExecution {
    [_mutableState scheduleTokenExecution];
}

- (void)mutSetShouldExpectPromptMarks:(BOOL)value {
    _mutableState.shouldExpectPromptMarks = value;
}

- (void)mutSetLastPromptLine:(long long)value {
    _mutableState.lastPromptLine = value;
}

- (void)mutSetDelegate:(id<VT100ScreenDelegate>)delegate {
#warning TODO: This is temporary. Mutable state should be the delegate.
    [_mutableState setTokenExecutorDelegate:delegate];
    delegate_ = delegate;
}

- (void)mutSetIntervalTreeObserver:(id<iTermIntervalTreeObserver>)intervalTreeObserver {
    _mutableState.intervalTreeObserver = intervalTreeObserver;
}

- (void)mutSetNormalization:(iTermUnicodeNormalization)value {
    _mutableState.normalization = value;
}

- (void)mutSetShellIntegrationInstalled:(BOOL)shellIntegrationInstalled {
    _mutableState.shellIntegrationInstalled = shellIntegrationInstalled;
}

- (void)mutSetAppendToScrollbackWithStatusBar:(BOOL)value {
    _mutableState.appendToScrollbackWithStatusBar = value;
}

- (void)mutSetTrackCursorLineMovement:(BOOL)trackCursorLineMovement {
    _mutableState.trackCursorLineMovement = trackCursorLineMovement;
}

- (void)mutSetSaveToScrollbackInAlternateScreen:(BOOL)value {
    _mutableState.saveToScrollbackInAlternateScreen = value;
}

- (void)mutInvalidateCommandStartCoord {
    [self mutSetCommandStartCoord:VT100GridAbsCoordMake(-1, -1)];
}

- (void)mutSetCommandStartCoord:(VT100GridAbsCoord)coord {
    [_mutableState setCoordinateOfCommandStart:coord];
}

- (void)mutResetScrollbackOverflow {
    [_mutableState resetScrollbackOverflow];
}

- (void)mutSetUnlimitedScrollback:(BOOL)newValue {
    _mutableState.unlimitedScrollback = newValue;
}

// Gets a line on the screen (0 = top of screen)
- (screen_char_t *)mutGetLineAtScreenIndex:(int)theIndex {
    return [_mutableState.currentGrid screenCharsAtLineNumber:theIndex];
}

#pragma mark - Dirty

- (void)mutResetAllDirty {
    _mutableState.currentGrid.allDirty = NO;
}

- (void)mutSetLineDirtyAtY:(int)y {
    if (y >= 0) {
        [_mutableState.currentGrid markCharsDirty:YES
                                       inRectFrom:VT100GridCoordMake(0, y)
                                               to:VT100GridCoordMake(_mutableState.width - 1, y)];
    }
}

- (void)mutSetCharDirtyAtCursorX:(int)x Y:(int)y {
    if (y < 0) {
        DLog(@"Warning: cannot set character dirty at y=%d", y);
        return;
    }
    int xToMark = x;
    int yToMark = y;
    if (xToMark == _state.currentGrid.size.width && yToMark < _state.currentGrid.size.height - 1) {
        xToMark = 0;
        yToMark++;
    }
    if (xToMark < _state.currentGrid.size.width && yToMark < _state.currentGrid.size.height) {
        [_mutableState.currentGrid markCharDirty:YES
                                              at:VT100GridCoordMake(xToMark, yToMark)
                                 updateTimestamp:NO];
        if (xToMark < _state.currentGrid.size.width - 1) {
            // Just in case the cursor was over a double width character
            [_mutableState.currentGrid markCharDirty:YES
                                                  at:VT100GridCoordMake(xToMark + 1, yToMark)
                                     updateTimestamp:NO];
        }
    }
}

- (void)mutResetDirty {
    [_mutableState.currentGrid markAllCharsDirty:NO];
}

- (void)mutRedrawGrid {
    [_mutableState.currentGrid setAllDirty:YES];
    // Force the screen to redraw right away. Some users reported lag and this seems to fix it.
    // I think the update timer was hitting a worst case scenario which made the lag visible.
    // See issue 3537.
    [delegate_ screenUpdateDisplay:YES];
}

#pragma mark - URLs

- (void)mutLinkTextInRange:(NSRange)range
basedAtAbsoluteLineNumber:(long long)absoluteLineNumber
                  URLCode:(unsigned int)code {
    [_mutableState linkTextInRange:range basedAtAbsoluteLineNumber:absoluteLineNumber URLCode:code];
}

#pragma mark - Highlighting

- (void)mutHighlightRun:(VT100GridRun)run
    withForegroundColor:(NSColor *)fgColor
        backgroundColor:(NSColor *)bgColor {
    [_mutableState highlightRun:run withForegroundColor:fgColor backgroundColor:bgColor];
}

- (void)mutHighlightTextInRange:(NSRange)range
      basedAtAbsoluteLineNumber:(long long)absoluteLineNumber
                         colors:(NSDictionary *)colors {
    [_mutableState highlightTextInRange:range
              basedAtAbsoluteLineNumber:absoluteLineNumber
                                 colors:colors];
}


#pragma mark - Scrollback

// sets scrollback lines.
- (void)mutSetMaxScrollbackLines:(unsigned int)lines {
    _mutableState.maxScrollbackLines = lines;
    [self.mutableLineBuffer setMaxLines: lines];
    if (!_state.unlimitedScrollback) {
        [_mutableState incrementOverflowBy:[self.mutableLineBuffer dropExcessLinesWithWidth:_state.currentGrid.size.width]];
    }
    [delegate_ screenDidChangeNumberOfScrollbackLines];
}

- (void)mutPopScrollbackLines:(int)linesPushed {
    // Undo the appending of the screen to scrollback
    int i;
    screen_char_t* dummy = iTermCalloc(_state.currentGrid.size.width, sizeof(screen_char_t));
    for (i = 0; i < linesPushed; ++i) {
        int cont;
        BOOL isOk __attribute__((unused)) =
        [self.mutableLineBuffer popAndCopyLastLineInto:dummy
                                                 width:_state.currentGrid.size.width
                                     includesEndOfLine:&cont
                                              metadata:NULL
                                          continuation:NULL];
        ITAssertWithMessage(isOk, @"Pop shouldn't fail");
    }
    free(dummy);
}

#pragma mark - Miscellaneous State

- (BOOL)mutGetAndResetHasScrolled {
    const BOOL result = _state.currentGrid.haveScrolled;
    _mutableState.currentGrid.haveScrolled = NO;
    return result;
}

#pragma mark - Synchronized Drawing

- (iTermTemporaryDoubleBufferedGridController *)mutableTemporaryDoubleBuffer {
    if ([delegate_ screenShouldReduceFlicker] || _mutableState.temporaryDoubleBuffer.explicit) {
        return _mutableState.temporaryDoubleBuffer;
    } else {
        return nil;
    }
}

- (PTYTextViewSynchronousUpdateState *)mutSetUseSavedGridIfAvailable:(BOOL)useSavedGrid {
    if (useSavedGrid && !_state.realCurrentGrid && self.mutableTemporaryDoubleBuffer.savedState) {
        _mutableState.realCurrentGrid = _state.currentGrid;
        _mutableState.currentGrid = self.mutableTemporaryDoubleBuffer.savedState.grid;
        self.mutableTemporaryDoubleBuffer.drewSavedGrid = YES;
        return self.mutableTemporaryDoubleBuffer.savedState;
    } else if (!useSavedGrid && _state.realCurrentGrid) {
        _mutableState.currentGrid = _state.realCurrentGrid;
        _mutableState.realCurrentGrid = nil;
    }
    return nil;
}

#pragma mark - Injection

- (void)mutInjectData:(NSData *)data {
    [_mutableState injectData:data];
}

#pragma mark - Triggers

- (void)mutForceCheckTriggers {
    [_mutableState forceCheckTriggers];
}

- (void)mutPerformPeriodicTriggerCheck {
    [_mutableState performPeriodicTriggerCheck];
}

@end

@implementation VT100Screen (Testing)

- (void)setMayHaveDoubleWidthCharacters:(BOOL)value {
    self.mutableLineBuffer.mayHaveDoubleWidthCharacter = value;
}

- (void)destructivelySetScreenWidth:(int)width height:(int)height {
    width = MAX(width, kVT100ScreenMinColumns);
    height = MAX(height, kVT100ScreenMinRows);

    self.mutablePrimaryGrid.size = VT100GridSizeMake(width, height);
    self.mutableAltGrid.size = VT100GridSizeMake(width, height);
    self.mutablePrimaryGrid.cursor = VT100GridCoordMake(0, 0);
    self.mutableAltGrid.cursor = VT100GridCoordMake(0, 0);
    [self.mutablePrimaryGrid resetScrollRegions];
    [self.mutableAltGrid resetScrollRegions];
    [_mutableState.terminal resetSavedCursorPositions];

    _mutableState.findContext.substring = nil;

    _mutableState.scrollbackOverflow = 0;
    [delegate_ screenRemoveSelection];

    [self.mutablePrimaryGrid markAllCharsDirty:YES];
    [self.mutableAltGrid markAllCharsDirty:YES];
}

@end
