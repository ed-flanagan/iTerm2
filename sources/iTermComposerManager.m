//
//  iTermComposerManager.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 3/31/20.
//

#import "iTermComposerManager.h"

#import "iTermAdvancedSettingsModel.h"
#import "iTermMinimalComposerViewController.h"
#import "iTermStatusBarComposerComponent.h"
#import "iTermStatusBarViewController.h"
#import "NSObject+iTerm.h"
#import "NSView+iTerm.h"

@interface iTermComposerManager()<
    iTermMinimalComposerViewControllerDelegate,
    iTermStatusBarComposerComponentDelegate>
@end

@implementation iTermComposerManager {
    iTermStatusBarComposerComponent *_component;
    iTermStatusBarViewController *_statusBarViewController;
    iTermMinimalComposerViewController *_minimalViewController;
    NSString *_saved;
    BOOL _preserveSaved;
    BOOL _dismissCanceled;
}

- (void)setCommand:(NSString *)command {
    _saved = [command copy];
}

- (void)showOrAppendToDropdownWithString:(NSString *)string {
    if (!_dropDownComposerViewIsVisible) {
        _saved = [string copy];
        [self showMinimalComposerInView:[self.delegate composerManagerContainerView:self]];
    } else {
        _minimalViewController.stringValue = [NSString stringWithFormat:@"%@\n%@",
                                              _minimalViewController.stringValue, string];
    }
    [_minimalViewController makeFirstResponder];
}

- (BOOL)dropDownComposerIsFirstResponder {
    return _dropDownComposerViewIsVisible && _minimalViewController.composerIsFirstResponder;
}

- (void)makeDropDownComposerFirstResponder {
    [_minimalViewController makeFirstResponder];
}

- (iTermStatusBarComposerComponent *)currentComponent {
    iTermStatusBarViewController *statusBarViewController = [self.delegate composerManagerStatusBarViewController:self];
    if (statusBarViewController) {
        iTermStatusBarComposerComponent *component = [statusBarViewController visibleComponentWithIdentifier:[iTermStatusBarComposerComponent statusBarComponentIdentifier]];
        return component;
    }
    return nil;
}

- (void)setStringValue:(NSString *)command {
    _saved = [command copy];
    if (_dropDownComposerViewIsVisible) {
        _minimalViewController.stringValue = command;
    } else {
        iTermStatusBarComposerComponent *component = [self currentComponent];
        component.stringValue = command;
    }
}

- (void)showWithCommand:(NSString *)command {
    [self setStringValue:command];
    if (_dropDownComposerViewIsVisible) {
        // Put into already-visible drop-down view.
        [_minimalViewController makeFirstResponder];
        return;
    }
    iTermStatusBarComposerComponent *component = [self currentComponent];
    if (component) {
        // Put into already-visible status bar component.
        [component makeFirstResponder];
        [component deselect];
        return;
    }
    // Nothing is currently visible. Reveal as usual.
    [self reveal];
}

- (void)reveal {
    iTermStatusBarViewController *statusBarViewController = [self.delegate composerManagerStatusBarViewController:self];
    if (statusBarViewController && [self shouldRevealStatusBarComposerInViewController:statusBarViewController]) {
        if (_dropDownComposerViewIsVisible) {
            _saved = _minimalViewController.stringValue;
            [self dismissMinimalViewAnimated:YES];
        } else {
            [self showComposerInStatusBar:statusBarViewController];
        }
    } else {
        [self showMinimalComposerInView:[self.delegate composerManagerContainerView:self]];
    }
}

- (BOOL)shouldRevealStatusBarComposerInViewController:(iTermStatusBarViewController *)statusBarViewController {
    if ([iTermAdvancedSettingsModel alwaysUseStatusBarComposer]) {
        return YES;
    }
    return [statusBarViewController visibleComponentWithIdentifier:[iTermStatusBarComposerComponent statusBarComponentIdentifier]] != nil;
}

- (void)revealMinimal {
    iTermStatusBarViewController *statusBarViewController = [self.delegate composerManagerStatusBarViewController:self];
    if (statusBarViewController) {
        iTermStatusBarComposerComponent *component = [statusBarViewController visibleComponentWithIdentifier:[iTermStatusBarComposerComponent statusBarComponentIdentifier]];
        if (component) {
            _saved = [component.stringValue copy];
        }
    }
    [self showMinimalComposerInView:[self.delegate composerManagerContainerView:self]];
}

- (void)showComposerInStatusBar:(iTermStatusBarViewController *)statusBarViewController {
    iTermStatusBarComposerComponent *component;
    component = [statusBarViewController visibleComponentWithIdentifier:[iTermStatusBarComposerComponent statusBarComponentIdentifier]];
    if (component) {
        [component makeFirstResponder];
        return;
    }
    component = [iTermStatusBarComposerComponent castFrom:_statusBarViewController.temporaryRightComponent];
    if (component && component == _component) {
        [component makeFirstResponder];
        return;
    }
    NSDictionary *knobs = @{ iTermStatusBarPriorityKey: @(INFINITY) };
    NSDictionary *configuration = @{ iTermStatusBarComponentConfigurationKeyKnobValues: knobs};
    iTermVariableScope *scope = [self.delegate composerManagerScope:self];
    component = [[iTermStatusBarComposerComponent alloc] initWithConfiguration:configuration
                                                                         scope:scope];
    _statusBarViewController = statusBarViewController;
    _statusBarViewController.temporaryRightComponent = component;
    _component = component;
    _component.stringValue = _saved ?: @"";
    component.composerDelegate = self;
    [component makeFirstResponder];
}

