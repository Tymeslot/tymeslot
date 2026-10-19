defmodule Tymeslot.Integrations.Calendar.Apple.Provider do
  @moduledoc """
  Apple iCloud provider that leverages the shared CalDAV base module.

  iCloud exposes calendars over CalDAV at the fixed host `caldav.icloud.com`.
  The server URL is therefore locked — users only supply their Apple ID email
  and an **app-specific password** (iCloud rejects the account password and
  requires a password generated at appleid.apple.com → Sign-In and Security →
  App-Specific Passwords).

  Two operational notes that differ from other CalDAV providers:

  * The guessed `/calendars/{user}/` discovery path returns `403`; iCloud only
    reveals calendars through the RFC 4791 principal chain, which the shared
    discovery layer follows automatically on a `403`.
  * `calendar-home-set` is returned as an absolute URL on a per-user partition
    host (e.g. `https://p110-caldav.icloud.com/…/calendars/`); the shared
    `UrlBuilder` reduces it to its path and pins it to the validated
    `caldav.icloud.com` host, which serves the same collections.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  use Tymeslot.Integrations.Calendar.CalDAV.FamilyProvider,
    member: :apple,
    schema: [
      base_url: "Apple iCloud CalDAV server URL (always https://caldav.icloud.com)",
      username: "Apple ID email address (e.g. you@icloud.com)",
      password:
        "An app-specific password generated at appleid.apple.com — not your Apple ID password",
      calendar_paths: "List of calendar paths to sync (auto-discovered when omitted)"
    ],
    invalid_url_message:
      dgettext(
        "integrations_calendar",
        "Invalid Apple iCloud URL. The server must be https://caldav.icloud.com."
      ),
    connected_message: dgettext("integrations_calendar", "Apple iCloud connection successful"),
    not_found_message:
      dgettext(
        "integrations_calendar",
        "Apple iCloud CalDAV endpoint not found. The server URL must be https://caldav.icloud.com"
      )
end
