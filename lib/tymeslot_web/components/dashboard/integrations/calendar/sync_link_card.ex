defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkCard do
  @moduledoc """
  One configured link, collapsed to a line and expanded to its settings.

  Replaces two separate surfaces that between them made a link's configuration
  hard to find: a read-only "Active links" list, and a settings panel that
  opened elsewhere on the page when a small dot inside the grid was clicked.
  The dot was the whole problem — a 6px target, rendered only under cells that
  already had a link, that opened a form somewhere the eye was not. An
  organiser who never found it never discovered that a link had settings at
  all.

  A card is where a link is read *and* written, so there is one place to look
  and one place to act. The grid decides which pairs mirror; a card decides how
  one of them does, and is the only route to removing it.

  ## Why removal lives here and not in the grid

  The grid cycles a cell to `:paused`, which is reversible and destroys
  nothing. Removal withdraws every placeholder the link has written, and a
  withdrawn placeholder cannot be restored — the busy blocks are deliberately
  indistinguishable from ordinary events, so an organiser cannot even see what
  went. Keeping it off the grid means the destructive action is not one
  misclick away from the reversible one it sits beside.

  ## What the collapsed line says

  The pair, what the placeholder will actually read on the target, whether the
  link is live or paused, and how many differences were resolved without
  asking. That last count is the one an organiser needs before they need
  anything else: mirroring overwrites edits and withdraws placeholders on its
  own, and a resolution nobody sees is indistinguishable from a bug.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias TymeslotWeb.Dashboard.SyncLinks.ConflictLabels

  attr :link, :map, required: true
  attr :conflicts, :list, default: []
  attr :expanded?, :boolean, default: false
  attr :values, :map, default: %{}
  attr :error, :string, default: nil
  attr :tier_options, :list, required: true
  attr :calendar_options, :list, required: true
  attr :without_calendar_choice?, :boolean, required: true
  attr :target, :any, required: true

  @spec sync_link_card(map()) :: Phoenix.LiveView.Rendered.t()
  def sync_link_card(assigns) do
    ~H"""
    <li
      id={"sync-link-#{@link.id}"}
      class={[
        "overflow-hidden rounded-token-lg border",
        (@link.enabled && "border-tymeslot-200 bg-white") || "border-amber-200 bg-amber-50"
      ]}
    >
      <%!-- The whole line is the control. A chevron alone is a small target
            for something that has a full-width row available to it. --%>
      <button
        type="button"
        id={"sync-link-toggle-#{@link.id}"}
        phx-click="toggle_sync_link_card"
        phx-value-id={@link.id}
        phx-target={@target}
        aria-expanded={to_string(@expanded?)}
        aria-controls={"sync-link-body-#{@link.id}"}
        class="flex w-full flex-col items-start gap-2 p-3 text-left hover:bg-tymeslot-50 sm:flex-row sm:items-center sm:gap-3"
      >
        <span class="flex w-full items-start gap-3 sm:contents">
          <span class={[
            "mt-0.5 flex-none text-token-xs text-tymeslot-400 transition-transform sm:mt-0",
            @expanded? && "rotate-90"
          ]}>
            &#9654;
          </span>

          <%!-- Stacked below `sm:`, side by side above it. At 375px a pair on
              one line truncates both names and drops both accounts — which
              re-creates exactly the ambiguity `integration_qualifier/1` exists
              to remove, since two Google calendars carry the same name and
              differ only in the account that just got cut. --%>
          <span class="flex min-w-0 flex-1 flex-col gap-1 sm:flex-row sm:flex-wrap sm:items-center sm:gap-x-2">
            <.endpoint integration={@link.source_integration} />
            <span class="text-turquoise-600" aria-hidden="true">
              <span class="sm:hidden">&darr;</span>
              <span class="hidden sm:inline">&rarr;</span>
            </span>
            <span class="sr-only">{dgettext("dashboard_integrations", "mirrors onto")}</span>
            <.endpoint integration={@link.target_integration} />
          </span>
        </span>

        <%!-- Below `sm:` the tags take their own line rather than competing
              with the pair for width: sharing a row is what forced the account
              into an ellipsis, and the account is the half that disambiguates
              two calendars of the same provider. --%>
        <span class="flex flex-wrap items-center gap-1.5 pl-6 sm:flex-none sm:pl-0">
          <span class="rounded-token-full border border-tymeslot-200 bg-tymeslot-50 px-2 py-0.5 text-token-2xs font-semibold text-tymeslot-600">
            {privacy_tier_label(@link)}
          </span>
          <span
            :if={@link.enabled}
            class="rounded-token-full border border-turquoise-200 bg-turquoise-50 px-2 py-0.5 text-token-2xs font-semibold text-turquoise-700"
          >
            {dgettext("dashboard_integrations", "Live")}
          </span>
          <span
            :if={not @link.enabled}
            class="rounded-token-full border border-amber-300 bg-amber-50 px-2 py-0.5 text-token-2xs font-semibold text-amber-700"
          >
            {dgettext("dashboard_integrations", "Paused")}
          </span>
          <span
            :if={@conflicts != []}
            class="rounded-token-full border border-red-200 bg-red-50 px-2 py-0.5 text-token-2xs font-semibold text-red-700"
          >
            {dngettext(
              "dashboard_integrations",
              "%{count} resolved",
              "%{count} resolved",
              length(@conflicts)
            )}
          </span>
        </span>
      </button>

      <div
        :if={@expanded?}
        id={"sync-link-body-#{@link.id}"}
        class="border-t border-tymeslot-100 p-3 pl-9"
      >
        <p :if={@error} class="mb-3 text-token-sm font-semibold text-red-700" role="alert">
          {@error}
        </p>

        <.form
          for={%{}}
          id={"sync-link-settings-#{@link.id}"}
          phx-submit="save_sync_link_settings"
          phx-change="validate_sync_link_settings"
          phx-value-id={@link.id}
          phx-target={@target}
          class="space-y-3"
        >
          <%!-- The id travels in the form rather than in the component's
                assigns: with every card able to be open at once, a single
                "selected link" would be ambiguous about which one a submit
                belongs to. --%>
          <input type="hidden" name="sync_link[id]" value={@link.id} />

          <div class="grid gap-3 sm:grid-cols-2">
            <.input
              type="select"
              name="sync_link[privacy_tier]"
              id={"sync-link-tier-#{@link.id}"}
              label={dgettext("dashboard_integrations", "Show as")}
              value={settings_value(@values, @link, "privacy_tier")}
              options={@tier_options}
            />

            <%!-- Only asked for on the tier that shows one; the other two write
                  an opaque placeholder with no label to give. --%>
            <.input
              :if={settings_value(@values, @link, "privacy_tier") == "generic_label"}
              type="text"
              name="sync_link[generic_label]"
              id={"sync-link-label-#{@link.id}"}
              label={dgettext("dashboard_integrations", "Placeholder title")}
              value={settings_value(@values, @link, "generic_label")}
              placeholder={dgettext("dashboard_integrations", "Busy")}
            />

            <%!-- Hidden for a target without `:target_calendar_choice`: the
                  CalDAV family ignores a calendar id and always writes to the
                  primary path. --%>
            <.input
              :if={not @without_calendar_choice? and @calendar_options != []}
              type="select"
              name="sync_link[target_calendar_id]"
              id={"sync-link-calendar-#{@link.id}"}
              label={dgettext("dashboard_integrations", "Target calendar")}
              value={settings_value(@values, @link, "target_calendar_id")}
              options={@calendar_options}
              prompt={dgettext("dashboard_integrations", "Default calendar")}
            />

            <p :if={@without_calendar_choice?} class="self-end text-token-xs text-tymeslot-500">
              {dgettext(
                "dashboard_integrations",
                "This provider always writes to its primary calendar."
              )}
            </p>
          </div>

          <.conflict_log link={@link} conflicts={@conflicts} target={@target} />

          <div class="flex flex-wrap items-center justify-between gap-2 border-t border-tymeslot-100 pt-3">
            <button
              type="button"
              phx-click="delete_sync_link"
              phx-value-id={@link.id}
              phx-target={@target}
              data-confirm={
                dgettext(
                  "dashboard_integrations",
                  "Remove this link? The placeholders it wrote are withdrawn from %{target}, and that cannot be undone.",
                  target: DisplayHelpers.integration_label(@link.target_integration)
                )
              }
              class="rounded-token-md border border-red-200 px-3 py-1.5 text-token-xs font-semibold text-red-700 hover:bg-red-50"
            >
              {dgettext("dashboard_integrations", "Remove link")}
            </button>

            <div class="flex flex-wrap items-center gap-2">
              <button
                type="button"
                phx-click="toggle_sync_link"
                phx-value-id={@link.id}
                phx-target={@target}
                class="rounded-token-md border border-tymeslot-200 bg-white px-3 py-1.5 text-token-xs font-semibold text-tymeslot-700 hover:bg-tymeslot-50"
              >
                {(@link.enabled && dgettext("dashboard_integrations", "Pause")) ||
                  dgettext("dashboard_integrations", "Resume")}
              </button>
              <button
                type="submit"
                class="rounded-token-md bg-tymeslot-900 px-4 py-2 text-token-sm font-semibold text-white hover:bg-tymeslot-800"
              >
                {dgettext("dashboard_integrations", "Save changes")}
              </button>
            </div>
          </div>
        </.form>
      </div>
    </li>
    """
  end

  # Name over account, the same split the grid headers use, so one calendar
  # reads identically wherever it appears.
  attr :integration, :map, required: true

  defp endpoint(assigns) do
    ~H"""
    <span class="min-w-0">
      <span class="block truncate text-token-sm font-semibold text-tymeslot-900">
        {DisplayHelpers.integration_name(@integration)}
      </span>
      <span
        :if={DisplayHelpers.integration_qualifier(@integration)}
        class="block truncate font-mono text-token-2xs text-tymeslot-500"
      >
        {DisplayHelpers.integration_qualifier(@integration)}
      </span>
    </span>
    """
  end

  # Collapsed by default and behind a count, because a link that has resolved
  # many differences would otherwise bury its own settings under a list. The
  # count is the part that has to be visible; the detail is what you open when
  # the count surprises you.
  attr :link, :map, required: true
  attr :conflicts, :list, required: true
  attr :target, :any, required: true

  defp conflict_log(assigns) do
    ~H"""
    <details
      :if={@conflicts != []}
      id={"sync-link-conflicts-#{@link.id}"}
      class="overflow-hidden rounded-token-md border border-red-200 bg-red-50"
    >
      <summary class="cursor-pointer px-3 py-2 text-token-xs font-semibold text-red-700 hover:bg-red-100">
        {dngettext(
          "dashboard_integrations",
          "%{count} difference resolved automatically",
          "%{count} differences resolved automatically",
          length(@conflicts)
        )}
      </summary>

      <div class="bg-white px-3 py-2">
        <ul class="divide-y divide-tymeslot-100">
          <li :for={conflict <- @conflicts} class="py-2 text-token-xs text-tymeslot-600">
            <p class="font-semibold text-tymeslot-800">
              {ConflictLabels.conflict_kind_label(conflict.kind)}
            </p>
            <p>{ConflictLabels.conflict_resolution_label(conflict.resolution)}</p>
            <p class="break-all font-mono text-token-2xs text-tymeslot-400">
              {conflict.source_uid}
            </p>
          </li>
        </ul>

        <div class="flex flex-wrap gap-2 pt-2">
          <button
            type="button"
            phx-click="dismiss_sync_link_conflicts"
            phx-value-id={@link.id}
            phx-target={@target}
            class="rounded-token-md border border-tymeslot-200 bg-white px-3 py-1.5 text-token-xs font-semibold text-tymeslot-700 hover:bg-tymeslot-50"
          >
            {dgettext("dashboard_integrations", "Mark as seen")}
          </button>
          <button
            type="button"
            phx-click="show_sync_link_conflicts"
            phx-value-id={@link.id}
            phx-target={@target}
            class="rounded-token-md border border-tymeslot-200 bg-white px-3 py-1.5 text-token-xs font-semibold text-tymeslot-700 hover:bg-tymeslot-50"
          >
            {dgettext("dashboard_integrations", "Refresh")}
          </button>
        </div>
      </div>
    </details>
    """
  end

  # An in-flight edit wins over the stored value, so a tier just chosen keeps
  # the label field open across the change event. With nothing in flight the
  # card reads the link, which is what makes a save show the saved value back
  # rather than echoing the submission.
  defp settings_value(values, link, key) do
    case Map.get(values, key) do
      nil -> link |> Map.get(String.to_existing_atom(key)) |> to_string()
      submitted -> submitted
    end
  end

  # What the placeholder will actually say, not what tier was picked. The
  # generic-label row quotes the organiser's own words back at them, because
  # "Shown with a generic label" is a description of a setting rather than of
  # the block their colleagues will see.
  defp privacy_tier_label(%{privacy_tier: "generic_label", generic_label: label})
       when is_binary(label) and label != "" do
    dgettext("dashboard_integrations", "Shown as \"%{label}\"", label: label)
  end

  defp privacy_tier_label(%{privacy_tier: tier}), do: privacy_tier_label(tier)

  defp privacy_tier_label("busy_only"),
    do: dgettext("dashboard_integrations", "Shown as busy, with no detail")

  # A label-less row at that tier can only predate the input, and the honest
  # sentence is the one describing what the target calendar shows today.
  defp privacy_tier_label("generic_label"),
    do: dgettext("dashboard_integrations", "Shown as busy, until a placeholder title is set")

  defp privacy_tier_label("full_passthrough"),
    do: dgettext("dashboard_integrations", "Shown with the original title")

  defp privacy_tier_label(_tier), do: dgettext("dashboard_integrations", "Shown as busy")
end
