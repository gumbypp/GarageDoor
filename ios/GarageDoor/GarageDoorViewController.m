//
//  GarageDoorViewController.m
//  GarageDoor
//
//  Created by Dale Low on 4/28/14.
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

#import "GarageDoorViewController.h"

#import "shared_key.h"
#import "shared_protocol.h"
#import "BLE.h"
#import "MD5/MD5.h"
#import "PebbleManager.h"

typedef enum {
    kRequestStateIdle,
    kRequestStateSending
} RequestState;

union long_hex {
    uint32_t lunsign;
    struct {
        uint8_t b0;
        uint8_t b1;
        uint8_t b2;
        uint8_t b3;
    } lbytes;
};

typedef void (^CompletionHandler)(NSData *responseData, NSError *error);

// transport
#define kErrorDomain                @"GarageDoorViewController"
#define kErrorCodeSendFailed        -1
#define kErrorCodeDisconnect        -2
#define kErrorCodeResponseInvalid   -3
#define kErrorCodeResponseTooShort  -4
#define kErrorCodeSequenceMismatch  -5
#define kErrorCodeAuthFailed        -6
#define kErrorCodeLengthMismatch    -7

///////////////////////////////////////////////////////////////////////////////

@interface Transaction : NSObject

@property (nonatomic, strong) NSData *data;
@property (nonatomic, assign) uint8_t messageSequenceNumber;
@property (nonatomic, copy) CompletionHandler completionHandler;

@end

@implementation Transaction

- (id)initWithData:(NSData *)data messageSequenceNumber:(uint8_t)messageSequenceNumber completionHandler:(CompletionHandler)completionHandler
{
    self = [super init];
    if (self) {
        _data = data;
        _messageSequenceNumber = messageSequenceNumber;
        _completionHandler = completionHandler;
    }
    return self;
}

@end

///////////////////////////////////////////////////////////////////////////////

@interface GarageDoorViewController () <BLEDelegate, PebbleManagerDelegate>

@property (nonatomic, weak) IBOutlet UIView *garageDoorView;
@property (nonatomic, weak) IBOutlet UILabel *unknownDoorStateLabel;
@property (nonatomic, weak) IBOutlet UIButton *btnConnect;
@property (nonatomic, weak) IBOutlet UIButton *btnActivate;
@property (nonatomic, weak) IBOutlet UIActivityIndicatorView *indConnecting;

@property (nonatomic, strong) BLE *ble;
@property (nonatomic, strong) NSTimer *statusCheckTimer;
@property (nonatomic, assign) uint8_t sequenceNumber;
@property (nonatomic, assign) uint8_t activeSequenceNumber;
@property (nonatomic, assign) uint32_t keyPart;
@property (nonatomic, retain) NSMutableArray *transactionQueue;
@property (nonatomic, assign) RequestState requestState;
@property (nonatomic, copy) CompletionHandler completionHandler;

@end

///////////////////////////////////////////////////////////////////////////////

@implementation GarageDoorViewController

