defmodule TymeslotWeb.Components.CoreComponents.SettingRow do
  @moduledoc """
  One on/off setting: a label and a description beside the control that
  switches it, on a flat card.
  """
  use Phoenix.Component

  alias TymeslotWeb.Components.CoreComponents.Containers
  alias TymeslotWeb.Components.CoreComponents.Icons
  alias TymeslotWeb.Components.UI.StatusSwitch

  @doc """
  Renders one on/off setting.

      <.setting_row
        id="allow-guests-toggle"
        label="Let invitees add guests"
        description="Each guest is emailed a confirmation."
        checked={@allow_guests}
        on_change="toggle_allow_guests"
        target={@myself}
      />

  * `control={:checkbox}` (the default) puts the checkbox and its text in one
    `<label>` that fills the card; `control={:switch}` renders a
    `StatusSwitch` at the row's end, for a setting that takes effect the
    moment it is flipped.
  * The control's accessible name is the label alone; the description, and
    the reason while disabled, are its description (`aria-describedby`).
  * The control carries no `name`: the change is sent by `on_change` (a click
    event to `target`), so a row inside a form adds nothing to its params.
  * `disabled` with a `:disabled_reason` says why the setting cannot be
    changed. The reason sits outside the label, so it may hold a link, and is
    shown only while the row is disabled. The label stays at full contrast so
    it can still be read.
  * Further attributes (`phx-value-*`, `data-testid`) go to the control.
  """
  attr :id, :string, required: true, doc: "The control's id"
  attr :label, :string, required: true
  attr :description, :string, default: nil
  attr :control, :atom, default: :checkbox, values: [:checkbox, :switch]
  attr :checked, :boolean, required: true
  attr :on_change, :string, required: true, doc: "The click event that flips the setting"
  attr :target, :any, default: nil
  attr :disabled, :boolean, default: false
  attr :class, :any, default: nil, doc: "Layout classes only"
  attr :rest, :global, doc: "Extra attributes for the control"

  slot :disabled_reason, doc: "Why the setting cannot be changed; shown only while disabled"

  @spec setting_row(map()) :: Phoenix.LiveView.Rendered.t()
  def setting_row(assigns) do
    reason? = assigns.disabled and assigns.disabled_reason != []

    described_by =
      [assigns.description && "#{assigns.id}-description", reason? && "#{assigns.id}-reason"]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    assigns =
      assign(assigns,
        reason?: reason?,
        described_by: if(described_by == "", do: nil, else: described_by)
      )

    ~H"""
    <%= if @control == :checkbox do %>
      <Containers.card variant={:flat} padding={:none} interactive={!@disabled} class={@class}>
        <label
          for={@id}
          class={[
            "flex items-start gap-3 p-4",
            if(@disabled, do: "cursor-not-allowed", else: "cursor-pointer")
          ]}
        >
          <input
            type="checkbox"
            id={@id}
            class="checkbox mt-0.5 shrink-0"
            checked={@checked}
            disabled={@disabled}
            phx-click={@on_change}
            phx-target={@target}
            aria-labelledby={"#{@id}-label"}
            aria-describedby={@described_by}
            {@rest}
          />
          <span class="block min-w-0 space-y-1">
            <span id={"#{@id}-label"} class="block text-token-sm font-medium text-tymeslot-800">
              {@label}
            </span>
            <span
              :if={@description}
              id={"#{@id}-description"}
              class="block text-token-sm text-tymeslot-600"
            >
              {@description}
            </span>
          </span>
        </label>
        <.reason :if={@reason?} id={@id} class="-mt-2 pr-4 pb-4 pl-11">
          {render_slot(@disabled_reason)}
        </.reason>
      </Containers.card>
    <% else %>
      <Containers.card
        variant={:flat}
        padding={:sm}
        class={["flex items-center justify-between gap-4", @class]}
      >
        <div class="min-w-0 space-y-1">
          <label
            for={@id}
            id={"#{@id}-label"}
            class="block cursor-pointer text-token-sm font-medium text-tymeslot-800"
          >
            {@label}
          </label>
          <p :if={@description} id={"#{@id}-description"} class="text-token-sm text-tymeslot-600">
            {@description}
          </p>
          <.reason :if={@reason?} id={@id}>{render_slot(@disabled_reason)}</.reason>
        </div>
        <StatusSwitch.status_switch
          id={@id}
          checked={@checked}
          on_change={@on_change}
          target={@target}
          disabled={@disabled}
          class="shrink-0"
          aria-labelledby={"#{@id}-label"}
          aria-describedby={@described_by}
          {@rest}
        />
      </Containers.card>
    <% end %>
    """
  end

  attr :id, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  defp reason(assigns) do
    ~H"""
    <p
      id={"#{@id}-reason"}
      class={["flex items-start gap-1.5 text-token-sm font-medium text-tymeslot-700", @class]}
    >
      <Icons.icon name="hero-information-circle" class="mt-0.5 h-4 w-4 shrink-0 text-turquoise-600" />
      <span>{render_slot(@inner_block)}</span>
    </p>
    """
  end
end
