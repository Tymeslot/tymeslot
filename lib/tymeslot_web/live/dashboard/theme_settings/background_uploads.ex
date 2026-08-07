defmodule TymeslotWeb.Dashboard.ThemeSettings.BackgroundUploads do
  @moduledoc """
  The background image and video upload pipeline for theme customisation.

  Split from `ThemeCustomizationComponent`, which is otherwise about choosing
  colours and themes. Uploading is a separate concern with its own lifecycle:
  declare the sockets up front, receive progress callbacks as bytes arrive,
  consume the finished entry, then re-read the profile to pick up the new path.

  Image and video differ only in their constraints and which processing
  function runs, so they are driven from `@kinds` rather than written twice.

  ## Consuming happens in a later message

  `allow_upload/3`'s progress callback runs in the *parent* LiveView process,
  not the component, so it cannot consume the upload itself. It sends the
  component a message instead, and consumption happens when that arrives. That
  is why `configure/2` needs the component module: it is the `send_update/3`
  target, and getting it wrong means uploads silently never complete.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [allow_upload: 3, send_update: 3]

  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.ThemeCustomizations
  alias TymeslotWeb.Helpers.ThemeUploadHelper
  alias TymeslotWeb.Helpers.UploadConstraints
  alias TymeslotWeb.Live.Shared.Flash

  # Five uploads per ten minutes, shared across both kinds: video encoding is
  # the expensive part and a per-kind budget would double the ceiling.
  @rate_limit_max 5
  @rate_limit_window_ms 600_000

  @kinds %{
    image: %{upload_key: :background_image, constraint: :image},
    video: %{upload_key: :background_video, constraint: :video}
  }

  @typedoc "Which background asset is being uploaded."
  @type kind :: :image | :video

  @doc """
  Declares both upload sockets, unless they are already declared.

  `component` is the LiveComponent module the progress callbacks notify; see
  the module docs on why consumption cannot happen in the callback itself.
  """
  @spec configure(Phoenix.LiveView.Socket.t(), module()) :: Phoenix.LiveView.Socket.t()
  def configure(socket, component) do
    if socket.assigns[:uploads] && socket.assigns.uploads[:background_image] do
      socket
    else
      Enum.reduce(@kinds, socket, fn {kind, config}, acc ->
        allow_upload(acc, config.upload_key,
          accept: UploadConstraints.allowed_extensions(config.constraint),
          max_entries: 1,
          max_file_size: UploadConstraints.max_file_size(config.constraint),
          auto_upload: true,
          progress: progress_callback(component, kind)
        )
      end)
    end
  end

  @doc """
  Consumes a finished upload and refreshes the customisation from the profile.

  Readiness is checked *before* the rate limit, and deliberately so. Both
  entry points reach here: the `phx-change` validate handler fires on every
  change event during an upload, so charging the limit first would spend a
  user's whole budget on events that had nothing to consume, and lock them out
  of their own upload part-way through. Charging only when there is genuinely a
  finished file to process makes the limit mean "uploads processed", which is
  the thing worth limiting.

  A rate-limited or not-yet-finished upload returns the socket untouched: the
  entry stays put and the next progress message tries again.
  """
  @spec consume(Phoenix.LiveView.Socket.t(), kind()) :: Phoenix.LiveView.Socket.t()
  def consume(socket, kind) do
    if ready?(socket, @kinds[kind].upload_key) do
      rate_limited(socket, fn -> process(socket, kind) end)
    else
      socket
    end
  end

  defp rate_limited(socket, fun) do
    user_id = socket.assigns.profile.user_id

    case RateLimiter.check_rate_limit(
           "theme_upload:#{user_id}",
           @rate_limit_max,
           @rate_limit_window_ms
         ) do
      :ok ->
        fun.()

      {:error, :rate_limited} ->
        Flash.error(
          dgettext(
            "dashboard_appearance",
            "Too many upload attempts. Please wait a few minutes and try again."
          )
        )

        socket
    end
  end

  defp progress_callback(component, kind) do
    fn _config, entry, socket ->
      if entry.done? do
        send_update(self(), component, id: socket.assigns.id, consume_upload: kind)
      end

      {:noreply, socket}
    end
  end

  defp process(socket, :image) do
    socket
    |> ThemeUploadHelper.process_background_image_upload(socket.assigns.profile)
    |> apply_result(socket)
  end

  defp process(socket, :video) do
    socket
    |> ThemeUploadHelper.process_background_video_upload(socket.assigns.profile)
    |> apply_result(socket)
  end

  defp apply_result({:ok, message}, socket) do
    # Re-read the customisation so the new asset path is reflected immediately.
    %{customization: customization} =
      ThemeCustomizations.initialize_customization(
        socket.assigns.profile.id,
        socket.assigns.theme_id
      )

    Flash.info(message)
    assign(socket, :customization, customization)
  end

  defp apply_result({:error, message}, socket) do
    Flash.error(message)
    socket
  end

  # Consuming an in-flight entry would truncate the file, so every entry must
  # have finished or been cancelled first.
  defp ready?(socket, upload_key) do
    case socket.assigns.uploads[upload_key] do
      nil -> false
      %{entries: []} -> false
      %{entries: entries} -> Enum.all?(entries, &(&1.done? or &1.cancelled?))
    end
  end
end
