# App It privacy policy

## Scope

This policy covers the reviewed app-it plugin package version 0.2.0. It does not describe other versions, legacy tools, or every file in the source repository. Publication of this policy does not by itself announce a software release.

Publisher: Christian Katzmann.

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

## Publisher and contact

Publisher: Christian Katzmann. Effective date: September 30, 2026. For private privacy or support requests, contact [christian@katzmann.dk](mailto:christian@katzmann.dk). Send a minimal description; do not include credentials, notebook contents, production records or raw traces. Any information you choose to send for support is processed in the publisher's existing email service to answer that request, and remains until the correspondence is deleted. Request deletion through the same address. Provider backups and mandatory retention, if applicable, can outlast live-mailbox deletion.
