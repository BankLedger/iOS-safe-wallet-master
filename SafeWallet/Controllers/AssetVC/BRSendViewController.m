//
//  BRSendViewController.m
//  BreadWallet
//
//  Created by Aaron Voisine on 5/8/13.
//  Copyright (c) 2013 Aaron Voisine <voisine@gmail.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "BRSendViewController.h"
#import "BRRootViewController.h"
#import "BRScanViewController.h"
#import "BRAmountViewController.h"
#import "BRSettingsViewController.h"
#import "BRBubbleView.h"
#import "BRWalletManager.h"
#import "BRPeerManager.h"
#import "BRPaymentRequest.h"
#import "BRPaymentProtocol.h"
#import "BRKey.h"
#import "BRTransaction.h"
#import "NSString+Bitcoin.h"
#import "NSMutableData+Bitcoin.h"
#import "NSString+Dash.h"
#import "NSData+Dash.h"
#import "NSData+Bitcoin.h"
#import "BREventManager.h"
#import "FBShimmeringView.h"
#import "MBProgressHUD.h"
#import "DSShapeshiftManager.h"
#import "BRBIP32Sequence.h"
#import "BRAssetViewController.h"
#import "BRSafeUtils.h"

#define SCAN_TIP      NSLocalizedString(@"Scan someone else's QR code to get their dash or bitcoin address. "\
"You can send a payment to anyone with an address.", nil)
#define CLIPBOARD_TIP NSLocalizedString(@"Dash addresses can also be copied to the clipboard. "\
"A dash address always starts with 'X' or '7'.", nil)

#define LOCK @"\xF0\x9F\x94\x92" // unicode lock symbol U+1F512 (utf-8)
#define REDX @"\xE2\x9D\x8C"     // unicode cross mark U+274C, red x emoji (utf-8)
#define NBSP @"\xC2\xA0"         // no-break space (utf-8)

#define SEND_INSTANTLY_KEY @"SEND_INSTANTLY_KEY"

static NSString *sanitizeString(NSString *s)
{
    NSMutableString *sane = [NSMutableString stringWithString:(s) ? s : @""];
    
    CFStringTransform((CFMutableStringRef)sane, NULL, kCFStringTransformToUnicodeName, NO);
    return sane;
}

@interface BRSendViewController ()

@property (nonatomic, assign) BOOL clearClipboard, useClipboard, showTips, showBalance, canChangeAmount, sendInstantly;
@property (nonatomic, strong) BRTransaction *sweepTx;
@property (nonatomic, strong) BRPaymentProtocolRequest *request, *shapeshiftRequest;
@property (nonatomic, strong) NSString *scheme;
@property (nonatomic, strong) DSShapeshiftEntity * associatedShapeshift;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, assign) uint64_t amount;
@property (nonatomic, strong) NSString *okAddress, *okIdentity;
@property (nonatomic, strong) BRBubbleView *tipView;
@property (nonatomic, strong) BRScanViewController *scanController;

@property (nonatomic, strong) IBOutlet UILabel *sendLabel;
@property (nonatomic, strong) IBOutlet UISwitch *instantSwitch;
@property (nonatomic, strong) IBOutlet UIButton *scanButton, *clipboardButton;
@property (nonatomic, strong) IBOutlet UIView * shapeshiftView;
@property (nonatomic, strong) IBOutlet UILabel * shapeshiftLabel;
@property (nonatomic, strong) IBOutlet NSLayoutConstraint * NFCWidthConstraint;
@property (nonatomic, strong) IBOutlet NSLayoutConstraint * leftOfNFCButtonWhitespaceConstraint;
/// 新增变量  支付请求
@property (nonatomic, strong) BRPaymentRequest *payRequest;
@end

@implementation BRSendViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    
    // TODO: XXX redesign page with round buttons like the iOS power down screen... apple watch also has round buttons
    self.scanButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.clipboardButton.titleLabel.adjustsFontSizeToFitWidth = YES;
#warning Language International
    if(self.balanceModel.assetId.length != 0) {
        self.sendLabel.text = [NSString stringWithFormat:@"发送 %@", self.balanceModel.nameString];
    } else {
        self.sendLabel.text = @"发送 SAFE";
    }
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    self.scanButton.titleLabel.adjustsLetterSpacingToFitWidth = YES;
    self.clipboardButton.titleLabel.adjustsLetterSpacingToFitWidth = YES;
#pragma clang diagnostic pop
    
    self.view.backgroundColor = [UIColor whiteColor];
    self.navigationItem.title = NSLocalizedString(@"Send Assets", nil);
    
    FBShimmeringView *shimmeringView = [[FBShimmeringView alloc] initWithFrame:CGRectMake(0, self.shapeshiftView.frame.origin.y, self.view.frame.size.width, self.shapeshiftView.frame.size.height)];
    [self.view addSubview:shimmeringView];
    [self.shapeshiftView removeFromSuperview];
    [shimmeringView addSubview:self.shapeshiftView];
    shimmeringView.contentView = self.shapeshiftView;
    // Start shimmering.
    shimmeringView.shimmering = YES;
    shimmeringView.shimmeringSpeed = 5;
    shimmeringView.shimmeringDirection = FBShimmerDirectionUp;
    shimmeringView.shimmeringPauseDuration = 0.0;
    shimmeringView.shimmeringHighlightLength = 1.0f;
    shimmeringView.shimmeringAnimationOpacity = 0.8;
    self.shapeshiftView = shimmeringView;
    
    FBShimmeringView *shimmeringInnerLabelView = [[FBShimmeringView alloc] initWithFrame:self.shapeshiftLabel.frame];
    [self.shapeshiftLabel removeFromSuperview];
    [shimmeringInnerLabelView addSubview:self.shapeshiftLabel];
    shimmeringInnerLabelView.contentView = self.shapeshiftLabel;
    
    shimmeringInnerLabelView.shimmering = YES;
    shimmeringInnerLabelView.shimmeringSpeed = 100;
    shimmeringInnerLabelView.shimmeringPauseDuration = 0.8;
    shimmeringInnerLabelView.shimmeringAnimationOpacity = 0.2;
    [self.shapeshiftView addSubview:shimmeringInnerLabelView];
    NSArray * shapeshiftsInProgress = [DSShapeshiftEntity shapeshiftsInProgress];
    if (![shapeshiftsInProgress count]) {
        
        self.shapeshiftView.hidden = TRUE;
    } else {
        for (DSShapeshiftEntity * shapeshift in shapeshiftsInProgress) {
            [shapeshift transaction];
            [self startObservingShapeshift:shapeshift];
        }
    }
    
    self.sendInstantly = [[NSUserDefaults standardUserDefaults] boolForKey:SEND_INSTANTLY_KEY];
    [self.instantSwitch setOn:self.sendInstantly];
    @weakify(self);
    [[NSNotificationCenter defaultCenter] addObserverForName:BRWalletBalanceChangedNotification object:nil
                                                       queue:nil usingBlock:^(NSNotification *note) {
                                                           @strongify(self);
                                                           BRWalletManager *mgr = [BRWalletManager sharedInstance];
                                                           for (BRBalanceModel *balanceModel in mgr.wallet.balanceArray) {
                                                               if (self.balanceModel.assetId.length == 0) {
                                                                   self.balanceModel = balanceModel;
                                                                   break;
                                                               } else {
                                                                   if ([self.balanceModel.assetId isEqual:balanceModel.assetId]) {
                                                                       self.balanceModel = balanceModel;
                                                                       break;
                                                                   }
                                                               }
                                                           }
                                                           
                                                       }];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self cancel:nil];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    if (! self.scanController) {
        self.scanController = [self.storyboard instantiateViewControllerWithIdentifier:@"ScanViewController"];
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    BRLogFunc;
}

-(BOOL)processURLAddressList:(NSURL*)url {
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    if (! [self.url isEqual:url]) {
        self.url = url;
        UIAlertController * alert = [UIAlertController
                                     alertControllerWithTitle:NSLocalizedString(@"copy wallet addresses to clipboard?", nil)
                                     message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* cancelButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"cancel", nil)
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                           if (self.url) {
                                               self.clearClipboard = YES;
                                               [self handleURL:self.url];
                                           }
                                           else [self cancelOrChangeAmount];
                                       }];
        UIAlertAction* copyButton = [UIAlertAction
                                     actionWithTitle:NSLocalizedString(@"copy", nil)
                                     style:UIAlertActionStyleDefault
                                     handler:^(UIAlertAction * action) {
                                         [self handleURL:self.url];
                                     }];
        
        [alert addAction:cancelButton];
        [alert addAction:copyButton];
        [self presentViewController:alert animated:YES completion:nil];
        return NO;
    }
    else {
        [UIPasteboard generalPasteboard].string =
        [[[manager.wallet.allReceiveAddresses
           setByAddingObjectsFromSet:manager.wallet.allChangeAddresses]
          objectsPassingTest:^BOOL(id obj, BOOL *stop) {
              return [manager.wallet addressIsUsed:obj];
          }].allObjects componentsJoinedByString:@"\n"];
        
        return YES;
        
    }
}

