# Security Policy

## Supported versions

Only the most recent release is supported. Fixes go into the next release rather
than being backported.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Anything older | No |

## Reporting a vulnerability

Open a [public issue](https://github.com/gpambrozio/paseo-menubar/issues/new/choose)
and describe what you found, including the version of Paseo Icon and of the Paseo
desktop app.

Public reporting is a deliberate choice for a project of this size, so be aware
that a report is visible from the moment you file it. If you believe a finding is
serious enough that disclosing it publicly would put users at risk, say so in a
short issue without the details and I will arrange a private channel.

## What this app has access to

Paseo Icon stores no credentials of its own. It reads the host list — including
connection credentials — out of the Paseo desktop app's own local storage, and
uses them to make read-only subscriptions to the daemons the desktop app already
knows about. It never runs agents, never writes to the desktop app's storage, and
creates no window. Findings about how those credentials are read, held in memory,
or logged are in scope.

Vulnerabilities in Paseo itself belong in the [Paseo](https://paseo.sh) project,
not here.
