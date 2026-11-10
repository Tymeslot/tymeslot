defmodule TymeslotWeb.Dashboard.ThemeSettings.PagesComponent do
  @moduledoc """
  The Theme screen's page switcher: the profile's own page at `/<username>`
  first, as "Main page", then each booking page by name, then the button that
  opens the new-page dialog.

  It stays one row whatever the count. On a wide screen with a few pages the
  pages are tabs; on a narrow screen, or once there are more pages or longer
  names than one row of tabs holds (`tabs_fit?/1`), they are a select. A draft is marked on its tab and in
  its option. Addresses are left to the page's own settings below, so labels
  stay short.

  The selection lives in the URL (`?page=<id>`), so a tab is a patch link, the
  select patches, and every editor on the screen follows it.

  `editable` is false when the account may not create pages
  (`BookingPages.editable?/1`): the new-page button then opens the upgrade
  prompt registered as `:feature_placeholder_components[:booking_pages]`
  instead of the dialog.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Ecto.Changeset
  alias Phoenix.LiveView.JS
  alias Tymeslot.BookingPages
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias TymeslotWeb.Components.Dashboard.BookingPages.NewPageModal
  alias TymeslotWeb.Components.Dashboard.BookingPages.UpgradeNotice
  alias TymeslotWeb.Dashboard.ThemeSettingsComponent
  alias TymeslotWeb.Live.Shared.Flash

  # Tabs while a few short names fit one row beside the main page and the
  # button; a select beyond, where a row of tabs would scroll out of sight.
  @tab_limit 4
  @tab_label_budget 60

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:can_create, length(assigns.pages) < BookingPages.max_pages())
     |> assign(:tabs?, tabs_fit?(assigns.pages))
     |> assign_new(:show_new_page, fn -> false end)
     |> assign_new(:show_upgrade, fn -> false end)
     |> assign_new(:slug_touched?, fn -> false end)
     |> assign_new(:form, fn -> new_form(assigns.profile, %{}, nil) end)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="mb-8 space-y-3" data-testid="booking-page-switcher">
      <div class="flex flex-wrap md:flex-nowrap items-center gap-3">
        <.tab_bar
          :if={@tabs?}
          id="booking-page-tabs"
          class="hidden md:block min-w-0 grow"
          aria_label={dgettext("dashboard_booking_pages", "Booking pages")}
          active_tab={active_tab(@selected_page)}
          tabs={tabs(@pages, @draft_ids)}
        />

        <.form
          for={%{}}
          as={:switcher}
          id="booking-page-select"
          phx-change="switch_page"
          phx-target={@myself}
          class={["min-w-0 flex-1 basis-48", @tabs? && "md:hidden"]}
        >
          <.select
            id="booking-page-select-input"
            name="page"
            icon="hero-document-text"
            aria-label={dgettext("dashboard_booking_pages", "Page you are editing")}
            value={active_tab(@selected_page)}
            options={options(@profile, @pages, @draft_ids)}
          />
        </.form>

        <%!-- Greyed out at the cap rather than removed, as the schedule
        switcher's button is: a ceiling should read as a ceiling. --%>
        <button
          type="button"
          disabled={not @can_create}
          phx-click={@can_create && "show_new_page"}
          phx-target={@myself}
          title={if(not @can_create, do: limit_message())}
          data-testid="new-booking-page"
          aria-label={dgettext("dashboard_booking_pages", "New page")}
          class={[
            "flex shrink-0 items-center gap-2 px-4 py-3 rounded-token-xl font-bold text-token-sm border-2 border-dashed transition-all duration-300",
            if(@can_create,
              do: "text-tymeslot-600 border-tymeslot-300 hover:border-tymeslot-400 hover:bg-white",
              else: "text-tymeslot-400 border-tymeslot-200 cursor-not-allowed"
            )
          ]}
        >
          <.icon name={if(@editable, do: "hero-plus", else: "hero-lock-closed")} class="w-4 h-4" />
          <%!-- Icon only on a phone, so the button keeps to the switcher's row. --%>
          <span class="hidden sm:inline">
            {dgettext("dashboard_booking_pages", "New page")}
          </span>
        </button>
      </div>

      <p :if={not @can_create} class="text-token-sm text-tymeslot-400 font-medium">
        {limit_message()}
      </p>

      <UpgradeNotice.upgrade_notice
        :if={@show_upgrade}
        id="new-booking-page-upgrade"
        current_user={@current_user}
        placeholder_components={@feature_placeholder_components}
      >
        {dgettext(
          "dashboard_booking_pages",
          "Your main page is included in every plan. Extra booking pages need an upgraded plan."
        )}
      </UpgradeNotice.upgrade_notice>

      <NewPageModal.new_page_modal
        show={@show_new_page}
        form={@form}
        target={@myself}
        username={@profile.username}
        on_cancel={JS.push("hide_new_page", target: @myself)}
      />
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("show_new_page", _params, %{assigns: %{editable: false}} = socket),
    do: {:noreply, assign(socket, :show_upgrade, not socket.assigns.show_upgrade)}

  def handle_event("show_new_page", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_page, true)
     |> assign(:slug_touched?, false)
     |> assign(:form, new_form(socket.assigns.profile, %{}, nil))}
  end

  def handle_event("hide_new_page", _params, socket),
    do: {:noreply, assign(socket, :show_new_page, false)}

  def handle_event("switch_page", %{"page" => "profile"}, socket),
    do: {:noreply, push_patch(socket, to: ThemeSettingsComponent.theme_path(nil))}

  def handle_event("switch_page", %{"page" => id}, socket) do
    case Enum.find(socket.assigns.pages, &(to_string(&1.id) == id)) do
      nil -> {:noreply, socket}
      page -> {:noreply, push_patch(socket, to: ThemeSettingsComponent.theme_path(page))}
    end
  end

  # The address follows the name until the host edits the address itself.
  def handle_event("validate_new_page", %{"page" => params} = event, socket) do
    touched? = socket.assigns.slug_touched? or event["_target"] == ["page", "slug"]

    params = follow_name(params, touched?)

    {:noreply,
     socket
     |> assign(:slug_touched?, touched?)
     |> assign(:form, new_form(socket.assigns.profile, params, :validate))}
  end

  # A submit sent before the last change's reply, as typing a name and
  # pressing Enter at once does, carries no address yet: derive it here too.
  def handle_event("create_page", %{"page" => params}, socket) do
    params = follow_name(params, socket.assigns.slug_touched?)

    case BookingPages.create(socket.assigns.profile, params) do
      {:ok, page} ->
        Flash.info(dgettext("dashboard_booking_pages", "Booking page created"))

        {:noreply,
         socket
         |> assign(:show_new_page, false)
         |> push_patch(to: ThemeSettingsComponent.theme_path(page))}

      {:error, :limit_reached} ->
        Flash.error(limit_message())
        {:noreply, assign(socket, :show_new_page, false)}

      # The plan changed while the dialog was open.
      {:error, :upgrade_required} ->
        {:noreply, assign(socket, show_new_page: false, show_upgrade: true, editable: false)}

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
          dgettext(
            "dashboard_booking_pages",
            "Could not create the booking page. Please try again."
          )
        )

        {:noreply, socket}
    end
  end

  defp follow_name(params, true = _slug_touched?), do: params

  defp follow_name(params, false = _slug_touched?),
    do: Map.put(params, "slug", BookingPages.suggest_slug(params["name"]))

  defp new_form(profile, params, action) do
    profile
    |> BookingPages.change_new(params)
    |> Map.put(:action, action)
    |> page_form()
  end

  # Its own input ids, apart from the page details form further down.
  defp page_form(changeset), do: to_form(changeset, as: :page, id: "new-booking-page")

  defp tabs_fit?(pages) do
    length(pages) <= @tab_limit and
      pages |> Enum.map(&String.length(&1.name)) |> Enum.sum() <= @tab_label_budget
  end

  defp tabs(pages, draft_ids) do
    [
      tab("profile", main_page_label(), nil, false)
      | Enum.map(pages, &tab(to_string(&1.id), &1.name, &1, MapSet.member?(draft_ids, &1.id)))
    ]
  end

  defp tab(id, label, page, draft?) do
    %{
      id: id,
      label: label,
      patch: ThemeSettingsComponent.theme_path(page),
      badge: if(draft?, do: draft_label())
    }
  end

  # The address is part of each option here, as a select shows nothing else.
  defp options(profile, pages, draft_ids) do
    [
      {"#{main_page_label()} · /#{profile.username}", "profile"}
      | Enum.map(pages, fn page ->
          label = BookingPages.name_and_address(page, profile.username)

          label =
            if MapSet.member?(draft_ids, page.id),
              do: "#{label} (#{draft_label()})",
              else: label

          {label, to_string(page.id)}
        end)
    ]
  end

  defp active_tab(nil), do: "profile"
  defp active_tab(page), do: to_string(page.id)

  defp main_page_label, do: dgettext("dashboard_booking_pages", "Main page")
  defp draft_label, do: dgettext("dashboard_booking_pages", "Draft")

  defp limit_message do
    dgettext(
      "dashboard_booking_pages",
      "You have reached the limit of %{count} booking pages. Delete one to add another.",
      count: BookingPages.max_pages()
    )
  end
end