- (void)handleURL:(NSURL *)url
{
    [BREventManager saveEvent:@"send:handle_url"
               withAttributes:@{@"scheme": (url.scheme ? url.scheme : @"(null)"),
                                @"host": (url.host ? url.host : @"(null)"),
                                @"path": (url.path ? url.path : @"(null)")}];
    
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    if ([url.scheme isEqual:@"safewallet"]) {
        if ([url.host isEqual:@"scanqr"] || [url.path isEqual:@"/scanqr"]) { // scan qr
            [self scanQR:self.scanButton];
        } else if ([url.host hasPrefix:@"request"] || [url.path isEqual:@"/request"]) {
            NSArray * array = [url.host componentsSeparatedByString:@"&"];
            NSMutableDictionary * dictionary = [[NSMutableDictionary alloc] init];
            for (NSString * param in array) {
                NSArray * paramArray = [param componentsSeparatedByString:@"="];
                if ([paramArray count] == 2) {
                    [dictionary setObject:paramArray[1] forKey:paramArray[0]];
                }
            }
            
            if (dictionary[@"request"] && dictionary[@"sender"] && (!dictionary[@"account"] || [dictionary[@"account"] isEqualToString:@"0"])) {
                if ([dictionary[@"request"] isEqualToString:@"masterPublicKey"]) {
                    [manager authenticateWithPrompt:[NSString stringWithFormat:NSLocalizedString(@"Application %@ would like to receive your Master Public Key.  This can be used to keep track of your wallet, this can not be used to move your Dash.",nil),dictionary[@"sender"]] andTouchId:NO alertIfLockout:YES completion:^(BOOL authenticatedOrSuccess,BOOL cancelled) {
                        if (authenticatedOrSuccess) {
                            BRBIP32Sequence *seq = [BRBIP32Sequence new];
                            NSString * masterPublicKeySerialized = [seq serializedMasterPublicKey:manager.extendedBIP44PublicKey depth:BIP44_PURPOSE_ACCOUNT_DEPTH];
                            NSString * masterPublicKeyNoPurposeSerialized = [seq serializedMasterPublicKey:manager.extendedBIP32PublicKey depth:BIP32_PURPOSE_ACCOUNT_DEPTH];
                            //TODO change add zc
                            NSURL * url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://callback=%@&masterPublicKeyBIP32=%@&masterPublicKeyBIP44=%@&account=%@&source=safewallet",dictionary[@"sender"],dictionary[@"request"],masterPublicKeyNoPurposeSerialized,masterPublicKeySerialized,@"0"]];
                            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
                                
                            }];
                        }
                    }];
                } else if ([dictionary[@"request"] isEqualToString:@"address"]) {
                    [manager authenticateWithPrompt:[NSString stringWithFormat:NSLocalizedString(@"Application %@ is requesting an address so it can pay you.  Would you like to authorize this?",nil),dictionary[@"sender"]] andTouchId:NO alertIfLockout:YES completion:^(BOOL authenticatedOrSuccess,BOOL cancelled) {
                        if (authenticatedOrSuccess) {
                            NSURL * url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://callback=%@&address=%@&source=safewallet",dictionary[@"sender"],dictionary[@"request"],manager.wallet.receiveAddress]];
                            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
                                
                            }];
                        }
                    }];
                }
                
            }
        } else if ([url.host hasPrefix:@"pay"] || [url.path isEqual:@"/pay"]) {
            NSMutableArray * array = [[url.host componentsSeparatedByString:@"&"] mutableCopy];
            NSMutableDictionary * dictionary = [[NSMutableDictionary alloc] init];
            for (NSString * param in array) {
                NSArray * paramArray = [param componentsSeparatedByString:@"="];
                if ([paramArray count] == 2) {
                    [dictionary setObject:paramArray[1] forKey:paramArray[0]];
                }
            }
            if (dictionary[@"pay"] && dictionary[@"sender"]) {
                if (dictionary[@"label"]) [dictionary removeObjectForKey:@"label"];
                NSURLComponents *components = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"safe:%@",dictionary[@"pay"]]];
                NSMutableArray *queryItems = [NSMutableArray array];
                NSURLQueryItem *label = [NSURLQueryItem queryItemWithName:@"label" value:[NSString stringWithFormat:NSLocalizedString(@"Application %@ is requesting a payment to",nil),[dictionary[@"sender"] capitalizedString]]];
                [queryItems addObject:label];
                for (NSString *key in dictionary) {
                    if ([key isEqualToString:@"label"]) continue;
                    [queryItems addObject:[NSURLQueryItem queryItemWithName:key value:dictionary[key]]];
                }
                components.queryItems = queryItems;
                NSURL * paymentURL = components.URL;
                [self confirmRequest:[BRPaymentRequest requestWithURL:paymentURL]];
            }
        }
    }
    else if ([url.scheme isEqual:@"safe"]) {
        [self confirmRequest:[BRPaymentRequest requestWithURL:url]];
    }
    else {
        UIAlertController * alert = [UIAlertController
                                     alertControllerWithTitle:NSLocalizedString(@"unsupported url", nil)
                                     message:url.absoluteString
                                     preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* okButton = [UIAlertAction
                                   actionWithTitle:@"ok"
                                   style:UIAlertActionStyleCancel
                                   handler:^(UIAlertAction * action) {
                                   }];
        [alert addAction:okButton];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)handleFile:(NSData *)file
{
    BRPaymentProtocolRequest *request = [BRPaymentProtocolRequest requestWithData:file];
    
    if (request) {
        [self confirmProtocolRequest:request];
        return;
    }
    
    // TODO: reject payments that don't match requested amounts/scripts, implement refunds
    BRPaymentProtocolPayment *payment = [BRPaymentProtocolPayment paymentWithData:file];
    
    if (payment.transactions.count > 0) {
        for (BRTransaction *tx in payment.transactions) {
            [(id)self.parentViewController.parentViewController startActivityWithTimeout:30];
            
            [[BRPeerManager sharedInstance] publishTransaction:tx completion:^(NSError *error) {
                [(id)self.parentViewController.parentViewController stopActivityWithSuccess:(! error)];
                
                if (error) {
                    UIAlertController * alert = [UIAlertController
                                                 alertControllerWithTitle:NSLocalizedString(@"couldn't transmit payment to dash network", nil)
                                                 message:error.localizedDescription
                                                 preferredStyle:UIAlertControllerStyleAlert];
                    UIAlertAction* okButton = [UIAlertAction
                                               actionWithTitle:@"ok"
                                               style:UIAlertActionStyleCancel
                                               handler:^(UIAlertAction * action) {
                                               }];
                    [alert addAction:okButton];
                    [self presentViewController:alert animated:YES completion:nil];
                }
                
                [self.view addSubview:[[[BRBubbleView
                                         viewWithText:(payment.memo.length > 0 ? payment.memo : NSLocalizedString(@"received", nil))
                                         center:CGPointMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2)] popIn]
                                       popOutAfterDelay:(payment.memo.length > 0 ? 3.0 : 2.0)]];
            }];
        }
        
        return;
    }
    
    BRPaymentProtocolACK *ack = [BRPaymentProtocolACK ackWithData:file];
    
    if (ack) {
        if (ack.memo.length > 0) {
            [self.view addSubview:[[[BRBubbleView viewWithText:ack.memo
                                                        center:CGPointMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2)] popIn]
                                   popOutAfterDelay:3.0]];
        }
        
        return;
    }
    UIAlertController * alert = [UIAlertController
                                 alertControllerWithTitle:NSLocalizedString(@"unsupported or corrupted document", nil)
                                 message:@""
                                 preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okButton = [UIAlertAction
                               actionWithTitle:@"ok"
                               style:UIAlertActionStyleCancel
                               handler:^(UIAlertAction *action) {
                               }];
    [alert addAction:okButton];
    [self presentViewController:alert animated:YES completion:nil];
    
}

- (NSString *)promptAssetForAmount:(uint64_t)amount fee:(uint64_t)fee address:(NSString *)address name:(NSString *)name
                              memo:(NSString *)memo isSecure:(BOOL)isSecure {
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    NSString *prompt = (isSecure && name.length > 0) ? LOCK @" " : @"";
    
    //BUG: XXX limit the length of name and memo to avoid having the amount clipped
    if (! isSecure && self.request.errorMessage.length > 0) prompt = [prompt stringByAppendingString:REDX @" "];
    if (name.length > 0) prompt = [prompt stringByAppendingString:sanitizeString(name)];
    if (! isSecure && prompt.length > 0) prompt = [prompt stringByAppendingString:@"\n"];
    if (! isSecure || prompt.length == 0) prompt = [prompt stringByAppendingString:address];
    if (memo.length > 0) prompt = [prompt stringByAppendingFormat:@"\n\n%@", sanitizeString(memo)];
    NSNumberFormatter *dashFormat = [[NSNumberFormatter alloc] init];
    dashFormat.lenient = YES;
    dashFormat.numberStyle = NSNumberFormatterCurrencyStyle;
    dashFormat.generatesDecimalNumbers = YES;
    dashFormat.negativeFormat = [dashFormat.positiveFormat
                                      stringByReplacingCharactersInRange:[dashFormat.positiveFormat rangeOfString:@"#"]
                                      withString:@"-#"];
    BRBalanceModel *nowBalanceModel = self.payRequest.amount > 0 ? [self returnCodeBalanceModel] : self.balanceModel;
    dashFormat.currencyCode = nowBalanceModel.nameString;
    dashFormat.currencySymbol = [nowBalanceModel.nameString stringByAppendingString:NARROW_NBSP];
    dashFormat.maximumFractionDigits = nowBalanceModel.multiple;
    dashFormat.minimumFractionDigits = 0; // iOS 8 bug, minimumFractionDigits now has to be set after currencySymbol
    dashFormat.maximum = @(MAX_MONEY/(int64_t)pow(10.0, dashFormat.maximumFractionDigits));
    prompt = [prompt stringByAppendingFormat:NSLocalizedString(@"\n\n     amount： %@", nil),
              [dashFormat stringFromNumber:[(id)[NSDecimalNumber numberWithLongLong:amount - fee]
                                            decimalNumberByMultiplyingByPowerOf10:-dashFormat.maximumFractionDigits]]];
    
    if (fee > 0) {
        prompt = [prompt stringByAppendingFormat:NSLocalizedString(@"\n        fee： +%@", nil),
                  [manager stringForDashAmount:fee]];
        prompt = [prompt stringByAppendingFormat:NSLocalizedString(@"\n          total： %@", nil),
                  [NSString stringWithFormat:@"%@ + %@", [dashFormat stringFromNumber:[(id)[NSDecimalNumber numberWithLongLong:amount - fee]
                                                                                       decimalNumberByMultiplyingByPowerOf10:-dashFormat.maximumFractionDigits]], [manager stringForDashAmount:fee]]];
    }
    return prompt;
}

// generate a description of a transaction so the user can review and decide whether to confirm or cancel
- (NSString *)promptForAmount:(uint64_t)amount fee:(uint64_t)fee address:(NSString *)address name:(NSString *)name
                         memo:(NSString *)memo isSecure:(BOOL)isSecure
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    NSString *prompt = (isSecure && name.length > 0) ? LOCK @" " : @"";
    
    //BUG: XXX limit the length of name and memo to avoid having the amount clipped
    if (! isSecure && self.request.errorMessage.length > 0) prompt = [prompt stringByAppendingString:REDX @" "];
    if (name.length > 0) prompt = [prompt stringByAppendingString:sanitizeString(name)];
    if (! isSecure && prompt.length > 0) prompt = [prompt stringByAppendingString:@"\n"];
    if (! isSecure || prompt.length == 0) prompt = [prompt stringByAppendingString:address];
    if (memo.length > 0) prompt = [prompt stringByAppendingFormat:@"\n\n%@", sanitizeString(memo)];
    prompt = [prompt stringByAppendingFormat:NSLocalizedString(@"\n\n     amount： %@", nil),
              [manager stringForDashAmount:amount - fee]];
    
    if (fee > 0) {
        prompt = [prompt stringByAppendingFormat:NSLocalizedString(@"\n        fee： +%@", nil),
                  [manager stringForDashAmount:fee]];
        prompt = [prompt stringByAppendingFormat:NSLocalizedString(@"\n          total： %@", nil),
                  [manager stringForDashAmount:amount]];
    }
    return prompt;
}


- (void)confirmRequest:(BRPaymentRequest *)request
{
    if (! request.isValid) {
        if ([request.paymentAddress isValidDashPrivateKey] || [request.paymentAddress isValidDashBIP38Key]) {
            [self confirmSweep:request.paymentAddress];
        }
        else {
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"not a valid dash or bitcoin address", nil)
                                         message:request.paymentAddress
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* okButton = [UIAlertAction
                                       actionWithTitle:@"ok"
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                       }];
            [alert addAction:okButton];
            [self presentViewController:alert animated:YES completion:nil];
            [self cancel:nil];
        }
    }
    else if (request.r.length > 0) { // payment protocol over HTTP
        [(id)self.parentViewController.parentViewController startActivityWithTimeout:20.0];
        
        [BRPaymentRequest fetch:request.r scheme:request.scheme timeout:20.0 completion:^(BRPaymentProtocolRequest *req, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [(id)self.parentViewController.parentViewController stopActivityWithSuccess:(! error)];
                
                if (error && ! ([request.paymentAddress isValidBitcoinAddress] || [request.paymentAddress isValidDashAddress])) {
                    UIAlertController * alert = [UIAlertController
                                                 alertControllerWithTitle:NSLocalizedString(@"couldn't make payment", nil)
                                                 message:error.localizedDescription
                                                 preferredStyle:UIAlertControllerStyleAlert];
                    UIAlertAction* okButton = [UIAlertAction
                                               actionWithTitle:@"ok"
                                               style:UIAlertActionStyleCancel
                                               handler:^(UIAlertAction * action) {
                                               }];
                    [alert addAction:okButton];
                    [self presentViewController:alert animated:YES completion:nil];
                    [self cancel:nil];
                }
                else [self confirmProtocolRequest:(error) ? request.protocolRequest : req];
            });
        }];
    }
    else [self confirmProtocolRequest:request.protocolRequest currency:request.scheme associatedShapeshift:nil wantsInstant:request.wantsInstant requiresInstantValue:request.instantValueRequired];
}

- (void)confirmProtocolRequest:(BRPaymentProtocolRequest *)protoReq {
    [self confirmProtocolRequest:protoReq currency:@"safe" associatedShapeshift:nil];
}

