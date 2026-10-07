//
//  MaimaiTouchHandler.m
//  MaimaiTouchDX
//
//  This implementation is intentionally self-contained so the Moonlight
//  stream view can be compiled unchanged for tvOS.
//

#import "MaimaiTouchHandler.h"

#if !TARGET_OS_TV

#import "Logger.h"
#import "StreamView.h"
#import "TouchDXRegions.h"
#import "Utils.h"

#import <ctype.h>
#import <math.h>
#import <stdio.h>

#import <arpa/inet.h>
#import <fcntl.h>
#import <netdb.h>
#import <netinet/tcp.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <unistd.h>

static const CGFloat kTouchDXPanelWidth = 896.0;
static const CGFloat kTouchDXPanelHeight = 898.0;
static const CGFloat kTouchDXDefaultRadius = 22.0;
static const CGFloat kTouchDXBCDEHalfCentimeterRadius = 8.6;

typedef struct {
    CGFloat scale;
    CGFloat originX;
    CGFloat originY;
} TouchDXPanelTransform;

@interface MaimaiTouchRegion : NSObject

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic) CGPathRef path;
@property (nonatomic) NSUInteger bitIndex;

@end

@implementation MaimaiTouchRegion

- (void)dealloc {
    if (_path != NULL) {
        CGPathRelease(_path);
    }
}

@end

static void TouchDXSkipSeparators(const char **cursor) {
    while (**cursor != '\0' &&
           (isspace((unsigned char)**cursor) || **cursor == ',')) {
        (*cursor)++;
    }
}

static BOOL TouchDXReadNumber(const char **cursor, CGFloat *value) {
    TouchDXSkipSeparators(cursor);

    char *end = NULL;
    double number = strtod(*cursor, &end);
    if (end == *cursor) {
        return NO;
    }

    *cursor = end;
    *value = (CGFloat)number;
    return YES;
}

static CGMutablePathRef TouchDXCreatePath(NSString *pathData,
                                           CGFloat offsetX,
                                           CGFloat offsetY) {
    CGMutablePathRef path = CGPathCreateMutable();
    const char *cursor = pathData.UTF8String;
    BOOL hasOpenSubpath = NO;
    BOOL parseFailed = NO;

    while (*cursor != '\0') {
        TouchDXSkipSeparators(&cursor);
        if (*cursor == '\0') {
            break;
        }

        char command = *cursor++;
        if (command == 'M') {
            CGFloat x = 0;
            CGFloat y = 0;
            if (!TouchDXReadNumber(&cursor, &x) ||
                !TouchDXReadNumber(&cursor, &y)) {
                parseFailed = YES;
                break;
            }

            CGPathMoveToPoint(path, NULL, x + offsetX, y + offsetY);
            hasOpenSubpath = YES;
        }
        else if (command == 'C') {
            CGFloat x1 = 0;
            CGFloat y1 = 0;
            CGFloat x2 = 0;
            CGFloat y2 = 0;
            CGFloat x = 0;
            CGFloat y = 0;

            if (!TouchDXReadNumber(&cursor, &x1) ||
                !TouchDXReadNumber(&cursor, &y1) ||
                !TouchDXReadNumber(&cursor, &x2) ||
                !TouchDXReadNumber(&cursor, &y2) ||
                !TouchDXReadNumber(&cursor, &x) ||
                !TouchDXReadNumber(&cursor, &y)) {
                parseFailed = YES;
                break;
            }

            CGPathAddCurveToPoint(path, NULL,
                                  x1 + offsetX, y1 + offsetY,
                                  x2 + offsetX, y2 + offsetY,
                                  x + offsetX, y + offsetY);
        }
        else if (command == 'Z') {
            if (hasOpenSubpath) {
                CGPathCloseSubpath(path);
                hasOpenSubpath = NO;
            }
        }
        else {
            parseFailed = YES;
            break;
        }
    }

    if (parseFailed) {
        CGPathRelease(path);
        return NULL;
    }

    return path;
}

static NSDictionary<NSString *, NSNumber *> *TouchDXBitMap(void) {
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"A1": @8,  @"A2": @9,  @"A3": @10, @"A4": @11,
            @"A5": @12, @"A6": @13, @"A7": @14, @"A8": @15,
            @"B1": @16, @"B2": @17, @"B3": @18, @"B4": @19,
            @"B5": @20, @"B6": @21, @"B7": @22, @"B8": @23,
            @"C1": @24, @"C2": @25,
            @"D1": @26, @"D2": @27, @"D3": @28, @"D4": @29,
            @"D5": @30, @"D6": @31, @"D7": @32, @"D8": @33,
            @"E1": @34, @"E2": @35, @"E3": @36, @"E4": @37,
            @"E5": @38, @"E6": @39, @"E7": @40, @"E8": @41,
        };
    });
    return map;
}

