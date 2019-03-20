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

/**
var formatter = new NSDateFormatter();
formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z";
var date = NSDate.date();
var formattedDate = formatter.stringFromDate(date);
console.log(formattedDate);
**/

//NSTimer.scheduledTimerWithTimeInterval(2, null, "hideManual", null, false);

var url = NSURL.URLWithString("https://example.com");
var request = NSURLRequest.requestWithURL(url);
var queue = new NSOperationQueue();
NSURLConnection.sendAsynchronousRequestQueueCompletionHandler(request, queue, (response, data, connectionError) => {
    var res = NSString.alloc().initWithDataEncoding(data, NSUTF8StringEncoding);
    console.log(res);
});

//var a = NSMutableString.alloc().init();
 
//f();
//gc();
//console.log("Finished allocating objects");

//var aString = new NSMutableString.alloc().init();
//var hasAppend = aString.respondsToSelector("appendString:");
//console.log(hasAppend);

/**
var a = NSURL.alloc();
var b = a.init();
//console.log(Object.getOwnPropertyNames(a.__proto__));
//console.log("\n--------\n");
//console.log(Object.getOwnPropertyNames(b.__proto__));
console.log(a.__proto__ == b.__proto__);
 **/

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

