// Closes from inside the entry script, so onclose runs before the entry has
// finished evaluating.
onclose = function () {
    throw new Error("boom from onclose");
};
close();
