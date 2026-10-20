// Type-checked by the TypeScriptUsageCompiles test against types/index.d.ts and
// the generated swift!SwiftDemo.d.ts snapshot. Every @ts-expect-error line
// must fail to compile: an unused directive is itself an error.
import * as swift from "ns:swift";
import { Demo, Point, Flavor, Polygon, Measurement, Square, Tracker, Counter, Palette, shout, globalCounter, delayedEcho, makeTrackerLater } from "ns:swift/SwiftDemo";

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

// @ts-expect-error  actor state is not assignable from outside the actor
new Counter().step = 2;
// @ts-expect-error  description is read-only
point.description = "x";
// @ts-expect-error  ambiguous overloads are not callable by base name
square.scale(2);
// @ts-expect-error  Flavor is a union of case names
const bad: Flavor = "mint";
// @ts-expect-error  ShapeError (an enum with associated values) is not bridged
SwiftDemo.ShapeError;
void [greeting, twice, x, text, maybe, live, counter, bad];
