defmodule Tymeslot.Integrations.Calendar.MailboxOrg.Provider do
  @moduledoc """
  mailbox.org provider that leverages the shared CalDAV base module.

  mailbox.org runs Open-Xchange and exposes calendars under a fixed
  `/caldav/` calendar-home-set. Calendar paths are server-issued opaque
  base64 identifiers, so this module never builds a path from user input —
  paths come from discovery only.

  Two operational notes that differ from other CalDAV providers:

  * Open-Xchange returns `201 Created` for both creates *and* updates and
    omits `ETag` on PUT responses. The shared layer already accepts
    `[200, 201, 204]` and re-fetches the ETag via HEAD/GET when needed.
  * Users with two-factor authentication must use an application-specific
    password generated under `Settings → Security`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  use Tymeslot.Integrations.Calendar.CalDAV.FamilyProvider,
    member: :mailbox_org,
    schema: [
      base_url: "mailbox.org CalDAV server URL (default: https://dav.mailbox.org)",
      username: "mailbox.org email address (e.g. you@mailbox.org)",
      password: "mailbox.org password — or an application-specific password if 2FA is enabled",
      calendar_paths: "List of calendar paths to sync (auto-discovered when omitted)"
    ],
    invalid_url_message:
      dgettext(
        "integrations_calendar",
        "Invalid mailbox.org URL. The server must be https://dav.mailbox.org."
      ),
    connected_message: dgettext("integrations_calendar", "mailbox.org connection successful"),
    not_found_message:
      dgettext(
        "integrations_calendar",
        "mailbox.org CalDAV endpoint not found. Confirm the server URL is https://dav.mailbox.org"
      )
end