- (void)confirmProtocolRequest:(BRPaymentProtocolRequest *)protoReq currency:(NSString*)currency associatedShapeshift:(DSShapeshiftEntity*)shapeshift
{
    [self confirmProtocolRequest:protoReq currency:currency associatedShapeshift:shapeshift wantsInstant:self.sendInstantly requiresInstantValue:FALSE];
}

- (void)confirmProtocolRequest:(BRPaymentProtocolRequest *)protoReq currency:(NSString*)currency associatedShapeshift:(DSShapeshiftEntity*)shapeshift wantsInstant:(BOOL)wantsInstant requiresInstantValue:(BOOL)requiresInstantValue
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    BRTransaction *tx = nil;
    uint64_t amount = 0, fee = 0;
    BOOL valid = protoReq.isValid, outputTooSmall = NO;
    
    if (!valid && [protoReq.errorMessage isEqual:NSLocalizedString(@"request expired", nil)]) {
        UIAlertController * alert = [UIAlertController
                                     alertControllerWithTitle:NSLocalizedString(@"bad payment request", nil)
                                     message:protoReq.errorMessage
                                     preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* okButton = [UIAlertAction
                                   actionWithTitle:@"ok"
                                   style:UIAlertActionStyleCancel
                                   handler:^(UIAlertAction * action) {
                                   }];
        [alert addAction:okButton];
        [self presentViewController:alert animated:YES completion:nil];
        [self cancel:nil];
        return;
    }
    
    //TODO: check for duplicates of already paid requests
    if (self.amount == 0) {
        for (NSNumber *outputAmount in protoReq.details.outputAmounts) {
            if (outputAmount.unsignedLongLongValue > 0 && outputAmount.unsignedLongLongValue < TX_MIN_OUTPUT_AMOUNT) {
                outputTooSmall = YES;
            }
            amount += outputAmount.unsignedLongLongValue;
        }
    }
    else amount = self.amount;

    if ([currency isEqualToString:@"safe"]) {
        NSString *address = [NSString addressWithScriptPubKey:protoReq.details.outputScripts.firstObject];
//        if ([manager.wallet containsAddress:address]) {
//            UIAlertController *alert = [UIAlertController
//                                         alertControllerWithTitle:@""
//                                         message:NSLocalizedString(@"this payment address is already in your wallet", nil)
//                                         preferredStyle:UIAlertControllerStyleAlert];
//            UIAlertAction *okButton = [UIAlertAction
//                                       actionWithTitle:@"ok"
//                                       style:UIAlertActionStyleCancel
//                                       handler:^(UIAlertAction * action) {
//                                       }];
//            [alert addAction:okButton];
//            [self presentViewController:alert animated:YES completion:nil];
//            [self cancel:nil];
//            return;
//        }
         if (! [self.okAddress isEqual:address] && [manager.wallet addressIsUsed:address] &&
                 [[UIPasteboard generalPasteboard].string isEqual:address]) {
            self.request = protoReq;
            self.scheme = currency;
            self.okAddress = address;
            self.associatedShapeshift = shapeshift;
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"WARNING", nil)
                                         message:NSLocalizedString(@"\nADDRESS ALREADY USED\ndash addresses are intended for single use only\n\n"
                                                                   "re-use reduces privacy for both you and the recipient and can result in loss if "
                                                                   "the recipient doesn't directly control the address", nil)
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* cancelButton = [UIAlertAction
                                           actionWithTitle:NSLocalizedString(@"Cancle", nil)
                                           style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction * action) {
                                               [self cancelOrChangeAmount];
                                           }];
            UIAlertAction* ignoreButton = [UIAlertAction
                                           actionWithTitle:NSLocalizedString(@"Continue", nil)
                                           style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction * action) {
                                               [self confirmProtocolRequest:self.request currency:self.scheme associatedShapeshift:self.associatedShapeshift];
                                           }];
            [alert addAction:ignoreButton];
            [alert addAction:cancelButton];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        } else if (wantsInstant && !self.sendInstantly) {
            self.request = protoReq;
            self.scheme = currency;
            self.associatedShapeshift = shapeshift;
            
            if (requiresInstantValue) {
                UIAlertController * alert = [UIAlertController
                                             alertControllerWithTitle:NSLocalizedString(@"instant payment", nil)
                                             message:NSLocalizedString(@"this request requires an instant payment but you have disabled instant payments",
                                                                       nil)
                                             preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction* ignoreButton = [UIAlertAction
                                               actionWithTitle:NSLocalizedString(@"cancel", nil)
                                               style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction * action) {
                                                   
                                               }];
                UIAlertAction* enableButton = [UIAlertAction
                                               actionWithTitle:NSLocalizedString(@"enable", nil)
                                               style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction * action) {
                                                   self.sendInstantly = TRUE;
                                                   [self.instantSwitch setOn:TRUE animated:TRUE];
                                                   [self confirmProtocolRequest:self.request currency:self.scheme associatedShapeshift:self.associatedShapeshift wantsInstant:TRUE requiresInstantValue:TRUE];
                                               }];
                
                [alert addAction:ignoreButton];
                [alert addAction:enableButton];
                [self presentViewController:alert animated:YES completion:nil];
            } else {
                
                UIAlertController * alert = [UIAlertController
                                             alertControllerWithTitle:NSLocalizedString(@"instant payment", nil)
                                             message:NSLocalizedString(@"request is for an instant payment but you have disabled instant payments",
                                                                       nil)
                                             preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction* ignoreButton = [UIAlertAction
                                               actionWithTitle:NSLocalizedString(@"ignore", nil)
                                               style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction * action) {
                                                   [self confirmProtocolRequest:self.request currency:self.scheme associatedShapeshift:self.associatedShapeshift];
                                               }];
                UIAlertAction* enableButton = [UIAlertAction
                                               actionWithTitle:NSLocalizedString(@"enable", nil)
                                               style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction * action) {
                                                   self.sendInstantly = TRUE;
                                                   [self.instantSwitch setOn:TRUE animated:TRUE];
                                                   [self confirmProtocolRequest:self.request currency:self.scheme associatedShapeshift:self.associatedShapeshift wantsInstant:TRUE requiresInstantValue:requiresInstantValue];
                                               }];
                
                [alert addAction:ignoreButton];
                [alert addAction:enableButton];
                [self presentViewController:alert animated:YES completion:nil];
            }
            return;
            
        } else if (amount > (self.payRequest.amount > 0 ? [self returnCodeBalanceModel].balance : self.balanceModel.balance) && amount != UINT64_MAX) { //TODO: 修改数据  manager.wallet.balance
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"insufficient funds", nil)
                                         message:nil
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* okButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"ok", nil)
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                       }];
            
            [alert addAction:okButton];
            [self presentViewController:alert animated:YES completion:nil];
            [self cancel:nil];
            return;
        } else if (wantsInstant && ([manager.wallet maxOutputAmountWithConfirmationCount:IX_PREVIOUS_CONFIRMATIONS_NEEDED usingInstantSend:TRUE] < amount)) {
            self.request = protoReq;
            self.scheme = currency;
            self.associatedShapeshift = shapeshift;
            if (requiresInstantValue) {
                UIAlertController * alert = [UIAlertController
                                             alertControllerWithTitle:NSLocalizedString(@"instant payment", nil)
                                             message:NSLocalizedString(@"This request requires an instant payment but you do not have enough inputs with 6 confirmations required by Instant Send, you may ask the merchant to accept a normal transaction or wait a few minutes.",
                                                                       nil)
                                             preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction* cancelButton = [UIAlertAction
                                               actionWithTitle:NSLocalizedString(@"cancel", nil)
                                               style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction * action) {
                                                   [self cancelOrChangeAmount];
                                               }];
                UIAlertAction* retryButton = [UIAlertAction
                                              actionWithTitle:NSLocalizedString(@"retry", nil)
                                              style:UIAlertActionStyleDefault
                                              handler:^(UIAlertAction * action) {
                                                  [self confirmProtocolRequest:self.request currency:self.scheme associatedShapeshift:self.associatedShapeshift wantsInstant:wantsInstant requiresInstantValue:requiresInstantValue];
                                              }];
                
                [alert addAction:cancelButton];
                [alert addAction:retryButton];
                [self presentViewController:alert animated:YES completion:nil];
            } else {
                UIAlertController * alert = [UIAlertController
                                             alertControllerWithTitle:NSLocalizedString(@"instant payment", nil)
                                             message:NSLocalizedString(@"Instant Send requires enough inputs with 6 confirmations, send anyways as regular transaction?",
                                                                       nil)
                                             preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction* cancelButton = [UIAlertAction
                                               actionWithTitle:NSLocalizedString(@"cancel", nil)
                                               style:UIAlertActionStyleCancel
                                               handler:^(UIAlertAction * action) {
                                                   [self cancelOrChangeAmount];
                                               }];
                UIAlertAction* enableButton = [UIAlertAction
                                               actionWithTitle:NSLocalizedString(@"send", nil)
                                               style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction * action) {
                                                   [self confirmProtocolRequest:self.request currency:self.scheme associatedShapeshift:self.associatedShapeshift wantsInstant:FALSE requiresInstantValue:requiresInstantValue];
                                               }];
                
                [alert addAction:cancelButton];
                [alert addAction:enableButton];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }
        } else if (protoReq.errorMessage.length > 0 && protoReq.commonName.length > 0 &&
                   ! [self.okIdentity isEqual:protoReq.commonName]) {
            self.request = protoReq;
            self.scheme = currency;
            self.okIdentity = protoReq.commonName;
            self.associatedShapeshift = shapeshift;
            
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"payee identity isn't certified", nil)
                                         message:protoReq.errorMessage
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* ignoreButton = [UIAlertAction
                                           actionWithTitle:NSLocalizedString(@"ignore", nil)
                                           style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction * action) {
                                               [self confirmProtocolRequest:self.request currency:self.scheme associatedShapeshift:self.associatedShapeshift];
                                           }];
            UIAlertAction* cancelButton = [UIAlertAction
                                           actionWithTitle:NSLocalizedString(@"cancel", nil)
                                           style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction * action) {
                                               [self cancelOrChangeAmount];
                                           }];
            
            [alert addAction:ignoreButton];
            [alert addAction:cancelButton];
            [self presentViewController:alert animated:YES completion:nil];
            
            return;
        }
        else if (amount == 0 || amount == UINT64_MAX) {
            BRAmountViewController *amountController = [self.storyboard
                                                        instantiateViewControllerWithIdentifier:@"AmountViewController"];
            amountController.maximumFractionDigits = self.balanceModel.multiple;
            amountController.delegate = self;
            amountController.isInstant = self.instantSwitch.on;
            self.request = protoReq;
            self.scheme = currency;
            self.associatedShapeshift = shapeshift;
            if (protoReq.commonName.length > 0) {
                if (valid && ! [protoReq.pkiType isEqual:@"none"]) {
                    amountController.to = [LOCK @" " stringByAppendingString:sanitizeString(protoReq.commonName)];
                }
                else if (protoReq.errorMessage.length > 0) {
                    amountController.to = [REDX @" " stringByAppendingString:sanitizeString(protoReq.commonName)];
                }
                else amountController.to = sanitizeString(protoReq.commonName);
            }
            else amountController.to = address;
            //[self updateTitleView];
            [self.navigationController pushViewController:amountController animated:YES];
            return;
        }
        else if (amount < TX_MIN_OUTPUT_AMOUNT && self.balanceModel.assetId.length == 0) {
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"couldn't make payment", nil)
                                         message:[NSString stringWithFormat:NSLocalizedString(@"dash payments can't be less than %@", nil),
                                                  [manager stringForDashAmount:TX_MIN_OUTPUT_AMOUNT]]
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* okButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"ok", nil)
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                           
                                       }];
            
            
            [alert addAction:okButton];
            [self presentViewController:alert animated:YES completion:nil];
            [self cancel:nil];
            return;
        }
        else if (outputTooSmall) {
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"couldn't make payment", nil)
                                         message:[NSString stringWithFormat:NSLocalizedString(@"dash transaction outputs can't be less than %@",
                                                                                              nil), [manager stringForDashAmount:TX_MIN_OUTPUT_AMOUNT]]
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* okButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"ok", nil)
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                           
                                       }];
            
            
            [alert addAction:okButton];
            [self presentViewController:alert animated:YES completion:nil];
            [self cancel:nil];
            return;
        }
        
        self.request = protoReq;
        self.scheme = @"safe";
        
        if (self.amount == 0) {
            
            if (shapeshift) {
                tx = [manager.wallet transactionForAmounts:protoReq.details.outputAmounts toOutputScripts:protoReq.details.outputScripts withUnlockHeights:protoReq.details.outputUnlockHeights withReserves:protoReq.details.outputReserves withFee:YES isInstant:wantsInstant toShapeshiftAddress:shapeshift.withdrawalAddress];
                tx.associatedShapeshift = shapeshift;
            } else {
                // TODO: 修改二维码带金额的交易
//                tx = [manager.wallet transactionForAmounts:protoReq.details.outputAmounts
//                                           toOutputScripts:protoReq.details.outputScripts withUnlockHeights:protoReq.details.outputUnlockHeights withReserves:protoReq.details.outputReserves withFee:YES isInstant:wantsInstant toShapeshiftAddress:nil];
                NSNumber *amountNumber;
                NSMutableData *reserveData = [NSMutableData data];
                BRBalanceModel *codeBalanceModel = [self returnCodeBalanceModel];
                if(codeBalanceModel.assetId.length != 0) {
                    amountNumber = @(self.payRequest.amount / (pow(10, 8-codeBalanceModel.multiple)));
                    codeBalanceModel.common.amount = self.payRequest.amount / (pow(10, 8-codeBalanceModel.multiple));
                    reserveData = [NSMutableData dataWithData:[BRSafeUtils generateTransferredAssetData:codeBalanceModel]];
                } else {
                    amountNumber = @(self.payRequest.amount);
                    reserveData = [NSMutableData dataWithData:protoReq.details.outputReserves.firstObject];
                }
                tx = [manager.wallet transactionForAmounts:@[amountNumber] toOutputScripts:@[protoReq.details.outputScripts.firstObject] withUnlockHeights:@[protoReq.details.outputUnlockHeights.firstObject] withReserves:@[reserveData] withFee:YES isInstant:wantsInstant toShapeshiftAddress:nil BalanceModel:codeBalanceModel];
            }
        }
        else {
            if (shapeshift) {
                tx = [manager.wallet transactionForAmounts:@[@(self.amount)]
                                           toOutputScripts:@[protoReq.details.outputScripts.firstObject] withUnlockHeights:@[protoReq.details.outputUnlockHeights.firstObject] withReserves:@[protoReq.details.outputReserves.firstObject] withFee:YES isInstant:wantsInstant toShapeshiftAddress:shapeshift.withdrawalAddress];
                tx.associatedShapeshift = shapeshift;
            } else {
                // TODO: 修改交易信息
//                tx = [manager.wallet transactionForAmounts:@[@(self.amount)]
//                                           toOutputScripts:@[protoReq.details.outputScripts.firstObject] withUnlockHeights:@[protoReq.details.outputUnlockHeights.firstObject] withReserves:@[protoReq.details.outputReserves.firstObject] withFee:YES isInstant:wantsInstant toShapeshiftAddress:nil];
                NSNumber *amountNumber;
                NSMutableData *reserveData = [NSMutableData data];
                if(self.balanceModel.assetId.length != 0) {
                    amountNumber = @(self.amount);
                    self.balanceModel.common.amount = self.amount;
                    reserveData = [NSMutableData dataWithData:[BRSafeUtils generateTransferredAssetData:self.balanceModel]];
                } else {
                    amountNumber = @(self.amount);
                    reserveData = [NSMutableData dataWithData:protoReq.details.outputReserves.firstObject];
                }
                tx = [manager.wallet transactionForAmounts:@[amountNumber] toOutputScripts:@[protoReq.details.outputScripts.firstObject] withUnlockHeights:@[protoReq.details.outputUnlockHeights.firstObject] withReserves:@[reserveData] withFee:YES isInstant:wantsInstant toShapeshiftAddress:nil BalanceModel:self.balanceModel];
            }
        }
        
        if (tx) {
            amount = [manager.wallet amountSentByTransaction:tx] - [manager.wallet amountReceivedFromTransaction:tx];
            fee = [manager.wallet feeForTransaction:tx];
//            BRLog(@"fee == %llu",fee);
            BRBalanceModel *nowBalanceModel = self.payRequest.amount > 0 ? [self returnCodeBalanceModel] : self.balanceModel;
            if (wantsInstant && amount >= 1000 * pow(10, nowBalanceModel.multiple)) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Message", nil) message:NSLocalizedString(@"The maximum amount of instant payment cannot be greater than 1000,please send it multiple times.", nil) preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction *sure = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:nil];
                [alert addAction:sure];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }
        }
        else {
            //TODO: 修改 manager.wallet.balance
//            BRBalanceModel *nowBalanceModel = self.payRequest.amount > 0 ? [self returnCodeBalanceModel] : self.balanceModel;
//            BRTransaction * tempTx = [manager.wallet transactionFor:nowBalanceModel.balance to:address withFee:NO];
//            fee = [manager.wallet feeForTxSize:tempTx.size isInstant:self.sendInstantly inputCount:tempTx.inputHashes.count];
//            fee += (nowBalanceModel.balance - amount) % 100;
//            amount += fee;
            // 可用资金不足
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"insufficient funds", nil)
                                         message:nil
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* okButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"ok", nil)
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                           
                                       }];
            [alert addAction:okButton];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        
        for (NSData *script in protoReq.details.outputScripts) {
            NSString *addr = [NSString addressWithScriptPubKey:script];
            
            if (! addr) addr = NSLocalizedString(@"unrecognized address", nil);
            if ([address rangeOfString:addr].location != NSNotFound) continue;
            address = [address stringByAppendingFormat:@"%@%@", (address.length > 0) ? @", " : @"", addr];
        }
        
        NSString *prompt;
        BRBalanceModel *nowBalanceModel = self.payRequest.amount > 0 ? [self returnCodeBalanceModel] : self.balanceModel;
        if(nowBalanceModel.assetId.length != 0) {
            prompt = [self promptAssetForAmount:(amount > fee ? amount : ( self.amount > 0 ? self.amount + fee : self.payRequest.amount / pow(10, 8 - nowBalanceModel.multiple) + fee)) fee:fee address:address name:protoReq.commonName
                                      memo:protoReq.details.memo isSecure:(valid && ! [protoReq.pkiType isEqual:@"none"])];
        } else {
            prompt = [self promptForAmount:(amount > fee ? amount : ( self.amount > 0 ? self.amount + fee : self.payRequest.amount / pow(10, 8 - nowBalanceModel.multiple) + fee)) fee:fee address:address name:protoReq.commonName
                                                memo:protoReq.details.memo isSecure:(valid && ! [protoReq.pkiType isEqual:@"none"])];
        }
