defmodule Tymeslot.Integrations.Calendar.Baikal.Provider do
  @moduledoc """
  Baikal provider that leverages the shared CalDAV base module.

  Baikal is a PHP-based CalDAV/CardDAV server. It exposes CalDAV through a
  `/dav.php` endpoint and stores calendars under
  `/dav.php/calendars/USERNAME/CALENDAR/`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  use Tymeslot.Integrations.Calendar.CalDAV.FamilyProvider,
    member: :baikal,
    schema: [
      base_url: "Baikal server URL (e.g., https://baikal.example.com/dav.php)",
      username: "Baikal username",
      password: "Baikal password",
      calendar_paths: "List of calendar paths to sync (auto-discovered if not provided)"
    ],
    invalid_url_message:
      dgettext(
        "integrations_calendar",
        "Invalid Baikal URL. Should be your Baikal server URL including /dav.php (e.g., https://baikal.example.com/dav.php)"
      ),
    connected_message: dgettext("integrations_calendar", "Baikal connection successful"),
    not_found_message:
      dgettext(
        "integrations_calendar",
        "Baikal server not found. Confirm the URL includes /dav.php (e.g., https://baikal.example.com/dav.php)."
      )
end
