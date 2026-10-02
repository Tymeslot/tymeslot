defmodule TymeslotWeb.Dashboard.ProfileSettings.AvatarUploadComponent do
  @moduledoc """
  Avatar upload component for profile settings.
  Allows users to upload or delete their profile picture.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.Avatars
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.ChangesetUtils
  alias TymeslotWeb.Helpers.UploadHandler

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
    case UploadHandler.settle_upload(socket, :avatar) do
      {socket, :settled} -> rate_limit_and_consume(socket)
      {socket, :in_progress} -> {:noreply, socket}
    end
  end

  # `consume_uploaded_entries/3` raises while any entry is still in flight, and
  # neither trigger guarantees the upload has settled: the progress callback
  # runs per entry and reports only its own, and the button can be pressed
  # mid-upload. Both therefore route through `settle_upload/2`.
  defp handle_avatar_progress(_config, entry, socket) do
    if entry.done? do
      case UploadHandler.settle_upload(socket, :avatar) do
        {socket, :settled} -> rate_limit_and_consume(socket)
        {socket, :in_progress} -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  defp rate_limit_and_consume(socket) do
    case RateLimiter.check_avatar_upload_rate_limit(socket.assigns.current_user.id) do
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      :ok ->
        metadata = DashboardHelpers.get_security_metadata(socket)
        {:noreply, consume_avatar_upload(socket, metadata)}
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
        Flash.error(List.first(error_messages) || dgettext("dashboard_profile", "Upload failed"))
        socket
    end
  end

  defp handle_successful_avatar_upload(updated_profile, socket) do
    send(self(), {:profile_updated, updated_profile})
    Flash.info(dgettext("dashboard_profile", "Avatar updated successfully"))
    socket = push_event(socket, "upload-complete", %{})
    assign(socket, profile: updated_profile)
  end

  defp handle_avatar_upload_error({:error, %Ecto.Changeset{} = changeset}, socket) do
    Flash.error(ChangesetUtils.get_first_error(changeset))
    socket
  end

  defp handle_avatar_upload_error({:error, reason}, socket) do
    Flash.error(
      dgettext("dashboard_profile", "Upload failed: %{reason}", reason: inspect(reason))
    )

    socket
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div
      id="avatar-upload-container"
      class="lg:col-span-1 space-y-8 text-center pt-4"
      phx-hook="AutoUpload"
    >
      <.section_header level={3} title={dgettext("dashboard_profile", "Profile Picture")} />

      <div class="relative inline-block mb-8" id="avatar-upload-section">
        <div class="w-40 h-40 rounded-[2.5rem] overflow-hidden bg-tymeslot-100 border-4 border-white shadow-2xl relative z-10 mx-auto">
          <img
            src={Profiles.avatar_url(@profile, :thumb)}
            alt={Profiles.avatar_alt_text(@profile)}
            class="w-full h-full object-cover"
          />
        </div>
        <div class="absolute inset-0 bg-turquoise-400 blur-2xl opacity-20 rounded-full scale-75 transition-opacity">
        </div>
      </div>

      <div class="space-y-4 max-w-[240px] mx-auto">
        <form
          id="avatar-upload-form"
          phx-submit="upload_avatar"
          phx-change="validate_avatar"
          phx-target={@myself}
          class="flex flex-col items-center gap-4"
        >
          <div class="w-full">
            <%= if @uploads && @uploads[:avatar] do %>
              <div class="relative group/input">
                <.live_file_input
                  upload={@uploads.avatar}
                  class="absolute inset-0 w-full h-full opacity-0 cursor-pointer z-20"
                />
                <div class={[button_classes(:primary), "w-full"]}>
                  <.icon name="hero-cloud-arrow-up" class="w-5 h-5 shrink-0" />
                  <span>
                    {if @uploads.avatar.entries != [],
                      do: dgettext("dashboard_profile", "Uploading..."),
                      else: dgettext("dashboard_profile", "Upload New")}
                  </span>
                </div>
              </div>
            <% else %>
              <div class={[button_classes(:primary), "w-full opacity-50"]} aria-disabled="true">
                {dgettext("dashboard_profile", "Upload New")}
              </div>
            <% end %>
          </div>

          <%= if @profile.avatar do %>
            <.action_button
              variant={:danger_soft}
              icon="hero-trash"
              class="w-full"
              phx-click="show"
              phx-target="#delete-avatar-modal"
            >
              {dgettext("dashboard_profile", "Delete Photo")}
            </.action_button>
          <% end %>

          <button type="submit" id="avatar-submit-btn" class="hidden">
            {dgettext("dashboard_profile", "Upload")}
          </button>
        </form>

        <p class="text-token-2xs text-tymeslot-400 font-bold uppercase tracking-widest pt-2">
          {dgettext("dashboard_profile", "JPG, PNG, GIF or WebP. Max 10MB.")}
        </p>

        <%!-- Upload progress --%>
        <%= if @uploads && @uploads[:avatar] do %>
          <%= for err <- upload_errors(@uploads.avatar) do %>
            <div class="mt-4 p-3 bg-red-50 border border-red-100 rounded-token-xl text-red-600 text-xs font-bold flex items-center gap-2">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2.5"
                  d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
              {Phoenix.Naming.humanize(err)}
            </div>
          <% end %>

          <%= for entry <- @uploads.avatar.entries do %>
            <div class="mt-6 p-4 bg-turquoise-50 rounded-token-2xl border-2 border-turquoise-100">
              <div class="flex items-center justify-between mb-2">
                <span class="text-turquoise-700 font-black text-xs uppercase tracking-wider">
                  {if entry.progress == 100,
                    do: dgettext("dashboard_profile", "Processing..."),
                    else: dgettext("dashboard_profile", "Uploading...")}
                </span>
                <span class="text-turquoise-600 font-black text-xs">{entry.progress}%</span>
              </div>
              <div class="bg-white rounded-full h-2 overflow-hidden shadow-inner">
                <div
                  class="bg-linear-to-r from-turquoise-500 to-cyan-500 h-full transition-all duration-300"
                  style={"width: #{entry.progress}%"}
                >
                </div>
              </div>
            </div>

            <%= for err <- upload_errors(@uploads.avatar, entry) do %>
              <div class="mt-2 p-3 bg-red-50 border border-red-100 rounded-token-xl text-red-600 text-xs font-bold flex items-center gap-2">
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2.5"
                    d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                  />
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