//            NSString *prompt = [self promptForAmount:amount fee:fee address:address name:protoReq.commonName
//                                            memo:protoReq.details.memo isSecure:(valid && ! [protoReq.pkiType isEqual:@"none"])];
            
        
        // to avoid the frozen pincode keyboard bug, we need to make sure we're scheduled normally on the main runloop
        // rather than a dispatch_async queue
        if(nowBalanceModel.assetId.length == 0) {
            CFRunLoopPerformBlock([[NSRunLoop mainRunLoop] getCFRunLoop], kCFRunLoopCommonModes, ^{
                [self confirmTransaction:tx toAddress:address withPrompt:prompt forAmount:(amount > fee ? amount : ( self.amount > 0 ? self.amount + fee : self.payRequest.amount / pow(10, 8 - nowBalanceModel.multiple) + fee))];
            });
        } else {
            CFRunLoopPerformBlock([[NSRunLoop mainRunLoop] getCFRunLoop], kCFRunLoopCommonModes, ^{
                [self confirmTransaction:tx toAddress:address withPrompt:prompt forAmount:fee];
            });

        }
//        CFRunLoopPerformBlock([[NSRunLoop mainRunLoop] getCFRunLoop], kCFRunLoopCommonModes, ^{
//            [self confirmTransaction:tx toAddress:address withPrompt:prompt forAmount:amount];
//        });
    } else if ([currency isEqualToString:@"bitcoin"]) {
        NSString *address = [NSString bitcoinAddressWithScriptPubKey:protoReq.details.outputScripts.firstObject];
        if (protoReq.errorMessage.length > 0 && protoReq.commonName.length > 0 &&
            ! [self.okIdentity isEqual:protoReq.commonName]) {
            self.request = protoReq;
            self.shapeshiftRequest = protoReq;
            self.scheme = currency;
            self.associatedShapeshift = shapeshift;
            self.okIdentity = protoReq.commonName;
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"payee identity isn't certified", nil)
                                         message:protoReq.errorMessage
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* ignoreButton = [UIAlertAction
                                           actionWithTitle:NSLocalizedString(@"ignore", nil)
                                           style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction * action) {
                                               [self confirmProtocolRequest:self.request currency:self.scheme associatedShapeshift:self.associatedShapeshift];
                                           }];
            UIAlertAction* cancelButton = [UIAlertAction
                                           actionWithTitle:NSLocalizedString(@"cancel", nil)
                                           style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction * action) {
                                               [self cancelOrChangeAmount];
                                           }];
            
            [alert addAction:ignoreButton];
            [alert addAction:cancelButton];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        else if (amount == 0 || amount == UINT64_MAX) {
            BRAmountViewController *c = [self.storyboard instantiateViewControllerWithIdentifier:@"AmountViewController"];
            self.scheme = currency;
            c.usingShapeshift = TRUE;
            c.delegate = self;
            self.request = protoReq;
            self.shapeshiftRequest = protoReq;
            self.associatedShapeshift = shapeshift;
            if (protoReq.commonName.length > 0) {
                if (valid && ! [protoReq.pkiType isEqual:@"none"]) {
                    c.to = [LOCK @" " stringByAppendingString:sanitizeString(address)];
                }
                else if (protoReq.errorMessage.length > 0) {
                    c.to = [REDX @" " stringByAppendingString:sanitizeString(address)];
                }
                else c.to = sanitizeString(shapeshift.withdrawalAddress);
            }
            else c.to = address;
            BRWalletManager *manager = [BRWalletManager sharedInstance];
            c.navigationItem.titleView = [self titleLabel];
            [self.navigationController pushViewController:c animated:YES];
            return;
        }
        else if (amount < TX_MIN_OUTPUT_AMOUNT) {
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"couldn't make payment", nil)
                                         message:[NSString stringWithFormat:NSLocalizedString(@"bitcoin payments can't be less than %@", nil),
                                                  [manager stringForBitcoinAmount:TX_MIN_OUTPUT_AMOUNT]]
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* okButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"ok", nil)
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                           
                                       }];
            
            
            [alert addAction:okButton];
            [self presentViewController:alert animated:YES completion:nil];
            [self cancel:nil];
            return;
        }
        else if (outputTooSmall) {
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"couldn't make payment", nil)
                                         message:[NSString stringWithFormat:NSLocalizedString(@"dash transaction outputs can't be less than %@",
                                                                                              nil), [manager stringForDashAmount:TX_MIN_OUTPUT_AMOUNT]]
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* okButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"ok", nil)
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                           
                                       }];
            
            
            [alert addAction:okButton];
            [self presentViewController:alert animated:YES completion:nil];
            [self cancel:nil];
            return;
        }
        self.request = protoReq;
        self.shapeshiftRequest = protoReq;
        self.scheme = currency;
        [self amountViewController:nil shapeshiftBitcoinAmount:amount approximateDashAmount:1.03*amount/manager.bitcoinDashPrice.doubleValue];
    }
}

