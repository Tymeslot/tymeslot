defmodule TymeslotWeb.Dashboard.Calendar.RailSets do
  @moduledoc """
  The Calendar sets section of the rail and the Calendars sheet: the
  organiser's sets, each with its digit, a row "No set" (0) once any exists,
  and New set. A row applies its set (`calendar:apply_set`); the pencil
  opens the inline name field (`calendar:edit_set`), which saves a new set
  or renames one and offers Delete. `id_prefix` keeps the rail's and the
  sheet's ids apart. Rows are 44px tall in the sheet (below 768px, where
  the rail is hidden) and 36px in the rail.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  # One set per digit, 1 to 9 (`CalendarSets.create/3` refuses a tenth).
  @max_sets 9

  @doc """
  What the sections and the chip need from the surface's assigns: the sets,
  the active digit (0 for none), the open name field and the active set's
  name.
  """
  @spec view(map()) :: %{
          sets: list(),
          active_position: 0..9,
          editor: nil | :new | {:rename, 1..9},
          name: String.t() | nil
        }
  def view(assigns) do
    active = Map.get(assigns, :active_set)

    %{
      sets: Map.get(assigns, :calendar_sets, []),
      active_position: (active && active.position) || 0,
      editor: Map.get(assigns, :set_editor),
      name: active && active.name
    }
  end

  attr :id_prefix, :string, default: "calendar-rail"
  attr :sets, :list, required: true
  attr :active_position, :integer, required: true
  attr :editor, :any, default: nil
  attr :target, :any, required: true

  @spec sets(map()) :: Phoenix.LiveView.Rendered.t()
  def sets(assigns) do
    assigns = assign(assigns, :max_sets, @max_sets)

    ~H"""
    <section id={"#{@id_prefix}-sets"} aria-labelledby={"#{@id_prefix}-sets-heading"}>
      <div class="mb-1 flex items-center gap-2">
        <h2
          id={"#{@id_prefix}-sets-heading"}
          class="min-w-0 flex-1 text-token-xs font-semibold uppercase tracking-wide text-tymeslot-500"
        >
          {dgettext("dashboard_calendar_power", "Calendar sets")}
        </h2>
        <.icon_button
          :if={@editor != :new and length(@sets) < @max_sets}
          id={"#{@id_prefix}-new-set"}
          icon="hero-plus"
          size={:sm}
          label={dgettext("dashboard_calendar_power", "New set")}
          phx-click="calendar:edit_set"
          phx-value-new="true"
          phx-target={@target}
        />
      </div>
      <p :if={@sets == [] and @editor != :new} class="text-token-sm text-tymeslot-500">
        {dgettext(
          "dashboard_calendar_power",
          "Save the calendars you show as a set, then press its number to switch to it."
        )}
      </p>
      <ul :if={@sets != []} class="space-y-0.5">
        <li>
          <.set_row
            id={"#{@id_prefix}-set-0"}
            position={0}
            label={dgettext("dashboard_calendar_power", "No set")}
            pressed={@active_position == 0}
            target={@target}
          />
        </li>
        <li :for={set <- @sets} class="flex items-center gap-1">
          <%= if @editor == {:rename, set.position} do %>
            <.editor id_prefix={@id_prefix} value={set.name} position={set.position} target={@target} />
          <% else %>
            <.set_row
              id={"#{@id_prefix}-set-#{set.position}"}
              position={set.position}
              label={set.name}
              pressed={@active_position == set.position}
              target={@target}
            />
            <.icon_button
              id={"#{@id_prefix}-set-#{set.position}-edit"}
              icon="hero-pencil-square"
              size={:sm}
              label={dgettext("dashboard_calendar_power", "Rename or delete %{name}", name: set.name)}
              phx-click="calendar:edit_set"
              phx-value-position={set.position}
              phx-target={@target}
            />
          <% end %>
        </li>
      </ul>
      <.editor :if={@editor == :new} id_prefix={@id_prefix} value="" position={nil} target={@target} />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :position, :integer, required: true
  attr :label, :string, required: true
  attr :pressed, :boolean, required: true
  attr :target, :any, required: true

  defp set_row(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      aria-pressed={to_string(@pressed)}
      aria-keyshortcuts={to_string(@position)}
      phx-click="calendar:apply_set"
      phx-value-position={@position}
      phx-target={@target}
      class={[
        "flex min-h-11 w-full min-w-0 flex-1 items-center gap-2 rounded-token-md px-2 text-left text-token-sm md:min-h-9",
        "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400",
        if(@pressed,
          do: "bg-turquoise-50 font-semibold text-turquoise-900",
          else: "text-tymeslot-700 hover:bg-tymeslot-50"
        )
      ]}
    >
      <span class="min-w-0 flex-1 truncate">{@label}</span>
      <kbd class="cal-kbd">{@position}</kbd>
    </button>
    """
  end

  attr :id_prefix, :string, required: true
  attr :value, :string, required: true
  attr :position, :any, default: nil
  attr :target, :any, required: true

  defp editor(assigns) do
    ~H"""
    <form
      novalidate
      id={"#{@id_prefix}-set-form"}
      phx-submit="calendar:save_set"
      phx-target={@target}
      class="w-full space-y-2"
    >
      <.input
        id={"#{@id_prefix}-set-name"}
        name="name"
        value={@value}
        label={dgettext("dashboard_calendar_power", "Set name")}
        placeholder={dgettext("dashboard_calendar_power", "For example, Work")}
        maxlength="40"
        phx-mounted={JS.focus()}
      />
      <div class="flex flex-wrap items-center gap-2">
        <.action_button type="submit" variant={:primary} size={:sm}>
          {dgettext("dashboard_calendar_editing", "Save")}
        </.action_button>
        <.action_button
          :if={@position}
          id={"#{@id_prefix}-set-#{@position}-delete"}
          variant={:danger_soft}
          size={:sm}
          phx-click="calendar:delete_set"
          phx-value-position={@position}
          phx-target={@target}
        >
          {dgettext("dashboard_calendar", "Delete")}
        </.action_button>
        <.action_button
          variant={:ghost}
          size={:sm}
          phx-click="calendar:cancel_set_edit"
          phx-target={@target}
        >
          {dgettext("dashboard_calendar_editing", "Cancel")}
        </.action_button>
      </div>
    </form>
    """
  end
end
