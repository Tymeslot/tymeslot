defmodule Tymeslot.Notifications.EventTypesTest do
  use ExUnit.Case, async: true

  @moduletag :notifications

  alias Tymeslot.Notifications.EventOptions
  alias Tymeslot.Notifications.EventTypes
  alias Tymeslot.Slack
  alias Tymeslot.Telegram
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias Tymeslot.Webhooks

  # Every channel's dashboard form offers this list. A channel whose form
  # showed fewer events than it subscribes to dropped the hidden ones on the
  # first edit, and one that could not offer an event could never send it.
  describe "options/0 and the channels that offer it" do
    test "offers every event, in order" do
      assert Enum.map(EventOptions.options(), & &1.value) == EventTypes.all()
    end

    test "Slack, Telegram and webhooks all offer every event" do
      for options <- [
            Slack.available_events(),
            Telegram.available_events(),
            Webhooks.available_events()
          ] do
        assert Enum.map(options, & &1.value) == EventTypes.all()
      end
    end

    test "Telegram accepts a subscription to every event" do
      assert TelegramIntegrationSchema.valid_events() == EventTypes.all()
    end

    test "labels are translated into the current locale" do
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        requested = Enum.find(Telegram.available_events(), &(&1.value == "meeting.requested"))
        assert requested.label == "Buchung angefragt"
      end)
    end
  end

  describe "to_event_type/1" do
    test "maps the three known event atoms to their wire names" do
      assert EventTypes.to_event_type(:meeting_created) == "meeting.created"
      assert EventTypes.to_event_type(:meeting_cancelled) == "meeting.cancelled"
      assert EventTypes.to_event_type(:meeting_rescheduled) == "meeting.rescheduled"
    end

    test "raises on an atom with no known wire name" do
      assert_raise ArgumentError, ~r/unknown event type/, fn ->
        EventTypes.to_event_type(:something_new)
      end
    end
  end

  describe "all/0" do
    test "returns every wire name to_event_type/1 can produce" do
      assert Enum.sort(EventTypes.all()) ==
               Enum.sort([
                 "meeting.cancelled",
                 "meeting.created",
                 "meeting.declined",
                 "meeting.request_expired",
                 "meeting.requested",
                 "meeting.rescheduled"
               ])
    end
  end
end
