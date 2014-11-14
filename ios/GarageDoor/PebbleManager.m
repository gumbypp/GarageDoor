//
//  PebbleManager.m
//  GarageDoor
//
//  Created by Dale Low on 7/17/14.
//  Copyright (c) 2014 gumbypp consulting. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
// associated documentation files (the "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
// - The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
// LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#import "PebbleManager.h"

@interface PebbleManager ()

@property (nonatomic, strong) PBWatch *targetWatch;

@end

@implementation PebbleManager

+ (PebbleManager *)sharedInstance
{
    static dispatch_once_t pred;
    static PebbleManager *shared = nil;
    
    dispatch_once(&pred, ^{
        shared = [[PebbleManager alloc] init];
    });
    
    return shared;
}

- (id)init
{
    self = [super init];
    if (self) {
        // We'd like to get called when Pebbles connect and disconnect, so become the delegate of PBPebbleCentral:
        [[PBPebbleCentral defaultCentral] setDelegate:self];
        
        // Initialize with the last connected watch:
        [self setTargetWatch:[[PBPebbleCentral defaultCentral] lastConnectedWatch]];
    }
    return self;
}

#pragma mark - Internal methods

- (void)sendMessageToWatch:(NSDictionary *)message
{
    [_targetWatch appMessagesPushUpdate:message onSent:^(PBWatch *watch, NSDictionary *update, NSError *error) {
        if (error) {
            NSLogWarn(@"failed to push message to pebble: %@", [error localizedDescription]);
        } else {
            NSLogDebug(@"pushed to pebble: %@", message);
        }
    }];
}

- (void)setTargetWatch:(PBWatch*)watch
{
    _targetWatch = watch;
    
    // NOTE:
    // For demonstration purposes, we start communicating with the watch immediately upon connection,
    // because we are calling -appMessagesGetIsSupported: here, which implicitely opens the communication session.
    // Real world apps should communicate only if the user is actively using the app, because there
    // is one communication session that is shared between all 3rd party iOS apps.
    
    // Test if the Pebble's firmware supports AppMessages / garage_door app:
    [watch appMessagesGetIsSupported:^(PBWatch *watch, BOOL isAppMessagesSupported) {
        if (isAppMessagesSupported) {
            // from appinfo.json:
            //     "uuid": "e69c7501-4a86-4d86-aafd-dd39b4305c03",
            
            uint8_t bytes[] = {0xe6, 0x9c, 0x75, 0x01, 0x4a, 0x86, 0x4d, 0x86, 0xaa, 0xfd, 0xdd, 0x39, 0xb4, 0x30, 0x5c, 0x03};
            NSData *uuid = [NSData dataWithBytes:bytes length:sizeof(bytes)];
            [[PBPebbleCentral defaultCentral] setAppUUID:uuid];
            
            NSLogDebug(@"pebble (%@) supports AppMessages", [watch name]);
            
            [watch appMessagesAddReceiveUpdateHandler:^BOOL(PBWatch *watch, NSDictionary *update) {
                NSLogDebug(@"update: %@", update);
                
                PebbleCmdType cmd = [update[@(kMessageKeyTxCmd)] intValue];                
                return [self.delegate pebbleManager:self didHandleCmd:cmd];
            }];
        } else {
            NSLogWarn(@"pebble (%@) does NOT support AppMessages - maybe it's just not around?", [watch name]);
        }
    }];
}

#pragma mark - PBPebbleCentralDelegate methods

- (void)pebbleCentral:(PBPebbleCentral*)central watchDidConnect:(PBWatch*)watch isNew:(BOOL)isNew
{
    [self setTargetWatch:watch];
}

- (void)pebbleCentral:(PBPebbleCentral*)central watchDidDisconnect:(PBWatch*)watch
{
//    [[[UIAlertView alloc] initWithTitle:@"Pebble disconnected!" message:[watch name] delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
    if (_targetWatch == watch || [watch isEqual:_targetWatch]) {
        [self setTargetWatch:nil];
    }
}


@end
