defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkSettingsPanel do
  @moduledoc """
  The settings for whichever link the organiser selected out of the grid.

  A link carries five things the grid cannot express — how much a placeholder
  discloses, the label it carries when that tier is chosen, which calendar on
  the target it lands on, and whether it is paused. The grid answers *which*
  pairs mirror; this answers *how* one of them does.

  It replaced a standalone "add a link" form. That form created links the grid
  now creates, while saying less about what already existed, so keeping both
  invited the organiser to use the worse of the two. What it uniquely offered
  is here instead, attached to a link rather than floating free.

  Rendering only with a link selected is the point: settings with nothing to
  apply to would be a form that cannot be submitted. The parent owns the
  selection, the rate limit and the write; this module only draws.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.DisplayHelpers

  attr :link, :any, default: nil
  attr :values, :map, required: true
  attr :error, :string, default: nil
  attr :tier_options, :list, required: true
  attr :calendar_options, :list, required: true
  attr :without_calendar_choice?, :boolean, required: true
  attr :target, :any, required: true

  @spec sync_link_settings(map()) :: Phoenix.LiveView.Rendered.t()
  def sync_link_settings(assigns) do
    ~H"""
    <%!-- The settings for whichever link the organiser picked out of the
              grid. There is no "add a link" form any more: the grid creates
              links, and a second form that did the same thing while saying less
              about what already exists invited the organiser to use the worse of
              the two. What the form uniquely offered — the per-link settings —
              lives here instead, attached to a link rather than floating free. --%>
    <section
      :if={@link}
      id="sync-link-settings"
      class="space-y-4 rounded-token-lg border border-tymeslot-300 bg-tymeslot-50 p-4"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h2 class="text-token-lg font-bold text-tymeslot-900">
            {dgettext("dashboard_integrations", "%{source} to %{target}",
              source: DisplayHelpers.integration_label(@link.source_integration),
              target: DisplayHelpers.integration_label(@link.target_integration)
            )}
          </h2>
          <p class="text-token-xs text-tymeslot-500">
            {dgettext("dashboard_integrations", "Settings for this link")}
          </p>
        </div>

        <button
          type="button"
          phx-click="deselect_sync_cell"
          phx-target={@target}
          class="rounded-token-md border border-tymeslot-200 bg-white px-3 py-1.5 text-token-xs font-semibold text-tymeslot-700 hover:bg-tymeslot-50"
        >
          {dgettext("dashboard_integrations", "Close")}
        </button>
      </div>

      <p :if={@error} class="text-token-sm font-semibold text-red-700">
        {@error}
      </p>

      <.form
        for={%{}}
        id="sync-link-settings-form"
        phx-submit="save_sync_link_settings"
        phx-change="validate_sync_link_settings"
        phx-target={@target}
        class="grid gap-4 sm:grid-cols-2"
      >
        <.input
          type="select"
          name="sync_link[privacy_tier]"
          id="sync-link-settings-tier"
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
          id="sync-link-settings-label"
          label={dgettext("dashboard_integrations", "Label")}
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
          id="sync-link-settings-calendar"
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

        <div class="sm:col-span-2 flex flex-wrap items-center justify-end gap-2">
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
            {dgettext("dashboard_integrations", "Save settings")}
          </button>
        </div>
      </.form>
    </section>
    """
  end

  # An in-flight edit wins over the stored value, so a tier just chosen keeps
  # the label field open across the change event. With nothing in flight the
  # panel reads the link, which is what makes a save show the saved value back
  # rather than echoing the submission.
  defp settings_value(values, link, key) do
    case Map.get(values, key) do
      nil -> link |> Map.get(String.to_existing_atom(key)) |> to_string()
      submitted -> submitted
    end
  end
end
