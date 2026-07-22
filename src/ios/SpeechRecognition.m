//
//  Created by jcesarmobile on 30/11/14.
//  Updates and enhancements by Wayne Fisher (Fisherlea Systems) 2018-2019.
//

#import "SpeechRecognition.h"
#import <Speech/Speech.h>

#if 0
#define DBG(a)          NSLog(a)
#define DBG1(a, b)      NSLog(a, b)
#define DBG2(a, b, c)   NSLog(a, b, c)
#else
#define DBG(a)
#define DBG1(a, b)
#define DBG2(a, b, c)
#endif

@implementation SpeechRecognition

- (void) pluginInitialize {
    NSError *error;

    // We need to be notified of route changes to know when a
    // Bluetooth headset becomes active. The audioEngine needs to be
    // re-initialized in this case.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification object:nil];

    DBG(@"[sr] pluginInitialize()");

    NSString * output = [self.commandDelegate.settings objectForKey:[@"speechRecognitionAllowAudioOutput" lowercaseString]];
    if(output && [output caseInsensitiveCompare:@"true"] == NSOrderedSame) {
        // If the allow audio output preference is set, the need to change the session category.
        // This allows for speech recognition and speech synthesis to be used in the same app.
        self.sessionCategory = AVAudioSessionCategoryPlayAndRecord;
    } else {
        // Maintain the original functionality for backwards compatibility.
        self.sessionCategory = AVAudioSessionCategoryRecord;
    }

    // Serial queue for all audio-engine work. Keeps the heavy setup/teardown
    // off the Cordova bridge (main) thread — which triggers Cordova's
    // "Plugin should use a background thread" warning and can jank the UI —
    // while guaranteeing every audio-engine operation runs on one consistent
    // thread. NOTE: the silence NSTimer must still be scheduled on the main
    // run loop, so that scheduling stays on the main queue.
    self.audioQueue = dispatch_queue_create("com.fisherlea.cordova.speech.audio", DISPATCH_QUEUE_SERIAL);

    self.resetAudioEngine = NO;
    self.audioEngine = [[AVAudioEngine alloc] init];
    self.audioSession = [AVAudioSession sharedInstance];

    self.isSpeaking = NO;
    self.silenceTimer = nil;

    AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionAllowBluetooth | AVAudioSessionCategoryOptionAllowBluetoothA2DP;
    if ([self.sessionCategory isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        // When audio output is enabled (e.g. UI beeps playing during
        // recognition), route playback to the built-in speaker instead of the
        // quiet receiver so the sounds are actually audible.
        options |= AVAudioSessionCategoryOptionDefaultToSpeaker;
    }

    if(![self.audioSession setCategory:self.sessionCategory
                                  mode:AVAudioSessionModeMeasurement
                               options:options
                                 error:&error]) {
        NSLog(@"[sr] Unable to setCategory: %@", error);
    }
}

- (void)routeChanged:(NSNotification *)notification {
    BOOL resetAudioEngine = NO;

    NSNumber *reason = [notification.userInfo objectForKey:AVAudioSessionRouteChangeReasonKey];

    DBG(@"[sr] routeChanged()");

    AVAudioSessionRouteDescription *route;
    AVAudioSessionPortDescription *port;

    if ([reason unsignedIntegerValue] == AVAudioSessionRouteChangeReasonNewDeviceAvailable) {
        NSLog(@"[sr] AVAudioSessionRouteChangeReasonNewDeviceAvailable");
        resetAudioEngine = YES;

        route = self.audioSession.currentRoute;
        port = route.inputs[0];
        NSLog(@"[sr] New device is %@", port.portType);
    } else if ([reason unsignedIntegerValue] == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        NSLog(@"[sr] AVAudioSessionRouteChangeReasonOldDeviceUnavailable");
        resetAudioEngine = YES;

        route = [notification.userInfo objectForKey:AVAudioSessionRouteChangePreviousRouteKey];
        port = route.inputs[0];
        NSLog(@"[sr] Removed device %@", port.portType);

        route = self.audioSession.currentRoute;
        port = route.inputs[0];
        NSLog(@"[sr] Now using device %@", port.portType);
    } else if ([reason unsignedIntegerValue] == AVAudioSessionRouteChangeReasonCategoryChange) {
        NSLog(@"[sr] AVAudioSessionRouteChangeReasonCategoryChange");

        AVAudioSessionCategory category = [self.audioSession category];

        NSLog(@"[sr] AVAudioSession category: %@", category);

        if(![category isEqualToString:AVAudioSessionCategoryRecord] &&
           ![category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
            if([category isEqualToString:AVAudioSessionCategoryPlayback]) {
                category = AVAudioSessionCategoryPlayAndRecord;
            } else {
                category = self.sessionCategory;
            }

            [self.audioSession setCategory:category error:nil];
        }
    }

    if(resetAudioEngine) {
        // If a Bluetooth device has been added or removed, we need to
        // re-initialize the audioEngine to adapt to the different
        // sampling rate of the Bluetooth headset (8kHz) vs the mic (44.1kHz).

        NSLog(@"[sr] Need to reset audioEngine");
        self.resetAudioEngine = YES;

        // If we are currently running, we need to stop and release the
        // existing recognition tasks. Otherwise, nothing gets received.
        dispatch_async(self.audioQueue, ^{
            [self stopAndRelease];
        });
    }
}

- (void) init:(CDVInvokedUrlCommand*)command
{
    // This may be called multiple times by different instances of the Javascript SpeechRecognition object.
    NSLog(@"[sr] init()");

    self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:self.pluginResult callbackId:command.callbackId];
}

- (void) start:(CDVInvokedUrlCommand*)command
{
    DBG(@"[sr] start()");
    if (!NSClassFromString(@"SFSpeechRecognizer")) {
        [self sendErrorWithMessage:@"No speech recognizer service available." andCode:4];
        return;
    }

    self.command = command;
    [self sendEvent:(NSString *)@"start"];

    dispatch_async(self.audioQueue, ^{
        if(self.resetAudioEngine) {
            NSLog(@"[sr] Reseting audioEngine");
            self.audioEngine = [self.audioEngine init];
            self.resetAudioEngine = NO;
        }

        [self recognize];
    });
}

- (void) recognize
{
    DBG(@"[sr] recognize()");
    NSString * lang = [self.command argumentAtIndex:0];
    if (lang && [lang isEqualToString:@"en"]) {
        lang = @"en-US";
    }

    self.silenceThreshold = [[self.command argumentAtIndex:4] floatValue];
    self.audioLevelThreshold = [[self.command argumentAtIndex:5] floatValue];

    // Pre-flight the two required per-app permissions before touching the audio
    // engine, so a disabled toggle produces a clear, actionable error instead of
    // a silent hang. Speech Recognition first, then Microphone.
    SFSpeechRecognizerAuthorizationStatus speechStatus = [SFSpeechRecognizer authorizationStatus];

    if (speechStatus == SFSpeechRecognizerAuthorizationStatusNotDetermined) {
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status){
            dispatch_async(self.audioQueue, ^{
                if (status == SFSpeechRecognizerAuthorizationStatusAuthorized) {
                    [self ensureMicPermissionThenRecord:lang];
                } else {
                    [self sendErrorWithMessage:@"Speech Recognition access was denied. Enable it in Settings for this app." andCode:4];
                }
            });
        }];
    } else if (speechStatus == SFSpeechRecognizerAuthorizationStatusAuthorized) {
        [self ensureMicPermissionThenRecord:lang];
    } else {
        // Denied or Restricted.
        [self sendErrorWithMessage:@"Speech Recognition is disabled for this app. Enable it in Settings for this app." andCode:4];
    }
}

