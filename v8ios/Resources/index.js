var f = () => {
    for (var i = 0; i < 1000000; i++) {
        //var obj = new NSObject();
        //var obj = new NSMutableString();
        var date = NSDate.date();
    }
};

//console.log(NSURLRequest.requestWithURL);
//var obj = new NSMutableString();
//obj.appendString("foo");
//NSURLRequest.requestWithURL();

var url = NSURL.URLWithString("http://example.com");
console.log(url);
//var date = NSDate.date();
//console.log(date);

//var formatter = new NSDateFormatter();
//var date = NSDate.date();
//var formattedDate = formatter.stringFromDate(date);
//console.log(formattedDate);

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

