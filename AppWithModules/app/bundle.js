require("./runtime.js");require("./vendor.js");module.exports =
(global["webpackJsonp"] = global["webpackJsonp"] || []).push([["bundle"],{

/***/ "../$$_lazy_route_resource lazy recursive":
/***/ (function(module, exports) {

function webpackEmptyAsyncContext(req) {
	// Here Promise.resolve().then() is used instead of new Promise() to prevent
	// uncaught exception popping up in devtools
	return Promise.resolve().then(function() {
		var e = new Error("Cannot find module '" + req + "'");
		e.code = 'MODULE_NOT_FOUND';
		throw e;
	});
}
webpackEmptyAsyncContext.keys = function() { return []; };
webpackEmptyAsyncContext.resolve = webpackEmptyAsyncContext;
module.exports = webpackEmptyAsyncContext;
webpackEmptyAsyncContext.id = "../$$_lazy_route_resource lazy recursive";

/***/ }),

/***/ "./app.css":
/***/ (function(module, exports, __webpack_require__) {

/* WEBPACK VAR INJECTION */(function(global) {exports = module.exports = __webpack_require__("../node_modules/css-loader/dist/runtime/api.js")(false);
// Imports
exports.i(__webpack_require__("../node_modules/css-loader/dist/cjs.js?!../node_modules/nativescript-theme-core/css/core.light.css"), "");

// Module
exports.push([module.i, "/*\nIn NativeScript, the app.css file is where you place CSS rules that\nyou would like to apply to your entire application. Check out\nhttp://docs.nativescript.org/ui/styling for a full list of the CSS\nselectors and properties you can use to style UI components.\n\n/*\nIn many cases you may want to use the NativeScript core theme instead\nof writing your own CSS rules. For a full list of class names in the theme\nrefer to http://docs.nativescript.org/ui/theme.\n*/\n", ""]);

;
    if (true) {
        module.hot.accept();
        module.hot.dispose(() => {
            global.hmrRefresh({ type: 'style', path: './app.css' });
        })
    }

/* WEBPACK VAR INJECTION */}.call(this, __webpack_require__("../node_modules/webpack/buildin/global.js")))

/***/ }),

/***/ "./app/app-routing.module.ts":
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "AppRoutingModule", function() { return AppRoutingModule; });
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__("../node_modules/@angular/core/fesm5/core.js");
/* harmony import */ var nativescript_angular_router__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__("../node_modules/nativescript-angular/router/index.js");
/* harmony import */ var nativescript_angular_router__WEBPACK_IMPORTED_MODULE_1___default = /*#__PURE__*/__webpack_require__.n(nativescript_angular_router__WEBPACK_IMPORTED_MODULE_1__);
/* harmony import */ var _item_items_component__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__("./app/item/items.component.ts");
/* harmony import */ var _item_item_detail_component__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__("./app/item/item-detail.component.ts");




var routes = [
    { path: "", redirectTo: "/items", pathMatch: "full" },
    { path: "items", component: _item_items_component__WEBPACK_IMPORTED_MODULE_2__["ItemsComponent"] },
    { path: "item/:id", component: _item_item_detail_component__WEBPACK_IMPORTED_MODULE_3__["ItemDetailComponent"] }
];
var AppRoutingModule = /** @class */ (function () {
    function AppRoutingModule() {
    }
    AppRoutingModule = __decorate([
        Object(_angular_core__WEBPACK_IMPORTED_MODULE_0__["NgModule"])({
            imports: [nativescript_angular_router__WEBPACK_IMPORTED_MODULE_1__["NativeScriptRouterModule"].forRoot(routes)],
            exports: [nativescript_angular_router__WEBPACK_IMPORTED_MODULE_1__["NativeScriptRouterModule"]]
        })
    ], AppRoutingModule);
    return AppRoutingModule;
}());



/***/ }),

/***/ "./app/app.component.html":
/***/ (function(module, exports) {

module.exports = "<!-- https://docs.nativescript.org/angular/core-concepts/angular-navigation.html#page-router-outlet -->\n<page-router-outlet></page-router-outlet>\n"

/***/ }),

/***/ "./app/app.component.ts":
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "AppComponent", function() { return AppComponent; });
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__("../node_modules/@angular/core/fesm5/core.js");

var AppComponent = /** @class */ (function () {
    function AppComponent() {
    }
    AppComponent = __decorate([
        Object(_angular_core__WEBPACK_IMPORTED_MODULE_0__["Component"])({
            selector: "ns-app",
            template: __webpack_require__("./app/app.component.html")
        })
    ], AppComponent);
    return AppComponent;
}());



/***/ }),

/***/ "./app/app.module.ts":
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "AppModule", function() { return AppModule; });
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__("../node_modules/@angular/core/fesm5/core.js");
/* harmony import */ var nativescript_angular_nativescript_module__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__("../node_modules/nativescript-angular/nativescript.module.js");
/* harmony import */ var nativescript_angular_nativescript_module__WEBPACK_IMPORTED_MODULE_1___default = /*#__PURE__*/__webpack_require__.n(nativescript_angular_nativescript_module__WEBPACK_IMPORTED_MODULE_1__);
/* harmony import */ var _app_routing_module__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__("./app/app-routing.module.ts");
/* harmony import */ var _app_component__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__("./app/app.component.ts");
/* harmony import */ var _item_items_component__WEBPACK_IMPORTED_MODULE_4__ = __webpack_require__("./app/item/items.component.ts");
/* harmony import */ var _item_item_detail_component__WEBPACK_IMPORTED_MODULE_5__ = __webpack_require__("./app/item/item-detail.component.ts");






// Uncomment and add to NgModule imports if you need to use two-way binding
// import { NativeScriptFormsModule } from "nativescript-angular/forms";
// Uncomment and add to NgModule imports if you need to use the HttpClient wrapper
// import { NativeScriptHttpClientModule } from "nativescript-angular/http-client";
var AppModule = /** @class */ (function () {
    /*
    Pass your application module to the bootstrapModule function located in main.ts to start your app
    */
    function AppModule() {
    }
    AppModule = __decorate([
        Object(_angular_core__WEBPACK_IMPORTED_MODULE_0__["NgModule"])({
            bootstrap: [
                _app_component__WEBPACK_IMPORTED_MODULE_3__["AppComponent"]
            ],
            imports: [
                nativescript_angular_nativescript_module__WEBPACK_IMPORTED_MODULE_1__["NativeScriptModule"],
                _app_routing_module__WEBPACK_IMPORTED_MODULE_2__["AppRoutingModule"]
            ],
            declarations: [
                _app_component__WEBPACK_IMPORTED_MODULE_3__["AppComponent"],
                _item_items_component__WEBPACK_IMPORTED_MODULE_4__["ItemsComponent"],
                _item_item_detail_component__WEBPACK_IMPORTED_MODULE_5__["ItemDetailComponent"]
            ],
            providers: [],
            schemas: [
                _angular_core__WEBPACK_IMPORTED_MODULE_0__["NO_ERRORS_SCHEMA"]
            ]
        })
        /*
        Pass your application module to the bootstrapModule function located in main.ts to start your app
        */
    ], AppModule);
    return AppModule;
}());



/***/ }),

/***/ "./app/item/item-detail.component.html":
/***/ (function(module, exports) {

module.exports = "<ActionBar title=\"Details\" class=\"action-bar\"></ActionBar>\n<FlexboxLayout flexDirection=\"column\" class=\"page\">\n    <FlexboxLayout class=\"m-15\">\n        <Label class=\"h2\" [text]=\"item.id + '. '\"></Label>\n        <Label class=\"h2\" [text]=\"item.name\"></Label>\n    </FlexboxLayout>\n    <Label class=\"h4\" [text]=\"item.role\"></Label>\n</FlexboxLayout>\n"

/***/ }),

