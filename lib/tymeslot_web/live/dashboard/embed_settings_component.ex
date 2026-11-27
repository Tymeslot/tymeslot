defmodule TymeslotWeb.Live.Dashboard.EmbedSettingsComponent do
  @moduledoc """
  Dashboard component for embedding options.
  Shows users different ways to embed their booking page with live previews.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.BookingPages
  alias Tymeslot.Locales
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Themes.Catalog
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Components.CoreComponents.Navigation
  alias TymeslotWeb.Dashboard.BookingLinkShare
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.Helpers
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.LivePreview
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.OptionsGrid
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.SecuritySection
  alias TymeslotWeb.Live.Scheduling.PreviewToken
  alias TymeslotWeb.Live.Shared.RateLimit

  require Logger

  @valid_embed_types Helpers.valid_embed_types()
  @valid_tabs Helpers.valid_tabs()

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    profile = assigns.profile
    integration_status = assigns[:integration_status] || %{}
    base_url = Endpoint.url()

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
      |> assign(:is_ready, is_ready)
      |> assign(:error_reason, error_reason)
      |> assign(:allowed_domains, allowed_domains)
      |> assign_new(:selected_embed_type, fn -> "inline" end)
      |> assign_new(:embed_script_url, fn -> ~p"/embed.js" end)
      |> assign_new(:active_tab, fn -> "options" end)
      |> assign_new(:embed_layout, fn -> "column" end)
      |> assign_new(:embed_locale, fn -> "" end)
      |> assign_new(:initial_height, fn -> nil end)
      |> assign_new(:max_width, fn -> nil end)
      |> assign_new(:prefill_name, fn -> "" end)
      |> assign_new(:prefill_email, fn -> "" end)
      # Minted once per mounted component, not per update: the hook re-creates
      # the iframe whenever a dataset value it watches changes, so a token that
      # churned would throw the organiser back to step one mid-preview. It
      # outliving the component is the failure we want — an hour-old preview
      # says so plainly rather than silently booking for real.
      |> assign_new(:preview_token, fn -> PreviewToken.sign(assigns.current_user.id) end)
      |> assign_targets(profile)
      |> select_target(assigns[:params] || %{})

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div>
      <.dashboard_page icon="hero-code-bracket" title={dgettext("dashboard_common", "Embed & Share")}>
        <p class="text-tymeslot-600 mb-6">
          {dgettext(
            "dashboard_embed",
            "Add your booking page to any website. Choose the option that works best for you."
          )}
        </p>

        <div class="space-y-6">
          <div
            :if={@pages != [] or @meeting_types != []}
            class="grid grid-cols-1 md:grid-cols-2 gap-4"
          >
            <.form
              :if={@pages != []}
              for={to_form(%{}, as: :embed_page)}
              id="embed-page-picker"
              phx-change="select_page"
              phx-target={@myself}
              novalidate
            >
              <.select
                id="embed-page-select"
                name="page"
                label={dgettext("dashboard_embed", "Booking page")}
                value={if(@selected_page_id, do: to_string(@selected_page_id), else: "profile")}
                options={page_options(@profile, @pages)}
              />
            </.form>

            <.form
              :if={@meeting_types != []}
              for={to_form(%{}, as: :embed_meeting_type)}
              id="embed-meeting-type-picker"
              phx-change="select_meeting_type"
              phx-target={@myself}
              novalidate
            >
              <.select
                id="embed-meeting-type-select"
                name="type"
                label={dgettext("dashboard_embed", "Meeting type")}
                value={if(@selected_type, do: to_string(@selected_type.id), else: "overview")}
                options={meeting_type_options(assigns)}
              />
              <%!-- Below the field, not in its description slot, so the two
                   pickers' fields stay level. --%>
              <p :if={@invitation_only_types?} class="mt-2 text-token-xs text-tymeslot-600">
                {dgettext(
                  "dashboard_embed",
                  "Invitation-only types are shared from their invitations."
                )}
              </p>
              <div
                :if={@selected_type && @selected_type.is_private}
                id="embed-private-type-note"
                class="mt-2 flex items-start gap-2 text-token-xs text-tymeslot-700"
              >
                <.pill tone={:neutral} size={:sm} uppercase>
                  {dgettext("dashboard_embed", "Unlisted")}
                </.pill>
                <span>
                  {dgettext(
                    "dashboard_embed",
                    "Hidden from your booking pages, but anyone with this snippet or link can book it."
                  )}
                </span>
              </div>
            </.form>
          </div>

          <.tab_bar
            id="embed-settings-tabs"
            active_tab={@active_tab}
            target={@myself}
            aria_label={dgettext("dashboard_embed", "Embed settings")}
            tabs={[
              %{
                id: "options",
                label: dgettext("dashboard_embed", "Embed Options"),
                icon: "hero-code-bracket"
              },
              %{
                id: "security",
                label: dgettext("dashboard_embed", "Security"),
                icon: "hero-lock-closed"
              },
              %{
                id: "preview",
                label: dgettext("dashboard_embed", "Live Preview"),
                icon: "hero-video-camera"
              }
            ]}
          />

          <.embed_panel id="options" active_tab={@active_tab}>
            <OptionsGrid.options_grid
              selected_embed_type={@selected_embed_type}
              username={@username}
              meeting_type={@meeting_type}
              base_url={@base_url}
              booking_url={@booking_url}
              embed_layout={@embed_layout}
              embed_locale={@embed_locale}
              initial_height={@initial_height}
              max_width={@max_width}
              prefill_name={@prefill_name}
              prefill_email={@prefill_email}
              myself={@myself}
            />
          </.embed_panel>

          <.embed_panel id="security" active_tab={@active_tab}>
            <SecuritySection.security_section
              allowed_domains={@allowed_domains}
              myself={@myself}
            />
          </.embed_panel>

          <.embed_panel id="preview" active_tab={@active_tab}>
            <LivePreview.live_preview
              selected_embed_type={@selected_embed_type}
              username={@address}
              base_url={@base_url}
              preview_token={@preview_token}
              embed_script_url={@embed_script_url}
              embed_layout={@embed_layout}
              embed_locale={@embed_locale}
              initial_height={@initial_height}
              max_width={@max_width}
              is_ready={@is_ready}
              error_reason={@error_reason}
              myself={@myself}
            />
          </.embed_panel>
        </div>
      </.dashboard_page>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :active_tab, :string, required: true
  slot :inner_block, required: true

  # Every panel stays rendered and only the selected one shows, so the live
  # preview keeps its loaded frame while another tab is open.
  defp embed_panel(assigns) do
    ~H"""
    <div
      role="tabpanel"
      id={Navigation.panel_id("embed-settings-tabs", @id)}
      aria-labelledby={Navigation.tab_id("embed-settings-tabs", @id)}
      hidden={@active_tab != @id}
      class="animate-in fade-in slide-in-from-bottom-4 duration-500"
    >
      {render_slot(@inner_block)}
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

    socket = BookingLinkShare.record(socket, socket.assigns.profile, "embed")
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

    locale =
      case params["locale"] do
        "" ->
          ""

        v when is_binary(v) ->
          if v in Locales.supported_codes(), do: v, else: socket.assigns.embed_locale

        _other ->
          socket.assigns.embed_locale
      end

    {:noreply,
     socket
     |> assign(:embed_layout, layout)
     |> assign(:embed_locale, locale)
     |> assign(:initial_height, blank_to_nil(params["initial_height"]))
     |> assign(:max_width, blank_to_nil(params["max_width"]))}
  end

  def handle_event("update_customisation", _params, socket),
    do: reject_invalid_event("update_customisation", socket)

  # The visitor details the link snippet carries. Kept as typed, so the fields
  # show what the organiser entered; `Helpers.link_prefill/1` decides what
  # reaches the link.
  def handle_event("update_link_prefill", %{"prefill" => %{} = params}, socket) do
    {:noreply,
     assign(socket,
       prefill_name: typed_text(params["name"]),
       prefill_email: typed_text(params["email"])
     )}
  end

  def handle_event("update_link_prefill", _params, socket),
    do: reject_invalid_event("update_link_prefill", socket)

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

  # The choice goes into the URL (`?page=<id>`, or `?type=<id>` for a meeting
  # type), so a reload keeps it; the patch comes back through `update/2`. A
  # page chosen here opens on its overview, whatever type was chosen before.
  def handle_event("select_page", %{"page" => "profile"}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/dashboard/embed")}

  def handle_event("select_page", %{"page" => id}, socket) when is_binary(id) do
    case find_by_id(socket.assigns.pages, id) do
      nil -> reject_invalid_event("select_page", socket)
      page -> {:noreply, push_patch(socket, to: ~p"/dashboard/embed?#{[page: page.id]}")}
    end
  end

  def handle_event("select_page", _params, socket),
    do: reject_invalid_event("select_page", socket)

  # The overview keeps the page the chosen type lived on.
  def handle_event("select_meeting_type", %{"type" => "overview"}, socket) do
    query = if page_id = socket.assigns.selected_page_id, do: [page: page_id], else: []
    {:noreply, push_patch(socket, to: ~p"/dashboard/embed?#{query}")}
  end

  def handle_event("select_meeting_type", %{"type" => id}, socket) when is_binary(id) do
    case find_by_id(socket.assigns.meeting_types, id) do
      nil -> reject_invalid_event("select_meeting_type", socket)
      type -> {:noreply, push_patch(socket, to: ~p"/dashboard/embed?#{[type: type.id]}")}
    end
  end

  def handle_event("select_meeting_type", _params, socket),
    do: reject_invalid_event("select_meeting_type", socket)

  # What a snippet can open on: the profile's pages, and every meeting type
  # with a public address with the page that address lives under. An
  # invitation-only type has none, so it is not offered.
  defp assign_targets(socket, profile) do
    pages = BookingPages.list(profile.id)

    {invitation_only, types} =
      profile.user_id
      |> MeetingTypes.get_bookable_meeting_types()
      |> Enum.split_with(& &1.invitation_only)

    homes =
      BookingPages.meeting_type_homes(profile, types, pages, BookingPages.memberships(profile.id))

    assign(socket,
      pages: pages,
      meeting_types: types,
      type_homes: homes,
      invitation_only_types?: invitation_only != []
    )
  end

  # A chosen type decides the page, its home, so the two pickers never
  # disagree. A `type` or `page` the profile does not have (deleted since the
  # link was copied) shows the main page's overview.
  defp select_target(socket, params) do
    case find_by_id(socket.assigns.meeting_types, params["type"]) do
      nil ->
        page = find_by_id(socket.assigns.pages, params["page"])

        socket
        |> assign(selected_type: nil, selected_page_id: page && page.id)
        |> assign_page_target(nil)

      type ->
        %{page: page, path: path} = Map.fetch!(socket.assigns.type_homes, type.id)

        socket
        |> assign(selected_type: type, selected_page_id: page && page.id)
        |> assign_page_target({MeetingTypes.effective_slug(type), path})
    end
  end

  # The snippet, link and preview follow the chosen page and type, and take
  # the page's theme. The snippets name the page's address in place of the
  # username and the type by its slug (`data-meeting-type`), as someone
  # writing one by hand would; the link and the preview open the type's
  # address, the one `BookingPages.meeting_type_homes/4` gives, which is
  # that page's. Allowed embed domains stay the profile's.
  defp assign_page_target(socket, type_target) do
    %{profile: profile, pages: pages, selected_page_id: page_id} = socket.assigns

    shown =
      case Enum.find(pages, &(&1.id == page_id)) do
        nil -> profile
        page -> BookingPages.apply_to_profile(profile, page)
      end

    page_address = BookingPages.public_address(shown)

    {meeting_type, address} =
      case type_target do
        {slug, "/" <> address} -> {slug, address}
        nil -> {nil, page_address}
      end

    socket
    |> assign(username: page_address, meeting_type: meeting_type, address: address)
    |> assign(:theme_id, shown.booking_theme || Catalog.default_id())
    |> assign(:booking_url, UrlBuilder.booking_url(address))
  end

  defp find_by_id(records, id) when is_binary(id),
    do: Enum.find(records, &(to_string(&1.id) == id))

  defp find_by_id(_records, _id), do: nil

  defp page_options(profile, pages) do
    [
      {"/" <> (profile.username || ""), "profile"}
      | Enum.map(pages, &{BookingPages.name_and_address(&1, profile.username), to_string(&1.id)})
    ]
  end

  # The overview first, then each type under the page its address lives on,
  # the profile's own page first and the rest in `page_options/2`'s order.
  defp meeting_type_options(%{profile: profile, pages: pages} = assigns) do
    by_page =
      Enum.group_by(assigns.meeting_types, fn type ->
        case assigns.type_homes[type.id].page do
          nil -> nil
          page -> page.id
        end
      end)

    groups =
      for {label, page_id} <- [
            {"/" <> (profile.username || ""), nil}
            | Enum.map(pages, &{BookingPages.name_and_address(&1, profile.username), &1.id})
          ],
          types = by_page[page_id],
          do: {label, Enum.map(types, &{meeting_type_label(&1), to_string(&1.id)})}

    [{dgettext("dashboard_embed", "All meeting types (overview)"), "overview"} | groups]
  end

  defp meeting_type_label(%{is_private: true, name: name}),
    do: dgettext("dashboard_embed", "%{name} (unlisted)", name: name)

  defp meeting_type_label(%{name: name}), do: name

  defp typed_text(value) when is_binary(value), do: value
  defp typed_text(_value), do: ""

  defp reject_invalid_event(event_name, socket) do
    Logger.warning("handle_event received invalid or missing parameter", event: event_name)
    {:noreply, socket}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: value

  defp perform_domain_update(socket, domains_payload, success_message) do
    user_id = socket.assigns.current_user.id

    # The limiter's own message is English; this one is translated.
    RateLimit.with_rate_limit(
      RateLimiter.check(:embed_domain_update, user_id),
      socket,
      fn ->
        case Profiles.update_allowed_embed_domains(socket.assigns.profile, domains_payload) do
          {:ok, updated_profile} ->
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
                  {:allowed_embed_domains, messages} ->
                    gettext_comment(
                      "The separator between two problems with the domains entered, " <>
                        "as in: Invalid domain, Invalid domain format"
                    )

                    Enum.join(messages, dpgettext("dashboard_embed", "list separator", ", "))

                  {field, messages} ->
                    "#{field}: #{Enum.join(messages, ", ")}"
                end
              )

            Flash.error(dgettext("dashboard_embed", "Failed to save: %{errors}", errors: errors))
            {:noreply, socket}
        end
      end,
      message:
        dgettext("dashboard_embed", "Too many updates. Please wait a moment before trying again.")
    )
  end
end
