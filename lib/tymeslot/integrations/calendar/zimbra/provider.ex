defmodule Tymeslot.Integrations.Calendar.Zimbra.Provider do
  @moduledoc """
  Zimbra provider that leverages the shared CalDAV base module.

  Zimbra uses CalDAV for calendar access with the standard path pattern:
  /dav/{username}/ for calendar discovery.

  This provider is a thin configuration layer over the base CalDAV
  implementation, providing Zimbra-specific defaults and messaging.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  use Tymeslot.Integrations.Calendar.CalDAV.FamilyProvider,
    member: :zimbra,
    schema: [
      base_url:
        "Zimbra server URL (e.g., https://mail.example.com) or full CalDAV URL (e.g., https://mail.example.com/dav/user@example.com)",
      username: "Zimbra username (usually your email address)",
      password: "Zimbra password",
      calendar_paths: "List of calendar paths to sync (auto-discovered if not provided)"
    ],
    invalid_url_message:
      dgettext(
        "integrations_calendar",
        "Invalid Zimbra URL. Should be your Zimbra server URL (e.g., https://mail.example.com) or full CalDAV URL (e.g., https://mail.example.com/dav/user@example.com)"
      ),
    connected_message: dgettext("integrations_calendar", "Zimbra connection successful"),
    not_found_message:
      dgettext("integrations_calendar", "Zimbra server not found. Check your server URL.")
end
