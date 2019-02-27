var base = require("./base"),
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
