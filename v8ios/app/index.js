var f = () => {
   for (var i = 0; i < 100000; i++) {
       var obj = new NSObject();
       var str = new NSMutableString();
       var date = NSDate.date();
       var url = NSURL.URLWithString("https://example.com");
       var request = NSURLRequest.requestWithURL(url);
       var a = NSMutableString.alloc();
       var b = a.init();
   }
};

//f();
//gc();
//gc();
//console.log("Finished allocating objects\n");

//var formatter = new NSDateFormatter();
//formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z";
//var date = NSDate.date();
//var formattedDate = formatter.stringFromDate(date);
//console.log(formattedDate.UTF8String);

require("./CanvasViewController");
require("./DetailViewController");
require("./MasterViewController");

var TNSAppDelegate = UIResponder.extend({
    get window() {
        return this._window;
    },
    set window(aWindow) {
        this._window = aWindow;
    }
}, {
    protocols: [UIApplicationDelegate]
});

//setTimeout(() => gc(), 10000);
UIApplicationMain(0, null, null, TNSAppDelegate.name);


//var TimerTarget = NSObject.extend({
//    tick: (timer) => {
//        console.log(timer.userInfo.UTF8String);
//    }
//}, {
//    exposedMethods: {
//        tick: {
//            returns: "v",
//            params: [ NSTimer ]
//        }
//    }
//});
//var target = new TimerTarget();
//NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(2.0, target, "tick:", "my user info", false);

//var url = NSURL.URLWithString("https://example.com");
//var request = NSURLRequest.requestWithURL(url);
//var queue = new NSOperationQueue();
//var cb = (response, data, connectionError) => {
//    var res = NSString.alloc().initWithDataEncoding(data, NSUTF8StringEncoding);
//    console.log(res.UTF8String);
//};
//NSURLConnection.sendAsynchronousRequestQueueCompletionHandler(request, queue, cb);


//var MyViewController = UIViewController.extend({
//   // Override an existing method from the base class.
//   // We will obtain the method signature from the protocol.
//   viewDidLoad: function () {
//        console.log("AAAA");
//       // Call super using the prototype:
//       //UIViewController.prototype.viewDidLoad.apply(this, arguments);
//       // or the super property:
//       this.super.viewDidLoad();
//
//       // Add UI to the view here...
//   },
////   shouldAutorotate: function () { return false; },
////
////   // You can override existing properties
////   get modalInPopover() { return this.super.modalInPopover; },
////   set modalInPopover(x) { this.super.modalInPopover = x; },
////
////   // Additional JavaScript instance methods or properties that are not accessible from Objective-C code.
////   myMethod: function() { },
////
//   get myProperty() { return true; },
//   set myProperty(x) { },
//   myMethod: function() {
//    console.log("aaaa");
//   }
//}, {
//   name: "MyViewController"
//});

//var aString = new NSMutableString.alloc().init();
//var hasAppend = aString.respondsToSelector("appendString:");
//console.log(hasAppend);

/**
var array = new NSMutableArray();
var buttonClass = UIButton;
var button = new buttonClass();
array.setObjectAtIndexedSubscript(buttonClass, 0);
array.setObjectAtIndexedSubscript(button, 1);
 **/



/**
var base = require("./base"),
    //regexp = require("./regexp"),
    richards = require("./richards"),
    deltablue = require("./deltablue"),
    crypto = require("./crypto"),
    raytrace = require("./raytrace"),
    earleyBoyer = require("./earley-boyer"),
    splay = require("./splay"),
    navierStokes = require("./navier-stokes"),
    mandreel = require("./mandreel"),
    box2D = require("./box2d");

BenchmarkSuite.RunSuites({
    NotifyStart : name => console.log(`Starting suite ${name}\n`),
    NotifyError : (name, result) => console.log(`Error: name: ${name}: ${result}\n`),
    NotifyResult : (name, result) => console.log(`Result of ${name}: ${result}\n`),
    NotifyScore : score => console.log(`Octane benchmark score: ${score}`)
}, []);
 **/