// Returns the microphone record-permission state as: 0 = undetermined, 1 = denied, 2 = granted.
- (int) micPermissionStatus
{
    if (@available(iOS 17.0, *)) {
        switch ([AVAudioApplication sharedInstance].recordPermission) {
            case AVAudioApplicationRecordPermissionGranted: return 2;
            case AVAudioApplicationRecordPermissionDenied:  return 1;
            default:                                        return 0;
        }
    } else {
        switch (self.audioSession.recordPermission) {
            case AVAudioSessionRecordPermissionGranted: return 2;
            case AVAudioSessionRecordPermissionDenied:  return 1;
            default:                                    return 0;
        }
    }
}

- (void) requestMicPermission:(void (^)(BOOL granted))handler
{
    if (@available(iOS 17.0, *)) {
        [AVAudioApplication requestRecordPermissionWithCompletionHandler:^(BOOL granted){ handler(granted); }];
    } else {
        [self.audioSession requestRecordPermission:^(BOOL granted){ handler(granted); }];
    }
}

// Verifies microphone access (requesting it if undetermined) before recording.
- (void) ensureMicPermissionThenRecord:(NSString *) lang
{
    int mic = [self micPermissionStatus];
    if (mic == 2) {
        [self recordAndRecognizeWithLang:lang];
    } else if (mic == 1) {
        [self sendErrorWithMessage:@"Microphone access is disabled for this app. Enable it in Settings for this app." andCode:4];
    } else {
        [self requestMicPermission:^(BOOL granted){
            dispatch_async(self.audioQueue, ^{
                if (granted) {
                    [self recordAndRecognizeWithLang:lang];
                } else {
                    [self sendErrorWithMessage:@"Microphone access was denied. Enable it in Settings for this app." andCode:4];
                }
            });
        }];
    }
}

