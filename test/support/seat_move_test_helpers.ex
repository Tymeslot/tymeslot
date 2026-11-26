defmodule Tymeslot.SeatMoveTestHelpers do
  @moduledoc """
  The shared setup and helpers of the move-my-seat integration tests
  (`Tymeslot.Bookings.RescheduleSeatIntegrationTest` and its sibling
  `RescheduleSeatChecksIntegrationTest`): an organiser offering every hour,
  a two-seat group type at one venue, and a booker's seat two days out to move.
  """

  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]
  import Tymeslot.Factory

  alias Tymeslot.Bookings.{Create, RescheduleSeat}
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  @doc "Builds the organiser, group type and seat every move test starts from."
  @spec seat_move_context(map()) :: map()
  def seat_move_context(_context) do
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    user = insert(:user, email: "organizer@example.com", name: "Test Organizer")
    profile = insert(:profile, user: user, timezone: "America/New_York")

    # The seat move is this test's subject, not availability: the host offers
    # every hour of every day so the schedule is never why a booking is refused.
    open_schedule_for(profile)

    # A group type's location is fixed in advance: one venue.
    venue = insert(:venue, user: user, name: "Main Hall", description: "1 Market Square")

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        is_active: true,
        max_participants: 2,
        locations: [in_person_location([venue])]
      )

    base_params = %{
      duration: "30min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    old_params = Map.merge(base_params, %{date: Date.add(Date.utc_today(), 2), time: "14:00"})

    {:ok, old_meeting} =
      Create.execute(old_params, %{"name" => "Mover", "email" => "mover@example.com"})

    mover =
      old_meeting.id
      |> ParticipantQueries.list_live_for_meeting()
      |> Enum.find(&(&1.email == "mover@example.com"))

    %{
      user: user,
      venue: venue,
      meeting_type: meeting_type,
      base_params: base_params,
      old_meeting: old_meeting,
      mover: mover
    }
  end

  @doc """
  Moves `participant`'s seat, submitted from its own organiser's booking
  page, as the seat reschedule link sends it.
  """
  @spec move(struct(), map()) :: term()
  def move(participant, params) do
    organizer_user_id = Repo.get!(MeetingSchema, participant.meeting_id).organizer_user_id
    RescheduleSeat.execute(participant.management_token, params, organizer_user_id)
  end

  @doc "The start, in UTC, of the slot `new_slot_params/0` asks for."
  @spec new_slot_start() :: DateTime.t()
  def new_slot_start do
    Date.utc_today()
    |> Date.add(3)
    |> DateTime.new!(~T[10:00:00], "America/New_York")
    |> DateTime.shift_zone!("Etc/UTC")
  end

  @doc "A 30-minute busy event on the organiser's calendar."
  @spec busy_event(String.t(), DateTime.t()) :: map()
  def busy_event(uid, start_time) do
    %{
      uid: uid,
      summary: "Busy",
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute)
    }
  end

  @doc "Stubs the organiser's calendar to return `events`."
  @spec stub_calendar_events([map()]) :: module()
  def stub_calendar_events(events), do: stub_calendar_result({:ok, events})

  @doc "Stubs the organiser's calendar fetch to return `result`."
  @spec stub_calendar_result(term()) :: module()
  def stub_calendar_result(result) do
    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      result
    end)
  end

  @doc "Move params for 10:00 New York time, three days out."
  @spec new_slot_params() :: map()
  def new_slot_params do
    %{
      date: Date.to_iso8601(Date.add(Date.utc_today(), 3)),
      time: "10:00",
      duration: "30min",
      user_timezone: "America/New_York"
    }
  end
end
