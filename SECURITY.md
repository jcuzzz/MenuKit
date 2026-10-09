# Security Policy

## Supported versions

Security fixes land on the latest released minor version. MenuKit is pre-1.0; older minors are
not patched.

## Reporting a vulnerability

**Do not open a public issue.** Report privately through GitHub:
**Security → Report a vulnerability** on this repository (private vulnerability reporting).
Include the MenuKit and Godot versions, steps to reproduce, and the output of
`MKRoot.dump_diagnostics()` if relevant.

Expect an acknowledgement within a week. Fixes are released with a CHANGELOG entry that credits
the reporter unless they ask otherwise.

## Scope

MenuKit is a client-side UI addon. Its own I/O is limited to reading and writing JSON settings,
input bindings and profiles under `user://`, which makes **malformed or hostile save files** the
main attack surface. The JSON backends treat unparseable or wrongly-typed files by quarantining
them rather than trusting them. The network backend is an abstraction: MenuKit ships only a stub
and never opens sockets itself, so real networking is the host's code and out of scope here.