- (void) recordAndRecognizeWithLang:(NSString *) lang
{
    DBG1(@"[sr] recordAndRecognizeWithLang(%@)", lang);
    NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:lang];
    self.sfSpeechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:locale];
    if (!self.sfSpeechRecognizer) {
        [self sendErrorWithMessage:@"The language is not supported" andCode:7];
    } else {

        // Fully tear down any in-progress session before starting a new one.
        // installTapOnBus: asserts (and crashes) if a tap is already installed
        // on the bus, so a second start() must stop the engine and remove the
        // existing tap first, not just cancel the recognition task.
        // Clearing sessionActive first makes any late callback from the old
        // task a no-op while the new session is being set up.
        self.sessionActive = NO;
        if ( self.recognitionTask ) {
            [self.recognitionTask cancel];
            self.recognitionTask = nil;
        }
        if ( self.audioEngine.isRunning ) {
            [self.audioEngine stop];
        }
        [self.audioEngine.inputNode removeTapOnBus:0];
        if ( self.recognitionRequest ) {
            [self.recognitionRequest endAudio];
            self.recognitionRequest = nil;
        }
        [self.silenceTimer invalidate];
        self.silenceTimer = nil;
        self.isSpeaking = NO;

        [self initAudioSession];

        self.recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        self.recognitionRequest.shouldReportPartialResults = [[self.command argumentAtIndex:1] boolValue];

        if (@available(iOS 13.0, *)) {
            if (self.sfSpeechRecognizer.supportsOnDeviceRecognition) {
                self.recognitionRequest.requiresOnDeviceRecognition = YES;
            }
        }

        self.speechStartSent = FALSE;

        // Tag this session. Because this plugin is a singleton, a torn-down
        // session's task can still fire its result handler late; those stale
        // callbacks must not leak into whatever session is current now (e.g.
        // an empty final from the old session poisoning the new one). Capture
        // the id and bail out of the handler if the session has been superseded.
        self.sessionId += 1;
        NSInteger mySession = self.sessionId;
        self.lastAlternatives = nil; // per-session cache of the last non-empty transcription

        self.recognitionTask = [self.sfSpeechRecognizer recognitionTaskWithRequest:self.recognitionRequest resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {

            if (mySession != self.sessionId) {
                NSLog(@"[sr] Ignoring callback from superseded session %ld (current %ld)", (long)mySession, (long)self.sessionId);
                return;
            }

            if (error) {
                NSLog(@"[sr] resultHandler error (%d) %@", (int) error.code, error.description);
                if (self.sessionActive) {
                    // Genuine error during an active session: report it, then end.
                    [self sendRecognizerError:error];
                    [self stopAndRelease];
                } else {
                    // Session already ended cleanly (e.g. silence auto-stop);
                    // ignore a late-arriving error so we don't contradict a
                    // successful result with a spurious failure.
                    NSLog(@"[sr] Ignoring late error; session already ended");
                }
                return;
            }

            if(!self.speechStartSent) {
                [self sendEvent:(NSString *)@"speechstart"];
                self.speechStartSent = TRUE;
            }

            if (result) {
                NSMutableArray * alternatives = [[NSMutableArray alloc] init];
                int maxAlternatives = [[self.command argumentAtIndex:2] intValue];
                for ( SFTranscription *transcription in result.transcriptions ) {
                    if (alternatives.count < maxAlternatives) {
                        float confMed = 0, confidence;
                        for ( SFTranscriptionSegment *transcriptionSegment in transcription.segments ) {
                            //NSLog(@"[sr] transcriptionSegment.confidence %f", transcriptionSegment.confidence);
                            confMed +=transcriptionSegment.confidence;
                        }
                        NSMutableDictionary * resultDict = [[NSMutableDictionary alloc]init];
                        [resultDict setValue:transcription.formattedString forKey:@"transcript"];
                        [resultDict setValue:[NSNumber numberWithBool:result.isFinal] forKey:@"final"];
                        if(transcription.segments.count == 0) {
                            DBG(@"*** No transcriptions for result!");
                            confidence = 0;
                        } else {
                            confidence = confMed/transcription.segments.count;
                        }
                        [resultDict setValue:[NSNumber numberWithFloat:confidence] forKey:@"confidence"];
                        [alternatives addObject:resultDict];
                    }
                }
                // On-device recognition can flood kAFAssistantErrorDomain 1101
                // and then hand back an EMPTY final result, which would drop the
                // spoken text entirely. We reliably get the text as interims, so
                // cache the last non-empty result and, if the final comes back
                // empty, substitute the cached text so the phrase isn't lost.
                NSString *primaryText = result.bestTranscription.formattedString ?: @"";
                BOOL hasText = primaryText.length > 0;

                if (hasText) {
                    self.lastAlternatives = alternatives;
                    [self sendResults:@[alternatives]];
                } else if (result.isFinal && self.lastAlternatives.count > 0) {
                    for (NSMutableDictionary *alt in self.lastAlternatives) {
                        [alt setValue:[NSNumber numberWithBool:YES] forKey:@"final"];
                    }
                    NSLog(@"[sr] Empty final result; substituting last transcription");
                    [self sendResults:@[self.lastAlternatives]];
                } else {
                    [self sendResults:@[alternatives]];
                }

                if ( result.isFinal ) {
                    if(self.speechStartSent) {
                        [self sendEvent:(NSString *)@"speechend"];
                        self.speechStartSent = FALSE;
                    }

                    [self stopAndRelease];
                }
            }
        }];

        AVAudioFormat *recordingFormat = [self.audioEngine.inputNode outputFormatForBus:0];
        DBG1(@"[sr] recordingFormat: sampleRate:%lf", recordingFormat.sampleRate);

      // Install tap with silence detection
      [self.audioEngine.inputNode installTapOnBus:0
                                       bufferSize:1024
                                           format:recordingFormat
                                            block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
        [self.recognitionRequest appendAudioPCMBuffer:buffer];

        // Calculate audio level
        float audioLevel = [self calculateAudioLevel:buffer];
        DBG1(@"[sr] audioLevel: %f", audioLevel);

        if (audioLevel > self.audioLevelThreshold) {
          DBG(@"[sr] Speaking");
          if (!self.isSpeaking) {
            self.isSpeaking = YES;
          }
          if(self.silenceTimer != nil){
            DBG(@"[sr] Invalidate silenceTimer");
            [self.silenceTimer invalidate];
            self.silenceTimer = nil;
          }
        } else {
          DBG(@"[sr] Silence");
          if (self.isSpeaking) {
            dispatch_async(dispatch_get_main_queue(), ^{
              if(self.silenceTimer == nil){
                DBG(@"[sr] Set silenceTimer");
                self.silenceTimer = [NSTimer scheduledTimerWithTimeInterval:self.silenceThreshold
                                                                     target:self
                                                                   selector:@selector(handleSilence)
                                                                   userInfo:nil
                                                                    repeats:NO];
              }
            });
          }
        }
      }];

        [self.audioEngine prepare];

        NSError *engineError = nil;
        if (![self.audioEngine startAndReturnError:&engineError]) {
            // Don't leave a dangling tap/request/task behind on failure.
            NSLog(@"[sr] Unable to start audioEngine: %@", engineError);
            [self.audioEngine.inputNode removeTapOnBus:0];
            if (self.recognitionTask) {
                [self.recognitionTask cancel];
                self.recognitionTask = nil;
            }
            self.recognitionRequest = nil;
            [self sendErrorWithMessage:@"Unable to start audio capture." andCode:2];
            return;
        }

        self.sessionActive = YES;
        [self sendEvent:(NSString *)@"audiostart"];
    }
}

