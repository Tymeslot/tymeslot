defmodule Tymeslot.Integrations.Calendar.Radicale.Provider do
  @moduledoc """
  Radicale provider: a thin configuration layer over the shared CalDAV
  implementation, providing Radicale-specific defaults and messaging.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  use Tymeslot.Integrations.Calendar.CalDAV.FamilyProvider,
    member: :radicale,
    schema: [
      base_url: "Radicale server URL (e.g., https://radicale.example.com:5232)",
      username: "Radicale username",
      password: "Radicale password",
      calendar_paths: "List of calendar UUIDs to sync (auto-discovered if not provided)"
    ],
    invalid_url_message:
      dgettext(
        "integrations_calendar",
        "Invalid Radicale URL. Should be your Radicale server URL (e.g., https://radicale.example.com:5232)"
      ),
    connected_message: dgettext("integrations_calendar", "Radicale connection successful"),
    not_found_message:
      dgettext(
        "integrations_calendar",
        "Radicale server not found. Check your server URL and port if needed."
      )
end
