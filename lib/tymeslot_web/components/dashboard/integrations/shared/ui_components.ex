defmodule TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents do
  @moduledoc """
  Shared UI components for integration configuration pages.
  Reduces code duplication across calendar and video integration configs.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Renders a form submit button with loading state.

  ## Examples

      <.form_submit_button saving={@saving} />
      <.form_submit_button saving={@saving} text="Save Integration" />
  """
  attr :saving, :boolean, required: true
  attr :text, :string, default: nil
  attr :saving_text, :string, default: nil
  attr :class, :string, default: "btn btn-primary"

  @spec form_submit_button(map()) :: Phoenix.LiveView.Rendered.t()
  def form_submit_button(assigns) do
    ~H"""
    <button type="submit" disabled={@saving} class={@class}>
      <%= if @saving do %>
        <span class="flex items-center">
          <.spinner class="h-4 w-4 mr-2" />
          {@saving_text || dgettext("dashboard_integrations", "Adding...")}
        </span>
      <% else %>
        {@text || dgettext("dashboard_integrations", "Add Integration")}
      <% end %>
    </button>
    """
  end

  @doc """
  Renders a secondary button for cancel/back actions.
  """
  attr :target, :any, required: true
  attr :label, :string, default: nil
  attr :icon, :string, default: nil
  attr :phx_click, :string, default: "back_to_providers"
  attr :class, :string, default: "btn btn-secondary"

  @spec secondary_button(map()) :: Phoenix.LiveView.Rendered.t()
  def secondary_button(assigns) do
    ~H"""
    <button
      type="button"
      class={@class}
      phx-click={@phx_click}
      phx-target={@target}
    >
      <%= if @icon do %>
        <.icon name={@icon} class="w-4 h-4 mr-2" />
      <% end %>
      {@label || dgettext("dashboard_integrations", "Cancel")}
    </button>
    """
  end

  @doc """
  Maps a connection status variant to the `CoreComponents.pill/1` tone that
  shows it. Shared by `ConnectionRow.connection_row/1` and
  `TabNav.integrations_tab_nav/1` so a row's status pill and its tab's status
  dot never drift out of sync.
  """
  @spec status_tone(:ok | :warning | :error | :paused | :info) :: atom()
  def status_tone(:ok), do: :success
  def status_tone(:warning), do: :warning
  def status_tone(:error), do: :danger
  def status_tone(:info), do: :info
  def status_tone(:paused), do: :neutral

  @doc """
  Attributes that make a `type="url"` input forgiving about the scheme.

  Spread onto every server URL input, calendar and video alike, so all of them
  behave the same way: `{UIComponents.server_url_attrs()}` on the element that
  carries `type="url"`, whether that is a `CoreComponents.input/1` call or the
  markup inside a form component.

  The element keeps its `type="url"`, and the `ServerUrlField` hook adds two
  things to the browser's check: a scheme-less address gains `https://` in the
  field itself when the value is committed, and a value the browser still
  refuses gets the message below rather than "Please enter a URL". Both are
  scoped to the one input, which is why this is not `novalidate` on the form:
  that would also stop the browser blocking an empty `required` name or API
  key, neither of which has an inline error to fall back on.

  The input needs an `id` for the hook to attach to.
  """
  @spec server_url_attrs() :: map()
  def server_url_attrs do
    %{
      "phx-hook" => "ServerUrlField",
      "data-scheme-hint" =>
        dgettext(
          "dashboard_integrations",
          "Enter a full address starting with https://, for example https://cloud.example.com"
        )
    }
  end
end
