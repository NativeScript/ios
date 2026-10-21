// Type-checked by the TypeScriptUsageCompiles test against types/index.d.ts and
// the generated swift!SwiftDemo.d.ts snapshot. Every @ts-expect-error line
// must fail to compile: an unused directive is itself an error.
import * as swift from "ns:swift";
import * as Kit from "ns:swift/SwiftDemoKit";
import type * as SwiftDemoTypes from "ns:swift/SwiftDemo";
import { Demo, Point, Flavor, Polygon, Measurement, Square, Tracker, Counter, Palette, shout, globalCounter, delayedEcho, makeTrackerLater, countdown, greetLater, transform, lookup, Notifier, measure, area, simplify, echo, Formula, bump, append, describe, firstSubview, makeNote } from "ns:swift/SwiftDemo";

const SwiftDemo = swift.module("SwiftDemo");
const demo: Demo = new SwiftDemo.Demo();
const greeting: string = demo.greet("NativeScript");
const twice: string = demo.greet("a", 2n);
const point = new Point({ x: 2, y: 3 });
const x: number = point.x;
point.y = 4;
const flavor: Flavor = Flavor.init(1) ?? Flavor.vanilla;
const text: string = Flavor.description(flavor);
const square: Polygon = new Square(3);
square["scale(by: Int)"](2);
const maybe: string | null = shout(null);
const live: number = Tracker.liveCount;
const counter: number = globalCounter;

const style: Polygon.Style = new Polygon("p").style;
const metrics: Polygon.Metrics = new Polygon.Metrics({ perimeter: 3 });
const unit = new Measurement.Unit("m");
const dashed: Polygon.Style = Polygon.Style.dashed;
void [style, metrics.perimeter, unit.symbol, dashed];

const echoed: Promise<string> = delayedEcho("x", 0.1);
const later: Promise<Tracker> = makeTrackerLater(1);
const counterValue: Promise<number> = new Counter().value;
const strokes: number = new Palette().stroke();
void [echoed, later, counterValue, strokes];

countdown(3, (value, done) => void (value.toFixed() + (done ? "!" : "")));
transform([1, 2], (n) => n.toFixed()).concat(["x"]);
lookup("k", () => null).toFixed();
greetLater(null, (greeting) => greeting?.toUpperCase());
const notifier = new Notifier();
notifier.subscribe((message) => message.length);

const measured = measure(2, 3);
const width: number = measured.case === "area" ? measured.width : 0;
const sum: Formula = simplify({ case: "sum", 0: { case: "number", value: 1 }, 1: { case: "number", value: 2 } });
const payload = echo({ case: "maybe", value: null });
void [width, sum, payload, area({ case: "none" })];
const counterRef = { value: 1 };
bump(counterRef);
const words = { value: ["a"] };
append("b", words);
void [counterRef.value.toFixed(), words.value.length];
const view = new UIView();
const subview: UIView | null = firstSubview(view);
void [describe(view), subview, makeNote("n")];
// @ts-expect-error  Objective-C parameters are typed
describe("view");
const pair: Kit.Pair<number, string> = new Kit.Pair(1, "one");
const swappedPair: Kit.Pair<string, number> = pair.swapped();
const score: SwiftDemoTypes.Score = SwiftDemo.makeScore("ada", 3);
const settled = SwiftDemo.settle(1);
const settledValue: number = settled.case === "done" ? settled.value : 0;
void [swappedPair, score, settledValue, SwiftDemo.describe(pair)];
const jsGreeting: SwiftDemoTypes.Greeting = {
  name: "js",
  punctuation: "?",
  greet: (other) => "hi " + other,
  reset() {},
};
void [SwiftDemo.introduce(jsGreeting, "you"), SwiftDemo.makeGreeting("swift").greet("x")];
// @ts-expect-error  an implementation provides every requirement
SwiftDemo.introduce({ name: "js", greet: (other: string) => other }, "you");
// @ts-expect-error  an instantiation's arguments are typed
SwiftDemo.describe(new Kit.Pair("one", 1));
// @ts-expect-error  inout parameters take a reference object
bump(1);
// @ts-expect-error  a case's values are typed
area({ case: "area", width: "2", height: 3 });
// @ts-expect-error  only the enum's cases are accepted
area({ case: "circle" });

// @ts-expect-error  closure arguments are typed
countdown(3, (value: string) => value);
// @ts-expect-error  closure results are typed
transform([1], (n) => n);
// @ts-expect-error  actor state is not assignable from outside the actor
new Counter().step = 2;
// @ts-expect-error  description is read-only
point.description = "x";
// @ts-expect-error  ambiguous overloads are not callable by base name
square.scale(2);
// @ts-expect-error  Flavor is a union of case names
const bad: Flavor = "mint";
// @ts-expect-error  Job (a closure payload) is not bridged, only its nested types
SwiftDemo.Job.idle;
new SwiftDemo.Job.Ticket(1);
void [greeting, twice, x, text, maybe, live, counter, bad];