/***/ "./app/item/item-detail.component.ts":
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "ItemDetailComponent", function() { return ItemDetailComponent; });
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__("../node_modules/@angular/core/fesm5/core.js");
/* harmony import */ var _angular_router__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__("../node_modules/@angular/router/fesm5/router.js");
/* harmony import */ var tns_core_modules_http__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__("../node_modules/tns-core-modules/http/http.js");
/* harmony import */ var tns_core_modules_http__WEBPACK_IMPORTED_MODULE_2___default = /*#__PURE__*/__webpack_require__.n(tns_core_modules_http__WEBPACK_IMPORTED_MODULE_2__);
/* harmony import */ var _item_service__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__("./app/item/item.service.ts");




var ItemDetailComponent = /** @class */ (function () {
    function ItemDetailComponent(itemService, route) {
        this.itemService = itemService;
        this.route = route;
    }
    ItemDetailComponent.prototype.ngOnInit = function () {
        var id = +this.route.snapshot.params.id;
        this.item = this.itemService.getItem(id);

        Object(tns_core_modules_http__WEBPACK_IMPORTED_MODULE_2__["request"])({
            url: "https://httpbin.org/post",
            method: "POST",
            headers: { "Content-Type": "application/json" },
            content: JSON.stringify({
                username: "usr",
                password: "pwd"
            })
        }).then(function (response) {
            console.log(response.content.toString());
        }, function (e) {
            console.log(e);
        });


        // Object(tns_core_modules_http__WEBPACK_IMPORTED_MODULE_2__["getString"])("https://httpbin.org/get").then(function (r) {
        //     console.log(r);
        // }, function (e) {
        //     console.log(e);
        // });
    };
    ItemDetailComponent.ctorParameters = function () { return [
        { type: _item_service__WEBPACK_IMPORTED_MODULE_3__["ItemService"] },
        { type: _angular_router__WEBPACK_IMPORTED_MODULE_1__["ActivatedRoute"] }
    ]; };
    ItemDetailComponent = __decorate([
        Object(_angular_core__WEBPACK_IMPORTED_MODULE_0__["Component"])({
            selector: "ns-details",
            template: __webpack_require__("./app/item/item-detail.component.html")
        }),
        __metadata("design:paramtypes", [_item_service__WEBPACK_IMPORTED_MODULE_3__["ItemService"],
            _angular_router__WEBPACK_IMPORTED_MODULE_1__["ActivatedRoute"]])
    ], ItemDetailComponent);
    return ItemDetailComponent;
}());



/***/ }),

/***/ "./app/item/item.service.ts":
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "ItemService", function() { return ItemService; });
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__("../node_modules/@angular/core/fesm5/core.js");

var ItemService = /** @class */ (function () {
    function ItemService() {
        this.items = new Array({ id: 1, name: "Ter Stegen", role: "Goalkeeper" }, { id: 3, name: "Piqué", role: "Defender" }, { id: 4, name: "I. Rakitic", role: "Midfielder" }, { id: 5, name: "Sergio", role: "Midfielder" }, { id: 6, name: "Denis Suárez", role: "Midfielder" }, { id: 7, name: "Arda", role: "Midfielder" }, { id: 8, name: "A. Iniesta", role: "Midfielder" }, { id: 9, name: "Suárez", role: "Forward" }, { id: 10, name: "Messi", role: "Forward" }, { id: 11, name: "Neymar", role: "Forward" }, { id: 12, name: "Rafinha", role: "Midfielder" }, { id: 13, name: "Cillessen", role: "Goalkeeper" }, { id: 14, name: "Mascherano", role: "Defender" }, { id: 17, name: "Paco Alcácer", role: "Forward" }, { id: 18, name: "Jordi Alba", role: "Defender" }, { id: 19, name: "Digne", role: "Defender" }, { id: 20, name: "Sergi Roberto", role: "Midfielder" }, { id: 21, name: "André Gomes", role: "Midfielder" }, { id: 22, name: "Aleix Vidal", role: "Midfielder" }, { id: 23, name: "Umtiti", role: "Defender" }, { id: 24, name: "Mathieu", role: "Defender" }, { id: 25, name: "Masip", role: "Goalkeeper" });
    }
    ItemService.prototype.getItems = function () {
        return this.items;
    };
    ItemService.prototype.getItem = function (id) {
        return this.items.filter(function (item) { return item.id === id; })[0];
    };
    ItemService = __decorate([
        Object(_angular_core__WEBPACK_IMPORTED_MODULE_0__["Injectable"])({
            providedIn: "root"
        })
    ], ItemService);
    return ItemService;
}());



/***/ }),

/***/ "./app/item/items.component.html":
/***/ (function(module, exports) {

module.exports = "<!--\nThe template defines the view of the component - what is actually rendered.\nIn NativeScript applications the template is defined with XML using NativeScript UI elements.\nIt is different from HTML. So instead of <input>, <span>, <div> etc. - we have <TextField>, <Label> and layouts.\nThe important thing is that although the elements are different - all of the Angular’s template syntax works exactly the same.\nSo you can still use template expressions, bindings, templates as well as all the built-in directives.\n-->\n\n<!--\nThe ActionBar is the NativeScript common abstraction over the Android ActionBar and iOS NavigationBar.\nhttp://docs.nativescript.org/ui/action-bar\n-->\n<ActionBar title=\"My App\" class=\"action-bar\">\n</ActionBar>\n\n<!--\nThe GridLayout arranges its child elements in a table structure of rows and columns.\nA cell can contain multiple child elements, they can span over multiple rows and columns, \nand even overlap each other. The GridLayout has one column and one row by default.\nYou can learn more about NativeScript layouts at https://docs.nativescript.org/ui/layout-containers.\n\nThese components make use of several CSS class names that are part of the NativeScript\ncore theme, such as p-20, btn, h2, and list-group. You can view a full list of the\nclass names available for styling your app at https://docs.nativescript.org/ui/theme.\n-->\n<GridLayout class=\"page\">\n    <ListView [items]=\"items\" class=\"list-group\">\n        <ng-template let-item=\"item\">\n            <Label [nsRouterLink]=\"['/item', item.id]\" [text]=\"item.name\"\n                class=\"list-group-item\"></Label>\n        </ng-template>\n    </ListView>\n</GridLayout>\n"

/***/ }),

/***/ "./app/item/items.component.ts":
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "ItemsComponent", function() { return ItemsComponent; });
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__("../node_modules/@angular/core/fesm5/core.js");
/* harmony import */ var _item_service__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__("./app/item/item.service.ts");


var ItemsComponent = /** @class */ (function () {
    function ItemsComponent(itemService) {
        this.itemService = itemService;
    }
    ItemsComponent.prototype.ngOnInit = function () {
        this.items = this.itemService.getItems();
    };
    ItemsComponent.ctorParameters = function () { return [
        { type: _item_service__WEBPACK_IMPORTED_MODULE_1__["ItemService"] }
    ]; };
    ItemsComponent = __decorate([
        Object(_angular_core__WEBPACK_IMPORTED_MODULE_0__["Component"])({
            selector: "ns-items",
            template: __webpack_require__("./app/item/items.component.html")
        }),
        __metadata("design:paramtypes", [_item_service__WEBPACK_IMPORTED_MODULE_1__["ItemService"]])
    ], ItemsComponent);
    return ItemsComponent;
}());



