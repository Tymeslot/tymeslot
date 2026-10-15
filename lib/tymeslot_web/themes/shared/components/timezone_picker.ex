defmodule TymeslotWeb.Themes.Shared.Components.TimezonePicker do
  @moduledoc """
  The booking page's timezone picker, shared by every theme: the dropdown, its
  search box and the matching timezones, each with its flag.

  The trigger's visible content is the theme's `:trigger` slot (Quill shows
  the local time and UTC offset there, Rhythm the flag and name); the
  screen-reader "Your timezone:" prefix that makes the trigger's accessible
  name contain its visible text is rendered here. Fixed markup with
  `tz-picker__*` class names, styled by each theme's CSS.

  Events go to `target`: `toggle_timezone_dropdown`,
  `close_timezone_dropdown`, `search_timezone` (keyup on the search box) and
  `change_timezone` with `phx-value-timezone`.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Timezones

  use TymeslotWeb.Components.CoreComponents, only: [dropdown: 1]
  import TymeslotWeb.Components.FlagHelpers, only: [timezone_flag: 1]

  attr :id, :string, default: "timezone-picker"
  attr :open, :boolean, required: true
  attr :search, :string, default: ""
  attr :target, :any, required: true

  slot :trigger,
    required: true,
    doc: "the trigger's visible content; the screen-reader prefix is added for you"

  @spec timezone_picker(map()) :: Phoenix.LiveView.Rendered.t()
  def timezone_picker(assigns) do
    ~H"""
    <div class="tz-picker">
      <.dropdown
        id={@id}
        open={@open}
        on_toggle="toggle_timezone_dropdown"
        on_close="close_timezone_dropdown"
        target={@target}
        role="dialog"
        panel_label={dgettext("booking", "Select timezone")}
        trigger_class="tz-picker__trigger"
        class="tz-picker__panel"
        unstyled={true}
      >
        <:trigger>
          <span class="sr-only">{dgettext("booking", "Your timezone")}:</span>
          {render_slot(@trigger)}
        </:trigger>
        <:panel>
          <div class="tz-picker__search-wrapper">
            <input
              id={"#{@id}-search"}
              type="text"
              class="tz-picker__search"
              phx-keyup="search_timezone"
              phx-target={@target}
              name="search"
              value={@search}
              placeholder={dgettext("booking", "Search cities, countries, or timezones...")}
              aria-label={dgettext("booking", "Search timezones")}
              autocomplete="off"
              phx-hook="AutoFocus"
            />
          </div>
          <div class="tz-picker__options scroll-y">
            <button
              :for={{label, value, offset} <- Timezones.search(@search)}
              type="button"
              class="tz-picker__option"
              phx-click="change_timezone"
              phx-value-timezone={value}
              phx-target={@target}
            >
              <div class="tz-picker__option-content">
                <.timezone_flag timezone={value} class="tz-picker__option-flag" fallback_icon="🌐" />
                <div class="tz-picker__option-text">
                  <div class="tz-picker__option-label">{label}</div>
                  <div class="tz-picker__option-offset">{offset}</div>
                </div>
              </div>
            </button>
          </div>
        </:panel>
      </.dropdown>
    </div>
    """
  end
end
