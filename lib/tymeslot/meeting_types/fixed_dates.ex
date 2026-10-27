defmodule Tymeslot.MeetingTypes.FixedDates do
  @moduledoc """
  Fixed dates: a group meeting type that offers the sessions its host
  planned, rather than the slots its availability schedule produces.

  A webinar, a training or a class that takes place on given dates fills
  each date up to the type's participant limit and is over once the last
  date has passed. The sessions themselves are the type's planned group
  meetings (`Tymeslot.Meetings.PlannedSessions`); this module holds the
  rules about the type.

  Only a group type can use fixed dates: a session is one meeting shared by
  everyone who signs up for it, which is what a group slot already is.
  """

  use Gettext, backend: TymeslotWeb.Gettext
  import Ecto.Changeset

  alias Tymeslot.Availability.SessionSlots
  alias Tymeslot.Meetings.PlannedSessions

  @doc "Whether `meeting_type` offers planned sessions instead of its schedule's slots."
  @spec enabled?(map() | nil) :: boolean()
  def enabled?(%{fixed_dates: true, max_participants: max}) when is_integer(max) and max > 1,
    do: true

  def enabled?(_meeting_type), do: false

  @doc """
  `meeting_types` without the fixed-date ones nobody can sign up for any
  more: their sessions have all passed, closed registration or filled up.
  Such a type is left off the public booking page, as an inactive one is;
  its direct link still says why it cannot be booked.
  """
  @spec reject_unbookable([map()]) :: [map()]
  def reject_unbookable(meeting_types) do
    open_ids = meeting_types |> Enum.filter(&enabled?/1) |> SessionSlots.open_type_ids()
    Enum.reject(meeting_types, &(enabled?(&1) and not MapSet.member?(open_ids, &1.id)))
  end

  @doc """
  Refuses fixed dates on a type that is not a group type. The message is a
  msgid of the `errors` domain on `:fixed_dates`, translated where the form
  shows it, like the schema's other rules.
  """
  @spec validate_changeset(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_changeset(changeset) do
    max = get_field(changeset, :max_participants)

    if get_field(changeset, :fixed_dates) == true and not (is_integer(max) and max > 1) do
      add_error(
        changeset,
        :fixed_dates,
        dgettext_noop("errors", "fixed dates need group bookings")
      )
    else
      changeset
    end
  end

  @doc """
  Refuses an update that would stop `meeting_type` offering fixed dates
  (fixed dates or group bookings turned off) while it still has upcoming
  planned dates: they would stay on the calendar and in people's diaries
  with nothing left to manage them from. The host cancels the dates first.
  """
  @spec check_sessions_kept(map(), Ecto.Changeset.t()) :: :ok | {:error, Ecto.Changeset.t()}
  def check_sessions_kept(meeting_type, changeset) do
    if enabled?(meeting_type) and not enabled?(apply_changes(changeset)) and
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
end
