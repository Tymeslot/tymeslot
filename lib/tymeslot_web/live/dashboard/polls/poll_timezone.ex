defmodule TymeslotWeb.Dashboard.Polls.PollTimezone do
  @moduledoc """
  The poll form's timezone field: the shared `TimezoneDropdown` inside the form
  (a hidden input posts the zone), and the dropdown's events.

  A host's profile can hold a zone the list does not carry (`America/Detroit`);
  the field shows and posts it regardless, because the value is the assign, not
  an option in a list.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Timezones
  alias TymeslotWeb.Components.TimezoneDropdown

  attr :timezone, :string, required: true
  attr :open, :boolean, required: true
  attr :search, :string, required: true
  attr :errors, :list, required: true
  attr :target, :any, required: true

  @spec field(map()) :: Phoenix.LiveView.Rendered.t()
  def field(assigns) do
    ~H"""
    <div>
      <div class="label">{dgettext("dashboard_polls", "Timezone")}</div>
      <TimezoneDropdown.timezone_dropdown
        profile={%{timezone: @timezone}}
        timezone_dropdown_open={@open}
        timezone_search={@search}
        target={@target}
        field_name="poll[timezone]"
        show_label={false}
        show_help={false}
      />
      <p :for={error <- @errors} class="form-error">{error}</p>
    </div>
    """
  end

  @doc """
  Handles one of the dropdown's events. `{:changed, socket}` means the zone
  changed, and the owner must refresh what depends on it.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:changed | :unchanged, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_timezone_dropdown", _params, socket) do
    {:unchanged,
     assign(socket, timezone_dropdown_open: not socket.assigns.timezone_dropdown_open)}
  end

  def handle_event("close_timezone_dropdown", _params, socket) do
    {:unchanged, assign(socket, timezone_dropdown_open: false)}
  end

  def handle_event("search_timezone", %{"value" => search}, socket) do
    {:unchanged, assign(socket, timezone_search: search)}
  end

  def handle_event("change_timezone", %{"timezone" => timezone}, socket) do
    socket = assign(socket, timezone_dropdown_open: false, timezone_search: "")

    if Timezones.valid?(timezone) do
      {:changed, assign(socket, :timezone, timezone)}
    else
      {:unchanged, socket}
    end
  end
end
