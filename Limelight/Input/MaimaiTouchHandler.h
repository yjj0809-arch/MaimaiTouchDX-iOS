//
//  MaimaiTouchHandler.h
//  MaimaiTouchDX
//

#import <UIKit/UIKit.h>

@class StreamView;

@interface MaimaiTouchHandler : UIResponder

- (instancetype)initWithStreamView:(StreamView *)streamView
                              host:(NSString *)host
                              port:(uint16_t)port;
- (void)start;
- (void)stop;

- (void)handleTouchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)handleTouchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)handleTouchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)handleTouchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;

@end
