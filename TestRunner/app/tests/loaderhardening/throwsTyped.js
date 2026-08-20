// Thrown during evaluation, so it travels out through require()'s failure path.
const err = new TypeError("typed-module-failure");
err.marker = "original-identity";
throw err;
