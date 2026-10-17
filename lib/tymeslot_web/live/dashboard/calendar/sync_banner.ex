defmodule TymeslotWeb.Dashboard.Calendar.SyncBanner do
  @moduledoc """
  The banner above the calendar grid naming each account with a sync
  problem (`Tymeslot.CalendarGrid.SyncProblems`) and what it means for the
  organiser: events that may be out of date, or changes saved here and
  waiting to be sent. Retry asks for a sync; an account that needs signing
  in again links to its connection instead. Always rendered, so the grid
  below never jumps when a problem appears.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :problems, :list, required: true
  attr :syncing_ids, :any, required: true
  attr :target, :any, required: true

  @spec sync_banner(map()) :: Phoenix.LiveView.Rendered.t()
  def sync_banner(assigns) do
    ~H"""
    <div id="calendar-sync-banner" class="shrink-0" role="status" aria-live="polite">
      <div
        :for={problem <- @problems}
        id={"calendar-sync-problem-#{problem.integration_id}"}
        class="flex items-center gap-3 border-b border-amber-200 bg-amber-50 px-3 py-2 text-token-sm text-amber-900 md:px-4"
      >
        <.icon name="hero-exclamation-triangle-mini" class="h-4 w-4 shrink-0 text-amber-600" />
        <span class="min-w-0 flex-1">{message(problem)}</span>
        <.link
          :if={problem.kind == :reauth}
          navigate={~p"/dashboard/integrations?tab=calendars"}
          class="shrink-0 font-semibold underline underline-offset-2 hover:text-amber-700"
        >
          {dgettext("dashboard_calendar", "Reconnect")}
        </.link>
        <.action_button
          :if={problem.kind != :reauth}
          id={"calendar-sync-retry-#{problem.integration_id}"}
          variant={:secondary}
          size={:sm}
          icon="hero-arrow-path"
          disabled={MapSet.member?(@syncing_ids, problem.integration_id)}
          phx-click="calendar:sync_account"
          phx-value-integration-id={problem.integration_id}
          phx-target={@target}
        >
          {dgettext("dashboard_calendar", "Retry")}
        </.action_button>
      </div>
    </div>
    """
  end

  defp message(%{kind: :reauth, account: account}),
    do:
      dgettext(
        "dashboard_calendar",
        "%{account} needs you to sign in again. Until you do, its events may be out of date.",
        account: account
      )

  defp message(%{kind: :unreachable, account: account, pending: []}),
    do:
      dgettext(
        "dashboard_calendar",
        "%{account} isn't responding. Its events may be out of date.",
        account: account
      )

  defp message(%{kind: :unreachable, account: account, pending: [title]}),
    do:
      dgettext(
        "dashboard_calendar",
        "%{account} isn't responding. Your change to “%{title}” is saved here and will be sent automatically.",
        account: account,
        title: title
      )

  defp message(%{kind: :unreachable, account: account, pending: titles}),
    do:
      dngettext(
        "dashboard_calendar",
        "%{account} isn't responding. %{count} change is saved here and will be sent automatically.",
        "%{account} isn't responding. %{count} changes are saved here and will be sent automatically.",
        length(titles),
        account: account
      )

  defp message(%{kind: :waiting, account: account, pending: [title]}),
    do:
      dgettext(
        "dashboard_calendar",
        "Your change to “%{title}” is saved here and will be sent to %{account} automatically.",
        account: account,
        title: title
      )

  defp message(%{kind: :waiting, account: account, pending: titles}),
    do:
      dngettext(
        "dashboard_calendar",
        "%{count} change is saved here and will be sent to %{account} automatically.",
        "%{count} changes are saved here and will be sent to %{account} automatically.",
        length(titles),
        account: account
      )
end
