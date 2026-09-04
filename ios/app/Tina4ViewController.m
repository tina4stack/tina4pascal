#import "Tina4ViewController.h"
#import "Tina4View.h"

@implementation Tina4ViewController {
    Tina4View *_view;
}

- (void)loadView {
    _view = [[Tina4View alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _view.host = self;
    self.view = _view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NSString *path = [[NSBundle mainBundle] pathForResource:@"controls" ofType:@"html"];
    NSString *html = [NSString stringWithContentsOfFile:path
        encoding:NSUTF8StringEncoding error:nil];
    if (!html) html = @"<body><h1>controls.html not found</h1></body>";
    [_view loadHTML:html];
}

@end
