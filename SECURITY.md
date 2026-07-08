# Security Policy

We take the security of Tymeslot seriously. Because Tymeslot is self-hosted by
many operators, a responsibly disclosed vulnerability lets us ship a fix before
it can be exploited in the wild. Thank you for helping keep the community safe.

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues,
discussions, or pull requests.** A public report exposes every self-hosted
instance until a fix is released.

Instead, report privately through either channel:

- **GitHub Private Vulnerability Reporting** (preferred) — open the
  [Security tab](https://github.com/Tymeslot/tymeslot/security) and click
  **"Report a vulnerability"**. This creates a private advisory visible only to
  the maintainers.
- **Contact form** — [tymeslot.app/contact](https://tymeslot.app/contact).
  Mark your message as a security report and we will follow up privately.

Please include as much of the following as possible:

- The type of issue (e.g. authentication bypass, injection, SSRF, privilege
  escalation, data exposure).
- The affected version or commit, and your deployment type (Docker, Cloudron,
  managed cloud).
- Step-by-step instructions to reproduce, including any proof-of-concept.
- The impact — what an attacker could achieve.

## What to expect

- **Acknowledgement** within **72 hours**.
- An initial assessment and severity rating within **7 days**.
- Regular updates as we work on a fix, and coordination with you on a
  disclosure timeline (we aim to release a patch within **90 days**, sooner for
  actively exploited issues).
- **Credit** in the release notes and security advisory for the fix, unless you
  prefer to remain anonymous.

## Supported versions

Security fixes are released against the **latest published version** on
[GitHub Releases](https://github.com/Tymeslot/tymeslot/releases). Self-hosters
should stay current with the latest release to receive security updates. The
managed cloud at [tymeslot.app](https://tymeslot.app) always runs a supported
version.

## Scope

In scope: the Tymeslot Core codebase in this repository, the official Docker and
Cloudron images, and the managed cloud service.

Out of scope: vulnerabilities in third-party dependencies (report those upstream,
though we appreciate a heads-up), issues requiring physical access to a
self-hoster's server, and findings that depend on a misconfigured deployment
rather than a flaw in Tymeslot itself.

## Safe harbour

We will not pursue or support legal action against researchers who act in good
faith, follow this policy, avoid privacy violations and service disruption, and
give us reasonable time to remediate before any public disclosure.
