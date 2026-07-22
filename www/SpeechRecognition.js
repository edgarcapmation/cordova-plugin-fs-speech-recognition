var exec = require("cordova/exec");

/**
    attribute SpeechGrammarList grammars;
    attribute DOMString lang;
    attribute boolean continuous;
    attribute boolean interimResults;
    attribute unsigned long maxAlternatives;
    attribute DOMString serviceURI;
 */
var SpeechRecognition = function () {
    this.grammars = null;
    this.lang = "en";
    this.continuous = false;
    this.interimResults = false;
    this.maxAlternatives = 1;
    this.serviceURI = "";
    this.silenceThreshold = 4; // seconds of silence before stopping
    this.audioLevelThreshold = 0.005; // minimum audio level below which the silence threshold is met

    // event methods
    this.onaudiostart = null;
    this.onsoundstart = null;
    this.onspeechstart = null;
    this.onspeechend = null;
    this.onsoundend = null;
    this.onaudioend = null;
    this.onresult = null;
    this.onnomatch = null;
    this.onerror = null;
    this.onstart = null;
    this.onend = null;

    exec(function() {
        console.log("initialized");
    }, function(e) {
        console.log("error: " + e);
    }, "SpeechRecognition", "init", []);
};

function _formatResultEvent(ev) {
    var event = new SpeechRecognitionEvent();

    event.type = ev.type;
    event.resultIndex = ev.resultIndex;
    event.emma = ev.emma;
    event.interpretation = ev.interpretation;

    for (var i = 0; i < ev.results.length; i++) {
        var result = new SpeechRecognitionResult();
        var alt = ev.results[i];

        for (var j = 0; j < alt.length; j++) {
            var alternative = new SpeechRecognitionAlternative();

            alternative.transcript = alt[j].transcript;
            alternative.confidence = alt[j].confidence;
            if (alt[j].final) {
                result.isFinal = true;
            }

            result.push(alternative);
        }

        event.results.push(result);
    }

    return event;
}

SpeechRecognition.prototype.start = function () {
    var that = this;
    var successCallback = function(event) {
        if (event.type === "audiostart" && typeof that.onaudiostart === "function") {
            that.onaudiostart(event);
        } else if (event.type === "soundstart" && typeof that.onsoundstart === "function") {
            that.onsoundstart(event);
        } else if (event.type === "speechstart" && typeof that.onspeechstart === "function") {
            that.onspeechstart(event);
        } else if (event.type === "speechend" && typeof that.onspeechend === "function") {
            that.onspeechend(event);
        } else if (event.type === "soundend" && typeof that.onsoundend === "function") {
            that.onsoundend(event);
        } else if (event.type === "audioend" && typeof that.onaudioend === "function") {
            that.onaudioend(event);
        } else if (event.type === "result" && typeof that.onresult === "function") {
            that.onresult(_formatResultEvent(event));
        } else if (event.type === "nomatch" && typeof that.onnomatch === "function") {
            that.onnomatch(_formatResultEvent(event));
        } else if (event.type === "start" && typeof that.onstart === "function") {
            that.onstart(event);
        } else if (event.type === "end" && typeof that.onend === "function") {
            that.onend(event);
        }
    };
    var errorCallback = function(err) {
        if (typeof that.onerror === "function") {
            var error = new SpeechRecognitionError();

            error.error = SpeechRecognitionError._errorCodes[err.error];
            error.message = err.message;

            that.onerror(error);
        }
    };

    exec(successCallback, errorCallback, "SpeechRecognition", "start", [this.lang, this.interimResults, this.maxAlternatives, this.serviceURI, this.silenceThreshold, this.audioLevelThreshold]);
};

SpeechRecognition.prototype.stop = function() {
    exec(null, null, "SpeechRecognition", "stop", []);
};

SpeechRecognition.prototype.abort = function() {
    exec(null, null, "SpeechRecognition", "abort", []);
};

// Opens iOS Settings, deep-linking toward the General/Keyboard area (where the
// global "Enable Dictation" toggle lives) when the OS allows it, otherwise the
// root Settings page. Use for the "service-not-allowed" (Dictation disabled)
// case. success/error callbacks are optional. iOS only; a no-op elsewhere.
SpeechRecognition.prototype.openSettings = function(success, error) {
    exec(success, error, "SpeechRecognition", "openSettings", []);
};

// Opens this app's own page in iOS Settings (documented API), where the
// per-app Microphone and Speech Recognition toggles live. Use for the
// "not-allowed" (permission denied) case. success/error callbacks are
// optional. iOS only; a no-op elsewhere.
SpeechRecognition.prototype.openAppSettings = function(success, error) {
    exec(success, error, "SpeechRecognition", "openAppSettings", []);
};

module.exports = SpeechRecognition;
