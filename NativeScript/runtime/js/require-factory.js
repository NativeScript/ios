(function() { 
    function require_factory(requireInternal, dirName) { 
        return function require(modulePath) { 
            if(global.__pauseOnNextRequire) {  debugger; 
global.__pauseOnNextRequire = false; }
            return requireInternal(modulePath, dirName); 
        } 
    } 
    return require_factory; 
})()
