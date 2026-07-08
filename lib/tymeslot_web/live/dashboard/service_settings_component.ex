defmodule TymeslotWeb.Dashboard.ServiceSettingsComponent do
  @moduledoc """
  LiveComponent for managing meeting settings in the dashboard.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Components.Dashboard.MeetingTypes.BookingLinkModal
  alias TymeslotWeb.Components.Dashboard.MeetingTypes.DeleteMeetingTypeModal
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Submission
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypesListComponent
  alias TymeslotWeb.Dashboard.MeetingSettings.SchedulingSettingsComponent
  alias TymeslotWeb.Endpoint
  require Logger

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:meeting_types, [])
     |> assign(:show_add_form, false)
     |> assign(:editing_type, nil)
     |> assign(:show_edit_overlay, false)
     |> assign(:form_errors, %{})
     |> assign(:saving, false)
     |> assign(:video_integrations, [])
     |> assign(:toggling_type_id, nil)
     |> assign(:custom_questions_allowed, true)
     |> assign(:show_slug_modal, false)
     |> assign(:slug_modal_type, nil)
     |> assign(:slug_draft, "")
     |> ModalHook.mount_modal(delete_meeting_type: false)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    # Merge new assigns into socket
    socket = assign(socket, assigns)

    # Always ensure we have the latest profile data
    socket = Helpers.maybe_reload_profile(socket)

    # Load meeting settings data directly (own your data)
    # Use socket.assigns to handle partial updates from send_update
    user_id = socket.assigns.current_user.id
    data = DashboardContext.get_meeting_settings_data(user_id)

    socket =
      socket
      |> assign(:meeting_types, data.meeting_types)
      |> assign(:video_integrations, data.video_integrations)
      |> assign(:calendar_integrations, data.calendar_integrations)
      |> assign(:payment_currency, host_currency(data.meeting_types, user_id))

    {:ok, socket}
  end

  # The host's pricing currency, used only to format the price token on paid
  # meeting type cards. Resolved from the Stripe Connect account, and only
  # when at least one meeting type is actually paid — unpaid lists skip the
  # extra query and fall back to the first allowed currency.
  defp host_currency(meeting_types, user_id) do
    if Enum.any?(meeting_types, & &1.payment_required) do
      case MeetingPayments.get_connect_account_for_user(user_id) do
        %{default_currency: currency} when is_binary(currency) and currency != "" -> currency
        _other -> "eur"
      end
    else
      "eur"
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_add_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_form, !socket.assigns.show_add_form)
     |> assign(:editing_type, nil)
     |> assign(:form_errors, %{})
     |> assign(:selected_icon, "none")
     |> assign(:form_data, %{})}
  end

  def handle_event("edit_type", %{"id" => id}, socket) do
    type = Enum.find(socket.assigns.meeting_types, &(&1.id == String.to_integer(id)))

    if is_nil(type) do
      Flash.error("Meeting type not found")
      {:noreply, socket}
    else
      form_data = %{
        "name" => type.name || "",
        "duration" => to_string(type.duration_minutes || 30),
        "description" => type.description || "",
        "icon" => type.icon || "none"
      }

      socket =
        socket
        |> assign(:editing_type, type)
        |> assign(:show_add_form, false)
        |> assign(:show_edit_overlay, true)
        |> assign(:form_errors, %{})
        |> assign(:selected_icon, type.icon || "none")
        |> assign(:meeting_mode, if(type.allow_video, do: "video", else: "personal"))
        |> assign(:selected_video_integration_id, Map.get(type, :video_integration_id))
        |> assign(:form_data, form_data)

      {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_type, nil)
     |> assign(:show_edit_overlay, false)
     |> assign(:form_errors, %{})
     |> assign(:selected_icon, "none")
     |> assign(:form_data, %{})}
  end

  def handle_event("close_edit_overlay", _params, socket) do
    # Edits auto-save as they happen, so closing only tears down the overlay.
    # Refresh the list view from the database so it reflects the saved state
    # — the data is already persisted regardless of how the user leaves.
    send(self(), {:meeting_type_changed})

    {:noreply,
     socket
     |> assign(:editing_type, nil)
     |> assign(:show_edit_overlay, false)
     |> assign(:form_errors, %{})
     |> assign(:selected_icon, "none")
     |> assign(:form_data, %{})}
  end

  # Validation is now handled inside MeetingTypeForm LiveComponent

  def handle_event("save_meeting_type", %{"meeting_type" => params}, socket) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_meeting_type_write_rate_limit(user_id), socket, fn ->
      do_save_meeting_type(params, socket)
    end)
  end

  def handle_event("toggle_type", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id
    type_id = String.to_integer(id)

    if socket.assigns.toggling_type_id == type_id do
      {:noreply, socket}
    else
      with_rate_limit(RateLimiter.check_meeting_type_write_rate_limit(user_id), socket, fn ->
        socket
        |> assign(:toggling_type_id, type_id)
        |> do_toggle_type(type_id, user_id)
      end)
    end
  end

  def handle_event("toggle_private", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id
    type_id = String.to_integer(id)

    with_rate_limit(RateLimiter.check_meeting_type_write_rate_limit(user_id), socket, fn ->
      do_toggle_private(socket, type_id, user_id)
    end)
  end

  def handle_event("open_slug_modal", _params, socket) do
    case socket.assigns.editing_type do
      nil ->
        {:noreply, socket}

      type ->
        {:noreply,
         socket
         |> assign(:show_slug_modal, true)
         |> assign(:slug_modal_type, type)
         |> assign(:slug_draft, MeetingTypes.effective_slug(type))}
    end
  end

  def handle_event("close_slug_modal", _params, socket) do
    {:noreply, hide_slug_modal(socket)}
  end

  def handle_event("slug_draft_changed", %{"slug" => slug}, socket) do
    {:noreply, assign(socket, :slug_draft, slug)}
  end

  def handle_event("randomise_slug", _params, socket) do
    user_id = socket.assigns.current_user.id
    {:noreply, assign(socket, :slug_draft, MeetingTypes.generate_random_slug(user_id))}
  end

  def handle_event("confirm_slug_change", _params, socket) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_meeting_type_write_rate_limit(user_id), socket, fn ->
      do_confirm_slug_change(socket, user_id)
    end)
  end

  def handle_event("show_delete_modal", %{"id" => id}, socket) do
    type_id = String.to_integer(id)
    type = MeetingTypes.get_meeting_type(type_id, socket.assigns.current_user.id)

    if type do
      {:noreply, ModalHook.show_modal(socket, :delete_meeting_type, type)}
    else
      Flash.error("Meeting type not found")
      {:noreply, socket}
    end
  end

  def handle_event("hide_delete_modal", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :delete_meeting_type)}
  end

  def handle_event("confirm_delete_meeting_type", _params, socket) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_meeting_type_write_rate_limit(user_id), socket, fn ->
      ModalHook.with_modal_data(socket, :delete_meeting_type, fn type ->
        case MeetingTypes.delete_meeting_type(type) do
          {:ok, _result} ->
            send(self(), {:meeting_type_changed})
            Flash.info("Meeting type deleted")
            {:noreply, ModalHook.hide_modal(socket, :delete_meeting_type)}

          {:error, _reason} ->
            Flash.error("Failed to delete meeting type")
            {:noreply, ModalHook.hide_modal(socket, :delete_meeting_type)}
        end
      end)
    end)
  end

  def handle_event("reorder_meeting_types", %{"ids" => ids}, socket) when is_list(ids) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_meeting_type_write_rate_limit(user_id), socket, fn ->
      # Convert to integers safely
      meeting_type_ids =
        ids
        |> Enum.map(fn
          id when is_integer(id) ->
            id

          id when is_binary(id) ->
            case Integer.parse(id) do
              {int, _value} -> int
              :error -> nil
            end

          _other ->
            nil
        end)
        |> Enum.reject(&is_nil/1)

      case MeetingTypes.reorder_meeting_types(user_id, meeting_type_ids) do
        {:ok, _result} ->
          send(self(), {:meeting_type_changed})
          Flash.info("Meeting types reordered")
          {:noreply, socket}

        {:error, reason} ->
          Logger.error("Failed to reorder meeting types", reason: inspect(reason))
          Flash.error("Failed to reorder meeting types")
          {:noreply, socket}
      end
    end)
  end

  # Private functions

  defp do_toggle_type(socket, type_id, user_id) do
    case MeetingTypes.get_meeting_type(type_id, user_id) do
      nil ->
        Flash.error("Meeting type not found")
        {:noreply, assign(socket, :toggling_type_id, nil)}

      type ->
        case MeetingTypes.toggle_meeting_type_status(type, %{is_active: !type.is_active}) do
          {:ok, updated_type} ->
            send(self(), {:meeting_type_changed})
            Flash.info("Meeting type status updated")

            updated_meeting_types =
              Enum.map(socket.assigns.meeting_types, fn
                t when t.id == updated_type.id -> updated_type
                t -> t
              end)

            {:noreply,
             assign(socket, meeting_types: updated_meeting_types, toggling_type_id: nil)}

          {:error, _reason} ->
            Flash.error("Failed to update meeting type")
            {:noreply, assign(socket, :toggling_type_id, nil)}
        end
    end
  end

  defp do_toggle_private(socket, type_id, user_id) do
    case MeetingTypes.get_meeting_type(type_id, user_id) do
      nil ->
        Flash.error(dgettext("dashboard_integrations", "Meeting type not found"))
        {:noreply, socket}

      type ->
        case MeetingTypes.set_private(type, !type.is_private) do
          {:ok, _updated} ->
            send(self(), {:meeting_type_changed})
            Flash.info(dgettext("dashboard_integrations", "Visibility updated"))
            {:noreply, reload_editing_type(socket, type_id, user_id)}

          {:error, _reason} ->
            Flash.error(dgettext("dashboard_integrations", "Failed to update visibility"))
            {:noreply, socket}
        end
    end
  end

  defp do_confirm_slug_change(socket, user_id) do
    type = socket.assigns.slug_modal_type

    case MeetingTypes.update_slug(type, socket.assigns.slug_draft) do
      {:ok, _updated} ->
        send(self(), {:meeting_type_changed})
        Flash.info(dgettext("dashboard_integrations", "Booking link updated"))

        {:noreply,
         socket
         |> reload_editing_type(type.id, user_id)
         |> hide_slug_modal()}

      {:error, :slug_taken} ->
        Flash.error(
          dgettext("dashboard_integrations", "That link is already taken. Please choose another.")
        )

        {:noreply, socket}

      {:error, %Ecto.Changeset{}} ->
        Flash.error(
          dgettext(
            "dashboard_integrations",
            "That link isn't valid. Use lowercase letters, numbers and hyphens."
          )
        )

        {:noreply, socket}
    end
  end

  # Re-fetches the (preloaded) type and refreshes both the open editor and the
  # underlying list entry so the UI reflects the saved state immediately.
  defp reload_editing_type(socket, type_id, user_id) do
    updated = MeetingTypes.get_meeting_type(type_id, user_id)

    meeting_types =
      Enum.map(socket.assigns.meeting_types, fn
        t when t.id == type_id -> updated
        t -> t
      end)

    socket
    |> assign(:meeting_types, meeting_types)
    |> assign(:editing_type, updated)
  end

  defp hide_slug_modal(socket) do
    socket
    |> assign(:show_slug_modal, false)
    |> assign(:slug_modal_type, nil)
    |> assign(:slug_draft, "")
  end

  defp with_rate_limit({:error, :rate_limited, message}, socket, _action) do
    Flash.error(message)
    {:noreply, socket}
  end

  defp with_rate_limit(:ok, _socket, action), do: action.()

  # The public base of a meeting type's booking link, e.g. "https://host/alice".
  # Returns nil when the profile has no username yet (link UI is then hidden).
  defp booking_base_url(%{username: username}) when is_binary(username) and username != "" do
    Endpoint.url() <> "/" <> username
  end

  defp booking_base_url(_profile), do: nil

  defp do_save_meeting_type(params, socket) do
    socket = assign(socket, :saving, true)
    metadata = Helpers.get_security_metadata(socket)

    case Submission.persist(
           params,
           metadata,
           socket.assigns.editing_type,
           socket.assigns.current_user
         ) do
      {:error, {:invalid_form, validation_errors}} ->
        {:noreply,
         socket
         |> assign(:form_errors, validation_errors)
         |> assign(:saving, false)}

      result ->
        Helpers.handle_meeting_type_save_result(result, socket)
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <.section_header
        icon="hero-squares-2x2"
        title="Meeting Settings"
        saving={@saving}
      />

      <%= if (@show_edit_overlay && @editing_type) || @show_add_form do %>
        <%!-- Form View (Add or Edit) --%>
        <div
          id="meeting-type-config-view"
          phx-hook="ScrollReset"
          data-action={if @editing_type, do: "edit-#{@editing_type.id}", else: "new"}
          class="space-y-8"
        >
          <div class="flex items-start justify-between bg-white p-6 rounded-token-3xl border-2 border-tymeslot-50 shadow-sm">
            <.section_header
              level={2}
              icon="hero-squares-2x2"
              title={if @editing_type, do: "Edit Meeting Type", else: "Add Meeting Type"}
            />
            <button
              phx-click={if @editing_type, do: "close_edit_overlay", else: "toggle_add_form"}
              phx-target={@myself}
              class="shrink-0 p-2 rounded-lg text-tymeslot-500 hover:text-tymeslot-700 hover:bg-tymeslot-100 transition-colors"
              title="Close"
            >
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>

          <div class="card-glass">
            <.live_component
              module={MeetingTypeForm}
              id={if @editing_type, do: "meeting-type-form-edit-#{@editing_type.id}", else: "meeting-type-form-new"}
              type={@editing_type}
              is_edit={!!@editing_type}
              video_integrations={@video_integrations}
              calendar_integrations={@calendar_integrations}
              parent_myself={@myself}
              saving={@saving}
              current_user={@current_user}
              client_ip={@client_ip}
              user_agent={@user_agent}
              form_errors={@form_errors}
              custom_questions_allowed={@custom_questions_allowed}
            />
          </div>

          <%!-- Booking link & visibility (existing types only; needs a username) --%>
          <div
            :if={@editing_type && booking_base_url(@profile)}
            class="card-glass space-y-6"
          >
            <div class="flex items-center gap-2">
              <.icon name="hero-link" class="w-5 h-5 text-turquoise-500" />
              <h3 class="font-semibold text-tymeslot-700 text-token-lg">
                {dgettext("dashboard_integrations", "Booking link & visibility")}
              </h3>
            </div>

            <div class="space-y-2">
              <label class="block font-medium text-tymeslot-700 text-token-sm">
                {dgettext("dashboard_integrations", "Direct booking link")}
              </label>
              <div class="flex flex-wrap items-center gap-2">
                <input
                  type="text"
                  readonly
                  value={"#{booking_base_url(@profile)}/#{MeetingTypes.effective_slug(@editing_type)}"}
                  class="font-mono text-token-sm flex-1 min-w-[12rem] px-4 py-2.5 rounded-token-xl border-2 border-tymeslot-100 bg-tymeslot-50 text-tymeslot-600 cursor-default"
                />
                <button
                  type="button"
                  id={"copy-booking-link-#{@editing_type.id}"}
                  phx-hook="CopyOnClick"
                  data-copy-text={"#{booking_base_url(@profile)}/#{MeetingTypes.effective_slug(@editing_type)}"}
                  data-copy-feedback={dgettext("dashboard_integrations", "Booking link copied!")}
                  class="whitespace-nowrap px-5 py-2.5 rounded-token-xl bg-tymeslot-50 text-tymeslot-600 font-bold hover:bg-tymeslot-100 transition-all border-2 border-transparent hover:border-tymeslot-200"
                >
                  {dgettext("dashboard_integrations", "Copy")}
                </button>
                <.action_button
                  type="button"
                  variant={:secondary}
                  phx-click="open_slug_modal"
                  phx-target={@myself}
                >
                  {dgettext("dashboard_integrations", "Change link")}
                </.action_button>
              </div>
              <p class="text-token-sm text-tymeslot-500">
                {dgettext("dashboard_integrations", 
                  "Anyone with this link can book this meeting type directly, without seeing your other meeting types."
                )}
              </p>
            </div>

            <div class="flex items-center justify-between gap-4 pt-2 border-t-2 border-tymeslot-50">
              <div>
                <p class="font-medium text-tymeslot-700">
                  {dgettext("dashboard_integrations", "Hide from public booking page")}
                </p>
                <p class="text-token-sm text-tymeslot-500">
                  {dgettext("dashboard_integrations", "When on, this meeting type is reachable only through its direct link.")}
                </p>
              </div>
              <button
                type="button"
                phx-click="toggle_private"
                phx-value-id={@editing_type.id}
                phx-target={@myself}
                role="switch"
                aria-checked={@editing_type.is_private}
                aria-label={dgettext("dashboard_integrations", "Hide from public booking page")}
                class={[
                  "relative inline-flex h-5 w-9 shrink-0 cursor-pointer rounded-full border-2 transition-colors duration-200 ease-in-out focus:outline-hidden focus:ring-2 focus:ring-turquoise-500 focus:ring-offset-2",
                  if(@editing_type.is_private,
                    do: "bg-turquoise-500 border-turquoise-500",
                    else: "bg-tymeslot-300 border-tymeslot-300"
                  )
                ]}
              >
                <span class={[
                  "pointer-events-none inline-block h-4 w-4 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
                  if(@editing_type.is_private, do: "translate-x-4", else: "translate-x-0")
                ]} />
              </button>
            </div>
          </div>

          <BookingLinkModal.booking_link_modal
            show={@show_slug_modal}
            meeting_type={@slug_modal_type}
            slug_draft={@slug_draft}
            base_url={booking_base_url(@profile) || ""}
            myself={@myself}
          />
        </div>
      <% else %>
        <%!-- Normal View --%>
        <div class="space-y-10">
          <%!-- Meeting Types Section --%>
          <div class="space-y-6">
            <MeetingTypesListComponent.meeting_types_section
              meeting_types={@meeting_types}
              show_add_form={@show_add_form}
              editing_type={@editing_type}
              currency={@payment_currency}
              parent_myself={@myself}
            />
          </div>

    <%!-- Scheduling Settings --%>
          <div>
            <.live_component
              module={SchedulingSettingsComponent}
              id="scheduling-settings"
              profile={@profile}
              client_ip={@client_ip}
              user_agent={@user_agent}
            />
          </div>
        </div>

    <%!-- Delete Meeting Type Modal --%>
        <DeleteMeetingTypeModal.delete_meeting_type_modal
          show={@show_delete_meeting_type_modal}
          meeting_type={@delete_meeting_type_modal_data}
          myself={@myself}
        />
      <% end %>

    <%!-- Add spacing after content to prevent flush bottom --%>
      <div class="pb-8"></div>
    </div>
    """
  end
end