/***/ }),

/***/ "./main.ts":
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* WEBPACK VAR INJECTION */(function(global) {/* harmony import */ var nativescript_angular_platform__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__("../node_modules/nativescript-angular/platform.js");
/* harmony import */ var nativescript_angular_platform__WEBPACK_IMPORTED_MODULE_0___default = /*#__PURE__*/__webpack_require__.n(nativescript_angular_platform__WEBPACK_IMPORTED_MODULE_0__);
/* harmony import */ var _app_app_module__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__("./app/app.module.ts");

            __webpack_require__("../node_modules/nativescript-dev-webpack/load-application-css-angular.js")();


        if (true) {
            const hmrUpdate = __webpack_require__("../node_modules/nativescript-dev-webpack/hmr/index.js").hmrUpdate;
            global.__initialHmrUpdate = true;
            global.__hmrSyncBackup = global.__onLiveSync;

            global.__onLiveSync = function () {
                hmrUpdate();
            };

            global.hmrRefresh = function({ type, path } = {}) {
                if (global.__initialHmrUpdate) {
                    return;
                }

                setTimeout(() => {
                    global.__hmrSyncBackup({ type, path });
                });
            };

            hmrUpdate().then(() => {
                global.__initialHmrUpdate = false;
            })
        }


        __webpack_require__("../node_modules/tns-core-modules/bundle-entry-points.js");


var options_Generated = {};

if (true) {
    options_Generated = {
        hmrOptions: {
            moduleTypeFactory: function () { return __webpack_require__("./app/app.module.ts").AppModule; },
            livesyncCallback: function (platformReboot) { setTimeout(platformReboot, 0); }
        }
    };
}

if (true) {
    module["hot"].accept(["./app/app.module.ts"], function(__WEBPACK_OUTDATED_DEPENDENCIES__) { /* harmony import */ _app_app_module__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__("./app/app.module.ts");
(function () {
        global["hmrRefresh"]({});
    })(__WEBPACK_OUTDATED_DEPENDENCIES__); });
}
// A traditional NativeScript application starts by initializing global objects,
// setting up global CSS rules, creating, and navigating to the main page.
// Angular applications need to take care of their own initialization:
// modules, components, directives, routes, DI providers.
// A NativeScript Angular app needs to make both paradigms work together,
// so we provide a wrapper platform object, platformNativeScriptDynamic,
// that sets up a NativeScript application and can bootstrap the Angular framework.
nativescript_angular_platform__WEBPACK_IMPORTED_MODULE_0__["platformNativeScriptDynamic"](Object.assign({}, options_Generated)).bootstrapModule(_app_app_module__WEBPACK_IMPORTED_MODULE_1__["AppModule"]);




/* WEBPACK VAR INJECTION */}.call(this, __webpack_require__("../node_modules/webpack/buildin/global.js")))

/***/ }),

