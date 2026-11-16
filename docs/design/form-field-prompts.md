# Form labels and placeholders

A field's label names the value. Its prompt is an example or instruction shown only while the
field is empty. On macOS a Form displays the label beside the input; using an example as the
label left “Lunch with Sam Fri 1pm” permanently beside a different event title.

Use the native `TextField` initializer with a semantic label and explicit `prompt:`. For a
full-width entry under an existing section heading, apply `labelsHidden()` to that field, not
the Form or section. Let the semantic field label supply its accessible name. Do not repeat it in an accessibility
override: macOS grouped forms can combine the two and announce the name twice. Persistent labels such as Name,
Dose, Starts and Calendar remain visible. This preserves familiar form structure and removes
an example competing with the user's actual value.

Sources: Apple's [TextField documentation](https://developer.apple.com/documentation/swiftui/textfield)
describes platform-specific label/prompt placement; [labelsHidden](https://developer.apple.com/documentation/swiftui/view/labelshidden())
retains the need for meaningful labels for accessibility.

## Audit

Reviewed all 55 TextField declarations in Banana, including shared wrappers and conditional
Mac/iOS views; there are no SecureField declarations. Fourteen entries now separate semantic
labels from their prompts and hide only the redundant visual label:

| Surface | Fields |
| --- | --- |
| Event creation and editing | Title and guest entry in both editors |
| Location picker | Location or room search |
| Reminder editor | Reminder title |
| Meal capture and review | Initial description, correction, backlog note, additional food and grouped backlog note |
| Problem report | Problem description |
| Booking settings | Link name beside its existing URL prefix |
| Shared AI input | Add, ask and refine entry, using the relevant purpose label |

The remaining declarations use actual value labels, already hide numeric labels beside their
own nutrient labels, or are plain search/composer controls outside Form label layout. No global
form style was changed, and the editors' bindings, parsing, focus actions and identifiers remain.
An older mobile test now finds the reminder title by its stable identifier rather than its old
placeholder-as-accessibility-label.

## Regression coverage

`MacToolbarTests.testEventFieldPromptsStayInsideEmptyFields` opens the real Mac event editor in
the dedicated test VM. It checks the accessible names and placeholders for title/location/guest,
asserts that the title spans the sheet, and captures empty and populated states. The example must
not appear as a separate static label before or after typing. Relevant mobile event, guest, meal
and feedback checks retain editing/submit behavior. These are functional/layout checks, not
frame or input latency measurements.

Final focused results: macOS 27.2 in the existing dedicated Tart VM, 1 passed / 0 failed /
0 skipped / no runtime warnings; iPhone Simulator, 5 passed / 0 failed / 0 skipped (event title
parsing and Undo, guest addition, meal-word editing and Undo, feedback submission, reminder
editor opening). Empty and populated Mac screenshots were inspected. The regression also caught
and corrected a duplicate accessible name caused by an unnecessary explicit override.

The non-beta Mac Release target compiled during the audit; final visual/accessibility evidence
uses the shared editor in a Debug Mac fixture after removing that override. These checks do not
constitute a signed release/preflight or replace the installed stable app. Original environment,
scheme-selection and accessibility failures are retained privately alongside the successful runs.
