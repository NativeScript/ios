describe("MusicKit NSProxy Issue", function () {

  /**
   * Problem Case:
   * MPMusicPlayerControllerPlaybackStateDidChangeNotification
   * emitted an object of type MPMusicPlayerController
   * which has a nowPlayingItem property which should be a proper instance of MPMediaItem
   * however it's only a NSProxy with no valid properties
   */
  it("nowPlayingItem should be a concrete MPMediaItem instance and not NSProxy object", done => {
    new Promise((resolve, reject) => {
      var observers = [];

      var playNow = () => {
        MPMusicPlayerController.systemMusicPlayer.prepareToPlayWithCompletionHandler(error => {
          if (error) {
            console.log('prepareToPlayWithCompletionHandler error:', error);
          }
          MPMusicPlayerController.systemMusicPlayer.play();
          MPMusicPlayerController.systemMusicPlayer.currentPlaybackRate = 1.0;
        });
        MPMusicPlayerController.systemMusicPlayer.beginGeneratingPlaybackNotifications();
        var observer = NSNotificationCenter.defaultCenter.addObserverForNameObjectQueueUsingBlock(
            MPMusicPlayerControllerPlaybackStateDidChangeNotification,
            null,
            null,
            function(notification) {
              if (notification.object && notification.object.nowPlayingItem) {
                if (notification.object.nowPlayingItem.playbackStoreID && notification.object.nowPlayingItem.title) {
                    console.log('notification.object.nowPlayingItem:', notification.object.nowPlayingItem);
                    console.log('nowPlayingItem.playbackStoreID:', notification.object.nowPlayingItem.playbackStoreID);
                    console.log('nowPlayingItem.title:', notification.object.nowPlayingItem.title);
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
          //console.log('capability:', capability);
          
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
