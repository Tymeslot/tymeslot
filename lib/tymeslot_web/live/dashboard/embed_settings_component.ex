defmodule TymeslotWeb.Live.Dashboard.EmbedSettingsComponent do
  @moduledoc """
  Dashboard component for embedding options.
  Shows users different ways to embed their booking page with live previews.
  """
  use TymeslotWeb, :live_component

  alias Ecto.Changeset
  alias Tymeslot.Profiles
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.Security
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.Helpers
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.LivePreview
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.OptionsGrid
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.SecuritySection

  require Logger

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

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <!-- Header -->
      <.section_header
        icon={:code}
        title="Embed & Share"
        class="mb-4"
      />

      <p class="text-tymeslot-600 mb-6">
        Add your booking page to any website. Choose the option that works best for you.
      </p>

      <!-- Tabbed Interface -->
      <.tabs active_tab={@active_tab} target={@myself}>
        <:tab id="options" label="Embed Options" icon={:code}>
          <OptionsGrid.options_grid
            selected_embed_type={@selected_embed_type}
            username={@username}
            base_url={@base_url}
            booking_url={@booking_url}
            myself={@myself}
          />
        </:tab>

        <:tab id="security" label="Security" icon={:lock}>
          <SecuritySection.security_section
            allowed_domains={@allowed_domains}
            myself={@myself}
          />
        </:tab>

        <:tab id="preview" label="Live Preview" icon={:video}>
          <LivePreview.live_preview
            selected_embed_type={@selected_embed_type}
            username={@username}
            base_url={@base_url}
            embed_script_url={@embed_script_url}
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
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("copy_code", %{"type" => type}, socket) do
    code = Helpers.embed_code(type, socket.assigns)

    socket = push_event(socket, "copy-to-clipboard", %{text: code})
    Flash.info("Code copied to clipboard!")

    {:noreply, socket}
  end

  def handle_event("select_embed_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :selected_embed_type, type)}
  end

  def handle_event("save_embed_domains", %{"allowed_domains" => domains_str}, socket) do
    # Split and clean input
    input_domains =
      domains_str
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if input_domains == [] do
      {:noreply, socket}
    else
      # Validate each domain using centralized security validation
      validation_results = Enum.map(input_domains, &Security.validate_domain/1)
      errors = Enum.filter(validation_results, &match?({:error, _reason}, &1))

      if errors != [] do
        {:error, reason} = List.first(errors)
        Flash.error(reason)
        {:noreply, socket}
      else
        valid_domains = Enum.map(validation_results, fn {:ok, d} -> d end)

        existing_domains =
          case socket.assigns.allowed_domains do
            ["none"] -> []
            list -> list
          end

        # Check for duplicates against existing
        duplicates = Enum.filter(valid_domains, fn domain -> domain in existing_domains end)

        if duplicates != [] do
          Flash.error("Already whitelisted: #{Enum.join(duplicates, ", ")}")
          {:noreply, socket}
        else
          updated_domains = existing_domains ++ valid_domains

          socket = push_event(socket, "reset-form", %{id: "embed-domains-form"})

          perform_domain_update(socket, updated_domains, "Security settings saved successfully!")
        end
      end
    end
  end

  def handle_event("remove_domain", %{"domain" => domain}, socket) do
    updated_domains = Enum.reject(socket.assigns.allowed_domains, &(&1 == domain))
    updated_domains = if updated_domains == [], do: ["none"], else: updated_domains

    perform_domain_update(socket, updated_domains, "Domain removed successfully")
  end

  def handle_event("clear_embed_domains", _params, socket) do
    perform_domain_update(socket, ["none"], "Embedding is now disabled")
  end

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

            {:noreply,
             socket
             |> assign(:profile, updated_profile)
             |> assign(:allowed_domains, updated_profile.allowed_embed_domains || [])
             |> then(fn s ->
               Flash.info(success_message)
               s
             end)}

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

            Flash.error("Failed to save: #{errors}")
            {:noreply, socket}
        end

      {:deny, _retry_after} ->
        Logger.warning("Embed domain update rate limit exceeded", user_id: user_id)

        Flash.error("Too many updates. Please wait a moment before trying again.")
        {:noreply, socket}
    end
  end
end
