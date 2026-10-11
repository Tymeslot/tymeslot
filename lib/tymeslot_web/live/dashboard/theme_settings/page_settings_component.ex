defmodule TymeslotWeb.Dashboard.ThemeSettings.PageSettingsComponent do
  @moduledoc """
  The selected page's own settings on the Theme screen: its address (to copy or
  open), the name and address of a booking page, the meeting types it lists,
  and deleting a booking page.

  `page` is nil for the profile's own page at `/<username>`, whose checklist
  works the meeting types' existing "unlisted" flag; on a booking page it works
  the page's listings (`BookingPages.set_meeting_type/3`). Either way a flip is
  a meeting type write, under the same rate limit as the meeting type screen's
  own switches.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.BookingPages
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Components.CoreComponents.Modal
  alias TymeslotWeb.Dashboard.ThemeSettingsComponent
  alias TymeslotWeb.Live.Shared.Flash

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:show_delete, fn -> false end)
     |> assign_new(:details_form, fn -> details_form(assigns.page, assigns.id) end)
     |> load_listings()}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id} class="mt-16">
      <.section_header icon="hero-globe-alt" title={dgettext("dashboard_appearance", "This page")} />

      <.card padding={:lg} class="space-y-8">
        <div class="space-y-2">
          <p class="label">{dgettext("dashboard_appearance", "Address")}</p>
          <div class="flex flex-wrap items-center gap-3">
            <code class="text-token-sm font-semibold text-tymeslot-700 break-all">
              {page_url(@profile, @page)}
            </code>
            <.action_button
              id={"#{@id}-copy"}
              type="button"
              variant={:secondary}
              icon="hero-clipboard-document"
              phx-hook="CopyOnClick"
              data-copy-text={page_url(@profile, @page)}
              data-copy-feedback={
                dgettext("dashboard_common", "Scheduling link copied to clipboard!")
              }
            >
              {dgettext("dashboard_appearance", "Copy link")}
            </.action_button>
            <.action_link
              href={page_url(@profile, @page)}
              target="_blank"
              rel="noopener noreferrer"
              variant={:secondary}
              icon="hero-arrow-top-right-on-square"
            >
              {dgettext("dashboard_appearance", "Open")}
            </.action_link>
          </div>
        </div>

        <.form
          :if={@page}
          for={@details_form}
          id={"#{@id}-details"}
          phx-change="validate_details"
          phx-submit="save_details"
          phx-target={@myself}
          class="space-y-4"
        >
          <.input
            field={@details_form[:name]}
            label={dgettext("dashboard_appearance", "Page name")}
            maxlength={BookingPageSchema.name_max_length()}
          />
          <.input field={@details_form[:slug]} label={dgettext("dashboard_appearance", "Address")} />
          <p class="text-token-sm text-tymeslot-500">
            {dgettext(
              "dashboard_appearance",
              "Changing the address stops the old one working at once. Links in emails you have already sent keep working."
            )}
          </p>
          <.action_button type="submit">{dgettext("dashboard_appearance", "Save")}</.action_button>
        </.form>

        <div class="space-y-3">
          <p class="label">{dgettext("dashboard_appearance", "Meeting types on this page")}</p>
          <p :if={@meeting_types == []} class="text-token-sm text-tymeslot-500">
            {dgettext("dashboard_appearance", "No meeting types yet.")}
          </p>
          <%!-- Switches, as in the meeting type editor: each one writes at
          once, and a refused write leaves a switch showing what is stored,
          where a checkbox would stay ticked. --%>
          <.setting_row
            :for={type <- @meeting_types}
            id={"#{@id}-type-#{type.id}"}
            control={:switch}
            label={type.name}
            description={inactive_note(type)}
            checked={listed?(@page, @memberships, type)}
            on_change="toggle_type"
            target={@myself}
            phx-value-id={type.id}
          />
        </div>

        <div :if={@page} class="pt-4 border-t border-tymeslot-100">
          <.action_button
            type="button"
            variant={:danger}
            icon="hero-trash"
            phx-click="show_delete"
            phx-target={@myself}
          >
            {dgettext("dashboard_appearance", "Delete page")}
          </.action_button>
        </div>
      </.card>

      <Modal.confirm_modal
        :if={@page}
        id={"#{@id}-delete"}
        show={@show_delete}
        title={dgettext("dashboard_appearance", "Delete booking page")}
        confirm_label={dgettext("dashboard_appearance", "Delete page")}
        on_cancel={JS.push("hide_delete", target: @myself)}
        on_confirm={JS.push("confirm_delete", target: @myself)}
      >
        <p>
          {dgettext(
            "dashboard_appearance",
            "Delete %{address}? Bookings made through it keep working and show your main page's look. Its colours and uploaded backgrounds are removed.",
            address: "/" <> @page.slug
          )}
        </p>
      </Modal.confirm_modal>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_type", %{"id" => id}, socket) do
    user_id = socket.assigns.profile.user_id

    with_rate_limit(RateLimiter.check_meeting_type_write_rate_limit(user_id), socket, fn ->
      do_toggle_type(socket, id, user_id)
    end)
  end

  def handle_event("validate_details", %{"page" => params}, socket) do
    changeset = BookingPages.change_details(socket.assigns.page, params)
    {:noreply, assign(socket, :details_form, page_form(changeset, socket.assigns.id))}
  end

  def handle_event("save_details", %{"page" => params}, socket) do
    case BookingPages.update_details(socket.assigns.page, params) do
      {:ok, page} ->
        Flash.info(dgettext("dashboard_appearance", "Booking page saved"))

        {:noreply,
         socket
         |> assign(page: page, details_form: details_form(page, socket.assigns.id))
         |> push_patch(to: ThemeSettingsComponent.theme_path(page))}

      {:error, :not_found} ->
        Flash.error(dgettext("dashboard_appearance", "This booking page no longer exists."))
        {:noreply, push_patch(socket, to: ThemeSettingsComponent.theme_path(nil))}

      {:error, changeset} ->
        {:noreply, assign(socket, :details_form, page_form(changeset, socket.assigns.id))}
    end
  end

  def handle_event("show_delete", _params, socket),
    do: {:noreply, assign(socket, :show_delete, true)}

  def handle_event("hide_delete", _params, socket),
    do: {:noreply, assign(socket, :show_delete, false)}

  def handle_event("confirm_delete", _params, socket) do
    case BookingPages.delete(socket.assigns.page) do
      {:ok, _page} ->
        Flash.info(dgettext("dashboard_appearance", "Booking page deleted"))

        {:noreply,
         socket
         |> assign(:show_delete, false)
         |> push_patch(to: ThemeSettingsComponent.theme_path(nil))}

      {:error, _reason} ->
        Flash.error(
          dgettext("dashboard_appearance", "Could not delete the booking page. Please try again.")
        )

        {:noreply, assign(socket, :show_delete, false)}
    end
  end

  defp do_toggle_type(socket, id, user_id) do
    with {type_id, ""} <- Integer.parse(id),
         %{} = type <- MeetingTypes.get_meeting_type(type_id, user_id),
         :ok <- toggle(socket.assigns.page, socket.assigns.memberships, type) do
      send(self(), {:meeting_type_changed})
      Flash.info(dgettext("dashboard_appearance", "Booking page saved"))
      {:noreply, load_listings(socket)}
    else
      _not_found_or_failed ->
        Flash.error(
          dgettext(
            "dashboard_appearance",
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

  defp details_form(nil, _id), do: nil

  defp details_form(page, id),
    do: page |> BookingPages.change_details(%{}) |> Map.put(:action, nil) |> page_form(id)

  # Its own input ids, apart from the new-page dialog's above it.
  defp page_form(changeset, id), do: to_form(changeset, as: :page, id: "#{id}-details")

  # The profile's own page is the type's existing "unlisted" flag.
  defp toggle(nil, _memberships, type) do
    case MeetingTypes.set_private(type, !type.is_private) do
      {:ok, _type} -> :ok
      {:error, _reason} -> :error
    end
  end

  defp toggle(page, memberships, type),
    do: BookingPages.set_meeting_type(page, type.id, not listed?(page, memberships, type))

  defp listed?(nil, _memberships, type), do: not type.is_private

  defp listed?(page, memberships, type),
    do: MapSet.member?(Map.get(memberships, type.id, MapSet.new()), page.id)

  defp inactive_note(%{is_active: true}), do: nil

  defp inactive_note(_type),
    do:
      dgettext(
        "dashboard_appearance",
        "Inactive: not offered anywhere until you turn it back on."
      )

  defp page_url(profile, nil), do: UrlBuilder.booking_url(profile.username)
  defp page_url(_profile, page), do: UrlBuilder.booking_url(page.slug)

  defp with_rate_limit({:error, :rate_limited, message}, socket, _action) do
    Flash.error(message)
    {:noreply, socket}
  end

  defp with_rate_limit(:ok, _socket, action), do: action.()
end
