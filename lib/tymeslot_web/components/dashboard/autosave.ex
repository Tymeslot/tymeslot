defmodule TymeslotWeb.Components.Dashboard.Autosave do
  @moduledoc """
  The pieces a dashboard form needs to save itself instead of carrying a save
  button: an inline status line, and the signal that tells the browser
  nothing typed is waiting to be saved.

  A form that autosaves does three things:

    * debounces its text fields to `"blur"`, so a value is sent when the
      organiser leaves the field rather than at every pause, and a
      half-written paragraph never reaches a public page;
    * on that change, saves when the value is valid and differs from what is
      stored, and otherwise shows the field's error and saves nothing;
    * carries `phx-hook="UnsavedChanges"` and calls `clean/2` whenever what
      the form shows is what is stored (after a save, or when the value is
      unchanged). Until then the hook asks before the tab is closed or
      reloaded, which is the one way out of the page that does not blur the
      field first.

  `status/1` replaces the success toast: the confirmation sits beside the
  fields the organiser just left, once per save, instead of in a corner of
  the screen. A failed save still raises an error flash, because it needs
  noticing.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView

  @typedoc "Where a form's autosave stands: nothing to report, saved, or a save that failed."
  @type status :: :idle | :saved | :error

  @doc """
  Tells the form's `UnsavedChanges` hook that the form shows what is stored,
  so leaving the page needs no warning.
  """
  @spec clean(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def clean(socket, form_id), do: LiveView.push_event(socket, "autosave:clean", %{id: form_id})

  attr :id, :string, required: true
  attr :status, :atom, values: [:idle, :saved, :error], default: :idle
  attr :class, :any, default: nil

  @doc """
  The status line under an autosaving form, announced politely to screen
  readers as it changes.
  """
  @spec status(map()) :: Phoenix.LiveView.Rendered.t()
  def status(assigns) do
    ~H"""
    <p
      id={@id}
      role="status"
      aria-live="polite"
      data-autosave-status={@status}
      class={["flex items-center gap-2 text-sm font-bold", status_colour(@status), @class]}
    >
      <%= case @status do %>
        <% :saved -> %>
          <.icon name="hero-check-circle-mini" class="w-5 h-5 shrink-0" />
          {dgettext("dashboard_common", "Saved")}
        <% :error -> %>
          <.icon name="hero-exclamation-circle-mini" class="w-5 h-5 shrink-0" />
          {dgettext("dashboard_common", "Not saved")}
        <% :idle -> %>
          {dgettext("dashboard_common", "Changes save when you leave a field.")}
      <% end %>
    </p>
    """
  end

  defp status_colour(:saved), do: "text-turquoise-700"
  defp status_colour(:error), do: "text-red-600"
  defp status_colour(:idle), do: "text-tymeslot-500"
end
