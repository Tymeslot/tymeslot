defmodule TymeslotWeb.Dashboard.VideoSettings.Components do
  @moduledoc """
  Functional components for the video settings dashboard.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.Providers.Directory, as: ProviderDirectory
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionRow

  @oauth_providers ~w(google_meet teams zoom)

  @doc """
  Renders a single connected video integration as a shared `connection_row`:
  a status-first, flat row with a one-line summary and an always-visible action
  cluster — Test connection (icon), Reconnect (OAuth only, promoted when the
  integration needs re-authentication), Edit (icon), and Delete (icon). There is
  no expand/collapse; every action is one click away.
  """
  attr :integration, :map, required: true
  attr :testing_connection, :any, default: nil
  attr :myself, :any, required: true
  attr :health_state, :map, default: nil

  @spec video_connection_row(map()) :: Phoenix.LiveView.Rendered.t()
  def video_connection_row(assigns) do
    integration = assigns.integration
    provider_name = ProviderDirectory.format_provider_name(:video, integration.provider)

    assigns =
      assigns
      |> assign(:status, video_status(integration, assigns.health_state))
      |> assign(:summary, video_summary(integration))
      |> assign(:type_tag, type_tag(integration.provider))
      |> assign(:oauth?, integration.provider in @oauth_providers)
      |> assign(
        :display_name,
        if(integration.name == provider_name, do: provider_name, else: integration.name)
      )

    ~H"""
    <ConnectionRow.connection_row
      id={to_string(@integration.id)}
      icon={@integration.provider}
      icon_type={:video}
      title={@display_name}
      type_tag={@type_tag}
      summary={@summary}
      status={@status}
      active?={@integration.is_active}
      toggle_event="toggle_integration"
      myself={@myself}
    >
      <:actions>
        <button
          :if={@integration.is_active}
          phx-click="test_connection"
          phx-value-id={@integration.id}
          phx-target={@myself}
          disabled={@testing_connection == @integration.id}
          aria-busy={(@testing_connection == @integration.id && "true") || "false"}
          class="flex items-center justify-center h-9 w-9 bg-tymeslot-50 text-tymeslot-700 rounded-token-lg border-2 border-tymeslot-100 hover:bg-tymeslot-100 transition-all shadow-sm shadow-tymeslot-500/5 disabled:opacity-60"
          title={
            (@testing_connection == @integration.id &&
               dgettext("dashboard_integrations", "Testing…")) ||
              dgettext("dashboard_integrations", "Test connection")
          }
          aria-label={
            (@testing_connection == @integration.id &&
               dgettext("dashboard_integrations", "Testing connection…")) ||
              dgettext("dashboard_integrations", "Test connection")
          }
        >
          <.icon
            name={(@testing_connection == @integration.id && "hero-arrow-path") || "hero-signal"}
            class={"w-5 h-5 #{(@testing_connection == @integration.id && "animate-spin") || ""}"}
          />
        </button>
        <button
          :if={@oauth?}
          phx-click="reconnect_integration"
          phx-value-id={@integration.id}
          phx-target={@myself}
          class={[
            "flex items-center justify-center gap-1.5 px-3 py-1.5 lg:h-9 lg:w-9 lg:px-0 lg:py-0 rounded-token-lg font-bold border-2 transition-all shadow-sm",
            (@integration.needs_reauth &&
               "bg-amber-50 text-amber-700 border-amber-100 hover:bg-amber-100 shadow-amber-500/5") ||
              "bg-tymeslot-50 text-tymeslot-700 border-tymeslot-100 hover:bg-tymeslot-100 shadow-tymeslot-500/5"
          ]}
          title={dgettext("dashboard_integrations", "Reconnect integration")}
          aria-label={dgettext("dashboard_integrations", "Reconnect integration")}
        >
          <.icon name="hero-arrow-path" class="w-4 h-4" /><span class="lg:hidden">{dgettext(
            "dashboard_integrations",
            "Reconnect"
          )}</span>
        </button>
        <button
          phx-click="show"
          phx-value-id={@integration.id}
          phx-target="#edit-video-modal"
          class="flex items-center justify-center h-9 w-9 bg-tymeslot-50 text-tymeslot-700 rounded-token-lg border-2 border-tymeslot-100 hover:bg-tymeslot-100 transition-all shadow-sm shadow-tymeslot-500/5"
          title={dgettext("dashboard_integrations", "Edit integration")}
          aria-label={dgettext("dashboard_integrations", "Edit integration")}
        >
          <.icon name="hero-pencil-square" class="w-5 h-5" />
        </button>
        <button
          phx-click="show"
          phx-value-id={@integration.id}
          phx-target="#delete-video-modal"
          class="flex items-center justify-center h-9 w-9 text-tymeslot-500 hover:text-red-500 hover:bg-red-50 rounded-token-lg border-2 border-transparent hover:border-red-100 transition-all"
          title={dgettext("dashboard_integrations", "Delete integration")}
          aria-label={dgettext("dashboard_integrations", "Delete integration")}
        >
          <.icon name="hero-trash" class="w-5 h-5" />
        </button>
      </:actions>
    </ConnectionRow.connection_row>
    """
  end

  @doc """
  Builds a one-line human summary for a video integration — the account,
  host, or custom link plus the provider-type descriptor — dropping absent
  segments gracefully.
  """
  @spec video_summary(map()) :: String.t()
  def video_summary(integration) do
    integration
    |> summary_segments()
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp summary_segments(%{provider: provider} = integration) when provider in @oauth_providers do
    [
      integration.provider_account_email,
      dgettext("dashboard_integrations", "OAuth"),
      dgettext("dashboard_integrations", "rooms created automatically")
    ]
  end

  defp summary_segments(%{provider: "mirotalk"} = integration) do
    [host(integration.base_url), dgettext("dashboard_integrations", "self-hosted")]
  end

  defp summary_segments(%{provider: "custom"} = integration) do
    [Map.get(integration, :custom_meeting_url), dgettext("dashboard_integrations", "custom link")]
  end

  defp summary_segments(integration) do
    [integration.provider_account_email || host(integration.base_url)]
  end

  # Status-first badge mapping. Precedence lives in the canonical
  # `HealthCheck.attention_status/2` classifier; this just maps the atom to
  # this row's badge variant/label.
  defp video_status(integration, health) do
    case HealthCheck.attention_status(integration, health) do
      :paused -> {:paused, dgettext("dashboard_integrations", "Paused")}
      :needs_reauth -> {:warning, dgettext("dashboard_integrations", "Reconnect")}
      :unhealthy -> {:warning, dgettext("dashboard_integrations", "Connection issues")}
      :ok -> {:ok, dgettext("dashboard_integrations", "Healthy")}
    end
  end

  defp type_tag(provider) when provider in @oauth_providers,
    do: dgettext("dashboard_integrations", "OAuth")

  defp type_tag("mirotalk"), do: dgettext("dashboard_integrations", "self-hosted")
  defp type_tag("custom"), do: dgettext("dashboard_integrations", "custom")
  defp type_tag(_provider), do: nil

  defp host(nil), do: nil
  defp host(base_url), do: URI.parse(base_url).host
end
