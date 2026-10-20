#import <UIKit/UIKit.h>
#include <rex/memory/utils.h>
#include <rex/thread.h>
#include <rex/thread/fiber.h>
#include <atomic>
#include <chrono>
#include <memory>
#include <thread>
#include <unistd.h>

using namespace std::chrono_literals;
using Fiber = rex::thread::Fiber;
struct FiberState { Fiber* root; int count = 0; bool intact = true; };
static void FiberEntry(void* argument) {
    auto* state = static_cast<FiberState*>(argument);
    volatile uint64_t canary = 0x123456789ABCDEF0ULL;
    for (;;) {
        state->intact &= canary == 0x123456789ABCDEF0ULL;
        ++state->count;
        Fiber::SwitchTo(state->root);
    }
}

@interface SmokeController : UIViewController
@property(nonatomic,strong) UITextView* output;
@property(nonatomic,strong) NSMutableString* report;
@property(nonatomic,strong) NSURL* logURL;
@property(nonatomic,strong) NSMutableArray<UIButton*>* testButtons;
@property(nonatomic) BOOL busy;
- (void)record:(NSString*)line;
@end

@implementation SmokeController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    NSURL* documents = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    self.logURL = [documents URLByAppendingPathComponent:@"liberty-runtime-smoke.log"];
    NSString* previous = [NSString stringWithContentsOfURL:self.logURL encoding:NSUTF8StringEncoding error:nil];
    self.report = [NSMutableString stringWithString:previous ?: @""];
    self.testButtons = [NSMutableArray array];
    UIStackView* stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel* title = [[UILabel alloc] init];
    title.text = @"Liberty runtime checks";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    [stack addArrangedSubview:title];
    UILabel* subtitle = [[UILabel alloc] init];
    subtitle.text = @"Real runtime core. Run tests in order. GTA IV is not included. If a test closes the app, reopen it and share the saved log.";
    subtitle.numberOfLines = 0;
    [stack addArrangedSubview:subtitle];
    NSArray* labels = @[@"1. Test memory", @"2. Test threads and events", @"3. Test fibre switching", @"Share saved log"];
    SEL actions[] = {@selector(memoryTest), @selector(threadTest), @selector(fiberTest), @selector(shareLog:)};
    for (NSUInteger i=0; i<labels.count; ++i) {
        UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:labels[i] forState:UIControlStateNormal];
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        [button addTarget:self action:actions[i] forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:button];
        if(i<3) [self.testButtons addObject:button];
    }
    self.output = [[UITextView alloc] init];
    self.output.editable = NO;
    self.output.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.output.text = self.report;
    [stack addArrangedSubview:self.output];
    [self.view addSubview:stack];
    UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.output.heightAnchor constraintGreaterThanOrEqualToConstant:160]
    ]];
    [self record:@"--- Runtime smoke 0.2 launch; source 1922957d9f5a ---"];
    [self record:[NSString stringWithFormat:@"%@ %@; RAM %llu MiB", UIDevice.currentDevice.systemName, UIDevice.currentDevice.systemVersion, NSProcessInfo.processInfo.physicalMemory/1048576]];
}
- (void)record:(NSString*)line {
    @synchronized(self) {
        [self.report appendFormat:@"%@  %@\n", [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]], line];
        NSError* error = nil;
        BOOL saved = [self.report writeToURL:self.logURL atomically:YES encoding:NSUTF8StringEncoding error:&error];
        NSString* text = [self.report copy];
        if (!saved) text = [text stringByAppendingFormat:@"\nLOG WRITE FAILED: %@", error.localizedDescription];
        dispatch_async(dispatch_get_main_queue(), ^{ self.output.text = text; });
    }
}
- (void)run:(NSString*)name block:(void (^)(void))test {
    if(self.busy) return;
    self.busy = YES;
    for(UIButton* b in self.testButtons) b.enabled = NO;
    [self record:[@"BEGIN " stringByAppendingString:name]];
    std::thread([self, test, name] {
        @autoreleasepool {
            try { test(); }
            catch(const std::exception& e) { [self record:[NSString stringWithFormat:@"FAIL exception: %s",e.what()]]; }
            catch(...) { [self record:@"FAIL unknown C++ exception"]; }
            [self record:[@"END " stringByAppendingString:name]];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                for(UIButton* b in self.testButtons) b.enabled = YES;
            });
        }
    }).detach();
}
- (void)memoryTest {
    [self run:@"memory" block:^{
        using namespace rex::memory;
        const size_t size = static_cast<size_t>(getpagesize()) * 4;
        void* allocation = AllocFixed(nullptr, size, AllocationType::kReserveCommit, PageAccess::kReadWrite);
        if(!allocation) { [self record:@"FAIL runtime allocation"]; return; }
        auto* bytes = static_cast<volatile unsigned char*>(allocation);
        for(size_t i=0;i<size;++i) bytes[i] = static_cast<unsigned char>(i*37);
        bool valid = true;
        for(size_t i=0;i<size;++i) if(bytes[i] != static_cast<unsigned char>(i*37)) valid = false;
        [self record:valid ? @"PASS runtime page allocation and read-back" : @"FAIL memory data mismatch"];
        size_t length = 0; PageAccess access = PageAccess::kNoAccess;
        bool query = QueryProtect(allocation,length,access);
        [self record:(query && length>=size && access==PageAccess::kReadWrite) ? @"PASS memory region query (read/write)" : @"FAIL memory region query"];
        bool readonly = Protect(allocation,size,PageAccess::kReadOnly);
        query = QueryProtect(allocation,length,access);
        [self record:(readonly && query && access==PageAccess::kReadOnly) ? @"PASS protection change to read-only" : @"FAIL read-only protection/query"];
        bool writable = Protect(allocation,size,PageAccess::kReadWrite);
        [self record:writable ? @"PASS protection restored to read/write" : @"FAIL restoring page protection"];
        if(writable) { bytes[0]=0x5A; [self record:bytes[0]==0x5A ? @"PASS write after restoring protection" : @"FAIL restored write"]; }
        [self record:DeallocFixed(allocation,size,DeallocationType::kRelease) ? @"PASS runtime page release" : @"FAIL runtime page release"];
        [self record:@"Scope: small anonymous data pages; no executable pages or guest fixed-address reservation tested."];
    }];
}
- (void)threadTest {
    [self run:@"threads/events" block:^{
        using namespace rex::thread;
        auto event = Event::CreateAutoResetEvent(false);
        bool empty = event && Wait(event.get(),false,0ms)==WaitResult::kTimeout;
        if(event) event->Set();
        bool signaled = event && Wait(event.get(),false,100ms)==WaitResult::kSuccess;
        bool reset = event && Wait(event.get(),false,0ms)==WaitResult::kTimeout;
        [self record:(empty && signaled && reset) ? @"PASS runtime event timeout, signal and auto-reset" : @"FAIL runtime event operations"];
        auto semaphore = Semaphore::Create(1,2);
        bool sem = semaphore && Wait(semaphore.get(),false,100ms)==WaitResult::kSuccess;
        sem = sem && Wait(semaphore.get(),false,0ms)==WaitResult::kTimeout;
        int prior = -1;
        sem = sem && semaphore->Release(1,&prior) && prior==0;
        sem = sem && Wait(semaphore.get(),false,100ms)==WaitResult::kSuccess;
        [self record:sem ? @"PASS runtime semaphore acquire/release" : @"FAIL runtime semaphore"];
        auto marker = std::make_shared<std::atomic<int>>(0);
        auto worker = Thread::Create(Thread::CreationParameters{},[marker] { marker->store(42); });
        bool finished = worker && Wait(worker.get(),false,2000ms)==WaitResult::kSuccess;
        [self record:(finished && marker->load()==42) ? @"PASS runtime thread creation, execution and completion wait" : @"FAIL runtime thread/completion wait"];
        if(worker && !finished) { (void)worker.release(); [self record:@"Thread handle retained because completion was not confirmed."]; }
        [self record:@"Scope: normal thread startup; thread suspension/resumption is not tested."];
    }];
}
- (void)fiberTest {
    [self run:@"fibres" block:^{
        Fiber* root = Fiber::ConvertCurrentThread();
        if(!root) { [self record:@"FAIL converting worker to fibre"]; return; }
        FiberState state{root};
        Fiber* child = Fiber::Create(256*1024,FiberEntry,&state);
        if(!child) { root->Destroy(); [self record:@"FAIL creating fibre stack"]; return; }
        [self record:@"Fibre stack created. Entering 100 switches; a crash here identifies the switching path."];
        for(int i=0;i<100;++i) Fiber::SwitchTo(child);
        bool pass = state.count==100 && state.intact && Fiber::Current()==root;
        child->Destroy(); root->Destroy();
        [self record:pass ? @"PASS 100 fibre round trips, stack canary and current-context tracking" : @"FAIL fibre result/context mismatch"];
        [self record:@"Scope: basic cooperative switching; full guest register/SIMD preservation is not established."];
    }];
}
- (void)shareLog:(UIButton*)sender {
    UIActivityViewController* share = [[UIActivityViewController alloc] initWithActivityItems:@[self.logURL] applicationActivities:nil];
    share.popoverPresentationController.sourceView = sender;
    share.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:share animated:YES completion:nil];
}
@end

@interface SmokeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow* window;
@end
@implementation SmokeDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[SmokeController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc,char* argv[]) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(SmokeDelegate.class)); } }
