defmodule TymeslotWeb.Dashboard.ProfileSettings.AvatarUploadComponent do
  @moduledoc """
  Avatar upload component for profile settings.
  Allows users to upload or delete their profile picture.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.Avatars
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.ChangesetUtils

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if socket.assigns[:uploads] && socket.assigns.uploads[:avatar] do
        socket
      else
        allow_upload(socket, :avatar,
          accept: Avatars.accepted_extensions(),
          max_entries: 1,
          max_file_size: Avatars.max_file_size(),
          auto_upload: true,
          progress: &handle_avatar_progress/3
        )
      end

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate_avatar", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload_avatar", _params, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_avatar_upload_rate_limit(user_id) do
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      :ok ->
        metadata = DashboardHelpers.get_security_metadata(socket)
        {:noreply, consume_avatar_upload(socket, metadata)}
    end
  end

  defp handle_avatar_progress(_config, entry, socket) do
    if entry.done? do
      user_id = socket.assigns.current_user.id

      case RateLimiter.check_avatar_upload_rate_limit(user_id) do
        {:error, :rate_limited, message} ->
          Flash.error(message)
          {:noreply, socket}

        :ok ->
          metadata = DashboardHelpers.get_security_metadata(socket)
          {:noreply, consume_avatar_upload(socket, metadata)}
      end
    else
      {:noreply, socket}
    end
  end

  defp consume_avatar_upload(socket, metadata) do
    profile = socket.assigns.profile

    results =
      consume_uploaded_entries(
        socket,
        :avatar,
        &Profiles.consume_avatar_upload(profile, &1, &2, metadata)
      )

    case results do
      [{:ok, updated_profile}] ->
        handle_successful_avatar_upload(updated_profile, socket)

      [%{__struct__: _module} = updated_profile] ->
        handle_successful_avatar_upload(updated_profile, socket)

      [{:error, _reason} = error | _rest] ->
        handle_avatar_upload_error(error, socket)

      [] ->
        socket

      [error_message] when is_binary(error_message) ->
        Flash.error(error_message)
        socket

      error_messages when is_list(error_messages) ->
        Flash.error(List.first(error_messages) || "Upload failed")
        socket
    end
  end

  defp handle_successful_avatar_upload(updated_profile, socket) do
    send(self(), {:profile_updated, updated_profile})
    Flash.info("Avatar updated successfully")
    socket = push_event(socket, "avatar-upload-complete", %{})
    assign(socket, profile: updated_profile)
  end

  defp handle_avatar_upload_error({:error, %Ecto.Changeset{} = changeset}, socket) do
    Flash.error(ChangesetUtils.get_first_error(changeset))
    socket
  end

  defp handle_avatar_upload_error({:error, reason}, socket) do
    Flash.error("Upload failed: #{inspect(reason)}")
    socket
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="avatar-upload-container" class="lg:col-span-1 space-y-8 text-center pt-4">
      <.section_header level={3} title="Profile Picture" />

      <div class="relative inline-block mb-8" phx-hook="AutoUpload" id="avatar-upload-section">
        <div class="w-40 h-40 rounded-[2.5rem] overflow-hidden bg-tymeslot-100 border-4 border-white shadow-2xl relative z-10 mx-auto">
          <img
            src={Profiles.avatar_url(@profile, :thumb)}
            alt={Profiles.avatar_alt_text(@profile)}
            class="w-full h-full object-cover"
          />
        </div>
        <div class="absolute inset-0 bg-turquoise-400 blur-2xl opacity-20 rounded-full scale-75 transition-opacity"></div>
      </div>

      <div class="space-y-4 max-w-[240px] mx-auto">
        <form
          id="avatar-upload-form"
          phx-submit="upload_avatar"
          phx-change="validate_avatar"
          phx-target={@myself}
          data-auto-upload="true"
          class="flex flex-col items-center gap-4"
        >
          <div class="w-full">
            <%= if @uploads && @uploads[:avatar] do %>
              <div class="relative group/input">
                <.live_file_input
                  upload={@uploads.avatar}
                  class="absolute inset-0 w-full h-full opacity-0 cursor-pointer z-20"
                />
                <div class="btn-primary w-full flex items-center justify-center gap-2 py-4 whitespace-nowrap">
                  <svg class="w-5 h-5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12" />
                  </svg>
                  <span><%= if @uploads.avatar.entries != [], do: "Uploading...", else: "Upload New" %></span>
                </div>
              </div>
            <% else %>
              <div class="btn-primary w-full opacity-50 cursor-not-allowed py-4">
                Upload New
              </div>
            <% end %>
          </div>

          <%= if @profile.avatar do %>
            <button
              type="button"
              phx-click="show"
              phx-target="#delete-avatar-modal"
              class="btn-danger w-full py-4 flex items-center justify-center gap-2 whitespace-nowrap"
            >
              <svg class="w-5 h-5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
              </svg>
              <span>Delete Photo</span>
            </button>
          <% end %>

          <button type="submit" id="avatar-submit-btn" class="hidden">Upload</button>
        </form>

        <p class="text-[10px] text-tymeslot-400 font-bold uppercase tracking-widest pt-2">
          JPG, PNG, GIF or WebP. Max 10MB.
        </p>

        <%!-- Upload progress --%>
        <%= if @uploads && @uploads[:avatar] do %>
          <%= for err <- upload_errors(@uploads.avatar) do %>
            <div class="mt-4 p-3 bg-red-50 border border-red-100 rounded-token-xl text-red-600 text-xs font-bold flex items-center gap-2 animate-in slide-in-from-top-1">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
              {Phoenix.Naming.humanize(err)}
            </div>
          <% end %>

          <%= for entry <- @uploads.avatar.entries do %>
            <div class="mt-6 p-4 bg-turquoise-50 rounded-token-2xl border-2 border-turquoise-100 animate-in fade-in zoom-in">
              <div class="flex items-center justify-between mb-2">
                <span class="text-turquoise-700 font-black text-xs uppercase tracking-wider">
                  <%= if entry.progress == 100, do: "Processing...", else: "Uploading..." %>
                </span>
                <span class="text-turquoise-600 font-black text-xs">{entry.progress}%</span>
              </div>
              <div class="bg-white rounded-full h-2 overflow-hidden shadow-inner">
                <div
                  class="bg-gradient-to-r from-turquoise-500 to-cyan-500 h-full transition-all duration-300"
                  style={"width: #{entry.progress}%"}
                ></div>
              </div>
            </div>

            <%= for err <- upload_errors(@uploads.avatar, entry) do %>
              <div class="mt-2 p-3 bg-red-50 border border-red-100 rounded-token-xl text-red-600 text-xs font-bold flex items-center gap-2 animate-in slide-in-from-top-1">
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                {Phoenix.Naming.humanize(err)}
              </div>
            <% end %>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end
end