- (BOOL)minimalComposerRevealed {
    return _minimalViewController != nil;
}

- (CGFloat)sideMargin {
    return self.isAutoComposer ? 0 : 20;
}

- (void)showMinimalComposerInView:(NSView *)superview {
    if (_minimalViewController) {
        _saved = _minimalViewController.stringValue;
        [self dismissMinimalViewAnimated:YES];
        return;
    }
    _minimalViewController = [[iTermMinimalComposerViewController alloc] init];
    _minimalViewController.delegate = self;
    _minimalViewController.isAutoComposer = self.isAutoComposer;
    _minimalViewController.view.frame = NSMakeRect(self.sideMargin,
                                                   superview.frame.size.height - _minimalViewController.view.frame.size.height,
                                                   _minimalViewController.view.frame.size.width,
                                                   _minimalViewController.view.frame.size.height);
    _minimalViewController.view.appearance = [self.delegate composerManagerAppearance:self];
    [_minimalViewController setHost:[self.delegate composerManagerRemoteHost:self]
                   workingDirectory:[self.delegate composerManagerWorkingDirectory:self]
                              scope:[self.delegate composerManagerScope:self]
                     tmuxController:[self.delegate composerManagerTmuxController:self]];
    [_minimalViewController setFont:[self.delegate composerManagerFont:self]];
    [_minimalViewController setTextColor:[self.delegate composerManagerTextColor:self]
                             cursorColor:[self.delegate composerManagerCursorColor:self]];
    [superview addSubview:_minimalViewController.view];
    if (_saved.length) {
        _minimalViewController.stringValue = _saved ?: @"";
        _saved = nil;
    }
    [_minimalViewController updateFrame];
    [_minimalViewController makeFirstResponder];
    _minimalViewController.view.hidden = _temporarilyHidden;
    _dropDownComposerViewIsVisible = YES;
    _dismissCanceled = YES;
    [_delegate composerManagerDidDisplayMinimalView:self];
}

- (BOOL)dismiss {
    return [self dismissAnimated:YES];
}

- (BOOL)dismissAnimated:(BOOL)animated {
    self.isAutoComposer = NO;

    if (!_dropDownComposerViewIsVisible) {
        return NO;
    }
    _saved = _minimalViewController.stringValue;
    [self dismissMinimalViewAnimated:animated];
    return YES;
}

- (void)layout {
    [_minimalViewController updateFrame];
}

- (BOOL)isEmpty {
    if (_minimalViewController) {
        return _minimalViewController.stringValue.length == 0;
    }
    return _component.stringValue.length == 0;
}

- (NSString *)contents {
    if (_minimalViewController) {
        return _minimalViewController.stringValue;
    }
    return _component.stringValue;
}

#pragma mark - iTermStatusBarComposerComponentDelegate

- (void)statusBarComposerComponentDidEndEditing:(iTermStatusBarComposerComponent *)component {
    if (_statusBarViewController.temporaryRightComponent == _component &&
        component == _component) {
        _saved = _component.stringValue;
        _statusBarViewController.temporaryRightComponent = nil;
        _component = nil;
        [self.delegate composerManagerDidRemoveTemporaryStatusBarComponent:self];
    }
}

#pragma mark - iTermMinimalComposerViewControllerDelegate

- (void)minimalComposer:(iTermMinimalComposerViewController *)composer
         enqueueCommand:(NSString *)command
                dismiss:(BOOL)dismiss {
    NSString *string = composer.stringValue;
    if (dismiss) {
        [self dismissMinimalViewAnimated:YES];
    }
    if (command.length == 0) {
        _saved = string;
        return;
    }
    _saved = nil;
    [self.delegate composerManager:self enqueueCommand:[command stringByAppendingString:@"\n"]];
}

- (void)minimalComposer:(nonnull iTermMinimalComposerViewController *)composer
            sendCommand:(nonnull NSString *)command
                dismiss:(BOOL)dismiss {
    NSString *string = composer.stringValue;
    const BOOL reset = dismiss && self.isAutoComposer;
    if (dismiss && !reset) {
        [self dismissMinimalViewAnimated:NO];
    }
    if (command.length == 0 && !self.isAutoComposer) {
        _saved = string;
        return;
    }
    _saved = nil;
    [self.delegate composerManager:self sendCommand:[command stringByAppendingString:@"\n"]];
    if (reset) {
        [self setStringValue:@""];
    }
}

