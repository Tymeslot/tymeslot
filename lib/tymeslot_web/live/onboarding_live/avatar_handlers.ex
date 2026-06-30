defmodule TymeslotWeb.OnboardingLive.AvatarHandlers do
  @moduledoc """
  Avatar upload handling for the onboarding profile step.

  Owns the auto-upload progress callback (rate-limited per user) and consuming
  the finished upload onto the profile, keeping the upload lifecycle out of the
  LiveView.
  """

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.OnboardingLive.BasicSettingsShared

  @doc """
  `allow_upload` progress callback. On completion it rate-limits the upload and
  then consumes it onto the profile; otherwise it leaves the socket untouched.
  """
  @spec handle_progress(atom(), Phoenix.LiveView.UploadEntry.t(), LiveView.Socket.t()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_progress(_name, entry, socket) do
    if entry.done? do
      case RateLimiter.check_avatar_upload_rate_limit(socket.assigns.current_user.id) do
        :ok ->
          {:noreply, consume(socket)}

        {:error, :rate_limited, message} ->
          {:noreply,
           socket
           |> LiveView.cancel_upload(:avatar, entry.ref)
           |> LiveView.put_flash(:error, message)}

        {:error, :invalid_user_id} ->
          {:noreply,
           socket
           |> LiveView.cancel_upload(:avatar, entry.ref)
           |> LiveView.put_flash(:error, "Upload failed. Please refresh and try again.")}
      end
    else
      {:noreply, socket}
    end
  end

  defp consume(socket) do
    profile = socket.assigns.profile
    metadata = BasicSettingsShared.metadata(socket)

    results =
      LiveView.consume_uploaded_entries(
        socket,
        :avatar,
        &Profiles.consume_avatar_upload(profile, &1, &2, metadata)
      )

    case results do
      [%ProfileSchema{} = updated] ->
        Component.assign(socket, :profile, updated)

      [{:error, _reason}] ->
        LiveView.put_flash(
          socket,
          :error,
          "Could not update your photo. Please try a different image."
        )

      _other ->
        socket
    end
  end
end
