defmodule Tymeslot.Integrations.Calendar.Google.ProviderTimezoneTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Google.Provider

  describe "normalise_events/2 timezone sanitisation" do
    setup do
      context = %{
        calendar_integration_id: 42,
        provider_calendar_id: "primary",
        synced_at: ~U[2026-04-08 12:00:00Z]
      }

      %{context: context}
    end

    test "normalises Windows zone name (Romance Standard Time) to IANA equivalent",
         %{context: context} do
      raw_events = [
        %{
          "iCalUID" => "windows-tz-uid@google.com",
          "id" => "windows-tz-id",
          "summary" => "Paris Meeting",
          "start" => %{
            "dateTime" => "2026-04-08T10:00:00+02:00",
            "timeZone" => "Romance Standard Time"
          },
          "end" => %{
            "dateTime" => "2026-04-08T11:00:00+02:00",
            "timeZone" => "Romance Standard Time"
          }
        }
      ]

      assert {:ok, [event]} = Provider.normalise_events(raw_events, context)
      assert event.timezone == "Europe/Paris"
    end

    test "strips quotes from quoted IANA timezone string", %{context: context} do
      raw_events = [
        %{
          "iCalUID" => "quoted-tz-uid@google.com",
          "id" => "quoted-tz-id",
          "summary" => "Brussels Meeting",
          "start" => %{
            "dateTime" => "2026-04-08T10:00:00+02:00",
            "timeZone" => ~s("Europe/Brussels")
          },
          "end" => %{
            "dateTime" => "2026-04-08T11:00:00+02:00",
            "timeZone" => ~s("Europe/Brussels")
          }
        }
      ]

      assert {:ok, [event]} = Provider.normalise_events(raw_events, context)
      assert event.timezone == "Europe/Brussels"
    end
  end
end
