defmodule TymeslotWeb.Live.Dashboard.EmbedSettingsComponent do
  @moduledoc """
  Dashboard component for embedding options.
  Shows users different ways to embed their booking page with live previews.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Profiles
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.Helpers
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.LivePreview
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.OptionsGrid
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.SecuritySection

  require Logger

  @valid_embed_types Helpers.valid_embed_types()
  @valid_tabs Helpers.valid_tabs()

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    # Extract props from parent
    profile = assigns.profile
    integration_status = assigns[:integration_status] || %{}
    base_url = Endpoint.url()
    username = profile.username
    theme_id = profile.booking_theme || "1"

    # Check if user is ready for scheduling using cached integration status when available
    is_ready = Map.get(integration_status, :has_calendar, false)

    # Use LinkAccessPolicy only for error reasons or if status is unknown
    error_reason =
      if is_ready do
        nil
      else
        scheduling_readiness = LinkAccessPolicy.check_public_readiness(profile)

        if match?({:ok, :ready}, scheduling_readiness),
          do: nil,
          else: elem(scheduling_readiness, 1)
      end

    # Format allowed domains for display
    allowed_domains = profile.allowed_embed_domains || []

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:profile, profile)
      |> assign(:current_user, assigns.current_user)
      |> assign(:base_url, base_url)
      |> assign(:username, username)
      |> assign(:theme_id, theme_id)
      |> assign(:booking_url, "#{base_url}/#{username}")
      |> assign(:is_ready, is_ready)
      |> assign(:error_reason, error_reason)
      |> assign(:allowed_domains, allowed_domains)
      |> assign_new(:selected_embed_type, fn -> "inline" end)
      |> assign_new(:embed_script_url, fn -> ~p"/embed.js" end)
      |> assign_new(:active_tab, fn -> "options" end)
      |> assign_new(:embed_layout, fn -> "column" end)
      |> assign_new(:initial_height, fn -> nil end)
      |> assign_new(:max_width, fn -> nil end)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <%!-- Header --%>
      <.section_header
        icon="hero-code-bracket"
        title={dgettext("dashboard_embed", "Embed & Share")}
        class="mb-4"
      />

      <p class="text-tymeslot-600 mb-6">
        {dgettext(
          "dashboard_embed",
          "Add your booking page to any website. Choose the option that works best for you."
        )}
      </p>

      <%!-- Tabbed Interface --%>
      <.tabs active_tab={@active_tab} target={@myself}>
        <:tab id="options" label={dgettext("dashboard_embed", "Embed Options")} icon="hero-code-bracket">
          <OptionsGrid.options_grid
            selected_embed_type={@selected_embed_type}
            username={@username}
            base_url={@base_url}
            booking_url={@booking_url}
            embed_layout={@embed_layout}
            initial_height={@initial_height}
            max_width={@max_width}
            myself={@myself}
          />
        </:tab>

        <:tab id="security" label={dgettext("dashboard_embed", "Security")} icon="hero-lock-closed">
          <SecuritySection.security_section
            allowed_domains={@allowed_domains}
            myself={@myself}
          />
        </:tab>

        <:tab id="preview" label={dgettext("dashboard_embed", "Live Preview")} icon="hero-video-camera">
          <LivePreview.live_preview
            selected_embed_type={@selected_embed_type}
            username={@username}
            base_url={@base_url}
            embed_script_url={@embed_script_url}
            embed_layout={@embed_layout}
            initial_height={@initial_height}
            max_width={@max_width}
            is_ready={@is_ready}
            error_reason={@error_reason}
            myself={@myself}
          />
        </:tab>
      </.tabs>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in @valid_tabs do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("switch_tab", _params, socket),
    do: reject_invalid_event("switch_tab", socket)

  def handle_event("copy_code", %{"type" => type}, socket) when type in @valid_embed_types do
    code = Helpers.embed_code(type, Helpers.snippet_options(socket.assigns))

    socket = push_event(socket, "copy-to-clipboard", %{text: code})
    Flash.info(dgettext("dashboard_embed", "Code copied to clipboard!"))

    {:noreply, socket}
  end

  def handle_event("copy_code", _params, socket),
    do: reject_invalid_event("copy_code", socket)

  def handle_event("select_embed_type", %{"type" => type}, socket)
      when type in @valid_embed_types do
    {:noreply, assign(socket, :selected_embed_type, type)}
  end

  def handle_event("select_embed_type", _params, socket),
    do: reject_invalid_event("select_embed_type", socket)

  # Customisation knobs surfaced to the embedder: layout, initial-height,
  # and max-width. Phoenix LiveView requires phx-change to fire from inside
  # a <form>, so the panel posts a `customise[...]` map with all three
  # values on every change. Validation happens at the snippet helper
  # boundary so nothing invalid ever reaches the rendered output.
  def handle_event("update_customisation", %{"customise" => params}, socket) do
    layout =
      case params["layout"] do
        v when is_binary(v) -> if v in Helpers.valid_layouts(), do: v, else: "column"
        _other -> socket.assigns.embed_layout
      end

    {:noreply,
     socket
     |> assign(:embed_layout, layout)
     |> assign(:initial_height, blank_to_nil(params["initial_height"]))
     |> assign(:max_width, blank_to_nil(params["max_width"]))}
  end

  def handle_event("update_customisation", _params, socket),
    do: reject_invalid_event("update_customisation", socket)

  def handle_event("save_embed_domains", %{"allowed_domains" => domains_str}, socket) do
    case Profiles.add_embed_domains(socket.assigns.profile, domains_str) do
      {:ok, merged_domains} ->
        perform_domain_update(
          socket,
          merged_domains,
          dgettext("dashboard_embed", "Security settings saved successfully!")
        )

      {:error, :empty_input} ->
        Flash.error(dgettext("dashboard_embed", "Please enter at least one domain."))
        {:noreply, socket}

      {:error, {:duplicates, duplicates}} ->
        Flash.error(
          dgettext("dashboard_embed", "Already whitelisted: %{domains}",
            domains: Enum.join(duplicates, ", ")
          )
        )

        {:noreply, socket}
    end
  end

  def handle_event("save_embed_domains", _params, socket),
    do: reject_invalid_event("save_embed_domains", socket)

  def handle_event("remove_domain", %{"domain" => domain}, socket) do
    if domain in socket.assigns.allowed_domains do
      updated_domains = Enum.reject(socket.assigns.allowed_domains, &(&1 == domain))
      updated_domains = if updated_domains == [], do: ["none"], else: updated_domains

      perform_domain_update(
        socket,
        updated_domains,
        dgettext("dashboard_embed", "Domain removed successfully")
      )
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_domain", _params, socket),
    do: reject_invalid_event("remove_domain", socket)

  def handle_event("clear_embed_domains", _params, socket) do
    perform_domain_update(
      socket,
      ["none"],
      dgettext("dashboard_embed", "Embedding is now disabled")
    )
  end

  defp reject_invalid_event(event_name, socket) do
    Logger.warning("handle_event received invalid or missing parameter", event: event_name)
    {:noreply, socket}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: value

  defp perform_domain_update(socket, domains_payload, success_message) do
    user_id = socket.assigns.current_user.id

    # Rate limit: 10 updates per hour per user
    case RateLimiter.check_rate(
           "embed_domain_update:#{user_id}",
           60_000 * 60,
           10
         ) do
      {:allow, _count} ->
        # Ensure we don't save duplicates and handle the "none" sentinel correctly
        final_domains =
          domains_payload
          |> Enum.uniq()
          |> Enum.reject(&(&1 == ""))

        case Profiles.update_allowed_embed_domains(socket.assigns.profile, final_domains) do
          {:ok, updated_profile} ->
            # Notify parent of profile update
            send(self(), {:profile_updated, updated_profile})
            Flash.info(success_message)

            {:noreply,
             socket
             |> push_event("reset-form", %{id: "embed-domains-form"})
             |> assign(:profile, updated_profile)
             |> assign(:allowed_domains, updated_profile.allowed_embed_domains || [])}

          {:error, %Changeset{} = changeset} ->
            errors =
              Enum.map_join(
                Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end),
                "; ",
                fn
                  {:allowed_embed_domains, messages} -> Enum.join(messages, ", ")
                  {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}"
                end
              )

            Flash.error(dgettext("dashboard_embed", "Failed to save: %{errors}", errors: errors))
            {:noreply, socket}
        end

      {:deny, _retry_after} ->
        Logger.warning("Embed domain update rate limit exceeded", user_id: user_id)

        Flash.error(
          dgettext(
            "dashboard_embed",
            "Too many updates. Please wait a moment before trying again."
          )
        )

        {:noreply, socket}
    end
  end
end
