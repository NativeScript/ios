    const { ObjectCreate, ObjectPrototypeHasOwnProperty } = primordials;
    function __extends(d, b) {
         for (var p in b) {
             if (ObjectPrototypeHasOwnProperty(b, p)) {
                 d[p] = b[p];
             }
         }
         function __() { this.constructor = d; }
         d.prototype = b === null ? ObjectCreate(b) :
(__.prototype = b.prototype, new __());
    }
    module.exports = __extends;