- (BRBalanceModel *) returnCodeBalanceModel {
    for (int i=0; i<[BRWalletManager sharedInstance].wallet.balanceArray.count; i++) {
        BRBalanceModel *codeBalanceModel = [BRWalletManager sharedInstance].wallet.balanceArray[i];
        if(self.payRequest.assetName.length == 0) {
            if(codeBalanceModel.assetId.length == 0) {
                return codeBalanceModel;
            }
        } else {
            if([codeBalanceModel.nameString isEqualToString:self.payRequest.assetName]) {
                return codeBalanceModel;
            }
        }
    }
    return nil;
}

-(void)insufficientFundsForTransaction:(BRTransaction *)tx forAmount:(uint64_t)amount {
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    uint64_t fuzz = [manager amountForLocalCurrencyString:[manager localCurrencyStringForDashAmount:1]]*2;
    
    // if user selected an amount equal to or below wallet balance, but the fee will bring the total above the
    // balance, offer to reduce the amount to available funds minus fee
    if (self.amount <= self.balanceModel.balance + fuzz && self.amount > 0) {  // TODO: 修改数据 manager.wallet.balance
        int64_t amount = [manager.wallet maxOutputAmountUsingInstantSend:tx.isInstant];
        
        if (amount > 0 && amount < self.amount) {
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"insufficient funds for dash network fee", nil)
                                         message:[NSString stringWithFormat:NSLocalizedString(@"reduce payment amount by\n%@?", nil),
                                                  [manager stringForDashAmount:self.amount - amount]]
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* cancelButton = [UIAlertAction
                                           actionWithTitle:NSLocalizedString(@"cancel", nil)
                                           style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction * action) {
                                               [self cancelOrChangeAmount];
                                           }];
            UIAlertAction* reduceButton = [UIAlertAction
                                           actionWithTitle:[NSString stringWithFormat:@"%@ (%@)",
                                                            [manager stringForDashAmount:amount - self.amount],
                                                            [manager localCurrencyStringForDashAmount:amount - self.amount]]
                                           style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction * action) {
                                               [self confirmProtocolRequest:self.request currency:self.scheme associatedShapeshift:self.associatedShapeshift];
                                           }];
            
            
            [alert addAction:cancelButton];
            [alert addAction:reduceButton];
            [self presentViewController:alert animated:YES completion:nil];
            self.amount = amount;
        }
        else {
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"insufficient funds for dash network fee", nil)
                                         message:nil
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* okButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"ok", nil)
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                           
                                       }];
            
            
            [alert addAction:okButton];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }
    else {
        UIAlertController * alert = [UIAlertController
                                     alertControllerWithTitle:NSLocalizedString(@"insufficient funds", nil)
                                     message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* okButton = [UIAlertAction
                                   actionWithTitle:NSLocalizedString(@"ok", nil)
                                   style:UIAlertActionStyleCancel
                                   handler:^(UIAlertAction * action) {
                                       
                                   }];
        [alert addAction:okButton];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)confirmTransaction:(BRTransaction *)tx toAddress:(NSString*)address withPrompt:(NSString *)prompt forAmount:(uint64_t)amount
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    __block BOOL previouslyWasAuthenticated = manager.didAuthenticate;
    
    if (! tx) { // tx is nil if there were insufficient wallet funds
        if (manager.didAuthenticate) {
            [self insufficientFundsForTransaction:tx forAmount:amount];
        } else {
            [manager seedWithPrompt:prompt forAmount:amount completion:^(NSData * _Nullable seed) {
                if (seed) {
                    [self insufficientFundsForTransaction:tx forAmount:amount];
                } else {
                    [self cancelOrChangeAmount];
                }
                if (!previouslyWasAuthenticated) manager.didAuthenticate = NO;
            }];
        }
    } else {

        [manager.wallet signTransaction:tx withPrompt:prompt amount:amount completion:^(BOOL signedTransaction) {
            if (!signedTransaction) {
                UIAlertController * alert = [UIAlertController
                                             alertControllerWithTitle:NSLocalizedString(@"couldn't make payment", nil)
                                             message:NSLocalizedString(@"error signing dash transaction", nil)
                                             preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction* okButton = [UIAlertAction
                                           actionWithTitle:NSLocalizedString(@"ok", nil)
                                           style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction * action) {
                                               
                                           }];
                [alert addAction:okButton];
                [self presentViewController:alert animated:YES completion:nil];
            } else {
                
                if (!previouslyWasAuthenticated) manager.didAuthenticate = NO;
                
                if (!tx.isSigned) { // double check
                    [self cancelOrChangeAmount];
                    return;
                }
                
                //[self.navigationController popViewControllerAnimated:YES];
                
                __block BOOL waiting = YES, sent = NO;
                
                [(id)self.parentViewController.parentViewController.parentViewController startActivityWithTimeout:30.0];
                
                [[BRPeerManager sharedInstance] publishTransaction:tx completion:^(NSError *error) {
                    if (error) {
                        if (! waiting && ! sent) {
                            UIAlertController * alert = [UIAlertController
                                                         alertControllerWithTitle:NSLocalizedString(@"couldn't make payment", nil)
                                                         message:error.localizedDescription
                                                         preferredStyle:UIAlertControllerStyleAlert];
                            UIAlertAction* okButton = [UIAlertAction
                                                       actionWithTitle:NSLocalizedString(@"ok", nil)
                                                       style:UIAlertActionStyleCancel
                                                       handler:^(UIAlertAction * action) {
                                                           
                                                       }];
                            [alert addAction:okButton];
                            [self presentViewController:alert animated:YES completion:nil];
                            [(id)self.parentViewController.parentViewController.parentViewController stopActivityWithSuccess:NO];
                            [self cancel:nil];
                        }
                    }
                    else if (! sent) { //TODO: show full screen sent dialog with tx info, "you sent b10,000 to bob"
                        if (tx.associatedShapeshift) {
                            [self startObservingShapeshift:tx.associatedShapeshift];
                            
                        }
                        sent = YES;
                        tx.timestamp = [NSDate timeIntervalSinceReferenceDate];
                        [manager.wallet registerTransaction:tx];
                        [self.view addSubview:[[[BRBubbleView viewWithText:NSLocalizedString(@"sent!", nil)
                                                                    center:CGPointMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2)] popIn]
                                               popOutAfterDelay:2.0]];
                        [(id)self.parentViewController.parentViewController.parentViewController stopActivityWithSuccess:YES];
                        [(id)self.parentViewController.parentViewController.parentViewController ping];
                        
                        
                        if (self.request.callbackScheme) {
                            NSURL * callback = [NSURL URLWithString:[self.request.callbackScheme
                                                                     stringByAppendingFormat:@"://callback=payack&address=%@&txid=%@",address,
                                                                     [NSString hexWithData:[NSData dataWithBytes:tx.txHash.u8
                                                                                                          length:sizeof(UInt256)].reverse]]];
                            [[UIApplication sharedApplication] openURL:callback options:@{} completionHandler:^(BOOL success) {
                                
                            }];
                        }
                        
                        [self reset:nil];
                    }
                    
                    waiting = NO;
                }];
                
                if (self.request.details.paymentURL.length > 0) {
                    uint64_t refundAmount = 0;
                    NSMutableData *refundScript = [NSMutableData data];
                    
                    [refundScript appendScriptPubKeyForAddress:manager.wallet.receiveAddress];
                    
                    for (NSNumber *amt in self.request.details.outputAmounts) {
                        refundAmount += amt.unsignedLongLongValue;
                    }
                    
                    // TODO: keep track of commonName/memo to associate them with outputScripts
                    BRPaymentProtocolPayment *payment =
                    [[BRPaymentProtocolPayment alloc] initWithMerchantData:self.request.details.merchantData
                                                              transactions:@[tx] refundToAmounts:@[@(refundAmount)] refundToScripts:@[refundScript] memo:nil];
                    
                    //BRLog(@"posting payment to: %@", self.request.details.paymentURL);
                    
                    [BRPaymentRequest postPayment:payment scheme:@"safe" to:self.request.details.paymentURL timeout:20.0
                                       completion:^(BRPaymentProtocolACK *ack, NSError *error) {
                                           dispatch_async(dispatch_get_main_queue(), ^{
                                               [(id)self.parentViewController.parentViewController.parentViewController stopActivityWithSuccess:(! error)];
                                               
                                               if (error) {
                                                   if (! waiting && ! sent) {
                                                       UIAlertController * alert = [UIAlertController
                                                                                    alertControllerWithTitle:@""
                                                                                    message:error.localizedDescription
                                                                                    preferredStyle:UIAlertControllerStyleAlert];
                                                       UIAlertAction* okButton = [UIAlertAction
                                                                                  actionWithTitle:NSLocalizedString(@"ok", nil)
                                                                                  style:UIAlertActionStyleCancel
                                                                                  handler:^(UIAlertAction * action) {
                                                                                      
                                                                                  }];
                                                       [alert addAction:okButton];
                                                       [self presentViewController:alert animated:YES completion:nil];
                                                       [(id)self.parentViewController.parentViewController.parentViewController stopActivityWithSuccess:NO];
                                                       [self cancel:nil];
                                                   }
                                               }
                                               else if (! sent) {
                                                   sent = YES;
                                                   tx.timestamp = [NSDate timeIntervalSinceReferenceDate];
                                                   [manager.wallet registerTransaction:tx];
                                                   [self.view addSubview:[[[BRBubbleView
                                                                            viewWithText:(ack.memo.length > 0 ? ack.memo : NSLocalizedString(@"sent!", nil))
                                                                            center:CGPointMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2)] popIn]
                                                                          popOutAfterDelay:(ack.memo.length > 0 ? 3.0 : 2.0)]];
                                                   [(id)self.parentViewController.parentViewController.parentViewController stopActivityWithSuccess:YES];
                                                   [(id)self.parentViewController.parentViewController.parentViewController ping];
                                                   if (self.request.callbackScheme) {
                                                       NSURL * callback = [NSURL URLWithString:[self.request.callbackScheme
                                                                                                stringByAppendingFormat:@"://callback=payack&address=%@&txid=%@",address,
                                                                                                [NSString hexWithData:[NSData dataWithBytes:tx.txHash.u8
                                                                                                                                     length:sizeof(UInt256)].reverse]]];
                                                       [[UIApplication sharedApplication] openURL:callback options:@{} completionHandler:^(BOOL success) {
                                                           
                                                       }];
                                                   }
                                                   
                                                   [self reset:nil];
                                               }
                                               
                                               waiting = NO;
                                           });
                                       }];
                }
                else waiting = NO;
            }
        }];
    }
}

