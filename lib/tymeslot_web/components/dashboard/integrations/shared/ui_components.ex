defmodule TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents do
  @moduledoc """
  Shared helpers for integration configuration pages, used by the calendar
  and video integration configs alike.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

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

  @doc """
  The Cancel and submit row at the foot of a provider's connect form.

  Cancel pushes `cancel_event` (by default back to the provider list) to
  `target`; the submit button shows a spinner and `saving_text` while
  `saving` is true. `class` sets the colour of the divider above the row:
  calendar forms pass their turquoise border.
  """
  attr :target, :any, required: true
  attr :saving, :boolean, default: false
  attr :cancel_event, :string, default: "back_to_providers"
  attr :submit_text, :string, default: nil, doc: "Defaults to \"Add Integration\""
  attr :saving_text, :string, default: nil, doc: "Defaults to \"Adding...\""
  attr :class, :any, default: "border-tymeslot-100"

  @spec form_actions(map()) :: Phoenix.LiveView.Rendered.t()
  def form_actions(assigns) do
    ~H"""
    <div class={["flex justify-between items-center pt-4 border-t", @class]}>
      <.action_button variant={:secondary} phx-click={@cancel_event} phx-target={@target}>
        {dgettext("dashboard_integrations", "Cancel")}
      </.action_button>
      <.loading_button
        type="submit"
        loading={@saving}
        loading_text={@saving_text || dgettext("dashboard_integrations", "Adding...")}
      >
        {@submit_text || dgettext("dashboard_integrations", "Add Integration")}
      </.loading_button>
    </div>
    """
  end
end