static BOOL TouchDXPathContainsPoint(CGPathRef path, CGPoint point) {
    return CGPathContainsPoint(path, NULL, point, false);
}

static BOOL TouchDXPathIntersectsCircle(CGPathRef path,
                                         CGPoint point,
                                         CGFloat radius) {
    if (radius <= 0.0f) {
        return TouchDXPathContainsPoint(path, point);
    }

    if (TouchDXPathContainsPoint(path, point)) {
        return YES;
    }

    for (NSUInteger i = 0; i < 8; i++) {
        CGFloat angle = (CGFloat)i * (CGFloat)M_PI_4;
        CGPoint sample = CGPointMake(point.x + cos(angle) * radius,
                                     point.y + sin(angle) * radius);
        if (TouchDXPathContainsPoint(path, sample)) {
            return YES;
        }
    }

    return NO;
}

@interface MaimaiTouchHandler ()

- (void)loadRegions;
- (TouchDXPanelTransform)panelTransform;
- (CGPoint)panelPointForTouch:(UITouch *)touch;
- (uint64_t)maskForTouch:(UITouch *)touch;
- (void)rebuildState;
- (void)updateTouches:(NSSet<UITouch *> *)touches removing:(BOOL)removing;
- (void)closeSocket;
- (void)installReadSource;
- (void)connectIfNeeded;
- (void)readAvailableData;
- (void)networkTick;

@end

@implementation MaimaiTouchHandler {
    __weak StreamView *_streamView;
    NSString *_host;
    uint16_t _port;

    NSMutableArray<MaimaiTouchRegion *> *_regions;
    NSMapTable<UITouch *, NSNumber *> *_touchMasks;

    NSLock *_stateLock;
    uint64_t _state;
    BOOL _inGame;

    dispatch_queue_t _networkQueue;
    dispatch_source_t _sendTimer;
    dispatch_source_t _readSource;
    NSMutableData *_readBuffer;
    int _socketFD;
    BOOL _started;

    CGFloat _userScale;
    CGFloat _offsetX;
    CGFloat _offsetY;
    CGFloat _baseTouchRadius;
    CGFloat _bcdeExtraRadius;
    NSTimeInterval _lastConnectAttempt;
}

- (instancetype)initWithStreamView:(StreamView *)streamView
                              host:(NSString *)host
                              port:(uint16_t)port {
    self = [super init];
    if (self) {
        _streamView = streamView;
        _host = [host copy] ?: @"127.0.0.1";
        _port = port != 0 ? port : 4321;
        _regions = [[NSMutableArray alloc] init];
        _touchMasks = [NSMapTable strongToStrongObjectsMapTable];
        _stateLock = [[NSLock alloc] init];
        _socketFD = -1;
        _started = NO;

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        _userScale = [defaults objectForKey:@"touchdxScale"] != nil ? [defaults floatForKey:@"touchdxScale"] : 1.0f;
        _offsetX = [defaults objectForKey:@"touchdxOffsetX"] != nil ? [defaults floatForKey:@"touchdxOffsetX"] : 0.0f;
        _offsetY = [defaults objectForKey:@"touchdxOffsetY"] != nil ? [defaults floatForKey:@"touchdxOffsetY"] : 0.0f;
        _baseTouchRadius = [defaults objectForKey:@"touchdxRadius"] != nil ? [defaults floatForKey:@"touchdxRadius"] : kTouchDXDefaultRadius;
        _bcdeExtraRadius = [defaults objectForKey:@"touchdxBCDERadius"] != nil ? [defaults floatForKey:@"touchdxBCDERadius"] : kTouchDXBCDEHalfCentimeterRadius;

        [self loadRegions];
    }
    return self;
}

- (void)loadRegions {
    NSDictionary<NSString *, NSNumber *> *bitMap = TouchDXBitMap();

    for (NSUInteger i = 0; i < kTouchDXRegionDefinitionCount; i++) {
        TouchDXRegionDefinition definition = kTouchDXRegionDefinitions[i];
        NSNumber *bitIndex = bitMap[@(definition.identifier)];
        if (bitIndex == nil) {
            continue;
        }

        NSString *pathData = [NSString stringWithUTF8String:definition.pathData];
        CGMutablePathRef path = TouchDXCreatePath(pathData,
                                                   definition.offsetX,
                                                   definition.offsetY);
        if (path == NULL) {
            Log(LOG_W, @"TouchDX could not parse region %@", pathData);
            continue;
        }

        MaimaiTouchRegion *region = [[MaimaiTouchRegion alloc] init];
        region.identifier = [NSString stringWithUTF8String:definition.identifier];
        region.path = path;
        region.bitIndex = bitIndex.unsignedIntegerValue;
        [_regions addObject:region];
    }

    Log(LOG_I, @"TouchDX loaded %lu touch regions", (unsigned long)_regions.count);
}

