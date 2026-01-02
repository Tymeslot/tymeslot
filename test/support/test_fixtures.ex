defmodule Tymeslot.TestFixtures do
  @moduledoc """
  Test fixtures for creating complex test data scenarios.
  """

  import Tymeslot.Factory
  alias Tymeslot.DatabaseQueries.{UserQueries, UserSessionQueries}
  alias Tymeslot.Repo
  alias Tymeslot.Security.Token

  @doc """
  Creates a meeting with all associated data.
  """
  @spec create_meeting_fixture(map()) :: term()
  def create_meeting_fixture(attrs \\ %{}) do
    # Handle legacy scheduled_at parameter
    start_time =
      Map.get(
        attrs,
        :scheduled_at,
        Map.get(
          attrs,
          :start_time,
          DateTime.truncate(DateTime.add(DateTime.utc_now(), 1, :day), :second)
        )
      )

    duration = Map.get(attrs, :duration_minutes, Map.get(attrs, :duration, 30))
    end_time = Map.get(attrs, :end_time, DateTime.add(start_time, duration, :minute))

    defaults = %{
      attendee_email: "test@example.com",
      attendee_name: "Test User",
      attendee_message: "Looking forward to our meeting",
      duration: duration,
      start_time: start_time,
      end_time: end_time,
      status: "confirmed",
      video_room_id: "test-room",
      organizer_video_url: "https://test.mirotalk.com/join/test-room?role=organizer",
      attendee_video_url: "https://test.mirotalk.com/join/test-room?role=attendee",
      video_room_enabled: true
    }

    # Remove legacy fields before merging
    attrs = attrs |> Map.delete(:scheduled_at) |> Map.delete(:duration_minutes)
    attrs = Map.merge(defaults, Map.new(attrs))
    insert(:meeting, attrs)
  end

  @doc """
  Creates multiple meetings for testing calendar views.
  """
  @spec create_calendar_scenario(Date.t(), keyword()) :: list(term())
  def create_calendar_scenario(date, opts \\ []) do
    num_meetings = Keyword.get(opts, :num_meetings, 3)
    duration = Keyword.get(opts, :duration, 30)

    Enum.map(0..(num_meetings - 1), fn i ->
      start_time =
        date
        |> DateTime.new!(~T[11:00:00], "Etc/UTC")
        |> DateTime.add(i * (duration + 15), :minute)

      create_meeting_fixture(%{
        start_time: start_time,
        duration: duration,
        attendee_name: "Test User #{i + 1}",
        attendee_email: "test#{i + 1}@example.com"
      })
    end)
  end

  @doc """
  Creates a meeting that's about to start (for reminder testing).
  """
  @spec create_upcoming_meeting_fixture(integer()) :: term()
  def create_upcoming_meeting_fixture(minutes_from_now \\ 30) do
    create_meeting_fixture(%{
      start_time: DateTime.add(DateTime.utc_now(), minutes_from_now, :minute),
      reminder_email_sent: false
    })
  end

  @doc """
  Creates meetings across timezone boundaries for testing.
  """
  @spec create_timezone_test_fixtures() :: {term(), term()}
  def create_timezone_test_fixtures do
    # Meeting at 11:59 PM UTC
    late_meeting =
      create_meeting_fixture(%{
        start_time:
          DateTime.utc_now()
          |> DateTime.add(1, :day)
          |> Map.put(:hour, 23)
          |> Map.put(:minute, 59),
        attendee_name: "Late Night User"
      })

    # Meeting at 12:01 AM UTC next day
    early_meeting =
      create_meeting_fixture(%{
        start_time:
          Map.put(Map.put(DateTime.add(DateTime.utc_now(), 2, :day), :hour, 0), :minute, 1),
        attendee_name: "Early Morning User"
      })

    {late_meeting, early_meeting}
  end

  @doc """
  Creates conflicting meetings for testing double-booking prevention.
  """
  @spec create_conflicting_meetings(DateTime.t()) :: {term(), list(map())}
  def create_conflicting_meetings(start_time) do
    # Existing meeting
    existing =
      create_meeting_fixture(%{
        start_time: start_time,
        attendee_name: "Existing User"
      })

    # Attempted overlapping meetings
    overlapping_attrs = [
      # Starts during existing meeting
      %{start_time: DateTime.add(start_time, 15, :minute)},
      # Starts before and ends during
      %{start_time: DateTime.add(start_time, -15, :minute)},
      # Exact same time
      %{start_time: start_time}
    ]

    {existing, overlapping_attrs}
  end

  @doc """
  Creates test data for rescheduling scenarios.
  """
  @spec create_rescheduling_fixture() :: {term(), DateTime.t()}
  def create_rescheduling_fixture do
    original_time = DateTime.truncate(DateTime.add(DateTime.utc_now(), 2, :day), :second)

    meeting =
      create_meeting_fixture(%{
        start_time: original_time,
        attendee_name: "Reschedule Test User",
        attendee_email: "reschedule@example.com",
        attendee_message: "Original message"
      })

    new_time = DateTime.add(original_time, 1, :day)

    {meeting, new_time}
  end

  @doc """
  Cleans up test meetings by UID pattern.
  """
  @spec cleanup_test_meetings(String.t()) :: {integer(), nil | list(term())}
  def cleanup_test_meetings(uid_pattern \\ "test-") do
    import Ecto.Query

    Repo.delete_all(
      from(m in Tymeslot.DatabaseSchemas.MeetingSchema, where: like(m.uid, ^"#{uid_pattern}%"))
    )
  end

  @doc """
  Creates a full day of booked meetings (for testing no availability).
  """
  @spec create_fully_booked_day(Date.t()) :: term()
  def create_fully_booked_day(date) do
    # Create meetings for every possible slot from 11 AM to 7:30 PM
    start_time = DateTime.new!(date, ~T[11:00:00], "Etc/UTC")
    end_time = DateTime.new!(date, ~T[19:30:00], "Etc/UTC")

    create_meetings_between(start_time, end_time, 30, 15)
  end

  defp create_meetings_between(current_time, end_time, duration, buffer) do
    if DateTime.compare(current_time, end_time) == :lt do
      create_meeting_fixture(%{
        start_time: current_time,
        duration: duration
      })

      next_time = DateTime.add(current_time, duration + buffer, :minute)
      create_meetings_between(next_time, end_time, duration, buffer)
    end
  end

  @doc """
  Creates a test user with default attributes.
  """
  @spec create_user_fixture(map()) :: term()
  def create_user_fixture(attrs \\ %{}) do
    defaults = %{
      email: "user#{System.unique_integer([:positive])}@example.com",
      password: "Password123!",
      password_confirmation: "Password123!",
      name: "Test User",
      verified_at: DateTime.utc_now()
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    {:ok, user} = UserQueries.create_user(attrs)
    user
  end

  @doc """
  Creates a test user session.
  """
  @spec create_session_fixture(term()) :: {term(), binary()}
  def create_session_fixture(user) do
    token = Token.generate_session_token()
    expires_at = DateTime.add(DateTime.utc_now(), 72, :hour)

    {:ok, session} = UserSessionQueries.create_session(user.id, token, expires_at)
    {session, token}
  end
end
