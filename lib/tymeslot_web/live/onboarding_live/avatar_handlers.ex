defmodule TymeslotWeb.OnboardingLive.AvatarHandlers do
  @moduledoc """
  Avatar upload handling for the onboarding profile step.

  Owns the auto-upload progress callback (rate-limited per user) and consuming
  the finished upload onto the profile, keeping the upload lifecycle out of the
  LiveView.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.UploadHandler
  alias TymeslotWeb.OnboardingLive.BasicSettingsShared

  @doc """
  `allow_upload` progress callback. On completion it rate-limits the upload and
  then consumes it onto the profile; otherwise it leaves the socket untouched.

  This entry being done is not on its own enough to consume: the callback runs
  per entry and `consume_uploaded_entries/3` raises if any sibling is still in
  flight, so `UploadHandler.settle_upload/2` decides when the upload as a whole
  is ready.
  """
  @spec handle_progress(atom(), Phoenix.LiveView.UploadEntry.t(), LiveView.Socket.t()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_progress(_name, entry, socket) do
    if entry.done? do
      case UploadHandler.settle_upload(socket, :avatar) do
        {socket, :settled} -> rate_limit_and_consume(socket, entry)
        {socket, :in_progress} -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  defp rate_limit_and_consume(socket, entry) do
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
         |> LiveView.put_flash(
           :error,
           dgettext("onboarding_wizard", "Upload failed. Please refresh and try again.")
         )}
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
        socket
        |> LiveView.push_event("upload-complete", %{})
        |> Component.assign(:profile, updated)

      [{:error, _reason}] ->
        LiveView.put_flash(
          socket,
          :error,
          dgettext(
            "onboarding_wizard",
            "Could not update your photo. Please try a different image."
          )
        )

      _other ->
        socket
    end
  end
end