- (void)start {
    if (_started) {
        return;
    }

    _started = YES;
    _networkQueue = dispatch_queue_create("moonlight.touchdx.network", DISPATCH_QUEUE_SERIAL);
    _readBuffer = [[NSMutableData alloc] init];

    _sendTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                        0,
                                        0,
                                        _networkQueue);
    if (_sendTimer == nil) {
        Log(LOG_E, @"TouchDX failed to create network timer");
        _started = NO;
        return;
    }

    dispatch_source_set_timer(_sendTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              4 * NSEC_PER_MSEC,
                              0);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_sendTimer, ^{
        [weakSelf networkTick];
    });
    dispatch_resume(_sendTimer);

    Log(LOG_I, @"TouchDX starting: %@:%u", _host, (unsigned)_port);
}

- (void)stop {
    _started = NO;

    if (_sendTimer != nil) {
        dispatch_source_cancel(_sendTimer);
        _sendTimer = nil;
    }

    [self closeSocket];
}

- (void)dealloc {
    [self stop];
}

- (TouchDXPanelTransform)panelTransform {
    TouchDXPanelTransform transform = { 1.0f, 0.0f, 0.0f };
    if (_streamView == nil) {
        return transform;
    }

    CGSize videoSize = [_streamView getVideoAreaSize];
    if (videoSize.width <= 0.0f || videoSize.height <= 0.0f) {
        return transform;
    }

    CGFloat baseScale = MIN(videoSize.width / kTouchDXPanelWidth,
                            videoSize.height / kTouchDXPanelHeight);
    CGFloat dx = (videoSize.width - kTouchDXPanelWidth * baseScale) / 2.0f;
    CGFloat dy = (videoSize.height - kTouchDXPanelHeight * baseScale) / 2.0f;
    CGFloat totalScale = baseScale * _userScale;
    CGFloat centerX = dx + _offsetX + (kTouchDXPanelWidth * baseScale) / 2.0f;
    CGFloat centerY = dy + _offsetY + (kTouchDXPanelHeight * baseScale) / 2.0f;

    transform.scale = totalScale;
    transform.originX = centerX - (kTouchDXPanelWidth * totalScale) / 2.0f;
    transform.originY = centerY - (kTouchDXPanelHeight * totalScale) / 2.0f;
    return transform;
}

- (CGPoint)panelPointForTouch:(UITouch *)touch {
    if (_streamView == nil) {
        return CGPointZero;
    }

    CGPoint videoPoint = [_streamView adjustCoordinatesForVideoArea:[touch locationInView:_streamView]];
    TouchDXPanelTransform transform = [self panelTransform];
    if (transform.scale <= 0.0f) {
        return CGPointZero;
    }

    return CGPointMake((videoPoint.x - transform.originX) / transform.scale,
                       (videoPoint.y - transform.originY) / transform.scale);
}

- (uint64_t)maskForTouch:(UITouch *)touch {
    BOOL inGame;
    [_stateLock lock];
    inGame = _inGame;
    [_stateLock unlock];

    CGPoint panelPoint = [self panelPointForTouch:touch];
    TouchDXPanelTransform transform = [self panelTransform];
    uint64_t mask = 0;

    for (MaimaiTouchRegion *region in _regions) {
        BOOL hit = NO;

        unichar regionPrefix = [region.identifier characterAtIndex:0];
        BOOL isAArea = regionPrefix == 'A';
        CGFloat regionRadius = _baseTouchRadius;
        if (!isAArea) {
            regionRadius += _bcdeExtraRadius;
        }
        regionRadius /= MAX(transform.scale, 0.001f);

        if (inGame || !isAArea) {
            hit = TouchDXPathIntersectsCircle(region.path, panelPoint, regionRadius);
        }
        else {
            hit = TouchDXPathContainsPoint(region.path, panelPoint);
        }

        if (hit) {
            mask |= (1ULL << region.bitIndex);
            if (!inGame && isAArea) {
                break;
            }
        }
    }

    return mask;
}

- (void)rebuildState {
    uint64_t state = 0;

    for (NSNumber *mask in _touchMasks.objectEnumerator) {
        state |= mask.unsignedLongLongValue;
    }

    [_stateLock lock];
    _state = state;
    [_stateLock unlock];
}

- (void)updateTouches:(NSSet<UITouch *> *)touches removing:(BOOL)removing {
    for (UITouch *touch in touches) {
        if (removing) {
            [_touchMasks removeObjectForKey:touch];
        }
        else {
            uint64_t mask = [self maskForTouch:touch];
            [_touchMasks setObject:@(mask) forKey:touch];
        }
    }

    [self rebuildState];
}

