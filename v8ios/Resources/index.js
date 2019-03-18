var f = () => {
    for (var i = 0; i < 10000000; i++) {
        //var obj = new NSObject();
        //var obj = new NSMutableString();
        var date = NSDate.date();
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
    console.log(response);
});

//f();
//console.log("Finished allocating objects");



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

