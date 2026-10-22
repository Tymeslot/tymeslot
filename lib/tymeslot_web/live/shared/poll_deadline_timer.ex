defmodule TymeslotWeb.Live.Shared.PollDeadlineTimer do
  @moduledoc """
  Wakes a LiveView when voting closes on a poll it shows, so an open page
  turns to its closed state at the deadline rather than on the next reload.

  A view keeps one timer for the next deadline among the polls on screen
  (`Tymeslot.Polls.next_to_close/2`). It fires as
  `{:poll_deadline_reached, poll_id}` to the calling process, which for a
  LiveComponent is its parent LiveView. The receiver must not trust the
  message: the host may have moved the deadline since the timer was armed.
  It reloads the poll, derives whether voting is open from the reloaded
  poll, and calls `sync/3` again, which arms the timer for whatever deadline
  comes next.

  Calling `sync/3` after every reload is enough to follow a moved deadline:
  a timer already running for the same deadline is kept, and any other is
  cancelled and replaced. A delay longer than `@max_delay_ms` is capped; the
  early wake-up finds voting still open and arms the timer again.
  """

  alias Tymeslot.Polls

  # Far below `Process.send_after/3`'s ceiling of 2^32 - 1 ms (about 49 days).
  @max_delay_ms :timer.hours(24 * 7)

  @enforce_keys [:ref, :deadline]
  defstruct [:ref, :deadline]

  @type t :: %__MODULE__{ref: reference(), deadline: DateTime.t()}

  @doc """
  Arms, keeps or cancels `timer` so it fires at the next deadline among
  `polls` as of `now`. Returns the timer to keep, or nil when no poll has a
  deadline still ahead.
  """
  @spec sync(t() | nil, [Polls.PollSchema.t()], DateTime.t()) :: t() | nil
  def sync(timer, polls, now) do
    case Polls.next_to_close(polls, now) do
      nil -> cancel(timer)
      poll -> arm(timer, poll, now)
    end
  end

  @doc "Cancels `timer`, if any. Always returns nil, the state of no timer."
  @spec cancel(t() | nil) :: nil
  def cancel(nil), do: nil

  def cancel(%__MODULE__{ref: ref}) do
    Process.cancel_timer(ref)
    nil
  end

  @doc "The longest single wait before the timer re-arms."
  @spec max_delay_ms() :: pos_integer()
  def max_delay_ms, do: @max_delay_ms

  defp arm(timer, %{deadline_at: deadline} = poll, now) do
    if running_for?(timer, deadline) do
      timer
    else
      cancel(timer)
      delay = deadline |> DateTime.diff(now, :millisecond) |> max(0) |> min(@max_delay_ms)
      ref = Process.send_after(self(), {:poll_deadline_reached, poll.id}, delay)
      %__MODULE__{ref: ref, deadline: deadline}
    end
  end

  # `read_timer/1` is false once the timer has fired: the wake-up that
  # delivered a capped wait must arm a fresh one for the same deadline.
  defp running_for?(%__MODULE__{ref: ref, deadline: current}, deadline),
    do: DateTime.compare(current, deadline) == :eq and is_integer(Process.read_timer(ref))

  defp running_for?(nil, _deadline), do: false
end
