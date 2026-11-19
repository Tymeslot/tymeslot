defmodule TymeslotWeb.Dashboard.Calendar.PanelNewDiscard do
  @moduledoc """
  Leaving the side panel's New event state while its draft has guests, who have
  not been invited yet: the panel asks first (`DiscardDraftModal`), whatever
  caused it, be it Cancel, the close button, or something that takes the panel's
  place: the organiser opened another event's preview (`calendar:open`), opened
  one in the panel (`calendar:edit`), or chose More options on a new quick
  create draft (`calendar:more_options`).

  `hold/2` asks, keeping what was asked for in the prompt; Discard
  (`discard/1`) drops the draft and then carries it out, and Go back
  (`keep/1`) leaves everything as it was. A draft with no guests, or a
  meeting already being booked (its guests are being invited), is left at
  once. More options is carried out by the hook, which is told to choose it
  again (`calendar:more-options-again`), since the popover is its own.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias TymeslotWeb.Dashboard.Calendar.PanelNewGuests
  alias TymeslotWeb.Dashboard.Calendar.PanelState

  @type socket :: Phoenix.LiveView.Socket.t()
  @type action :: :close | {:open, String.t()} | {:edit, String.t()} | {:more_options, String.t()}

  @doc """
  Holds `action` behind the question when the open New event draft has
  uninvited guests: `{:held, socket}` with the question on screen, or
  `:go` to carry it out now.
  """
  @spec hold(socket(), action()) :: {:held, socket()} | :go
  def hold(%{assigns: %{panel: %{mode: :new, status: status, form: form}}} = socket, action)
      when status != :saving do
    case PanelNewGuests.count(form) do
      0 -> :go
      count -> {:held, assign(socket, :discard_draft_prompt, %{count: count, then: action})}
    end
  end

  def hold(_socket, _action), do: :go

  @doc """
  Cancel or the close button in the New event state: the panel closes, or
  asks first (`hold/2`).
  """
  @spec cancel(socket()) :: socket()
  def cancel(%{assigns: %{panel: %{mode: :new}}} = socket) do
    case hold(socket, :close) do
      {:held, socket} -> socket
      :go -> PanelState.close(socket)
    end
  end

  def cancel(socket), do: socket

  @doc "Discard: the draft goes, and what was asked for is carried out."
  @spec discard(socket()) :: socket()
  def discard(%{assigns: %{discard_draft_prompt: %{then: action}, panel: %{mode: :new}}} = socket) do
    socket
    |> assign(:discard_draft_prompt, nil)
    |> PanelState.close()
    |> carry_on(action)
  end

  def discard(socket), do: assign(socket, :discard_draft_prompt, nil)

  @doc "Go back: the draft stays, and nothing else happens."
  @spec keep(socket()) :: socket()
  def keep(socket), do: assign(socket, :discard_draft_prompt, nil)

  defp carry_on(socket, :close), do: socket
  # The hook positions and focuses a preview it opened itself; this one it
  # did not (its `calendar:open` was answered `opened: false`), so it is told.
  defp carry_on(socket, {:open, id}) do
    socket = PanelState.open_preview(socket, id)

    if socket.assigns.preview,
      do: push_event(socket, "calendar:preview-opened", %{id: id}),
      else: socket
  end

  defp carry_on(socket, {:edit, id}), do: PanelState.open_edit(socket, id)

  defp carry_on(socket, {:more_options, draft}),
    do: push_event(socket, "calendar:more-options-again", %{draft: draft})
end
