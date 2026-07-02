defmodule Tymeslot.Agenda.Entry do
  @moduledoc """
  A single appointment on the dashboard agenda.

  Source-agnostic by design: a Tymeslot booking (`source: :tymeslot`) and a
  synced external calendar event (`source: :external`) are normalised into the
  same shape so the presentation layer renders one card for both.

  `start_at`/`end_at` are `DateTime`s. Timed entries carry them in UTC; all-day
  entries carry the local-timezone midnight boundaries of their date, which keeps
  them sorting ahead of that day's timed entries. `day` is the entry's local
  (user-timezone) date, precomputed so grouping never has to reconvert.
  """

  alias Tymeslot.Utils.DateTimeUtils

  @enforce_keys [:id, :source, :title, :day, :start_at, :end_at, :all_day?]
  defstruct [
    :id,
    :source,
    :title,
    :day,
    :start_at,
    :end_at,
    :all_day?,
    :location,
    :join_url,
    :who,
    :calendar,
    :colour,
    :target
  ]

  @type source :: :tymeslot | :external

  @typedoc """
  The stable override target for this entry: a booking (`{:meeting, uuid}`) or an
  external event (`{:external, integration_id, uid}`). Used to set/clear a colour.
  """
  @type target :: {:meeting, Ecto.UUID.t()} | {:external, integer(), String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          source: source(),
          title: String.t(),
          day: Date.t(),
          start_at: DateTime.t(),
          end_at: DateTime.t(),
          all_day?: boolean(),
          location: String.t() | nil,
          join_url: String.t() | nil,
          who: String.t() | nil,
          calendar: String.t() | nil,
          colour: String.t() | nil,
          target: target() | nil
        }

  @doc """
  Whether the entry occupies `date` (in `tz`) — by *overlap*, not just its start.

  `day` is the entry's first local date; the last is derived from `end_at`. A
  timed entry occupies every local date it spans (so an overnight meeting still
  in progress counts as today's), and an all-day entry occupies `[start, end)`
  since its `end_at` is the exclusive local midnight after the final day.

  This is what keeps a multi-day all-day block (a week of leave) and a
  cross-midnight meeting on the day the user is actually looking at, rather than
  only on the day they happened to start.
  """
  @spec covers?(t(), Date.t(), String.t()) :: boolean()
  def covers?(%__MODULE__{} = entry, %Date{} = date, tz) do
    not Date.after?(entry.day, date) and not Date.after?(date, last_date(entry, tz))
  end

  defp last_date(%__MODULE__{all_day?: true} = entry, tz),
    do: entry |> local_end_date(tz) |> Date.add(-1)

  defp last_date(%__MODULE__{} = entry, tz), do: local_end_date(entry, tz)

  defp local_end_date(%__MODULE__{end_at: end_at}, tz),
    do: end_at |> DateTimeUtils.convert_to_timezone(tz) |> DateTime.to_date()
end
