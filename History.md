0.3.3 / 2013-6-5
================
* Implementing the reset method to help with debugging

0.3.2 / 2013-6-2
================
* Cleaning up NSLogs everywhere

0.3.1 / 2013-6-1
================
* Removing OS X Platform from podfile

0.3.0 / 2013-6-1
================
* Re-architecting the library to bundle providers
* Adding support for Amplitude
* Adding support for Bugsnag
* Adding support for Chartbeat
* Adding support for Countly
* Adding support for Crittercism
* Adding support for Flurry
* Library now downloads the provider settings from the Segment.io server

0.2.2 / 2013-4-24
=================
* Fixing timestamps to include millisecond precision


0.2.1 / 2013-4-16
=================
* Fixing initWithSecret method signature in header file

0.2.0 / 2013-4-16
=================
* Simplifying sessionId to behave the same on iOS 6 as on iOS 5 and OS X
* Fixing reset function to actually destroy userId and roll sessionId

0.1.1 / 2013-4-11
=================
* Added a getSessionId method

0.1.0 / 2013-4-11
=================
* Added a testing suite
* Added context variable, which includes device info and metadata for Segment.io
* Added alias method


0.0.5 / 2013-4-1
================
* Merged fix from @pkamb to fix types in logging statements.

0.0.4 / 2013-3-23
==================
* Removed UDID usage after Apple's announcement that it will no longer be accepted in the app store https://developer.apple.com/news/?id=3212013a
* Renamed repo to analytics-ios-osx

0.0.3 / 2013-3-13
==================
* Made timestamp more accurate
* Added max batch size

0.0.2 / 2013-3-12
==================
* Merged in numerous improvements from [tonyxiao](https://github.com/tonyxiao)
    * support for OSX apps
    * a shared dispatch queue and async flushing
    * removed JSON library dependency to use native JSON support
* Added enqueueAction to DRY things up
* Added an optional initialization method that reveals flushAt and flushAfter
* Added Cocoapods podspec

0.0.1 / 2013-3-9
==================
* Added working library for iOS
* Added README