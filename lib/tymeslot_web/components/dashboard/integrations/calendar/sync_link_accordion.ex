defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkAccordion do
  @moduledoc """
  The link grid for a phone: one expandable section per source calendar, each
  target a row with its own three-state control.

  ## Why a matrix becomes a list

  A grid needs two axes on screen at once, and a phone has room for one. With a
  150px row header and 132px columns, a 375px viewport shows a single column at
  a time — the organiser scrolls sideways past one cell, and the row header
  that says which calendar they are configuring scrolls away with it. A matrix
  you can only ever see one cell of is not a matrix; it is a very awkward list.

  So below `sm:` it is an honest list. The section header is the source, the
  rows are the targets, and the direction the grid encodes in its axes is
  stated in words instead. Same pairs, same three states, same staging.

  ## Why the control is segmented rather than cycling

  The grid's cell cycles: click for mirroring, again for paused, again for
  gone. That works with a pointer, where the next click is free and a tooltip
  says what it will do. On a touch screen it is three deliberate taps to reach
  a state, no hover to explain them, and a mis-tap is a state change rather
  than nothing.

  Three segments make every state one tap and show which is selected without a
  legend. `aria-pressed` carries that to a screen reader, which the grid's
  cycling button could only approximate.

  ## What it shares with the grid, and why that matters

  Everything except the markup. Both layouts read `SyncLinkMatrix.stored_cells/1`
  and `changed_pairs/2`, list `grid_calendars/1`, refuse `blocked?/1` targets,
  and send the same `cycle_sync_cell` event into the same `SyncLinkStaging`
  model. Only the rendering differs.

  That is deliberate: two layouts with two models would drift, and the drift
  would surface as an organiser rotating their phone and seeing a different
  answer about which calendars are mirroring. The one thing that is *not*
  shared is the cycle — the accordion sends the state its segment names rather
  than "the next one" — which the handler already supports, because it honours
  the state the browser asks for instead of recomputing it.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkMatrix

  attr :integrations, :list, required: true
  attr :links, :list, required: true
  attr :staged_cells, :map, default: %{}
  attr :expanded_sources, :any, required: true
  attr :target, :any, required: true

  @spec sync_link_accordion(map()) :: Phoenix.LiveView.Rendered.t()
  def sync_link_accordion(assigns) do
    calendars = SyncLinkMatrix.grid_calendars(assigns.integrations)
    stored = SyncLinkMatrix.stored_cells(assigns.links)

    assigns =
      assigns
      |> assign(:calendars, calendars)
      |> assign(:effective_cells, Map.merge(stored, assigns.staged_cells))
      |> assign(:changed_pairs, SyncLinkMatrix.changed_pairs(stored, assigns.staged_cells))

    ~H"""
    <div :if={length(@calendars) >= 2} class="space-y-2">
      <section
        :for={source <- @calendars}
        id={"sync-source-#{source.id}"}
        class="overflow-hidden rounded-token-lg border border-tymeslot-200 bg-white"
      >
        <%!-- The whole row is the control. A chevron alone is a small target
              for something with a full-width row available to it. --%>
        <button
          type="button"
          id={"sync-source-toggle-#{source.id}"}
          phx-click="toggle_sync_source"
          phx-value-id={source.id}
          phx-target={@target}
          aria-expanded={to_string(expanded?(@expanded_sources, source))}
          aria-controls={"sync-source-targets-#{source.id}"}
          class="flex w-full items-center gap-2 p-3 text-left hover:bg-tymeslot-50"
        >
          <span class={[
            "w-3 flex-none text-token-xs text-tymeslot-400 transition-transform",
            expanded?(@expanded_sources, source) && "rotate-90"
          ]}>
            &#9654;
          </span>

          <span class="min-w-0 flex-1">
            <span class="block truncate text-token-sm font-semibold text-tymeslot-900">
              {DisplayHelpers.integration_name(source)}
            </span>
            <span
              :if={DisplayHelpers.integration_qualifier(source)}
              class="block truncate font-mono text-token-2xs text-tymeslot-500"
            >
              {DisplayHelpers.integration_qualifier(source)}
            </span>
          </span>

          <.tally
            mirroring={count_state(@calendars, @effective_cells, source, :active)}
            paused={count_state(@calendars, @effective_cells, source, :paused)}
          />
        </button>

        <div
          :if={expanded?(@expanded_sources, source)}
          id={"sync-source-targets-#{source.id}"}
          class="border-t border-tymeslot-100 px-3 pb-3"
        >
          <.target_row
            :for={target <- other_calendars(@calendars, source)}
            source={source}
            target={target}
            state={Map.get(@effective_cells, {source.id, target.id})}
            changed?={MapSet.member?(@changed_pairs, {source.id, target.id})}
            target_component={@target}
          />
        </div>
      </section>
    </div>
    """
  end

  # What this calendar is doing right now, counted over the *effective* state
  # so a staged change is reflected before it is saved. Both halves are named
  # rather than collapsed into one number: "1 mirroring" and "1 paused" are
  # different answers to "is this calendar sending anything", and a single
  # count would report a paused link as active work.
  attr :mirroring, :integer, required: true
  attr :paused, :integer, required: true

  defp tally(assigns) do
    ~H"""
    <span class={[
      "flex-none rounded-token-full border px-2 py-0.5 text-token-2xs font-semibold",
      (@mirroring > 0 && "border-turquoise-200 bg-turquoise-50 text-turquoise-700") ||
        ((@paused > 0 && "border-amber-300 bg-amber-50 text-amber-700") ||
           "border-tymeslot-200 bg-tymeslot-50 text-tymeslot-500")
    ]}>
      {tally_label(@mirroring, @paused)}
    </span>
    """
  end

  attr :source, :map, required: true
  attr :target, :map, required: true
  attr :state, :atom, default: nil
  attr :changed?, :boolean, default: false
  attr :target_component, :any, required: true

  defp target_row(assigns) do
    assigns = assign(assigns, :blocked?, SyncLinkMatrix.blocked?(assigns.target))

    ~H"""
    <div class="border-b border-tymeslot-100 py-3 last:border-b-0">
      <div class="mb-2 min-w-0">
        <span class="block truncate text-token-sm font-semibold text-tymeslot-800">
          {DisplayHelpers.integration_name(@target)}
        </span>
        <span
          :if={DisplayHelpers.integration_qualifier(@target)}
          class="block truncate font-mono text-token-2xs text-tymeslot-500"
        >
          {DisplayHelpers.integration_qualifier(@target)}
        </span>
      </div>

      <%!-- A subscription can send but never receive, so the row says so
            instead of offering three segments that would all be refused. --%>
      <p
        :if={@blocked?}
        class="rounded-token-md border border-dashed border-tymeslot-200 bg-tymeslot-50 p-2 text-center text-token-xs text-tymeslot-500"
      >
        {dgettext(
          "dashboard_integrations",
          "Read-only — this calendar can send, but cannot receive."
        )}
      </p>

      <div
        :if={not @blocked?}
        role="group"
        aria-label={
          dgettext("dashboard_integrations", "Mirror %{source} onto %{target}",
            source: DisplayHelpers.integration_label(@source),
            target: DisplayHelpers.integration_label(@target)
          )
        }
        class={[
          "grid grid-cols-3 overflow-hidden rounded-token-md border-2 border-tymeslot-200 bg-tymeslot-50",
          @changed? && "ring-2 ring-turquoise-400"
        ]}
      >
        <.segment
          :for={choice <- segments()}
          source={@source}
          target={@target}
          choice={choice}
          selected?={effective_state(@state) == choice.state}
          target_component={@target_component}
        />
      </div>
    </div>
    """
  end

  # One segment. `min-h-11` is 44px, the smallest target a thumb hits reliably;
  # the grid's cells are 36px, which is fine for a pointer and not for a hand.
  attr :source, :map, required: true
  attr :target, :map, required: true
  attr :choice, :map, required: true
  attr :selected?, :boolean, required: true
  attr :target_component, :any, required: true

  defp segment(assigns) do
    ~H"""
    <button
      type="button"
      id={"sync-seg-#{@source.id}-#{@target.id}-#{@choice.state}"}
      phx-click="cycle_sync_cell"
      phx-value-source={@source.id}
      phx-value-target={@target.id}
      phx-value-state={@choice.state}
      phx-target={@target_component}
      aria-pressed={to_string(@selected?)}
      class={[
        "min-h-11 border-r border-tymeslot-200 px-1 py-2 text-token-xs font-semibold last:border-r-0",
        (@selected? && @choice.selected_class) || "text-tymeslot-500 hover:bg-white"
      ]}
    >
      {@choice.label}
    </button>
    """
  end

  # The three states a pair can be in, in the order the grid cycles them, so an
  # organiser who has used both layouts meets them in the same order.
  defp segments do
    [
      %{
        state: "off",
        label: dgettext("dashboard_integrations", "Off"),
        selected_class: "bg-tymeslot-500 text-white"
      },
      %{
        state: "active",
        label: dgettext("dashboard_integrations", "Mirror"),
        selected_class: "bg-turquoise-600 text-white"
      },
      %{
        state: "paused",
        label: dgettext("dashboard_integrations", "Pause"),
        selected_class: "bg-amber-500 text-white"
      }
    ]
  end

  # A pair with no link is `nil` in the cell map and `"off"` on a segment: the
  # absence of a link and the choice to have none are the same state, named
  # differently by the two sides.
  defp effective_state(nil), do: "off"
  defp effective_state(state), do: to_string(state)

  defp other_calendars(calendars, source), do: Enum.reject(calendars, &(&1.id == source.id))

  defp count_state(calendars, cells, source, wanted) do
    calendars
    |> other_calendars(source)
    |> Enum.count(&(Map.get(cells, {source.id, &1.id}) == wanted))
  end

  defp expanded?(expanded, source), do: MapSet.member?(expanded, source.id)

  # Both counts, or whichever is non-zero, or "none". Spelled out rather than
  # rendered as bare numbers because the header is the only thing an organiser
  # reads before deciding whether to open a section.
  defp tally_label(0, 0), do: dgettext("dashboard_integrations", "None")

  defp tally_label(mirroring, 0),
    do:
      dngettext(
        "dashboard_integrations",
        "%{count} mirroring",
        "%{count} mirroring",
        mirroring
      )

  defp tally_label(0, paused),
    do: dngettext("dashboard_integrations", "%{count} paused", "%{count} paused", paused)

  defp tally_label(mirroring, paused) do
    dgettext("dashboard_integrations", "%{mirroring} mirroring · %{paused} paused",
      mirroring: mirroring,
      paused: paused
    )
  end
end