- (float)calculateAudioLevel:(AVAudioPCMBuffer *)buffer {
    float sum = 0.0;
    float *samples = buffer.floatChannelData[0];
    NSUInteger count = buffer.frameLength;

    // Calculate RMS (Root Mean Square) of the audio buffer
    for (NSUInteger i = 0; i < count; i++) {
        sum += samples[i] * samples[i];
    }

    return sqrtf(sum / count);
}

- (void)handleSilence {
    NSLog(@"[sr] handleSilence()");
    if (self.isSpeaking) {
        self.isSpeaking = NO;
        // Finalize the utterance instead of cancelling it. stopOrAbort calls
        // endAudio, which makes the recognizer deliver its FINAL result (the
        // recognized text) through the result handler — that final then
        // commits and ends the session normally. Previously this called
        // stopAndRelease, which cancels the task (kLSRErrorDomain 301) and
        // discards the recognized text, so no final result was ever emitted.
        [self stopOrAbort];
    }
}

- (void) initAudioSession
{
    NSError *error;

    if(![self.audioSession setActive:YES
                         withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error]) {
        NSLog(@"[sr] Unable to setActive:YES: %@", error);
    }
}

-(void) sendResults:(NSArray *) results
{
    NSMutableDictionary * event = [[NSMutableDictionary alloc]init];
    DBG(@"[sr] sendResults()");
    [event setValue:@"result" forKey:@"type"];
    [event setValue:nil forKey:@"emma"];
    [event setValue:nil forKey:@"interpretation"];
    [event setValue:[NSNumber numberWithInt:0] forKey:@"resultIndex"];
    [event setValue:results forKey:@"results"];

    self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:event];
    [self.pluginResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:self.pluginResult callbackId:self.command.callbackId];
    DBG(@"[sr] sendResults() complete");
}

