//
//  BRPaymentRequest.m
//  BreadWallet
//
//  Created by Aaron Voisine on 5/9/13.
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

#import "BRPaymentRequest.h"
#import "BRPaymentProtocol.h"
#import "NSString+Bitcoin.h"
#import "NSString+Dash.h"
#import "NSMutableData+Bitcoin.h"
#import "BRSafeUtils.h"

// BIP21 bitcoin URI object https://github.com/bitcoin/bips/blob/master/bip-0021.mediawiki
@implementation BRPaymentRequest

+ (instancetype)requestWithString:(NSString *)string
{
    return [[self alloc] initWithString:string];
}

+ (instancetype)requestWithData:(NSData *)data
{
    return [[self alloc] initWithData:data];
}

+ (instancetype)requestWithURL:(NSURL *)url
{
    return [[self alloc] initWithURL:url];
}

- (instancetype)initWithString:(NSString *)string
{
    if (! (self = [super init])) return nil;
    
    self.string = string;
    return self;
}

- (instancetype)initWithData:(NSData *)data
{
    return [self initWithString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
}

- (instancetype)initWithURL:(NSURL *)url
{
    return [self initWithString:url.absoluteString];
}

- (void)setString:(NSString *)string
{
    self.scheme = nil;
    self.paymentAddress = nil;
    self.label = nil;
    self.message = nil;
    self.assetName = nil;
    self.amount = 0;
    self.callbackScheme = nil;
    _wantsInstant = FALSE;
    _instantValueRequired = FALSE;
    self.r = nil;

    if (string.length == 0) return;

    NSString *s = [[string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                   stringByReplacingOccurrencesOfString:@" " withString:@"%20"];
 
    NSURL *url = [NSURL URLWithString:s];
    
    if (! url || ! url.scheme) {
        if ([s isValidBitcoinAddress] || [s isValidBitcoinPrivateKey]) {
            url = [NSURL URLWithString:[NSString stringWithFormat:@"bitcoin://%@", s]];
            self.scheme = @"bitcoin";
        } else if ([s isValidDashAddress] || [s isValidDashPrivateKey] || [s isValidDashBIP38Key]) {
            url = [NSURL URLWithString:[NSString stringWithFormat:@"safe://%@", s]];
            self.scheme = @"safe";
        }
    }
    else if (! url.host && url.resourceSpecifier) {
        url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@", url.scheme, url.resourceSpecifier]];
        self.scheme = url.scheme;
    } else if (url.scheme) {
        self.scheme = url.scheme;
    } else {
        self.scheme = @"safe";
    }
//    BRLog(@"=================%@ %@", url.scheme, url.host);
    if ([[url.scheme lowercaseString] isEqualToString:[@"safe" lowercaseString]] || [url.scheme isEqualToString:@"bitcoin"]) {
        self.paymentAddress = url.host;
    
        //TODO: correctly handle unknown but required url arguments (by reporting the request invalid)
        for (NSString *arg in [url.query componentsSeparatedByString:@"&"]) {
            NSArray *pair = [arg componentsSeparatedByString:@"="]; // if more than one '=', then pair[1] != value

            if (pair.count < 2) continue;
        
            NSString *value = [[[arg substringFromIndex:[pair[0] length] + 1]
                                stringByReplacingOccurrencesOfString:@"+" withString:@" "]
                               stringByRemovingPercentEncoding];
            
            BOOL require = FALSE;
            NSString * key = pair[0];
            if ([key hasPrefix:@"req-"] && key.length > 4) {
                key = [key substringFromIndex:4];
                require = TRUE;
            }

            if ([key isEqual:@"amount"]) {
                NSDecimal dec, amount;

                if ([[NSScanner scannerWithString:value] scanDecimal:&dec]) {
//                    NSDecimalMultiplyByPowerOf10(&amount, &dec, 8, NSRoundUp);
                    NSDecimalMultiplyByPowerOf10(&amount, &dec, self.balanceModel.multiple > 0 ? self.balanceModel.multiple : 10, NSRoundUp);
                    int result = (int)[[NSDecimalNumber decimalNumberWithDecimal:amount] compare:[NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%lld", INT64_MAX]]];
                    if(result >= 0) {
                        self.amount = 0;
                    } else {
                        self.amount = [NSDecimalNumber decimalNumberWithDecimal:amount].unsignedLongLongValue;
                    }
                }
                if (require)
                    _amountValueImmutable = TRUE;
            }
            else if ([key isEqual:@"label"]) {
                self.label = value;
            }
            else if ([key isEqual:@"sender"]) {
                self.callbackScheme = value;
            }
            else if ([key isEqual:@"message"]) {
                self.message = value;
            }
            else if ([[key lowercaseString] isEqual:@"is"]) {
                if ([value  isEqual: @"1"])
                    _wantsInstant = TRUE;
                if (require)
                    _instantValueRequired = TRUE;
            }
            else if ([key isEqual:@"r"]) {
                self.r = value;
            } else if ([key isEqual:@"assetName"]) {  // TODO: 支付url添加资产名称
                self.assetName = value;
            } else if ([key isEqual:@"IS"]) {
                if ([value  isEqual: @"1"])
                    _wantsInstant = TRUE;
            }
        }
    }
    else if (url) self.r = s; // BIP73 url: https://github.com/bitcoin/bips/blob/master/bip-0073.mediawiki
}

- (NSString *)string
{
//    if (! ([self.scheme isEqual:@"bitcoin"] || [self.scheme isEqual:@"safe"])) return self.r;
    if(! ([self.scheme isEqual:@"bitcoin"] || [[self.scheme lowercaseString] isEqualToString:[@"safe" lowercaseString]])) return self.r;

    NSMutableString *s = [NSMutableString stringWithFormat:@"%@:",self.scheme];
    NSMutableArray *q = [NSMutableArray array];
    NSMutableCharacterSet *charset = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    
    [charset removeCharactersInString:@"&="];
    if (self.paymentAddress) [s appendString:self.paymentAddress];
    
    // TODO:修改小数点位数
    if (self.amount > 0) {
//        [q addObject:[@"amount=" stringByAppendingString:[(id)[NSDecimalNumber numberWithUnsignedLongLong:self.amount]
//                                                          decimalNumberByMultiplyingByPowerOf10:-8].stringValue]];
        [q addObject:[@"amount=" stringByAppendingString:[(id)[NSDecimalNumber numberWithUnsignedLongLong:self.amount]
                                                          decimalNumberByMultiplyingByPowerOf10:self.balanceModel.multiple > 0 ? -self.balanceModel.multiple : -10].stringValue]];
    }

    if (self.label.length > 0) {
        [q addObject:[@"label=" stringByAppendingString:[self.label
         stringByAddingPercentEncodingWithAllowedCharacters:charset]]];
    }
    
    if (self.message.length > 0) {
        [q addObject:[@"message=" stringByAppendingString:[self.message
         stringByAddingPercentEncodingWithAllowedCharacters:charset]]];
    }
    
    // TODO: 支付url添加资产名称
    if (self.assetName.length > 0) {
        [q addObject:[@"assetName=" stringByAppendingString:[self.assetName
                                                             stringByAddingPercentEncodingWithAllowedCharacters:charset]]];
    }

    if (self.r.length > 0) {
        [q addObject:[@"r=" stringByAppendingString:[self.r
         stringByAddingPercentEncodingWithAllowedCharacters:charset]]];
    }
    
    if (self.wantsInstant) {
        [q addObject:@"IS=1"];
    }
    
    if (q.count > 0) {
        [s appendString:@"?"];
        [s appendString:[q componentsJoinedByString:@"&"]];
    }
    
    
    return s;
}

- (void)setData:(NSData *)data
{
    self.string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (NSData *)data
{
    return [self.string dataUsingEncoding:NSUTF8StringEncoding];
}

- (void)setUrl:(NSURL *)url
{
    self.string = url.absoluteString;
}

- (NSURL *)url
{
    return [NSURL URLWithString:self.string];
}

- (BOOL)isValid
{
//    if ([self.scheme isEqualToString:@"safe"]) {
    if([[self.scheme lowercaseString] isEqualToString:[@"safe" lowercaseString]]) {
        BOOL valid = ([self.paymentAddress isValidDashAddress] || (self.r && [NSURL URLWithString:self.r])) ? YES : NO;
        if (!valid) {
            //BRLog(@"Not a valid safe request");
        }
        return valid;
    } else if ([self.scheme isEqualToString:@"bitcoin"]) {
        BOOL valid = ([self.paymentAddress isValidBitcoinAddress] || (self.r && [NSURL URLWithString:self.r])) ? YES : NO;
        if (!valid) {
            //BRLog(@"Not a valid bitcoin request");
            
        }
        return valid;
    } else {
        return NO;
    }
}

// receiver converted to BIP70 request object
- (BRPaymentProtocolRequest *)protocolRequest
{
    static NSString *network = @"main";
#if DASH_TESTNET
    network = @"test";
#endif
    NSData *name = [self.label dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *script = [NSMutableData data];
    if ([self.paymentAddress isValidDashAddress]) {
        [script appendScriptPubKeyForAddress:self.paymentAddress];
    } else if ([self.paymentAddress isValidBitcoinAddress]) {
        [script appendBitcoinScriptPubKeyForAddress:self.paymentAddress];
    }
    if (script.length == 0) return nil;
    
//    BRPaymentProtocolDetails *details =
//        [[BRPaymentProtocolDetails alloc] initWithNetwork:network outputAmounts:@[@(self.amount)]
//         outputScripts:@[script] time:0 expires:0 memo:self.message paymentURL:nil merchantData:nil];
    
    //TODO: change zc  待修改  修改reverse字段数据
//    uint64_t unlockHeight = 0;
    uint64_t unlockHeight = self.unlockBlockHeight;
    NSMutableData *safeData = [NSMutableData data];
    [safeData appendString:@"safe"];
    BRPaymentProtocolDetails *details =
    [[BRPaymentProtocolDetails alloc] initWithNetwork:network outputAmounts:@[@(self.amount)] outputScripts:@[script] outputUnlockHeight:@[@(unlockHeight)] outputReverse:@[safeData] time:0 expires:0 memo:self.message paymentURL:nil merchantData:nil];
    
//    BRPaymentProtocolRequest *request =
//        [[BRPaymentProtocolRequest alloc] initWithVersion:TX_VERSION_NUMBER pkiType:@"none" certs:(name ? @[name] : nil) details:details
//         signature:nil callbackScheme:self.callbackScheme];
    BRPaymentProtocolRequest *request =
    [[BRPaymentProtocolRequest alloc] initWithVersion:[BRSafeUtils getTxVersionNumber] pkiType:@"none" certs:(name ? @[name] : nil) details:details
                                            signature:nil callbackScheme:self.callbackScheme];
    
    return request;
}

// fetches the request over HTTP and calls completion block
+ (void)fetch:(NSString *)url scheme:(NSString*)scheme timeout:(NSTimeInterval)timeout
completion:(void (^)(BRPaymentProtocolRequest *req, NSError *error))completion
{
    if (! completion) return;

    NSURL *u = [NSURL URLWithString:url];
    NSMutableURLRequest *req = (u) ? [NSMutableURLRequest requestWithURL:u
                                      cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:timeout] : nil;

    [req setValue:[NSString stringWithFormat:@"application/%@-paymentrequest",scheme] forHTTPHeaderField:@"Accept"];
//  [req addValue:@"text/uri-list" forHTTPHeaderField:@"Accept"]; // breaks some BIP72 implementations, notably bitpay's

    if (! req) {
        completion(nil, [NSError errorWithDomain:@"SafeWallet" code:417
                         userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"bad payment request URL", nil)}]);
        return;
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
    
        BRPaymentProtocolRequest *request = nil;
        NSString *network = @"main";
        
#if DASH_TESTNET
        network = @"test";
#endif
        
        if ([response.MIMEType.lowercaseString isEqual:[NSString stringWithFormat:@"application/%@-paymentrequest",scheme]] && data.length <= 50000) {
            request = [BRPaymentProtocolRequest requestWithData:data];
        }
        else if ([response.MIMEType.lowercaseString isEqual:@"text/uri-list"] && data.length <= 50000) {
            for (NSString *url in [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                                   componentsSeparatedByString:@"\n"]) {
                if ([url hasPrefix:@"#"]) continue; // skip comments
                request = [BRPaymentRequest requestWithString:url].protocolRequest; // use first url and ignore the rest
                break;
            }
        }
        
        if (! request) {
            //BRLog(@"unexpected response from %@:\n%@", req.URL.host,
                  //[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
            completion(nil, [NSError errorWithDomain:@"SafeWallet" code:417 userInfo:@{NSLocalizedDescriptionKey:
                             [NSString stringWithFormat:NSLocalizedString(@"unexpected response from %@", nil),
                              req.URL.host]}]);
        }
        else if (! [request.details.network isEqual:network]) {
            completion(nil, [NSError errorWithDomain:@"SafeWallet" code:417 userInfo:@{NSLocalizedDescriptionKey:
                             [NSString stringWithFormat:NSLocalizedString(@"requested network \"%@\" instead of \"%@\"",
                                                                          nil), request.details.network, network]}]);
        }
        else completion(request, nil);
    }] resume];
}

+ (void)postPayment:(BRPaymentProtocolPayment *)payment scheme:(NSString*)scheme to:(NSString *)paymentURL timeout:(NSTimeInterval)timeout
completion:(void (^)(BRPaymentProtocolACK *ack, NSError *error))completion
{
    NSURL *u = [NSURL URLWithString:paymentURL];
    NSMutableURLRequest *req = (u) ? [NSMutableURLRequest requestWithURL:u
                                      cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:timeout] : nil;
    
    if (! req) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"SafeWallet" code:417
                             userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"bad payment URL", nil)}]);
        }
        
        return;
    }

    [req setValue:[NSString stringWithFormat:@"application/%@-payment",scheme] forHTTPHeaderField:@"Content-Type"];
    [req addValue:[NSString stringWithFormat:@"application/%@-paymentack",scheme] forHTTPHeaderField:@"Accept"];
    req.HTTPMethod = @"POST";
    req.HTTPBody = payment.data;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }
        
        BRPaymentProtocolACK *ack = nil;
        
        if ([response.MIMEType.lowercaseString isEqual:[NSString stringWithFormat:@"application/%@-paymentack",scheme]] && data.length <= 50000) {
            ack = [BRPaymentProtocolACK ackWithData:data];
        }

        if (! ack) {
            //BRLog(@"unexpected response from %@:\n%@", req.URL.host,
                  //[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
            if (completion) {
                completion(nil, [NSError errorWithDomain:@"SafeWallet" code:417 userInfo:@{NSLocalizedDescriptionKey:
                                 [NSString stringWithFormat:NSLocalizedString(@"unexpected response from %@", nil),
                                  req.URL.host]}]);
            }
        }
        else if (completion) completion(ack, nil);
     }] resume];
}

@end
