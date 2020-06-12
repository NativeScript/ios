// Inform the test results runner that the runtime is up.
console.log('Application Start!');

require("./Infrastructure/timers");
require("./Infrastructure/simulator");
global.utf8 = require("./Infrastructure/utf8")

global.UNUSED = function (param) {
};

var args = NSProcessInfo.processInfo.arguments;
var logjunit = args.containsObject("-logjunit");

// Provides an output channel for jasmine JUnit test result xml.
global.__JUnitSaveResults = function (text) {
    TNSSaveResults(text);

    if (logjunit) {
        text.split('\n').forEach(function (line) {
            console.log("TKUnit: " + line);
        });
    }

    var reportUrl = NSProcessInfo.processInfo.environment.objectForKey("REPORT_BASEURL");
    if (reportUrl) {
        var urlRequest = NSMutableURLRequest.requestWithURL(NSURL.URLWithString(reportUrl));
        urlRequest.HTTPMethod = "POST";
        urlRequest.setValueForHTTPHeaderField("Content-Type", "application/xml");
        urlRequest.HTTPBody = NSString.stringWithString(text).dataUsingEncoding(4);
        var sessionConfig = NSURLSessionConfiguration.defaultSessionConfiguration;
        var queue = NSOperationQueue.mainQueue;
        var session = NSURLSession.sessionWithConfigurationDelegateDelegateQueue(sessionConfig, null, queue);
        var dataTask = session.dataTaskWithRequestCompletionHandler(urlRequest, (data, response, error) => { });
        dataTask.resume();
    }
};

global.__approot = NSString.stringWithString(NSBundle.mainBundle.bundlePath).stringByResolvingSymlinksInPath;

require("./Infrastructure/Jasmine/jasmine-2.0.1/boot");



