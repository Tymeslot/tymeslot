defmodule TymeslotWeb.Dashboard.Availability.ScheduleSwitcher do
  @moduledoc """
  Schedule picker and management actions for the availability page.

  A profile owns several named schedules, exactly one of which is the default.
  This switcher chooses which one the page below it is editing and exposes the
  actions that change the set itself: create, rename, duplicate, promote to
  default, and delete.

  Two things drive the layout. The tabs must outweigh everything around them,
  because every schedule renders the same weekly grid below and the strip is the
  only thing saying which one is being edited; so the actions that merely
  *manage* a schedule sit in a menu rather than competing as five buttons. And a
  schedule only means anything once a meeting type is booked against it, which
  is decided on a different page entirely, so the strip states which meeting
  types use the selected schedule rather than leaving that link invisible.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Dashboard.Availability.ScheduleAccents

  @doc """
  Renders the schedule tabs above the surface that edits the selected schedule.

  Tabs and content share one bordered box, with the strip as its top edge, so
  the weekly hours and policy inside it read as belonging to the active tab
  rather than to the account as a whole.
  """
  attr :schedules, :list, required: true
  attr :selected_schedule, :map, default: nil
  attr :meeting_type_names, :list, required: true
  attr :max_schedules, :integer, required: true
  attr :menu_open, :boolean, default: false
  attr :myself, :any, required: true
  slot :inner_block, required: true

  @spec schedule_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def schedule_panel(assigns) do
    assigns =
      assigns
      |> assign(:can_create, length(assigns.schedules) < assigns.max_schedules)
      |> assign(
        :accent,
        ScheduleAccents.for_schedule(assigns.schedules, assigns.selected_schedule)
      )

    ~H"""
    <%!-- The panel wears the selected schedule's own colour, and the day rows
    inside stay white, so the frame reads as "everything in here belongs to this
    schedule" rather than as decoration. --%>
    <div class={[
      "border-2 rounded-token-2xl shadow-xl overflow-hidden transition-colors duration-300",
      @accent.panel
    ]}>
      <.tab_bar
        variant={:attached}
        class={@accent.bar}
        active_tab={active_tab(@selected_schedule)}
        target={@myself}
        event="switch_tab"
        tabs={schedule_tabs(@schedules)}
      >
        <:trailing>
          <%!-- Kept in place once the cap is reached rather than removed: a
          button that greys out says there is a ceiling and what it is, whereas
          one that disappears just looks like a feature that went missing. --%>
          <button
            type="button"
            disabled={not @can_create}
            phx-click={@can_create && "show_schedule_form"}
            phx-value-mode="create"
            phx-target={@myself}
            title={limit_hint(@can_create, @max_schedules)}
            class={[
              "flex items-center gap-2 px-4 py-3 rounded-token-xl font-bold text-token-sm border-2 border-dashed transition-all duration-300",
              if(@can_create,
                do: "text-tymeslot-600 border-tymeslot-300 hover:border-tymeslot-400 hover:bg-white",
                else: "text-tymeslot-400 border-tymeslot-200 cursor-not-allowed"
              )
            ]}
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            <span>{dgettext("dashboard_availability", "New schedule")}</span>
          </button>
        </:trailing>

        <%!-- The menu acts on the schedule whose tab it sits in, so it rides
        inside that tab rather than standing off in the corner, where it read as
        a control over the whole page. --%>
        <:tab_action>
          <.dropdown
            :if={@selected_schedule}
            id="schedule-actions-dropdown"
            open={@menu_open}
            on_toggle="toggle_schedule_menu"
            on_close="close_schedule_menu"
            target={@myself}
            trigger_class="flex items-center justify-center w-8 h-8 rounded-token-lg text-white/80 hover:bg-white/20 hover:text-white transition-all duration-300 focus:outline-hidden focus:ring-2 focus:ring-white/60"
            class="bg-white border-2 border-tymeslot-100 rounded-token-xl shadow-lg py-1 w-56"
            aria-label={dgettext("dashboard_availability", "Manage this schedule")}
          >
            <:trigger>
              <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
            </:trigger>
            <:panel>
              <.dropdown_item
                label={dgettext("dashboard_availability", "Rename")}
                icon="hero-pencil-square"
                phx-click="show_schedule_form"
                phx-value-mode="rename"
                phx-target={@myself}
              />
              <.dropdown_item
                :if={@can_create}
                label={dgettext("dashboard_availability", "Duplicate")}
                icon="hero-document-duplicate"
                phx-click="duplicate_schedule"
                phx-target={@myself}
              />
              <.dropdown_item
                :if={not @selected_schedule.is_default}
                label={dgettext("dashboard_availability", "Make default")}
                icon="hero-star"
                phx-click="set_default_schedule"
                phx-target={@myself}
              />
              <.dropdown_divider :if={not @selected_schedule.is_default} />
              <.dropdown_item
                :if={not @selected_schedule.is_default}
                label={dgettext("dashboard_availability", "Delete")}
                icon="hero-trash"
                danger
                phx-click="show_delete_schedule_modal"
                phx-target={@myself}
              />
            </:panel>
          </.dropdown>
        </:tab_action>
      </.tab_bar>

      <div class="p-6 sm:p-8 space-y-8">
        <p class="text-token-sm text-tymeslot-500 font-medium">
          {usage_summary(@selected_schedule, @meeting_type_names)}
        </p>

        <%!-- Spelled out as well as shown on the disabled button, because a
        title only surfaces on hover and never on a touch screen. --%>
        <p :if={not @can_create} class="-mt-6 text-token-sm text-tymeslot-400 font-medium">
          {limit_message(@max_schedules)}
        </p>

        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp limit_hint(true, _max), do: nil
  defp limit_hint(false, max), do: limit_message(max)

  defp limit_message(max) do
    dgettext(
      "dashboard_availability",
      "You have reached the limit of %{count} schedules. Delete one to add another.",
      count: max
    )
  end

  defp schedule_tabs(schedules) do
    schedules
    |> Enum.with_index()
    |> Enum.map(fn {schedule, index} ->
      accent = ScheduleAccents.at(index)

      %{
        id: to_string(schedule.id),
        label: tab_label(schedule),
        accent: accent.tab,
        dot: accent.dot
      }
    end)
  end

  # The active tab is matched by string id, so a page with no schedule at all
  # simply has no tab selected rather than crashing on a nil lookup.
  defp active_tab(nil), do: nil
  defp active_tab(schedule), do: to_string(schedule.id)

  defp tab_label(%{is_default: true, name: name}),
    do: dgettext("dashboard_availability", "%{name} (default)", name: name)

  defp tab_label(%{name: name}), do: name

  # Spelling out where a schedule takes effect, because that is decided on the
  # meeting type and is otherwise invisible from this page.
  defp usage_summary(nil, _names), do: nil

  defp usage_summary(%{is_default: true}, []) do
    dgettext(
      "dashboard_availability",
      "Used by every meeting type that has no schedule of its own."
    )
  end

  defp usage_summary(_schedule, []) do
    dgettext(
      "dashboard_availability",
      "No meeting type uses these hours yet. Pick this schedule under a meeting type's booking rules."
    )
  end

  defp usage_summary(_schedule, names) do
    dgettext("dashboard_availability", "Used by %{meeting_types}.",
      meeting_types: Enum.join(names, ", ")
    )
  end
end
