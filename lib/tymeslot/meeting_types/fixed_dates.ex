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
    Enum.reject(meeting_types, &(enabled?(&1) and not SessionSlots.any_open?(&1)))
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
end