- (void)confirmSweep:(NSString *)privKey
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    
    if (! [privKey isValidDashPrivateKey] && ! [privKey isValidDashBIP38Key]) return;
    
    BRBubbleView *statusView = [BRBubbleView viewWithText:NSLocalizedString(@"checking private key balance...", nil)
                                                   center:CGPointMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2)];
    
    statusView.font = [UIFont systemFontOfSize:15.0];
    statusView.customView = [[UIActivityIndicatorView alloc]
                             initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    [(id)statusView.customView startAnimating];
    [self.view addSubview:[statusView popIn]];
    
    [manager sweepPrivateKey:privKey withFee:YES completion:^(BRTransaction *tx, uint64_t fee, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [statusView popOut];
            
            if (error) {
                UIAlertController * alert = [UIAlertController
                                             alertControllerWithTitle:@""
                                             message:error.localizedDescription
                                             preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction* okButton = [UIAlertAction
                                           actionWithTitle:NSLocalizedString(@"ok", nil)
                                           style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction * action) {
                                           }];
                [alert addAction:okButton];
                [self presentViewController:alert animated:YES completion:nil];
                [self cancel:nil];
            }
            else if (tx) {
                uint64_t amount = fee;
                
                for (NSNumber *amt in tx.outputAmounts) amount += amt.unsignedLongLongValue;
                self.sweepTx = tx;
                
                NSString *alertFmt = NSLocalizedString(@"Send %@ (%@) from this private key into your wallet? "
                                                       "The dash network will receive a fee of %@ (%@).", nil);
                NSString *alertMsg = [NSString stringWithFormat:alertFmt, [manager stringForDashAmount:amount],
                                      [manager localCurrencyStringForDashAmount:amount], [manager stringForDashAmount:fee],
                                      [manager localCurrencyStringForDashAmount:fee]];
                
                UIAlertController * alert = [UIAlertController
                                             alertControllerWithTitle:@""
                                             message:alertMsg
                                             preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction* cancelButton = [UIAlertAction
                                               actionWithTitle:NSLocalizedString(@"cancel", nil)
                                               style:UIAlertActionStyleCancel
                                               handler:^(UIAlertAction * action) {
                                                   [self cancelOrChangeAmount];
                                               }];
                UIAlertAction* amountButton = [UIAlertAction
                                               actionWithTitle:[NSString stringWithFormat:@"%@ (%@)", [manager stringForDashAmount:amount],
                                                                [manager localCurrencyStringForDashAmount:amount]]
                                               style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction * action) {
                                                   [(id)self.parentViewController.parentViewController.parentViewController startActivityWithTimeout:30];
                                                   
                                                   [[BRPeerManager sharedInstance] publishTransaction:self.sweepTx completion:^(NSError *error) {
                                                       [(id)self.parentViewController.parentViewController.parentViewController stopActivityWithSuccess:(! error)];
                                                       
                                                       if (error) {
                                                           UIAlertController * alert = [UIAlertController
                                                                                        alertControllerWithTitle:NSLocalizedString(@"couldn't sweep balance", nil)
                                                                                        message:error.localizedDescription
                                                                                        preferredStyle:UIAlertControllerStyleAlert];
                                                           
                                                           UIAlertAction* okButton = [UIAlertAction
                                                                                      actionWithTitle:NSLocalizedString(@"ok", nil)
                                                                                      style:UIAlertActionStyleCancel
                                                                                      handler:^(UIAlertAction * action) {
                                                                                      }];
                                                           [alert addAction:okButton];
                                                           [self presentViewController:alert animated:YES completion:nil];
                                                           [self cancel:nil];
                                                           return;
                                                       }
                                                       
                                                       [self.view addSubview:[[[BRBubbleView viewWithText:NSLocalizedString(@"swept!", nil)
                                                                                                   center:CGPointMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2)]
                                                                               popIn] popOutAfterDelay:2.0]];
                                                       [self reset:nil];
                                                   }];
                                                   
                                               }];
                [alert addAction:amountButton];
                [alert addAction:cancelButton];
                [self presentViewController:alert animated:YES completion:nil];
            }
            else [self cancel:nil];
        });
    }];
}

- (void)showBalance:(NSString *)address
{
    if (! [address isValidBitcoinAddress]) return;
    
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    BRBubbleView *statusView = [BRBubbleView viewWithText:NSLocalizedString(@"checking address balance...", nil)
                                                   center:CGPointMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2)];
    
    statusView.font = [UIFont systemFontOfSize:15.0];
    statusView.customView = [[UIActivityIndicatorView alloc]
                             initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    [(id)statusView.customView startAnimating];
    [self.view addSubview:[statusView popIn]];
    
    [manager utxosForAddresses:@[address]
                    completion:^(NSArray *utxos, NSArray *amounts, NSArray *scripts, NSError *error) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [statusView popOut];
                            
                            if (error) {
                                UIAlertController * alert = [UIAlertController
                                                             alertControllerWithTitle:NSLocalizedString(@"couldn't check address balance", nil)
                                                             message:error.localizedDescription
                                                             preferredStyle:UIAlertControllerStyleAlert];
                                UIAlertAction* okButton = [UIAlertAction
                                                           actionWithTitle:NSLocalizedString(@"ok", nil)
                                                           style:UIAlertActionStyleCancel
                                                           handler:^(UIAlertAction * action) {
                                                           }];
                                [alert addAction:okButton];
                                [self presentViewController:alert animated:YES completion:nil];
                            }
                            else {
                                uint64_t balance = 0;
                                
                                for (NSNumber *amt in amounts) balance += amt.unsignedLongLongValue;
                                
                                NSString *alertMsg = [NSString stringWithFormat:NSLocalizedString(@"%@\n\nbalance: %@ (%@)", nil),
                                                      address, [manager stringForDashAmount:balance],
                                                      [manager localCurrencyStringForDashAmount:balance]];
                                
                                UIAlertController * alert = [UIAlertController
                                                             alertControllerWithTitle:@""
                                                             message:alertMsg
                                                             preferredStyle:UIAlertControllerStyleAlert];
                                UIAlertAction* okButton = [UIAlertAction
                                                           actionWithTitle:NSLocalizedString(@"ok", nil)
                                                           style:UIAlertActionStyleCancel
                                                           handler:^(UIAlertAction * action) {
                                                           }];
                                [alert addAction:okButton];
                                [self presentViewController:alert animated:YES completion:nil];
                            }
                        });
                    }];
}

- (void)cancelOrChangeAmount
{
    if (self.canChangeAmount && self.request && self.amount == 0) {
        UIAlertController * alert = [UIAlertController
                                     alertControllerWithTitle:NSLocalizedString(@"change payment amount?", nil)
                                     message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* cancelButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"cancel",nil)
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                           [self cancel:nil];
                                       }];
        UIAlertAction* changeButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"change",nil)
                                       style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction * action) {
                                           
                                       }];
        [alert addAction:cancelButton];
        [alert addAction:changeButton];
        [self presentViewController:alert animated:YES completion:nil];
        self.amount = UINT64_MAX;
    }
    else [self cancel:nil];
}

//- (void)hideTips
//{
//    if (self.tipView.alpha > 0.5) [self.tipView popOut];
//}
//
//- (BOOL)nextTip
//{
//    if (self.tipView.alpha < 0.5) return [(id)self.parentViewController.parentViewController nextTip];
//
//    BRBubbleView *tipView = self.tipView;
//
//    self.tipView = nil;
//    [tipView popOut];
//
//    if ([tipView.text hasPrefix:SCAN_TIP]) {
//        self.tipView = [BRBubbleView viewWithText:CLIPBOARD_TIP
//                                         tipPoint:CGPointMake(self.clipboardButton.center.x, self.clipboardButton.center.y + 10.0)
//                                     tipDirection:BRBubbleTipDirectionUp];
//        self.tipView.backgroundColor = tipView.backgroundColor;
//        self.tipView.font = tipView.font;
//        self.tipView.userInteractionEnabled = NO;
//        [self.view addSubview:[self.tipView popIn]];
//    }
//    else if (self.showTips && [tipView.text hasPrefix:CLIPBOARD_TIP]) {
//        self.showTips = NO;
//        [(id)self.parentViewController.parentViewController tip:self];
//    }
//    
//    return YES;
//}

- (void)resetQRGuide
{
    self.scanController.message.text = nil;
    self.scanController.cameraGuide.image = [UIImage imageNamed:@"cameraguide"];
}

- (void)updateClipboardText
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *str = [[UIPasteboard generalPasteboard].string
                         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *text = @"";
        UIImage *img = [UIPasteboard generalPasteboard].image;
        NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSet];
        NSCharacterSet *separators = [NSCharacterSet alphanumericCharacterSet].invertedSet;
        
        if (str) {
            [set addObject:str];
            [set addObjectsFromArray:[str componentsSeparatedByCharactersInSet:separators]];
        }
        
        if (img) {
            @synchronized ([CIContext class]) {
                CIContext *context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@(YES)}];
                
                if (! context) context = [CIContext context];
                
                for (CIQRCodeFeature *qr in [[CIDetector detectorOfType:CIDetectorTypeQRCode context:context
                                                                options:nil] featuresInImage:[CIImage imageWithCGImage:img.CGImage]]) {
                    [set addObject:[qr.messageString
                                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
                }
            }
        }
        
        for (NSString *s in set) {
            BRPaymentRequest *req = [BRPaymentRequest requestWithString:s];
            
            if ([req.paymentAddress isValidBitcoinAddress]) {
                text = (req.label.length > 0) ? sanitizeString(req.label) : req.paymentAddress;
                break;
            }
            else if ([s hasPrefix:@"bitcoin:"]) {
                text = sanitizeString(s);
                break;
            }
        }
    });
}

- (void)payFirstFromArray:(NSArray *)array
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    NSUInteger i = 0;
    
    for (NSString *str in array) {
        BRPaymentRequest *req = [BRPaymentRequest requestWithString:str];
        self.payRequest = req;
        NSData *data = str.hexToData.reverse;
        
        i++;
        
        // if the clipboard contains a known txHash, we know it's not a hex encoded private key
        if (data.length == sizeof(UInt256) && [manager.wallet transactionForHash:*(UInt256 *)data.bytes]) continue;
        
        if ([req.paymentAddress isValidBitcoinAddress] || [req.paymentAddress isValidDashAddress] || [str isValidBitcoinPrivateKey] || [str isValidDashPrivateKey] || [str isValidBitcoinBIP38Key] || [str isValidDashBIP38Key] ||
            (req.r.length > 0 && ([req.scheme isEqual:@"bitcoin:"] || [req.scheme isEqual:@"safe:"]))) {
            [self performSelector:@selector(confirmRequest:) withObject:req afterDelay:0.1];// delayed to show highlight
            return;
        }
        else if (req.r.length > 0) { // may be BIP73 url: https://github.com/bitcoin/bips/blob/master/bip-0073.mediawiki
            [BRPaymentRequest fetch:req.r scheme:req.scheme timeout:5.0 completion:^(BRPaymentProtocolRequest *req, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (error) { // don't try any more BIP73 urls
                        [self payFirstFromArray:[array objectsAtIndexes:[array
                                                                         indexesOfObjectsPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
                                                                             return (idx >= i && ([obj hasPrefix:@"safe:"] || ! [NSURL URLWithString:obj]));
                                                                         }]]];
                    }
                    else [self confirmProtocolRequest:req];
                });
            }];
            
            return;
        }
    }
    UIAlertController * alert = [UIAlertController
                                 alertControllerWithTitle:@""
                                 message:NSLocalizedString(@"clipboard doesn't contain a valid dash or bitcoin address", nil)
                                 preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okButton = [UIAlertAction
                               actionWithTitle:NSLocalizedString(@"ok", nil)
                               style:UIAlertActionStyleCancel
                               handler:^(UIAlertAction * action) {
                               }];
    [alert addAction:okButton];
    [self presentViewController:alert animated:YES completion:nil];
    [self performSelector:@selector(cancel:) withObject:self afterDelay:0.1];
}

-(UILabel*)titleLabel {
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    UILabel * titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 1, 100)];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [titleLabel setBackgroundColor:[UIColor clearColor]];
    NSMutableAttributedString * attributedDashString = [[manager attributedStringForDashAmount:manager.wallet.balance withTintColor:[UIColor whiteColor]] mutableCopy];
    NSString * titleString = [NSString stringWithFormat:@" (%@)",
                              [manager localCurrencyStringForDashAmount:manager.wallet.balance]];
    [attributedDashString appendAttributedString:[[NSAttributedString alloc] initWithString:titleString attributes:@{NSForegroundColorAttributeName:[UIColor whiteColor]}]];
    titleLabel.attributedText = attributedDashString;
    return titleLabel;
}

