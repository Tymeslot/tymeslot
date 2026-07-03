defmodule TymeslotWeb.Dashboard.VideoSettings.Components do
  @moduledoc """
  Functional components for the video settings dashboard.
  """
  use TymeslotWeb, :html

  alias Tymeslot.Integrations.Providers.Directory, as: ProviderDirectory
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionRow

  @oauth_providers ~w(google_meet teams zoom)

  @doc """
  Renders a single connected video integration as a shared `connection_row`:
  a status-first header with a one-line summary, the connection meta
  (provider type, account/host/custom link, and a short description) in the
  expandable `:detail` slot, and the test/edit/delete controls in the
  `:actions` slot. When an OAuth integration needs re-authentication
  (`needs_reauth`), the Reconnect control is surfaced on the collapsed header
  via `:header_action` instead of the expanded actions, so the fix is one click
  away without opening the row.
  """
  attr :integration, :map, required: true
  attr :expanded?, :boolean, default: false
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
      |> assign(:type_label, type_label(integration.provider))
      |> assign(:description, provider_description(integration.provider))
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
      expanded?={@expanded?}
      toggle_event="toggle_integration"
      myself={@myself}
    >
      <:header_action :if={@oauth? && @integration.needs_reauth}>
        <button
          phx-click="reconnect_integration"
          phx-value-id={@integration.id}
          phx-target={@myself}
          class="flex items-center gap-1.5 px-3 py-1.5 bg-amber-50 text-amber-700 rounded-token-xl font-bold border-2 border-amber-100 hover:bg-amber-100 transition-all shadow-sm shadow-amber-500/5"
          title="Reconnect OAuth"
        >
          <.icon name="hero-arrow-path" class="w-4 h-4" /> Reconnect
        </button>
      </:header_action>

      <:detail>
        <dl class="space-y-2 text-token-sm">
          <div class="flex items-center gap-2">
            <dt class="text-token-2xs font-black uppercase tracking-widest text-tymeslot-400">
              Type
            </dt>
            <dd class="font-semibold text-tymeslot-700">{@type_label}</dd>
          </div>
          <div :if={@integration.provider_account_email} class="flex items-center gap-2">
            <dt class="text-token-2xs font-black uppercase tracking-widest text-tymeslot-400">
              Account
            </dt>
            <dd class="text-tymeslot-700 break-all">{@integration.provider_account_email}</dd>
          </div>
          <div :if={@integration.base_url} class="flex items-center gap-2">
            <dt class="text-token-2xs font-black uppercase tracking-widest text-tymeslot-400">
              Host
            </dt>
            <dd class="text-tymeslot-700 break-all">{URI.parse(@integration.base_url).host}</dd>
          </div>
          <div :if={Map.get(@integration, :custom_meeting_url)} class="flex items-center gap-2">
            <dt class="text-token-2xs font-black uppercase tracking-widest text-tymeslot-400">
              Link
            </dt>
            <dd class="text-tymeslot-700 break-all">{@integration.custom_meeting_url}</dd>
          </div>
        </dl>
        <p class="mt-3 text-token-sm text-tymeslot-500">{@description}</p>
      </:detail>

      <:actions>
        <button
          :if={@integration.is_active}
          phx-click="test_connection"
          phx-value-id={@integration.id}
          phx-target={@myself}
          disabled={@testing_connection == @integration.id}
          class="flex items-center gap-2 px-4 py-2 bg-tymeslot-50 text-tymeslot-700 rounded-token-xl font-bold border-2 border-tymeslot-100 hover:bg-tymeslot-100 transition-all shadow-sm shadow-tymeslot-500/5 disabled:opacity-60"
          title="Test connection"
        >
          <.icon
            name={
              (@testing_connection == @integration.id && "hero-arrow-path") || "hero-check-circle"
            }
            class={"w-4 h-4 #{(@testing_connection == @integration.id && "animate-spin") || ""}"}
          />
          {(@testing_connection == @integration.id && "Testing...") || "Test connection"}
        </button>
        <button
          :if={@oauth? && !@integration.needs_reauth}
          phx-click="reconnect_integration"
          phx-value-id={@integration.id}
          phx-target={@myself}
          class="flex items-center gap-2 px-4 py-2 bg-tymeslot-50 text-tymeslot-700 rounded-token-xl font-bold border-2 border-tymeslot-100 hover:bg-tymeslot-100 transition-all shadow-sm shadow-tymeslot-500/5"
          title="Reconnect OAuth"
        >
          <.icon name="hero-arrow-path" class="w-4 h-4" /> Reconnect
        </button>
        <button
          phx-click="show"
          phx-value-id={@integration.id}
          phx-target="#edit-video-modal"
          class="flex items-center gap-2 px-4 py-2 bg-tymeslot-50 text-tymeslot-700 rounded-token-xl font-bold border-2 border-tymeslot-100 hover:bg-tymeslot-100 transition-all shadow-sm shadow-tymeslot-500/5"
          title="Edit Integration"
        >
          <.icon name="hero-pencil-square" class="w-4 h-4" /> Edit
        </button>
        <button
          phx-click="show"
          phx-value-id={@integration.id}
          phx-target="#delete-video-modal"
          class="ml-auto flex items-center gap-2 px-4 py-2 text-tymeslot-500 hover:text-red-500 hover:bg-red-50 rounded-token-xl font-bold border-2 border-transparent hover:border-red-100 transition-all"
          title="Delete Integration"
        >
          <.icon name="hero-trash" class="w-4 h-4" /> Delete
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
    [integration.provider_account_email, "OAuth", "rooms created automatically"]
  end

  defp summary_segments(%{provider: "mirotalk"} = integration) do
    [host(integration.base_url), "self-hosted"]
  end

  defp summary_segments(%{provider: "custom"} = integration) do
    [Map.get(integration, :custom_meeting_url), "custom link"]
  end

  defp summary_segments(integration) do
    [integration.provider_account_email || host(integration.base_url)]
  end

  # Status-first badge mapping, dispatched on integration/health shape.
  defp video_status(%{is_active: false}, _health), do: {:paused, "Paused"}
  defp video_status(%{needs_reauth: true}, _health), do: {:warning, "Reconnect"}

  defp video_status(_integration, %{status: :unhealthy}),
    do: {:warning, "Connection issues"}

  defp video_status(_integration, _health), do: {:ok, "Healthy"}

  defp type_tag(provider) when provider in @oauth_providers, do: "OAuth"
  defp type_tag("mirotalk"), do: "self-hosted"
  defp type_tag("custom"), do: "custom"
  defp type_tag(_provider), do: nil

  defp type_label(provider) when provider in @oauth_providers, do: "OAuth Provider"
  defp type_label("mirotalk"), do: "Self-Hosted"
  defp type_label("custom"), do: "Custom URL"
  defp type_label(_provider), do: "Video Provider"

  defp provider_description(provider) when provider in @oauth_providers,
    do: "A meeting link is created automatically when a booking is confirmed."

  defp provider_description("mirotalk"),
    do: "Meeting rooms are generated on your self-hosted MiroTalk server."

  defp provider_description("custom"),
    do: "Your custom meeting link is shared with every booking."

  defp provider_description(_provider),
    do: "A video link is added to online meetings when they're booked."

  defp host(nil), do: nil
  defp host(base_url), do: URI.parse(base_url).host
end
