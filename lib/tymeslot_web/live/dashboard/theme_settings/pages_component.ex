defmodule TymeslotWeb.Dashboard.ThemeSettings.PagesComponent do
  @moduledoc """
  The Theme screen's page tabs: the profile's own page at `/<username>` first,
  then each booking page, then the button that opens the new-page dialog.

  The selection lives in the URL (`?page=<id>`), so a tab is a patch link and
  every editor on the screen follows it.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Ecto.Changeset
  alias Phoenix.LiveView.JS
  alias Tymeslot.BookingPages
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias TymeslotWeb.Components.CoreComponents.Modal
  alias TymeslotWeb.Dashboard.ThemeSettingsComponent
  alias TymeslotWeb.Live.Shared.Flash

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:can_create, length(assigns.pages) < BookingPages.max_pages())
     |> assign_new(:show_new_page, fn -> false end)
     |> assign_new(:slug_touched?, fn -> false end)
     |> assign_new(:form, fn -> new_form(assigns.profile, %{}, nil) end)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="mb-10 space-y-3">
      <.tab_bar
        id="booking-page-tabs"
        overflow={:wrap}
        aria_label={dgettext("dashboard_appearance", "Booking pages")}
        active_tab={active_tab(@selected_page)}
        tabs={tabs(@profile, @pages)}
      >
        <:trailing>
          <%!-- Greyed out at the cap rather than removed, as the schedule
          switcher's button is: a ceiling should read as a ceiling. --%>
          <button
            type="button"
            disabled={not @can_create}
            phx-click={@can_create && "show_new_page"}
            phx-target={@myself}
            title={if(not @can_create, do: limit_message())}
            data-testid="new-booking-page"
            class={[
              "flex items-center gap-2 px-4 py-3 rounded-token-xl font-bold text-token-sm border-2 border-dashed transition-all duration-300",
              if(@can_create,
                do: "text-tymeslot-600 border-tymeslot-300 hover:border-tymeslot-400 hover:bg-white",
                else: "text-tymeslot-400 border-tymeslot-200 cursor-not-allowed"
              )
            ]}
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            <span>{dgettext("dashboard_appearance", "New page")}</span>
          </button>
        </:trailing>
      </.tab_bar>

      <p :if={not @can_create} class="text-token-sm text-tymeslot-400 font-medium">
        {limit_message()}
      </p>

      <Modal.modal
        id="new-booking-page-modal"
        show={@show_new_page}
        on_cancel={JS.push("hide_new_page", target: @myself)}
      >
        <:header>{dgettext("dashboard_appearance", "New booking page")}</:header>

        <.form
          for={@form}
          id="new-booking-page-form"
          phx-change="validate_new_page"
          phx-submit="create_page"
          phx-target={@myself}
          class="space-y-6"
        >
          <.input
            field={@form[:name]}
            label={dgettext("dashboard_appearance", "Page name")}
            maxlength={BookingPageSchema.name_max_length()}
          />
          <.input field={@form[:slug]} label={dgettext("dashboard_appearance", "Address")} />
          <p class="text-token-sm text-tymeslot-500">
            {dgettext(
              "dashboard_appearance",
              "The page starts with your main page's theme and colours, its own texts switched off, and no meeting types."
            )}
          </p>
          <div class="flex justify-end gap-3">
            <.action_button
              type="button"
              variant={:secondary}
              phx-click="hide_new_page"
              phx-target={@myself}
            >
              {dgettext("dashboard_appearance", "Cancel")}
            </.action_button>
            <.action_button type="submit">
              {dgettext("dashboard_appearance", "Create page")}
            </.action_button>
          </div>
        </.form>
      </Modal.modal>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("show_new_page", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_page, true)
     |> assign(:slug_touched?, false)
     |> assign(:form, new_form(socket.assigns.profile, %{}, nil))}
  end

  def handle_event("hide_new_page", _params, socket),
    do: {:noreply, assign(socket, :show_new_page, false)}

  # The address follows the name until the host edits the address itself.
  def handle_event("validate_new_page", %{"page" => params} = event, socket) do
    touched? = socket.assigns.slug_touched? or event["_target"] == ["page", "slug"]
    params = if touched?, do: params, else: Map.put(params, "slug", slug_from(params["name"]))

    {:noreply,
     socket
     |> assign(:slug_touched?, touched?)
     |> assign(:form, new_form(socket.assigns.profile, params, :validate))}
  end

  def handle_event("create_page", %{"page" => params}, socket) do
    case BookingPages.create(socket.assigns.profile, params) do
      {:ok, page} ->
        Flash.info(dgettext("dashboard_appearance", "Booking page created"))

        {:noreply,
         socket
         |> assign(:show_new_page, false)
         |> push_patch(to: ThemeSettingsComponent.theme_path(page))}

      {:error, :limit_reached} ->
        Flash.error(limit_message())
        {:noreply, assign(socket, :show_new_page, false)}

      {:error, %Changeset{data: %BookingPageSchema{}} = changeset} ->
        {:noreply, assign(socket, :form, page_form(changeset))}

      # The database refused a copy of the main page's colours, so nothing was
      # created. The changeset is the colours', which this form has no fields
      # for.
      {:error, colours} ->
        Logger.error("Could not copy the main page's colours to a new booking page",
          profile_id: socket.assigns.profile.id,
          reason: LogFormat.reason(colours)
        )

        Flash.error(
          dgettext("dashboard_appearance", "Could not create the booking page. Please try again.")
        )

        {:noreply, socket}
    end
  end

  defp new_form(profile, params, action) do
    profile
    |> BookingPages.change_new(params)
    |> Map.put(:action, action)
    |> page_form()
  end

  # Its own input ids, apart from the page details form further down.
  defp page_form(changeset), do: to_form(changeset, as: :page, id: "new-booking-page")

  # German letters are spelt out as an address would be typed (Prüfung →
  # pruefung); any other accent is dropped (Café → cafe).
  defp slug_from(name) do
    (name || "")
    |> String.downcase()
    |> String.normalize(:nfc)
    |> String.replace(["ä", "ö", "ü", "ß"], &spelt_out/1)
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp spelt_out("ä"), do: "ae"
  defp spelt_out("ö"), do: "oe"
  defp spelt_out("ü"), do: "ue"
  defp spelt_out("ß"), do: "ss"

  defp tabs(profile, pages) do
    profile_tab = tab("profile", "/" <> (profile.username || ""), nil)
    [profile_tab | Enum.map(pages, &tab(to_string(&1.id), BookingPages.name_and_address(&1), &1))]
  end

  defp tab(id, label, page),
    do: %{id: id, label: label, patch: ThemeSettingsComponent.theme_path(page)}

  defp active_tab(nil), do: "profile"
  defp active_tab(page), do: to_string(page.id)

  defp limit_message do
    dgettext(
      "dashboard_appearance",
      "You have reached the limit of %{count} booking pages. Delete one to add another.",
      count: BookingPages.max_pages()
    )
  end
end