- (id)init
{
    self = [super init];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit
{
    _transactionQueue = [[NSMutableArray alloc] init];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.unknownDoorStateLabel.hidden = NO;
    self.btnActivate.enabled = NO;

    self.requestState = kRequestStateIdle;

    self.ble = [[BLE alloc] init];
    [_ble controlSetup];
    _ble.delegate = self;
    
    [PebbleManager sharedInstance].delegate = self;
}

#pragma mark - Internal methods

- (NSData *)bigEndianDataForDword:(uint32_t)value
{
    union long_hex lu;
    uint8_t a[4];
    
    lu.lunsign = value;
    a[0] = lu.lbytes.b3;
    a[1] = lu.lbytes.b2;
    a[2] = lu.lbytes.b1;
    a[3] = lu.lbytes.b0;
    
    return [NSData dataWithBytes:a length:4];
}

- (uint32_t)dwordForBigEndianData:(NSData *)value
{
    union long_hex lu;
    uint8_t *bytes = (uint8_t *)[value bytes];
    
    lu.lbytes.b3 = *bytes++;
    lu.lbytes.b2 = *bytes++;
    lu.lbytes.b1 = *bytes++;
    lu.lbytes.b0 = *bytes++;
    
    return lu.lunsign;
}

- (NSData *)getSignatureForBytes:(uint8_t *)bytes length:(NSUInteger)length key1:(uint32_t)key1 key2:(uint32_t)key2
{
    NSMutableData *data = [[NSMutableData alloc] initWithBytes:bytes length:length];

    [data appendData:[self bigEndianDataForDword:key1]];
    [data appendData:[self bigEndianDataForDword:key2]];
    
    // returns pointer to global data - not thread-safe
    unsigned char *hash = make_hash((unsigned char*)[data bytes], [data length]);

    return [NSData dataWithBytes:hash length:16];
}

- (void)connectOrDisconnect
{
    if (self.ble.activePeripheral) {
        if (self.ble.activePeripheral.state == CBPeripheralStateConnected) {
            [[self.ble CM] cancelPeripheralConnection:[self.ble activePeripheral]];
            return;
        }
    }
    
    if (self.ble.peripherals) {
        self.ble.peripherals = nil;
    }
    
    [self.btnConnect setEnabled:false];
    [self.ble findBLEPeripherals:2];
    
    [NSTimer scheduledTimerWithTimeInterval:(float)2.0 target:self selector:@selector(connectionTimer:) userInfo:nil repeats:NO];
    [self.indConnecting startAnimating];
}

- (void)connectionTimer:(NSTimer *)timer
{
    if (self.ble.peripherals.count > 0) {
        [self.ble connectPeripheral:[self.ble.peripherals objectAtIndex:0]];
    } else {
        [self.indConnecting stopAnimating];
        [self.btnConnect setEnabled:true];
        [self.btnConnect setTitle:@"Connect" forState:UIControlStateNormal];
        [[PebbleManager sharedInstance] sendMessageToWatch:@{ @(kMessageKeyRxLabelBtnSelect): @"Connect",
                                                              @(kMessageKeyRxLabelBtnDown): @"--" }];
    }
}

- (void)queueOrSendMessageWithCommand:(uint8_t)cmd
                              payload:(NSData *)payload
                  withCompletionBlock:(CompletionHandler)completionBlock
{
    uint8_t buf[2];
    buf[0] = cmd;
    buf[1] = ++self.sequenceNumber;
    
    NSMutableData *fullPayload = [[NSMutableData alloc] initWithBytes:buf length:2];
    [fullPayload appendData:payload];
    
    // data = signature + fullPayload
    NSMutableData *data = [[self getSignatureForBytes:(uint8_t *)[fullPayload bytes]
                                               length:[fullPayload length]
                                                 key1:kSharedKey
                                                 key2:self.keyPart] mutableCopy];
    [data appendData:fullPayload];
    
    if (kRequestStateIdle == self.requestState) {
        NSLogDebug(@"sending request immediately: %@", data);
        [self sendMessageWithPayload:data messageSequenceNumber:self.sequenceNumber withCompletionBlock:completionBlock];
    } else {
        NSLogDebug(@"queuing request: %@", data);
        [self.transactionQueue addObject:[[Transaction alloc] initWithData:data
                                                     messageSequenceNumber:self.sequenceNumber
                                                         completionHandler:completionBlock]];
    }
}

- (void)sendMessageWithPayload:(NSData *)payload
         messageSequenceNumber:(uint8_t)messageSequenceNumber
           withCompletionBlock:(CompletionHandler)completionBlock
{
    NSAssert(kRequestStateIdle == self.requestState, @"assert: expect kRequestStateIdle");
    
    if (![self.ble write:payload]) {
        NSLogWarn(@"failed to send: %@", payload);
        completionBlock(nil, [NSError errorWithDomain:kErrorDomain code:kErrorCodeSendFailed userInfo:nil]);
    } else {
        NSLogDebug(@"message %@ sent - waiting for response", payload);

        self.activeSequenceNumber = messageSequenceNumber;
        self.requestState = kRequestStateSending;
        self.completionHandler = completionBlock;
    }
}

- (void)invokeCompletionHandlerWithData:(NSData *)data error:(NSError *)error
{
    self.requestState = kRequestStateIdle;
    
    if (!self.completionHandler) {
        NSAssert(NO, @"assert: must have completion handler");
        return;
    }
    
    // make local copy to handle the case where sendMessageWithPayload is invoked before the completion handler returns
    CompletionHandler ch = self.completionHandler;
    ch(data, error);
    
    if (kRequestStateIdle != self.requestState) {
        NSLogDebug(@"completion handler started a new transaction - skipping check for pending transactions");
        return;
    }

    // check for a pending transaction
    if ([self.transactionQueue count]) {
        Transaction *nextTransaction = [self.transactionQueue objectAtIndex:0];
        [self.transactionQueue removeObjectAtIndex:0];
        
        NSLogDebug(@"starting next transaction");
        [self sendMessageWithPayload:nextTransaction.data
               messageSequenceNumber:nextTransaction.messageSequenceNumber
                 withCompletionBlock:nextTransaction.completionHandler];
    }
}

- (void)activateGarageDoor:(BOOL)on
{
    uint8_t buf[2] = { 0x00, 0x00 };
    
    buf[0] = on ? 0x01 : 0x00;
    NSData *data = [[NSData alloc] initWithBytes:buf length:2];
    
    void (^controlLED)() = ^{
        NSLogDebug(@"kCmdControl request: %@", data);
        [self queueOrSendMessageWithCommand:kCmdControl payload:data withCompletionBlock:^(NSData *responseData, NSError *error) {
            if (error) {
                [[[UIAlertView alloc] initWithTitle:@"Command failed"
                                            message:[NSString stringWithFormat:@"%@ - %@", data, error.localizedDescription]
                                           delegate:nil
                                  cancelButtonTitle:@"OK"
                                  otherButtonTitles:nil] show];
            } else {
                NSLogDebug(@"kCmdControl response: %@", responseData);
            }
        }];
    };

    if (on) {
        // for kCmdGetKeyPart, data is ignored
        NSLogDebug(@"kCmdGetKeyPart request: %@", data);
        [self queueOrSendMessageWithCommand:kCmdGetKeyPart payload:data withCompletionBlock:^(NSData *responseData, NSError *error) {
            if (error) {
                [[[UIAlertView alloc] initWithTitle:@"Command failed"
                                            message:[NSString stringWithFormat:@"%@ - %@", data, error.localizedDescription]
                                           delegate:nil
                                  cancelButtonTitle:@"OK"
                                  otherButtonTitles:nil] show];
            } else {
                NSLogDebug(@"kCmdGetKeyPart response: %@", responseData);
                if ([responseData length] == 4) {
                    self.keyPart = [self dwordForBigEndianData:responseData];
                    NSLogDebug(@"keyPart: %08x", self.keyPart);
                    
                    controlLED();
                }
            }
        }];
    } else {
        controlLED();
    }
}

- (void)checkStatus:(NSTimer *)timer
{
    if (timer != self.statusCheckTimer) {
        return;
    }
    
    BOOL firstCheck = (timer == nil);

    // dummy request data - not used
    uint8_t buf[2] = { 0x00, 0x00 };
    NSData *data = [[NSData alloc] initWithBytes:buf length:2];

    [self queueOrSendMessageWithCommand:kCmdGetStatus payload:data withCompletionBlock:^(NSData *responseData, NSError *error) {
        if (error) {
            NSLogWarn(@"kCmdGetStatus failed: %@", [error description]);
        } else {
//            NSLogDebug(@"kCmdGetStatus response: %@", responseData);
            if ([responseData length] == 2) {
                BOOL doorFullyClosed = (((uint8_t *)[responseData bytes])[0]) ? YES : NO;
                BOOL doorFullyOpen = (((uint8_t *)[responseData bytes])[1]) ? NO : YES;
                
                NSLogDebug(@"kCmdGetStatus doorFullyClosed: %u, doorFullyOpen: %u", doorFullyClosed, doorFullyOpen);

                self.unknownDoorStateLabel.hidden = YES;

                [UIView animateWithDuration:(firstCheck ? 0 : 0.5) animations:^{
                    if (doorFullyOpen && doorFullyClosed) {
                        // error state
                        [[[UIAlertView alloc] initWithTitle:@"Error" message:@"Door open and closed at the same time" delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
                    } else if (doorFullyOpen) {
                        self.garageDoorView.frame = CGRectMake(0, -self.garageDoorView.frame.size.height, self.garageDoorView.frame.size.width, self.garageDoorView.frame.size.height);
                    } else if (doorFullyClosed) {
                        self.garageDoorView.frame = CGRectMake(0, 0, self.garageDoorView.frame.size.width, self.garageDoorView.frame.size.height);
                    } else if (!doorFullyOpen && !doorFullyClosed) {
                        self.garageDoorView.frame = CGRectMake(0, -self.garageDoorView.frame.size.height/2, self.garageDoorView.frame.size.width, self.garageDoorView.frame.size.height);
                    }
                }];
            }
        }
    }];
}

#pragma mark - Event handlers

- (IBAction)connectPressed:(id)sender
{
    NSLogDebug(@"entered");
    
    [self connectOrDisconnect];
}

- (IBAction)activateButtonDown:(id)sender
{
    NSLogDebug(@"entered");
        
    [self activateGarageDoor:YES];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self activateGarageDoor:NO];
    });
}

