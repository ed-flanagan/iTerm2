//
//  VT100ScreenMutableState+Resizing.h
//  iTerm2SharedARC
//
//  Created by George Nachman on 1/10/22.
//

#import "VT100ScreenMutableState.h"

@class iTermSelection;

NS_ASSUME_NONNULL_BEGIN

@interface VT100ScreenMutableState (Resizing)

#pragma mark - Private APIs (remove this once migration is done)

- (VT100GridSize)safeSizeForSize:(VT100GridSize)proposedSize;
- (BOOL)shouldSetSizeTo:(VT100GridSize)size;
- (void)sanityCheckIntervalsFrom:(VT100GridSize)oldSize note:(NSString *)note;
- (void)willSetSizeWithSelection:(iTermSelection *)selection;
- (int)appendScreen:(VT100Grid *)grid
       toScrollback:(LineBuffer *)lineBufferToUse
     withUsedHeight:(int)usedHeight
          newHeight:(int)newHeight;
- (VT100GridRun)runByTrimmingNullsFromRun:(VT100GridRun)run;
- (BOOL)trimSelectionFromStart:(VT100GridCoord)start
                           end:(VT100GridCoord)end
                      toStartX:(VT100GridCoord *)startPtr
                        toEndX:(VT100GridCoord *)endPtr;
- (LineBufferPositionRange *)positionRangeForCoordRange:(VT100GridCoordRange)range
                                           inLineBuffer:(LineBuffer *)lineBuffer
                                          tolerateEmpty:(BOOL)tolerateEmpty;
- (NSArray *)subSelectionTuplesWithUsedHeight:(int)usedHeight
                                    newHeight:(int)newHeight
                                    selection:(iTermSelection *)selection;
- (BOOL)intervalTreeObjectMayBeEmpty:(id<IntervalTreeObject>)note;
- (NSArray *)intervalTreeObjectsWithUsedHeight:(int)usedHeight
                                     newHeight:(int)newHeight
                                          grid:(VT100Grid *)grid
                                    lineBuffer:(LineBuffer *)realLineBuffer;
- (LineBuffer *)prepareToResizeInAlternateScreenMode:(NSArray **)altScreenSubSelectionTuplesPtr
                                 intervalTreeObjects:(NSArray **)altScreenNotesPtr
                                        hasSelection:(BOOL)couldHaveSelection
                                           selection:(iTermSelection *)selection
                                          lineBuffer:(LineBuffer *)realLineBuffer
                                          usedHeight:(int)usedHeight
                                             newSize:(VT100GridSize)newSize;
- (BOOL)convertRange:(VT100GridCoordRange)range
             toWidth:(int)newWidth
                  to:(VT100GridCoordRange *)resultPtr
        inLineBuffer:(LineBuffer *)lineBuffer
       tolerateEmpty:(BOOL)tolerateEmpty;
- (NSArray *)subSelectionsWithConvertedRangesFromSelection:(iTermSelection *)selection
                                                  newWidth:(int)newWidth;
- (IntervalTree *)replacementIntervalTreeForNewWidth:(int)newWidth;
- (void)fixUpPrimaryGridIntervalTreeForNewSize:(VT100GridSize)newSize
                           wasShowingAltScreen:(BOOL)wasShowingAltScreen;

- (void)restorePrimaryGridWithLineBuffer:(LineBuffer *)realLineBuffer
                                 oldSize:(VT100GridSize)oldSize
                                 newSize:(VT100GridSize)newSize;
- (BOOL)computeRangeFromOriginalLimit:(LineBufferPosition *)originalLimit
                        limitPosition:(LineBufferPosition *)limit
                        startPosition:(LineBufferPosition *)startPos
                          endPosition:(LineBufferPosition *)endPos
                             newWidth:(int)newWidth
                           lineBuffer:(LineBuffer *)lineBuffer  // NOTE: May be append-only
                                range:(VT100GridCoordRange *)resultRangePtr
                         linesMovedUp:(int)linesMovedUp;
- (void)addObjectsToIntervalTreeFromTuples:(NSArray *)altScreenNotes
                                   newSize:(VT100GridSize)newSize
                      originalLastPosition:(LineBufferPosition *)originalLastPos
                           newLastPosition:(LineBufferPosition *)newLastPos
                              linesMovedUp:(int)linesMovedUp
                      appendOnlyLineBuffer:(LineBuffer *)appendOnlyLineBuffer;

- (NSArray *)subSelectionsForNewSize:(VT100GridSize)newSize
                          lineBuffer:(LineBuffer *)realLineBuffer
                                grid:(VT100Grid *)copyOfAltGrid
                          usedHeight:(int)usedHeight
                  subSelectionTuples:(NSArray *)altScreenSubSelectionTuples
                originalLastPosition:(LineBufferPosition *)originalLastPos
                     newLastPosition:(LineBufferPosition *)newLastPos
                        linesMovedUp:(int)linesMovedUp
                appendOnlyLineBuffer:(LineBuffer *)appendOnlyLineBuffer;
- (NSArray *)subSelectionsAfterRestoringPrimaryGridWithCopyOfAltGrid:(VT100Grid *)copyOfAltGrid
                                                        linesMovedUp:(int)linesMovedUp
                                                        toLineBuffer:(LineBuffer *)realLineBuffer
                                                  subSelectionTuples:(NSArray *)altScreenSubSelectionTuples
                                                originalLastPosition:(LineBufferPosition *)originalLastPos
                                                             oldSize:(VT100GridSize)oldSize
                                                             newSize:(VT100GridSize)newSize
                                                          usedHeight:(int)usedHeight
                                                 intervalTreeObjects:(NSArray *)altScreenNotes;
- (void)updateAlternateScreenIntervalTreeForNewSize:(VT100GridSize)newSize;
- (void)didResizeToSize:(VT100GridSize)newSize
              selection:(iTermSelection *)selection
     couldHaveSelection:(BOOL)couldHaveSelection
          subSelections:(NSArray *)newSubSelections
                 newTop:(int)newTop
               delegate:(id<VT100ScreenDelegate>)delegate;
- (void)reallySetSize:(VT100GridSize)newSize
         visibleLines:(VT100GridRange)previouslyVisibleLineRange
            selection:(iTermSelection *)selection
             delegate:(id<VT100ScreenDelegate>)delegate
              hasView:(BOOL)hasView;

@end

NS_ASSUME_NONNULL_END