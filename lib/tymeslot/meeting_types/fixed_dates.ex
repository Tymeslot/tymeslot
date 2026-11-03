defmodule Tymeslot.MeetingTypes.FixedDates do
  @moduledoc """
  Fixed dates: a meeting type that offers dates its host chose, rather than
  the slots its availability schedule produces. One setting, two shapes,
  decided by whether the type is a group type:

    * a group type offers **sessions** (`sessions?/1`): a webinar, a
      training or a class that takes place on given dates fills each date
      up to the type's participant limit and is over once the last date has
      passed. The sessions are the type's planned group meetings
      (`Tymeslot.Meetings.PlannedSessions`), on the host's calendar from the
      moment they are planned.
    * a one-to-one type offers **offered times** (`offered_times?/1`): the
      exact starts the host listed (`Tymeslot.MeetingTypes.OfferedTimes`).
      They are not meetings; they replace the weekly schedule as the source
      of the type's starts, and every other booking rule still applies.

  This module holds the rules about the type.
  """

  use Gettext, backend: TymeslotWeb.Gettext
  import Ecto.Changeset

  alias Tymeslot.Availability.SessionSlots
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.MeetingTypes.OfferedTimes

  @doc "Whether `meeting_type` offers planned sessions: a group type with fixed dates."
  @spec sessions?(map() | nil) :: boolean()
  def sessions?(%{fixed_dates: true, max_participants: max}) when is_integer(max) and max > 1,
    do: true

  def sessions?(_meeting_type), do: false

  @doc """
  Whether `meeting_type` offers the exact times its host listed: a
  one-to-one type with fixed dates.
  """
  @spec offered_times?(map() | nil) :: boolean()
  def offered_times?(%{fixed_dates: true} = meeting_type),
    do: Map.get(meeting_type, :max_participants) in [nil, 1]

  def offered_times?(_meeting_type), do: false

  @doc """
  `meeting_types` without the fixed-date ones nobody can book any more: a
  group type whose sessions have all passed, closed registration or filled
  up, and a one-to-one type with no upcoming offered time. Such a type is
  left off the public booking page, as an inactive one is; its direct link
  still says why it cannot be booked.
  """
  @spec reject_unbookable([map()]) :: [map()]
  def reject_unbookable(meeting_types) do
    open_ids =
      meeting_types
      |> Enum.filter(&sessions?/1)
      |> SessionSlots.open_type_ids()

    offering_ids =
      meeting_types
      |> Enum.filter(&offered_times?/1)
      |> OfferedTimes.next_by_type()
      |> Enum.flat_map(fn {id, next} -> if next, do: [id], else: [] end)
      |> MapSet.new()

    Enum.reject(meeting_types, fn type ->
      (sessions?(type) and not MapSet.member?(open_ids, type.id)) or
        (offered_times?(type) and not MapSet.member?(offering_ids, type.id))
    end)
  end

  @doc """
  Refuses an update that would stop `meeting_type` offering its planned
  sessions (fixed dates or group bookings turned off) while it still has
  upcoming ones: they would stay on the calendar and in people's diaries
  with nothing left to manage them from. The host cancels the dates first.
  """
  @spec check_sessions_kept(map(), Ecto.Changeset.t()) :: :ok | {:error, Ecto.Changeset.t()}
  def check_sessions_kept(meeting_type, changeset) do
    if sessions?(meeting_type) and not sessions?(apply_changes(changeset)) and
         PlannedSessions.upcoming(meeting_type) != [] do
      {:error,
       add_error(
         changeset,
         :fixed_dates,
         dgettext_noop("errors", "cancel the planned dates before turning fixed dates off")
       )}
    else
      :ok
    end
  end

  @doc """
  Refuses an update that would make a one-to-one type offering upcoming
  times a group type: its times would silently turn into nothing, since a
  group type with fixed dates offers sessions instead. The host removes the
  times first. Turning fixed dates off is allowed: the times are simply
  unused until it is turned on again.
  """
  @spec check_offered_times_kept(map(), Ecto.Changeset.t()) ::
          :ok | {:error, Ecto.Changeset.t()}
  def check_offered_times_kept(meeting_type, changeset) do
    updated = apply_changes(changeset)

    if offered_times?(meeting_type) and group?(updated) and
         OfferedTimes.upcoming(meeting_type) != [] do
      {:error,
       add_error(
         changeset,
         :max_participants,
         dgettext_noop("errors", "remove the offered times before turning group bookings on")
       )}
    else
      :ok
    end
  end

  defp group?(%{max_participants: max}) when is_integer(max) and max > 1, do: true
  defp group?(_meeting_type), do: false
end
