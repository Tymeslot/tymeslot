defmodule TymeslotWeb.Dashboard.ProfileSettings.UsernameFormComponent do
  @moduledoc """
  Username form component for profile settings.
  Allows users to update their unique booking URL.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Polls
  alias Tymeslot.Profiles
  alias Tymeslot.Security.FieldValidators.UsernameValidator
  alias Tymeslot.Security.InputProcessor
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.ChangesetUtils
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.ProfileSettings.UsernameChangeModal
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  import UsernameChangeModal, only: [username_change_modal: 1]

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     assign(socket,
       username_check: nil,
       username_available: nil,
       pending_username: nil,
       open_poll_count: 0,
       saving: false,
       form_errors: %{}
     )}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("check_username_availability", %{"username" => username}, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_username_check_rate_limit("user:#{user_id}") do
      {:error, :rate_limited} ->
        {:noreply, socket}

      :ok ->
        metadata = DashboardHelpers.get_security_metadata(socket)
        socket = update_username_availability(socket, username, metadata)
        {:noreply, socket}
    end
  end

  # Setting a username for the first time breaks nothing, so it saves straight
  # away. Replacing one that is already live is irreversible for everybody
  # holding a link to it, so it stops for a confirmation that says which
  # surfaces go with it.
  def handle_event("update_username", %{"username" => username}, socket) do
    metadata = DashboardHelpers.get_security_metadata(socket)
    current = socket.assigns.profile && socket.assigns.profile.username

    case InputProcessor.validate_field(username, :username) do
      {:ok, sanitized} when is_binary(current) and current != "" and sanitized != current ->
        {:noreply,
         assign(socket,
           pending_username: sanitized,
           open_poll_count: Polls.count_open_polls(socket.assigns.current_user.id)
         )}

      _first_time_or_invalid ->
        perform_username_update(socket, username, metadata)
    end
  end

  def handle_event("cancel_username_change", _params, socket) do
    {:noreply, assign(socket, pending_username: nil)}
  end

  def handle_event("confirm_username_change", _params, socket) do
    metadata = DashboardHelpers.get_security_metadata(socket)
    username = socket.assigns.pending_username

    socket
    |> assign(pending_username: nil)
    |> perform_username_update(username, metadata)
  end

  defp update_username_availability(socket, username, _metadata) do
    cond do
      username == "" ->
        assign(socket, username_check: nil, username_available: nil)

      socket.assigns.profile && username == socket.assigns.profile.username ->
        assign(socket, username_check: username, username_available: :current)

      true ->
        case InputProcessor.validate_field(username, :username,
               reserved_words: Profiles.reserved_paths()
             ) do
          {:ok, sanitized_username} ->
            available = Profiles.username_available?(sanitized_username)
            assign(socket, username_check: sanitized_username, username_available: available)

          {:error, message} ->
            assign(socket, username_check: username, username_available: {:error, message})
        end
    end
  end

  defp perform_username_update(socket, username, _metadata) do
    profile = socket.assigns.profile
    user_id = socket.assigns.current_user.id

    socket = assign(socket, :saving, true)

    with {:ok, sanitized_username} <- InputProcessor.validate_field(username, :username),
         {:ok, updated_profile} <-
           Profiles.update_username(profile, sanitized_username, user_id) do
      handle_successful_username_update(socket, updated_profile, sanitized_username)
    else
      error -> handle_username_update_error(socket, error)
    end
  end

  defp handle_successful_username_update(socket, updated_profile, sanitized_username) do
    send(self(), {:profile_updated, updated_profile})

    booking_page_url = "#{display_url()}/#{sanitized_username}"

    send(
      self(),
      {:flash,
       {:info,
        dgettext("dashboard_profile", "Username updated! Your booking page: %{url}",
          url: booking_page_url
        )}}
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

  defp display_url, do: String.replace(Policy.app_url(), ~r/^https?:\/\//, "")

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns = assign(assigns, :display_url, display_url())

    ~H"""
    <div id="username-form-container">
      <.section_header level={3} title={dgettext("dashboard_profile", "Custom URL")} class="mb-4" />
      <form
        id="username-form"
        phx-submit="update_username"
        phx-change="check_username_availability"
        phx-target={@myself}
        class="space-y-4"
      >
        <div>
          <div class="flex flex-col sm:flex-row items-stretch gap-4">
            <div class="flex-1">
              <% prefix_length = String.length(@display_url) + 1 %>
              <% input_padding = "--leading-icon-width: #{prefix_length}ch;" %>
              <.input
                name="username"
                label={dgettext("dashboard_profile", "Your Custom URL")}
                value={if @profile, do: @profile.username || "", else: ""}
                placeholder={dgettext("dashboard_profile", "yourname")}
                pattern={UsernameValidator.html_pattern()}
                minlength={Constraints.username_length_range().first}
                maxlength={Constraints.username_length_range().last}
                phx-debounce="500"
                errors={FormValidationHelpers.field_errors(@form_errors, :username)}
                style={input_padding}
              >
                <:leading_icon>
                  <span class="text-tymeslot-400 font-bold text-token-sm tracking-tight whitespace-nowrap">{@display_url}/</span>
                </:leading_icon>

                <%= if @username_check && (!@profile || @username_check != @profile.username) do %>
                  <div class="absolute right-3 top-1/2 -translate-y-1/2 shrink-0">
                    <%= case @username_available do %>
                      <% true -> %>
                        <div class="inline-flex items-center px-2 py-0.5 rounded-token-lg bg-emerald-50 text-emerald-700 text-token-2xs font-black uppercase tracking-wider border border-emerald-100">
                          <svg
                            class="w-3 h-3 mr-1"
                            fill="none"
                            stroke="currentColor"
                            viewBox="0 0 24 24"
                          >
                            <path
                              stroke-linecap="round"
                              stroke-linejoin="round"
                              stroke-width="3"
                              d="M5 13l4 4L19 7"
                            />
                          </svg>
                          {dgettext("dashboard_profile", "Available")}
                        </div>
                      <% false -> %>
                        <div class="inline-flex items-center px-2 py-0.5 rounded-token-lg bg-red-50 text-red-700 text-token-2xs font-black uppercase tracking-wider border border-red-100">
                          <svg
                            class="w-3 h-3 mr-1"
                            fill="none"
                            stroke="currentColor"
                            viewBox="0 0 24 24"
                          >
                            <path
                              stroke-linecap="round"
                              stroke-linejoin="round"
                              stroke-width="3"
                              d="M6 18L18 6M6 6l12 12"
                            />
                          </svg>
                          {dgettext("dashboard_profile", "Taken")}
                        </div>
                      <% {:error, _message} -> %>
                        <div class="inline-flex items-center px-2 py-0.5 rounded-token-lg bg-amber-50 text-amber-700 text-token-2xs font-black uppercase tracking-wider border border-amber-100">
                          {dgettext("dashboard_profile", "Invalid")}
                        </div>
                      <% _ -> %>
                    <% end %>
                  </div>
                <% end %>
              </.input>
            </div>
            <div class="flex items-end">
              <button
                type="submit"
                class="btn-primary px-8 whitespace-nowrap h-[52px]"
                phx-disable-with={dgettext("dashboard_profile", "Saving...")}
              >
                {dgettext("dashboard_profile", "Update URL")}
              </button>
            </div>
          </div>

          <div class="mt-4">
            <%= if @profile && @profile.username do %>
              <div class="flex items-center gap-2 text-token-sm font-bold text-tymeslot-500">
                <svg
                  class="w-4 h-4 text-emerald-500"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2.5"
                    d="M5 13l4 4L19 7"
                  />
                </svg>
                {dgettext("dashboard_profile", "Live at:")}
                <a
                  href={"#{Policy.app_url()}/#{@profile.username}"}
                  target="_blank"
                  class="text-turquoise-600 hover:text-turquoise-700 underline decoration-2 decoration-turquoise-100 underline-offset-4 transition-colors"
                >
                  {@display_url}/{@profile.username}
                </a>
              </div>
            <% else %>
              <p class="text-token-sm text-tymeslot-500 font-medium">
                {dgettext(
                  "dashboard_profile",
                  "Choose a unique username for your personal booking page."
                )}
              </p>
            <% end %>
          </div>
        </div>
      </form>

      <.username_change_modal
        pending_username={@pending_username}
        current_username={(@profile && @profile.username) || ""}
        display_url={@display_url}
        open_poll_count={@open_poll_count}
        myself={@myself}
      />
    </div>
    """
  end
end