-(void)updateTitleView {
    if (self.navigationItem.titleView && [self.navigationItem.titleView isKindOfClass:[UILabel class]]) {
        BRWalletManager *manager = [BRWalletManager sharedInstance];
        NSMutableAttributedString * attributedDashString = [[manager attributedStringForDashAmount:manager.wallet.balance withTintColor:[UIColor whiteColor]] mutableCopy];
        NSString * titleString = [NSString stringWithFormat:@" (%@)",
                                  [manager localCurrencyStringForDashAmount:manager.wallet.balance]];
        [attributedDashString appendAttributedString:[[NSAttributedString alloc] initWithString:titleString attributes:@{NSForegroundColorAttributeName:[UIColor whiteColor]}]];
        ((UILabel*)self.navigationItem.titleView).attributedText = attributedDashString;
        [((UILabel*)self.navigationItem.titleView) sizeToFit];
    } else {
        self.navigationItem.titleView = [self titleLabel];
    }
}

#pragma mark - Shapeshift

-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    DSShapeshiftEntity * shapeshift = (DSShapeshiftEntity *)object;
    switch ([shapeshift.shapeshiftStatus integerValue]) {
        case eShapeshiftAddressStatus_Complete:
        {
            NSArray * shapeshiftsInProgress = [DSShapeshiftEntity shapeshiftsInProgress];
            if (![shapeshiftsInProgress count]) {
                self.shapeshiftLabel.text = shapeshift.shapeshiftStatusString;
                self.shapeshiftView.hidden = TRUE;
            }
            [self.view addSubview:[[[BRBubbleView viewWithText:NSLocalizedString(@"shapeshift succeeded", nil)
                                                        center:CGPointMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2)] popIn]
                                   popOutAfterDelay:2.0]];
            break;
        }
        case eShapeshiftAddressStatus_Received:
            self.shapeshiftLabel.text = shapeshift.shapeshiftStatusString;
        default:
            break;
    }
}


-(void)startObservingShapeshift:(DSShapeshiftEntity*)shapeshift {
    
    [shapeshift addObserver:self forKeyPath:@"shapeshiftStatus" options:NSKeyValueObservingOptionNew context:nil];
    [shapeshift routinelyCheckStatusAtInterval:10];
    self.shapeshiftView.hidden = FALSE;
}


// MARK: - IBAction

//- (IBAction)tip:(id)sender
//{
//    if ([self nextTip]) return;
//
//    if (! [sender isKindOfClass:[UIGestureRecognizer class]] || ! [[sender view] isKindOfClass:[UILabel class]]) {
//        if (! [sender isKindOfClass:[UIViewController class]]) return;
//        self.showTips = YES;
//    }
//
//    self.tipView = [BRBubbleView viewWithText:SCAN_TIP
//                                     tipPoint:CGPointMake(self.scanButton.center.x, self.scanButton.center.y - 10.0)
//                                 tipDirection:BRBubbleTipDirectionDown];
//    self.tipView.font = [UIFont systemFontOfSize:15.0];
//    [self.view addSubview:[self.tipView popIn]];
//}

- (IBAction)enableInstantX:(id)sender {
    self.sendInstantly = ((UISwitch*)sender).isOn;
    [[NSUserDefaults standardUserDefaults] setBool:self.sendInstantly forKey:SEND_INSTANTLY_KEY];
}

- (IBAction)scanQR:(id)sender
{
    //if ([self nextTip]) return;
    [BREventManager saveEvent:@"send:scan_qr"];
    if (! [sender isEqual:self.scanButton]) self.showBalance = YES;
    [sender setEnabled:NO];
    self.scanController.delegate = self;
    self.scanController.transitioningDelegate = self;
    [self.navigationController presentViewController:self.scanController animated:YES completion:nil];
}

- (IBAction)payToClipboard:(id)sender
{
    //if ([self nextTip]) return;
    [BREventManager saveEvent:@"send:pay_clipboard"];
    
    NSString *str = [[UIPasteboard generalPasteboard].string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    UIImage *img = [UIPasteboard generalPasteboard].image;
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSet];
    NSCharacterSet *separators = [NSCharacterSet alphanumericCharacterSet].invertedSet;
    
    if (str) {
        [set addObject:str];
        [set addObjectsFromArray:[str componentsSeparatedByCharactersInSet:separators]];
    }
    
    if (img) {
        @synchronized ([CIContext class]) {
            CIContext *context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@(YES)}];
            
            if (! context) context = [CIContext context];
            
            for (CIQRCodeFeature *qr in [[CIDetector detectorOfType:CIDetectorTypeQRCode context:context options:nil]
                                         featuresInImage:[CIImage imageWithCGImage:img.CGImage]]) {
                [set addObject:[qr.messageString
                                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
            }
        }
    }
    
    [sender setEnabled:NO];
    //self.clearClipboard = YES;
    [self payFirstFromArray:set.array];
}

- (IBAction)reset:(id)sender
{
    [self.navigationController popViewControllerAnimated:YES];
    [BREventManager saveEvent:@"send:reset"];
    
    if (self.clearClipboard) [UIPasteboard generalPasteboard].string = @"";
    self.request = nil;
    self.shapeshiftRequest = nil;
    self.scheme = nil;
    [self cancel:sender];
}

- (IBAction)cancel:(id)sender
{
    [BREventManager saveEvent:@"send:cancel"];
    self.url = nil;
    self.sweepTx = nil;
    self.amount = 0;
    self.okAddress = self.okIdentity = nil;
    self.clearClipboard = self.useClipboard = NO;
    self.canChangeAmount = self.showBalance = NO;
    self.scanButton.enabled = self.clipboardButton.enabled = YES;
    [self updateClipboardText];
}

// MARK: - BRAmountViewControllerDelegate

- (void)amountViewController:(BRAmountViewController *)amountViewController selectedAmount:(uint64_t)amount
{
    self.amount = amount / pow(10, 8 - self.balanceModel.multiple);
    [self confirmProtocolRequest:self.request];
}

- (void)amountViewController:(BRAmountViewController *)amountViewController selectedAmount:(uint64_t)amount unlockBlockHeight:(uint64_t)blockHeight {
    self.amount = amount / pow(10, 8 - self.balanceModel.multiple);
    self.payRequest.unlockBlockHeight = blockHeight + 1 + (uint64_t)[BRPeerManager sharedInstance].lastBlockHeight;
    [self confirmProtocolRequest:self.payRequest.protocolRequest];
}

-(void)verifyShapeshiftAmountIsInBounds:(uint64_t)amount completionBlock:(void (^)(void))completionBlock failureBlock:(void (^)(void))failureBlock {
    [[DSShapeshiftManager sharedInstance] GET_marketInfo:^(NSDictionary *marketInfo, NSError *error) {
        if (error) {
            failureBlock();
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"shapeshift failed", nil)
                                         message:error.localizedDescription
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* okButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"ok", nil)
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                       }];
            [alert addAction:okButton];
            [self presentViewController:alert animated:YES completion:nil];
        } else {
            BRWalletManager *manager = [BRWalletManager sharedInstance];
            if ([DSShapeshiftManager sharedInstance].min > (amount * .97)) {
                failureBlock();
                UIAlertController * alert = [UIAlertController
                                             alertControllerWithTitle:NSLocalizedString(@"shapeshift failed", nil)
                                             message:[NSString stringWithFormat:NSLocalizedString(@"The amount you wanted to shapeshift is too low, "
                                                                                                  @"please input a value over %@", nil),[manager stringForDashAmount:[DSShapeshiftManager sharedInstance].min / .97]]
                                             preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction* okButton = [UIAlertAction
                                           actionWithTitle:NSLocalizedString(@"ok", nil)
                                           style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction * action) {
                                           }];
                [alert addAction:okButton];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            } else if ([DSShapeshiftManager sharedInstance].limit < (amount * 1.03)) {
                failureBlock();
                UIAlertController * alert = [UIAlertController
                                             alertControllerWithTitle:NSLocalizedString(@"shapeshift failed", nil)
                                             message:[NSString stringWithFormat:NSLocalizedString(@"The amount you wanted to shapeshift is too high, "
                                                                                                  @"please input a value under %@", nil),[manager stringForDashAmount:[DSShapeshiftManager sharedInstance].limit / 1.03]]
                                             preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction* okButton = [UIAlertAction
                                           actionWithTitle:NSLocalizedString(@"ok", nil)
                                           style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction * action) {
                                           }];
                [alert addAction:okButton];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }
            completionBlock();
        }
    }];
    
}