- (void)minimalComposer:(iTermMinimalComposerViewController *)composer
    sendToAdvancedPaste:(NSString *)content {
    [self dismissMinimalViewAnimated:YES];
    _saved = nil;
    [self.delegate composerManager:self
               sendToAdvancedPaste:[content stringByAppendingString:@"\n"]];
}

- (void)minimalComposer:(iTermMinimalComposerViewController *)composer
            sendControl:(NSString *)control {
    [self.delegate composerManager:self sendControl:control];
}

- (NSRect)minimalComposer:(iTermMinimalComposerViewController *)composer frameForHeight:(CGFloat)desiredHeight {
    return [self.delegate composerManager:self
                    frameForDesiredHeight:desiredHeight
                            previousFrame:composer.view.frame];
}

- (CGFloat)minimalComposerMaximumHeight:(iTermMinimalComposerViewController *)composer {
    return NSHeight(composer.view.superview.bounds) - 8;
}

- (void)minimalComposer:(iTermMinimalComposerViewController *)composer
       frameDidChangeTo:(NSRect)newFrame {
    [self.delegate composerManager:self minimalFrameDidChangeTo:newFrame];
}

- (CGFloat)minimalComposerLineHeight:(iTermMinimalComposerViewController *)composer {
    return [self.delegate composerManagerLineHeight:self];
}

- (void)minimalComposerOpenHistory:(iTermMinimalComposerViewController *)composer {
    [self.delegate composerManagerOpenHistory:self];
}

- (BOOL)minimalComposer:(iTermMinimalComposerViewController *)composer wantsKeyEquivalent:(NSEvent *)event {
    return [self.delegate composerManager:self wantsKeyEquivalent:event];
}

- (void)minimalComposer:(iTermMinimalComposerViewController *)composer performFindPanelAction:(id)sender {
    return [self.delegate composerManager:self performFindPanelAction:sender];
}

- (void)minimalComposer:(iTermMinimalComposerViewController *)composer desiredHeightDidChange:(CGFloat)desiredHeight {
    [self.delegate composerManager:self desiredHeightDidChange:desiredHeight];
}

- (void)dismissMinimalViewAnimated:(BOOL)animated {
    iTermMinimalComposerViewController *vc = _minimalViewController;
    __weak __typeof(self) weakSelf = self;
    _dismissCanceled = NO;
    if (animated) {
        [NSView animateWithDuration:0.125
                         animations:^{
            vc.view.animator.alphaValue = 0;
        }
                         completion:^(BOOL finished) {
            [weakSelf finishDismissingMinimalView:vc];
        }];
        [self prepareToDismissMinimalView];
        // You get into infinite recursion if you do ths inside resignFirstResponder.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate composerManagerWillDismissMinimalView:self];
        });
    } else {
        vc.view.alphaValue = 0;
        [self.delegate composerManagerWillDismissMinimalView:self];
        [self prepareToDismissMinimalView];
        [self finishDismissingMinimalView:vc];
        return;
    }
}

- (void)prepareToDismissMinimalView {
    _minimalViewController = nil;
    _dropDownComposerViewIsVisible = NO;
}

- (void)finishDismissingMinimalView:(iTermMinimalComposerViewController *)vc {
    if (_dismissCanceled) {
        DLog(@"Dismiss canceled");
        return;
    }
    [vc.view removeFromSuperview];
    [self.delegate composerManagerDidDismissMinimalView:self];
}

- (void)updateFrame {
    [_minimalViewController updateFrame];
}

- (CGFloat)desiredHeight {
    return _minimalViewController.desiredHeight;
}

- (NSRect)dropDownFrame {
    return _minimalViewController.view.frame;
}

- (void)setIsSeparatorVisible:(BOOL)isSeparatorVisible {
    _minimalViewController.isSeparatorVisible = isSeparatorVisible;
}

- (BOOL)isSeparatorVisible {
    return _minimalViewController.isSeparatorVisible;
}

- (void)setSeparatorColor:(NSColor *)separatorColor {
    _minimalViewController.separatorColor = separatorColor;
}

- (NSColor *)separatorColor {
    return _minimalViewController.separatorColor;
}

- (void)updateFont {
    [_minimalViewController setFont:[self.delegate composerManagerFont:self]];
    [_minimalViewController setTextColor:[self.delegate composerManagerTextColor:self]
                             cursorColor:[self.delegate composerManagerCursorColor:self]];
    [self updateFrame];
}

- (void)setPrefix:(NSMutableAttributedString *)prefix userData:(nonnull id)userData {
    [_minimalViewController setPrefix:prefix];
    _prefixUserData = userData;
}

- (void)insertText:(NSString *)string {
    if (_minimalViewController) {
        [_minimalViewController insertText:string];
    } else {
        [_component insertText:string];
    }
}

- (void)setTemporarilyHidden:(BOOL)temporarilyHidden {
    _temporarilyHidden = temporarilyHidden;
    _minimalViewController.view.hidden = temporarilyHidden;
}

- (NSRect)cursorFrameInScreenCoordinates {
    if (_minimalViewController) {
        return _minimalViewController.cursorFrameInScreenCoordinates;
    }
    return _component.cursorFrameInScreenCoordinates;
}
@end
