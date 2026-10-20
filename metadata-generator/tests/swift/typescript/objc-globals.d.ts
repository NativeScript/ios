// The few Objective-C classes the SwiftDemo declarations name, standing in
// for @nativescript/types-ios.
declare class NSObject {}
declare class UIResponder extends NSObject {}
declare class UIView extends UIResponder {
  tag: number;
}
declare class UILabel extends UIView {
  text: string;
}
