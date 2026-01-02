defmodule TymeslotWeb.Dashboard.ProfileSettingsComponent do
  @moduledoc """
  LiveView component for managing user profile settings including timezone,
  display name, scheduling preferences, and username configuration.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.{Profiles, Utils.TimezoneUtils}
  alias Tymeslot.Security.SettingsInputProcessor
  alias Tymeslot.Utils.ChangesetUtils
  alias TymeslotWeb.Components.{CoreComponents, FormSystem}
  alias TymeslotWeb.Components.DashboardComponents
  alias TymeslotWeb.Components.TimezoneDropdown
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers
  alias TymeslotWeb.Live.Shared.Flash
  require Logger

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    timezone_options = TimezoneUtils.get_all_timezone_options()

    socket =
      socket
      |> assign(assigns)
      |> assign(timezone_options: timezone_options)
      |> assign(username_check: nil)
      |> assign(username_available: nil)
      |> assign(saving: false)
      |> assign(timezone_dropdown_open: false)
      |> assign(timezone_search: "")
      |> assign(:form_errors, %{})
      |> assign(:parent_uploads, assigns[:parent_uploads] || nil)

    socket = ModalHook.mount_modal(socket, [{:delete_avatar, false}])

    # Handle avatar upload result if present
    socket =
      if assigns[:avatar_upload_result] do
        # Extract socket from {:noreply, socket} tuple
        elem(handle_avatar_upload_result(assigns.avatar_upload_result, socket), 1)
      else
        socket
      end

    {:ok, socket}
  end

  # Validation event handlers
  @impl true
  def handle_event("validate_full_name", %{"full_name" => full_name}, socket) do
    metadata = DashboardHelpers.get_security_metadata(socket)

    case SettingsInputProcessor.validate_full_name_update(full_name, metadata: metadata) do
      {:ok, sanitized_name} ->
        # Clear any previous error for this field
        socket = assign(socket, :form_errors, Map.delete(socket.assigns.form_errors, :full_name))
        maybe_update_full_name(socket, sanitized_name)

      {:error, error} ->
        errors = Map.put(socket.assigns.form_errors, :full_name, error)
        {:noreply, assign(socket, :form_errors, errors)}
    end
  end

  def handle_event("validate_username", %{"username" => username}, socket) do
    metadata = DashboardHelpers.get_security_metadata(socket)

    case SettingsInputProcessor.validate_username_update(username, metadata: metadata) do
      {:ok, _sanitized_username} ->
        {:noreply,
         assign(socket, :form_errors, Map.delete(socket.assigns.form_errors, :username))}

      {:error, error} ->
        errors = Map.put(socket.assigns.form_errors, :username, error)
        {:noreply, assign(socket, :form_errors, errors)}
    end
  end

  def handle_event("check_username_availability", %{"username" => username}, socket) do
    metadata = DashboardHelpers.get_security_metadata(socket)

    socket = update_username_availability(socket, username, metadata)

    {:noreply, socket}
  end

  def handle_event("update_username", %{"username" => username}, socket) do
    metadata = DashboardHelpers.get_security_metadata(socket)
    perform_username_update(socket, username, metadata)
  end

  def handle_event("show_delete_avatar_modal", _params, socket) do
    {:noreply, ModalHook.show_modal(socket, :delete_avatar)}
  end

  def handle_event("hide_delete_avatar_modal", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :delete_avatar)}
  end

  def handle_event("delete_avatar", _params, socket) do
    profile = socket.assigns.profile
    socket = ModalHook.hide_modal(socket, :delete_avatar)

    case Profiles.delete_avatar(profile) do
      {:ok, updated_profile} ->
        send(self(), {:profile_updated, updated_profile})
        Flash.info("Avatar deleted successfully")

        # Notify parent to reset uploads
        send(self(), :reset_avatar_upload)

        # Push event to clear the file input in JavaScript
        socket = push_event(socket, "avatar-upload-complete", %{})

        {:noreply, assign(socket, profile: updated_profile)}

      {:error, reason} ->
        error_msg = "Failed to delete avatar: #{inspect(reason)}"
        Flash.error(error_msg)
        {:noreply, socket}
    end
  end

  def handle_event("toggle_timezone_dropdown", _params, socket) do
    {:noreply, assign(socket, timezone_dropdown_open: !socket.assigns.timezone_dropdown_open)}
  end

  def handle_event("close_timezone_dropdown", _params, socket) do
    {:noreply, assign(socket, timezone_dropdown_open: false)}
  end

  def handle_event("search_timezone", %{"search" => search}, socket) do
    {:noreply, assign(socket, timezone_search: search)}
  end

  def handle_event("search_timezone", %{"value" => search}, socket) do
    {:noreply, assign(socket, timezone_search: search)}
  end

  def handle_event("change_timezone", %{"timezone" => timezone}, socket) do
    metadata = DashboardHelpers.get_security_metadata(socket)
    socket = assign(socket, timezone_dropdown_open: false, timezone_search: "")

    # First validate the timezone
    case SettingsInputProcessor.validate_timezone_update(timezone, metadata: metadata) do
      {:ok, sanitized_timezone} ->
        handle_profile_update(
          socket,
          fn profile -> Profiles.update_timezone(profile, sanitized_timezone) end,
          fn updated_profile ->
            label = label_for_timezone(socket, updated_profile.timezone)
            "Timezone updated to #{label}"
          end
        )

      {:error, validation_error} ->
        errors = Map.put(socket.assigns.form_errors, :timezone, validation_error)
        socket = assign(socket, :form_errors, errors)
        {:noreply, socket}
    end
  end

  # Private helpers

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
     |> assign(:form_errors, Map.delete(socket.assigns.form_errors, :username))}
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

  defp handle_profile_update(socket, update_fn, success_msg) do
    profile = socket.assigns.profile
    socket = assign(socket, :saving, true)

    case update_fn.(profile) do
      {:ok, updated_profile} ->
        msg = if is_function(success_msg), do: success_msg.(updated_profile), else: success_msg

        send(self(), {:profile_updated, updated_profile})
        Flash.info(msg)

        {:noreply,
         socket
         |> assign(profile: updated_profile)
         |> assign(saving: false)}

      other ->
        Flash.error(error_to_message(other))
        {:noreply, assign(socket, saving: false)}
    end
  end

  defp error_to_message({:error, %Ecto.Changeset{} = changeset}) do
    ChangesetUtils.get_first_error(changeset)
  end

  defp error_to_message({:error, message}) do
    "#{message}"
  end

  defp handle_avatar_upload_result(uploaded_files, socket) do
    case uploaded_files do
      [{:ok, updated_profile}] ->
        handle_successful_avatar_upload(updated_profile, socket)

      [%{__struct__: _} = updated_profile] ->
        handle_successful_avatar_upload(updated_profile, socket)

      [{:error, _} = error | _] ->
        handle_avatar_upload_error(error, socket)

      [] ->
        Flash.error("No file was uploaded")
        {:noreply, socket}

      [error_message] when is_binary(error_message) ->
        Flash.error(error_message)
        {:noreply, socket}

      error_messages when is_list(error_messages) ->
        error_msg = List.first(error_messages) || "Upload failed"
        Flash.error(error_msg)
        {:noreply, socket}
    end
  end

  defp handle_successful_avatar_upload(updated_profile, socket) do
    send(self(), {:profile_updated, updated_profile})
    Flash.info("Avatar updated successfully")

    # Push event to clear the file input in JavaScript
    socket = push_event(socket, "avatar-upload-complete", %{})

    {:noreply, assign(socket, profile: updated_profile)}
  end

  defp handle_avatar_upload_error(error, socket) do
    error_msg = format_upload_error(error)
    Flash.error(error_msg)
    {:noreply, socket}
  end

  # Helpers to reduce nesting
  defp maybe_update_full_name(socket, sanitized_name) do
    profile = socket.assigns.profile

    if profile && sanitized_name != profile.full_name do
      handle_profile_update(
        socket,
        fn p -> Profiles.update_full_name(p, sanitized_name) end,
        "Display name updated"
      )
    else
      {:noreply, socket}
    end
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

  defp label_for_timezone(socket, timezone_value) do
    case Enum.find(socket.assigns.timezone_options, fn {_label, value} ->
           value == timezone_value
         end) do
      {label, _value} -> label
      _ -> timezone_value
    end
  end

  defp format_upload_error({:error, %Ecto.Changeset{} = changeset}) do
    ChangesetUtils.get_first_error(changeset)
  end

  defp format_upload_error({:error, reason}) do
    "Upload failed: #{inspect(reason)}"
  end

  defp avatar_error_to_string(:too_large), do: "File too large (max 10MB)"
  defp avatar_error_to_string(:too_many_files), do: "Too many files"
  defp avatar_error_to_string(:not_accepted), do: "File type not accepted"
  defp avatar_error_to_string(err), do: "Upload error: #{inspect(err)}"

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <DashboardComponents.section_header icon={:user} title="Profile Settings" saving={@saving} />

      <div class="space-y-8">
        <!-- Avatar Upload Section -->
        <div class="card-glass" phx-hook="AutoUpload" id="avatar-upload-section">
          <h3 class="text-lg font-medium text-gray-800 mb-4">Profile Picture</h3>
          <div class="flex items-center space-x-4">
            <div class="w-20 h-20 rounded-full overflow-hidden bg-white/20 backdrop-blur-sm border border-purple-400/30">
              <img
                src={Profiles.avatar_url(@profile, :thumb)}
                alt={Profiles.avatar_alt_text(@profile)}
                class="w-full h-full object-cover"
              />
            </div>
            <div class="flex-1">
              <form
                id="avatar-upload-form"
                phx-submit="upload_avatar"
                phx-change="validate_avatar"
                data-auto-upload="true"
              >
                <div class="flex items-center space-x-4">
                  <div class="relative">
                    <%= if @parent_uploads && @parent_uploads[:avatar] do %>
                      <.live_file_input
                        upload={@parent_uploads.avatar}
                        class="absolute inset-0 w-full h-full opacity-0 cursor-pointer"
                      />
                      <label
                        for={@parent_uploads.avatar.ref}
                        class="btn btn-primary btn-sm cursor-pointer"
                      >
                        <svg
                          class="w-4 h-4 mr-2"
                          fill="none"
                          stroke="currentColor"
                          viewBox="0 0 24 24"
                        >
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="2"
                            d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12"
                          >
                          </path>
                        </svg>
                        <%= if @parent_uploads && @parent_uploads[:avatar] && @parent_uploads.avatar.entries != [] do %>
                          <span class="animate-pulse">Uploading...</span>
                        <% else %>
                          Upload New
                        <% end %>
                      </label>
                    <% else %>
                      <div class="btn btn-primary btn-sm opacity-50 cursor-not-allowed">
                        <svg
                          class="w-4 h-4 mr-2"
                          fill="none"
                          stroke="currentColor"
                          viewBox="0 0 24 24"
                        >
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="2"
                            d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12"
                          >
                          </path>
                        </svg>
                        Upload New
                      </div>
                    <% end %>
                  </div>
                  <!-- Hidden submit button for auto-upload -->
                  <button type="submit" id="avatar-submit-btn" style="display: none;">
                    Upload
                  </button>
                  <%= if @profile.avatar do %>
                    <button
                      type="button"
                      phx-click="show_delete_avatar_modal"
                      phx-target={@myself}
                      class="btn btn-sm bg-red-600 hover:bg-red-700 text-white"
                    >
                      <svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                        >
                        </path>
                      </svg>
                      Delete
                    </button>
                  <% end %>
                </div>

    <!-- Upload progress -->
                <%= if @parent_uploads && @parent_uploads[:avatar] do %>
                  <%= for entry <- @parent_uploads.avatar.entries do %>
                    <div class="mt-4 p-3 bg-blue-50 border border-blue-200 rounded-lg">
                      <div class="flex items-center justify-between text-sm">
                        <div class="flex items-center">
                          <svg
                            class="animate-spin h-4 w-4 mr-2 text-blue-600"
                            fill="none"
                            viewBox="0 0 24 24"
                          >
                            <circle
                              class="opacity-25"
                              cx="12"
                              cy="12"
                              r="10"
                              stroke="currentColor"
                              stroke-width="4"
                            >
                            </circle>
                            <path
                              class="opacity-75"
                              fill="currentColor"
                              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                            >
                            </path>
                          </svg>
                          <span class="text-blue-700 font-medium">
                            <%= if entry.progress == 100 do %>
                              Processing...
                            <% else %>
                              Uploading...
                            <% end %>
                          </span>
                        </div>
                        <span class="text-blue-600 font-bold">{entry.progress}%</span>
                      </div>
                      <div class="mt-2 text-xs text-gray-600">{entry.client_name}</div>
                      <div class="mt-2 bg-white/50 rounded-full h-2">
                        <div
                          class="bg-gradient-to-r from-blue-500 to-purple-600 h-2 rounded-full transition-all duration-300"
                          style={"width: #{entry.progress}%"}
                        >
                        </div>
                      </div>
                    </div>
                  <% end %>
                <% end %>

    <!-- Only show upload errors if we're not in the middle of saving -->
                <%= if @parent_uploads && @parent_uploads[:avatar] && @parent_uploads.avatar.entries != [] && !@saving do %>
                  <%= for err <- upload_errors(@parent_uploads.avatar) do %>
                    <p class="mt-2 text-sm text-red-400">
                      {avatar_error_to_string(err)}
                    </p>
                  <% end %>
                <% end %>

                <p class="mt-2 text-sm text-gray-600">
                  JPG, PNG, GIF or WebP. Max 10MB. Files upload automatically after selection.
                </p>
              </form>
            </div>
          </div>
        </div>

    <!-- Settings Form -->
        <div class="card-glass">
          <div class="space-y-6">
            <.full_name_setting profile={@profile} myself={@myself} form_errors={@form_errors} />
            <.username_setting
              profile={@profile}
              username_check={@username_check}
              username_available={@username_available}
              myself={@myself}
              form_errors={@form_errors}
            />
            <.timezone_setting
              profile={@profile}
              timezone_options={@timezone_options}
              timezone_dropdown_open={@timezone_dropdown_open}
              timezone_search={@timezone_search}
              myself={@myself}
              form_errors={@form_errors}
            />
          </div>
        </div>
      </div>

    <!-- Delete Avatar Modal -->
      <CoreComponents.modal
        id="delete-avatar-modal"
        show={@show_delete_avatar_modal}
        on_cancel={Phoenix.LiveView.JS.push("hide_delete_avatar_modal", target: @myself)}
        size={:medium}
      >
        <:header>
          <svg class="w-5 h-5 text-red-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z"
            />
          </svg>
          Delete Avatar
        </:header>
        <p>
          Are you sure you want to delete your avatar? This action cannot be undone.
        </p>
        <:footer>
          <CoreComponents.action_button
            variant={:secondary}
            phx-click={Phoenix.LiveView.JS.push("hide_delete_avatar_modal", target: @myself)}
          >
            Cancel
          </CoreComponents.action_button>
          <CoreComponents.action_button
            variant={:danger}
            phx-click={Phoenix.LiveView.JS.push("delete_avatar", target: @myself)}
          >
            Delete Avatar
          </CoreComponents.action_button>
        </:footer>
      </CoreComponents.modal>
    </div>
    """
  end

  # Component functions
  defp full_name_setting(assigns) do
    ~H"""
    <FormSystem.form_wrapper for={%{}} phx_change="validate_full_name" phx_target={@myself}>
      <FormSystem.text_field
        name="full_name"
        value={if @profile, do: @profile.full_name || "", else: ""}
        label="Display Name"
        placeholder="Enter your full name"
        help="This name will appear to visitors when they book meetings with you. Changes are saved automatically."
        errors={if @form_errors[:full_name], do: [@form_errors[:full_name]], else: []}
        phx-debounce="500"
      />
    </FormSystem.form_wrapper>
    """
  end

  defp timezone_setting(assigns) do
    ~H"""
    <div>
      <TimezoneDropdown.timezone_dropdown
        profile={@profile}
        timezone_options={@timezone_options}
        timezone_dropdown_open={@timezone_dropdown_open}
        timezone_search={@timezone_search}
        target={@myself}
        safe_flags={false}
      />
      <%= if @form_errors[:timezone] do %>
        <p class="text-sm text-red-400 mt-1">{@form_errors[:timezone]}</p>
      <% end %>
    </div>
    """
  end

  defp username_setting(assigns) do
    ~H"""
    <form phx-submit="update_username" phx-change="check_username_availability" phx-target={@myself}>
      <div>
        <label for="username" class="label text-gray-700">
          Your Custom URL
        </label>
        <div class="flex items-center space-x-3">
          <% base_url = Policy.app_url() %>
          <% display_url = String.replace(base_url, ~r/^https?:\/\//, "") %>
          <span class="text-sm text-gray-600">{display_url}/</span>
          <input
            type="text"
            id="username"
            name="username"
            value={if @profile, do: @profile.username || "", else: ""}
            placeholder="yourname"
            pattern="[a-z0-9][a-z0-9-]{2,29}"
            minlength="3"
            maxlength="30"
            phx-debounce="500"
            class={[
              "glass-input flex-1",
              if(@form_errors[:username], do: "border-red-500", else: "")
            ]}
          />
          <%= if @form_errors[:username] do %>
            <p class="text-sm text-red-400 mt-1">{@form_errors[:username]}</p>
          <% end %>
          <button type="submit" class="btn btn-primary" phx-disable-with="Saving...">
            Save
          </button>
        </div>
        <div class="mt-2">
          <%= if @profile && @profile.username do %>
            <% base_url = Policy.app_url() %>
            <% display_url = String.replace(base_url, ~r/^https?:\/\//, "") %>
            <p class="text-sm text-green-400">
              Your booking page:
              <a
                href={"#{base_url}/#{if @profile, do: @profile.username, else: ""}"}
                target="_blank"
                class="link"
              >
                {display_url}/{if @profile, do: @profile.username, else: ""}
              </a>
            </p>
          <% else %>
            <p class="text-sm text-gray-600">
              Choose a unique username for your personal booking page. Use lowercase letters, numbers, and hyphens only.
            </p>
          <% end %>

          <%= if @username_check && (!@profile || @username_check != @profile.username) do %>
            <div class="mt-2">
              <%= case @username_available do %>
                <% true -> %>
                  <p class="text-sm text-green-400 flex items-center">
                    <svg class="w-4 h-4 mr-1" fill="currentColor" viewBox="0 0 20 20">
                      <path
                        fill-rule="evenodd"
                        d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
                        clip-rule="evenodd"
                      />
                    </svg>
                    Username is available!
                  </p>
                <% false -> %>
                  <p class="text-sm text-red-400 flex items-center">
                    <svg class="w-4 h-4 mr-1" fill="currentColor" viewBox="0 0 20 20">
                      <path
                        fill-rule="evenodd"
                        d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z"
                        clip-rule="evenodd"
                      />
                    </svg>
                    Username is already taken
                  </p>
                <% {:error, message} -> %>
                  <p class="text-sm text-yellow-400">
                    {message}
                  </p>
                <% _ -> %>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </form>
    """
  end
end