// Maps an SFSpeechRecognizer/kAFAssistantErrorDomain NSError to a W3C
// SpeechRecognition error code and a human-readable, actionable message.
// Error codes (see www/SpeechRecognitionError.js):
//   0 no-speech, 1 aborted, 2 audio-capture, 3 network,
//   4 not-allowed, 5 service-not-allowed, 6 bad-grammar, 7 language-not-supported
-(void) sendRecognizerError:(NSError *)error
{
    NSInteger code = 3;                            // network: generic fallback (previous behavior)
    NSString *message = error.localizedDescription;

    NSString *dictationDisabledMessage = @"Speech recognition is unavailable because Dictation is disabled. Enable it in Settings > General > Keyboard > Enable Dictation.";

    if ([error.domain isEqualToString:@"kLSRErrorDomain"]) {
        switch (error.code) {
            case 201:
                // "Siri and Dictation are disabled" — the local speech
                // recognition service is turned off at the OS level.
                code = 5;                          // service-not-allowed
                message = dictationDisabledMessage;
                break;
            default:
                break;
        }
    } else if ([error.domain isEqualToString:@"kAFAssistantErrorDomain"]) {
        switch (error.code) {
            case 1101:
                // Assistant-side variant of "Siri and Dictation are disabled".
                code = 5;                          // service-not-allowed
                message = dictationDisabledMessage;
                break;
            case 1110:
                // No speech was detected by the recognizer.
                code = 0;                          // no-speech
                break;
            case 203:
            case 216:
            case 1700:
                // Request was cancelled/aborted.
                code = 1;                          // aborted
                break;
            default:
                break;
        }
    }

    [self sendErrorWithMessage:message andCode:code];
}

-(void) sendErrorWithMessage:(NSString *)errorMessage andCode:(NSInteger) code
{
    NSMutableDictionary * event = [[NSMutableDictionary alloc]init];
    DBG2(@"[sr] sendErrorWithMessage: (%d) %@", (int) code, errorMessage);
    [event setValue:@"error" forKey:@"type"];
    [event setValue:[NSNumber numberWithInteger:code] forKey:@"error"];
    [event setValue:errorMessage forKey:@"message"];
    self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:event];
    [self.pluginResult setKeepCallbackAsBool:NO];
    [self.commandDelegate sendPluginResult:self.pluginResult callbackId:self.command.callbackId];
    DBG(@"[sr] sendErrorWithMessage() complete");
}

