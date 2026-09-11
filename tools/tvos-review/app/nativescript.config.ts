export default {
  id: 'org.nativescript.tvosreview',
  projectName: 'TVOSReview',
  appPath: 'app',
  main: 'app/app.js',
  appResourcesPath: 'App_Resources',
  tvos: {
    discardUncaughtJsExceptions: false,
    SPMPackages: [{ name: 'FontManager', libs: ['FontManager'], path: '../font-manager/packages/font-manager/src-native/ios/FontManager' }],
  },
};
