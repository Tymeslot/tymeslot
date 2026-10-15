defmodule TymeslotWeb.Dashboard.ThemeSettings.AssetUploads do
  @moduledoc """
  The upload pipeline for a theme's asset fields: the background image and
  video, and any file an option group of a theme's own declares.

  Split from `ThemeCustomizationComponent`, which is otherwise about choosing
  options. Uploading is a separate concern with its own lifecycle: declare the
  sockets up front, receive progress callbacks as bytes arrive, consume the
  finished entry, which hands the file to `ThemeCustomizations.attach_asset/4`
  and gets the saved customisation back.

  One upload per asset field of the theme's spec
  (`ThemeCustomizations.asset_fields/1`), named after the field
  (`@uploads.background_image_path`), with the constraints of the field's kind.
  An upload form sends `upload_asset` with a hidden `asset_field` input naming
  its field.

  ## Consuming happens in a later message

  `allow_upload/3`'s progress callback runs in the *parent* LiveView process,
  not the component, so it cannot consume the upload itself. It sends the
  component a message instead, and consumption happens when that arrives. That
  is why `configure/3` needs the component module: it is the `send_update/3`
  target, and getting it wrong means uploads silently never complete.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [allow_upload: 3, consume_uploaded_entries: 3, send_update: 3]

  alias Tymeslot.Media.UploadConstraints
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.ThemeCustomizations
  alias TymeslotWeb.Helpers.ImageUploadErrors
  alias TymeslotWeb.Live.Shared.Flash

  # Five uploads per ten minutes, shared across every field: video encoding is
  # the expensive part and a per-field budget would multiply the ceiling.
  @rate_limit_max 5
  @rate_limit_window_ms 600_000

  @doc """
  Declares an upload input for each asset field the theme's spec lists
  (`ThemeCustomizations.asset_fields/1`), named after the field and limited as
  its kind is, skipping any already declared. A theme without asset fields
  gets none.

  `component` is the LiveComponent module the progress callbacks notify; see
  the module docs on why consumption cannot happen in the callback itself.
  """
  @spec configure(Phoenix.LiveView.Socket.t(), module(), [{atom(), atom()}]) ::
          Phoenix.LiveView.Socket.t()
  def configure(socket, component, asset_fields) do
    Enum.reduce(asset_fields, socket, fn {field, kind}, acc ->
      if declared?(acc, field) do
        acc
      else
        allow_upload(acc, field,
          accept: UploadConstraints.allowed_extensions(kind),
          max_entries: 1,
          max_file_size: UploadConstraints.max_file_size(kind),
          auto_upload: true,
          progress: progress_callback(component, field)
        )
      end
    end)
  end

  defp declared?(socket, field), do: Map.has_key?(socket.assigns[:uploads] || %{}, field)

  @doc """
  Consumes a finished upload into the asset field `field`, saving it through
  `ThemeCustomizations.attach_asset/4`, and assigns the saved customisation.
  A field the theme does not declare is ignored.

  Readiness is checked *before* the rate limit, and deliberately so. Both
  entry points reach here: the `phx-change` validate handler fires on every
  change event during an upload, so charging the limit first would spend a
  user's whole budget on events that had nothing to consume, and lock them out
  of their own upload part-way through. Charging only when there is genuinely a
  finished file to process makes the limit mean "uploads processed", which is
  the thing worth limiting.

  A rate-limited or not-yet-finished upload returns the socket untouched: the
  entry stays put and the next form event (`upload_asset`) tries again.
  """
  @spec consume(Phoenix.LiveView.Socket.t(), atom()) :: Phoenix.LiveView.Socket.t()
  def consume(socket, field) do
    declared = ThemeCustomizations.asset_fields(socket.assigns.theme_id)

    if Keyword.has_key?(declared, field) and ready?(socket, field) do
      rate_limited(socket, fn -> process(socket, field) end)
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

  defp progress_callback(component, field) do
    fn _config, entry, socket ->
      if entry.done? do
        send_update(self(), component, id: socket.assigns.id, consume_upload: field)
      end

      {:noreply, socket}
    end
  end

  defp process(socket, field) do
    %{profile: profile, theme_id: theme_id} = socket.assigns

    # The file must be stored inside the callback: the temporary upload is
    # deleted as soon as it returns.
    results =
      consume_uploaded_entries(socket, field, fn %{path: path}, entry ->
        {:ok,
         ThemeCustomizations.attach_asset(profile.id, theme_id, field, %{
           path: path,
           filename: entry.client_name
         })}
      end)

    case results do
      [{:ok, customization}] ->
        Flash.info(success_message(field))
        assign(socket, :customization, customization)

      [{:error, message}] when is_binary(message) ->
        Flash.error(message)
        socket

      [{:error, reason}] ->
        Flash.error(
          ImageUploadErrors.message(reason) || dgettext("dashboard_appearance", "Upload failed")
        )

        socket

      [] ->
        Flash.error(dgettext("dashboard_appearance", "No file was uploaded"))
        socket

      _several ->
        Flash.error(dgettext("dashboard_appearance", "Upload failed"))
        socket
    end
  end

  defp success_message(:background_image_path),
    do: dgettext("dashboard_appearance", "Background image uploaded successfully")

  defp success_message(:background_video_path),
    do: dgettext("dashboard_appearance", "Background video uploaded successfully")

  defp success_message(:logo_path),
    do: dgettext("dashboard_appearance", "Logo uploaded successfully")

  defp success_message(:cover_path),
    do: dgettext("dashboard_appearance", "Cover image uploaded successfully")

  defp success_message(_field), do: dgettext("dashboard_appearance", "File uploaded successfully")

  # Consuming an in-flight entry would truncate the file, so every entry must
  # have finished or been cancelled first.
  defp ready?(socket, field) do
    case socket.assigns[:uploads][field] do
      nil -> false
      %{entries: []} -> false
      %{entries: entries} -> Enum.all?(entries, &(&1.done? or &1.cancelled?))
    end
  end
end
