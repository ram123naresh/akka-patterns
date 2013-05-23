#import "CVServer.h"
#import "BlockingQueueInputStream.h"
#import "AFNetworking/AFHTTPRequestOperation.h"
#import "AFNetworking/AFHTTPClient.h"
#import "i264Encoder.h"

typedef enum {
	kCVServerConnecitonStatic,
	kCVServerConnecitonStream
} CVServerConnectionMode;

@interface AbstractCVServerConnectionInput : NSObject {
@protected
	NSURL *url;
	NSString *sessionId;
	id<CVServerConnectionDelegate> delegate;
}
- (id)initWithUrl:(NSURL*)url session:(NSString*)session andDelegate:(id<CVServerConnectionDelegate>)delegate;
- (void)initConnectionInput;
@end

@interface CVServerConnectionInputStatic : AbstractCVServerConnectionInput<CVServerConnectionInput>
@end

@interface CVServerConnectionInputStream : AbstractCVServerConnectionInput<CVServerConnectionInput> {
#if !(TARGET_IPHONE_SIMULATOR)
	i264Encoder* encoder;
#endif
}
- (void)oni264Encoder:(i264Encoder *)encoder completedFrameData:(NSData *)data;
@end

@implementation CVServerTransactionConnection {
	NSURL *baseUrl;
	NSString *sessionId;
}

- (CVServerTransactionConnection*)initWithUrl:(NSURL*)aBaseUrl andSessionId:(NSString*)aSessionId {
	self = [super init];
	if (self) {
		baseUrl = aBaseUrl;
		sessionId = aSessionId;
	}
	return self;
}

- (NSURL*)inputUrl:(NSString*)path {
	NSString *pathWithSessionId = [NSString stringWithFormat:@"%@/%@", path, sessionId];
	return [baseUrl URLByAppendingPathComponent:pathWithSessionId];
}

- (id<CVServerConnectionInput>)staticInput:(id<CVServerConnectionDelegate>)delegate {
	return [[CVServerConnectionInputStatic alloc] initWithUrl:[self inputUrl:@"static"] session:sessionId andDelegate:delegate];
}

- (id<CVServerConnectionInput>)streamInput:(id<CVServerConnectionDelegate>)delegate {
	return [[CVServerConnectionInputStream alloc] initWithUrl:[self inputUrl:@"stream"] session:sessionId andDelegate:delegate];
}

@end

@implementation CVServerConnection {
	NSURL *baseUrl;
	CVServerConnectionMode mode;
}

- (id)initWithUrl:(NSURL *)aBaseUrl {
	self = [super init];
	if (self) {
		baseUrl = aBaseUrl;
	}
	
	return self;
}

+ (CVServerConnection*)connection:(NSURL *)baseUrl {
	[[NSURLCache sharedURLCache] setMemoryCapacity:0];
	[[NSURLCache sharedURLCache] setDiskCapacity:0];
	
	return [[CVServerConnection alloc] initWithUrl:baseUrl];
}

- (CVServerTransactionConnection*)begin:(id)configuration {
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:baseUrl];
	[request setTimeoutInterval:30.0];
	[request setHTTPMethod:@"POST"];
	AFHTTPRequestOperation* operation = [[AFHTTPRequestOperation alloc] initWithRequest:request];
	[operation start];
	[operation waitUntilFinished];
	NSString* sessionId = [operation responseString];
	return [[CVServerTransactionConnection alloc] initWithUrl:baseUrl andSessionId:sessionId];
}

@end

@implementation AbstractCVServerConnectionInput

- (id)initWithUrl:(NSURL*)aUrl session:(NSString*)aSessionId andDelegate:(id<CVServerConnectionDelegate>)aDelegate {
	self = [super init];
	if (self) {
		url = aUrl;
		sessionId = aSessionId;
		delegate = aDelegate;
		[self initConnectionInput];
	}
	return self;
}

- (void)initConnectionInput {
	// nothing in the abstract class
}

@end

/**
 * Uses plain JPEG encoding to submit the images from the incoming stream of frames
 */
@implementation CVServerConnectionInputStatic

- (void)submitFrame:(CMSampleBufferRef)frame {
	NSData* data = [@"FU" dataUsingEncoding:NSUTF8StringEncoding];
	
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
	[request setTimeoutInterval:30.0];
	[request setHTTPMethod:@"POST"];
	[request setHTTPBody:data];
	[request addValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
	AFHTTPRequestOperation* operation = [[AFHTTPRequestOperation alloc] initWithRequest:request];
	[operation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, id responseObject) {
		[delegate cvServerConnectionOk:responseObject];
	} failure:^(AFHTTPRequestOperation *operation, NSError *error) {
		[delegate cvServerConnectionFailed:error];
	}];
	[operation start];
	[operation waitUntilFinished];
}

- (void)stopRunning {
	// This is a static connection. Nothing to see here.
}

@end

/**
 * Uses the i264 encoder to encode the incoming stream of frames. 
 */
@implementation CVServerConnectionInputStream {
	BlockingQueueInputStream *stream;
}

- (void)initConnectionInput {
	stream = [[BlockingQueueInputStream alloc] init];

	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
	[request setTimeoutInterval:30.0];
	[request setHTTPMethod:@"POST"];
	[request setHTTPBodyStream:stream];
	[request addValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
	AFHTTPRequestOperation* operation = [[AFHTTPRequestOperation alloc] initWithRequest:request];
	[operation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, id responseObject) {
		[delegate cvServerConnectionOk:responseObject];
	} failure:^(AFHTTPRequestOperation *operation, NSError *error) {
		[delegate cvServerConnectionFailed:error];
	}];
	[operation start];
	
#if !(TARGET_IPHONE_SIMULATOR)
	int framesPerSecond = 25;
	encoder = [[i264Encoder alloc] initWithDelegate:self];
	[encoder setInPicHeight:[NSNumber numberWithInt:480]];
	[encoder setInPicWidth:[NSNumber numberWithInt:720]];
	[encoder setFrameRate:[NSNumber numberWithInt:framesPerSecond]];
	[encoder setKeyFrameInterval:[NSNumber numberWithInt:framesPerSecond * 5]];
	[encoder setAvgDataRate:[NSNumber numberWithInt:100000]];
	[encoder setBitRate:[NSNumber numberWithInt:100000]];
	[encoder startEncoder];
#endif
}

- (void)submitFrame:(CMSampleBufferRef)frame {
#if !(TARGET_IPHONE_SIMULATOR)
	CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(frame);
	[encoder encodePixelBuffer:pixelBuffer];
#endif
}

- (void)oni264Encoder:(i264Encoder *)encoder completedFrameData:(NSData *)data {
	NSData* sessionIdData = [sessionId dataUsingEncoding:NSASCIIStringEncoding];
	NSMutableData *frame = [NSMutableData dataWithData:sessionIdData];
	[frame appendData:data];
	[stream appendData:frame];
}

- (void)stopRunning {
	[stream appendData:[sessionId dataUsingEncoding:NSASCIIStringEncoding]];
	[stream close];
#if !(TARGET_IPHONE_SIMULATOR)
	[encoder stopEncoder];
#endif
}

@end