defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkConflictSummary do
  @moduledoc """
  The whole-account count of resolutions the organiser has not yet seen.

  Sits above the grid rather than inside a card, because a resolution nobody
  opens a card to find is a resolution nobody sees. Mirroring settles
  divergences without asking — a placeholder edited on the target is
  overwritten, a source deleted takes its placeholder with it — and both
  destroy work that the organiser did. The count is how they learn it happened
  at all; the per-link detail is what they open once the count surprises them.

  Rendered only when something is unseen. A strip permanently reading "0
  differences" is a strip that stops being read, which defeats the one job it
  has.

  Extracted from `SyncLinksSettingsComponent` because that module reached the
  650-line budget the analyser enforces, and this is the piece with the
  cleanest seam: it needs the counts and the acting component's target, and
  knows nothing about staging, settings or the write path.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :total, :integer, required: true
  attr :link_count, :integer, required: true
  attr :target, :any, required: true

  @spec sync_link_conflict_summary(map()) :: Phoenix.LiveView.Rendered.t()
  def sync_link_conflict_summary(assigns) do
    ~H"""
    <section
      :if={@total > 0}
      id="sync-link-conflict-summary"
      class="flex flex-wrap items-center justify-between gap-3 rounded-token-lg border border-red-200 bg-red-50 px-4 py-3"
    >
      <p class="text-token-sm font-semibold text-red-700">
        {dngettext(
          "dashboard_integrations",
          "%{count} difference resolved automatically",
          "%{count} differences resolved automatically",
          @total
        )}
        <span class="font-normal text-tymeslot-600">
          {dngettext(
            "dashboard_integrations",
            "across %{count} link",
            "across %{count} links",
            @link_count
          )}
        </span>
      </p>

      <button
        type="button"
        phx-click="dismiss_all_sync_link_conflicts"
        phx-target={@target}
        class="rounded-token-md border border-tymeslot-200 bg-white px-3 py-1.5 text-token-xs font-semibold text-tymeslot-700 hover:bg-tymeslot-50"
      >
        {dgettext("dashboard_integrations", "Mark all as seen")}
      </button>
    </section>
    """
  end
end