describe("NSNotificationCenter", function () {

  /**
   * Trying to check if simpler case could exhibit same behavior with native classes as properties on the notification object
   * however this case appears to work fine
   */
//  it("NSNotification object should be native class and not NSProxy", done => {
//    new Promise((resolve, reject) => {
//
//      var observers = [];
//      var observer = NSNotificationCenter.defaultCenter.addObserverForNameObjectQueueUsingBlock(
//          'testv8',
//          null,
//          null,
//          function(notification) {
//            console.log('notification:', notification);
//            console.log('notification.name:', notification.name);
//            console.log('notification.object:', notification.object);
//            console.log('notification.object.testEmbeddedClass:', notification.object.testEmbeddedClass);
//            console.log('typeof notification.object:', typeof notification.object);
//            console.log('notification.object.constructor.name:', notification.object.constructor.name);
//            resolve(true);
//          }
//        );
//        observers.push(observer);
//
//        setTimeout(() => {
//          var obj = new TNSClassWithPlaceholder();
//
//          expect(obj.description).toBe("real");
//          NSNotificationCenter.defaultCenter.postNotificationNameObject('testv8', obj);
//        }, 1000);
//
//    }).then(res => {
//        expect(res).toBe(true);
//    }).catch(e => {
//        expect(true).toBe(false, "The catch callback of the promise was called");
//        done();
//    }).finally(() => {
//        done();
//    });
//  });

  /**
   * Problem Case:
   * MPMusicPlayerControllerPlaybackStateDidChangeNotification
   * emits an object of type MPMusicPlayerController
   * which has a nowPlayingItem property which should be a proper instance of MPMediaItem
   * however it's only a NSProxy with no valid properties
   * This same code works 100% in JavaScript Core runtime where the nowPlayingItem has all valid properties with valid values
   */
  it("Apple Music should emit nowPlayingItem MPMediaItem instance and not NSProxy object", done => {
    new Promise((resolve, reject) => {
      var observers = [];

      var playNow = () => {
        MPMusicPlayerController.systemMusicPlayer.prepareToPlayWithCompletionHandler(error => {
          if (error) {
            console.log('prepareToPlayWithCompletionHandler error:', error);
          }
//          console.log('MPMusicPlayerController.systemMusicPlayer:', MPMusicPlayerController.systemMusicPlayer);
//          console.log('MPMusicPlayerController.systemMusicPlayer.nowPlayingItem:', MPMusicPlayerController.systemMusicPlayer.nowPlayingItem);
          MPMusicPlayerController.systemMusicPlayer.play();
          MPMusicPlayerController.systemMusicPlayer.currentPlaybackRate = 1.0;
        });
        MPMusicPlayerController.systemMusicPlayer.beginGeneratingPlaybackNotifications();
        var observer = NSNotificationCenter.defaultCenter.addObserverForNameObjectQueueUsingBlock(
            MPMusicPlayerControllerPlaybackStateDidChangeNotification,
            null,
            null,
            function(notification) {
//              console.log('notification:', notification);
//              console.log('notification.name:', notification.name);
              if (notification.object) {
//                console.log('notification.object:', notification.object);
//                console.log('notification.object.constructor.name:', notification.object.constructor.name);
                if (notification.object.nowPlayingItem) {
                  console.log('notification.object.nowPlayingItem:', notification.object.nowPlayingItem);
                  console.log('SHOULD HAVE THIS PROPERTY nowPlayingItem.playbackStoreID:', notification.object.nowPlayingItem.playbackStoreID);
                  console.log('SHOULD HAVE THIS PROPERTY nowPlayingItem.title:', notification.object.nowPlayingItem.title);
                  resolve(true);
                }
              }
            }
          );
          observers.push(observer);
      }

      var requestPerm = () => {
        var cloudCtrl = SKCloudServiceController.new();
        cloudCtrl.requestCapabilitiesWithCompletionHandler((capability, error) => {
          if (error) {
            console.log('requestCapabilitiesWithCompletionHandler error:', error);
          }
//          console.log('capability:', capability);
          
          // switch (capability) {
          //   case SKCloudServiceCapability.MusicCatalogPlayback:
          //   case SKCloudServiceCapability.AddToCloudMusicLibrary:
          //   case 257:

          //   break;
          // }
          MPMusicPlayerController.systemMusicPlayer.setQueueWithStoreIDs(['1507894470']);
          playNow();
        });
      };

      var authStatus = SKCloudServiceController.authorizationStatus();
      if (authStatus === SKCloudServiceAuthorizationStatus.Authorized) {
        requestPerm();
      } else {
        SKCloudServiceController.requestAuthorization(status => {
          requestPerm();
        });
      }  

    }).then(res => {
        expect(res).toBe(true);
    }).catch(e => {
        expect(true).toBe(false, "The catch callback of the promise was called");
        done();
    }).finally(() => {
        done();
    });
  });
});

// require("./Marshalling/Primitives/Function");
// require("./Marshalling/Primitives/Static");
// require("./Marshalling/Primitives/Instance");
// require("./Marshalling/Primitives/Derived");
// //
// require("./Marshalling/ObjCTypesTests");
// require("./Marshalling/ConstantsTests");
// require("./Marshalling/RecordTests");
// require("./Marshalling/VectorTests");
// require("./Marshalling/MatrixTests");
// require("./Marshalling/NSStringTests");
// //import "./Marshalling/TypesTests";
// require("./Marshalling/PointerTests");
// require("./Marshalling/ReferenceTests");
// require("./Marshalling/FunctionPointerTests");
// require("./Marshalling/EnumTests");
// require("./Marshalling/ProtocolTests");
// //
// // import "./Inheritance/ConstructorResolutionTests";
// require("./Inheritance/InheritanceTests");
// require("./Inheritance/ProtocolImplementationTests");
// require("./Inheritance/TypeScriptTests");
// //
// require("./MethodCallsTests");
// //import "./FunctionsTests";
// require("./VersionDiffTests");
// require("./ObjCConstructors");
// //
// require("./MetadataTests");
// //
// require("./ApiTests");
// require("./DeclarationConflicts");
// //
// require("./Promises");
// require("./Modules");
// //
// require("./RuntimeImplementedAPIs");

// // Tests common for all runtimes.
// require("./shared/index").runAllTests();

execute();

UIApplicationMain(0, null, null, null);