-(void) sendEvent:(NSString *) eventType
{
    NSMutableDictionary * event = [[NSMutableDictionary alloc]init];
    DBG1(@"[sr] sendEvent: %@", eventType);
    [event setValue:eventType forKey:@"type"];
    self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:event];
    [self.pluginResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:self.pluginResult callbackId:self.command.callbackId];
    DBG(@"[sr] sendEvent() complete");
}

-(void) stop:(CDVInvokedUrlCommand*)command
{
    DBG(@"[sr] stop()");
    [self stopOrAbort];
}

-(void) abort:(CDVInvokedUrlCommand*)command
{
    DBG(@"[sr] abort()");
    [self stopOrAbort];
}

// Shared opener: tries `primary`; if it can't be opened and `fallback` is
// non-nil, tries `fallback`. Reports OK/ERROR back to the given command.
-(void) openSettingsURL:(NSURL *)primary fallback:(NSURL *)fallback forCommand:(CDVInvokedUrlCommand*)command
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];

        void (^finish)(BOOL) = ^(BOOL success) {
            CDVPluginResult *result = success
                ? [CDVPluginResult resultWithStatus:CDVCommandStatus_OK]
                : [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Unable to open Settings."];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        };

        [app openURL:primary options:@{} completionHandler:^(BOOL opened) {
            if (opened || fallback == nil) {
                finish(opened);
            } else {
                NSLog(@"[sr] Primary settings URL failed; falling back");
                [app openURL:fallback options:@{} completionHandler:^(BOOL openedFallback) {
                    finish(openedFallback);
                }];
            }
        }];
    });
}

// Opens iOS Settings, deep-linking toward the General/Keyboard area (where the
// global "Enable Dictation" toggle lives) when the OS honors it, otherwise the
// root Settings page. The deep link uses a private URL scheme and is only
// appropriate for in-house (non-App-Store) distribution. Use this for the
// "Siri and Dictation are disabled" (service-not-allowed) case.
-(void) openSettings:(CDVInvokedUrlCommand*)command
{
    NSLog(@"[sr] openSettings()");
    [self openSettingsURL:[NSURL URLWithString:@"App-Prefs:root=General"]
                 fallback:[NSURL URLWithString:@"App-Prefs:"]
               forCommand:command];
}

// Opens this app's own page in Settings using the documented API. This is where
// the per-app Microphone and Speech Recognition permission toggles live. Use
// this for the not-allowed (permission denied) case.
-(void) openAppSettings:(CDVInvokedUrlCommand*)command
{
    NSLog(@"[sr] openAppSettings()");
    [self openSettingsURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]
                 fallback:nil
               forCommand:command];
}

-(void) stopOrAbort
{
    DBG(@"[sr] stopOrAbort()");
    dispatch_async(self.audioQueue, ^{
        if (self.audioEngine.isRunning) {
            [self.audioEngine stop];
            [self sendEvent:(NSString *)@"audioend"];

            if(self.recognitionRequest) {
                [self.recognitionRequest endAudio];
            }
        }
    });
}

-(void) stopAndRelease
{
    DBG(@"[sr] stopAndRelease()");

    // Idempotent: a session ends exactly once. Guards against duplicate
    // audioend/end events when both the silence timer and a late recognizer
    // callback try to tear the same session down.
    if (!self.sessionActive) {
        return;
    }
    self.sessionActive = NO;

    [self.silenceTimer invalidate];
    self.silenceTimer = nil;
    self.isSpeaking = NO;

    if (self.audioEngine.isRunning) {
        [self.audioEngine stop];
        [self sendEvent:(NSString *)@"audioend"];
    }
    [self.audioEngine.inputNode removeTapOnBus:0];

    if(self.recognitionRequest) {
        [self.recognitionRequest endAudio];
        self.recognitionRequest = nil;
    }

    if(self.recognitionTask) {
        if(self.recognitionTask.state != SFSpeechRecognitionTaskStateCompleted) {
            [self.recognitionTask cancel];
        }
        self.recognitionTask = nil;
    }

    /* TODO: Disabled for now.
     * Maybe should be performed by HeadsetControl.disconnect???
     * Or maybe allow use of a plugin parameter/option to disable this???
    if(self.audioSession) {
        NSError *error;

        NSLog(@"setActive:NO");
        if(![self.audioSession setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error]) {
            NSLog(@"[sr] Unable to setActive:NO: %@", error);
        }
    }
    */

    [self sendEvent:(NSString *)@"end"];
}

@end