- (void)amountViewController:(BRAmountViewController *)amountViewController shapeshiftBitcoinAmount:(uint64_t)amount approximateDashAmount:(uint64_t)dashAmount
{
    MBProgressHUD *hud  = [MBProgressHUD showHUDAddedTo:self.navigationController.topViewController.view animated:YES];
    hud.label.text       = NSLocalizedString(@"Starting Shapeshift!", nil);
    
    [self verifyShapeshiftAmountIsInBounds:dashAmount completionBlock:^{
        //we know the exact amount of bitcoins we want to send
        BRWalletManager *m = [BRWalletManager sharedInstance];
        NSString * address = [NSString bitcoinAddressWithScriptPubKey:self.shapeshiftRequest.details.outputScripts.firstObject];
        NSString * returnAddress = m.wallet.receiveAddress;
        NSNumber * numberAmount = [m numberForAmount:amount];
        [[DSShapeshiftManager sharedInstance] POST_SendAmount:numberAmount withAddress:address returnAddress:returnAddress completionBlock:^(NSDictionary *shiftInfo, NSError *error) {
            [hud hideAnimated:TRUE];
            if (error) {
                //BRLog(@"shapeshiftBitcoinAmount Error %@",error);
                
                UIAlertController * alert = [UIAlertController
                                             alertControllerWithTitle:NSLocalizedString(@"shapeshift failed", nil)
                                             message:error.localizedDescription
                                             preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction* okButton = [UIAlertAction
                                           actionWithTitle:NSLocalizedString(@"ok", nil)
                                           style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction * action) {
                                           }];
                [alert addAction:okButton];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }
            NSString * depositAddress = shiftInfo[@"deposit"];
            NSString * withdrawalAddress = shiftInfo[@"withdrawal"];
            NSNumber * withdrawalAmount = shiftInfo[@"withdrawalAmount"];
            NSNumber * depositAmountNumber = @([shiftInfo[@"depositAmount"] doubleValue]);
            if (depositAmountNumber && [withdrawalAmount floatValue] && [depositAmountNumber floatValue]) {
                uint64_t depositAmount = [[[NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%@",depositAmountNumber]] decimalNumberByMultiplyingByPowerOf10:8]
                                          unsignedLongLongValue];
                self.amount = depositAmount;
                
                DSShapeshiftEntity * shapeshift = [DSShapeshiftEntity registerShapeshiftWithInputAddress:depositAddress andWithdrawalAddress:withdrawalAddress withStatus:eShapeshiftAddressStatus_Unused fixedAmountOut:depositAmountNumber amountIn:depositAmountNumber];
                
                BRPaymentRequest * request = [BRPaymentRequest requestWithString:[NSString stringWithFormat:@"safe:%@?amount=%llu&label=%@&message=Shapeshift to %@",depositAddress,depositAmount,sanitizeString(self.shapeshiftRequest.commonName),withdrawalAddress]];
                [self confirmProtocolRequest:request.protocolRequest currency:@"safe" associatedShapeshift:shapeshift];
            }
        }];
    } failureBlock:^{
        [hud hideAnimated:TRUE];
    }];
}

- (void)amountViewController:(BRAmountViewController *)amountViewController shapeshiftDashAmount:(uint64_t)amount
{
    MBProgressHUD *hud  = [MBProgressHUD showHUDAddedTo:self.navigationController.topViewController.view animated:YES];
    hud.label.text       = NSLocalizedString(@"Starting Shapeshift!", nil);
    [self verifyShapeshiftAmountIsInBounds:amount completionBlock:^{
        //we don't know the exact amount of bitcoins we want to send, we are just sending dash
        BRWalletManager *m = [BRWalletManager sharedInstance];
        NSString * address = [NSString bitcoinAddressWithScriptPubKey:self.shapeshiftRequest.details.outputScripts.firstObject];
        NSString * returnAddress = m.wallet.receiveAddress;
        self.amount = amount;
        DSShapeshiftEntity * shapeshift = [DSShapeshiftEntity unusedShapeshiftHavingWithdrawalAddress:address];
        NSString * depositAddress = shapeshift.inputAddress;
        
        if (shapeshift) {
            [hud hideAnimated:TRUE];
            BRPaymentRequest * request = [BRPaymentRequest requestWithString:[NSString stringWithFormat:@"safe:%@?amount=%llu&label=%@&message=Shapeshift to %@",depositAddress,self.amount,sanitizeString(self.request.commonName),address]];
            [self confirmProtocolRequest:request.protocolRequest currency:@"safe" associatedShapeshift:shapeshift];
        } else {
            [[DSShapeshiftManager sharedInstance] POST_ShiftWithAddress:address returnAddress:returnAddress completionBlock:^(NSDictionary *shiftInfo, NSError *error) {
                [hud hideAnimated:TRUE];
                if (error) {
                    //BRLog(@"shapeshiftDashAmount Error %@",error);
                    UIAlertController * alert = [UIAlertController
                                                 alertControllerWithTitle:NSLocalizedString(@"shapeshift failed", nil)
                                                 message:error.localizedDescription
                                                 preferredStyle:UIAlertControllerStyleAlert];
                    UIAlertAction* okButton = [UIAlertAction
                                               actionWithTitle:NSLocalizedString(@"ok", nil)
                                               style:UIAlertActionStyleCancel
                                               handler:^(UIAlertAction * action) {
                                               }];
                    [alert addAction:okButton];
                    [self presentViewController:alert animated:YES completion:nil];
                    return;
                }
                NSString * depositAddress = shiftInfo[@"deposit"];
                NSString * withdrawalAddress = shiftInfo[@"withdrawal"];
                if (withdrawalAddress && depositAddress) {
                    DSShapeshiftEntity * shapeshift = [DSShapeshiftEntity registerShapeshiftWithInputAddress:depositAddress andWithdrawalAddress:withdrawalAddress withStatus:eShapeshiftAddressStatus_Unused];
                    BRPaymentRequest * request = [BRPaymentRequest requestWithString:[NSString stringWithFormat:@"safe:%@?amount=%llu&label=%@&message=Shapeshift to %@",depositAddress,self.amount,sanitizeString(self.shapeshiftRequest.commonName),withdrawalAddress]];
                    [self confirmProtocolRequest:request.protocolRequest currency:@"safe" associatedShapeshift:shapeshift];
                }
            }];
        }
    } failureBlock:^{
        [hud hideAnimated:TRUE];
    }];
}


// MARK: - AVCaptureMetadataOutputObjectsDelegate
// TODO: 扫描二维码结果
- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputMetadataObjects:(NSArray *)metadataObjects
       fromConnection:(AVCaptureConnection *)connection
{
    for (AVMetadataMachineReadableCodeObject *codeObject in metadataObjects) {
        if (! [codeObject.type isEqual:AVMetadataObjectTypeQRCode]) continue;
        
        [BREventManager saveEvent:@"send:scanned_qr"];
        
        NSString *addr = [codeObject.stringValue stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        BRPaymentRequest *request = [BRPaymentRequest requestWithString:addr];
        if(request.amount > 0) {
            BOOL isAsset = NO;
            for(BRBalanceModel *balanceModel in [BRWalletManager sharedInstance].wallet.balanceArray) {
                if(request.assetName.length != 0 && [balanceModel.nameString isEqualToString:request.assetName]) {
                    isAsset = YES;
                    break;
                }
            }
            if(!isAsset && request.assetName.length != 0) {
                [self.navigationController dismissViewControllerAnimated:YES completion:^{
                    [self resetQRGuide];
                    [AppTool showMessage:@"您暂无此资产，无法转账" showView:self.view];
                }];
                return;
            }
        }
        self.payRequest = request;
        if ((request.isValid) || [addr isValidBitcoinPrivateKey] || [addr isValidDashPrivateKey] || [addr isValidDashBIP38Key]) {
            self.scanController.cameraGuide.image = [UIImage imageNamed:@"cameraguide-green"];
            [self.scanController stop];
            
            [BREventManager saveEvent:@"send:valid_qr_scan"];
            
            if (request.r.length > 0) { // start fetching payment protocol request right away
                [BRPaymentRequest fetch:request.r scheme:request.scheme timeout:5.0
                             completion:^(BRPaymentProtocolRequest *req, NSError *error) {
                                 dispatch_async(dispatch_get_main_queue(), ^{
                                     if (error) request.r = nil;
                                     
                                     if (error && ! request.isValid) {
                                         UIAlertController * alert = [UIAlertController
                                                                      alertControllerWithTitle:NSLocalizedString(@"couldn't make payment", nil)
                                                                      message:error.localizedDescription
                                                                      preferredStyle:UIAlertControllerStyleAlert];
                                         UIAlertAction* okButton = [UIAlertAction
                                                                    actionWithTitle:NSLocalizedString(@"ok", nil)
                                                                    style:UIAlertActionStyleCancel
                                                                    handler:^(UIAlertAction * action) {
                                                                    }];
                                         [alert addAction:okButton];
                                         [self presentViewController:alert animated:YES completion:nil];
                                         [self cancel:nil];
                                         // continue here and handle the invalid request inside confirmRequest:
                                     }
                                     
                                     [self.navigationController dismissViewControllerAnimated:YES completion:^{
                                         [self resetQRGuide];
                                     }];
                                     
                                     if (error) {
                                         [BREventManager saveEvent:@"send:unsuccessful_qr_payment_protocol_fetch"];
                                         [self confirmRequest:request]; // payment protocol fetch failed, so use standard request
                                     }
                                     else {
                                         [BREventManager saveEvent:@"send:successful_qr_payment_protocol_fetch"];
                                         [self confirmProtocolRequest:req];
                                     }
                                 });
                             }];
            }
            else { // standard non payment protocol request
                [self.navigationController dismissViewControllerAnimated:YES completion:^{
                    [self resetQRGuide];
                    if (request.amount > 0) self.canChangeAmount = YES;
                    if (request.isValid && self.showBalance) {
                        [self showBalance:request.paymentAddress];
                        [self cancel:nil];
                    }
                    else {
                        [self confirmRequest:request];
                    }
                }];
            }
        } else {
            [BRPaymentRequest fetch:request.r scheme:request.scheme timeout:5.0
                         completion:^(BRPaymentProtocolRequest *req, NSError *error) { // check to see if it's a BIP73 url
                             dispatch_async(dispatch_get_main_queue(), ^{
                                 [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(resetQRGuide) object:nil];
                                 
                                 if (req) {
                                     self.scanController.cameraGuide.image = [UIImage imageNamed:@"cameraguide-green"];
                                     [self.scanController stop];
                                     
                                     [self.navigationController dismissViewControllerAnimated:YES completion:^{
                                         [self resetQRGuide];
                                     }];
                                     
                                     [BREventManager saveEvent:@"send:successful_bip73"];
                                     [self confirmProtocolRequest:req];
                                 }
                                 else {
                                     self.scanController.cameraGuide.image = [UIImage imageNamed:@"cameraguide-red"];
                                     if (([request.scheme isEqual:@"safe"] && request.paymentAddress.length > 1) ||
                                         [request.paymentAddress hasPrefix:@"X"] || [request.paymentAddress hasPrefix:@"7"]) {
                                         self.scanController.message.text = [NSString stringWithFormat:@"%@:\n%@",
                                                                             NSLocalizedString(@"not a valid dash address", nil),
                                                                             request.paymentAddress];
                                     } else if (([request.scheme isEqual:@"bitcoin"] && request.paymentAddress.length > 1) ||
                                                [request.paymentAddress hasPrefix:@"1"] || [request.paymentAddress hasPrefix:@"3"]) {
                                         self.scanController.message.text = [NSString stringWithFormat:@"%@:\n%@",
                                                                             NSLocalizedString(@"not a valid bitcoin address", nil),
                                                                             request.paymentAddress];
                                     }
                                     else self.scanController.message.text = NSLocalizedString(@"not a dash or bitcoin QR code", nil);
                                     
                                     [self performSelector:@selector(resetQRGuide) withObject:nil afterDelay:0.35];
                                     [BREventManager saveEvent:@"send:unsuccessful_bip73"];
                                 }
                             });
                         }];
        }
        
        break;
    }
}

// MARK: UIViewControllerAnimatedTransitioning

// This is used for percent driven interactive transitions, as well as for container controllers that have companion
// animations that might need to synchronize with the main animation.
- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)transitionContext
{
    return 0.35;
}

// This method can only be a nop if the transition is interactive and not a percentDriven interactive transition.
- (void)animateTransition:(id<UIViewControllerContextTransitioning>)transitionContext
{
    UIView *containerView = transitionContext.containerView;
    UIViewController *to = [transitionContext viewControllerForKey:UITransitionContextToViewControllerKey],
    *from = [transitionContext viewControllerForKey:UITransitionContextFromViewControllerKey];
    UIImageView *img = self.scanButton.imageView;
    UIView *guide = self.scanController.cameraGuide;
    
    [self.scanController.view layoutIfNeeded];
    
    if (to == self.scanController) {
        [containerView addSubview:to.view];
        to.view.frame = from.view.frame;
        to.view.center = CGPointMake(to.view.center.x, containerView.frame.size.height*3/2);
        guide.transform = CGAffineTransformMakeScale(img.bounds.size.width/guide.bounds.size.width,
                                                     img.bounds.size.height/guide.bounds.size.height);
        guide.alpha = 0;
        
        [UIView animateWithDuration:0.1 animations:^{
            img.alpha = 0.0;
            guide.alpha = 1.0;
        }];
        
        [UIView animateWithDuration:[self transitionDuration:transitionContext] delay:0 usingSpringWithDamping:0.8
              initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
                  to.view.center = from.view.center;
              } completion:^(BOOL finished) {
                  img.alpha = 1.0;
                  [transitionContext completeTransition:YES];
              }];
        
        [UIView animateWithDuration:0.8 delay:0.15 usingSpringWithDamping:0.5 initialSpringVelocity:0
                            options:UIViewAnimationOptionCurveEaseOut animations:^{
                                guide.transform = CGAffineTransformIdentity;
                            } completion:^(BOOL finished) {
                                [to.view addSubview:guide];
                            }];
    }
    else {
        [containerView insertSubview:to.view belowSubview:from.view];
        [self cancel:nil];
        
        [UIView animateWithDuration:0.8 delay:0.0 usingSpringWithDamping:0.5 initialSpringVelocity:0
                            options:UIViewAnimationOptionCurveEaseIn animations:^{
                                guide.transform = CGAffineTransformMakeScale(img.bounds.size.width/guide.bounds.size.width,
                                                                             img.bounds.size.height/guide.bounds.size.height);
                                guide.alpha = 0.0;
                            } completion:^(BOOL finished) {
                                guide.transform = CGAffineTransformIdentity;
                                guide.alpha = 1.0;
                            }];
        
        [UIView animateWithDuration:[self transitionDuration:transitionContext] - 0.15 delay:0.15
                            options:UIViewAnimationOptionCurveEaseIn animations:^{
                                from.view.center = CGPointMake(from.view.center.x, containerView.frame.size.height*3/2);
                            } completion:^(BOOL finished) {
                                [transitionContext completeTransition:YES];
                            }];
    }
}

// MARK: - UIViewControllerTransitioningDelegate

- (id<UIViewControllerAnimatedTransitioning>)animationControllerForPresentedController:(UIViewController *)presented
                                                                  presentingController:(UIViewController *)presenting sourceController:(UIViewController *)source
{
    return self;
}

- (id<UIViewControllerAnimatedTransitioning>)animationControllerForDismissedController:(UIViewController *)dismissed
{
    return self;
}

@end
