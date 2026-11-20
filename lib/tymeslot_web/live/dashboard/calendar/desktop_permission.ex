defmodule TymeslotWeb.Dashboard.Calendar.DesktopPermission do
  @moduledoc """
  The browser's side of desktop notifications. Only the browser knows
  whether it allows them, and it asks only inside a user gesture, so the
  `DesktopReminderPermission` hook does the asking: on the display options'
  switch and their "Allow notifications" button, it requests permission in
  the click and pushes the answer here; the command bar's row does the same
  from the key or click that runs it. The preference is saved as on only for
  `"granted"`; turning it off stays the plain toggle (`DisplayPreferences`).

  The surface keeps what it last heard in `desktop_permission`, a map of the
  browser's `permission` (nil until a hook reports it) and whether the last
  attempt to switch on was `refused`, so the display options can say why
  notifications are off, or why they cannot fire while on (`note/1`).
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.Calendar.DisplayPreferences
  alias TymeslotWeb.Dashboard.Calendar.ReminderFeed
  alias TymeslotWeb.Dashboard.Calendar.Toast

  # What `Notification.permission` can say, plus `unsupported` for a browser
  # with no Notification API at all.
  @permissions ~w(default granted denied unsupported)

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "The surface's permission state before any hook has reported."
  @spec initial() :: %{permission: nil, refused: false}
  def initial, do: %{permission: nil, refused: false}

  @doc """
  Answers the hook's events: `calendar:desktop_permission` reports the
  current permission when a control mounts; `calendar:enable_desktop_reminders`
  carries the answer to the request a click made. A refusal from the command
  bar (`"source" => "command"`) is also told in the toast, as the display
  options that would explain it are not open.
  """
  @spec handle(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle("calendar:desktop_permission", %{"permission" => permission}, socket)
      when permission in @permissions,
      do: {:noreply, put(socket, permission, socket.assigns.desktop_permission.refused)}

  def handle("calendar:enable_desktop_reminders", %{"permission" => "granted"}, socket),
    do: {:noreply, socket |> put("granted", false) |> switch_on()}

  def handle("calendar:enable_desktop_reminders", %{"permission" => permission} = params, socket)
      when permission in @permissions do
    socket = put(socket, permission, true)

    if params["source"] == "command",
      do: {:noreply, Toast.show(socket, refusal(permission))},
      else: {:noreply, socket}
  end

  def handle(_event, _params, socket), do: {:noreply, socket}

  defp put(socket, permission, refused),
    do: assign(socket, :desktop_permission, %{permission: permission, refused: refused})

  # A preference saved as on before the browser was asked ("Allow
  # notifications") needs no save, only the permission.
  defp switch_on(%{assigns: %{preferences: %{desktop_reminders_enabled: true}}} = socket),
    do: socket

  defp switch_on(socket),
    do:
      socket
      |> DisplayPreferences.save(:desktop_reminders_enabled, true, :settings)
      |> ReminderFeed.refresh()

  defp refusal("denied"),
    do:
      dgettext(
        "dashboard_calendar_power",
        "Blocked in your browser settings. Allow notifications for this site there, then switch desktop notifications on again."
      )

  defp refusal("unsupported"),
    do: dgettext("dashboard_calendar_power", "This browser does not support notifications.")

  defp refusal(_dismissed),
    do:
      dgettext(
        "dashboard_calendar_power",
        "Your browser did not allow notifications, so desktop notifications are still off."
      )

  attr :id, :string, required: true, doc: "the note's id; the grant button's is derived from it"
  attr :state, :map, required: true, doc: "the surface's `desktop_permission`"
  attr :enabled, :boolean, required: true, doc: "whether the preference is on"

  @doc """
  What the browser's permission means for the switch above it. A `default`
  permission with the preference already on (saved before the switch asked)
  gets a button, which is the user gesture the request needs; a blocked one
  can only be lifted in the browser's own settings.
  """
  @spec note(map()) :: Phoenix.LiveView.Rendered.t()
  def note(%{state: %{permission: "denied"}, enabled: true} = assigns) do
    ~H"""
    <p id={@id} role="status" class="text-token-xs text-amber-700">
      {dgettext(
        "dashboard_calendar_power",
        "Desktop notifications are on, but your browser is blocking them. Allow notifications for this site in your browser settings and they will start."
      )}
    </p>
    """
  end

  def note(%{state: %{permission: "default"}, enabled: true} = assigns) do
    ~H"""
    <div id={@id} role="status" class="space-y-1">
      <p class="text-token-xs text-amber-700">
        {dgettext(
          "dashboard_calendar_power",
          "Desktop notifications are on, but your browser has not allowed them yet."
        )}
      </p>
      <.action_button
        id={"#{@id}-grant"}
        variant={:ghost}
        size={:sm}
        class="max-sm:min-h-11 pointer-coarse:min-h-11"
        phx-hook="DesktopReminderPermission"
        data-report-event="calendar:desktop_permission"
        data-enable-event="calendar:enable_desktop_reminders"
      >
        {dgettext("dashboard_calendar_power", "Allow notifications")}
      </.action_button>
    </div>
    """
  end

  def note(%{state: %{permission: permission}} = assigns)
      when permission in ~w(denied unsupported) do
    assigns = assign(assigns, :message, refusal(permission))

    ~H"""
    <p id={@id} role="status" class="text-token-xs text-amber-700">{@message}</p>
    """
  end

  def note(%{state: %{permission: "default", refused: true}} = assigns) do
    assigns = assign(assigns, :message, refusal("default"))

    ~H"""
    <p id={@id} role="status" class="text-token-xs text-amber-700">{@message}</p>
    """
  end

  def note(assigns), do: ~H""
end
