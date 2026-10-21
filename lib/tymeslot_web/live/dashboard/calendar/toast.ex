defmodule TymeslotWeb.Dashboard.Calendar.Toast do
  @moduledoc """
  The toast that names the result of each change on the calendar surface
  ("Moved to Thu 22 Oct, 11:15") and offers Undo when it can be undone. One
  at a time: a newer result replaces it. It leaves on its own after
  `@lifetime`, or with its close button; Ctrl Z still undoes once it has
  gone.

  The region is always rendered, so screen readers hear each new message.
  Its place and layer come from `calendar-phone.css`: above every sheet and
  modal, and on a phone above the tab bar and the + button.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.LiveView, only: [send_update_after: 3]

  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface

  @lifetime 10_000

  @doc """
  Shows `message`; `undo: true` adds the Undo button. `key:` names the
  event the message is about, so `dismiss/2` can leave other events' toasts.
  """
  @spec show(Phoenix.LiveView.Socket.t(), String.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def show(socket, message, opts \\ []) do
    id = System.unique_integer([:positive])

    send_update_after(
      CalendarSurface,
      [id: socket.assigns.id, action: :toast_expired, toast: id],
      @lifetime
    )

    assign(socket, :toast, %{
      id: id,
      key: Keyword.get(opts, :key),
      message: message,
      undo: Keyword.get(opts, :undo, false)
    })
  end

  @doc "Removes the toast `id` if it is still the one shown."
  @spec expire(Phoenix.LiveView.Socket.t(), integer()) :: Phoenix.LiveView.Socket.t()
  def expire(%{assigns: %{toast: %{id: id}}} = socket, id), do: assign(socket, :toast, nil)
  def expire(socket, _id), do: socket

  @doc "Removes the toast."
  @spec dismiss(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def dismiss(socket), do: assign(socket, :toast, nil)

  @doc "Removes the toast if it is about the event `key` names."
  @spec dismiss(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def dismiss(%{assigns: %{toast: %{key: key}}} = socket, key), do: dismiss(socket)
  def dismiss(socket, _key), do: socket

  attr :toast, :map, default: nil
  attr :target, :any, required: true

  @spec toast(map()) :: Phoenix.LiveView.Rendered.t()
  def toast(assigns) do
    ~H"""
    <div
      id="calendar-toast-region"
      class="cal-toast-region pointer-events-none flex justify-center px-4"
      role="status"
      aria-live="polite"
    >
      <div
        :if={@toast}
        id="calendar-toast"
        class="pointer-events-auto flex max-w-lg items-center gap-3 rounded-token-lg bg-tymeslot-900 py-2.5 pl-4 pr-2 text-token-sm text-white shadow-lg"
      >
        <span class="min-w-0 flex-1">{@toast.message}</span>
        <button
          :if={@toast.undo}
          id="calendar-undo"
          type="button"
          phx-click="calendar:undo"
          phx-target={@target}
          class="min-h-11 min-w-11 shrink-0 rounded-token-md px-2 py-1 font-semibold sm:min-h-0 sm:min-w-0 text-turquoise-300 hover:text-turquoise-200 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400"
        >
          {dgettext("dashboard_calendar", "Undo")}
        </button>
        <button
          type="button"
          phx-click="calendar:dismiss_toast"
          phx-target={@target}
          aria-label={dgettext("dashboard_calendar", "Dismiss")}
          class="min-h-11 min-w-11 shrink-0 max-sm:inline-flex max-sm:items-center max-sm:justify-center rounded-token-md p-1 text-tymeslot-300 hover:text-white focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400 sm:min-h-0 sm:min-w-0"
        >
          <.icon name="hero-x-mark-mini" class="h-4 w-4" />
        </button>
      </div>
    </div>
    """
  end
end
