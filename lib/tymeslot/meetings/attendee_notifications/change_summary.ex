defmodule Tymeslot.Meetings.AttendeeNotifications.ChangeSummary do
  @moduledoc "Immutable description of an attendee-notifiable change."

  @type field :: :title | :starts_at | :ends_at | :location | :description | :video_link
  @type attendee :: %{email: String.t(), name: String.t() | nil}

  @type t :: %__MODULE__{
          changed_fields: [field],
          added_attendees: [attendee],
          removed_attendees: [attendee],
          retained_attendees: [attendee],
          next_sequence: non_neg_integer
        }

  defstruct changed_fields: [],
            added_attendees: [],
            removed_attendees: [],
            retained_attendees: [],
            next_sequence: 0

  @spec new(map) :: t
  def new(attrs) when is_map(attrs) do
    struct(__MODULE__, attrs)
  end

  @spec any_changes?(t) :: boolean
  def any_changes?(%__MODULE__{changed_fields: [], added_attendees: [], removed_attendees: []}),
    do: false

  def any_changes?(%__MODULE__{}), do: true
end
