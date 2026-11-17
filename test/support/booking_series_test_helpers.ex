defmodule Tymeslot.BookingSeriesTestHelpers do
  @moduledoc """
  What the booking series domain suites (`test/tymeslot/booking_series/`)
  share: a host and a weekly series type (held for approval or not), a
  series booked by Ada, the series' sessions and their statuses in series
  order, the email jobs enqueued for an action, a series read back, a
  session moved into the past, and the params moving one to another day.

  Each suite books one series at a time, so "the series' sessions" are
  every meeting that belongs to a series.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions, only: [assert: 1]
  import Tymeslot.AvailabilityTestHelpers, only: [create_always_bookable_profile: 1]
  import Tymeslot.Factory, only: [insert: 2]

  alias Ecto.Changeset
  alias Oban.Testing
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.PaidSeriesTestHelpers, as: Paid
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  @doc "A host whose page is bookable at any time, in UTC."
  @spec host(String.t()) :: map()
  def host(username \\ "grace-host") do
    create_always_bookable_profile(
      timezone: "Etc/UTC",
      profile: %{username: username, full_name: "Grace Hopper"}
    )
  end

  @doc "A weekly series type of two to twelve sessions, `attrs` overriding."
  @spec series_type(map(), keyword()) :: struct()
  def series_type(host, attrs \\ []) do
    insert(
      :meeting_type,
      Keyword.merge(
        [
          user: host.user,
          name: "Mentoring",
          duration_minutes: 30,
          series_mode: :recurring,
          series_frequency: :weekly,
          series_interval: 1,
          series_min_occurrences: 2,
          series_max_occurrences: 12
        ],
        attrs
      )
    )
  end

  @doc "A `series_type/2` held for approval, answered within 48 hours."
  @spec approval_type(map(), keyword()) :: struct()
  def approval_type(host, attrs \\ []),
    do:
      series_type(
        host,
        Keyword.merge([requires_approval: true, approval_window_hours: 48], attrs)
      )

  @doc "Ada books `count` weekly sessions of `type`, the first a week from today."
  @spec book(map(), struct(), pos_integer(), String.t()) :: term()
  def book(host, type, count, message \\ "") do
    BookingSeries.book(
      %{
        duration: 30,
        user_timezone: "Etc/UTC",
        organizer_user_id: host.user.id,
        meeting_type_id: type.id,
        series: %{mode: :recurring, first_start: Paid.at(7), count: count}
      },
      %{"name" => "Ada Lovelace", "email" => "ada@example.com", "message" => message}
    )
  end

  @doc "Ada asks for three sessions of an approval series, with a message."
  @spec book_three(map(), struct() | nil) :: map()
  def book_three(host \\ host(), type \\ nil) do
    type = type || approval_type(host)
    assert {:ok, %{series: series}} = book(host, type, 3, "Weekly please")
    %{host: host, type: type, series: series}
  end

  @doc "The params moving a session to 10:00 UTC, `days` from today."
  @spec move_to(integer()) :: map()
  def move_to(days) do
    %{
      date: days |> Paid.at() |> DateTime.to_date() |> Date.to_string(),
      time: "10:00 AM",
      duration: "30min",
      user_timezone: "Etc/UTC"
    }
  end

  @doc "Every meeting of a series, in series order."
  @spec meetings() :: [MeetingSchema.t()]
  def meetings,
    do:
      Repo.all(
        from(m in MeetingSchema, where: not is_nil(m.series_id), order_by: m.series_position)
      )

  @doc "The statuses of `meetings/0`, in series order."
  @spec statuses() :: [atom()]
  def statuses, do: Enum.map(meetings(), & &1.status)

  @doc "The email jobs enqueued for `action`."
  @spec email_jobs(String.t()) :: [Oban.Job.t()]
  def email_jobs(action),
    do: Testing.all_enqueued(Repo, worker: EmailWorker, args: %{"action" => action})

  @doc "The series as it is now stored."
  @spec reload_series(SeriesSchema.t()) :: SeriesSchema.t()
  def reload_series(series), do: Repo.get!(SeriesSchema, series.id)

  @doc """
  Moves a session into the past, as far back as its position in weeks: it
  has happened.
  """
  @spec into_the_past!(MeetingSchema.t()) :: MeetingSchema.t()
  def into_the_past!(meeting) do
    start = DateTime.add(DateTime.utc_now(:second), -7 * meeting.series_position, :day)

    meeting
    |> Changeset.change(start_time: start, end_time: DateTime.add(start, 30, :minute))
    |> Repo.update!()
  end
end
