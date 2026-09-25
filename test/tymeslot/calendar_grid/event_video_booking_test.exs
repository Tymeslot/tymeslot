defmodule Tymeslot.CalendarGrid.EventVideoBookingTest do
  @moduledoc """
  `CalendarGrid.change_event_video/3` refuses an event that is the calendar
  copy of a Tymeslot booking: the booking's room is the meeting's, and a room
  made from the grid would leave its emails pointing at the old one.

  No provider is stubbed: a refusal must reach neither the video provider nor
  the calendar, and Mox fails any call that was not expected.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :video

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  setup :verify_on_exit!

  @link "https://video.example.com/join/booking-room"

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "google")
    video_integration = insert(:video_integration, user: user, provider: "mirotalk")

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "google",
        provider_event_id: "booking-google-id",
        description: "Join video call: #{@link}",
        video_link: @link,
        video_integration_id: video_integration.id
      )

    %{user: user, integration: integration, video_integration: video_integration, event: event}
  end

  describe "change_event_video/3 on the calendar copy of a booking" do
    for field <- [:uid, :provider_event_id] do
      test "linked by its #{field}, refuses a new room and leaves the event alone", %{
        user: user,
        integration: integration,
        event: event
      } do
        link_meeting(integration, Map.take(event, [unquote(field)]))
        other = insert(:video_integration, user: user, provider: "mirotalk")

        assert {:error, :linked_to_booking} =
                 CalendarGrid.change_event_video(user.id, event, other.id)

        assert_untouched(event)
      end
    end

    test "refuses removing the booking's link", %{
      user: user,
      integration: integration,
      event: event
    } do
      link_meeting(integration, %{uid: event.uid})

      assert {:error, :linked_to_booking} = CalendarGrid.change_event_video(user.id, event, nil)
      assert_untouched(event)
    end

    test "still answers an unchanged choice as unchanged", %{
      user: user,
      integration: integration,
      video_integration: video_integration,
      event: event
    } do
      link_meeting(integration, %{uid: event.uid})

      assert {:ok, :unchanged} =
               CalendarGrid.change_event_video(user.id, event, video_integration.id)
    end
  end

  describe "ensure_video_changeable/1" do
    test "allows an event no booking mirrors", %{event: event} do
      assert :ok = CalendarGrid.ensure_video_changeable(event)
    end
  end

  defp link_meeting(integration, identity) do
    insert(
      :meeting,
      Map.merge(
        %{calendar_integration_id: integration.id, uid: "unrelated-uid", provider_event_id: nil},
        identity
      )
    )
  end

  defp assert_untouched(event) do
    assert {:ok, row} =
             ProviderCalendarEventQueries.get_by_uid(event.calendar_integration_id, event.uid)

    assert {row.video_link, row.video_integration_id, row.description} ==
             {event.video_link, event.video_integration_id, event.description}
  end
end
