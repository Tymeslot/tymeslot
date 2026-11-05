defmodule TymeslotWeb.Dashboard.ThemeSettings.PageSettingsComponent do
  @moduledoc """
  The selected page's own settings, first on its view of the Theme screen:
  its address (to copy or open), the name and address of a booking page, the
  meeting types it lists, and deleting a booking page. A booking page that
  lists nothing it can offer is a draft (`BookingPages.published?/1`), which
  the heading marks and a note explains.

  `page` is nil for the profile's own page at `/<username>`, whose checklist
  works the meeting types' existing "unlisted" flag; on a booking page it works
  the page's listings (`BookingPages.set_meeting_type/3`). Either way a flip is
  a meeting type write, under the same rate limit as the meeting type screen's
  own switches, and sends the state it asks for (`phx-value-listed`), so it
  does what the host saw even when another tab changed the listing meanwhile.

  `read_only` is set for a booking page its owner may no longer change
  (`BookingPages.editable?/1`): its fields and switches are disabled, and
  only deleting it stays open.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.BookingPages
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Components.Dashboard.BookingPages.AddressPreview
  alias TymeslotWeb.Components.Dashboard.BookingPages.DeletePageModal
  alias TymeslotWeb.Dashboard.ThemeSettingsComponent
  alias TymeslotWeb.Live.Shared.Flash

  # A meeting type's description is shown beside its switch up to this long;
  # a longer one would push the switches apart.
  @short_description 80

  # Events that act on a named page. The main page's tab renders none of
  # their controls, so there they can only arrive hand-sent.
  @page_events ~w(validate_details save_details show_delete confirm_delete)

  # The two values a listing switch sends as `listed`.
  @listed_values ~w(true false)

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:read_only, fn -> false end)
     |> assign_new(:draft, fn -> false end)
     |> assign_new(:show_delete, fn -> false end)
     |> assign_new(:only_listed_here, fn -> [] end)
     |> refresh_details_form(socket.assigns[:page])
     |> load_listings()}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id} class="mb-12">
      <.section_header icon={if(@page, do: "hero-document-text", else: "hero-home")}>
        <span class="inline-flex flex-wrap items-center gap-2">
          <span>{page_title(@page)}</span>
          <.pill :if={@draft} tone={:warning} icon="hero-pencil-square-mini" data-testid="page-draft">
            {dgettext("dashboard_booking_pages", "Draft")}
          </.pill>
        </span>
      </.section_header>

      <.card padding={:lg} class="space-y-6">
        <p :if={@draft} class="text-token-sm text-tymeslot-600" data-testid="page-draft-note">
          {dgettext(
            "dashboard_booking_pages",
            "This page is a draft: visitors cannot open it yet. It goes live once it lists a meeting type that can be booked. Until then, only you can see it through Live Preview."
          )}
        </p>

        <%!-- A booking page's address is edited here, its whole link shown
        under the field; the main page's is its username, set on the profile,
        so it is only shown. --%>
        <.form
          :if={@page}
          for={@details_form}
          id={"#{@id}-details"}
          phx-change="validate_details"
          phx-submit="save_details"
          phx-target={@myself}
          class="space-y-4"
        >
          <%!-- A disabled fieldset disables every field in it without a
          `disabled` on each. --%>
          <fieldset
            disabled={@read_only}
            class="min-w-0 m-0 p-0 border-0 grid gap-4 md:grid-cols-2"
          >
            <.input
              field={@details_form[:name]}
              label={dgettext("dashboard_booking_pages", "Page name")}
              maxlength={BookingPageSchema.name_max_length()}
            >
              <:description>
                {dgettext(
                  "dashboard_booking_pages",
                  "For you only: it labels the page in your dashboard."
                )}
              </:description>
            </.input>
            <.input
              field={@details_form[:slug]}
              label={dgettext("dashboard_booking_pages", "Address")}
            >
              <:description>
                <AddressPreview.address_preview
                  id={"#{@id}-address-preview"}
                  username={@profile.username}
                  slug={@details_form[:slug].value}
                />
              </:description>
            </.input>
          </fieldset>
          <p class="text-token-xs text-tymeslot-500">
            {dgettext(
              "dashboard_booking_pages",
              "You can change the address at any time: the old one keeps leading to this page."
            )}
          </p>
          <div class="flex flex-wrap items-center gap-3">
            <.action_button type="submit" disabled={@read_only}>
              {dgettext("dashboard_booking_pages", "Save")}
            </.action_button>
            <.link_actions id={@id} url={page_url(@profile, @page)} draft={@draft} />
          </div>
        </.form>

        <div :if={!@page} class="space-y-2">
          <p class="label">{dgettext("dashboard_booking_pages", "Address")}</p>
          <div class="flex flex-wrap items-center gap-3">
            <code class="text-token-sm font-semibold text-tymeslot-700 break-all">
              {page_url(@profile, @page)}
            </code>
            <.link_actions id={@id} url={page_url(@profile, @page)} draft={@draft} />
          </div>
        </div>

        <fieldset disabled={@read_only} class="min-w-0 m-0 p-0 border-0 space-y-3">
          <p class="label">{dgettext("dashboard_booking_pages", "Meeting types on this page")}</p>
          <p :if={@meeting_types == []} class="text-token-sm text-tymeslot-500">
            {dgettext("dashboard_booking_pages", "No meeting types yet.")}
          </p>
          <%!-- Switches, as in the meeting type editor: each one writes at
          once, and a refused write leaves a switch showing what is stored,
          where a checkbox would stay ticked. Two columns on a wide screen, so
          a long list stays short. --%>
          <div class="grid gap-3 lg:grid-cols-2">
            <.setting_row
              :for={type <- @meeting_types}
              id={"#{@id}-type-#{type.id}"}
              control={:switch}
              label={type.name}
              description={type_description(type)}
              checked={listed?(@page, @memberships, type)}
              disabled={@read_only}
              on_change="toggle_type"
              target={@myself}
              phx-value-id={type.id}
              phx-value-listed={to_string(not listed?(@page, @memberships, type))}
            />
          </div>
        </fieldset>

        <div :if={@page} class="pt-4 border-t border-tymeslot-100">
          <.action_button
            type="button"
            variant={:danger}
            icon="hero-trash"
            phx-click="show_delete"
            phx-target={@myself}
          >
            {dgettext("dashboard_booking_pages", "Delete page")}
          </.action_button>
        </div>
      </.card>

      <DeletePageModal.delete_page_modal
        :if={@page}
        id={"#{@id}-delete"}
        show={@show_delete}
        address={"#{@profile.username}/#{@page.slug}"}
        main_address={@profile.username}
        only_listed_here={Enum.map(@only_listed_here, & &1.name)}
        on_cancel={JS.push("hide_delete", target: @myself)}
        on_confirm={JS.push("confirm_delete", target: @myself)}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :url, :string, required: true
  attr :draft, :boolean, required: true

  # Copying the link stays open on a draft, so it can be shared ahead of
  # going live; opening it waits until it is live.
  defp link_actions(assigns) do
    ~H"""
    <.action_button
      id={"#{@id}-copy"}
      type="button"
      variant={:secondary}
      icon="hero-clipboard-document"
      phx-hook="CopyOnClick"
      data-copy-text={@url}
      data-copy-feedback={dgettext("dashboard_common", "Scheduling link copied to clipboard!")}
    >
      {dgettext("dashboard_booking_pages", "Copy link")}
    </.action_button>
    <.action_link
      :if={not @draft}
      href={@url}
      target="_blank"
      rel="noopener noreferrer"
      variant={:secondary}
      icon="hero-arrow-top-right-on-square"
    >
      {dgettext("dashboard_booking_pages", "Open")}
    </.action_link>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event(event, _params, %{assigns: %{page: nil}} = socket) when event in @page_events,
    do: {:noreply, socket}

  def handle_event("toggle_type", %{"id" => id, "listed" => listed}, socket)
      when is_binary(id) and listed in @listed_values do
    user_id = socket.assigns.profile.user_id

    with_rate_limit(RateLimiter.check(:meeting_type_write, user_id), socket, fn ->
      do_toggle_type(socket, id, listed == "true", user_id)
    end)
  end

  # Sent by hand without an id or a `listed` it can read: ignored.
  def handle_event("toggle_type", _params, socket), do: {:noreply, socket}

  def handle_event("validate_details", %{"page" => params}, socket) do
    changeset = BookingPages.change_details(socket.assigns.page, params)
    {:noreply, assign(socket, :details_form, page_form(changeset, socket.assigns.id))}
  end

  def handle_event("save_details", %{"page" => params}, socket) do
    case BookingPages.update_details(socket.assigns.page, params) do
      {:ok, page} ->
        Flash.info(dgettext("dashboard_booking_pages", "Booking page saved"))

        {:noreply,
         socket
         |> assign(page: page, details_form: details_form(page, socket.assigns.id))
         |> push_patch(to: ThemeSettingsComponent.theme_path(page))}

      {:error, :not_found} ->
        Flash.error(dgettext("dashboard_booking_pages", "This booking page no longer exists."))
        {:noreply, push_patch(socket, to: ThemeSettingsComponent.theme_path(nil))}

      {:error, :upgrade_required} ->
        Flash.error(BookingPages.locked_message())
        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :details_form, page_form(changeset, socket.assigns.id))}
    end
  end

  def handle_event("show_delete", _params, socket) do
    {:noreply,
     assign(socket,
       show_delete: true,
       only_listed_here: BookingPages.only_listed_on(socket.assigns.page)
     )}
  end

  def handle_event("hide_delete", _params, socket),
    do: {:noreply, assign(socket, :show_delete, false)}

  def handle_event("confirm_delete", _params, socket) do
    case BookingPages.delete(socket.assigns.page) do
      {:ok, _page} ->
        Flash.info(dgettext("dashboard_booking_pages", "Booking page deleted"))

        {:noreply,
         socket
         |> assign(:show_delete, false)
         |> push_patch(to: ThemeSettingsComponent.theme_path(nil))}

      {:error, _reason} ->
        Flash.error(
          dgettext(
            "dashboard_booking_pages",
            "Could not delete the booking page. Please try again."
          )
        )

        {:noreply, assign(socket, :show_delete, false)}
    end
  end

  defp do_toggle_type(socket, id, listed?, user_id) do
    with {type_id, ""} <- Integer.parse(id),
         %{} = type <- MeetingTypes.get_meeting_type(type_id, user_id),
         :ok <- set_listed(socket.assigns.page, type, listed?) do
      send(self(), {:meeting_type_changed})
      Flash.info(dgettext("dashboard_booking_pages", "Booking page saved"))
      {:noreply, load_listings(socket)}
    else
      {:error, :upgrade_required} ->
        Flash.error(BookingPages.locked_message())
        {:noreply, socket}

      _not_found_or_failed ->
        Flash.error(
          dgettext(
            "dashboard_booking_pages",
            "Could not update this page's meeting types. Please try again."
          )
        )

        {:noreply, socket}
    end
  end

  defp load_listings(socket) do
    profile = socket.assigns.profile

    socket
    |> assign(:meeting_types, MeetingTypes.get_all_meeting_types(profile.user_id))
    |> assign(:memberships, BookingPages.memberships(profile.id))
  end

  # The form follows the page when it changes under it (renamed in another
  # tab, or saved here), and keeps what the host is typing otherwise.
  defp refresh_details_form(socket, previous_page) do
    page = socket.assigns.page

    if Map.has_key?(socket.assigns, :details_form) and same_details?(previous_page, page),
      do: socket,
      else: assign(socket, :details_form, details_form(page, socket.assigns.id))
  end

  defp same_details?(%{name: name, slug: slug}, %{name: name, slug: slug}), do: true
  defp same_details?(nil, nil), do: true
  defp same_details?(_previous, _page), do: false

  defp details_form(nil, _id), do: nil

  defp details_form(page, id),
    do: page |> BookingPages.change_details(%{}) |> Map.put(:action, nil) |> page_form(id)

  # Its own input ids, apart from the new-page dialog's above it.
  defp page_form(changeset, id), do: to_form(changeset, as: :page, id: "#{id}-details")

  # The profile's own page is the type's existing "unlisted" flag.
  defp set_listed(nil, type, listed?) do
    case MeetingTypes.set_private(type, not listed?) do
      {:ok, _type} -> :ok
      {:error, _reason} -> :error
    end
  end

  defp set_listed(page, type, listed?), do: BookingPages.set_meeting_type(page, type.id, listed?)

  defp listed?(nil, _memberships, type), do: not type.is_private

  defp listed?(page, memberships, type),
    do: MapSet.member?(Map.get(memberships, type.id, MapSet.new()), page.id)

  # Its length, then its description when short, then why it is not offered.
  defp type_description(type) do
    [
      dgettext("dashboard_booking_pages", "%{minutes} min", minutes: type.duration_minutes),
      short_description(type.description),
      inactive_note(type)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp short_description(description) when is_binary(description) do
    trimmed = String.trim(description)

    if trimmed != "" and String.length(trimmed) <= @short_description,
      do: trimmed,
      else: nil
  end

  defp short_description(_none), do: nil

  defp inactive_note(%{is_active: true}), do: nil

  defp inactive_note(_type),
    do:
      dgettext(
        "dashboard_booking_pages",
        "Inactive: not offered anywhere until you turn it back on."
      )

  defp page_title(nil), do: dgettext("dashboard_booking_pages", "Main page")
  defp page_title(%BookingPageSchema{name: name}), do: name

  defp page_url(profile, nil), do: UrlBuilder.booking_url(profile.username)

  defp page_url(profile, page),
    do:
      UrlBuilder.booking_url(
        BookingPages.public_address(BookingPages.apply_to_profile(profile, page))
      )

  defp with_rate_limit({:error, :rate_limited, message}, socket, _action) do
    Flash.error(message)
    {:noreply, socket}
  end

  defp with_rate_limit(:ok, _socket, action), do: action.()
end
