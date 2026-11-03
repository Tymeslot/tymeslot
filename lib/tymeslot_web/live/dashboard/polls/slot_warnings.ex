defmodule TymeslotWeb.Dashboard.Polls.SlotWarnings do
  @moduledoc """
  The advisory warnings under the create form's candidate-time rows
  (`PollForm`): a time inside the host's time off, and a time that clashes
  with an event in their calendar. Neither stops a poll being saved;
  confirmation is where both are enforced.

  The rows are read as `ranges/3`, each keyed by its row, and both checks
  answer with the keys of the rows they flag.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Polls
  alias Tymeslot.Polls.SlotHealth
  alias TymeslotWeb.Components.CoreComponents.Icons
  alias TymeslotWeb.Dashboard.Polls.{CandidateTimes, LocalTime}

  @conflict_timeout 6_000

  @type range :: %{id: non_neg_integer(), start_time: DateTime.t(), end_time: DateTime.t()}

  @doc """
  The rows that name a time, read in `timezone`, as ranges `minutes` long.
  Empty without a usable length: the duration field shows its own error on
  save.
  """
  @spec ranges([CandidateTimes.row()], String.t(), integer() | nil) :: [range()]
  def ranges(rows, timezone, minutes) when is_integer(minutes) and minutes > 0 do
    for %{key: key, value: value} <- rows,
        start_time = LocalTime.to_utc(value, timezone),
        start_time != nil,
        do: %{
          id: key,
          start_time: start_time,
          end_time: DateTime.add(start_time, minutes, :minute)
        }
  end

  def ranges(_rows, _timezone, _minutes), do: []

  @doc "The keys of the `ranges` that fall within `user_id`'s time off."
  @spec time_off_keys(integer(), [range()]) :: MapSet.t()
  def time_off_keys(_user_id, []), do: MapSet.new()

  def time_off_keys(user_id, [first | _rest] = ranges) do
    minutes = DateTime.diff(first.end_time, first.start_time, :minute)
    clashing = Polls.starts_during_time_off(user_id, Enum.map(ranges, & &1.start_time), minutes)
    for range <- ranges, range.start_time in clashing, into: MapSet.new(), do: range.id
  end

  @doc """
  The keys of the `ranges` that clash with an event in `user_id`'s calendar.
  Fetches the calendar, so the form runs it off the LiveView process; a slow
  or failed fetch flags nothing (`SlotHealth.check_within/2`). `poll_id`, the
  draft's when there is one, only labels the log of a failed fetch.
  """
  @spec conflict_keys(integer(), Ecto.UUID.t() | nil, [range()]) :: MapSet.t()
  def conflict_keys(user_id, poll_id, ranges) do
    %{id: poll_id, user_id: user_id, time_slots: ranges}
    |> SlotHealth.check_within(@conflict_timeout)
    |> Enum.flat_map(fn
      {key, :conflict} -> [key]
      {_key, :ok} -> []
    end)
    |> MapSet.new()
  end

  attr :key, :integer, required: true
  attr :time_off?, :boolean, required: true
  attr :conflict?, :boolean, required: true

  @doc "The warnings under the row under `key`."
  @spec warnings(map()) :: Phoenix.LiveView.Rendered.t()
  def warnings(assigns) do
    ~H"""
    <p
      :if={@time_off?}
      data-testid="poll-slot-time-off-warning"
      data-slot-key={@key}
      class="flex items-center gap-1 text-token-xs text-amber-700"
    >
      <Icons.icon name="hero-exclamation-triangle-mini" class="w-4 h-4 shrink-0" />
      {dgettext(
        "dashboard_polls",
        "This time falls within your time off, so it can't be confirmed while that stays in place."
      )}
    </p>
    <p
      :if={@conflict?}
      data-testid="poll-slot-conflict-warning"
      data-slot-key={@key}
      class="flex items-center gap-1 text-token-xs text-amber-700"
    >
      <Icons.icon name="hero-calendar-mini" class="w-4 h-4 shrink-0" />
      {dgettext("dashboard_polls", "This time clashes with an event in your calendar.")}
    </p>
    """
  end
end
