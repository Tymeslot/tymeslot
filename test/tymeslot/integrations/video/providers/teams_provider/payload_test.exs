defmodule Tymeslot.Integrations.Video.Providers.TeamsProvider.PayloadTest do
  use ExUnit.Case, async: true
  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Shared.MicrosoftConfig
  alias Tymeslot.Integrations.Video.EventDetails
  alias Tymeslot.Integrations.Video.Providers.TeamsProvider.Payload

  @start ~U[2030-03-14 09:30:00Z]
  @finish ~U[2030-03-14 10:15:00Z]

  describe "event_window/1" do
    test "takes the booking's title and times from the event details" do
      config = %{
        event_details: %EventDetails{
          summary: "Quarterly review",
          start_time: @start,
          end_time: @finish
        }
      }

      assert Payload.event_window(config) ==
               {:ok, %{subject: "Quarterly review", start_time: @start, end_time: @finish}}
    end

    test "converts times in another zone to UTC" do
      config = %{
        event_details: %EventDetails{
          summary: "Berlin call",
          start_time: DateTime.shift_zone!(@start, "Europe/Berlin"),
          end_time: DateTime.shift_zone!(@finish, "Europe/Berlin")
        }
      }

      assert {:ok, %{start_time: start_time, end_time: end_time}} = Payload.event_window(config)
      assert start_time.time_zone == "Etc/UTC"
      assert DateTime.to_iso8601(start_time) == "2030-03-14T09:30:00Z"
      assert DateTime.to_iso8601(end_time) == "2030-03-14T10:15:00Z"
    end

    test "reads ISO 8601 strings from the flat update keys" do
      config = %{
        meeting_topic: "Moved",
        meeting_start_time: "2030-04-02T16:00:00+02:00",
        meeting_end_time: "2030-04-02T17:00:00+02:00"
      }

      assert {:ok, window} = Payload.event_window(config)
      assert window.subject == "Moved"
      assert window.start_time == ~U[2030-04-02 14:00:00Z]
      assert window.end_time == ~U[2030-04-02 15:00:00Z]
    end

    test "falls back to a generic subject when the booking has no title" do
      config = %{event_details: %EventDetails{start_time: @start, end_time: @finish}}

      assert {:ok, %{subject: "Scheduled Meeting"}} = Payload.event_window(config)
    end

    test "refuses a booking without a start time" do
      config = %{event_details: %EventDetails{summary: "x", end_time: @finish}}

      assert Payload.event_window(config) ==
               {:error, {:configuration_error, "Teams meeting has no exact start_time"}}
    end

    test "refuses a booking without an end time" do
      config = %{event_details: %EventDetails{summary: "x", start_time: @start}}

      assert Payload.event_window(config) ==
               {:error, {:configuration_error, "Teams meeting has no exact end_time"}}
    end

    test "refuses a time it cannot read rather than guessing one" do
      config = %{meeting_start_time: "tomorrow at nine", meeting_end_time: "2030-04-02T17:00:00Z"}

      assert Payload.event_window(config) ==
               {:error, {:configuration_error, "Teams meeting has no exact start_time"}}
    end
  end

  describe "event_fields/1" do
    test "writes the subject and both times as UTC" do
      window = %{subject: "Quarterly review", start_time: @start, end_time: @finish}

      assert Payload.event_fields(window) == %{
               subject: "Quarterly review",
               start: %{dateTime: "2030-03-14T09:30:00Z", timeZone: "UTC"},
               end: %{dateTime: "2030-03-14T10:15:00Z", timeZone: "UTC"}
             }
    end
  end

  describe "online_meeting/1" do
    test "names the business provider for a work or school tenant" do
      assert Payload.online_meeting(%{tenant_id: "contoso-tenant"}) ==
               %{isOnlineMeeting: true, onlineMeetingProvider: "teamsForBusiness"}
    end

    test "leaves the provider to Graph for a personal account or an unknown tenant" do
      for tenant_id <- [MicrosoftConfig.consumer_tenant_id(), "common", nil] do
        assert Payload.online_meeting(%{tenant_id: tenant_id}) == %{isOnlineMeeting: true},
               "tenant #{inspect(tenant_id)}"
      end
    end
  end

  describe "new_event/2" do
    test "is the booking's event with the online meeting switched on" do
      window = %{subject: "Quarterly review", start_time: @start, end_time: @finish}

      assert Payload.new_event(window, %{tenant_id: "contoso-tenant"}) == %{
               subject: "Quarterly review",
               start: %{dateTime: "2030-03-14T09:30:00Z", timeZone: "UTC"},
               end: %{dateTime: "2030-03-14T10:15:00Z", timeZone: "UTC"},
               isOnlineMeeting: true,
               onlineMeetingProvider: "teamsForBusiness"
             }
    end
  end

  describe "join_url/1" do
    test "prefers the online meeting's join link" do
      event = %{
        "onlineMeeting" => %{"joinUrl" => "https://teams.microsoft.com/l/meetup-join/new"},
        "onlineMeetingUrl" => "https://teams.microsoft.com/l/meetup-join/old"
      }

      assert Payload.join_url(event) == "https://teams.microsoft.com/l/meetup-join/new"
    end

    test "falls back to the legacy onlineMeetingUrl" do
      event = %{"onlineMeetingUrl" => "https://teams.microsoft.com/l/meetup-join/old"}

      assert Payload.join_url(event) == "https://teams.microsoft.com/l/meetup-join/old"
    end

    test "is nil for an event without a Teams meeting" do
      assert Payload.join_url(%{"id" => "plain-event", "onlineMeeting" => nil}) == nil
    end
  end
end
