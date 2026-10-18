defmodule TymeslotWeb.Dashboard.Calendar.PanelStatus do
  @moduledoc """
  The side panel's header line, which says what happened to the changes
  made in it: `:idle` before any, `:saving` while a write runs, `:saved`,
  `{:waiting, account}` when a change is saved here but the calendar could
  not be reached, `:read_only`, and `{:failed, reason}`.

  The panel keeps the references of its own writes (`writes`), so an answer
  to another event's write leaves the line alone.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @type t ::
          :idle
          | :saving
          | :saved
          | {:waiting, String.t()}
          | :read_only
          | {:failed, String.t()}

  @doc "The panel once it has started the write `ref`."
  @spec started(map(), term()) :: map()
  def started(panel, ref), do: %{panel | writes: [ref | panel.writes], status: :saving}

  @doc """
  The panel once the write `ref` answered `outcome`
  (`Tymeslot.CalendarGrid.WriteQueue.outcome/0`); `account` names the
  calendar account a queued write waits for. A write the panel did not
  start changes nothing.
  """
  @spec settled(map(), term(), term(), String.t()) :: map()
  def settled(%{writes: writes} = panel, ref, outcome, account) do
    if ref in writes do
      left = List.delete(writes, ref)
      %{panel | writes: left, status: after_write(outcome, left, account)}
    else
      panel
    end
  end

  @doc "The panel after a change was refused before anything was written."
  @spec refused(map(), String.t()) :: map()
  def refused(panel, reason), do: %{panel | status: {:failed, reason}}

  @doc "The words for `status`."
  @spec text(t()) :: String.t()
  def text(:idle), do: dgettext("dashboard_calendar_editing", "Changes save automatically")
  def text(:saving), do: dgettext("dashboard_calendar_editing", "Saving…")
  def text(:saved), do: dgettext("dashboard_calendar_editing", "Saved")

  def text({:waiting, account}),
    do:
      dgettext("dashboard_calendar_editing", "Saved here, waiting to reach %{account}",
        account: account
      )

  def text(:read_only), do: dgettext("dashboard_calendar_editing", "Read only")

  def text({:failed, reason}),
    do: dgettext("dashboard_calendar_editing", "Couldn't save. %{reason}", reason: reason)

  defp after_write(:failed, _left, _account),
    do: {:failed, dgettext("dashboard_calendar_editing", "The change was put back.")}

  defp after_write(:queued, _left, account), do: {:waiting, account}
  defp after_write(_answered, [], _account), do: :saved
  defp after_write(_answered, _left, _account), do: :saving
end