/***/ "./package.json":
/***/ (function(module) {

module.exports = {"main":"main.js","android":{"v8Flags":"--expose_gc","markingMode":"none"}};

/***/ })

},[["./main.ts","runtime","vendor"]]]);
//# sourceMappingURL=data:application/json;charset=utf-8;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbIndlYnBhY2s6Ly8vLi4vJF9sYXp5X3JvdXRlX3Jlc291cmNlIGxhenkgbmFtZXNwYWNlIG9iamVjdCIsIndlYnBhY2s6Ly8vLi9hcHAuY3NzIiwid2VicGFjazovLy8uL2FwcC9hcHAtcm91dGluZy5tb2R1bGUudHMiLCJ3ZWJwYWNrOi8vLy4vYXBwL2FwcC5jb21wb25lbnQuaHRtbCIsIndlYnBhY2s6Ly8vLi9hcHAvYXBwLmNvbXBvbmVudC50cyIsIndlYnBhY2s6Ly8vLi9hcHAvYXBwLm1vZHVsZS50cyIsIndlYnBhY2s6Ly8vLi9hcHAvaXRlbS9pdGVtLWRldGFpbC5jb21wb25lbnQuaHRtbCIsIndlYnBhY2s6Ly8vLi9hcHAvaXRlbS9pdGVtLWRldGFpbC5jb21wb25lbnQudHMiLCJ3ZWJwYWNrOi8vLy4vYXBwL2l0ZW0vaXRlbS5zZXJ2aWNlLnRzIiwid2VicGFjazovLy8uL2FwcC9pdGVtL2l0ZW1zLmNvbXBvbmVudC5odG1sIiwid2VicGFjazovLy8uL2FwcC9pdGVtL2l0ZW1zLmNvbXBvbmVudC50cyIsIndlYnBhY2s6Ly8vLi9tYWluLnRzIl0sIm5hbWVzIjpbXSwibWFwcGluZ3MiOiI7Ozs7OztBQUFBO0FBQ0E7QUFDQTtBQUNBO0FBQ0E7QUFDQTtBQUNBO0FBQ0EsRUFBRTtBQUNGO0FBQ0EsNENBQTRDLFdBQVc7QUFDdkQ7QUFDQTtBQUNBLHlFOzs7Ozs7O0FDWkEseUVBQTJCLG1CQUFPLENBQUMsZ0RBQWdEO0FBQ25GO0FBQ0EsVUFBVSxtQkFBTyxDQUFDLG9HQUErRjs7QUFFakg7QUFDQSxjQUFjLFFBQVM7O0FBRXZCO0FBQ0EsUUFBUSxJQUFVO0FBQ2xCO0FBQ0E7QUFDQSwrQkFBK0IsbUNBQW1DO0FBQ2xFLFNBQVM7QUFDVDs7Ozs7Ozs7OztBQ2JBO0FBQUE7QUFBQTtBQUFBO0FBQUE7QUFBQTtBQUFBO0FBQXlDO0FBQzhCO0FBR2Y7QUFDVztBQUVuRSxJQUFNLE1BQU0sR0FBVztJQUNuQixFQUFFLElBQUksRUFBRSxFQUFFLEVBQUUs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RSxZQUFZLEVBQUUsRUFDakQsRUFBRSxFQUFFLEVBQUUsQ0FBQyxFQUFFLElBQUksRUFBRSxPQUFPLEVBQUUsSUFBSSxFQUFFLFVBQVUsRUFBRSxFQUMxQyxFQUFFLEVBQUUsRUFBRSxDQUFDLEVBQUUsSUFBSSxFQUFFLFlBQVksRUFBRSxJQUFJLEVBQUUsWUFBWSxFQUFFLEVBQ2pELEVBQUUsRUFBRSxFQUFFLENBQUMsRUFBRSxJQUFJLEVBQUUsUUFBUSxFQUFFLElBQUksRUFBRSxZQUFZLEVBQUUsRUFDN0MsRUFBRSxFQUFFLEVBQUUsQ0FBQyxFQUFFLElBQUksRUFBRSxjQUFjLEVBQUUsSUFBSSxFQUFFLFlBQVksRUFBRSxFQUNuRCxFQUFFLEVBQUUsRUFBRSxDQUFDLEVBQUUsSUFBSSxFQUFFLE1BQU0sRUFBRSxJQUFJLEVBQUUsWUFBWSxFQUFFLEVBQzNDLEVBQUUsRUFBRSxFQUFFLENBQUMsRUFBRSxJQUFJLEVBQUUsWUFBWSxFQUFFLElBQUksRUFBRSxZQUFZLEVBQUUsRUFDakQsRUFBRSxFQUFFLEVBQUUsQ0FBQyxFQUFFLElBQUksRUFBRSxRQUFRLEVBQUUsSUFBSSxFQUFFLFNBQVMsRUFBRSxFQUMxQyxFQUFFLEVBQUUsRUFBRSxFQUFFLEVBQUUsSUFBSSxFQUFFLE9BQU8sRUFBRSxJQUFJLEVBQUUsU0FBUyxFQUFFLEVBQzFDLEVBQUUsRUFBRSxFQUFFLEVBQUUsRUFBRSxJQUFJLEVBQUUsUUFBUSxFQUFFLElBQUksRUFBRSxTQUFTLEVBQUUsRUFDM0MsRUFBRSxFQUFFLEVBQUUsRUFBRSxFQUFFLElBQUksRUFBRSxTQUFTLEVBQUUsSUFBSSxFQUFFLFlBQVksRUFBRSxFQUMvQyxFQUFFLEVBQUUsRUFBRSxFQUFFLEVBQUUsSUFBSSxFQUFFLFdBQVcsRUFBRSxJQUFJLEVBQUUsWUFBWSxFQUFFLEVBQ2pELEVBQUUsRUFBRSxFQUFFLEVBQUUsRUFBRSxJQUFJLEVBQUUsWUFBWSxFQUFFLElBQUksRUFBRSxVQUFVLEVBQUUsRUFDaEQsRUFBRSxFQUFFLEVBQUUsRUFBRSxFQUFFLElBQUksRUFBRSxjQUFjLEVBQUUsSUFBSSxFQUFFLFNBQVMsRUFBRSxFQUNqRCxFQUFFLEVBQUUsRUFBRSxFQUFFLEVBQUUsSUFBSSxFQUFFLFlBQVksRUFBRSxJQUFJLEVBQUUsVUFBVSxFQUFFLEVBQ2hELEVBQUUsRUFBRSxFQUFFLEVBQUUsRUFBRSxJQUFJLEVBQUUsT0FBTyxFQUFFLElBQUksRUFBRSxVQUFVLEVBQUUsRUFDM0MsRUFBRSxFQUFFLEVBQUUsRUFBRSxFQUFFLElBQUksRUFBRSxlQUFlLEVBQUUsSUFBSSxFQUFFLFlBQVksRUFBRSxFQUNyRCxFQUFFLEVBQUUsRUFBRSxFQUFFLEVBQUUsSUFBSSxFQUFFLGFBQWEsRUFBRSxJQUFJLEVBQUUsWUFBWSxFQUFFLEVBQ25ELEVBQUUsRUFBRSxFQUFFLEVBQUUsRUFBRSxJQUFJLEVBQUUsYUFBYSxFQUFFLElBQUksRUFBRSxZQUFZLEVBQUUsRUFDbkQsRUFBRSxFQUFFLEVBQUUsRUFBRSxFQUFFLElBQUksRUFBRSxRQUFRLEVBQUUsSUFBSSxFQUFFLFVBQVUsRUFBRSxFQUM1QyxFQUFFLEVBQUUsRUFBRSxFQUFFLEVBQUUsSUFBSSxFQUFFLFNBQVMsRUFBRSxJQUFJLEVBQUUsVUFBVSxFQUFFLEVBQzdDLEVBQUUsRUFBRSxFQUFFLEVBQUUsRUFBRSxJQUFJLEVBQUUsT0FBTyxFQUFFLElBQUksRUFBRSxZQUFZLEVBQUUsQ0FDaEQsQ0FBQztJQVNOLENBQUM7SUFQRyw4QkFBUSxHQUFSO1FBQ0ksT0FBTyxJQUFJLENBQUMsS0FBSyxDQUFDO0lBQ3RCLENBQUM7SUFFRCw2QkFBTyxHQUFQLFVBQVEsRUFBVTtRQUNkLE9BQU8sSUFBSSxDQUFDLEtBQUssQ0FBQyxNQUFNLENBQUMsVUFBQyxJQUFJLElBQUssV0FBSSxDQUFDLEVBQUUsS0FBSyxFQUFFLEVBQWQsQ0FBYyxDQUFDLENBQUMsQ0FBQyxDQUFDLENBQUM7SUFDMUQsQ0FBQztJQWhDUSxXQUFXO1FBSHZCLGdFQUFVLENBQUM7WUFDUixVQUFVLEVBQUUsTUFBTTtTQUNyQixDQUFDO09BQ1csV0FBVyxDQWlDdkI7SUFBRCxrQkFBQztDQUFBO0FBakN1Qjs7Ozs7Ozs7QUNQeEIsNHJEOzs7Ozs7OztBQ0FBO0FBQUE7QUFBQTtBQUFBO0FBQWtEO0FBR0w7QUFNN0M7SUFHSSx3QkFBb0IsV0FBd0I7UUFBeEIsZ0JBQVcsR0FBWCxXQUFXLENBQWE7SUFBSSxDQUFDO0lBRWpELGlDQUFRLEdBQVI7UUFDSSxJQUFJLENBQUMsS0FBSyxHQUFHLElBQUksQ0FBQyxXQUFXLENBQUMsUUFBUSxFQUFFLENBQUM7SUFDN0MsQ0FBQzs7Z0JBSmdDLHlEQUFXOztJQUhuQyxjQUFjO1FBSjFCLCtEQUFTLENBQUM7WUFDUCxRQUFRLEVBQUUsVUFBVTtZQUNwQixnRUFBcUM7U0FDeEMsQ0FBQzt5Q0FJbUMseURBQVc7T0FIbkMsY0FBYyxDQVExQjtJQUFELHFCQUFDO0NBQUE7QUFSMEI7Ozs7Ozs7Ozs7Ozs7O0FDTjNCLE9BQU8sRUFBRSxzQkFBUyxDQUFFLDBFQUF5Qjs7Ozs7Ozs7Ozs7Ozs7Ozs7QUFFN0Msa0NBQWdGO0FBQ2hGLDJEQUEwRTtBQUMxRSxtQkFBc0U7QUFDdEUsY0FBeUQ7QUFDZ0I7QUFDekUsb0NBQXdFO0FBQ3hFLGtEQUFtRjtBQUNuRixjQUF5RCIsImZpbGUiOiJidW5kbGUuanMiLCJzb3VyY2VzQ29udGVudCI6WyJmdW5jdGlvbiB3ZWJwYWNrRW1wdHlBc3luY0NvbnRleHQocmVxKSB7XG5cdC8vIEhlcmUgUHJvbWlzZS5yZXNvbHZlKCkudGhlbigpIGlzIHVzZWQgaW5zdGVhZCBvZiBuZXcgUHJvbWlzZSgpIHRvIHByZXZlbnRcblx0Ly8gdW5jYXVnaHQgZXhjZXB0aW9uIHBvcHBpbmcgdXAgaW4gZGV2dG9vbHNcblx0cmV0dXJuIFByb21pc2UucmVzb2x2ZSgpLnRoZW4oZnVuY3Rpb24oKSB7XG5cdFx0dmFyIGUgPSBuZXcgRXJyb3IoXCJDYW5ub3QgZmluZCBtb2R1bGUgJ1wiICsgcmVxICsgXCInXCIpO1xuXHRcdGUuY29kZSA9ICdNT0RVTEVfTk9UX0ZPVU5EJztcblx0XHR0aHJvdyBlO1xuXHR9KTtcbn1cbndlYnBhY2tFbXB0eUFzeW5jQ29udGV4dC5rZXlzID0gZnVuY3Rpb24oKSB7IHJldHVybiBbXTsgfTtcbndlYnBhY2tFbXB0eUFzeW5jQ29udGV4dC5yZXNvbHZlID0gd2VicGFja0VtcHR5QXN5bmNDb250ZXh0O1xubW9kdWxlLmV4cG9ydHMgPSB3ZWJwYWNrRW1wdHlBc3luY0NvbnRleHQ7XG53ZWJwYWNrRW1wdHlBc3luY0NvbnRleHQuaWQgPSBcIi4uLyQkX2xhenlfcm91dGVfcmVzb3VyY2UgbGF6eSByZWN1cnNpdmVcIjsiLCJleHBvcnRzID0gbW9kdWxlLmV4cG9ydHMgPSByZXF1aXJlKFwiLi4vbm9kZV9tb2R1bGVzL2Nzcy1sb2FkZXIvZGlzdC9ydW50aW1lL2FwaS5qc1wiKShmYWxzZSk7XG4vLyBJbXBvcnRzXG5leHBvcnRzLmkocmVxdWlyZShcIi0hLi4vbm9kZV9tb2R1bGVzL2Nzcy1sb2FkZXIvZGlzdC9janMuanM/P3JlZi0tNi0xIW5hdGl2ZXNjcmlwdC10aGVtZS1jb3JlL2Nzcy9jb3JlLmxpZ2h0LmNzc1wiKSwgXCJcIik7XG5cbi8vIE1vZHVsZVxuZXhwb3J0cy5wdXNoKFttb2R1bGUuaWQsIFwiLypcXG5JbiBOYXRpdmVTY3JpcHQsIHRoZSBhcHAuY3NzIGZpbGUgaXMgd2hlcmUgeW91IHBsYWNlIENTUyBydWxlcyB0aGF0XFxueW91IHdvdWxkIGxpa2UgdG8gYXBwbHkgdG8geW91ciBlbnRpcmUgYXBwbGljYXRpb24uIENoZWNrIG91dFxcbmh0dHA6Ly9kb2NzLm5hdGl2ZXNjcmlwdC5vcmcvdWkvc3R5bGluZyBmb3IgYSBmdWxsIGxpc3Qgb2YgdGhlIENTU1xcbnNlbGVjdG9ycyBhbmQgcHJvcGVydGllcyB5b3UgY2FuIHVzZSB0byBzdHlsZSBVSSBjb21wb25lbnRzLlxcblxcbi8qXFxuSW4gbWFueSBjYXNlcyB5b3UgbWF5IHdhbnQgdG8gdXNlIHRoZSBOYXRpdmVTY3JpcHQgY29yZSB0aGVtZSBpbnN0ZWFkXFxub2Ygd3JpdGluZyB5b3VyIG93biBDU1MgcnVsZXMuIEZvciBhIGZ1bGwgbGlzdCBvZiBjbGFzcyBuYW1lcyBpbiB0aGUgdGhlbWVcXG5yZWZlciB0byBodHRwOi8vZG9jcy5uYXRpdmVzY3JpcHQub3JnL3VpL3RoZW1lLlxcbiovXFxuXCIsIFwiXCJdKTtcblxuO1xuICAgIGlmIChtb2R1bGUuaG90KSB7XG4gICAgICAgIG1vZHVsZS5ob3QuYWNjZXB0KCk7XG4gICAgICAgIG1vZHVsZS5ob3QuZGlzcG9zZSgoKSA9PiB7XG4gICAgICAgICAgICBnbG9iYWwuaG1yUmVmcmVzaCh7IHR5cGU6ICdzdHlsZScsIHBhdGg6ICcuL2FwcC5jc3MnIH0pO1xuICAgICAgICB9KVxuICAgIH1cbiIsImltcG9ydCB7IE5nTW9kdWxlIH0gZnJvbSBcIkBhbmd1bGFyL2NvcmVcIjtcbmltcG9ydCB7IE5hdGl2ZVNjcmlwdFJvdXRlck1vZHVsZSB9IGZyb20gXCJuYXRpdmVzY3JpcHQtYW5ndWxhci9yb3V0ZXJcIjtcbmltcG9ydCB7IFJvdXRlcyB9IGZyb20gXCJAYW5ndWxhci9yb3V0ZXJcIjtcblxuaW1wb3J0IHsgSXRlbXNDb21wb25lbnQgfSBmcm9tIFwiLi9pdGVtL2l0ZW1zLmNvbXBvbmVudFwiO1xuaW1wb3J0IHsgSXRlbURldGFpbENvbXBvbmVudCB9IGZyb20gXCIuL2l0ZW0vaXRlbS1kZXRhaWwuY29tcG9uZW50XCI7XG5cbmNvbnN0IHJvdXRlczogUm91dGVzID0gW1xuICAgIHsgcGF0aDogXCJcIiwgcmVkaXJlY3RUbzogXCIvaXRlbXNcIiwgcGF0aE1hdGNoOiBcImZ1bGxcIiB9LFxuICAgIHsgcGF0aDogXCJpdGVtc1wiLCBjb21wb25lbnQ6IEl0ZW1zQ29tcG9uZW50IH0sXG4gICAgeyBwYXRoOiBcIml0ZW0vOmlkXCIsIGNvbXBvbmVudDogSXRlbURldGFpbENvbXBvbmVudCB9XG5dO1xuXG5ATmdNb2R1bGUoe1xuICAgIGltcG9ydHM6IFtOYXRpdmVTY3JpcHRSb3V0ZXJNb2R1bGUuZm9yUm9vdChyb3V0ZXMpXSxcbiAgICBleHBvcnRzOiBbTmF0aXZlU2NyaXB0Um91dGVyTW9kdWxlXVxufSlcbmV4cG9ydCBjbGFzcyBBcHBSb3V0aW5nTW9kdWxlIHsgfVxuIiwibW9kdWxlLmV4cG9ydHMgPSBcIjwhLS0gaHR0cHM6Ly9kb2NzLm5hdGl2ZXNjcmlwdC5vcmcvYW5ndWxhci9jb3JlLWNvbmNlcHRzL2FuZ3VsYXItbmF2aWdhdGlvbi5odG1sI3BhZ2Utcm91dGVyLW91dGxldCAtLT5cXG48cGFnZS1yb3V0ZXItb3V0bGV0PjwvcGFnZS1yb3V0ZXItb3V0bGV0PlxcblwiIiwiaW1wb3J0IHsgQ29tcG9uZW50IH0gZnJvbSBcIkBhbmd1bGFyL2NvcmVcIjtcblxuQENvbXBvbmVudCh7XG4gICAgc2VsZWN0b3I6IFwibnMtYXBwXCIsXG4gICAgdGVtcGxhdGVVcmw6IFwiLi9hcHAuY29tcG9uZW50Lmh0bWxcIlxufSlcbmV4cG9ydCBjbGFzcyBBcHBDb21wb25lbnQgeyB9XG4iLCJpbXBvcnQgeyBOZ01vZHVsZSwgTk9fRVJST1JTX1NDSEVNQSB9IGZyb20gXCJAYW5ndWxhci9jb3JlXCI7XG5pbXBvcnQgeyBOYXRpdmVTY3JpcHRNb2R1bGUgfSBmcm9tIFwibmF0aXZlc2NyaXB0LWFuZ3VsYXIvbmF0aXZlc2NyaXB0Lm1vZHVsZVwiO1xuXG5pbXBvcnQgeyBBcHBSb3V0aW5nTW9kdWxlIH0gZnJvbSBcIi4vYXBwLXJvdXRpbmcubW9kdWxlXCI7XG5pbXBvcnQgeyBBcHBDb21wb25lbnQgfSBmcm9tIFwiLi9hcHAuY29tcG9uZW50XCI7XG5pbXBvcnQgeyBJdGVtc0NvbXBvbmVudCB9IGZyb20gXCIuL2l0ZW0vaXRlbXMuY29tcG9uZW50XCI7XG5pbXBvcnQgeyBJdGVtRGV0YWlsQ29tcG9uZW50IH0gZnJvbSBcIi4vaXRlbS9pdGVtLWRldGFpbC5jb21wb25lbnRcIjtcblxuLy8gVW5jb21tZW50IGFuZCBhZGQgdG8gTmdNb2R1bGUgaW1wb3J0cyBpZiB5b3UgbmVlZCB0byB1c2UgdHdvLXdheSBiaW5kaW5nXG4vLyBpbXBvcnQgeyBOYXRpdmVTY3JpcHRGb3Jtc01vZHVsZSB9IGZyb20gXCJuYXRpdmVzY3JpcHQtYW5ndWxhci9mb3Jtc1wiO1xuXG4vLyBVbmNvbW1lbnQgYW5kIGFkZCB0byBOZ01vZHVsZSBpbXBvcnRzIGlmIHlvdSBuZWVkIHRvIHVzZSB0aGUgSHR0cENsaWVudCB3cmFwcGVyXG4vLyBpbXBvcnQgeyBOYXRpdmVTY3JpcHRIdHRwQ2xpZW50TW9kdWxlIH0gZnJvbSBcIm5hdGl2ZXNjcmlwdC1hbmd1bGFyL2h0dHAtY2xpZW50XCI7XG5cbkBOZ01vZHVsZSh7XG4gICAgYm9vdHN0cmFwOiBbXG4gICAgICAgIEFwcENvbXBvbmVudFxuICAgIF0sXG4gICAgaW1wb3J0czogW1xuICAgICAgICBOYXRpdmVTY3JpcHRNb2R1bGUsXG4gICAgICAgIEFwcFJvdXRpbmdNb2R1bGVcbiAgICBdLFxuICAgIGRlY2xhcmF0aW9uczogW1xuICAgICAgICBBcHBDb21wb25lbnQsXG4gICAgICAgIEl0ZW1zQ29tcG9uZW50LFxuICAgICAgICBJdGVtRGV0YWlsQ29tcG9uZW50XG4gICAgXSxcbiAgICBwcm92aWRlcnM6IFtdLFxuICAgIHNjaGVtYXM6IFtcbiAgICAgICAgTk9fRVJST1JTX1NDSEVNQVxuICAgIF1cbn0pXG4vKlxuUGFzcyB5b3VyIGFwcGxpY2F0aW9uIG1vZHVsZSB0byB0aGUgYm9vdHN0cmFwTW9kdWxlIGZ1bmN0aW9uIGxvY2F0ZWQgaW4gbWFpbi50cyB0byBzdGFydCB5b3VyIGFwcFxuKi9cbmV4cG9ydCBjbGFzcyBBcHBNb2R1bGUgeyB9XG4iLCJtb2R1bGUuZXhwb3J0cyA9IFwiPEFjdGlvbkJhciB0aXRsZT1cXFwiRGV0YWlsc1xcXCIgY2xhc3M9XFxcImFjdGlvbi1iYXJcXFwiPjwvQWN0aW9uQmFyPlxcbjxGbGV4Ym94TGF5b3V0IGZsZXhEaXJlY3Rpb249XFxcImNvbHVtblxcXCIgY2xhc3M9XFxcInBhZ2VcXFwiPlxcbiAgICA8RmxleGJveExheW91dCBjbGFzcz1cXFwibS0xNVxcXCI+XFxuICAgICAgICA8TGFiZWwgY2xhc3M9XFxcImgyXFxcIiBbdGV4dF09XFxcIml0ZW0uaWQgKyAnLiAnXFxcIj48L0xhYmVsPlxcbiAgICAgICAgPExhYmVsIGNsYXNzPVxcXCJoMlxcXCIgW3RleHRdPVxcXCJpdGVtLm5hbWVcXFwiPjwvTGFiZWw+XFxuICAgIDwvRmxleGJveExheW91dD5cXG4gICAgPExhYmVsIGNsYXNzPVxcXCJoNFxcXCIgW3RleHRdPVxcXCJpdGVtLnJvbGVcXFwiPjwvTGFiZWw+XFxuPC9GbGV4Ym94TGF5b3V0PlxcblwiIiwiaW1wb3J0IHsgQ29tcG9uZW50LCBPbkluaXQgfSBmcm9tIFwiQGFuZ3VsYXIvY29yZVwiO1xuaW1wb3J0IHsgQWN0aXZhdGVkUm91dGUgfSBmcm9tIFwiQGFuZ3VsYXIvcm91dGVyXCI7XG5pbXBvcnQgeyBnZXRTdHJpbmcgfSBmcm9tIFwidG5zLWNvcmUtbW9kdWxlcy9odHRwXCI7XG5cbmltcG9ydCB7IEl0ZW0gfSBmcm9tIFwiLi9pdGVtXCI7XG5pbXBvcnQgeyBJdGVtU2VydmljZSB9IGZyb20gXCIuL2l0ZW0uc2VydmljZVwiO1xuXG5AQ29tcG9uZW50KHtcbiAgICBzZWxlY3RvcjogXCJucy1kZXRhaWxzXCIsXG4gICAgdGVtcGxhdGVVcmw6IFwiLi9pdGVtLWRldGFpbC5jb21wb25lbnQuaHRtbFwiXG59KVxuZXhwb3J0IGNsYXNzIEl0ZW1EZXRhaWxDb21wb25lbnQgaW1wbGVtZW50cyBPbkluaXQge1xuICAgIGl0ZW06IEl0ZW07XG5cbiAgICBjb25zdHJ1Y3RvcihcbiAgICAgICAgcHJpdmF0ZSBpdGVtU2VydmljZTogSXRlbVNlcnZpY2UsXG4gICAgICAgIHByaXZhdGUgcm91dGU6IEFjdGl2YXRlZFJvdXRlXG4gICAgKSB7IH1cblxuICAgIG5nT25Jbml0KCk6IHZvaWQge1xuICAgICAgICBjb25zdCBpZCA9ICt0aGlzLnJvdXRlLnNuYXBzaG90LnBhcmFtcy5pZDtcbiAgICAgICAgdGhpcy5pdGVtID0gdGhpcy5pdGVtU2VydmljZS5nZXRJdGVtKGlkKTtcblxuICAgICAgICBnZXRTdHJpbmcoXCJodHRwczovL2h0dHBiaW4ub3JnL2dldFwiKS50aGVuKChyOiBzdHJpbmcpID0+IHtcbiAgICAgICAgICAgIGNvbnNvbGUubG9nKHIpO1xuICAgICAgICB9LCAoZSkgPT4ge1xuICAgICAgICAgICAgY29uc29sZS5sb2coZSk7XG4gICAgICAgIH0pO1xuICAgIH1cbn1cbiIsImltcG9ydCB7IEluamVjdGFibGUgfSBmcm9tIFwiQGFuZ3VsYXIvY29yZVwiO1xuXG5pbXBvcnQgeyBJdGVtIH0gZnJvbSBcIi4vaXRlbVwiO1xuXG5ASW5qZWN0YWJsZSh7XG4gICAgcHJvdmlkZWRJbjogXCJyb290XCJcbn0pXG5leHBvcnQgY2xhc3MgSXRlbVNlcnZpY2Uge1xuICAgIHByaXZhdGUgaXRlbXMgPSBuZXcgQXJyYXk8SXRlbT4oXG4gICAgICAgIHsgaWQ6IDEsIG5hbWU6IFwiVGVyIFN0ZWdlblwiLCByb2xlOiBcIkdvYWxrZWVwZXJcIiB9LFxuICAgICAgICB7IGlkOiAzLCBuYW1lOiBcIlBpcXXDqVwiLCByb2xlOiBcIkRlZmVuZGVyXCIgfSxcbiAgICAgICAgeyBpZDogNCwgbmFtZTogXCJJLiBSYWtpdGljXCIsIHJvbGU6IFwiTWlkZmllbGRlclwiIH0sXG4gICAgICAgIHsgaWQ6IDUsIG5hbWU6IFwiU2VyZ2lvXCIsIHJvbGU6IFwiTWlkZmllbGRlclwiIH0sXG4gICAgICAgIHsgaWQ6IDYsIG5hbWU6IFwiRGVuaXMgU3XDoXJlelwiLCByb2xlOiBcIk1pZGZpZWxkZXJcIiB9LFxuICAgICAgICB7IGlkOiA3LCBuYW1lOiBcIkFyZGFcIiwgcm9sZTogXCJNaWRmaWVsZGVyXCIgfSxcbiAgICAgICAgeyBpZDogOCwgbmFtZTogXCJBLiBJbmllc3RhXCIsIHJvbGU6IFwiTWlkZmllbGRlclwiIH0sXG4gICAgICAgIHsgaWQ6IDksIG5hbWU6IFwiU3XDoXJlelwiLCByb2xlOiBcIkZvcndhcmRcIiB9LFxuICAgICAgICB7IGlkOiAxMCwgbmFtZTogXCJNZXNzaVwiLCByb2xlOiBcIkZvcndhcmRcIiB9LFxuICAgICAgICB7IGlkOiAxMSwgbmFtZTogXCJOZXltYXJcIiwgcm9sZTogXCJGb3J3YXJkXCIgfSxcbiAgICAgICAgeyBpZDogMTIsIG5hbWU6IFwiUmFmaW5oYVwiLCByb2xlOiBcIk1pZGZpZWxkZXJcIiB9LFxuICAgICAgICB7IGlkOiAxMywgbmFtZTogXCJDaWxsZXNzZW5cIiwgcm9sZTogXCJHb2Fsa2VlcGVyXCIgfSxcbiAgICAgICAgeyBpZDogMTQsIG5hbWU6IFwiTWFzY2hlcmFub1wiLCByb2xlOiBcIkRlZmVuZGVyXCIgfSxcbiAgICAgICAgeyBpZDogMTcsIG5hbWU6IFwiUGFjbyBBbGPDoWNlclwiLCByb2xlOiBcIkZvcndhcmRcIiB9LFxuICAgICAgICB7IGlkOiAxOCwgbmFtZTogXCJKb3JkaSBBbGJhXCIsIHJvbGU6IFwiRGVmZW5kZXJcIiB9LFxuICAgICAgICB7IGlkOiAxOSwgbmFtZTogXCJEaWduZVwiLCByb2xlOiBcIkRlZmVuZGVyXCIgfSxcbiAgICAgICAgeyBpZDogMjAsIG5hbWU6IFwiU2VyZ2kgUm9iZXJ0b1wiLCByb2xlOiBcIk1pZGZpZWxkZXJcIiB9LFxuICAgICAgICB7IGlkOiAyMSwgbmFtZTogXCJBbmRyw6kgR29tZXNcIiwgcm9sZTogXCJNaWRmaWVsZGVyXCIgfSxcbiAgICAgICAgeyBpZDogMjIsIG5hbWU6IFwiQWxlaXggVmlkYWxcIiwgcm9sZTogXCJNaWRmaWVsZGVyXCIgfSxcbiAgICAgICAgeyBpZDogMjMsIG5hbWU6IFwiVW10aXRpXCIsIHJvbGU6IFwiRGVmZW5kZXJcIiB9LFxuICAgICAgICB7IGlkOiAyNCwgbmFtZTogXCJNYXRoaWV1XCIsIHJvbGU6IFwiRGVmZW5kZXJcIiB9LFxuICAgICAgICB7IGlkOiAyNSwgbmFtZTogXCJNYXNpcFwiLCByb2xlOiBcIkdvYWxrZWVwZXJcIiB9XG4gICAgKTtcblxuICAgIGdldEl0ZW1zKCk6IEFycmF5PEl0ZW0+IHtcbiAgICAgICAgcmV0dXJuIHRoaXMuaXRlbXM7XG4gICAgfVxuXG4gICAgZ2V0SXRlbShpZDogbnVtYmVyKTogSXRlbSB7XG4gICAgICAgIHJldHVybiB0aGlzLml0ZW1zLmZpbHRlcigoaXRlbSkgPT4gaXRlbS5pZCA9PT0gaWQpWzBdO1xuICAgIH1cbn1cbiIsIm1vZHVsZS5leHBvcnRzID0gXCI8IS0tXFxuVGhlIHRlbXBsYXRlIGRlZmluZXMgdGhlIHZpZXcgb2YgdGhlIGNvbXBvbmVudCAtIHdoYXQgaXMgYWN0dWFsbHkgcmVuZGVyZWQuXFxuSW4gTmF0aXZlU2NyaXB0IGFwcGxpY2F0aW9ucyB0aGUgdGVtcGxhdGUgaXMgZGVmaW5lZCB3aXRoIFhNTCB1c2luZyBOYXRpdmVTY3JpcHQgVUkgZWxlbWVudHMuXFxuSXQgaXMgZGlmZmVyZW50IGZyb20gSFRNTC4gU28gaW5zdGVhZCBvZiA8aW5wdXQ+LCA8c3Bhbj4sIDxkaXY+IGV0Yy4gLSB3ZSBoYXZlIDxUZXh0RmllbGQ+LCA8TGFiZWw+IGFuZCBsYXlvdXRzLlxcblRoZSBpbXBvcnRhbnQgdGhpbmcgaXMgdGhhdCBhbHRob3VnaCB0aGUgZWxlbWVudHMgYXJlIGRpZmZlcmVudCAtIGFsbCBvZiB0aGUgQW5ndWxhcuKAmXMgdGVtcGxhdGUgc3ludGF4IHdvcmtzIGV4YWN0bHkgdGhlIHNhbWUuXFxuU28geW91IGNhbiBzdGlsbCB1c2UgdGVtcGxhdGUgZXhwcmVzc2lvbnMsIGJpbmRpbmdzLCB0ZW1wbGF0ZXMgYXMgd2VsbCBhcyBhbGwgdGhlIGJ1aWx0LWluIGRpcmVjdGl2ZXMuXFxuLS0+XFxuXFxuPCEtLVxcblRoZSBBY3Rpb25CYXIgaXMgdGhlIE5hdGl2ZVNjcmlwdCBjb21tb24gYWJzdHJhY3Rpb24gb3ZlciB0aGUgQW5kcm9pZCBBY3Rpb25CYXIgYW5kIGlPUyBOYXZpZ2F0aW9uQmFyLlxcbmh0dHA6Ly9kb2NzLm5hdGl2ZXNjcmlwdC5vcmcvdWkvYWN0aW9uLWJhclxcbi0tPlxcbjxBY3Rpb25CYXIgdGl0bGU9XFxcIk15IEFwcFxcXCIgY2xhc3M9XFxcImFjdGlvbi1iYXJcXFwiPlxcbjwvQWN0aW9uQmFyPlxcblxcbjwhLS1cXG5UaGUgR3JpZExheW91dCBhcnJhbmdlcyBpdHMgY2hpbGQgZWxlbWVudHMgaW4gYSB0YWJsZSBzdHJ1Y3R1cmUgb2Ygcm93cyBhbmQgY29sdW1ucy5cXG5BIGNlbGwgY2FuIGNvbnRhaW4gbXVsdGlwbGUgY2hpbGQgZWxlbWVudHMsIHRoZXkgY2FuIHNwYW4gb3ZlciBtdWx0aXBsZSByb3dzIGFuZCBjb2x1bW5zLCBcXG5hbmQgZXZlbiBvdmVybGFwIGVhY2ggb3RoZXIuIFRoZSBHcmlkTGF5b3V0IGhhcyBvbmUgY29sdW1uIGFuZCBvbmUgcm93IGJ5IGRlZmF1bHQuXFxuWW91IGNhbiBsZWFybiBtb3JlIGFib3V0IE5hdGl2ZVNjcmlwdCBsYXlvdXRzIGF0IGh0dHBzOi8vZG9jcy5uYXRpdmVzY3JpcHQub3JnL3VpL2xheW91dC1jb250YWluZXJzLlxcblxcblRoZXNlIGNvbXBvbmVudHMgbWFrZSB1c2Ugb2Ygc2V2ZXJhbCBDU1MgY2xhc3MgbmFtZXMgdGhhdCBhcmUgcGFydCBvZiB0aGUgTmF0aXZlU2NyaXB0XFxuY29yZSB0aGVtZSwgc3VjaCBhcyBwLTIwLCBidG4sIGgyLCBhbmQgbGlzdC1ncm91cC4gWW91IGNhbiB2aWV3IGEgZnVsbCBsaXN0IG9mIHRoZVxcbmNsYXNzIG5hbWVzIGF2YWlsYWJsZSBmb3Igc3R5bGluZyB5b3VyIGFwcCBhdCBodHRwczovL2RvY3MubmF0aXZlc2NyaXB0Lm9yZy91aS90aGVtZS5cXG4tLT5cXG48R3JpZExheW91dCBjbGFzcz1cXFwicGFnZVxcXCI+XFxuICAgIDxMaXN0VmlldyBbaXRlbXNdPVxcXCJpdGVtc1xcXCIgY2xhc3M9XFxcImxpc3QtZ3JvdXBcXFwiPlxcbiAgICAgICAgPG5nLXRlbXBsYXRlIGxldC1pdGVtPVxcXCJpdGVtXFxcIj5cXG4gICAgICAgICAgICA8TGFiZWwgW25zUm91dGVyTGlua109XFxcIlsnL2l0ZW0nLCBpdGVtLmlkXVxcXCIgW3RleHRdPVxcXCJpdGVtLm5hbWVcXFwiXFxuICAgICAgICAgICAgICAgIGNsYXNzPVxcXCJsaXN0LWdyb3VwLWl0ZW1cXFwiPjwvTGFiZWw+XFxuICAgICAgICA8L25nLXRlbXBsYXRlPlxcbiAgICA8L0xpc3RWaWV3PlxcbjwvR3JpZExheW91dD5cXG5cIiIsImltcG9ydCB7IENvbXBvbmVudCwgT25Jbml0IH0gZnJvbSBcIkBhbmd1bGFyL2NvcmVcIjtcblxuaW1wb3J0IHsgSXRlbSB9IGZyb20gXCIuL2l0ZW1cIjtcbmltcG9ydCB7IEl0ZW1TZXJ2aWNlIH0gZnJvbSBcIi4vaXRlbS5zZXJ2aWNlXCI7XG5cbkBDb21wb25lbnQoe1xuICAgIHNlbGVjdG9yOiBcIm5zLWl0ZW1zXCIsXG4gICAgdGVtcGxhdGVVcmw6IFwiLi9pdGVtcy5jb21wb25lbnQuaHRtbFwiXG59KVxuZXhwb3J0IGNsYXNzIEl0ZW1zQ29tcG9uZW50IGltcGxlbWVudHMgT25Jbml0IHtcbiAgICBpdGVtczogQXJyYXk8SXRlbT47XG5cbiAgICBjb25zdHJ1Y3Rvcihwcml2YXRlIGl0ZW1TZXJ2aWNlOiBJdGVtU2VydmljZSkgeyB9XG5cbiAgICBuZ09uSW5pdCgpOiB2b2lkIHtcbiAgICAgICAgdGhpcy5pdGVtcyA9IHRoaXMuaXRlbVNlcnZpY2UuZ2V0SXRlbXMoKTtcbiAgICB9XG59XG4iLCIvLyB0aGlzIGltcG9ydCBzaG91bGQgYmUgZmlyc3QgaW4gb3JkZXIgdG8gbG9hZCBzb21lIHJlcXVpcmVkIHNldHRpbmdzIChsaWtlIGdsb2JhbHMgYW5kIHJlZmxlY3QtbWV0YWRhdGEpXG5pbXBvcnQgeyBwbGF0Zm9ybU5hdGl2ZVNjcmlwdER5bmFtaWMgfSBmcm9tIFwibmF0aXZlc2NyaXB0LWFuZ3VsYXIvcGxhdGZvcm1cIjtcblxuaW1wb3J0IHsgQXBwTW9kdWxlIH0gZnJvbSBcIi4vYXBwL2FwcC5tb2R1bGVcIjtcblxuLy8gQSB0cmFkaXRpb25hbCBOYXRpdmVTY3JpcHQgYXBwbGljYXRpb24gc3RhcnRzIGJ5IGluaXRpYWxpemluZyBnbG9iYWwgb2JqZWN0cyxcbi8vIHNldHRpbmcgdXAgZ2xvYmFsIENTUyBydWxlcywgY3JlYXRpbmcsIGFuZCBuYXZpZ2F0aW5nIHRvIHRoZSBtYWluIHBhZ2UuXG4vLyBBbmd1bGFyIGFwcGxpY2F0aW9ucyBuZWVkIHRvIHRha2UgY2FyZSBvZiB0aGVpciBvd24gaW5pdGlhbGl6YXRpb246XG4vLyBtb2R1bGVzLCBjb21wb25lbnRzLCBkaXJlY3RpdmVzLCByb3V0ZXMsIERJIHByb3ZpZGVycy5cbi8vIEEgTmF0aXZlU2NyaXB0IEFuZ3VsYXIgYXBwIG5lZWRzIHRvIG1ha2UgYm90aCBwYXJhZGlnbXMgd29yayB0b2dldGhlcixcbi8vIHNvIHdlIHByb3ZpZGUgYSB3cmFwcGVyIHBsYXRmb3JtIG9iamVjdCwgcGxhdGZvcm1OYXRpdmVTY3JpcHREeW5hbWljLFxuLy8gdGhhdCBzZXRzIHVwIGEgTmF0aXZlU2NyaXB0IGFwcGxpY2F0aW9uIGFuZCBjYW4gYm9vdHN0cmFwIHRoZSBBbmd1bGFyIGZyYW1ld29yay5cbnBsYXRmb3JtTmF0aXZlU2NyaXB0RHluYW1pYygpLmJvb3RzdHJhcE1vZHVsZShBcHBNb2R1bGUpO1xuIl0sInNvdXJjZVJvb3QiOiIifQ==