- (IBAction)activateButtonUp:(id)sender
{
    NSLogDebug(@"entered");

    // up is sent automatically after down
}

#pragma mark - BLEDelegate methods

- (void)bleDidConnect
{
    NSLogDebug(@"entered");
    
    [self.indConnecting stopAnimating];
    [self.btnConnect setEnabled:true];
    [self.btnConnect setTitle:@"Disconnect" forState:UIControlStateNormal];
    [[PebbleManager sharedInstance] sendMessageToWatch:@{ @(kMessageKeyRxLabelBtnSelect): @"Disconnect",
                                                          @(kMessageKeyRxLabelBtnDown): @"Activate" }];
    
    self.btnActivate.enabled = YES;

    [self checkStatus:nil];
    self.statusCheckTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(checkStatus:) userInfo:nil repeats:YES];
}

- (void)bleDidDisconnect
{
    NSLogDebug(@"entered");

    // door state unknown - show as closed with "?" label
    self.garageDoorView.frame = CGRectMake(0, 0, self.garageDoorView.frame.size.width, self.garageDoorView.frame.size.height);
    self.unknownDoorStateLabel.hidden = NO;

    [self.statusCheckTimer invalidate];
    self.statusCheckTimer = nil;

    self.btnActivate.enabled = NO;

    [self.indConnecting stopAnimating];
    [self.btnConnect setEnabled:true];
    [self.btnConnect setTitle:@"Connect" forState:UIControlStateNormal];
    [[PebbleManager sharedInstance] sendMessageToWatch:@{ @(kMessageKeyRxLabelBtnSelect): @"Connect",
                                                          @(kMessageKeyRxLabelBtnDown): @"--" }];

    if (kRequestStateIdle != self.requestState) {
        [self invokeCompletionHandlerWithData:nil error:[NSError errorWithDomain:kErrorDomain code:kErrorCodeDisconnect userInfo:nil]];
    }
}

