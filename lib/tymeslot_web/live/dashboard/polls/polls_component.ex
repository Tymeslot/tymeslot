defmodule TymeslotWeb.Dashboard.Polls.PollsComponent do
  @moduledoc """
  Dashboard component for meeting polls.

  Meeting polls let a host propose several candidate slots and invite guests to
  vote on the times that suit them, then confirm a booking from the winning slot.
  This module renders the Polls section shell — the header and the container that
  the poll list and creation flow are mounted into.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <%!-- Header --%>
      <.section_header
        icon="hero-hand-raised"
        title={dgettext("dashboard_common", "Polls")}
        class="mb-4"
      />

      <p class="text-tymeslot-600 mb-6">
        {dgettext(
          "dashboard_common",
          "Find a time that works for everyone. Propose a few slots and let your guests vote."
        )}
      </p>

      <%!-- Poll list and creation flow are mounted here in a later task. --%>
      <div id="polls-container" class="space-y-6"></div>
    </div>
    """
  end
end
