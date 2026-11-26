defmodule Tymeslot.Integrations.MeetingProvisioningGoogleMeetTest do
  @moduledoc """
  A booking on the Google Calendar of the same Google account as its Google
  Meet integration. Google Calendar replaces a Meet code made outside Calendar
  with one made for the event, so such a booking takes the Meet Google makes
  with the booking's event.
  """

  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.MeetingProvisioning
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.ClockHelpers

  setup :verify_on_exit!

  @meet_url "https://meet.google.com/abc-defg-hij"
  @booked_at ~U[2026-03-01 10:00:00Z]

  defp meet_booking(opts) do
    user = insert(:user)

    calendar =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        provider_account_id: Keyword.get(opts, :calendar_account, "google-sub-1"),
        default_booking_calendar_id: Keyword.get(opts, :default_calendar),
        needs_reauth: Keyword.get(opts, :calendar_needs_reauth, false)
      )

    video =
      insert(:video_integration,
        user: user,
        provider: "google_meet",
        provider_account_id: "google-sub-1",
        needs_reauth: Keyword.get(opts, :needs_reauth, false)
      )

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        video_integration_id: video.id,
        calendar_integration_id: calendar.id,
        provider_event_id: Keyword.get(opts, :provider_event_id),
        inserted_at: @booked_at
      )

    %{calendar: calendar, meeting: meeting}
  end

  # The booking's calendar is the one the resolver names for this very
  # meeting; answering for any other meeting would hide a caller that asks
  # about the wrong one.
  defp stub_booking_calendar(%MeetingSchema{id: meeting_id}, calendar_id, path \\ "primary") do
    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn
      %MeetingSchema{id: ^meeting_id} ->
        {:ok, %{integration_id: calendar_id, calendar_path: path}}
    end)
  end

  # The booking's event, read from the calendar `calendar_path` as Google
  # answers for it, carrying `conference` as its `conferenceData`.
  defp stub_booking_event(%{calendar: calendar, meeting: meeting}, conference, path \\ "primary") do
    stub_booking_calendar(meeting, calendar.id, path)
    event_id = meeting.provider_event_id
    calendar_id = calendar.id
    user_id = meeting.organizer_user_id
    read_from = path || "primary"

    stub(Tymeslot.CalendarMock, :fetch_event, fn
      %{provider_event_id: ^event_id, calendar_id: ^read_from}, {^calendar_id, ^user_id} ->
        {:ok, [%{provider_metadata: %{"conferenceData" => conference}}]}
    end)
  end

  defp stub_unreadable_event(%{calendar: calendar, meeting: meeting}, error) do
    stub_booking_calendar(meeting, calendar.id)
    stub(Tymeslot.CalendarMock, :fetch_event, fn _ref, _context -> error end)
  end

  # The booking's event is written once, as the booking stands, asking Google
  # for a Meet with a booking request that records when it was made.
  defp expect_conference_request(%{meeting: meeting}, result) do
    event_id = meeting.provider_event_id
    meeting_id = meeting.id

    expect(Tymeslot.CalendarMock, :update_event, fn ^event_id, event_data, %{id: ^meeting_id} ->
      asked_at = DateTime.to_unix(Clock.utc_now())

      assert %{createRequest: %{requestId: "tymeslot-booking-" <> request}} =
               event_data.conference_data

      assert String.starts_with?(request, "#{asked_at}-")
      result
    end)
  end

  defp made_meet,
    do: %{"entryPoints" => [%{"entryPointType" => "video", "uri" => @meet_url}]}

  defp pending_meet,
    do: %{"createRequest" => %{"status" => %{"statusCode" => "pending"}}}

  defp at_seconds(seconds, fun),
    do: ClockHelpers.with_frozen_clock(DateTime.add(@booked_at, seconds, :second), fun)

  describe "MeetingProvisioning.booking_room_placement/1" do
    test "takes the Meet Google made on the booking's event" do
      booking = meet_booking(provider_event_id: "google-event-1")
      stub_booking_event(booking, made_meet())

      at_seconds(10, fn ->
        assert MeetingProvisioning.booking_room_placement(booking.meeting) ==
                 {:calendar_meet, "google-event-1", @meet_url}
      end)
    end

    test "waits while Google is still making the event's Meet" do
      booking = meet_booking(provider_event_id: "google-event-1")
      stub_booking_event(booking, pending_meet())

      at_seconds(10, fn ->
        assert MeetingProvisioning.booking_room_placement(booking.meeting) ==
                 :awaiting_calendar_event
      end)
    end

    test "makes a Meet of its own once the event's Meet is overdue" do
      booking = meet_booking(provider_event_id: "google-event-1")
      stub_booking_event(booking, pending_meet())

      at_seconds(121, fn ->
        assert MeetingProvisioning.booking_room_placement(booking.meeting) == :own_event
      end)
    end

    # An event written before the booking was put on Meet: long after the
    # booking, so the wait for its jobs is over, yet the Meet still belongs on
    # the event, which is asked for one in place.
    test "asks an event that asked for no Meet for one in place, and waits for it" do
      booking = meet_booking(provider_event_id: "google-event-1")
      stub_booking_event(booking, nil)
      expect_conference_request(booking, {:ok, %{}})

      at_seconds(600, fn ->
        assert MeetingProvisioning.booking_room_placement(booking.meeting) ==
                 :awaiting_calendar_event
      end)
    end

    test "makes a Meet of its own when the calendar refuses the Meet asked for in place" do
      booking = meet_booking(provider_event_id: "google-event-1")
      stub_booking_event(booking, nil)
      expect_conference_request(booking, {:error, :conference_refused})

      at_seconds(600, fn ->
        assert MeetingProvisioning.booking_room_placement(booking.meeting) == :own_event
      end)
    end

    # The booking left Meet after the job read it: the event is not asked,
    # and the next attempt reads the booking as it now stands.
    test "does not ask the event for a Meet once the booking has left Meet" do
      booking = meet_booking(provider_event_id: "google-event-1")
      stub_booking_event(booking, nil)

      booking.meeting
      |> Changeset.change(video_integration_id: nil)
      |> Repo.update!()

      at_seconds(10, fn ->
        assert MeetingProvisioning.booking_room_placement(booking.meeting) ==
                 :awaiting_calendar_event
      end)
    end

    # A meeting that keeps reading as changed (cancelled while its event
    # still stands) would otherwise be read again every few seconds for good.
    test "makes a Meet of its own once a booking that keeps changing outlasts the wait" do
      booking = meet_booking(provider_event_id: "google-event-1")
      stub_booking_event(booking, nil)

      booking.meeting
      |> Changeset.change(status: :cancelled)
      |> Repo.update!()

      at_seconds(121, fn ->
        assert MeetingProvisioning.booking_room_placement(booking.meeting) == :own_event
      end)
    end

    # Nothing will come to wait for, and the booking's confirmation waits on
    # the room.
    test "makes a Meet of its own at once when Google failed the event's Meet" do
      booking = meet_booking(provider_event_id: "google-event-1")

      stub_booking_event(booking, %{
        "createRequest" => %{"status" => %{"statusCode" => "failure"}}
      })

      at_seconds(10, fn ->
        assert MeetingProvisioning.booking_room_placement(booking.meeting) == :own_event
      end)
    end

    test "makes a Meet of its own at once when Google no longer has the event" do
      booking = meet_booking(provider_event_id: "google-event-1")
      stub_unreadable_event(booking, {:error, :not_found})

      at_seconds(10, fn ->
        assert MeetingProvisioning.booking_room_placement(booking.meeting) == :own_event
      end)
    end

    test "waits for a Meet asked for after the booking from when it was asked for" do
      booking = meet_booking(provider_event_id: "google-event-1")
      requested_at = @booked_at |> DateTime.add(600, :second) |> DateTime.to_unix()

      stub_booking_event(booking, %{
        "createRequest" => %{
          "requestId" => "tymeslot-booking-#{requested_at}-0123456789ABCDEF",
          "status" => %{"statusCode" => "pending"}
        }
      })

      at_seconds(719, fn ->
        assert MeetingProvisioning.booking_room_placement(booking.meeting) ==
                 :awaiting_calendar_event
      end)

      at_seconds(721, fn ->
        assert MeetingProvisioning.booking_room_placement(booking.meeting) == :own_event
      end)
    end

    # The booking resolver hands a create the meeting's own integration with
    # no calendar named, which Google writes to the primary calendar, whatever
    # the integration's stored default.
    test "reads the event from the primary calendar when the booking names none" do
      booking =
        meet_booking(provider_event_id: "google-event-1", default_calendar: "team@group.google")

      stub_booking_event(booking, made_meet(), nil)

      at_seconds(10, fn ->
        assert MeetingProvisioning.booking_room_placement(booking.meeting) ==
                 {:calendar_meet, "google-event-1", @meet_url}
      end)
    end

    # Whether the event carries a Meet is unknown, and a Meet of its own could
    # be a second one, so a read that may yet succeed is waited out like the
    # event itself.
    test "waits rather than make a Meet of its own while the event cannot be read" do
      booking = meet_booking(provider_event_id: "google-event-1")
      stub_unreadable_event(booking, {:error, :rate_limited})

      at_seconds(10, fn ->
        assert MeetingProvisioning.booking_room_placement(booking.meeting) ==
                 :awaiting_calendar_event
      end)
    end

    test "makes a Meet of its own once the event has been unreadable for the whole wait" do
      booking = meet_booking(provider_event_id: "google-event-1")
      stub_unreadable_event(booking, {:error, :rate_limited})

      at_seconds(121, fn ->
        assert MeetingProvisioning.booking_room_placement(booking.meeting) == :own_event
      end)
    end

    # Retrying these would only leave the booking without any link.
    for reason <- [:unauthorized, :no_calendar_integration] do
      test "makes a Meet of its own at once when the calendar read fails with #{reason}" do
        booking = meet_booking(provider_event_id: "google-event-1")
        stub_unreadable_event(booking, {:error, unquote(reason)})

        at_seconds(10, fn ->
          assert MeetingProvisioning.booking_room_placement(booking.meeting) == :own_event
        end)
      end
    end

    test "makes a Meet of its own at once when the calendar waits to be reconnected" do
      booking = meet_booking(provider_event_id: "google-event-1", calendar_needs_reauth: true)
      stub_unreadable_event(booking, {:error, :network_error})

      at_seconds(10, fn ->
        assert MeetingProvisioning.booking_room_placement(booking.meeting) == :own_event
      end)
    end

    test "waits for the booking's event when the calendar has not written it yet" do
      %{calendar: calendar, meeting: meeting} = meet_booking(provider_event_id: nil)
      stub_booking_calendar(meeting, calendar.id)

      at_seconds(10, fn ->
        assert MeetingProvisioning.booking_room_placement(meeting) == :awaiting_calendar_event
      end)
    end

    test "makes a Meet of its own when the calendar is another Google account" do
      %{calendar: calendar, meeting: meeting} =
        meet_booking(calendar_account: "google-sub-2", provider_event_id: "google-event-1")

      stub_booking_calendar(meeting, calendar.id)

      at_seconds(10, fn ->
        assert MeetingProvisioning.booking_room_placement(meeting) == :own_event
      end)
    end
  end

  describe "MeetingProvisioning.booking_event_video_fields/1" do
    test "has the event created asking Google for a Meet while the room waits for it" do
      %{calendar: calendar, meeting: meeting} = meet_booking(provider_event_id: nil)
      stub_booking_calendar(meeting, calendar.id)

      at_seconds(10, fn ->
        assert %{
                 conference_data: %{
                   createRequest: %{conferenceSolutionKey: %{type: "hangoutsMeet"}}
                 }
               } = MeetingProvisioning.booking_event_video_fields(meeting)
      end)
    end

    test "asks for no Meet on an event the booking already has" do
      %{calendar: calendar, meeting: meeting} = meet_booking(provider_event_id: "google-event-1")
      stub_booking_calendar(meeting, calendar.id)

      at_seconds(10, fn ->
        assert MeetingProvisioning.booking_event_video_fields(meeting) == %{}
      end)
    end

    # The video job refuses such an integration, so a Meet on the event would
    # be a link the booking and its emails never carry.
    test "asks for no Meet when the Meet integration waits to be reconnected" do
      %{calendar: calendar, meeting: meeting} =
        meet_booking(provider_event_id: nil, needs_reauth: true)

      stub_booking_calendar(meeting, calendar.id)

      at_seconds(10, fn ->
        assert MeetingProvisioning.booking_event_video_fields(meeting) == %{}
      end)
    end
  end

  describe "MeetingProvisioning.booking_event_update_fields/1" do
    # The booking's event as last synced, carrying a conference made at
    # `request_id`.
    defp cache_booking_event(%{calendar: calendar, meeting: meeting}, request_id) do
      insert(:provider_calendar_event,
        calendar_integration: calendar,
        provider_event_id: meeting.provider_event_id,
        provider_metadata: %{
          "conferenceData" => %{"createRequest" => %{"requestId" => request_id}}
        }
      )
    end

    test "takes off the Meet the booking asked for once the booking moved off Meet" do
      booking = meet_booking(provider_event_id: "google-event-1")
      cache_booking_event(booking, "tymeslot-booking-0123456789ABCDEF")
      moved = %{booking.meeting | video_integration_id: nil}

      assert MeetingProvisioning.booking_event_update_fields(moved) == %{conference_data: :remove}
    end

    test "leaves a conference the organiser added in Google Calendar" do
      booking = meet_booking(provider_event_id: "google-event-1")
      cache_booking_event(booking, "added-in-google-calendar")
      moved = %{booking.meeting | video_integration_id: nil}

      assert MeetingProvisioning.booking_event_update_fields(moved) == %{}
    end

    test "leaves the Meet a booking still waits to take" do
      %{calendar: calendar, meeting: meeting} =
        booking = meet_booking(provider_event_id: "google-event-1")

      cache_booking_event(booking, "tymeslot-booking-0123456789ABCDEF")
      stub_booking_calendar(meeting, calendar.id)

      assert MeetingProvisioning.booking_event_update_fields(meeting) == %{}
    end
  end
end
