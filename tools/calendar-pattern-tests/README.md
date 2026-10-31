# Event-type pattern experiment

User proposal: repeat a dumbbell, phone or camera across an event so its type is
recognizable when overlapping events leave too little room for readable text.
Calendar color still identifies its calendar. This is an isolated experiment,
not a shipping renderer change or a performance acceptance claim.

Apple already provides the required primitive:
[Core Graphics tiled-image drawing](https://developer.apple.com/documentation/coregraphics/cgcontext/draw(_:in:bytiling:)).
Use existing SF Symbols and a fixed cached tile, not a view per repeated icon or
a new rendering library. The renderer comparison calls the actual
`CalendarNativeEventRaster.draw` for the existing bars.

```sh
mkdir -p .build/calendar-pattern-tests
swiftc -O Banana/Views/CalendarNativeText.swift Banana/Views/CalendarNativeEventRaster.swift tools/calendar-pattern-tests/main.swift -o .build/calendar-pattern-tests/probe
.build/calendar-pattern-tests/probe .build/calendar-pattern-tests/run-1
```

The output directory must be new. Light/dark previews show three columns:
current text, pattern only, pattern with text. Each row uses workout, phone, or
video imagery; widths are 16, 24, 40, 80 and 180 points. An additional plain
no-text timing control isolates the cost of the pattern from removing text.
Every case retains 24 samples per mode in rotating order. Initial tile creation,
tile memory, output image memory, and exact pixels after tile eviction/recreation
are recorded. These are Mac component timings, not physical UI/frame measurements.

Before adoption: inspect narrow-width clipping and symbol recognition, test real
multi-calendar dense pages on all device families, preserve invitation/completion
and privacy states, and add event-type metadata to the prepared-artwork cache key.
Do not infer a call type solely from an ambiguous title or leak a redacted event's
type through its pattern. Preserve existing accessible event names, activation,
and details; texture is supplemental. Very narrow bars may not fit even one icon.
The title-and-pattern option reserves a quiet title area; it is not a solution for
12 columns of unreadable text.
