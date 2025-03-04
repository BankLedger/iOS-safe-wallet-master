//
//  UIView+Extension.h
//  dashwallet
//
//  Created by joker on 2018/6/26.
//  Copyright © 2018年 Aaron Voisine. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface UIView (Extension)

- (UIEdgeInsets)safeInsets;

- (void)roundCornerWithRadius:(CGFloat)radius roundingCorners:(UIRectCorner)roundingCorners borderWidth:(CGFloat)width borderColor:(UIColor *)color;

@end
