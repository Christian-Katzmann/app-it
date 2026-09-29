# App It privacy policy draft

Draft for publisher approval. This copy is packaged locally and has not been
verified as a published policy. Publisher: Christian Katzmann.

## Data used and purpose

App It runs in the coding agent the user selected. It reads the selected local
project's configuration, scripts, relevant source and icon assets to determine
how to create a launcher. It can process local paths, project/app names, bundle
identifiers, URLs, port numbers, process identifiers, build output, diagnostics
and screenshots used to verify that launcher. Project files and server logs may
contain personal information; only use a project the user authorized.

App It writes launcher scripts, configuration, icons, reports, application
bundles, local runtime state and logs. Native WebKit stores website session
state such as cookies and local storage on the user's Mac. The local app loads
the selected local server or hosted URL; hosted sites receive ordinary browser
requests, network identifiers, and any data the user submits to that site.

## Recipients

The publisher operates no App It backend, telemetry collector or analytics
service. App It does not upload project contents to the publisher. The host
coding agent can process prompts, selected files, tool output and screenshots
under that host's privacy terms. A selected hosted website and any services used
by the user's project receive data according to their own behavior and policies.
Optional project dependency installation may contact the configured package
registry only when authorized. Do not copy login cookies, tokens or credentials
from another application into a generated app.

## Retention and controls

The publisher retains no usage data through this package. Generated artifacts
remain on the user's Mac until the user removes them. Runtime PID/port state is
cleaned on normal quit, while diagnostic logs and reports can remain until
deleted; the package sets no automatic retention period for those files.
WebKit website data persists according to macOS and website behavior until
cleared by the user. Host-agent retention is governed by the host's terms.

Users choose the project and URL, can review changes before use, quit the app
to stop its owned runtime, uninstall the generated app, and remove its generated
project files, named runtime/log directories and website data after checking
that they are no longer needed. Do not delete shared project dependencies or
unrelated servers as part of uninstall. Public support issues remain public
according to GitHub's retention policy; do not include private data there.

## Contact

Use [the project's support issues](https://github.com/Christian-Katzmann/app-it/issues)
for non-sensitive questions. Publisher action before release: approve this text,
provide a private contact route for privacy requests, publish the final policy
at an accessible HTTPS URL, and add that verified URL to both OpenAI manifests.
