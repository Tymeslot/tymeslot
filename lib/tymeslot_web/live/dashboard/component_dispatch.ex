defmodule TymeslotWeb.Dashboard.ComponentDispatch do
  @moduledoc """
  Action-to-component dispatch for `DashboardLive`.

  Maps each `live_action` to its LiveComponent module, computes any prop
  overrides the component needs, evaluates feature-gates, and renders the
  placeholder shown when a feature is gated off. Extension components
  registered via `:dashboard_action_components` are resolved here too.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Naming
  alias Tymeslot.Agenda.Day
  alias Tymeslot.Profiles
  alias TymeslotWeb.Dashboard.AutomationSettingsComponent
  alias TymeslotWeb.Dashboard.BookingsManagementComponent
  alias TymeslotWeb.Dashboard.CalendarGridComponent
  alias TymeslotWeb.Dashboard.CalendarSettingsComponent
  alias TymeslotWeb.Dashboard.DashboardOverviewComponent
  alias TymeslotWeb.Dashboard.IntegrationsHubComponent
  alias TymeslotWeb.Dashboard.PaymentsSettingsComponent
  alias TymeslotWeb.Dashboard.ProfileSettingsComponent
  alias TymeslotWeb.Dashboard.ScheduleSettingsComponent
  alias TymeslotWeb.Dashboard.ServiceSettingsComponent
  alias TymeslotWeb.Dashboard.ThemeSettingsComponent
  alias TymeslotWeb.Dashboard.VideoSettingsComponent
  alias TymeslotWeb.Live.Dashboard.EmbedSettingsComponent

  @doc """
  Returns the stable string id used for the LiveComponent rendered for the
  given action. `send_update/2` callers must use this same id.
  """
  @spec component_id(atom()) :: String.t()
  def component_id(action), do: to_string(action)

  @doc """
  Resolves the LiveComponent module for the given action. Extension actions
  fall through to the registered `:dashboard_action_components` map, and an
  unknown action defaults to `DashboardOverviewComponent`.
  """
  @spec component_for_action(atom(), map() | nil) :: module()
  def component_for_action(:overview, _components), do: DashboardOverviewComponent
  def component_for_action(:settings, _components), do: ProfileSettingsComponent
  def component_for_action(:availability, _components), do: ScheduleSettingsComponent
  def component_for_action(:meeting_settings, _components), do: ServiceSettingsComponent
  def component_for_action(:calendar, _components), do: CalendarGridComponent
  def component_for_action(:calendar_integration, _components), do: CalendarSettingsComponent
  def component_for_action(:video_integration, _components), do: VideoSettingsComponent
  def component_for_action(:integrations, _components), do: IntegrationsHubComponent
  def component_for_action(:automation, _components), do: AutomationSettingsComponent
  def component_for_action(:theme, _components), do: ThemeSettingsComponent
  def component_for_action(:theme_customization, _components), do: ThemeSettingsComponent
  def component_for_action(:meetings, _components), do: BookingsManagementComponent
  def component_for_action(:embed, _components), do: EmbedSettingsComponent
  def component_for_action(:payments, _components), do: PaymentsSettingsComponent

  def component_for_action(action, components) do
    Map.get(components || %{}, action, DashboardOverviewComponent)
  end

  @doc """
  Returns a map of assign overrides for the given action. Only actions that
  need to transform assigns before passing them to the component are listed
  here; all other actions receive the socket assigns directly.
  """
  @spec props_for_action(map()) :: map()
  def props_for_action(%{live_action: :overview} = assigns) do
    %{shared_data: %{agenda: assigns[:agenda] || %Day{}}}
  end

  def props_for_action(%{live_action: action} = assigns)
      when action in [:settings, :availability] do
    %{profile: Profiles.prefill_timezone(assigns.profile, assigns[:detected_timezone])}
  end

  def props_for_action(_assigns), do: %{}

  @doc """
  Evaluates the feature gate for the given action. Returns `true` if the
  action is not gated or if the gating assign is truthy.
  """
  @spec should_render_feature?(atom(), map()) :: boolean()
  def should_render_feature?(action, assigns) do
    gates = assigns[:dashboard_feature_gates] || %{}

    case Map.get(gates, action) do
      nil -> true
      assign_key -> Map.get(assigns, assign_key, true)
    end
  end

  attr :section, :atom, required: true
  attr :current_user, :any, required: true
  attr :feature_placeholder_components, :map, required: true

  @doc """
  Renders the placeholder shown when a feature is gated off. Delegates to
  a registered placeholder component when one is configured, otherwise
  falls back to a generic message.
  """
  @spec feature_placeholder(map()) :: Phoenix.LiveView.Rendered.t()
  def feature_placeholder(assigns) do
    assigns =
      assigns
      |> assign(:placeholder_component, assigns.feature_placeholder_components[assigns.section])
      |> assign(:feature_name, Naming.humanize(assigns.section))

    ~H"""
    <%= if @placeholder_component do %>
      <.live_component
        module={@placeholder_component}
        id={"#{@section}_placeholder"}
        current_user={@current_user}
        feature={@section}
      />
    <% else %>
      <%!-- Core fallback: just show a simple message --%>
      <div class="p-8 text-center text-tymeslot-500">
        <p>
          {dgettext(
            "dashboard_common",
            "This feature (%{feature_name}) is not available on your current plan.",
            feature_name: @feature_name
          )}
        </p>
      </div>
    <% end %>
    """
  end
end
