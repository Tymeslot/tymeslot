defmodule TymeslotWeb.Dashboard.ProfileSettings.UsernameFormComponent do
  @moduledoc """
  Username form component for profile settings.
  Allows users to update their unique booking URL.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Profiles
  alias Tymeslot.Security.SettingsInputProcessor
  alias Tymeslot.Utils.ChangesetUtils
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(username_check: nil)
     |> assign(username_available: nil)
     |> assign(saving: false)
     |> assign(:form_errors, %{})}
  end

  @impl Phoenix.LiveComponent
  def handle_event("check_username_availability", %{"username" => username}, socket) do
    metadata = DashboardHelpers.get_security_metadata(socket)
    socket = update_username_availability(socket, username, metadata)
    {:noreply, socket}
  end

  def handle_event("update_username", %{"username" => username}, socket) do
    metadata = DashboardHelpers.get_security_metadata(socket)
    perform_username_update(socket, username, metadata)
  end

  defp update_username_availability(socket, username, metadata) do
    cond do
      username == "" ->
        assign(socket, username_check: nil, username_available: nil)

      socket.assigns.profile && username == socket.assigns.profile.username ->
        assign(socket, username_check: username, username_available: :current)

      true ->
        case SettingsInputProcessor.validate_username_update(username, metadata: metadata) do
          {:ok, sanitized_username} ->
            available = Profiles.username_available?(sanitized_username)
            assign(socket, username_check: sanitized_username, username_available: available)

          {:error, message} ->
            assign(socket, username_check: username, username_available: {:error, message})
        end
    end
  end

  defp perform_username_update(socket, username, metadata) do
    profile = socket.assigns.profile
    user_id = socket.assigns.current_user.id

    socket = assign(socket, :saving, true)

    with {:ok, sanitized_username} <-
           SettingsInputProcessor.validate_username_update(username, metadata: metadata),
         {:ok, updated_profile} <-
           Profiles.update_username(profile, sanitized_username, user_id) do
      handle_successful_username_update(socket, updated_profile, sanitized_username)
    else
      error -> handle_username_update_error(socket, error)
    end
  end

  defp handle_successful_username_update(socket, updated_profile, sanitized_username) do
    base_url = Policy.app_url()
    display_url = String.replace(base_url, ~r/^https?:\/\//, "")

    send(self(), {:profile_updated, updated_profile})

    send(
      self(),
      {:flash,
       {:info, "Username updated! Your booking page: #{display_url}/#{sanitized_username}"}}
    )

    {:noreply,
     socket
     |> assign(profile: updated_profile)
     |> assign(saving: false)
     |> assign(
       :form_errors,
       FormValidationHelpers.delete_field_error(socket.assigns.form_errors, :username)
     )}
  end

  defp handle_username_update_error(socket, error) do
    case error do
      {:error, %Ecto.Changeset{} = changeset} ->
        Flash.error(ChangesetUtils.get_first_error(changeset))
        {:noreply, assign(socket, saving: false)}

      {:error, message} when is_binary(message) ->
        Flash.error(message)
        {:noreply, assign(socket, saving: false)}
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="username-form-container">
      <.section_header level={3} title="Custom URL" class="mb-4" />
      <form phx-submit="update_username" phx-change="check_username_availability" phx-target={@myself} class="space-y-4">
        <div>
          <div class="flex flex-col sm:flex-row items-stretch gap-4">
            <div class="flex-1">
              <% base_url = Policy.app_url() %>
              <% display_url = String.replace(base_url, ~r/^https?:\/\//, "") %>
              <% prefix_length = String.length(display_url) + 1 %>
              <% input_padding = "--leading-icon-width: #{prefix_length}ch;" %>
              <.input
                name="username"
                label="Your Custom URL"
                value={if @profile, do: @profile.username || "", else: ""}
                placeholder="yourname"
                pattern="[a-z0-9][a-z0-9-]{2,29}"
                minlength="3"
                maxlength="30"
                phx-debounce="500"
                errors={FormValidationHelpers.field_errors(@form_errors, :username)}
                style={input_padding}
              >
                <:leading_icon>
                  <span class="text-tymeslot-400 font-bold text-token-sm tracking-tight whitespace-nowrap">{display_url}/</span>
                </:leading_icon>

                <%= if @username_check && (!@profile || @username_check != @profile.username) do %>
                  <div class="absolute right-3 top-1/2 -translate-y-1/2 shrink-0">
                    <%= case @username_available do %>
                      <% true -> %>
                        <div class="inline-flex items-center px-2 py-0.5 rounded-token-lg bg-emerald-50 text-emerald-700 text-[10px] font-black uppercase tracking-wider border border-emerald-100 animate-in zoom-in">
                          <svg class="w-3 h-3 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M5 13l4 4L19 7" />
                          </svg>
                          Available
                        </div>
                      <% false -> %>
                        <div class="inline-flex items-center px-2 py-0.5 rounded-token-lg bg-red-50 text-red-700 text-[10px] font-black uppercase tracking-wider border border-red-100 animate-in zoom-in">
                          <svg class="w-3 h-3 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M6 18L18 6M6 6l12 12" />
                          </svg>
                          Taken
                        </div>
                      <% {:error, _message} -> %>
                        <div class="inline-flex items-center px-2 py-0.5 rounded-token-lg bg-amber-50 text-amber-700 text-[10px] font-black uppercase tracking-wider border border-amber-100 animate-in zoom-in">
                          Invalid
                        </div>
                      <% _ -> %>
                    <% end %>
                  </div>
                <% end %>
              </.input>
            </div>
            <div class="flex items-end">
              <button type="submit" class="btn-primary px-8 whitespace-nowrap h-[52px]" phx-disable-with="Saving...">
                Update URL
              </button>
            </div>
          </div>
          
          <div class="mt-4">
            <%= if @profile && @profile.username do %>
              <% base_url = Policy.app_url() %>
              <% display_url = String.replace(base_url, ~r/^https?:\/\//, "") %>
              <div class="flex items-center gap-2 text-token-sm font-bold text-tymeslot-500">
                <svg class="w-4 h-4 text-emerald-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M5 13l4 4L19 7" />
                </svg>
                Live at: 
                <a
                  href={"#{base_url}/#{if @profile, do: @profile.username, else: ""}"}
                  target="_blank"
                  class="text-turquoise-600 hover:text-turquoise-700 underline decoration-2 decoration-turquoise-100 underline-offset-4 transition-colors"
                >
                  {display_url}/{if @profile, do: @profile.username, else: ""}
                </a>
              </div>
            <% else %>
              <p class="text-token-sm text-tymeslot-500 font-medium">
                Choose a unique username for your personal booking page.
              </p>
            <% end %>
          </div>
        </div>
      </form>
    </div>
    """
  end
end