- (void)bleDidUpdateRSSI:(NSNumber *)rssi
{
}

- (void)bleDidReceiveData:(unsigned char *)bytes length:(int)length
{
    NSMutableString *result = [NSMutableString stringWithCapacity:length*3];
    
    for (int i=0; i<length; i++) {
        [result appendFormat:@"%02X ", bytes[i]];
    }
    
    NSLogDebug(@"received <--- %@", result);

    if (kRequestStateIdle != self.requestState) {
        if (length < kHeaderLen) {
            [self invokeCompletionHandlerWithData:nil error:[NSError errorWithDomain:kErrorDomain code:kErrorCodeResponseTooShort userInfo:nil]];
        } else if (bytes[0] != kResponseSignature) {
            [self invokeCompletionHandlerWithData:nil error:[NSError errorWithDomain:kErrorDomain code:kErrorCodeResponseInvalid userInfo:nil]];
        } else if (bytes[1] != self.activeSequenceNumber) {
            [self invokeCompletionHandlerWithData:nil error:[NSError errorWithDomain:kErrorDomain code:kErrorCodeSequenceMismatch userInfo:nil]];
        } else if (bytes[2] == kResponseErrorSig) {
            [self invokeCompletionHandlerWithData:nil error:[NSError errorWithDomain:kErrorDomain code:kErrorCodeAuthFailed userInfo:nil]];
        } else if (bytes[3] != (length - kHeaderLen)) {
            [self invokeCompletionHandlerWithData:nil error:[NSError errorWithDomain:kErrorDomain code:kErrorCodeLengthMismatch userInfo:nil]];
        } else {
            NSMutableData *responseData = [[NSMutableData alloc] initWithBytes:bytes length:length];
            [responseData replaceBytesInRange:NSMakeRange(0, kHeaderLen) withBytes:NULL length:0];
            [self invokeCompletionHandlerWithData:responseData error:nil];
        }
    }
}

#pragma mark - PebbleManagerDelegate methods

- (BOOL)pebbleManager:(PebbleManager *)manager didHandleCmd:(PebbleCmdType)cmd
{
    switch (cmd) {
        case kPebbleCmdBtnUp: {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [manager sendMessageToWatch:@{ @(kMessageKeyRxLabelBtnUp): @"Pong",
                                               @(kMessageKeyRxLabelBtnSelect): self.btnConnect.titleLabel.text,
                                               @(kMessageKeyRxLabelBtnDown): self.btnActivate.enabled ? @"Activate" : @"--" }];
            });
            break;
        }
            
        case kPebbleCmdBtnSelect:
            if (self.btnConnect.enabled) {
                [self connectPressed:nil];
            } // TODO - else notify pebble of bad state
            break;
            
        case kPebbleCmdBtnDown:
            if (self.btnActivate.enabled) {
                // TODO - set flag to reroute error msg, if any, back to pebble
                [self activateButtonDown:nil];
            } // TODO - else notify pebble of bad state
            break;
            
        default:
            return NO;
    }
    
    return YES;
}

@end
