defmodule Tymeslot.Integrations.Calendar.RemovedCalendar do
  @moduledoc """
  A calendar Tymeslot stopped using because the calendar server no longer
  has it, kept on its integration (`removed_calendars`) until the owner
  dismisses the notice. See `Tymeslot.Integrations.Calendar.RemovedCalendars`.

  `id` is the calendar's path, or its provider id when it has none, so a
  calendar removed again before the notice is dismissed replaces its entry
  rather than being listed twice.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          removed_at: DateTime.t()
        }

  @primary_key false
  embedded_schema do
    field :id, :string
    field :name, :string
    field :removed_at, :utc_datetime
  end
end