- (void)handleTouchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateTouches:touches removing:NO];
}

- (void)handleTouchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateTouches:touches removing:NO];
}

- (void)handleTouchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateTouches:touches removing:YES];
}

- (void)handleTouchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateTouches:touches removing:YES];
}

- (void)closeSocket {
    if (_readSource != nil) {
        dispatch_source_cancel(_readSource);
        _readSource = nil;
    }

    if (_socketFD >= 0) {
        close(_socketFD);
        _socketFD = -1;
    }

    [_readBuffer setLength:0];
}

- (void)installReadSource {
    if (_socketFD < 0 || _readSource != nil) {
        return;
    }

    _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                                         (uintptr_t)_socketFD,
                                         0,
                                         _networkQueue);
    if (_readSource == nil) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_readSource, ^{
        [weakSelf readAvailableData];
    });
    dispatch_resume(_readSource);
}

- (void)connectIfNeeded {
    if (_socketFD >= 0) {
        return;
    }

    NSTimeInterval now = CACurrentMediaTime();
    if (now - _lastConnectAttempt < 1.0) {
        return;
    }
    _lastConnectAttempt = now;

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    char portString[16];
    snprintf(portString, sizeof(portString), "%u", (unsigned)_port);

    struct addrinfo *addresses = NULL;
    int result = getaddrinfo(_host.UTF8String, portString, &hints, &addresses);
    if (result != 0 || addresses == NULL) {
        return;
    }

    for (struct addrinfo *address = addresses; address != NULL; address = address->ai_next) {
        int fd = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (fd < 0) {
            continue;
        }

        int noSigPipe = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

        int noDelay = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, sizeof(noDelay));

        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);

        int connectResult = connect(fd, address->ai_addr, address->ai_addrlen);
        if (connectResult < 0 && errno != EINPROGRESS) {
            close(fd);
            continue;
        }

        if (connectResult < 0) {
            fd_set writeSet;
            FD_ZERO(&writeSet);
            FD_SET(fd, &writeSet);

            struct timeval timeout;
            timeout.tv_sec = 0;
            timeout.tv_usec = 250000;

            int selectResult = select(fd + 1, NULL, &writeSet, NULL, &timeout);
            if (selectResult <= 0) {
                close(fd);
                continue;
            }

            int socketError = 0;
            socklen_t errorLength = sizeof(socketError);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) != 0 ||
                socketError != 0) {
                close(fd);
                continue;
            }
        }

        _socketFD = fd;
        [_readBuffer setLength:0];
        [self installReadSource];
        Log(LOG_I, @"TouchDX connected to %@:%u", _host, (unsigned)_port);
        break;
    }

    freeaddrinfo(addresses);
}

- (void)readAvailableData {
    if (_socketFD < 0) {
        return;
    }

    uint8_t buffer[512];
    BOOL disconnected = NO;

    while (YES) {
        ssize_t received = recv(_socketFD, buffer, sizeof(buffer), 0);
        if (received > 0) {
            [_readBuffer appendBytes:buffer length:(NSUInteger)received];
        }
        else if (received == 0) {
            disconnected = YES;
            break;
        }
        else if (errno == EAGAIN || errno == EWOULDBLOCK) {
            break;
        }
        else {
            disconnected = YES;
            break;
        }
    }

    while (_readBuffer.length >= 8) {
        const uint8_t *bytes = _readBuffer.bytes;
        if (bytes[0] == 0x47 && bytes[1] == 0x41 &&
            bytes[2] == 0x4D && bytes[3] == 0x45) {
            BOOL inGame = bytes[7] == 1;
            [_stateLock lock];
            _inGame = inGame;
            [_stateLock unlock];
        }

        [_readBuffer replaceBytesInRange:NSMakeRange(0, 8)
                                withBytes:NULL
                                   length:0];
    }

    if (disconnected) {
        [self closeSocket];
    }
}

- (void)networkTick {
    if (!_started) {
        return;
    }

    if (_socketFD < 0) {
        [self connectIfNeeded];
        return;
    }

    uint64_t state;
    [_stateLock lock];
    state = _state;
    [_stateLock unlock];

    uint8_t packet[8];
    for (NSUInteger i = 0; i < 8; i++) {
        packet[i] = (uint8_t)((state >> (i * 8)) & 0xFF);
    }

    ssize_t sent = send(_socketFD, packet, sizeof(packet), 0);
    if (sent == sizeof(packet)) {
        return;
    }

    if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        return;
    }

    [self closeSocket];
}

@end

#endif
